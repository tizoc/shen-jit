/* Included by process.c after its checked native configuration and value helpers. */
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/proc.h>
#endif
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

static int64_t native_last_error(void)
{
    return errno;
}

static bool native_close(Native fd)
{
    return fd < 0 || close(fd) == 0; /* Never retry close: a reused descriptor could be closed. */
}

static char **environment_copy(size_t *count, Error *e)
{
    size_t n = 0, bytes = 0;
    while (environ[n]) {
        bytes += strlen(environ[n]) + 1;
        if (++n > ITEM_LIMIT || bytes > DATA_LIMIT) {
            fail(e, "environment exceeds native limits");
            return NULL;
        }
    }
    char **out = calloc(n + 1, sizeof *out);
    if (!out) {
        fail(e, "cannot copy environment");
        return NULL;
    }
    *count = n;
    for (size_t i = 0; i < n; i++)
        if (!(out[i] = strdup(environ[i]))) {
            fail(e, "cannot copy environment");
            break;
        }
    return out;
}

static char *absolute_path(const char *base, const char *path, Error *e)
{
    if (*path == '/')
        return strdup(path);
    size_t a = strlen(base), b = strlen(path);
    if (a + b + 2 > TEXT_LIMIT) {
        fail(e, "resolved process path exceeds 1 MiB");
        return NULL;
    }
    char *out = malloc(a + b + 2);
    if (!out)
        fail(e, "cannot allocate process path");
    else
        snprintf(out, a + b + 2, "%s/%s", base, path);
    return out;
}

static bool make_pipe(Stream *s, int direction, Error *e)
{
    int fds[2];
#ifdef __linux__
    if (pipe2(fds, O_CLOEXEC) < 0) {
#else
    if (pipe(fds) < 0) {
#endif
        *e = native_error(errno);
        return false;
    }
    for (int i = 0; i < 2; i++) {
        if (fds[i] < 3) {
            int fd = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
            if (fd < 0) {
                *e = native_error(errno);
                close(fds[0]);
                close(fds[1]);
                return false;
            }
            close(fds[i]);
            fds[i] = fd;
        }
    }
    s->pipe->handle = fds[direction ? 0 : 1];
    s->child = fds[direction ? 1 : 0];
    /* Child ends stay blocking. Only the parent's end is nonblocking. */
    if (fcntl(s->pipe->handle, F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(s->pipe->handle, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(s->child, F_SETFD, FD_CLOEXEC) < 0) {
        *e = native_error(errno);
        return false;
    }
    return true;
}

static bool action_error(Error *e, int rc)
{
    if (rc)
        *e = native_error(rc); /* posix_spawn functions return errors, not errno. */
    return rc == 0;
}

#ifndef __APPLE__
/* New glibcs can close the whole range atomically in the child. On older supported glibcs,
   snapshot /proc/self/fd. Project-owned descriptors are created close-on-exec, including during
   this snapshot; foreign libraries must follow that same creation policy. */
static bool close_actions(posix_spawn_file_actions_t *actions, Error *e)
{
    typedef int (*CloseFrom)(posix_spawn_file_actions_t *, int);
    CloseFrom close_from =
        (CloseFrom)dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addclosefrom_np");
    if (close_from)
        return action_error(e, close_from(actions, 3));
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) {
        *e = native_error(errno);
        return false;
    }
    bool ok = true;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            if (errno) {
                *e = native_error(errno);
                ok = false;
            }
            break;
        }
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        if (*end || fd < 3)
            continue;
        if (!action_error(e, posix_spawn_file_actions_addclose(actions, (int)fd))) {
            ok = false;
            break;
        }
    }
    closedir(dir);
    return ok;
}
#endif

static int spawn_program(Spawn *s, Child *c, const char *cwd, posix_spawn_file_actions_t *actions,
                         posix_spawnattr_t *attr)
{
    if (!s->search || strchr(s->program, '/')) {
        Error e = {0};
        char *path = absolute_path(cwd, s->program, &e);
        if (!path)
            return ENOMEM;
        int rc = posix_spawn(&c->pid, path, actions, attr, s->argv, s->env);
        free(path);
        return rc;
    }
    const char *path = "/usr/bin:/bin";
    for (size_t i = 0; i < s->envc; i++)
        if (!strncmp(s->env[i], "PATH=", 5))
            path = s->env[i] + 5;
    bool denied = false;
    for (;;) {
        const char *end = strchr(path, ':');
        size_t n = end ? (size_t)(end - path) : strlen(path);
        char *dir = malloc(n + 1);
        if (!dir)
            return ENOMEM;
        memcpy(dir, path, n);
        dir[n] = 0;
        Error e = {0};
        char *base = n ? absolute_path(cwd, dir, &e) : strdup(cwd);
        char *file = base ? absolute_path(base, s->program, &e) : NULL;
        free(dir);
        free(base);
        if (!file)
            return ENOMEM;
        int rc = posix_spawn(&c->pid, file, actions, attr, s->argv, s->env);
        free(file);
        if (!rc)
            return 0;
        if (rc == EACCES)
            denied = true;
        else if (rc != ENOENT && rc != ENOTDIR)
            return rc;
        if (!end)
            break;
        path = end + 1;
    }
    return denied ? EACCES : ENOENT;
}

static void spawn_native(Spawn *s, Child *c, Error *e)
{
    pthread_mutex_lock(&spawn_lock);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    bool have_actions = false, have_attr = false;
    char *cwd = NULL, *base = NULL;
    struct sigaction disposition;
    if (sigaction(SIGCHLD, NULL, &disposition) < 0) {
        *e = native_error(errno);
        goto done;
    }
    if (disposition.sa_handler == SIG_IGN || (disposition.sa_flags & SA_NOCLDWAIT)) {
        fail(e, "SIGCHLD must permit this library to reap its children");
        goto done;
    }
    base = getcwd(NULL, 0);
    if (!base) {
        *e = native_error(errno);
        goto done;
    }
    cwd = absolute_path(base, s->cwd, e);
    free(base);
    if (!cwd) {
        if (!e->domain)
            fail(e, "cannot allocate working directory");
        goto done;
    }
    if (!action_error(e, posix_spawn_file_actions_init(&actions)))
        goto done;
    have_actions = true;
    if (!action_error(e, posix_spawnattr_init(&attr)))
        goto done;
    have_attr = true;
    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGPIPE);
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (s->group)
        flags |= POSIX_SPAWN_SETPGROUP;
    if (!action_error(e, posix_spawnattr_setflags(&attr, flags)) ||
        !action_error(e, posix_spawnattr_setsigmask(&attr, &mask)) ||
        !action_error(e, posix_spawnattr_setsigdefault(&attr, &defaults)) ||
        (s->group && !action_error(e, posix_spawnattr_setpgroup(&attr, 0))))
        goto done;
    /* This extension is present in glibc 2.29 and macOS 10.15, the adapter's minimums. */
    if (!action_error(e, posix_spawn_file_actions_addchdir_np(&actions, cwd)))
        goto done;
    for (int i = 0; i < 3; i++) {
        Stream *st = &s->streams[i];
        int fd = i;
        if (st->kind == 2) {
            if (!make_pipe(st, i, e))
                goto done;
            fd = st->child;
        } else if (st->kind >= 3 && st->kind <= 5) {
            int mode = st->kind == 3 ? O_RDONLY
                                     : O_WRONLY | O_CREAT | (st->kind == 5 ? O_APPEND : O_TRUNC);
            if (!action_error(e,
                              posix_spawn_file_actions_addopen(&actions, i, st->path, mode, 0666)))
                goto done;
            continue;
        } else if (st->kind == 1) {
            if (!action_error(e, posix_spawn_file_actions_addopen(&actions, i, "/dev/null",
                                                                  i ? O_WRONLY : O_RDONLY, 0)))
                goto done;
            continue;
        } else if (st->kind == 6) {
            fd = st->from->handle;
            int mode = fcntl(fd, F_GETFL);
            if (mode < 0 || fcntl(fd, F_SETFL, mode & ~O_NONBLOCK) < 0) {
                *e = native_error(errno);
                goto done;
            }
        }
        /* dup2(fd, fd) explicitly preserves inherited stdio under CLOEXEC_DEFAULT too. */
        if (!action_error(e, posix_spawn_file_actions_adddup2(&actions, fd, i)))
            goto done;
    }
#ifndef __APPLE__
    if (!close_actions(&actions, e))
        goto done;
#endif
    action_error(e, spawn_program(s, c, cwd, &actions, &attr));
done:
    if (e->domain && s->streams[0].from)
        fcntl(s->streams[0].from->handle, F_SETFL, O_NONBLOCK);
    for (int i = 0; i < 3; i++)
        native_close(s->streams[i].child);
    if (have_attr)
        posix_spawnattr_destroy(&attr);
    if (have_actions)
        posix_spawn_file_actions_destroy(&actions);
    free(cwd);
    pthread_mutex_unlock(&spawn_lock);
}

static void child_poll(Child *c, Error *e)
{
    if (c->exited)
        return;
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)c->pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
        if (errno != EINTR)
            *e = native_error(errno);
    } else if (info.si_pid) {
        c->exited = true;
        c->kind = info.si_code == CLD_EXITED ? 1 : 2;
        c->code = (uint32_t)info.si_status;
    }
}

static void child_signal(Child *c, bool force, Error *e)
{
    if (c->exited && !c->group)
        return;
    if (kill(c->group ? -c->pid : c->pid, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH)
        return;
    int code = errno;
#ifdef __APPLE__
    /* Darwin returns EPERM for a group containing only its reserved zombie leader. Do not
       hide a real permission failure if live members remain. With no live member, none can fork. */
    if (code == EPERM && c->group && !c->exited) {
        Error observed = {0};
        child_poll(c, &observed);
    }
    if (code == EPERM && c->group && c->exited) {
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, c->pid};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size <= DATA_LIMIT) {
            size += 32 * sizeof(struct kinfo_proc);
            struct kinfo_proc *members = malloc(size);
            if (members && sysctl(mib, 4, members, &size, NULL, 0) == 0) {
                bool alive = false;
                for (size_t i = 0; i < size / sizeof *members; i++)
                    if (members[i].kp_proc.p_stat != SZOMB && members[i].kp_proc.p_stat != 0)
                        alive = true;
                free(members);
                if (!alive)
                    return;
            } else
                free(members);
        }
    }
#endif
    *e = native_error(code);
}

static void child_close(Child *c, Error *e)
{
    /* Closing releases ownership; termination is explicit. Keep the leader reserved until now
       so a group signal after its exit cannot hit a reused process-group ID. */
    int status;
    pid_t rc;
    do {
        rc = waitpid(c->pid, &status, WNOHANG);
    } while (rc < 0 && errno == EINTR);
    if (rc != c->pid && !e->domain)
        *e = rc < 0 ? native_error(errno) : (Error){3, 0, "observed child was not ready to reap"};
}

static int64_t pipe_transfer(Pipe *p, unsigned char *data, size_t n, bool writing, Error *e)
{
    ssize_t rc = writing ? write(p->handle, data, n) : read(p->handle, data, n);
    if (rc >= 0)
        return writing && !rc ? -1 : rc;
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
        return -1;
    *e = native_error(errno);
    return 0;
}

static void pipe_pause(Pipe **pipes, size_t n, int milliseconds)
{
    struct pollfd fds[96];
    for (size_t i = 0; i < n; i++)
        fds[i] = (struct pollfd){pipes[i]->handle, pipes[i]->writing ? POLLOUT : POLLIN, 0};
    poll(fds, n, milliseconds); /* EINTR returns to Shen's deadline/cancellation checks. */
}

/* Native process/pipe operations. Shen owns pumping, limits, deadlines and cleanup policy. */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0A00
#endif
#include "shen.h"
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#include <wchar.h>
#define EXPORT __declspec(dllexport)
typedef HANDLE Native;
#define INVALID_NATIVE INVALID_HANDLE_VALUE
#else
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#define EXPORT __attribute__((visibility("default")))
typedef int Native;
#define INVALID_NATIVE (-1)
extern char **environ;
#endif

#define CHUNK 65536
#define TEXT_LIMIT 1048576
#define DATA_LIMIT 8388608
#define ITEM_LIMIT 65536

typedef struct {
    int domain;
    int64_t code;
    const char *message;
} Error;

typedef struct {
    Native handle;
    bool busy, writing, transferred;
} Pipe;

typedef struct {
    bool busy, group, exited;
    int kind;
    uint32_t code;
#ifdef _WIN32
    HANDLE handle, job;
    DWORD pid;
#else
    pid_t pid;
#endif
} Child;

typedef struct {
    int kind; /* inherit, null, pipe, read file, write file, append file, pipe from previous child
               */
    char *path;
    Pipe *from, *pipe;
    Native child;
} Stream;

typedef struct {
    char *program, **argv, **env, *cwd;
    size_t argc, envc;
    bool group, search;
    Stream streams[3];
} Spawn;

static Error native_error(int64_t code)
{
    return (Error){
#ifdef _WIN32
        2,
#else
        1,
#endif
        code, NULL};
}

static bool fail(Error *e, const char *message)
{
    *e = (Error){3, 0, message};
    return false;
}

/* This vector is distinct from every successful native result. */
static shen_value error_result(shen_vm *vm, Error e)
{
    char text[1024] = "";
    if (e.message)
        snprintf(text, sizeof text, "%s", e.message);
    else if (e.domain == 1)
        snprintf(text, sizeof text, "%s", strerror((int)e.code));
#ifdef _WIN32
    else {
        wchar_t wide[512];
        DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
                                 (DWORD)e.code, 0, wide, 512, NULL);
        if (!n || !WideCharToMultiByte(CP_UTF8, 0, wide, (int)n, text, sizeof text - 1, NULL, NULL))
            snprintf(text, sizeof text, "Windows process error %lld", (long long)e.code);
    }
#endif
    shen_value out = shen_make_vector(vm, 4, SHEN_NIL);
    if (out == SHEN_ERROR)
        return out;
    shen_root(vm, &out);
    shen_vector_set(vm, out, 0, shen_make_fixnum(-1));
    shen_vector_set(vm, out, 1, shen_make_fixnum(e.domain));
    shen_vector_set(vm, out, 2, shen_make_fixnum(e.code));
    shen_value message = shen_make_string(vm, text, strlen(text));
    if (message != SHEN_ERROR)
        shen_vector_set(vm, out, 3, message);
    shen_unroot(vm, 1);
    return message == SHEN_ERROR ? message : out;
}

static char *copy_text(shen_vm *vm, shen_value v, size_t *budget, Error *e)
{
    size_t n;
    const char *text = shen_string_bytes(vm, v, &n);
    if (!text || n > TEXT_LIMIT || n + 1 > *budget || memchr(text, 0, n)) {
        fail(e, "arguments must be NUL-free strings within the configured native limits");
        return NULL;
    }
    char *copy = malloc(n + 1);
    if (!copy) {
        fail(e, "cannot allocate process arguments");
        return NULL;
    }
    memcpy(copy, text, n);
    copy[n] = 0;
    *budget -= n + 1;
    return copy;
}

static char **copy_strings(shen_vm *vm, shen_value list, const char *first, size_t *count, Error *e)
{
    size_t n = first ? 1 : 0, budget = DATA_LIMIT;
    shen_value tail = list;
    while (shen_is_pair(vm, tail)) {
        if (++n > ITEM_LIMIT) {
            fail(e, "too many process arguments or environment entries");
            return NULL;
        }
        tail = shen_tail(vm, tail);
    }
    if (tail != SHEN_NIL) {
        fail(e, "process arguments must be a proper list");
        return NULL;
    }
    char **items = calloc(n + 1, sizeof *items);
    if (!items) {
        fail(e, "cannot allocate process arguments");
        return NULL;
    }
    size_t i = 0;
    if (first) {
        items[i++] = strdup(first);
        if (!items[0])
            fail(e, "cannot allocate program name");
    }
    for (; i < n && !e->domain; i++, list = shen_tail(vm, list))
        items[i] = copy_text(vm, shen_head(vm, list), &budget, e);
    *count = n;
    return items;
}

static void free_strings(char **items, size_t count)
{
    if (items)
        for (size_t i = 0; i < count; i++)
            free(items[i]);
    free(items);
}

static void free_spawn(Spawn *s)
{
    free(s->program);
    free(s->cwd);
    free_strings(s->argv, s->argc);
    free_strings(s->env, s->envc);
    for (int i = 0; i < 3; i++)
        free(s->streams[i].path);
}

static bool read_spawn(shen_vm *vm, shen_value v, Spawn *s, Error *e)
{
    if (shen_vector_length(vm, v) != 7)
        return fail(e, "invalid spawn configuration");
    size_t budget = DATA_LIMIT;
    s->program = copy_text(vm, shen_vector_ref(vm, v, 0), &budget, e);
    s->cwd = copy_text(vm, shen_vector_ref(vm, v, 3), &budget, e);
    if (e->domain || !*s->program || !*s->cwd)
        return fail(e, "program and working directory must not be empty");
    s->argv = copy_strings(vm, shen_vector_ref(vm, v, 1), s->program, &s->argc, e);
    s->env = copy_strings(vm, shen_vector_ref(vm, v, 2), NULL, &s->envc, e);
    if (e->domain)
        return false;
    for (size_t i = 0; i < s->envc; i++)
        if (!strchr(s->env[i], '=') || s->env[i][0] == '=')
            return fail(e, "invalid environment entry");
    shen_value streams = shen_vector_ref(vm, v, 4);
    if (shen_vector_length(vm, streams) != 3)
        return fail(e, "invalid standard stream configuration");
    for (int i = 0; i < 3; i++) {
        Stream *st = &s->streams[i];
        shen_value pair = shen_vector_ref(vm, streams, i);
        if (shen_vector_length(vm, pair) != 2)
            return fail(e, "invalid standard stream");
        shen_value kind = shen_vector_ref(vm, pair, 0);
        if (!shen_is_fixnum(kind) || shen_fixnum(kind) < 0 || shen_fixnum(kind) > 6)
            return fail(e, "invalid standard stream kind");
        st->kind = (int)shen_fixnum(kind);
        if (st->kind >= 3 && st->kind <= 5) {
            st->path = copy_text(vm, shen_vector_ref(vm, pair, 1), &budget, e);
            if (!st->path)
                return false;
        }
        if (st->kind == 6) {
            st->from = shen_pointer(vm, shen_vector_ref(vm, pair, 1), "process.pipe");
            if (i || !st->from || st->from->writing || st->from->busy || st->from->transferred)
                return fail(e, "pipeline input is not an available output pipe");
        }
    }
    shen_value group = shen_vector_ref(vm, v, 5), search = shen_vector_ref(vm, v, 6);
    if ((group != SHEN_TRUE && group != SHEN_FALSE) ||
        (search != SHEN_TRUE && search != SHEN_FALSE))
        return fail(e, "invalid spawn flags");
    s->group = group == SHEN_TRUE;
    s->search = search == SHEN_TRUE;
    return true;
}

#ifdef _WIN32
#include "process-win.h"
#else
#include "process-posix.h"
#endif

EXPORT int shen_process_abi(void)
{
    return 1;
}

EXPORT shen_value shen_process_environment(shen_vm *vm, shen_value *args)
{
    (void)args;
    Error e = {0};
    size_t count = 0;
    char **items = environment_copy(&count, &e);
    shen_value out = SHEN_NIL, text = SHEN_NIL;
    shen_root(vm, &out);
    shen_root(vm, &text);
    for (size_t i = count; i && !e.domain; i--) {
        text = shen_make_string(vm, items[i - 1], strlen(items[i - 1]));
        if (text == SHEN_ERROR || (out = shen_cons(vm, text, out)) == SHEN_ERROR)
            break;
    }
    free_strings(items, count);
    shen_value result = e.domain ? error_result(vm, e) : text == SHEN_ERROR ? SHEN_ERROR : out;
    shen_unroot(vm, 2);
    return result;
}

EXPORT shen_value shen_process_spawn(shen_vm *vm, shen_value *args)
{
    if (!shen_is_procedure(vm, args[1]))
        return shen_raise(vm, "process: missing child constructor");
    Spawn s = {0};
    Error e = {0};
    for (int i = 0; i < 3; i++)
        s.streams[i].child = INVALID_NATIVE;
    if (!read_spawn(vm, args[0], &s, &e)) {
        free_spawn(&s);
        return error_result(vm, e);
    }
    Child *child = calloc(1, sizeof *child);
    bool pending = false;
    shen_value out = SHEN_NIL, wrapper = SHEN_NIL;
    shen_root(vm, &out);
    shen_root(vm, &wrapper);
    if (!child)
        goto memory;
    child->group = s.group;
    out = shen_make_vector(vm, 5, SHEN_NIL);
    if (out == SHEN_ERROR) {
        pending = true;
        goto memory;
    }
    shen_value pointer = shen_make_pointer(vm, child, "process.child");
    if (pointer == SHEN_ERROR) {
        pending = true;
        goto memory;
    }
    shen_vector_set(vm, out, 0, pointer);
    for (int i = 0; i < 3; i++) {
        if (s.streams[i].kind != 2)
            continue;
        Pipe *p = calloc(1, sizeof *p);
        if (!p)
            goto memory;
        p->handle = INVALID_NATIVE;
        p->writing = i == 0;
        s.streams[i].pipe = p;
        pointer = shen_make_pointer(vm, p, "process.pipe");
        if (pointer == SHEN_ERROR) {
            pending = true;
            goto memory;
        }
        shen_vector_set(vm, out, i + 1, pointer);
    }
    /* Construct every managed endpoint before starting the child. An OOM cannot orphan it. */
    wrapper = shen_call(vm, args[1], 1, &out);
    if (wrapper == SHEN_ERROR) {
        pending = true;
        goto memory;
    }
    if (s.streams[0].from)
        s.streams[0].from->busy = true;
    void *token = shen_release(vm);
    spawn_native(&s, child, &e);
    shen_acquire(vm, token);
    if (s.streams[0].from) {
        s.streams[0].from->busy = false;
        if (!e.domain)
            s.streams[0].from->transferred = true;
    }
    if (e.domain)
        goto failed;
    shen_vector_set(vm, out, 4, shen_make_fixnum(child->pid));
    free_spawn(&s);
    shen_unroot(vm, 2);
    return wrapper;

memory:
    if (!pending)
        fail(&e, "cannot allocate child handle");
failed:
    for (int i = 0; i < 3; i++) {
        if (s.streams[i].pipe) {
            native_close(s.streams[i].pipe->handle);
            free(s.streams[i].pipe);
        }
    }
    free(child);
    free_spawn(&s);
    shen_unroot(vm, 2);
    return pending ? SHEN_ERROR : error_result(vm, e);
}

EXPORT shen_value shen_process_poll(shen_vm *vm, shen_value *args)
{
    Child *c = shen_pointer(vm, args[0], "process.child");
    if (!c || c->busy)
        return shen_raise(vm, "process: child is closed, stale or already in use");
    c->busy = true;
    Error e = {0};
    void *token = shen_release(vm);
    child_poll(c, &e);
    shen_acquire(vm, token);
    c->busy = false;
    if (e.domain)
        return error_result(vm, e);
    shen_value out = shen_make_vector(vm, 2, SHEN_NIL);
    if (out != SHEN_ERROR) {
        shen_vector_set(vm, out, 0, shen_make_fixnum(c->exited ? c->kind : 0));
        shen_vector_set(vm, out, 1, shen_make_fixnum(c->code));
    }
    return out;
}

EXPORT shen_value shen_process_signal(shen_vm *vm, shen_value *args)
{
    Child *c = shen_pointer(vm, args[0], "process.child");
    if (!c || c->busy || (args[1] != SHEN_TRUE && args[1] != SHEN_FALSE))
        return shen_raise(vm, "process: invalid or busy child");
    c->busy = true;
    bool force = args[1] == SHEN_TRUE;
    Error e = {0};
    void *token = shen_release(vm);
    child_signal(c, force, &e);
    shen_acquire(vm, token);
    c->busy = false;
    return e.domain ? error_result(vm, e) : SHEN_TRUE;
}

/* Invalidators kill aliases while holding the VM lock, before native resources are freed. */
static bool invalidate(shen_vm *vm, shen_value *args, const char *kind)
{
    if (!shen_is_procedure(vm, args[1])) {
        shen_raise(vm, "process: missing handle invalidator");
        return false;
    }
    if (shen_call(vm, args[1], 1, args) == SHEN_ERROR)
        return false;
    if (shen_pointer(vm, args[0], kind)) {
        shen_raise(vm, "process: handle was not invalidated");
        return false;
    }
    return true;
}

EXPORT shen_value shen_process_close(shen_vm *vm, shen_value *args)
{
    Child *c = shen_pointer(vm, args[0], "process.child");
    if (!c || c->busy)
        return shen_raise(vm, "process: invalid or busy child");
    if (!c->exited)
        return error_result(vm, (Error){3, 0, "wait for the child before closing it"});
    c->busy = true;
    if (!invalidate(vm, args, "process.child")) {
        c->busy = false;
        return SHEN_ERROR;
    }
    Error e = {0};
    void *token = shen_release(vm);
    child_close(c, &e);
    free(c);
    shen_acquire(vm, token);
    return e.domain ? error_result(vm, e) : SHEN_TRUE;
}

EXPORT shen_value shen_process_pipe_close(shen_vm *vm, shen_value *args)
{
    Pipe *p = shen_pointer(vm, args[0], "process.pipe");
    if (!p || p->busy)
        return shen_raise(vm, "process: invalid or busy pipe");
    p->busy = true;
    if (!invalidate(vm, args, "process.pipe")) {
        p->busy = false;
        return SHEN_ERROR;
    }
    Error e = {0};
    void *token = shen_release(vm);
    if (!native_close(p->handle))
        e = native_error(native_last_error());
    free(p);
    shen_acquire(vm, token);
    return e.domain ? error_result(vm, e) : SHEN_TRUE;
}

static shen_value transfer(shen_vm *vm, shen_value *args, bool writing)
{
    Pipe *p = shen_pointer(vm, args[0], "process.pipe");
    size_t n;
    unsigned char *bytes = shen_bytes_data(vm, args[1], &n);
    if (!p || p->busy || p->transferred || p->writing != writing || !bytes || !n || n > CHUNK)
        return shen_raise(vm, "process: invalid pipe transfer");
    unsigned char data[CHUNK];
    if (writing)
        memcpy(data, bytes, n);
    p->busy = true;
    Error e = {0};
    void *token = shen_release(vm);
    int64_t moved = pipe_transfer(p, data, n, writing, &e);
    shen_acquire(vm, token);
    p->busy = false;
    if (!writing && moved > 0) {
        bytes = shen_bytes_data(vm, args[1], &n);
        memcpy(bytes, data, (size_t)moved);
    }
    return e.domain ? error_result(vm, e) : shen_make_fixnum(moved);
}

EXPORT shen_value shen_process_read(shen_vm *vm, shen_value *args)
{
    return transfer(vm, args, false);
}

EXPORT shen_value shen_process_write(shen_vm *vm, shen_value *args)
{
    return transfer(vm, args, true);
}

EXPORT shen_value shen_process_pause(shen_vm *vm, shen_value *args)
{
    if (!shen_is_fixnum(args[1]) || shen_fixnum(args[1]) < 0 || shen_fixnum(args[1]) > 100)
        return shen_raise(vm, "process: invalid wait slice");
    Pipe *pipes[96];
    size_t n = 0;
    shen_value list = args[0];
    for (; shen_is_pair(vm, list); list = shen_tail(vm, list)) {
        Pipe *p = shen_pointer(vm, shen_head(vm, list), "process.pipe");
        if (!p || p->busy || p->transferred || n == 96)
            return shen_raise(vm, "process: invalid wait pipes");
        pipes[n++] = p;
    }
    if (list != SHEN_NIL)
        return shen_raise(vm, "process: invalid wait pipe list");
    for (size_t i = 0; i < n; i++)
        pipes[i]->busy = true;
    int milliseconds = (int)shen_fixnum(args[1]);
    void *token = shen_release(vm);
    pipe_pause(pipes, n, milliseconds);
    shen_acquire(vm, token);
    for (size_t i = 0; i < n; i++)
        pipes[i]->busy = false;
    return SHEN_TRUE;
}

/* Windows 10+: explicit handle/job lists and nonblocking local byte pipes. */
#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
/* Older MinGW headers omit this Windows 10 SDK attribute. Its published number is 13. */
#define PROC_THREAD_ATTRIBUTE_JOB_LIST ProcThreadAttributeValue(13, FALSE, TRUE, FALSE)
#endif
static SRWLOCK spawn_lock = SRWLOCK_INIT;

static int64_t native_last_error(void)
{
    return GetLastError();
}

static bool native_close(Native h)
{
    return !h || h == INVALID_HANDLE_VALUE || CloseHandle(h);
}

static wchar_t *wide_text(const char *text, Error *e)
{
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!n) {
        *e = native_error(GetLastError());
        return NULL;
    }
    wchar_t *out = malloc((size_t)n * sizeof *out);
    if (!out)
        fail(e, "cannot allocate UTF-16 arguments");
    else if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, out, n)) {
        *e = native_error(GetLastError());
        free(out);
        out = NULL;
    }
    return out;
}

static char *utf8_text(const wchar_t *text, Error *e)
{
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, NULL, 0, NULL, NULL);
    if (!n) {
        *e = native_error(GetLastError());
        return NULL;
    }
    char *out = malloc((size_t)n);
    if (!out)
        fail(e, "cannot allocate UTF-8 environment");
    else if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, out, n, NULL, NULL)) {
        *e = native_error(GetLastError());
        free(out);
        out = NULL;
    }
    return out;
}

static char **environment_copy(size_t *count, Error *e)
{
    wchar_t *block = GetEnvironmentStringsW();
    if (!block) {
        *e = native_error(GetLastError());
        return NULL;
    }
    size_t n = 0, bytes = 0;
    for (const wchar_t *p = block; *p; p += wcslen(p) + 1)
        if (*p != L'=')
            n++;
    char **out = n <= ITEM_LIMIT ? calloc(n + 1, sizeof *out) : NULL;
    if (!out)
        fail(e, "cannot allocate environment or too many entries");
    else {
        for (const wchar_t *p = block; *p && !e->domain; p += wcslen(p) + 1) {
            if (*p == L'=')
                continue; /* Drive-relative hidden variables are not part of the public environment.
                           */
            char *text = utf8_text(p, e);
            out[(*count)++] = text;
            if (text && (bytes += strlen(text) + 1) > DATA_LIMIT)
                fail(e, "environment exceeds native limits");
        }
    }
    FreeEnvironmentStringsW(block);
    return out;
}

static wchar_t *full_path(const wchar_t *text, Error *e)
{
    DWORD n = GetFullPathNameW(text, 0, NULL, NULL);
    if (!n || n > 32768) {
        *e = n ? (Error){3, 0, "Windows path exceeds 32767 UTF-16 units"}
               : native_error(GetLastError());
        return NULL;
    }
    wchar_t *out = malloc((size_t)n * sizeof *out);
    if (!out)
        fail(e, "cannot allocate working directory");
    else {
        DWORD used = GetFullPathNameW(text, n, out, NULL);
        if (!used || used >= n) {
            *e = native_error(used ? ERROR_INSUFFICIENT_BUFFER : GetLastError());
            free(out);
            out = NULL;
        }
    }
    return out;
}

static wchar_t *path_at(const wchar_t *base, const wchar_t *path, Error *e)
{
    bool slash = *path == L'/' || *path == L'\\';
    bool unc = slash && (path[1] == L'/' || path[1] == L'\\');
    if (path[0] && path[1] == L':' && path[2] != L'/' && path[2] != L'\\') {
        fail(e, "Windows drive-relative paths are unsupported");
        return NULL;
    }
    if (unc || (path[0] && path[1] == L':'))
        return full_path(path, e);
    size_t a = wcslen(base), b = wcslen(path);
    if (slash) {
        if (base[0] && base[1] == L':')
            a = 2;
        else {
            a = 2;
            for (int component = 0; component < 2; component++) {
                while (base[a] && base[a] != L'\\' && base[a] != L'/')
                    a++;
                if (!component && base[a])
                    a++;
            }
        }
    }
    if (a + b + 2 > 32768) {
        fail(e, "Windows path exceeds 32767 UTF-16 units");
        return NULL;
    }
    wchar_t *out = malloc((a + b + 2) * sizeof *out);
    if (!out)
        fail(e, "cannot allocate process path");
    else {
        memcpy(out, base, a * sizeof *out);
        size_t at = a;
        if (!slash)
            out[at++] = L'\\';
        memcpy(out + at, path, (b + 1) * sizeof *out);
    }
    return out;
}

static bool command_char(wchar_t *out, size_t *used, wchar_t c, Error *e)
{
    if (*used >= 32766)
        return fail(e, "Windows command line exceeds 32766 UTF-16 units");
    out[(*used)++] = c;
    return true;
}

/* Quote every argument by the Microsoft CRT convention, including empty arguments. */
static wchar_t *command_line(Spawn *s, Error *e)
{
    wchar_t *out = calloc(32768, sizeof *out);
    if (!out) {
        fail(e, "cannot allocate command line");
        return NULL;
    }
    size_t used = 0;
    for (size_t i = 0; i < s->argc && !e->domain; i++) {
        wchar_t *arg = wide_text(s->argv[i], e);
        if (!arg)
            break;
        if (i)
            command_char(out, &used, L' ', e);
        command_char(out, &used, L'"', e);
        const wchar_t *p = arg;
        while (!e->domain) {
            size_t slashes = 0;
            while (*p == L'\\') {
                slashes++;
                p++;
            }
            size_t emit = (*p == L'"' || !*p) ? slashes * 2 : slashes;
            if (*p == L'"')
                emit++;
            for (size_t j = 0; j < emit && !e->domain; j++)
                command_char(out, &used, L'\\', e);
            if (!*p)
                break;
            command_char(out, &used, *p++, e);
        }
        command_char(out, &used, L'"', e);
        free(arg);
    }
    if (e->domain) {
        free(out);
        return NULL;
    }
    return out;
}

static int compare_environment(const void *a, const void *b)
{
    return CompareStringOrdinal(*(wchar_t *const *)a, -1, *(wchar_t *const *)b, -1, TRUE) -
           CSTR_EQUAL;
}

static wchar_t *environment_block(Spawn *s, Error *e)
{
    wchar_t **items = calloc(s->envc + 1, sizeof *items);
    if (!items) {
        fail(e, "cannot allocate environment");
        return NULL;
    }
    size_t size = 1;
    for (size_t i = 0; i < s->envc && !e->domain; i++) {
        items[i] = wide_text(s->env[i], e);
        if (items[i])
            size += wcslen(items[i]) + 1;
    }
    wchar_t *block = e->domain ? NULL : calloc(size + 1, sizeof *block);
    if (!block && !e->domain)
        fail(e, "cannot allocate environment block");
    if (block) {
        qsort(items, s->envc, sizeof *items, compare_environment);
        size_t at = 0;
        for (size_t i = 0; i < s->envc; i++) {
            size_t n = wcslen(items[i]) + 1;
            memcpy(block + at, items[i], n * sizeof *block);
            at += n;
        }
    }
    for (size_t i = 0; i < s->envc; i++)
        free(items[i]);
    free(items);
    return block;
}

static wchar_t *executable_at(const wchar_t *cwd, const wchar_t *program, Error *e)
{
    wchar_t *path = path_at(cwd, program, e);
    if (!path)
        return NULL;
    const wchar_t *name = path;
    for (const wchar_t *p = path; *p; p++)
        if (*p == L'/' || *p == L'\\')
            name = p + 1;
    const wchar_t *extension = wcsrchr(name, L'.');
    if (extension && (!_wcsicmp(extension, L".cmd") || !_wcsicmp(extension, L".bat"))) {
        fail(e, "batch files require an explicitly invoked command interpreter");
        free(path);
        return NULL;
    }
    if (!extension) {
        size_t n = wcslen(path);
        wchar_t *next = realloc(path, (n + 5) * sizeof *path);
        if (!next) {
            fail(e, "cannot allocate executable path");
            free(path);
            return NULL;
        }
        path = next;
        memcpy(path + n, L".exe", 5 * sizeof *path);
    }
    return path;
}

static wchar_t *find_program(Spawn *s, const wchar_t *cwd, Error *e)
{
    wchar_t *program = wide_text(s->program, e);
    if (!program)
        return NULL;
    if (!s->search || wcschr(program, L'/') || wcschr(program, L'\\') || wcschr(program, L':')) {
        wchar_t *out = executable_at(cwd, program, e);
        free(program);
        return out;
    }
    const char *search = NULL;
    for (size_t i = 0; i < s->envc; i++)
        if (!_strnicmp(s->env[i], "PATH=", 5))
            search = s->env[i] + 5;
    wchar_t *paths;
    if (search)
        paths = wide_text(search, e);
    else {
        wchar_t system[32768];
        UINT n = GetSystemDirectoryW(system, 32768);
        paths = n && n < 32768 ? _wcsdup(system) : NULL;
        if (!paths)
            fail(e, "cannot obtain default executable search directory");
    }
    wchar_t *out = NULL;
    if (paths) {
        wchar_t *at = paths;
        for (;;) {
            wchar_t *end = wcschr(at, L';');
            if (end)
                *end = 0;
            size_t n = wcslen(at);
            if (n >= 2 && at[0] == L'"' && at[n - 1] == L'"') {
                at[n - 1] = 0;
                at++;
            }
            wchar_t *base = *at ? path_at(cwd, at, e) : _wcsdup(cwd);
            wchar_t *candidate = base ? executable_at(base, program, e) : NULL;
            free(base);
            if (candidate) {
                DWORD attributes = GetFileAttributesW(candidate);
                if (attributes != INVALID_FILE_ATTRIBUTES &&
                    !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
                    out = candidate;
                    break;
                }
                free(candidate);
            }
            if (!end || e->domain)
                break;
            at = end + 1;
        }
    }
    free(paths);
    free(program);
    if (!out && !e->domain)
        *e = native_error(ERROR_FILE_NOT_FOUND);
    return out;
}

static bool make_pipe(Stream *s, int direction, Error *e)
{
    unsigned char random[16];
    if (BCryptGenRandom(NULL, random, sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG))
        return fail(e, "cannot obtain a secure pipe name");
    wchar_t name[160];
    uint64_t a, b;
    memcpy(&a, random, 8);
    memcpy(&b, random + 8, 8);
    swprintf(name, 160, L"\\\\.\\pipe\\shen-jit-%lu-%016llx%016llx",
             (unsigned long)GetCurrentProcessId(), (unsigned long long)a, (unsigned long long)b);
    HANDLE server = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                     PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT |
                                         PIPE_REJECT_REMOTE_CLIENTS,
                                     1, CHUNK, CHUNK, 0, NULL);
    if (server == INVALID_HANDLE_VALUE) {
        *e = native_error(GetLastError());
        return false;
    }
    s->pipe->handle = server;
    SECURITY_ATTRIBUTES security = {sizeof security, NULL, TRUE};
    HANDLE client = CreateFileW(name, direction ? GENERIC_WRITE : GENERIC_READ, 0, &security,
                                OPEN_EXISTING, 0, NULL);
    if (client == INVALID_HANDLE_VALUE) {
        *e = native_error(GetLastError());
        return false;
    }
    s->child = client;
    if (!ConnectNamedPipe(server, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) {
        *e = native_error(GetLastError());
        return false;
    }
    /* The client retains PIPE_WAIT; the parent's handle returns immediately when empty/full. */
    return true;
}

static void spawn_native(Spawn *s, Child *c, Error *e)
{
    AcquireSRWLockExclusive(&spawn_lock);
    wchar_t *raw = wide_text(s->cwd, e);
    wchar_t *cwd = raw ? full_path(raw, e) : NULL;
    free(raw);
    wchar_t *program = cwd ? find_program(s, cwd, e) : NULL;
    wchar_t *command = e->domain ? NULL : command_line(s, e);
    wchar_t *environment = e->domain ? NULL : environment_block(s, e);
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof startup;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    HANDLE handles[3] = {0};
    SIZE_T size = 0;
    bool attributes_ready = false;
    if (e->domain)
        goto done;
    for (int i = 0; i < 3; i++) {
        Stream *st = &s->streams[i];
        SECURITY_ATTRIBUTES security = {sizeof security, NULL, TRUE};
        if (st->kind == 2) {
            if (!make_pipe(st, i, e))
                goto done;
        } else if (st->kind >= 3 && st->kind <= 5) {
            wchar_t *name = wide_text(st->path, e);
            wchar_t *path = name ? path_at(cwd, name, e) : NULL;
            free(name);
            if (!path)
                goto done;
            DWORD access = st->kind == 3   ? GENERIC_READ
                           : st->kind == 5 ? FILE_APPEND_DATA
                                           : GENERIC_WRITE;
            DWORD mode = st->kind == 3   ? OPEN_EXISTING
                         : st->kind == 5 ? OPEN_ALWAYS
                                         : CREATE_ALWAYS;
            st->child =
                CreateFileW(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            &security, mode, FILE_ATTRIBUTE_NORMAL, NULL);
            free(path);
        } else if (st->kind == 1) {
            st->child =
                CreateFileW(L"NUL", i ? GENERIC_WRITE : GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
        } else {
            HANDLE source = st->kind == 6 ? st->from->handle
                                          : GetStdHandle(i == 0   ? STD_INPUT_HANDLE
                                                         : i == 1 ? STD_OUTPUT_HANDLE
                                                                  : STD_ERROR_HANDLE);
            if (st->kind == 6) {
                DWORD mode = PIPE_WAIT | PIPE_READMODE_BYTE;
                if (!SetNamedPipeHandleState(source, &mode, NULL, NULL)) {
                    *e = native_error(GetLastError());
                    goto done;
                }
            }
            if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), &st->child, 0,
                                 TRUE, DUPLICATE_SAME_ACCESS)) {
                *e = native_error(GetLastError());
                goto done;
            }
        }
        if (st->child == INVALID_HANDLE_VALUE) {
            *e = native_error(GetLastError());
            goto done;
        }
        handles[i] = st->child;
    }
    startup.StartupInfo.hStdInput = handles[0];
    startup.StartupInfo.hStdOutput = handles[1];
    startup.StartupInfo.hStdError = handles[2];
    if (s->group) {
        c->job = CreateJobObjectW(NULL, NULL);
        if (!c->job) {
            *e = native_error(GetLastError());
            goto done;
        }
    }
    InitializeProcThreadAttributeList(NULL, s->group ? 2 : 1, 0, &size);
    startup.lpAttributeList = malloc(size);
    if (!startup.lpAttributeList) {
        fail(e, "cannot allocate process attributes");
        goto done;
    }
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, s->group ? 2 : 1, 0, &size)) {
        *e = native_error(GetLastError());
        goto done;
    }
    attributes_ready = true;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   handles, sizeof handles, NULL, NULL) ||
        (s->group &&
         !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                    &c->job, sizeof c->job, NULL, NULL))) {
        *e = native_error(GetLastError());
        goto done;
    }
    PROCESS_INFORMATION info = {0};
    if (!CreateProcessW(program, command, NULL, NULL, TRUE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                            (s->group ? CREATE_NEW_PROCESS_GROUP : 0),
                        environment, cwd, &startup.StartupInfo, &info))
        *e = native_error(GetLastError());
    else {
        c->handle = info.hProcess;
        c->pid = info.dwProcessId;
        CloseHandle(info.hThread);
    }
done:
    if (e->domain && s->streams[0].from) {
        DWORD mode = PIPE_NOWAIT | PIPE_READMODE_BYTE;
        SetNamedPipeHandleState(s->streams[0].from->handle, &mode, NULL, NULL);
    }
    for (int i = 0; i < 3; i++)
        native_close(s->streams[i].child);
    if (attributes_ready)
        DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    if (e->domain)
        native_close(c->job);
    free(cwd);
    free(program);
    free(command);
    free(environment);
    ReleaseSRWLockExclusive(&spawn_lock);
}

static void child_poll(Child *c, Error *e)
{
    if (c->exited)
        return;
    DWORD rc = WaitForSingleObject(c->handle, 0);
    if (rc == WAIT_OBJECT_0) {
        DWORD code;
        if (!GetExitCodeProcess(c->handle, &code))
            *e = native_error(GetLastError());
        else {
            c->exited = true;
            c->kind = 1;
            c->code = code; /* Exit code 259 is valid after the handle is signalled. */
        }
    } else if (rc == WAIT_FAILED)
        *e = native_error(GetLastError());
}

static void child_signal(Child *c, bool force, Error *e)
{
    if (c->exited && !c->group)
        return;
    BOOL ok = c->group ? TerminateJobObject(c->job, force ? 137 : 143)
                       : TerminateProcess(c->handle, force ? 137 : 143);
    if (!ok) {
        DWORD code = GetLastError();
        if (!c->group)
            child_poll(c, e);
        if ((c->group || !c->exited) && !e->domain)
            *e = native_error(code);
    }
}

static void child_close(Child *c, Error *e)
{
    if (c->job && !CloseHandle(c->job))
        *e = native_error(GetLastError());
    if (!CloseHandle(c->handle) && !e->domain)
        *e = native_error(GetLastError());
}

static int64_t pipe_transfer(Pipe *p, unsigned char *data, size_t n, bool writing, Error *e)
{
    DWORD moved = 0;
    BOOL ok = writing ? WriteFile(p->handle, data, (DWORD)n, &moved, NULL)
                      : ReadFile(p->handle, data, (DWORD)n, &moved, NULL);
    if (ok)
        return writing && !moved ? -1 : (int64_t)moved;
    DWORD code = GetLastError();
    if (!writing && (code == ERROR_BROKEN_PIPE || code == ERROR_PIPE_NOT_CONNECTED))
        return 0;
    if (!writing && code == ERROR_NO_DATA)
        return -1;
    *e = native_error(code);
    return 0;
}

static void pipe_pause(Pipe **pipes, size_t n, int milliseconds)
{
    (void)pipes;
    (void)n;
    Sleep((DWORD)(milliseconds < 10 ? milliseconds : 10));
}

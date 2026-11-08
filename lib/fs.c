/* Native layouts stay here; traversal, paths, temporary files and I/O stay in Shen. */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0600 /* Strict UTF-16 conversion requires Windows Vista or later. */
#endif
#include "shen.h"
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#define EXPORT __declspec(dllexport)
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#define EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
    int domain;
    int64_t code;
    const char *message;
} Error;
typedef struct {
    char *text;
#ifdef _WIN32
    wchar_t *wide;
#endif
} Path;

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

static void free_path(Path *p)
{
    free(p->text);
#ifdef _WIN32
    free(p->wide);
#endif
}

/* No managed allocation while a string address is borrowed. */
static bool read_path(shen_vm *vm, shen_value value, Path *p, Error *e)
{
    size_t n;
    const char *text = shen_string_bytes(vm, value, &n);
    if (!text || !n || n > 1048576 || memchr(text, 0, n)) {
        *e = (Error){3, 0, "path must be a nonempty NUL-free string of at most 1 MiB"};
        return false;
    }
    p->text = malloc(n + 1);
    if (!p->text) {
        *e = (Error){3, 0, "cannot allocate path"};
        return false;
    }
    memcpy(p->text, text, n);
    p->text[n] = 0;
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, p->text, -1, NULL, 0);
    if (!count) {
        *e = native_error(GetLastError());
        return false;
    }
    p->wide = malloc((size_t)count * sizeof *p->wide);
    if (!p->wide) {
        *e = (Error){3, 0, "cannot allocate path"};
        return false;
    }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, p->text, -1, p->wide, count)) {
        *e = native_error(GetLastError());
        return false;
    }
#endif
    return true;
}

/* Private reply: domain (0 success, 1 POSIX, 2 Win32, 3 library, 4 limit), code, message, payload. */
static shen_value reply(shen_vm *vm, Error e, shen_value payload)
{
    char message[1024] = "";
    if (e.message)
        snprintf(message, sizeof message, "%s", e.message);
    else if (e.domain == 1)
        snprintf(message, sizeof message, "%s", strerror((int)e.code));
#ifdef _WIN32
    else if (e.domain == 2) {
        wchar_t wide[512];
        DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
                                 (DWORD)e.code, 0, wide, 512, NULL);
        if (!n ||
            !WideCharToMultiByte(CP_UTF8, 0, wide, (int)n, message, sizeof message - 1, NULL, NULL))
            snprintf(message, sizeof message, "Windows filesystem error %lld", (long long)e.code);
    }
#endif
    shen_root(vm, &payload);
    shen_value out = shen_make_vector(vm, 4, SHEN_NIL);
    if (out == SHEN_ERROR) {
        shen_unroot(vm, 1);
        return out;
    }
    shen_root(vm, &out);
    shen_vector_set(vm, out, 0, shen_make_fixnum(e.domain));
    shen_vector_set(vm, out, 1, shen_make_fixnum(e.code));
    shen_vector_set(vm, out, 3, payload);
    shen_value text = shen_make_string(vm, message, strlen(message));
    if (text != SHEN_ERROR)
        shen_vector_set(vm, out, 2, text);
    shen_unroot(vm, 2);
    return text == SHEN_ERROR ? SHEN_ERROR : out;
}

EXPORT int shen_fs_abi(void)
{
    return 1;
}

EXPORT shen_value shen_fs_resolve(shen_vm *vm, shen_value *args)
{
    Error e = {0};
    char *text = NULL;
    Path p = {0};
    if (!read_path(vm, args[0], &p, &e)) {
        free_path(&p);
        return reply(vm, e, SHEN_NIL);
    }
    void *token = shen_release(vm);
#ifdef _WIN32
    DWORD size = GetFullPathNameW(p.wide, 0, NULL, NULL);
    wchar_t *wide = size && size <= 1048576 ? malloc((size_t)size * sizeof *wide) : NULL;
    if (!size)
        e = native_error(GetLastError());
    else if (size > 1048576)
        e = (Error){4, 0, "resolved path exceeds 1 MiB"};
    else if (!wide)
        e = (Error){3, 0, "cannot allocate current directory"};
    else {
        DWORD n = GetFullPathNameW(p.wide, size, wide, NULL);
        if (!n)
            e = native_error(GetLastError());
        else if (n >= size)
            e = (Error){3, 0, "current directory changed while resolving a path"};
        else {
            int bytes =
                WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, NULL, 0, NULL, NULL);
            if (!bytes)
                e = native_error(GetLastError());
            else {
                text = malloc((size_t)bytes);
                if (!text)
                    e = (Error){3, 0, "cannot allocate current directory"};
                else if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, text, bytes,
                                              NULL, NULL))
                    e = native_error(GetLastError());
            }
        }
    }
    free(wide);
#else
    if (p.text[0] == '/') {
        text = p.text;
        p.text = NULL;
    } else {
        char *cwd = NULL;
        for (size_t capacity = 4096;; capacity *= 2) {
            cwd = malloc(capacity);
            if (!cwd) {
                e = (Error){3, 0, "cannot allocate current directory"};
                break;
            }
            if (getcwd(cwd, capacity))
                break;
            int code = errno;
            free(cwd);
            cwd = NULL;
            if (code != ERANGE) {
                e = native_error(code);
                break;
            }
            if (capacity == 1048576) {
                e = (Error){4, 0, "current directory exceeds 1 MiB"};
                break;
            }
        }
        if (cwd) {
            size_t a = strlen(cwd), b = strlen(p.text);
            bool slash = a && cwd[a - 1] != '/';
            if (a + b + (size_t)slash > 1048576)
                e = (Error){4, 0, "resolved path exceeds 1 MiB"};
            else {
                text = malloc(a + b + (size_t)slash + 1);
                if (!text)
                    e = (Error){3, 0, "cannot allocate resolved path"};
                else
                    snprintf(text, a + b + (size_t)slash + 1, "%s%s%s", cwd, slash ? "/" : "",
                             p.text);
            }
            free(cwd);
        }
    }
#endif
    shen_acquire(vm, token);
    free_path(&p);
    shen_value payload = e.domain ? SHEN_NIL : shen_make_string(vm, text, strlen(text));
    free(text);
    return payload == SHEN_ERROR ? SHEN_ERROR : reply(vm, e, payload);
}

#ifdef _WIN32
static void file_time(FILETIME t, int64_t *seconds, int64_t *nanos)
{
    uint64_t ticks = ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
    *seconds = (int64_t)(ticks / 10000000) - INT64_C(11644473600);
    *nanos = (int64_t)(ticks % 10000000) * 100;
}
#endif

EXPORT shen_value shen_fs_stat(shen_vm *vm, shen_value *args)
{
    Path p = {0};
    Error e = {0};
    int64_t fields[6] = {0};
    if (args[1] != SHEN_TRUE && args[1] != SHEN_FALSE)
        return shen_raise(vm, "fs: invalid follow flag");
    bool follow = args[1] == SHEN_TRUE;
    if (read_path(vm, args[0], &p, &e)) {
        void *token = shen_release(vm);
#ifdef _WIN32
        DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
        HANDLE h = CreateFileW(p.wide, FILE_READ_ATTRIBUTES,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                               OPEN_EXISTING, flags, NULL);
        if (h == INVALID_HANDLE_VALUE)
            e = native_error(GetLastError());
        else {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(h, &info))
                e = native_error(GetLastError());
            else {
                if (!follow && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
                    fields[0] = 2;
                else if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                    fields[0] = 1;
                else
                    fields[0] = 0;
                uint64_t size = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
                if (size > (UINT64_C(1) << 61) - 1)
                    e = (Error){3, 0, "file size exceeds fixnum range"};
                else
                    fields[1] = (int64_t)size;
                file_time(info.ftLastWriteTime, &fields[2], &fields[3]);
                file_time(info.ftLastAccessTime, &fields[4], &fields[5]);
            }
            if (!CloseHandle(h) && !e.domain)
                e = native_error(GetLastError());
        }
#else
        struct stat info;
        if ((follow ? stat(p.text, &info) : lstat(p.text, &info)) < 0)
            e = native_error(errno);
        else {
            if (S_ISREG(info.st_mode))
                fields[0] = 0;
            else if (S_ISDIR(info.st_mode))
                fields[0] = 1;
            else if (S_ISLNK(info.st_mode))
                fields[0] = 2;
            else
                fields[0] = 3;
            fields[1] = info.st_size;
#ifdef __APPLE__
            fields[2] = info.st_mtimespec.tv_sec;
            fields[3] = info.st_mtimespec.tv_nsec;
            fields[4] = info.st_atimespec.tv_sec;
            fields[5] = info.st_atimespec.tv_nsec;
#else
            fields[2] = info.st_mtim.tv_sec;
            fields[3] = info.st_mtim.tv_nsec;
            fields[4] = info.st_atim.tv_sec;
            fields[5] = info.st_atim.tv_nsec;
#endif
        }
#endif
        shen_acquire(vm, token);
    }
    free_path(&p);
    for (int i = 0; i < 6 && !e.domain; i++)
        if (!shen_fits_fixnum(fields[i]) || (i == 1 && fields[i] < 0))
            e = (Error){3, 0, "metadata exceeds fixnum range"};
    if (e.domain)
        return reply(vm, e, SHEN_NIL);
    shen_value out = shen_make_vector(vm, 6, SHEN_NIL);
    if (out == SHEN_ERROR)
        return out;
    for (int i = 0; i < 6; i++)
        shen_vector_set(vm, out, i, shen_make_fixnum(fields[i]));
    return reply(vm, e, out);
}

typedef struct {
    char **names;
    size_t used, capacity, bytes, entries, byte_limit;
    Error error;
} Listing;

static bool add_name(Listing *l, const char *name)
{
    if (!strcmp(name, ".") || !strcmp(name, ".."))
        return true;
    size_t n = strlen(name);
    if (l->used == l->entries) {
        l->error = (Error){4, 0, "directory entry limit exceeded"};
        return false;
    }
    if (n > l->byte_limit - l->bytes) {
        l->error = (Error){4, 0, "directory name-byte limit exceeded"};
        return false;
    }
    if (l->used == l->capacity) {
        size_t next = l->capacity ? l->capacity * 2 : 32;
        if (next > l->entries)
            next = l->entries;
        void *p = realloc(l->names, next * sizeof *l->names);
        if (!p) {
            l->error = (Error){3, 0, "cannot allocate directory entries"};
            return false;
        }
        l->names = p;
        l->capacity = next;
    }
    char *copy = malloc(n + 1);
    if (!copy) {
        l->error = (Error){3, 0, "cannot allocate directory name"};
        return false;
    }
    memcpy(copy, name, n + 1);
    l->names[l->used++] = copy;
    l->bytes += n;
    return true;
}

static int compare_names(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

EXPORT shen_value shen_fs_list(shen_vm *vm, shen_value *args)
{
    if (!shen_is_fixnum(args[1]) || !shen_is_fixnum(args[2]) || shen_fixnum(args[1]) < 0 ||
        shen_fixnum(args[1]) > 1000000 || shen_fixnum(args[2]) < 0 ||
        shen_fixnum(args[2]) > 67108864)
        return shen_raise(vm, "fs: invalid directory limits");
    Listing l = {.entries = (size_t)shen_fixnum(args[1]),
                 .byte_limit = (size_t)shen_fixnum(args[2])};
    Path p = {0};
    if (read_path(vm, args[0], &p, &l.error)) {
        void *token = shen_release(vm);
#ifdef _WIN32
        size_t n = wcslen(p.wide);
        wchar_t *pattern = malloc((n + 3) * sizeof *pattern);
        if (!pattern)
            l.error = (Error){3, 0, "cannot allocate directory pattern"};
        else {
            memcpy(pattern, p.wide, n * sizeof *pattern);
            if (pattern[n - 1] != L'/' && pattern[n - 1] != L'\\')
                pattern[n++] = L'\\';
            pattern[n++] = L'*';
            pattern[n] = 0;
            WIN32_FIND_DATAW data;
            HANDLE h = FindFirstFileW(pattern, &data);
            if (h == INVALID_HANDLE_VALUE) {
                DWORD code = GetLastError();
                DWORD attrs = GetFileAttributesW(p.wide);
                if (code != ERROR_FILE_NOT_FOUND || attrs == INVALID_FILE_ATTRIBUTES ||
                    !(attrs & FILE_ATTRIBUTE_DIRECTORY))
                    l.error = native_error(code);
            } else {
                for (;;) {
                    char name[4 * MAX_PATH + 1];
                    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data.cFileName, -1,
                                             name, sizeof name, NULL, NULL)) {
                        l.error = native_error(GetLastError());
                        break;
                    }
                    if (!add_name(&l, name))
                        break;
                    if (!FindNextFileW(h, &data)) {
                        DWORD code = GetLastError();
                        if (code != ERROR_NO_MORE_FILES)
                            l.error = native_error(code);
                        break;
                    }
                }
                if (!FindClose(h) && !l.error.domain)
                    l.error = native_error(GetLastError());
            }
            free(pattern);
        }
#else
        DIR *dir = opendir(p.text);
        if (!dir)
            l.error = native_error(errno);
        else {
            for (;;) {
                errno = 0;
                struct dirent *entry = readdir(dir);
                if (!entry) {
                    if (errno)
                        l.error = native_error(errno);
                    break;
                }
                if (!add_name(&l, entry->d_name))
                    break;
            }
            if (closedir(dir) < 0 && !l.error.domain)
                l.error = native_error(errno);
        }
#endif
        if (l.used > 1)
            qsort(l.names, l.used, sizeof *l.names, compare_names);
        shen_acquire(vm, token);
    }
    free_path(&p);
    shen_value names = SHEN_NIL, name = SHEN_NIL, payload = SHEN_NIL;
    shen_root(vm, &names);
    shen_root(vm, &name);
    shen_root(vm, &payload);
    bool failed = false;
    if (!l.error.domain) {
        for (size_t i = l.used; i > 0; i--) {
            name = shen_make_string(vm, l.names[i - 1], strlen(l.names[i - 1]));
            if (name == SHEN_ERROR) {
                failed = true;
                break;
            }
            names = shen_cons(vm, name, names);
            if (names == SHEN_ERROR) {
                failed = true;
                break;
            }
        }
        if (!failed) {
            payload = shen_make_vector(vm, 2, SHEN_NIL);
            if (payload == SHEN_ERROR)
                failed = true;
            else {
                shen_vector_set(vm, payload, 0, names);
                shen_vector_set(vm, payload, 1, shen_make_fixnum(l.bytes));
            }
        }
    }
    for (size_t i = 0; i < l.used; i++)
        free(l.names[i]);
    free(l.names);
    shen_value out = failed ? SHEN_ERROR : reply(vm, l.error, payload);
    shen_unroot(vm, 3);
    return out;
}

EXPORT shen_value shen_fs_rename(shen_vm *vm, shen_value *args)
{
    if (args[2] != SHEN_TRUE && args[2] != SHEN_FALSE)
        return shen_raise(vm, "fs: invalid replacement flag");
    bool replace = args[2] == SHEN_TRUE;
    Path from = {0}, to = {0};
    Error e = {0};
    if (read_path(vm, args[0], &from, &e) && read_path(vm, args[1], &to, &e)) {
        void *token = shen_release(vm);
#ifdef _WIN32
        if (!MoveFileExW(from.wide, to.wide, replace ? MOVEFILE_REPLACE_EXISTING : 0))
            e = native_error(GetLastError());
#else
        int rc;
        if (replace)
            rc = rename(from.text, to.text);
#ifdef __APPLE__
        else
            rc = renamex_np(from.text, to.text, RENAME_EXCL);
#else
        else
            rc = renameat2(AT_FDCWD, from.text, AT_FDCWD, to.text, RENAME_NOREPLACE);
#endif
        if (rc < 0)
            e = native_error(errno);
#endif
        shen_acquire(vm, token);
    }
    free_path(&from);
    free_path(&to);
    return reply(vm, e, SHEN_NIL);
}

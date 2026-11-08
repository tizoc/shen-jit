/* Independent child program for argv, binary pipes, inheritance and lifecycle tests. */
#define _DEFAULT_SOURCE 1
#ifdef _WIN32
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void pause_ms(unsigned n)
{
#ifdef _WIN32
    Sleep(n);
#else
    usleep(n * 1000);
#endif
}

static void integer(uint64_t n, int bytes)
{
    for (int i = 0; i < bytes; i++, n >>= 8)
        fputc((int)(n & 255), stdout);
}

static unsigned char pattern(size_t at)
{
    return (unsigned char)(at % 251);
}

static void produce(size_t count, FILE *stream, bool inverse)
{
    unsigned char bytes[4096];
    for (size_t at = 0; at < count;) {
        size_t n = count - at < sizeof bytes ? count - at : sizeof bytes;
        for (size_t i = 0; i < n; i++)
            bytes[i] = (unsigned char)(pattern(at + i) ^ (inverse ? 255 : 0));
        if (fwrite(bytes, 1, n, stream) != n)
            exit(31);
        at += n;
    }
    fflush(stream);
}

#ifdef _WIN32
static char *utf8(const wchar_t *value)
{
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
    char *out = n ? malloc((size_t)n) : NULL;
    if (!out || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, out, n, NULL, NULL))
        exit(33);
    return out;
}
#endif

static int run(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    const char *mode = argv[1];
    if (!strcmp(mode, "args")) {
        integer((uint64_t)(argc - 2), 4);
        for (int i = 2; i < argc; i++) {
            size_t n = strlen(argv[i]);
            integer(n, 4);
            fwrite(argv[i], 1, n, stdout);
        }
    } else if (!strcmp(mode, "exit")) {
        return (int)strtoul(argv[2], NULL, 10);
    } else if (!strcmp(mode, "echo") || !strcmp(mode, "fail-filter")) {
        unsigned char bytes[4096];
        size_t n;
        while ((n = fread(bytes, 1, sizeof bytes, stdin))) {
            if (fwrite(bytes, 1, n, stdout) != n)
                return 31;
            fflush(stdout);
        }
        if (!strcmp(mode, "fail-filter"))
            return 17;
    } else if (!strcmp(mode, "duplex")) {
        size_t n = (size_t)strtoull(argv[2], NULL, 10);
        produce(n, stdout, false);
        produce(n, stderr, true);
        unsigned char bytes[4096];
        uint64_t total = 0;
        uint32_t hash = 2166136261u;
        size_t got;
        while ((got = fread(bytes, 1, sizeof bytes, stdin))) {
            total += got;
            for (size_t i = 0; i < got; i++)
                hash = (hash ^ bytes[i]) * 16777619u;
        }
        integer(total, 8);
        integer(hash, 4);
    } else if (!strcmp(mode, "flood")) {
        produce((size_t)strtoull(argv[2], NULL, 10), stdout, false);
    } else if (!strcmp(mode, "hold") || !strcmp(mode, "ignore-term") ||
               !strcmp(mode, "ready-ignore-term")) {
#ifndef _WIN32
        if (strstr(mode, "ignore-term"))
            signal(SIGTERM, SIG_IGN);
#endif
        if (!strcmp(mode, "ready-ignore-term")) {
            fputc('r', stderr);
            fflush(stderr);
        }
        pause_ms((unsigned)strtoul(argv[2], NULL, 10));
    } else if (!strcmp(mode, "descendant") || !strcmp(mode, "descendant-ignore-term")) {
#ifdef _WIN32
        wchar_t path[32768], command[32768];
        GetModuleFileNameW(NULL, path, 32768);
        swprintf(command, 32768, L"\"%ls\" hold 10000", path);
        STARTUPINFOW startup = {0};
        startup.cb = sizeof startup;
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        PROCESS_INFORMATION info;
        if (!CreateProcessW(path, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &info))
            return 34;
        integer(info.dwProcessId, 4);
        CloseHandle(info.hProcess);
        CloseHandle(info.hThread);
#else
        pid_t pid = fork();
        if (pid < 0)
            return 34;
        if (!pid) {
            if (!strcmp(mode, "descendant-ignore-term"))
                signal(SIGTERM, SIG_IGN);
            pause_ms(10000);
            _exit(0);
        }
        integer((uint64_t)pid, 4);
#endif
    } else if (!strcmp(mode, "handle")) {
#ifdef _WIN32
        HANDLE h = (HANDLE)(uintptr_t)strtoull(argv[2], NULL, 10);
        DWORD flags;
        integer(GetHandleInformation(h, &flags) != 0, 4);
#endif
    } else if (!strcmp(mode, "signals")) {
#ifndef _WIN32
        sigset_t mask;
        sigprocmask(SIG_SETMASK, NULL, &mask);
        struct sigaction action;
        sigaction(SIGPIPE, NULL, &action);
        integer(sigismember(&mask, SIGINT), 4);
        integer(action.sa_handler == SIG_DFL, 4);
#endif
    } else if (!strcmp(mode, "cwd")) {
#ifdef _WIN32
        wchar_t wide[32768];
        GetCurrentDirectoryW(32768, wide);
        char *text = utf8(wide);
#else
        char *text = getcwd(NULL, 0);
#endif
        if (!text)
            return 35;
        fwrite(text, 1, strlen(text), stdout);
        free(text);
    } else if (!strcmp(mode, "environment")) {
#ifdef _WIN32
        int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, NULL, 0);
        wchar_t *name = malloc((size_t)n * sizeof *name);
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, name, n);
        const wchar_t *value = _wgetenv(name);
        char *text = value ? utf8(value) : NULL;
        free(name);
#else
        char *text = getenv(argv[2]);
#endif
        if (text)
            fwrite(text, 1, strlen(text), stdout);
#ifdef _WIN32
        free(text);
#endif
    } else if (!strcmp(mode, "has-file")) {
        bool found = false;
#ifndef _WIN32
        for (int fd = 3; fd < 2048; fd++) {
            char name[4096];
#ifdef __APPLE__
            if (fcntl(fd, F_GETPATH, name) == 0 && !strcmp(name, argv[2]))
                found = true;
#else
            char link[64];
            snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
            ssize_t n = readlink(link, name, sizeof name - 1);
            if (n >= 0) {
                name[n] = 0;
                if (!strcmp(name, argv[2]))
                    found = true;
            }
#endif
        }
#endif
        integer(found, 4);
    } else if (!strcmp(mode, "sockets")) {
        int found = 0;
#ifndef _WIN32
        for (int fd = 3; fd < 2048; fd++) {
            struct stat info;
            if (!fstat(fd, &info) && S_ISSOCK(info.st_mode))
                found++;
        }
#endif
        integer(found, 4);
    } else if (!strcmp(mode, "slow-input")) {
        int c;
        uint64_t n = 0;
        while ((c = fgetc(stdin)) != EOF) {
            (void)c;
            n++;
            pause_ms(2);
        }
        integer(n, 8);
    } else if (!strcmp(mode, "progress")) {
        size_t total = (size_t)strtoull(argv[2], NULL, 10);
        for (size_t at = 0; at < total; at += 4096) {
            produce(total - at < 4096 ? total - at : 4096, stdout, false);
            FILE *marker = fopen(argv[3], "wb");
            if (!marker)
                return 36;
            fprintf(marker, "%zu", at + 4096);
            fclose(marker);
        }
    } else
        return 3;
    return 0;
}

#ifdef _WIN32
int wmain(int argc, wchar_t **wide)
{
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
    char **args = calloc((size_t)argc + 1, sizeof *args);
    for (int i = 0; i < argc; i++)
        args[i] = utf8(wide[i]);
    int result = run(argc, args);
    for (int i = 0; i < argc; i++)
        free(args[i]);
    free(args);
    return result;
}
#else
int main(int argc, char **argv)
{
    return run(argc, argv);
}
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "win32.h"

#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

/* The narrow CRT argument list uses the active ANSI code page and loses names
   before our UTF-8 I/O can see them. Convert the wide entry point's arguments. */
void win_arguments_free(int argc, char **argv)
{
    if (!argv)
        return;
    for (int i = 0; i < argc; i++)
        free(argv[i]);
    free(argv);
}

char **win_arguments(int argc, wchar_t **wide)
{
    char **argv = calloc((size_t)argc + 1, sizeof *argv);
    if (!argv)
        return NULL;
    for (int i = 0; i < argc; i++) {
        int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[i], -1, NULL, 0, NULL, NULL);
        if (!n || !(argv[i] = malloc((size_t)n)) ||
            !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[i], -1, argv[i], n, NULL, NULL)) {
            win_arguments_free(argc, argv);
            return NULL;
        }
    }
    return argv;
}

/* Windows opens the standard streams in text mode, which would turn \n into
   \r\n. Byte streams see the same bytes as elsewhere. */
static LARGE_INTEGER started, ticks_per_second;

void win_startup(void)
{
    QueryPerformanceFrequency(&ticks_per_second);
    QueryPerformanceCounter(&started);
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
}

/* For get-time: clock() and gettimeofday tick once a millisecond there, too coarse to
   time anything short. clock() is elapsed time there too, not processor time, whose
   counter ticks only every 15.6 ms. */
double win_run_seconds(void)
{
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (double)(now.QuadPart - started.QuadPart) / (double)ticks_per_second.QuadPart;
}

double win_unix_seconds(void)
{
    FILETIME t;
    GetSystemTimePreciseAsFileTime(&t);
    ULARGE_INTEGER u = {.LowPart = t.dwLowDateTime, .HighPart = t.dwHighDateTime};
    return (double)(u.QuadPart - 116444736000000000ULL) * 1e-7;
}

bool win_executable(char *path, size_t size)
{
    DWORD n = GetModuleFileNameA(NULL, path, (DWORD)size);
    return n > 0 && n < size;
}

void *win_reserve(size_t bytes) { return VirtualAlloc(NULL, bytes, MEM_RESERVE, PAGE_NOACCESS); }

bool win_commit(void *at, size_t bytes) { return VirtualAlloc(at, bytes, MEM_COMMIT, PAGE_READWRITE) != NULL; }

void win_release(void *at) { VirtualFree(at, 0, MEM_RELEASE); }

/* The handler runs on a thread of its own, unlike a signal's. As a signal
   ends select elsewhere, it ends the main thread's read here, and only a read:
   cancelling a write would lose what was being written. */
static void (*interrupt_handler)(int);
static HANDLE main_thread;
static volatile LONG main_reading;

static BOOL WINAPI on_console_event(DWORD event)
{
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT)
        return FALSE;
    interrupt_handler(0);
    if (main_reading)
        CancelSynchronousIo(main_thread);
    return TRUE;
}

void win_catch_interrupts(void (*handler)(int))
{
    interrupt_handler = handler;
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &main_thread, 0, FALSE,
                    DUPLICATE_SAME_ACCESS);
    SetConsoleCtrlHandler(on_console_event, TRUE);
}

long win_read_input(unsigned char *into, size_t size)
{
    bool on_main = main_thread && GetThreadId(main_thread) == GetCurrentThreadId();
    DWORD n = 0;
    if (on_main)
        main_reading = 1;
    BOOL ok = ReadFile(GetStdHandle(STD_INPUT_HANDLE), into, (DWORD)size, &n, NULL);
    DWORD error = ok ? 0 : GetLastError();
    if (on_main)
        main_reading = 0;
    if (error == ERROR_OPERATION_ABORTED)
        return -1;
    return ok ? (long)n : 0; /* a closed pipe is the end of the input */
}

void win_sleep_briefly(void) { Sleep(10); }

void *win_library_open(const char *file) { return file ? LoadLibraryA(file) : GetModuleHandleA(NULL); }

void *win_library_find(void *library, const char *name) { return (void *)GetProcAddress(library, name); }

int win_last_error(void) { return (int)GetLastError(); }

bool win_replace(const char *from, const char *to) { return MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING) != 0; }

#endif

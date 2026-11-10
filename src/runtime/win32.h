/* What Windows does differently, apart so that
   <windows.h>, whose names clash with the runtime's, stays in win32.c. */
#ifndef WIN32_H
#define WIN32_H
#ifdef _WIN32

#include <stdbool.h>
#include <stddef.h>

void win_startup(void);
char **win_arguments(int argc, wchar_t **wide);
void win_arguments_free(int argc, char **argv);
double win_run_seconds(void);
double win_unix_seconds(void);
bool win_executable(char *path, size_t size);
void *win_reserve(size_t bytes);
bool win_commit(void *at, size_t bytes);
void win_release(void *at);
void win_catch_interrupts(void (*handler)(int));
/* Bytes read from standard input; 0 at its end; -1 when a Ctrl-C ended the wait. */
long win_read_input(unsigned char *into, size_t size);
void win_sleep_briefly(void);
/* A library, or with NULL what the process started from; a function in one; GetLastError. */
void *win_library_open(const char *file);
void *win_library_find(void *library, const char *name);
int win_last_error(void);
/* Moves a file over another, which rename refuses to do there. */
bool win_replace(const char *from, const char *to);

#endif
#endif

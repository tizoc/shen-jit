/* Persistent runtime files must not leak into a spawned child. */
#ifndef SJ_FILE_H
#define SJ_FILE_H
#include <stdio.h>
#include <string.h>
#include <errno.h>

static inline FILE *sj_fopen(const char *path, const char *mode)
{
#ifdef __linux__
    /* glibc's e opens with O_CLOEXEC atomically, including while another thread spawns. */
    char flags[16];
    size_t n = strlen(mode);
    if (n + 2 > sizeof flags) {
        errno = EINVAL;
        return NULL;
    }
    memcpy(flags, mode, n);
    flags[n] = 'e';
    flags[n + 1] = 0;
    return fopen(path, flags);
#else
    /* The subprocess adapter whitelists inherited handles on Windows and macOS. */
    return fopen(path, mode);
#endif
}
#endif

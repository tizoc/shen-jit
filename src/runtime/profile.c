/* The sampling profiler. With
   SHEN_JIT_PROFILE set, a SIGPROF timer records the instruction address
   at every millisecond of CPU time, or as often as the system delivers it. At exit each address is named, by the
   JIT's code ranges for compiled Shen functions or by the symbol table for
   the runtime's C functions, and a flat profile goes to stderr. Samples
   gather where the process comes back from the kernel, so C functions that
   enter it (mmap, the JIT's W^X switches) show more than their share. */
#ifdef _WIN32
#include "vm.h"

#include <stdio.h>

bool profile_start(void)
{
    fprintf(stderr, "shen-jit: SHEN_JIT_PROFILE is not available on Windows\n");
    return false;
}
bool profile_running(void) { return false; }
void profile_code(const void *start, size_t size, const char *name, size_t len) {}
#else
#define _GNU_SOURCE /* REG_RIP and dladdr on Linux */
#include "vm.h"

#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#ifdef __APPLE__
#include <sys/ucontext.h>
#else
#include <ucontext.h>
#endif

enum { MAX_SAMPLES = 1 << 20, PROFILE_LINES = 30 };

static uintptr_t *samples;
static volatile size_t nsamples, dropped;

typedef struct {
    uintptr_t start, end;
    char *name;
} Range;

static Range *ranges;
static size_t nranges, ranges_cap;

static uintptr_t pc_of(void *context)
{
    ucontext_t *uc = context;
#if defined(__APPLE__) && defined(__aarch64__)
    return (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
#elif defined(__APPLE__) && defined(__x86_64__)
    return (uintptr_t)uc->uc_mcontext->__ss.__rip;
#elif defined(__linux__) && defined(__x86_64__)
    return (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__linux__) && defined(__aarch64__)
    return (uintptr_t)uc->uc_mcontext.pc;
#else
    (void)uc;
    return 0;
#endif
}

/* Only stores the address: nothing here may allocate or touch the VM. */
static void on_sample(int sig, siginfo_t *info, void *context)
{
    if (nsamples < MAX_SAMPLES)
        samples[nsamples++] = pc_of(context);
    else
        dropped++;
}

void profile_code(const void *start, size_t size, const char *name, size_t len)
{
    if (!samples)
        return;
    if (nranges == ranges_cap) {
        size_t cap = ranges_cap ? 2 * ranges_cap : 1024;
        Range *r = realloc(ranges, cap * sizeof *r);
        if (!r)
            return;
        ranges = r;
        ranges_cap = cap;
    }
    char *copy = malloc(len + 1);
    if (!copy)
        return;
    memcpy(copy, name, len);
    copy[len] = 0;
    ranges[nranges++] = (Range){(uintptr_t)start, (uintptr_t)start + size, copy};
}

typedef struct {
    const char *name;
    bool c;
    size_t count;
} Entry;

static int by_address(const void *a, const void *b)
{
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return (x > y) - (x < y);
}

static int by_name(const void *a, const void *b)
{
    const Entry *x = a, *y = b;
    return x->c != y->c ? x->c - y->c : strcmp(x->name, y->name);
}

static int by_count(const void *a, const void *b)
{
    size_t x = ((const Entry *)a)->count, y = ((const Entry *)b)->count;
    return (x < y) - (x > y);
}

/* Native code is not freed while the profiler runs (jit.c), so the ranges
   don't overlap. */
static Entry name_of(uintptr_t pc)
{
    size_t lo = 0, hi = nranges;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (ranges[mid].start <= pc)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo > 0 && pc < ranges[lo - 1].end)
        return (Entry){ranges[lo - 1].name, false, 0};
    Dl_info info;
    if (dladdr((void *)pc, &info) && info.dli_sname)
        return (Entry){info.dli_sname, true, 0};
    return (Entry){"(unnamed code)", true, 0};
}

static void report(void)
{
    struct itimerval off = {{0, 0}, {0, 0}};
    setitimer(ITIMER_PROF, &off, NULL);
    size_t n = nsamples;
    qsort(samples, n, sizeof *samples, by_address);
    qsort(ranges, nranges, sizeof *ranges, by_address); /* start comes first */
    Entry *e = malloc((n ? n : 1) * sizeof *e);
    if (!e)
        return;
    size_t m = 0;
    for (size_t i = 0; i < n;) { /* one lookup per distinct address */
        size_t j = i;
        while (j < n && samples[j] == samples[i])
            j++;
        e[m] = name_of(samples[i]);
        e[m++].count = j - i;
        i = j;
    }
    qsort(e, m, sizeof *e, by_name);
    size_t k = 0;
    for (size_t i = 0; i < m; i++) {
        if (k && e[k - 1].c == e[i].c && strcmp(e[k - 1].name, e[i].name) == 0)
            e[k - 1].count += e[i].count;
        else
            e[k++] = e[i];
    }
    qsort(e, k, sizeof *e, by_count);
    fprintf(stderr, "shen-jit: profile of %zu samples over %.2f s of CPU time", n,
            (double)clock() / CLOCKS_PER_SEC);
    if (dropped)
        fprintf(stderr, " (%zu more not recorded)", (size_t)dropped);
    fprintf(stderr, "\n");
    for (size_t i = 0; i < k && i < PROFILE_LINES; i++)
        fprintf(stderr, "%6.1f%% %7zu  %s%s\n", 100.0 * (double)e[i].count / (double)n, e[i].count,
                e[i].name, e[i].c ? " (C)" : "");
    free(e);
}

bool profile_running(void) { return samples != NULL; }

bool profile_start(void)
{
    samples = malloc(MAX_SAMPLES * sizeof *samples);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sample;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    struct itimerval every = {{0, 1000}, {0, 1000}};
    if (!samples || sigaction(SIGPROF, &sa, NULL) != 0 || setitimer(ITIMER_PROF, &every, NULL) != 0) {
        free(samples);
        samples = NULL;
        return false;
    }
    thread_at_exit(report);
    return true;
}
#endif

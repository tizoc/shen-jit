/* Threads: real ones, of which one runs at a time, holding a global lock.

   Each has its own guest stack, handlers and C roots. The running thread's are in the
   VM's fields, where emitted code reads them, so that code runs the same with
   or without threads; the others' wait in their Thread. It costs nothing until
   the first (thread F).

   A thread gives up the lock at a frame or loop check, when the ticker asks it
   to because another is waiting, and while it waits for input. Those are places
   where everything a collection needs is published, since the next thread may
   collect. Waiting threads are served in order, so that one that yields cannot
   take the lock straight back. */
#define _DEFAULT_SOURCE /* nanosleep and pthread_attr_setstacksize under -std=c11 */
#include "jit.h"
#include "ops.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef _WIN32
#include <sys/resource.h>
#endif

enum {
    THREAD_STACK_WORDS = 1 << 13,        /* grows as the main thread's does */
    C_STACK_MARGIN = 256 * 1024,         /* for what runs past the check on a nested call */
    TICK_NANOSECONDS = 10 * 1000 * 1000
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
/* A waiter sleeps on its ticket's slot, so that a release wakes the next thread and not the
   whole queue, which took all the machine's cores at 1000 threads waiting on sockets. */
#define TURN PTHREAD_COND_INITIALIZER
static pthread_cond_t turn[16] = {TURN, TURN, TURN, TURN, TURN, TURN, TURN, TURN,
                                  TURN, TURN, TURN, TURN, TURN, TURN, TURN, TURN};
#undef TURN
static uint64_t next_ticket, serving; /* serving is the holder's; the rest wait */
static VM *ticking;

static void acquire(void)
{
    pthread_mutex_lock(&lock);
    uint64_t ticket = next_ticket++;
    while (ticket != serving)
        pthread_cond_wait(&turn[ticket % 16], &lock);
    pthread_mutex_unlock(&lock);
}

static void release(void)
{
    pthread_mutex_lock(&lock);
    serving++;
    pthread_cond_broadcast(&turn[serving % 16]);
    pthread_mutex_unlock(&lock);
}

static bool others_waiting(void)
{
    pthread_mutex_lock(&lock);
    bool waiting = next_ticket - serving > 1;
    pthread_mutex_unlock(&lock);
    return waiting;
}

/* Where nested calls stop on a C stack of this size, seen from near its base. */
static uintptr_t c_stack_limit(size_t bytes)
{
    char here;
    return (uintptr_t)&here - bytes + C_STACK_MARGIN;
}

/* The main thread's stack: what the system gives it, with the linker's choice on
   Windows (Makefile). */
void thread_note_main_stack(VM *vm)
{
    size_t bytes = C_STACK_BYTES;
#ifndef _WIN32
    struct rlimit limit;
    if (getrlimit(RLIMIT_STACK, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY)
        bytes = (size_t)limit.rlim_cur;
#endif
    vm->c_stack_limit = bytes > C_STACK_MARGIN ? c_stack_limit(bytes) : 0;
}

void thread_note_worker_stack(VM *vm)
{
    vm->c_stack_limit = c_stack_limit(C_STACK_BYTES);
}

Thread *thread_leave(VM *vm)
{
    Thread *t = vm->thread;
    t->stack = vm->stack;
    t->stack_words = vm->stack_words;
    t->fp = vm->fp;
    t->top = vm->top;
    t->stack_limit = vm->stack_limit;
    t->handlers = vm->handlers;
    t->nhandlers = vm->nhandlers;
    t->handlers_cap = vm->handlers_cap;
    t->trace_floor = vm->trace_floor;
    t->site = vm->site;
    t->croots = vm->croots;
    t->ncroots = vm->ncroots;
    t->croots_cap = vm->croots_cap;
    t->foreign_error = vm->foreign_error;
    t->foreign_c_error = vm->foreign_c_error;
    t->exception = vm->exception; /* C may raise, give up the lock and then return the error */
    t->trace = vm->trace;
    release();
    return t;
}

void thread_enter(Thread *t)
{
    acquire();
    VM *vm = t->vm;
    vm->thread = t;
    vm->stack = t->stack;
    vm->stack_words = t->stack_words;
    vm->fp = t->fp;
    vm->top = t->top;
    vm->handlers = t->handlers;
    vm->nhandlers = t->nhandlers;
    vm->handlers_cap = t->handlers_cap;
    vm->trace_floor = t->trace_floor;
    vm->site = t->site;
    vm->c_stack_limit = t->c_stack_limit;
    vm->croots = t->croots;
    vm->ncroots = t->ncroots;
    vm->croots_cap = t->croots_cap;
    vm->foreign_error = t->foreign_error;
    vm->foreign_c_error = t->foreign_c_error;
    vm->exception = t->exception;
    vm->trace = t->trace;
    vm_set_limit(vm, t->stack_limit);
}

void thread_yield(VM *vm)
{
    if (others_waiting())
        thread_enter(thread_leave(vm));
}

/* The ticker asked: clear the request, whose limit a thread resuming would
   otherwise keep, and let another run. A Ctrl-C that came meanwhile stays. */
void thread_preempted(VM *vm)
{
    int asked = PREEMPT;
    __atomic_compare_exchange_n(&vm->interrupted, &asked, 0, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    vm_set_limit(vm, vm->stack_limit);
    thread_yield(vm);
}

/* As a Ctrl-C does (prims.c): the request, then the limit, so that a thread
   setting the limit sees the request. Loops test the request and frames the
   limit. */
static void *ticker(void *unused)
{
    (void)unused;
    for (;;) {
        struct timespec wait = {0, TICK_NANOSECONDS};
        nanosleep(&wait, NULL);
        pthread_mutex_lock(&lock);
        if (ticking && next_ticket - serving > 1) {
            int none = 0;
            __atomic_compare_exchange_n(&ticking->interrupted, &none, PREEMPT, false, __ATOMIC_SEQ_CST,
                                        __ATOMIC_SEQ_CST);
            ticking->check_limit = NULL;
        }
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

/* With SIGINT blocked: a Ctrl-C has to reach the main thread, to end its wait for
   input, and threads inherit the mask. */
static bool start_detached(void *(*run)(void *), void *arg)
{
    pthread_attr_t attr;
    pthread_t id;
    if (pthread_attr_init(&attr) != 0)
        return false;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, C_STACK_BYTES);
#ifdef _WIN32
    bool ok = pthread_create(&id, &attr, run, arg) == 0; /* Ctrl-C has a thread of its own there */
#else
    sigset_t block, mask;
    sigemptyset(&block);
    sigaddset(&block, SIGINT);
    pthread_sigmask(SIG_BLOCK, &block, &mask);
    bool ok = pthread_create(&id, &attr, run, arg) == 0;
    pthread_sigmask(SIG_SETMASK, &mask, NULL);
#endif
    pthread_attr_destroy(&attr);
    return ok;
}

static void *thread_main(void *arg)
{
    Thread *t = arg;
    VM *vm = t->vm;
    t->c_stack_limit = c_stack_limit(C_STACK_BYTES);
    thread_enter(t);
    V thunk = t->thunk;
    t->thunk = V_NIL;
    if (jit_call(vm, thunk, 0, NULL) == V_CLEARED)
        sj_report(vm, "thread");
    fflush(stdout);
    for (Thread **p = &vm->threads; *p; p = &(*p)->next)
        if (*p == t) {
            *p = t->next;
            break;
        }
    free(vm->stack);
    free(vm->handlers);
    free(vm->croots);
    free(t);
    vm->thread = NULL; /* the next to enter sets every field */
    release();
    return NULL;
}

/* The first thread: from now on there is a lock, which this thread holds, and
   all code needs its loop checks, which it was compiled without unless the
   REPL catches Ctrl-C. */
static bool first_thread(VM *vm)
{
    static bool ticker_started;
    Thread *main = calloc(1, sizeof *main);
    if (!main || (!ticker_started && !start_detached(ticker, NULL))) {
        free(main);
        return false;
    }
    ticker_started = true;
    main->vm = vm;
    main->main = true;
    main->thunk = main->exception = main->trace = V_NIL;
    main->c_stack_limit = vm->c_stack_limit;
    vm->threads = vm->thread = main;
    pthread_mutex_lock(&lock);
    next_ticket = 1;
    serving = 0;
    ticking = vm;
    pthread_mutex_unlock(&lock);
    if (!vm->interruptible) {
        vm->interruptible = true;
        jit_recompile(vm);
    }
    return true;
}

V thread_start(VM *vm)
{
    if (vm->worker_owner || vm->worker_scope)
        return sj_raise(vm, "worker: legacy threads cannot run inside a worker scope");
    if (!is_proc(vm->args[0]))
        return sj_raise_value(vm, "thread: ~S is not a function", vm->args[0]);
    if (!vm->threads && !first_thread(vm))
        return sj_raise(vm, "thread: cannot start a thread");
    Thread *t = calloc(1, sizeof *t);
    V *stack = vm_cleared_stack(THREAD_STACK_WORDS);
    if (!t || !stack) {
        free(t);
        free(stack);
        return sj_raise(vm, "thread: cannot start a thread");
    }
    t->vm = vm;
    t->thunk = vm->args[0]; /* first_thread may have collected */
    t->exception = t->trace = V_NIL;
    t->stack = t->fp = t->top = t->stack_limit = stack;
    t->stack_words = THREAD_STACK_WORDS;
    t->trace_floor = SIZE_MAX;
    t->next = vm->threads;
    vm->threads = t;
    if (!start_detached(thread_main, t)) {
        vm->threads = t->next;
        free(stack);
        free(t);
        return sj_raise(vm, "thread: cannot start a thread");
    }
    return V_TRUE;
}

/* Reports for the end of the process, SHEN_JIT_STATS's and the profiler's: at exit, and from
   thread_exit, whose _exit skips what atexit registers. */
static void (*reports[4])(void);
static size_t nreports;

static void run_reports(void)
{
    while (nreports)
        reports[--nreports]();
}

void thread_at_exit(void (*report)(void))
{
    if (nreports == sizeof reports / sizeof reports[0])
        return;
    if (!nreports)
        atexit(run_reports);
    reports[nreports++] = report;
}

/* Ends the process with threads about. exit would flush every stream, waiting
   on any that another thread is blocked reading, so flush what was written and
   go. */
void thread_exit(VM *vm, int status)
{
    run_reports();
    fflush(stdout);
    fflush(stderr);
    for (size_t i = 0; i < vm->nfiles; i++) {
        uint64_t *o = ptr(vm->files[i]);
        if ((o[STREAM_FLAGS] & STREAM_OPEN) && (o[STREAM_FLAGS] & STREAM_OUTPUT))
            fflush((FILE *)(uintptr_t)o[STREAM_HANDLE]);
    }
    _exit(status);
}

/* This thread holds the lock until the process ends, so no other runs again:
   what only they reach need not stay alive, or go in an image. */
void thread_forget_others(VM *vm)
{
    if (vm->threads) {
        vm->threads = vm->thread;
        vm->thread->next = NULL;
    }
}

bool thread_is_only(const VM *vm)
{
    return !vm->threads || (vm->thread->main && !vm->threads->next);
}

void thread_free_all(VM *vm)
{
    pthread_mutex_lock(&lock);
    if (ticking == vm)
        ticking = NULL;
    pthread_mutex_unlock(&lock);
    while (vm->threads) {
        Thread *t = vm->threads;
        vm->threads = t->next;
        if (t != vm->thread) {
            free(t->stack);
            free(t->handlers);
            free(t->croots);
        }
        free(t);
    }
    vm->thread = NULL;
}

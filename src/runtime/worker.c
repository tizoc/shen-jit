/* One VM per joinable OS thread. Only copied binary messages cross heaps.
   The host may allocate/collect while workers are parked: each worker roots
   its reply and cannot execute again until the host has copied all slices.
   No lock is held while Shen code, a collector or a JIT compiler runs.

   The scope owns an optional immutable native input copy. Workers can read
   words through checked accessors, never obtain its address or mutate it.
   It is freed only after every worker VM is destroyed and its thread joined.

   Jobs must terminate/cooperate: there is no unsafe pthread cancellation.
   Ordinary guest errors stop further batches; running jobs finish before
   the error crosses back into the host. Native code remains trusted. */
#define _DEFAULT_SOURCE
#include "worker.h"
#include "jit.h"
#include "ops.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <time.h>

enum { MAX_WORKERS = 64, MAX_SLICES = 16, MAX_REQUEST = 1 << 20, MAX_SHARED = 64 << 20,
       MAX_RESPONSE = 64 << 20 };

typedef struct { const unsigned char *bytes; size_t length; } Slice;
typedef struct Worker {
    struct WorkerScope *scope;
    pthread_t thread;
    size_t index, seen;
    unsigned char *request;
    size_t request_length, response_length, nslices;
    Slice slices[MAX_SLICES];
} Worker;

typedef struct WorkerScope {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    Worker workers[MAX_WORKERS];
    size_t count, started, ready, epoch, done, response_bytes;
    size_t initial_words, max_words, stress;
    bool closing, failed;
    char error[384];
    char *image, *entry;
    unsigned char *shared;
    size_t shared_length;
    V token, body, host_view;
} WorkerScope;

static size_t live_workers;

/* Called only with the scope mutex held. Preserve the first error. */
static void fail(WorkerScope *s, const char *message)
{
    if (!s->failed) {
        snprintf(s->error, sizeof s->error, "%s", message);
        __atomic_store_n(&s->failed, true, __ATOMIC_RELEASE);
    }
    pthread_cond_broadcast(&s->changed);
}

static void guest_error(VM *vm, char *text, size_t size)
{
    vm->args[0] = vm->exception;
    V message = sj_primitive(vm, P_ERROR_TO_STRING);
    if (is_object(message) && obj_type(message) == T_STRING)
        snprintf(text, size, "%.*s", (int)(string_length(message) < size - 1 ? string_length(message) : size - 1),
                 string_bytes(message));
    else
        snprintf(text, size, "worker raised an error");
}

static bool slices(Worker *w, V reply)
{
    w->nslices = w->response_length = 0;
    while (is_pair(reply) && w->nslices < MAX_SLICES) {
        V slice = ptr(reply)[0];
        if (!is_pair(slice))
            return false;
        V bytes = ptr(slice)[0];
        slice = ptr(slice)[1];
        if (!is_pair(slice) || !is_fix(ptr(slice)[0]) || fixval(ptr(slice)[0]) < 0)
            return false;
        size_t at = (size_t)fixval(ptr(slice)[0]);
        slice = ptr(slice)[1];
        if (!is_pair(slice) || !is_fix(ptr(slice)[0]) || fixval(ptr(slice)[0]) < 0 || ptr(slice)[1] != V_NIL ||
            !is_object(bytes) || obj_type(bytes) != T_BYTES)
            return false;
        size_t n = (size_t)fixval(ptr(slice)[0]), length = (size_t)hdr_size(ptr(bytes)[0]);
        if (at > length || n > length - at || n > MAX_RESPONSE - w->response_length)
            return false;
        w->slices[w->nslices++] = (Slice){(const unsigned char *)(ptr(bytes) + 1) + at, n};
        w->response_length += n;
        reply = ptr(reply)[1];
    }
    return reply == V_NIL;
}

static void *run_worker(void *argument)
{
    Worker *w = argument;
    WorkerScope *s = w->scope;
    __atomic_add_fetch(&live_workers, 1, __ATOMIC_RELAXED);
    Jit *jit = jit_create();
    VM *vm = jit ? image_load(s->image, s->initial_words, 1 << 16,
                              jit_compile_stub(jit), jit_foreign_stub(jit)) : NULL;
    V entry = V_NIL, request = V_NIL, reply = V_NIL;
    char error[384] = "worker: cannot load image";
    bool initialized = false;
    if (vm) {
        jit_attach(vm, jit);
        vm->worker_owner = w;
        vm->stress = s->stress;
        vm->max_words = s->max_words;
        thread_note_worker_stack(vm);
        vm_root(vm, &entry);
        vm_root(vm, &request);
        vm_root(vm, &reply);
        if (vm->space_words > s->max_words) {
            snprintf(error, sizeof error, "worker: image exceeds its heap limit");
        } else if (sj_init_host(vm)) {
            V name = intern_cstr(vm, s->entry);
            if (name != V_CLEARED) {
                entry = *cell_function(vm, symbol_cell(name));
                initialized = is_proc(entry) && hdr_type(ptr(entry)[0]) == T_CLOSURE;
            }
            if (!initialized)
                snprintf(error, sizeof error, "worker: entry is not a Shen function");
        }
    }
    pthread_mutex_lock(&s->lock);
    if (!initialized)
        fail(s, error);
    s->ready++;
    pthread_cond_broadcast(&s->changed);
    for (;;) {
        while (!s->closing && w->seen == s->epoch)
            pthread_cond_wait(&s->changed, &s->lock);
        if (s->closing || !initialized)
            break;
        w->seen = s->epoch;
        bool skip = s->failed;
        pthread_mutex_unlock(&s->lock);
        reply = V_NIL;
        bool ok = false;
        if (!skip) {
            request = make_bytes(vm, w->request, w->request_length);
            if (request != V_CLEARED)
                reply = jit_call(vm, entry, 1, &request);
            else
                sj_raise(vm, "out of memory");
            if (request == V_CLEARED || reply == V_CLEARED)
                guest_error(vm, error, sizeof error);
            else if (!(ok = slices(w, reply)))
                snprintf(error, sizeof error, "worker: reply must be at most 16 [bytes offset length] slices");
        }
        pthread_mutex_lock(&s->lock);
        if (!skip && !ok)
            fail(s, error);
        if (ok && w->response_length > MAX_RESPONSE - s->response_bytes)
            fail(s, "worker: aggregate replies exceed 64 MiB");
        else if (ok)
            s->response_bytes += w->response_length;
        s->done++;
        pthread_cond_broadcast(&s->changed);
        /* reply stays rooted, and this VM cannot collect, until next epoch. */
    }
    if (vm) {
        vm_unroot(vm, 3);
        /* SLJIT's executable allocator serializes every code free. Releasing
           code one VM at a time avoids contending for that lock per function;
           keep heap destruction outside this scope lock so it can overlap. */
        jit_destroy(vm);
    }
    pthread_mutex_unlock(&s->lock);
    if (vm) {
        vm_destroy(vm);
    } else {
        jit_dispose(jit);
    }
    __atomic_sub_fetch(&live_workers, 1, __ATOMIC_RELAXED);
    return NULL;
}

static void stop(WorkerScope *s)
{
    pthread_mutex_lock(&s->lock);
    __atomic_store_n(&s->closing, true, __ATOMIC_RELEASE);
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
    for (size_t i = 0; i < s->started; i++)
        if (pthread_join(s->workers[i].thread, NULL) != 0)
            abort(); /* private joinable handles: returning could free a live VM */
    /* The canonical parent descriptor may escape through globals or a returned
       closure. Every alias is invalidated before storage dies.
       Worker descriptors die with their VMs, before their threads are joined. */
    if (is_object(s->host_view)) {
        uint64_t *p = ptr(s->host_view);
        p[POINTER_ADDRESS] = p[POINTER_LENGTH] = 0;
    }
    for (size_t i = 0; i < s->count; i++)
        free(s->workers[i].request);
    pthread_cond_destroy(&s->changed);
    pthread_mutex_destroy(&s->lock);
    free(s->image);
    free(s->entry);
    free(s->shared);
}

static char *copy_name(V value, bool symbol)
{
    if (symbol) {
        if (!is_symbol(value))
            return NULL;
        value = ptr(value)[SYM_NAME];
    }
    if (!is_object(value) || obj_type(value) != T_STRING || string_length(value) > 4096 ||
        memchr(string_bytes(value), 0, string_length(value)))
        return NULL;
    char *copy = malloc(string_length(value) + 1);
    if (copy) {
        memcpy(copy, string_bytes(value), string_length(value));
        copy[string_length(value)] = 0;
    }
    return copy;
}

V worker_scope(VM *vm)
{
    if (vm->worker_owner || vm->worker_scope || vm->threads)
        return sj_raise(vm, "worker: scopes cannot nest or mix with legacy threads");
    if (profile_running() || getenv("SHEN_JIT_PERF_MAP"))
        return sj_raise(vm, "worker: process-wide profiling is unsupported in a worker scope");
    if (!is_fix(vm->args[2]) || fixval(vm->args[2]) < 0 || fixval(vm->args[2]) > MAX_WORKERS ||
        !is_proc(vm->args[4]))
        return sj_raise(vm, "worker: expected 0..64 workers and a scope body");
    V limits = vm->args[3];
    V values[3];
    for (size_t i = 0; i < 3; i++) {
        if (!is_pair(limits))
            return sj_raise(vm, "worker: limits must be [initial-bytes max-bytes shared-bytes]");
        values[i] = ptr(limits)[0];
        limits = ptr(limits)[1];
    }
    if (limits != V_NIL || !is_fix(values[0]) || !is_fix(values[1]) || fixval(values[0]) < 65536 ||
        fixval(values[1]) < fixval(values[0]) || fixval(values[1]) > (512 << 20) ||
        !is_object(values[2]) || obj_type(values[2]) != T_BYTES || hdr_size(ptr(values[2])[0]) > MAX_SHARED)
        return sj_raise(vm, "worker: invalid heap limits or shared input");
    WorkerScope *s = calloc(1, sizeof *s);
    if (!s)
        return sj_raise(vm, "out of memory");
    if (pthread_mutex_init(&s->lock, NULL) != 0) {
        free(s);
        return sj_raise(vm, "worker: cannot create mutex");
    }
    if (pthread_cond_init(&s->changed, NULL) != 0) {
        pthread_mutex_destroy(&s->lock);
        free(s);
        return sj_raise(vm, "worker: cannot create condition variable");
    }
    s->count = (size_t)fixval(vm->args[2]);
    s->initial_words = (size_t)fixval(values[0]) / sizeof(V);
    s->max_words = (size_t)fixval(values[1]) / sizeof(V);
    s->stress = vm->stress;
    s->image = copy_name(vm->args[0], false);
    s->entry = copy_name(vm->args[1], true);
    s->shared_length = (size_t)hdr_size(ptr(values[2])[0]);
    s->shared = malloc(s->shared_length ? s->shared_length : 1);
    s->body = vm->args[4];
    s->token = s->host_view = V_NIL;
    if (!s->image || !s->entry || !s->shared) {
        stop(s);
        free(s);
        return sj_raise(vm, "worker: invalid image/entry or out of memory");
    }
    memcpy(s->shared, ptr(values[2]) + 1, s->shared_length);
    size_t roots = vm->ncroots;
    vm_root(vm, &s->body);
    vm_root(vm, &s->token);
    vm_root(vm, &s->host_view);
    s->token = make_vector(vm, 0, V_NIL); /* identity only: never exposes a native address */
    if (s->token == V_CLEARED) {
        stop(s);
        free(s);
        vm->ncroots = roots;
        return sj_raise(vm, "out of memory");
    }
    pthread_attr_t attr;
    bool have_attr = pthread_attr_init(&attr) == 0;
    bool attributes = have_attr && pthread_attr_setstacksize(&attr, C_STACK_BYTES) == 0;
#ifndef _WIN32
    sigset_t block, previous;
    sigemptyset(&block);
    sigaddset(&block, SIGINT);
    bool masked = pthread_sigmask(SIG_BLOCK, &block, &previous) == 0;
    attributes = attributes && masked;
#endif
    for (size_t i = 0; i < s->count; i++) {
        Worker *w = &s->workers[i];
        w->scope = s;
        w->index = i;
        if (!attributes || pthread_create(&w->thread, &attr, run_worker, w) != 0) {
            pthread_mutex_lock(&s->lock);
            fail(s, "worker: cannot create OS thread");
            pthread_mutex_unlock(&s->lock);
            break;
        }
        s->started++;
    }
#ifndef _WIN32
    if (masked)
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
#endif
    if (have_attr)
        pthread_attr_destroy(&attr);
    pthread_mutex_lock(&s->lock);
    while (s->ready < s->started)
        pthread_cond_wait(&s->changed, &s->lock);
    bool ready = !s->failed && s->started == s->count;
    pthread_mutex_unlock(&s->lock);
    vm->worker_scope = s;
    V result = ready ? jit_call_nested(vm, s->body, 1, &s->token) : V_CLEARED;
    stop(s); /* every VM dies before any scope data is freed */
    vm->worker_scope = NULL;
    bool failed = s->failed;
    char error[sizeof s->error];
    memcpy(error, s->error, sizeof error);
    free(s);
    vm->ncroots = roots;
    return failed && (!ready || result != V_CLEARED) ? sj_raise_text(vm, error) : result;
}

V worker_batch(VM *vm)
{
    WorkerScope *s = vm->worker_scope;
    if (!s || vm->args[0] != s->token)
        return sj_raise(vm, "worker: inactive or foreign scope token");
    V requests = vm->args[1];
    /* Validate and copy every request before publishing any work. */
    for (size_t i = 0; i < s->count; i++) {
        if (!is_pair(requests) || !is_object(ptr(requests)[0]) || obj_type(ptr(requests)[0]) != T_BYTES)
            return sj_raise(vm, "worker: one byte request per worker is required");
        V b = ptr(requests)[0];
        size_t n = (size_t)hdr_size(ptr(b)[0]);
        if (n > MAX_REQUEST)
            return sj_raise(vm, "worker: request exceeds 1 MiB");
        unsigned char *copy = realloc(s->workers[i].request, n ? n : 1);
        if (!copy)
            return sj_raise(vm, "out of memory");
        s->workers[i].request = copy;
        s->workers[i].request_length = n;
        memcpy(copy, ptr(b) + 1, n);
        requests = ptr(requests)[1];
    }
    if (requests != V_NIL)
        return sj_raise(vm, "worker: too many requests");
    pthread_mutex_lock(&s->lock);
    if (s->failed) {
        pthread_mutex_unlock(&s->lock);
        return sj_raise(vm, "worker: scope failed");
    }
    s->done = s->response_bytes = 0;
    s->epoch++;
    pthread_cond_broadcast(&s->changed);
    while (s->done < s->count) {
        struct timespec wake;
        timespec_get(&wake, TIME_UTC);
        wake.tv_nsec += 20000000;
        if (wake.tv_nsec >= 1000000000) {
            wake.tv_sec++;
            wake.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&s->changed, &s->lock, &wake);
        if (vm->interrupted == INTERRUPT)
            fail(s, "worker: scope interrupted; waiting for running jobs");
    }
    bool failed = s->failed;
    pthread_mutex_unlock(&s->lock);
    V replies = V_NIL;
    size_t roots = vm->ncroots;
    vm_root(vm, &replies);
    for (size_t i = s->count; !failed && i-- > 0;) {
        Worker *w = &s->workers[i];
        V bytes = make_bytes(vm, NULL, w->response_length);
        if (bytes == V_CLEARED) {
            failed = true;
            break;
        }
        unsigned char *to = (unsigned char *)(ptr(bytes) + 1);
        for (size_t k = 0; k < w->nslices; k++) {
            memcpy(to, w->slices[k].bytes, w->slices[k].length);
            to += w->slices[k].length;
        }
        replies = make_pair(vm, bytes, replies);
        if (replies == V_CLEARED)
            failed = true;
    }
    vm->ncroots = roots;
    pthread_mutex_lock(&s->lock);
    if (failed && !s->failed)
        fail(s, "worker: cannot copy reply into host heap");
    pthread_mutex_unlock(&s->lock);
    if (vm->interrupted == INTERRUPT && sj_take_interrupt(vm))
        return V_CLEARED;
    return failed ? sj_raise_text(vm, s->error) : replies;
}

V worker_index(VM *vm)
{
    return vm->worker_owner ? fix((int64_t)vm->worker_owner->index) : sj_raise(vm, "worker: not in a worker");
}

V worker_live(VM *vm)
{
    return fix((int64_t)__atomic_load_n(&live_workers, __ATOMIC_RELAXED));
}

V worker_cancelled(VM *vm)
{
    if (!vm->worker_owner)
        return sj_raise(vm, "worker: not in a worker");
    WorkerScope *s = vm->worker_owner->scope;
    bool cancelled = __atomic_load_n(&s->failed, __ATOMIC_ACQUIRE) ||
                     __atomic_load_n(&s->closing, __ATOMIC_ACQUIRE);
    return cancelled ? V_TRUE : V_FALSE;
}

V worker_shared_view(VM *vm)
{
    WorkerScope *s = vm->worker_owner ? vm->worker_owner->scope : vm->worker_scope;
    if (!s)
        return sj_raise(vm, "worker: no active shared storage");
    if (!vm->worker_owner && s->host_view != V_NIL)
        return s->host_view;
    uint64_t *p = vm_alloc(vm, POINTER_WORDS);
    if (!p)
        return sj_raise(vm, "out of memory");
    p[0] = HEADER(T_SHARED_BYTES, 0);
    p[POINTER_KIND] = p[POINTER_OWNER] = V_NIL;
    p[POINTER_ADDRESS] = (uint64_t)(uintptr_t)s->shared;
    p[POINTER_LENGTH] = s->shared_length;
    V view = tagged(p, TAG_OBJECT);
    if (!vm->worker_owner)
        s->host_view = view;
    return view;
}


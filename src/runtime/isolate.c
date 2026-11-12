/* Isolates over one program (docs/design.md, "The builder and isolates"): each runs on an OS
   thread of its own, in a context of its own (a VM) over the builder's program, and they talk
   only through channels. A value crosses as a fragment: copied out of the sender's heap into
   blocks outside every heap, then into the receiver's, so no heap is read by two threads. What
   is in the program space crosses by pointer, and a symbol of the sender's own by its name.

   One lock, the isolates' lock, guards the tables of isolates and channels and the counts of
   the rendezvous; each isolate waits on a condition of its own. The builder changes the program
   only while every other isolate is stopped: waiting on a channel, inside a blocking region, or
   parked at a safe point, where its loop and entry checks bring it once its interrupt is ATTEND.
   It holds the compile lock meanwhile, which compiling also takes, so nothing compiles against
   cells being patched. */
#define _DEFAULT_SOURCE
#include "vm.h"
#include "jit.h"
#include "ops.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* A fragment's blocks, and a new isolate's heap and stack, in words. Both grow as needed. */
enum { BLOCK_WORDS = 1 << 12, CONTEXT_WORDS = 1 << 14, CONTEXT_STACK = 1 << 12 };

/* ---------------------------------------------------------------------------------------------
   Fragments */

typedef struct Fragment {
    uint64_t **blocks;
    size_t *used, *size;
    size_t nblocks, cap, words;
    V root;
} Fragment;

static void fragment_free(Fragment *f)
{
    if (!f)
        return;
    for (size_t i = 0; i < f->nblocks; i++)
        free(f->blocks[i]);
    free(f->blocks);
    free(f->used);
    free(f->size);
    free(f);
}

static uint64_t *fragment_alloc(Fragment *f, size_t words)
{
    if (!f->nblocks || f->used[f->nblocks - 1] + words > f->size[f->nblocks - 1]) {
        if (f->nblocks == f->cap) {
            size_t cap = f->cap ? 2 * f->cap : 8;
            uint64_t **blocks = realloc(f->blocks, cap * sizeof *blocks);
            if (!blocks)
                return NULL;
            f->blocks = blocks;
            size_t *used = realloc(f->used, cap * sizeof *used);
            if (!used)
                return NULL;
            f->used = used;
            size_t *size = realloc(f->size, cap * sizeof *size);
            if (!size)
                return NULL;
            f->size = size;
            f->cap = cap;
        }
        size_t n = words > BLOCK_WORDS ? words : BLOCK_WORDS;
        if (!(f->blocks[f->nblocks] = malloc(n * sizeof(uint64_t))))
            return NULL;
        f->used[f->nblocks] = 0;
        f->size[f->nblocks++] = n;
    }
    uint64_t *at = f->blocks[f->nblocks - 1] + f->used[f->nblocks - 1];
    f->used[f->nblocks - 1] += words;
    f->words += words;
    return at;
}

/* The objects of a fragment, in the order they were copied: a pair has no header. */
static size_t fragment_object_words(const uint64_t *s) { return is_header(*s) ? obj_words(*s) : 2; }

/* From an object's old address to its copy, so that sharing and cycles are kept. */
typedef struct {
    uintptr_t *keys;
    V *values;
    size_t cap, n;
} Map;

static size_t map_index(const Map *m, uintptr_t key)
{
    return (size_t)((key >> 3) * UINT64_C(0x9E3779B97F4A7C15) >> 20) & (m->cap - 1);
}

static V map_get(const Map *m, uintptr_t key)
{
    if (!m->cap)
        return 0;
    for (size_t i = map_index(m, key);; i = (i + 1) & (m->cap - 1)) {
        if (!m->keys[i])
            return 0;
        if (m->keys[i] == key)
            return m->values[i];
    }
}

static bool map_put(Map *m, uintptr_t key, V value)
{
    if (2 * (m->n + 1) > m->cap) {
        size_t cap = m->cap ? 2 * m->cap : 64;
        Map grown = {calloc(cap, sizeof(uintptr_t)), malloc(cap * sizeof(V)), cap, 0};
        if (!grown.keys || !grown.values) {
            free(grown.keys);
            free(grown.values);
            return false;
        }
        for (size_t i = 0; i < m->cap; i++)
            if (m->keys[i])
                map_put(&grown, m->keys[i], m->values[i]);
        free(m->keys);
        free(m->values);
        *m = grown;
    }
    size_t i = map_index(m, key);
    while (m->keys[i])
        i = (i + 1) & (m->cap - 1);
    m->keys[i] = key;
    m->values[i] = value;
    m->n++;
    return true;
}

/* ---------------------------------------------------------------------------------------------
   Isolates and channels */

enum { STARTING, RUNNING, WAITING, STOPPED, ENDED };

typedef struct Isolate {
    Program *program;
    VM *vm; /* while it runs */
    pthread_cond_t wake;
    uint32_t index, generation;
    int state;
    size_t blocked;    /* blocking regions it is in */
    bool killed;       /* for good, which its monitors are told */
    bool kill_pending; /* until its next safe point raises it */
    bool ending;       /* monitors added now get down at once */
    V entry;           /* the procedure it runs, in the program space */
    Fragment *argument; /* until it takes it */
    uint64_t gensym_base;
    uint64_t *monitors; /* channels told when it ends: index << 32 | generation */
    size_t nmonitors, monitors_cap;
    /* Why it ended, kept until the record is used again, for monitors that come after: a symbol of
       the program space, or an error's text. */
    V end_symbol;
    char *end_text;
    size_t end_length;
} Isolate;

typedef struct Channel {
    uint32_t generation;
    size_t next_free; /* while unused: the next free slot's index plus one, or 0 */
    bool used, closed, receiver_waiting;
    size_t capacity, count, head;
    Fragment **queue;
    Isolate *receiver;
    Isolate **senders; /* waiting while it is full */
    size_t nsenders, senders_cap;
} Channel;

typedef struct Isolates {
    pthread_mutex_t lock, compile;
    pthread_cond_t stopped;
    Isolate **table; /* the builder's first */
    size_t n, cap;
    Channel *channels;
    size_t nchannels, channels_cap;
    size_t free_channel; /* the first free slot's index plus one, or 0 */
    size_t running; /* isolates other than the builder that are not stopped */
    bool rendezvous;
    uint64_t epoch;         /* publications so far */
    size_t published_count; /* published symbols when the rendezvous began */
    size_t globals;         /* global slots every isolate has */
    uint64_t spawned;
    V tag_isolate, tag_receiver, tag_sender, tag_given, end, down, normal, killed, ended;
    V constant_symbols[8], constant_values[8];
    size_t nconstants;
} Isolates;

/* Its turn at its next safe point: the interrupt first, then the limit, as a Ctrl-C does
   (vm_set_limit). */
static void attend(VM *vm)
{
    __atomic_store_n(&vm->interrupted, ATTEND, __ATOMIC_SEQ_CST);
    vm->check_limit = NULL;
}

static bool counted(VM *vm) { return vm->isolate && vm->program->owner != vm; }

/* With the lock held. */
static void park(Isolates *ps, Isolate *p, int state)
{
    p->state = state;
    ps->running--;
    pthread_cond_signal(&ps->stopped);
}

/* With the lock held: once no rendezvous is going on, running again. */
static void resume(Isolates *ps, Isolate *p)
{
    while (ps->rendezvous)
        pthread_cond_wait(&p->wake, &ps->lock);
    p->state = RUNNING;
    ps->running++;
}

/* A publication since this isolate last looked: its next safe point collects. */
static void note_epoch(Isolates *ps, VM *vm)
{
    if (vm->epoch_seen != ps->epoch)
        attend(vm);
}

/* After a publication, before anything published can reach this isolate: a collection that
   replaces its own symbols whose names have been published by the published ones (heap.c). */
void isolate_fixup(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps || !counted(vm))
        return;
    uint64_t epoch = __atomic_load_n(&ps->epoch, __ATOMIC_ACQUIRE);
    if (vm->epoch_seen == epoch)
        return;
    vm->epoch_seen = epoch;
    vm->fixup = true;
    vm_collect(vm, 0);
    vm->fixup = false;
}

/* The compile lock, recursive, as the builder collects while it holds it. An isolate waits for
   it inside a blocking region, since the builder holds it for a whole rendezvous. */
void program_compile_lock(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps)
        return;
    isolate_block(vm);
    pthread_mutex_lock(&ps->compile);
    isolate_unblock(vm);
}

void program_compile_unlock(VM *vm)
{
    if (vm->program->isolates)
        pthread_mutex_unlock(&vm->program->isolates->compile);
}

/* A new global number has a slot in every isolate before any code can use it. */
void isolates_commit_globals(Program *program, size_t n)
{
    Isolates *ps = program->isolates;
    if (!ps)
        return;
    pthread_mutex_lock(&ps->lock);
    if (n > ps->globals)
        ps->globals = n;
    for (size_t i = 1; i < ps->n; i++)
        if (ps->table[i]->vm && ps->table[i]->state != ENDED)
            vm_globals_commit(ps->table[i]->vm, n);
    pthread_mutex_unlock(&ps->lock);
}

void isolate_block(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps || !counted(vm))
        return;
    pthread_mutex_lock(&ps->lock);
    if (vm->isolate->blocked++ == 0)
        park(ps, vm->isolate, WAITING);
    pthread_mutex_unlock(&ps->lock);
}

void isolate_unblock(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps || !counted(vm))
        return;
    pthread_mutex_lock(&ps->lock);
    if (--vm->isolate->blocked == 0) {
        resume(ps, vm->isolate);
        note_epoch(ps, vm);
    }
    pthread_mutex_unlock(&ps->lock);
}

/* With the lock held, in any isolate: waiting on its condition until woken, counted as
   stopped meanwhile unless it is the builder. */
static void wait_turn(Isolates *ps, VM *vm)
{
    Isolate *p = vm->isolate;
    if (counted(vm))
        park(ps, p, WAITING);
    pthread_cond_wait(&p->wake, &ps->lock);
    if (counted(vm)) {
        resume(ps, p);
        note_epoch(ps, vm);
    }
}

/* Whether an isolate other than the builder has not ended. */
bool isolates_running(Program *program)
{
    Isolates *ps = program->isolates;
    if (!ps)
        return false;
    pthread_mutex_lock(&ps->lock);
    bool any = false;
    for (size_t i = 1; i < ps->n && !any; i++)
        any = ps->table[i]->state != ENDED;
    pthread_mutex_unlock(&ps->lock);
    return any;
}

/* The builder stops every other isolate, holding the compile lock until program_go. An isolate
   that clears its interrupt just as this sets it may keep running past its frame checks, so
   the request is made again until all are stopped. */
bool program_stop(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps || vm->program->owner != vm)
        return false;
    pthread_mutex_lock(&ps->compile);
    pthread_mutex_lock(&ps->lock);
    ps->rendezvous = true;
    ps->published_count = vm->program->published.count;
    while (ps->running > 0) {
        for (size_t i = 1; i < ps->n; i++)
            if (ps->table[i]->state == RUNNING && ps->table[i]->vm)
                attend(ps->table[i]->vm);
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += 1000000;
        if (until.tv_nsec >= 1000000000) {
            until.tv_sec++;
            until.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&ps->stopped, &ps->lock, &until);
    }
    pthread_mutex_unlock(&ps->lock);
    return true;
}

void program_go(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    pthread_mutex_lock(&ps->lock);
    ps->rendezvous = false;
    if (vm->program->published.count != ps->published_count)
        __atomic_add_fetch(&ps->epoch, 1, __ATOMIC_RELEASE);
    for (size_t i = 1; i < ps->n; i++)
        pthread_cond_signal(&ps->table[i]->wake);
    pthread_mutex_unlock(&ps->lock);
    pthread_mutex_unlock(&ps->compile);
}

/* At a safe point of an isolate whose interrupt is ATTEND: its turn, its fix-up, or a kill. */
V isolate_attend(VM *vm)
{
    int asked = ATTEND;
    __atomic_compare_exchange_n(&vm->interrupted, &asked, 0, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    vm_set_limit(vm, vm->stack_limit);
    Isolates *ps = vm->program->isolates;
    if (!ps || !counted(vm))
        return V_NIL;
    Isolate *p = vm->isolate;
    pthread_mutex_lock(&ps->lock);
    if (ps->rendezvous) {
        park(ps, p, STOPPED);
        resume(ps, p);
    }
    bool kill = p->kill_pending;
    p->kill_pending = false;
    pthread_mutex_unlock(&ps->lock);
    isolate_fixup(vm);
    return kill ? sj_raise(vm, "killed") : V_NIL;
}

/* A handle: [Tag Index Generation], an absvector of the caller's. Each tag is a function of the
   port's that prints it, as the printer calls an absvector's first element when it is one. */
static V handle(VM *vm, V tag, size_t index, uint32_t generation)
{
    V v = make_vector(vm, 3, V_NIL);
    if (v == V_CLEARED)
        return v;
    ptr(v)[1] = tag;
    ptr(v)[2] = fix((int64_t)index);
    ptr(v)[3] = fix((int64_t)generation);
    return v;
}

static bool handle_of(V v, V tag, size_t *index, uint32_t *generation)
{
    if (!is_object(v) || obj_type(v) != T_VECTOR || hdr_size(ptr(v)[0]) != 3 || ptr(v)[1] != tag ||
        !is_fix(ptr(v)[2]) || !is_fix(ptr(v)[3]) || fixval(ptr(v)[2]) < 0)
        return false;
    *index = (size_t)fixval(ptr(v)[2]);
    *generation = (uint32_t)fixval(ptr(v)[3]);
    return true;
}

/* ---------------------------------------------------------------------------------------------
   Copying out: what a value reaches of the sender's heap, into a fragment, breadth first as a
   collection copies, with nothing written into the sender's objects. Nothing allocates in the
   heap meanwhile, so nothing moves. */

typedef struct {
    VM *vm;
    Isolates *ps;
    Fragment *f;
    Map map;
    bool spawn;
    const char *error;
    V offender;
    size_t *given; /* channels whose receive endpoints move, at spawn */
    size_t ngiven, given_cap;
} Out;

static V out_fail(Out *o, const char *error, V v)
{
    if (!o->error) {
        o->error = error;
        o->offender = v;
    }
    return V_NIL;
}

static V out_copy(Out *o, V v, size_t words)
{
    uint64_t *q = fragment_alloc(o->f, words);
    if (!q)
        return out_fail(o, "out of memory", V_NIL);
    memcpy(q, ptr(v), words * sizeof(uint64_t));
    V copy = tagged(q, tag3(v));
    if (!map_put(&o->map, (uintptr_t)ptr(v), copy))
        return out_fail(o, "out of memory", V_NIL);
    return copy;
}

static V out_value(Out *o, V v)
{
    if (o->error || !is_ptr(v))
        return v;
    if (v == o->ps->end)
        return out_fail(o, "the end of a stream cannot be sent", V_NIL);
    if (in_program(o->vm, ptr(v)) && !(is_symbol(v) && !symbol_published(v)))
        return v;
    V known = map_get(&o->map, (uintptr_t)ptr(v));
    if (known)
        return known;
    if (is_symbol(v))
        return out_copy(o, v, SYM_WORDS); /* for its name, which the scan copies */
    if (is_pair(v))
        return out_copy(o, v, 2);
    if (is_proc(v))
        return out_fail(o, "~S cannot be sent: only the program's functions can", v);
    size_t index;
    uint32_t generation;
    switch (obj_type(v)) {
    case T_STRING:
    case T_REAL:
    case T_BYTES:
    case T_EXCEPTION: return out_copy(o, v, obj_words(ptr(v)[0]));
    case T_VECTOR:
        if (handle_of(v, o->ps->tag_receiver, &index, &generation))
            return out_fail(o, "~S can move only at spawn, through shen-jit.give", v);
        if (handle_of(v, o->ps->tag_given, &index, &generation)) {
            if (!o->spawn)
                return out_fail(o, "~S can move only at spawn", v);
            if (o->ngiven == o->given_cap) {
                size_t cap = o->given_cap ? 2 * o->given_cap : 4;
                size_t *given = realloc(o->given, cap * sizeof *given);
                if (!given)
                    return out_fail(o, "out of memory", V_NIL);
                o->given = given;
                o->given_cap = cap;
            }
            o->given[o->ngiven++] = index;
            V copy = out_copy(o, v, obj_words(ptr(v)[0]));
            if (!o->error)
                ptr(copy)[1] = o->ps->tag_receiver;
            return copy;
        }
        return out_copy(o, v, obj_words(ptr(v)[0]));
    default: return out_fail(o, "~S cannot be sent", v);
    }
}

/* A fragment of v, or NULL with the reason in *error and the value at fault in *offender. */
static Fragment *fragment_out(VM *vm, V v, bool spawn, size_t **given, size_t *ngiven, const char **error,
                              V *offender)
{
    Out o = {vm, vm->program->isolates, calloc(1, sizeof(Fragment)), {NULL, NULL, 0, 0}, spawn, NULL, V_NIL,
             NULL, 0, 0};
    Fragment *f = o.f;
    if (!f) {
        o.error = "out of memory";
    } else {
        f->root = out_value(&o, v);
        for (size_t b = 0; b < f->nblocks && !o.error; b++)
            for (size_t w = 0; w < f->used[b] && !o.error;) {
                uint64_t *s = f->blocks[b] + w;
                w += fragment_object_words(s);
                if (is_header(*s)) {
                    size_t first, count;
                    obj_values(*s, &first, &count);
                    for (size_t i = 0; i < count; i++)
                        s[first + i] = out_value(&o, s[first + i]);
                } else {
                    s[0] = out_value(&o, s[0]);
                    s[1] = out_value(&o, s[1]);
                }
            }
    }
    free(o.map.keys);
    free(o.map.values);
    if (o.error) {
        fragment_free(f);
        free(o.given);
        *error = o.error;
        *offender = o.offender;
        return NULL;
    }
    if (given) {
        *given = o.given;
        *ngiven = o.ngiven;
    } else {
        free(o.given);
    }
    return f;
}

/* ---------------------------------------------------------------------------------------------
   Copying in: a fragment into this context's heap. Its symbols are interned first, by name,
   which may collect; then there is room for the rest at once, so nothing moves while it is
   copied. */

static V in_value(VM *vm, Map *map, V v)
{
    if (!is_ptr(v) || in_program(vm, ptr(v)))
        return v;
    V known = map_get(map, (uintptr_t)ptr(v));
    if (known)
        return known;
    size_t words = is_pair(v) ? 2 : obj_words(ptr(v)[0]);
    uint64_t *q = vm_alloc(vm, words); /* there is room: this does not collect */
    memcpy(q, ptr(v), words * sizeof(uint64_t));
    V copy = tagged(q, tag3(v));
    map_put(map, (uintptr_t)ptr(v), copy);
    return copy;
}

static V fragment_in(VM *vm, Fragment *f)
{
    isolate_fixup(vm);
    if (!is_ptr(f->root) || in_program(vm, ptr(f->root)))
        return f->root;
    size_t nsyms = 0;
    for (size_t b = 0; b < f->nblocks; b++)
        for (size_t w = 0; w < f->used[b]; w += fragment_object_words(f->blocks[b] + w))
            nsyms += is_header(f->blocks[b][w]) && hdr_type(f->blocks[b][w]) == T_SYMBOL;
    V *syms = calloc(nsyms ? nsyms : 1, sizeof *syms);
    uint64_t **where = malloc((nsyms ? nsyms : 1) * sizeof *where);
    if (!syms || !where) {
        free(syms);
        free(where);
        return sj_raise(vm, "out of memory");
    }
    size_t k = 0;
    bool ok = true;
    for (size_t b = 0; b < f->nblocks && ok; b++)
        for (size_t w = 0; w < f->used[b] && ok; w += fragment_object_words(f->blocks[b] + w)) {
            uint64_t *s = f->blocks[b] + w;
            if (!is_header(*s) || hdr_type(*s) != T_SYMBOL)
                continue;
            V name = s[SYM_NAME];
            where[k] = s;
            syms[k] = V_NIL;
            vm_root(vm, &syms[k]);
            syms[k] = intern(vm, string_bytes(name), string_length(name));
            ok = syms[k++] != V_CLEARED;
        }
    Map map = {NULL, NULL, 0, 0};
    V root = V_CLEARED;
    size_t stress = vm->stress;
    vm->stress = 0; /* the room made here is used here */
    if (ok && ((size_t)(vm->hlimit - vm->hp) >= f->words || vm_collect(vm, f->words)) &&
        (size_t)(vm->hlimit - vm->hp) >= f->words) {
        for (size_t i = 0; i < k; i++)
            map_put(&map, (uintptr_t)where[i], syms[i]);
        uint64_t *start = vm->hp;
        root = in_value(vm, &map, f->root);
        for (uint64_t *s = start; s < vm->hp; s += fragment_object_words(s)) {
            if (is_header(*s)) {
                size_t first, count;
                obj_values(*s, &first, &count);
                for (size_t i = 0; i < count; i++)
                    s[first + i] = in_value(vm, &map, s[first + i]);
            } else {
                s[0] = in_value(vm, &map, s[0]);
                s[1] = in_value(vm, &map, s[1]);
            }
        }
    }
    vm->stress = stress;
    vm_unroot(vm, k);
    free(map.keys);
    free(map.values);
    free(syms);
    free(where);
    return root == V_CLEARED ? sj_raise(vm, "out of memory") : root;
}

/* ---------------------------------------------------------------------------------------------
   The first use: the builder's record, the tags, and the program's constants, copied into the
   program space where every isolate reads them. */

static const char *const constant_names[] = {"*language*", "*implementation*", "*release*", "*port*",
                                             "*porters*", "*os*", "*version*"};

static V publish(VM *vm, const char *name)
{
    V s = intern_cstr(vm, name);
    return s != V_CLEARED && program_publish(vm, s) ? s : V_CLEARED;
}

static Isolates *isolates_start(VM *vm)
{
    if (vm->program->isolates)
        return vm->program->isolates;
    if (vm->program->owner != vm || vm->threads || vm->worker_owner)
        return NULL;
    Isolates *ps = calloc(1, sizeof *ps);
    Isolate *self = calloc(1, sizeof *self);
    Isolate **table = malloc(16 * sizeof *table);
    if (!ps || !self || !table) {
        free(ps);
        free(self);
        free(table);
        return NULL;
    }
    ps->tag_isolate = publish(vm, "shen-jit.print-isolate");
    ps->tag_receiver = publish(vm, "shen-jit.print-receiver");
    ps->tag_sender = publish(vm, "shen-jit.print-sender");
    ps->tag_given = publish(vm, "shen-jit.print-given");
    ps->end = publish(vm, "shen-jit.end-of-stream");
    ps->down = publish(vm, "down");
    ps->normal = publish(vm, "normal");
    ps->killed = publish(vm, "killed");
    ps->ended = publish(vm, "ended");
    for (size_t i = 0; i < sizeof constant_names / sizeof constant_names[0]; i++) {
        V s = publish(vm, constant_names[i]);
        V value = s == V_CLEARED ? V_CLEARED : global_value(vm, s);
        if (is_object(value) && obj_type(value) == T_STRING)
            value = program_copy_string(vm, value);
        if (s != V_CLEARED && value != V_CLEARED && (!is_ptr(value) || in_program(vm, ptr(value)))) {
            ps->constant_symbols[ps->nconstants] = s;
            ps->constant_values[ps->nconstants++] = value;
        }
    }
    if (ps->tag_isolate == V_CLEARED || ps->tag_receiver == V_CLEARED || ps->tag_sender == V_CLEARED ||
        ps->tag_given == V_CLEARED || ps->end == V_CLEARED || ps->down == V_CLEARED || ps->normal == V_CLEARED ||
        ps->killed == V_CLEARED || ps->ended == V_CLEARED) {
        free(ps);
        free(self);
        free(table);
        return NULL;
    }
    pthread_mutexattr_t recursive;
    pthread_mutexattr_init(&recursive);
    pthread_mutexattr_settype(&recursive, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&ps->compile, &recursive);
    pthread_mutexattr_destroy(&recursive);
    pthread_mutex_init(&ps->lock, NULL);
    pthread_cond_init(&ps->stopped, NULL);
    pthread_cond_init(&self->wake, NULL);
    self->program = vm->program;
    self->vm = vm;
    self->state = RUNNING;
    table[0] = self;
    ps->table = table;
    ps->n = 1;
    ps->cap = 16;
    ps->globals = vm->program->nglobals;
    vm->isolate = self;
    /* Code compiled so far has no loop checks, which an isolate's turn needs. */
    if (!vm->interruptible) {
        vm->interruptible = true;
        jit_recompile(vm);
    }
    vm->program->isolates = ps;
    return ps;
}

/* ---------------------------------------------------------------------------------------------
   Channels, with the lock held. */

static Channel *channel_at(Isolates *ps, size_t index, uint32_t generation)
{
    return index < ps->nchannels && ps->channels[index].used && ps->channels[index].generation == generation
               ? &ps->channels[index] : NULL;
}

/* A new channel's index, or SIZE_MAX. */
static size_t channel_new(Isolates *ps, size_t capacity, Isolate *receiver)
{
    Fragment **queue = calloc(capacity, sizeof *queue);
    if (!queue)
        return SIZE_MAX;
    size_t i = ps->nchannels;
    if (ps->free_channel) {
        i = ps->free_channel - 1;
        ps->free_channel = ps->channels[i].next_free;
    } else {
        if (ps->nchannels == ps->channels_cap) {
            size_t cap = ps->channels_cap ? 2 * ps->channels_cap : 64;
            Channel *channels = realloc(ps->channels, cap * sizeof *channels);
            if (!channels) {
                free(queue);
                return SIZE_MAX;
            }
            ps->channels = channels;
            ps->channels_cap = cap;
        }
        memset(&ps->channels[ps->nchannels++], 0, sizeof(Channel));
    }
    Channel *c = &ps->channels[i];
    c->used = true;
    c->closed = c->receiver_waiting = false;
    c->capacity = capacity;
    c->count = c->head = 0;
    c->queue = queue;
    c->receiver = receiver;
    c->nsenders = 0;
    return i;
}

static void wake_senders(Channel *c)
{
    for (size_t i = 0; i < c->nsenders; i++)
        pthread_cond_signal(&c->senders[i]->wake);
    c->nsenders = 0;
}

static void channel_free(Isolates *ps, Channel *c)
{
    for (size_t i = 0; i < c->count; i++)
        fragment_free(c->queue[(c->head + i) % c->capacity]);
    free(c->queue);
    c->queue = NULL;
    c->count = 0;
    wake_senders(c);
    c->used = false;
    c->generation++;
    c->next_free = ps->free_channel;
    ps->free_channel = (size_t)(c - ps->channels) + 1;
}

/* What the isolates held, freed with the builder's VM once no other isolate runs, as none does when
   a program ends; one that ran would still use it, so then it is left to the system. An isolate
   clears its VM under the lock as the last thing it does with any of this. */
void isolates_free(Program *program)
{
    Isolates *ps = program->isolates;
    if (!ps)
        return;
    pthread_mutex_lock(&ps->lock);
    bool running = false;
    for (size_t i = 1; i < ps->n; i++)
        running = running || ps->table[i]->vm || ps->table[i]->state != ENDED;
    pthread_mutex_unlock(&ps->lock);
    if (running)
        return;
    for (size_t i = 0; i < ps->nchannels; i++) {
        Channel *c = &ps->channels[i];
        for (size_t k = 0; c->used && k < c->count; k++)
            fragment_free(c->queue[(c->head + k) % c->capacity]);
        free(c->queue);
        free(c->senders);
    }
    free(ps->channels);
    for (size_t i = 0; i < ps->n; i++) {
        Isolate *p = ps->table[i];
        fragment_free(p->argument);
        free(p->monitors);
        free(p->end_text);
        pthread_cond_destroy(&p->wake);
        free(p);
    }
    free(ps->table);
    pthread_mutex_destroy(&ps->lock);
    pthread_mutex_destroy(&ps->compile);
    free(ps);
    program->isolates = NULL;
}

static bool enqueue(Channel *c, Fragment *f)
{
    if (c->count == c->capacity)
        return false;
    c->queue[(c->head + c->count++) % c->capacity] = f;
    if (c->receiver_waiting)
        pthread_cond_signal(&c->receiver->wake);
    return true;
}

static Fragment *dequeue(Channel *c)
{
    Fragment *f = c->queue[c->head];
    c->head = (c->head + 1) % c->capacity;
    c->count--;
    wake_senders(c);
    return f;
}

/* A message the runtime sends, such as down. */
static Fragment *message(VM *vm, V v)
{
    const char *error;
    V offender;
    return fragment_out(vm, v, false, NULL, NULL, &error, &offender);
}

/* [down P Reason]. */
static V down_message(VM *vm, Isolates *ps, V isolate, V reason)
{
    vm_root(vm, &isolate);
    V tail = make_pair(vm, reason, V_NIL);
    V mid = tail == V_CLEARED ? V_CLEARED : make_pair(vm, isolate, tail);
    vm_unroot(vm, 1);
    return mid == V_CLEARED ? V_CLEARED : make_pair(vm, ps->down, mid);
}

/* ---------------------------------------------------------------------------------------------
   An isolate's life. */

/* It tells its monitors, closes its files and the channels it receives on, and frees its
   context. */
static void isolate_end(Isolate *p, V reason)
{
    VM *vm = p->vm;
    Isolates *ps = vm->program->isolates;
    bool text = is_ptr(reason) && obj_type(reason) == T_STRING;
    size_t length = text ? string_length(reason) : 0;
    char *copy = text ? malloc(length ? length : 1) : NULL;
    if (copy)
        memcpy(copy, string_bytes(reason), length);
    pthread_mutex_lock(&ps->lock);
    p->ending = true;
    p->end_symbol = text ? V_CLEARED : reason;
    p->end_text = copy;
    p->end_length = length;
    uint64_t *monitors = p->monitors;
    size_t n = p->nmonitors;
    p->monitors = NULL;
    p->nmonitors = p->monitors_cap = 0;
    pthread_mutex_unlock(&ps->lock);

    Fragment **fragments = calloc(n ? n : 1, sizeof *fragments);
    vm_root(vm, &reason);
    V self = handle(vm, ps->tag_isolate, p->index, p->generation);
    V down = self == V_CLEARED ? V_CLEARED : down_message(vm, ps, self, reason);
    vm_unroot(vm, 1);
    for (size_t i = 0; fragments && down != V_CLEARED && i < n; i++)
        fragments[i] = message(vm, down);
    for (size_t i = 0; i < vm->nfiles; i++)
        if (ptr(vm->files[i])[STREAM_FLAGS] & STREAM_OPEN) {
            fclose((FILE *)(uintptr_t)ptr(vm->files[i])[STREAM_HANDLE]);
            ptr(vm->files[i])[STREAM_FLAGS] &= ~(uint64_t)STREAM_OPEN;
        }

    pthread_mutex_lock(&ps->lock);
    for (size_t i = 0; i < n; i++) {
        Channel *c = channel_at(ps, (size_t)(monitors[i] >> 32), (uint32_t)monitors[i]);
        Fragment *f = fragments ? fragments[i] : NULL;
        if (!f || !c || !enqueue(c, f))
            fragment_free(f);
    }
    for (size_t i = 0; i < ps->nchannels; i++)
        if (ps->channels[i].used && ps->channels[i].receiver == p)
            channel_free(ps, &ps->channels[i]);
    park(ps, p, ENDED);
    pthread_mutex_unlock(&ps->lock);
    free(fragments);
    free(monitors);
    vm->isolate = NULL;
    vm_destroy(vm);
    pthread_mutex_lock(&ps->lock);
    p->vm = NULL;
    pthread_mutex_unlock(&ps->lock);
}

/* It starts as a program does (docs/design.md): the program's constants and the standard
   streams, then the port's run state, with its gensyms counted from a base of its own. */
static void *isolate_main(void *argument)
{
    Isolate *p = argument;
    Program *program = p->program;
    Isolates *ps = program->isolates;
    VM *vm = vm_create_context(program, CONTEXT_WORDS, CONTEXT_STACK);
    if (!vm) {
        fputs("shen-jit: an isolate cannot start: out of memory\n", stderr);
        pthread_mutex_lock(&ps->lock);
        p->state = ENDED;
        p->nmonitors = 0;
        fragment_free(p->argument);
        p->argument = NULL;
        pthread_mutex_unlock(&ps->lock);
        return NULL;
    }
    vm->isolate = p;
    vm->stress = program->owner->stress;
    vm->max_words = program->owner->max_words;
    thread_note_worker_stack(vm);
    pthread_mutex_lock(&ps->lock);
    p->vm = vm;
    vm_globals_commit(vm, ps->globals > program->nglobals ? ps->globals : program->nglobals);
    resume(ps, p);
    vm->epoch_seen = ps->epoch;
    if (p->kill_pending)
        attend(vm);
    pthread_mutex_unlock(&ps->lock);

    V reason = ps->normal, value = V_NIL;
    vm_root(vm, &reason);
    vm_root(vm, &value);
    for (size_t i = 0; i < ps->nconstants; i++) {
        V *slot = global_slot_new(vm, ps->constant_symbols[i]);
        if (slot)
            *slot = ps->constant_values[i];
    }
    V start = published_find(vm, "shen-jit.start-isolate", 22);
    V proc = start ? *cell_function(vm, symbol_cell(start)) : V_CLEARED;
    V base = fix((int64_t)p->gensym_base);
    bool ok = sj_init_host(vm) && is_proc(proc) && jit_call(vm, proc, 1, &base) != V_CLEARED;
    if (ok) {
        value = fragment_in(vm, p->argument);
        ok = value != V_CLEARED;
    }
    pthread_mutex_lock(&ps->lock);
    fragment_free(p->argument);
    p->argument = NULL;
    pthread_mutex_unlock(&ps->lock);
    if (ok)
        ok = jit_call(vm, p->entry, 1, &value) != V_CLEARED;
    if (!ok) {
        pthread_mutex_lock(&ps->lock);
        bool killed = p->killed;
        pthread_mutex_unlock(&ps->lock);
        if (killed) {
            reason = ps->killed;
        } else {
            sj_report(vm, "isolate");
            V text = vm->exception == V_NIL ? V_CLEARED : exception_message(vm, vm->exception);
            reason = text == V_CLEARED ? ps->ended : text;
        }
    }
    vm_unroot(vm, 2);
    isolate_end(p, reason);
    return NULL;
}

static bool start_thread(Isolate *p)
{
    pthread_attr_t attr;
    pthread_t id;
    if (pthread_attr_init(&attr) != 0)
        return false;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, C_STACK_BYTES);
#ifdef _WIN32
    bool ok = pthread_create(&id, &attr, isolate_main, p) == 0;
#else
    sigset_t block, mask;
    sigemptyset(&block);
    sigaddset(&block, SIGINT); /* a Ctrl-C is the builder's */
    pthread_sigmask(SIG_BLOCK, &block, &mask);
    bool ok = pthread_create(&id, &attr, isolate_main, p) == 0;
    pthread_sigmask(SIG_SETMASK, &mask, NULL);
#endif
    pthread_attr_destroy(&attr);
    return ok;
}

/* With the lock held: a record, an ended one's again if there is one. */
static Isolate *new_isolate(Isolates *ps, Program *program)
{
    Isolate *p = NULL;
    for (size_t i = 1; i < ps->n && !p; i++)
        if (ps->table[i]->state == ENDED && !ps->table[i]->vm && !ps->table[i]->argument)
            p = ps->table[i];
    if (p) {
        p->generation++;
    } else {
        if (ps->n == ps->cap) {
            Isolate **table = realloc(ps->table, 2 * ps->cap * sizeof *table);
            if (!table)
                return NULL;
            ps->table = table;
            ps->cap *= 2;
        }
        if (!(p = calloc(1, sizeof *p)))
            return NULL;
        pthread_cond_init(&p->wake, NULL);
        p->index = (uint32_t)ps->n;
        ps->table[ps->n++] = p;
    }
    p->program = program;
    p->vm = NULL;
    p->killed = p->kill_pending = p->ending = false;
    p->blocked = 0;
    p->nmonitors = 0;
    free(p->end_text);
    p->end_text = NULL;
    p->end_length = 0;
    p->end_symbol = V_CLEARED;
    p->state = STARTING;
    p->gensym_base = ++ps->spawned << 32;
    return p;
}

/* ---------------------------------------------------------------------------------------------
   The primitive: (shen-jit.isolate Op A B), which the port's shen-jit.spawn and the rest call. */

enum { OP_SPAWN, OP_CHANNEL, OP_SENDER, OP_SEND, OP_RECEIVE, OP_RECEIVE_ANY, OP_CLOSE, OP_GIVE, OP_MONITOR,
       OP_KILL, OP_SELF };

static V raise_copy(VM *vm, const char *error, V offender)
{
    return strstr(error, "~S") ? sj_raise_value(vm, error, offender) : sj_raise(vm, error);
}

static Isolate *isolate_at(Isolates *ps, V v)
{
    size_t index;
    uint32_t generation;
    if (!handle_of(v, ps->tag_isolate, &index, &generation) || index >= ps->n)
        return NULL;
    Isolate *p = ps->table[index];
    return p->generation == generation ? p : NULL;
}

static bool unary(VM *vm, V f)
{
    if (!is_proc(f) || !in_program(vm, ptr(f)))
        return false;
    if (hdr_type(ptr(f)[0]) == T_CLOSURE)
        return (ptr(ptr(f)[CLO_CODE])[CODE_ARITY] & UINT32_MAX) == 1;
    return hdr_type(ptr(f)[0]) == T_FOREIGN && ptr(f)[FOREIGN_ARITY] == 1;
}

static V spawn(VM *vm, Isolates *ps, V name, V argument)
{
    V f = is_symbol(name) && in_program(vm, ptr(name)) ? *cell_function(vm, symbol_cell(name)) : V_CLEARED;
    if (!unary(vm, f))
        return sj_raise_value(vm, "shen-jit.spawn: ~S is not a function of one argument that the builder defined",
                              name);
    const char *error = NULL;
    V offender = V_NIL;
    size_t *given = NULL, ngiven = 0;
    Fragment *fragment = fragment_out(vm, argument, true, &given, &ngiven, &error, &offender);
    if (!fragment)
        return raise_copy(vm, error, offender);
    pthread_mutex_lock(&ps->lock);
    for (size_t i = 0; i < ngiven; i++)
        if (given[i] >= ps->nchannels || !ps->channels[given[i]].used ||
            ps->channels[given[i]].receiver != vm->isolate) {
            pthread_mutex_unlock(&ps->lock);
            free(given);
            fragment_free(fragment);
            return sj_raise(vm, "shen-jit.give: only a channel's receiver can give it");
        }
    Isolate *p = new_isolate(ps, vm->program);
    if (p) {
        p->entry = f;
        p->argument = fragment;
        for (size_t i = 0; i < ngiven; i++)
            ps->channels[given[i]].receiver = p;
    }
    pthread_mutex_unlock(&ps->lock);
    if (p && start_thread(p)) {
        free(given);
        return handle(vm, ps->tag_isolate, p->index, p->generation);
    }
    pthread_mutex_lock(&ps->lock);
    if (p) {
        for (size_t i = 0; i < ngiven; i++)
            ps->channels[given[i]].receiver = vm->isolate;
        p->state = ENDED;
        p->argument = NULL;
    }
    pthread_mutex_unlock(&ps->lock);
    free(given);
    fragment_free(fragment);
    return sj_raise(vm, "shen-jit.spawn: cannot start a thread");
}

/* With the lock held, which it releases if it says so: a kill to raise now. */
static bool killed_now(VM *vm, Isolates *ps)
{
    if (!counted(vm) || !vm->isolate->kill_pending)
        return false;
    vm->isolate->kill_pending = false;
    pthread_mutex_unlock(&ps->lock);
    return true;
}

/* Marks the endpoints of a receive as waited on, or not. */
static void waiting(Isolates *ps, V endpoints, bool any, bool on)
{
    for (V l = endpoints; any ? is_pair(l) : l != V_NIL; l = any ? ptr(l)[1] : V_NIL) {
        size_t index;
        uint32_t generation;
        if (handle_of(any ? ptr(l)[0] : l, ps->tag_receiver, &index, &generation) &&
            channel_at(ps, index, generation))
            ps->channels[index].receiver_waiting = on;
    }
}

/* (shen-jit.receive R), or with `any`, (shen-jit.receive-any Rs), which gives [R Message]. */
static V receive(VM *vm, Isolates *ps, V endpoints, bool any)
{
    V from = V_NIL, got = V_NIL;
    vm_root(vm, &endpoints);
    vm_root(vm, &from);
    vm_root(vm, &got);
    const char *error = NULL;
    V offender = V_NIL;
    pthread_mutex_lock(&ps->lock);
    for (;;) {
        if (killed_now(vm, ps)) {
            error = "killed";
            break;
        }
        size_t n = 0;
        Channel *ready = NULL;
        for (V l = endpoints; !ready && (any ? is_pair(l) : n == 0); n++) {
            size_t index;
            uint32_t generation;
            from = any ? ptr(l)[0] : l;
            if (any)
                l = ptr(l)[1];
            if (!handle_of(from, ps->tag_receiver, &index, &generation)) {
                error = "shen-jit.receive: ~S is not a receive endpoint";
                offender = from;
                break;
            }
            Channel *c = channel_at(ps, index, generation);
            if (!c) {
                error = "channel closed";
                break;
            }
            if (c->receiver != vm->isolate) {
                error = "shen-jit.receive: ~S belongs to another isolate";
                offender = from;
                break;
            }
            if (c->count || c->closed)
                ready = c;
        }
        if (error) {
            pthread_mutex_unlock(&ps->lock);
            break;
        }
        if (ready && ready->count) {
            Fragment *f = dequeue(ready);
            pthread_mutex_unlock(&ps->lock);
            got = fragment_in(vm, f);
            fragment_free(f);
            break;
        }
        if (ready) {
            channel_free(ps, ready);
            pthread_mutex_unlock(&ps->lock);
            got = ps->end;
            break;
        }
        if (!n) {
            pthread_mutex_unlock(&ps->lock);
            error = "shen-jit.receive-any: no channels";
            break;
        }
        waiting(ps, endpoints, any, true);
        wait_turn(ps, vm);
        waiting(ps, endpoints, any, false);
    }
    V result = got;
    if (error) {
        result = offender == V_NIL ? sj_raise(vm, error) : sj_raise_value(vm, error, offender);
    } else if (got != V_CLEARED && any) {
        V tail = make_pair(vm, got, V_NIL);
        result = tail == V_CLEARED ? V_CLEARED : make_pair(vm, from, tail);
        if (result == V_CLEARED)
            result = sj_raise(vm, "out of memory");
    }
    vm_unroot(vm, 3);
    return result;
}

static V send(VM *vm, Isolates *ps, V sender, V v)
{
    size_t index;
    uint32_t generation;
    if (!handle_of(sender, ps->tag_sender, &index, &generation))
        return sj_raise_value(vm, "shen-jit.send: ~S is not a send endpoint", sender);
    const char *error = NULL;
    V offender = V_NIL;
    Fragment *f = fragment_out(vm, v, false, NULL, NULL, &error, &offender);
    if (!f)
        return raise_copy(vm, error, offender);
    pthread_mutex_lock(&ps->lock);
    for (;;) {
        Channel *c = channel_at(ps, index, generation);
        if (!c || c->closed) {
            error = "channel closed";
            break;
        }
        if (enqueue(c, f))
            break;
        if (killed_now(vm, ps)) {
            fragment_free(f);
            return sj_raise(vm, "killed");
        }
        bool listed = false;
        for (size_t i = 0; i < c->nsenders; i++)
            listed |= c->senders[i] == vm->isolate;
        if (!listed && c->nsenders == c->senders_cap) {
            size_t cap = c->senders_cap ? 2 * c->senders_cap : 4;
            Isolate **senders = realloc(c->senders, cap * sizeof *senders);
            if (!senders) {
                error = "out of memory";
                break;
            }
            c->senders = senders;
            c->senders_cap = cap;
        }
        if (!listed)
            c->senders[c->nsenders++] = vm->isolate;
        wait_turn(ps, vm);
    }
    pthread_mutex_unlock(&ps->lock);
    if (error) {
        fragment_free(f);
        return sj_raise(vm, error);
    }
    return v;
}

static V monitor(VM *vm, Isolates *ps, V isolate)
{
    pthread_mutex_lock(&ps->lock);
    Isolate *p = isolate_at(ps, isolate);
    size_t i = channel_new(ps, 1, vm->isolate);
    uint32_t generation = i == SIZE_MAX ? 0 : ps->channels[i].generation;
    bool ended = !p || p->state == ENDED || p->ending;
    /* One that has ended gives its reason, if its record says it, and otherwise ended. */
    V reason = ended && p && !p->end_text && p->end_symbol != V_CLEARED ? p->end_symbol : ps->ended;
    char *text = NULL;
    size_t length = ended && p && p->end_text ? p->end_length : 0;
    if (ended && p && p->end_text && (text = malloc(length ? length : 1)))
        memcpy(text, p->end_text, length);
    if (i != SIZE_MAX && !ended) {
        if (p->nmonitors == p->monitors_cap) {
            size_t cap = p->monitors_cap ? 2 * p->monitors_cap : 4;
            uint64_t *monitors = realloc(p->monitors, cap * sizeof *monitors);
            if (monitors) {
                p->monitors = monitors;
                p->monitors_cap = cap;
            }
        }
        if (p->nmonitors < p->monitors_cap)
            p->monitors[p->nmonitors++] = (uint64_t)i << 32 | generation;
        else
            ended = true; /* told at once rather than never */
    }
    pthread_mutex_unlock(&ps->lock);
    if (i == SIZE_MAX) {
        free(text);
        return sj_raise(vm, "out of memory");
    }
    V r = V_NIL;
    vm_root(vm, &isolate);
    vm_root(vm, &r);
    vm_root(vm, &reason);
    r = handle(vm, ps->tag_receiver, i, generation);
    if (ended && r != V_CLEARED && text && (reason = make_string(vm, text, length)) == V_CLEARED)
        reason = ps->ended;
    free(text);
    if (ended && r != V_CLEARED) { /* already over: down at once */
        V down = down_message(vm, ps, isolate, reason);
        Fragment *f = down == V_CLEARED ? NULL : message(vm, down);
        pthread_mutex_lock(&ps->lock);
        Channel *c = channel_at(ps, i, generation);
        if (!f || !c || !enqueue(c, f))
            fragment_free(f);
        pthread_mutex_unlock(&ps->lock);
    }
    vm_unroot(vm, 3);
    return r == V_CLEARED ? sj_raise(vm, "out of memory") : r;
}

V sj_isolate(VM *vm, V op, V a, V b)
{
    Isolates *ps = isolates_start(vm);
    if (!ps)
        return sj_raise(vm, "isolates start in the builder, and not beside threads or in a worker");
    size_t index;
    uint32_t generation;
    switch (is_fix(op) ? fixval(op) : -1) {
    case OP_SPAWN: return spawn(vm, ps, a, b);
    case OP_CHANNEL: {
        if (!is_fix(a) || fixval(a) < 1 || fixval(a) > (1 << 24))
            return sj_raise_value(vm, "shen-jit.channel: ~S is not a capacity from 1 to 2^24", a);
        pthread_mutex_lock(&ps->lock);
        size_t i = channel_new(ps, (size_t)fixval(a), vm->isolate);
        uint32_t g = i == SIZE_MAX ? 0 : ps->channels[i].generation;
        pthread_mutex_unlock(&ps->lock);
        return i == SIZE_MAX ? sj_raise(vm, "out of memory") : handle(vm, ps->tag_receiver, i, g);
    }
    case OP_SENDER:
    case OP_GIVE:
        if (!handle_of(a, ps->tag_receiver, &index, &generation))
            return sj_raise_value(vm, fixval(op) == OP_SENDER ? "shen-jit.sender: ~S is not a receive endpoint"
                                                              : "shen-jit.give: ~S is not a receive endpoint", a);
        return handle(vm, fixval(op) == OP_SENDER ? ps->tag_sender : ps->tag_given, index, generation);
    case OP_SEND: return send(vm, ps, a, b);
    case OP_RECEIVE: return receive(vm, ps, a, false);
    case OP_RECEIVE_ANY: return receive(vm, ps, a, true);
    case OP_CLOSE: {
        bool receiver = handle_of(a, ps->tag_receiver, &index, &generation);
        if (!receiver && !handle_of(a, ps->tag_sender, &index, &generation))
            return sj_raise_value(vm, "shen-jit.close: ~S is not an endpoint", a);
        pthread_mutex_lock(&ps->lock);
        Channel *c = channel_at(ps, index, generation);
        if (c && receiver && c->receiver != vm->isolate) {
            pthread_mutex_unlock(&ps->lock);
            return sj_raise_value(vm, "shen-jit.close: ~S belongs to another isolate", a);
        }
        if (c && receiver) {
            channel_free(ps, c);
        } else if (c && !c->closed) {
            c->closed = true;
            wake_senders(c);
            if (c->receiver_waiting)
                pthread_cond_signal(&c->receiver->wake);
        }
        pthread_mutex_unlock(&ps->lock);
        return a;
    }
    case OP_MONITOR: return monitor(vm, ps, a);
    case OP_KILL: {
        pthread_mutex_lock(&ps->lock);
        Isolate *p = isolate_at(ps, a);
        if (p && p != ps->table[0] && p->state != ENDED && !p->ending) {
            p->killed = p->kill_pending = true;
            if (p->vm)
                attend(p->vm);
            pthread_cond_signal(&p->wake);
        }
        pthread_mutex_unlock(&ps->lock);
        return a;
    }
    case OP_SELF: return handle(vm, ps->tag_isolate, vm->isolate->index, vm->isolate->generation);
    default: return sj_raise_value(vm, "shen-jit.isolate: ~S is not an operation", op);
    }
}

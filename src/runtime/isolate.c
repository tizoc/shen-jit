/* Isolates over one program (docs/design.md, "The builder and isolates"): each runs on an OS
   thread of its own, in a context of its own (a VM) over the builder's program, and they talk
   only through channels. A value crosses as a fragment: copied out of the sender's heap into
   blocks outside every heap, then into the receiver's, so no heap is read by two threads. What
   is in the program space crosses by pointer, symbols included, as every symbol is there once
   isolates exist (objects.c).

   The program does not change while isolates other than the builder run: defining refuses
   (loader.c), so they need no safe points. One lock, the isolates' lock, guards the tables of
   isolates and channels; each isolate waits on a condition of its own. The compile lock guards
   compiling at a first call and the JIT's tables, which every isolate uses. */
#define _DEFAULT_SOURCE
#include "vm.h"
#include "jit.h"
#include "ops.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef _WIN32
#include <sys/resource.h>
#endif

/* A fragment's blocks, and a new isolate's heap and stack, in words. Both grow as needed. */
enum { BLOCK_WORDS = 1 << 12, CONTEXT_WORDS = 1 << 14, CONTEXT_STACK = 1 << 12 };

/* ---------------------------------------------------------------------------------------------
   Fragments */

/* A block holds BLOCK_WORDS, or one object larger than that, alone and filling it: so an object of
   LARGE_WORDS or more, which is larger, always has a block of its own, which a heap can take. */
typedef struct {
    uint64_t *words; /* NULL once a heap has taken it */
    size_t used;
} Block;

typedef struct Fragment {
    Block *blocks;
    size_t nblocks, cap, words;
    V root;
} Fragment;

static void fragment_free(Fragment *f)
{
    if (!f)
        return;
    for (size_t i = 0; i < f->nblocks; i++)
        free(f->blocks[i].words);
    free(f->blocks);
    free(f);
}

static uint64_t *fragment_alloc(Fragment *f, size_t words)
{
    Block *b = f->nblocks ? &f->blocks[f->nblocks - 1] : NULL;
    if (!b || b->used + words > (b->used > BLOCK_WORDS ? b->used : BLOCK_WORDS)) {
        Block *blocks = grow_array(f->blocks, &f->cap, f->nblocks, sizeof *blocks, 8);
        if (!blocks)
            return NULL;
        f->blocks = blocks;
        uint64_t *words_at = malloc((words > BLOCK_WORDS ? words : BLOCK_WORDS) * sizeof(uint64_t));
        if (!words_at)
            return NULL;
        b = &f->blocks[f->nblocks++];
        *b = (Block){words_at, 0};
    }
    uint64_t *at = b->words + b->used;
    b->used += words;
    f->words += words;
    return at;
}

/* The objects of a fragment, in the order they were copied: a pair has no header. */
static size_t fragment_object_words(const uint64_t *s) { return is_header(*s) ? obj_words(*s) : 2; }


/* ---------------------------------------------------------------------------------------------
   Isolates and channels */

typedef struct Isolate {
    Program *program;
    VM *vm; /* while it runs */
    pthread_cond_t wake;
    uint32_t index, generation;
    bool ended; /* its function has returned or raised, or it could not start, and its monitors are told */
    bool killed;       /* for good, which its monitors are told */
    bool kill_pending; /* until its next channel operation raises it */
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
    Isolate **table; /* the builder's first */
    size_t n, cap;
    Channel *channels;
    size_t nchannels, channels_cap;
    size_t free_channel; /* the first free slot's index plus one, or 0 */
    size_t globals;      /* global slots every isolate has */
    uint64_t spawned;
    uint32_t seed; /* where generations start, so that an endpoint saved in an image matches nothing */
    V tag_isolate, tag_receiver, tag_sender, tag_given, end, down, normal, killed, ended;
    V start, ending, run, sweepers; /* the port's functions and global an isolate starts and ends with, found once */
    V constant_symbols[8], constant_values[8];
    size_t nconstants;
    size_t stress, max_words; /* the builder's settings, for every isolate, read here rather than in
                                 the builder's record, which it changes for a moment as it receives */
    const char *self;         /* the executable, beside which libraries are looked for too */
} Isolates;

/* The compile lock, recursive, as the builder may collect while it holds it. */
void program_compile_lock(VM *vm)
{
    if (vm->program->isolates)
        pthread_mutex_lock(&vm->program->isolates->compile);
}

void program_compile_unlock(VM *vm)
{
    if (vm->program->isolates)
        pthread_mutex_unlock(&vm->program->isolates->compile);
}

/* A new global number has a slot in every VM before any code can use it, the builder's
   included. Called with the lock that numbering takes (objects.c). */
bool isolates_commit_globals(Program *program, size_t n)
{
    Isolates *ps = program->isolates;
    if (!ps)
        return true;
    bool ok = true;
    pthread_mutex_lock(&ps->lock);
    for (size_t i = 0; i < ps->n; i++)
        if (ps->table[i]->vm && !ps->table[i]->ended)
            ok = vm_globals_commit(ps->table[i]->vm, n) && ok;
    if (ok && n > ps->globals)
        ps->globals = n;
    pthread_mutex_unlock(&ps->lock);
    return ok; /* if not, the global gets no number: a slot made in some is only room */
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
        any = !ps->table[i]->ended;
    pthread_mutex_unlock(&ps->lock);
    return any;
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

/* What a constructor made, or "out of memory" raised when it could not. */
static V made(VM *vm, V v) { return v == V_CLEARED ? sj_raise(vm, "out of memory") : v; }

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
    AddrMap map;
    bool spawn;
    const char *error;
    V offender;
    uint64_t *given; /* channels whose receive endpoints move, at spawn: index << 32 | generation */
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
    if (!addr_map_put(&o->map, (uintptr_t)ptr(v), copy))
        return out_fail(o, "out of memory", V_NIL);
    return copy;
}

static V out_value(Out *o, V v)
{
    if (o->error || !is_ptr(v))
        return v;
    if (v == o->ps->end)
        return out_fail(o, "the end of a stream cannot be sent", V_NIL);
    if (in_program(o->vm, ptr(v)))
        return v;
    V known = addr_map_get(&o->map, (uintptr_t)ptr(v));
    if (known)
        return known;
    if (is_pair(v))
        return out_copy(o, v, 2);
    if (is_proc(v))
        return out_fail(o, "~S cannot be sent: only the program's functions can", v);
    size_t index;
    uint32_t generation;
    switch (obj_type(v)) {
    case T_STRING:
    case T_FLOAT:
    case T_BYTES:
    case T_EXCEPTION: return out_copy(o, v, obj_words(ptr(v)[0]));
    case T_VECTOR:
        if (handle_of(v, o->ps->tag_receiver, &index, &generation))
            return out_fail(o, "~S can move only at spawn, through channel.give", v);
        if (handle_of(v, o->ps->tag_given, &index, &generation)) {
            if (!o->spawn)
                return out_fail(o, "~S can move only at spawn", v);
            uint64_t *given = grow_array(o->given, &o->given_cap, o->ngiven, sizeof *given, 4);
            if (!given)
                return out_fail(o, "out of memory", V_NIL);
            o->given = given;
            o->given[o->ngiven++] = (uint64_t)index << 32 | generation;
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
static Fragment *fragment_out(VM *vm, V v, bool spawn, uint64_t **given, size_t *ngiven, const char **error,
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
            for (size_t w = 0; w < f->blocks[b].used && !o.error;) {
                uint64_t *s = f->blocks[b].words + w;
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
    addr_map_free(&o.map);
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
   Copying in: a fragment into words laid out from `to`, as many as it has, breadth first: into
   this context's heap, with room for all of it made first, so that nothing moves while it is
   copied, or into the program space, shared, with its vectors and byte buffers marked so. The
   fragment is freed next, so a copied object is forwarded in it, as a collection forwards, rather
   than mapped. */

typedef struct {
    VM *vm;
    uint64_t *next;
    bool shared, adopt;
} In;

/* A large byte buffer or string, which has no values in it, in a block of its own (fragment_alloc),
   which a heap can take as it is. */
static bool adoptable(const uint64_t *o)
{
    return is_header(o[0]) && obj_words(o[0]) >= LARGE_WORDS &&
           (hdr_type(o[0]) == T_BYTES || hdr_type(o[0]) == T_STRING);
}

static V in_value(In *in, V v)
{
    if (!is_ptr(v) || in_program(in->vm, ptr(v)))
        return v;
    uint64_t *o = ptr(v);
    if (o[0] == V_FORWARD)
        return o[1];
    if (in->adopt && !is_pair(v) && adoptable(o)) /* taken by the heap, as it is */
        return v;
    size_t words = is_pair(v) ? 2 : obj_words(o[0]);
    uint64_t *q = in->next;
    in->next += words;
    memcpy(q, o, words * sizeof(uint64_t));
    if (in->shared && !is_pair(v) && (hdr_type(q[0]) == T_VECTOR || hdr_type(q[0]) == T_BYTES))
        q[0] |= SHARED_BIT;
    V copy = tagged(q, tag3(v));
    o[0] = V_FORWARD; /* every object has two words at least, as for a collection */
    o[1] = copy;
    return copy;
}

static V copy_fragment(VM *vm, Fragment *f, uint64_t *to, bool shared, bool adopt)
{
    In in = {vm, to, shared, adopt};
    for (size_t b = 0; adopt && b < f->nblocks; b++)
        if (adoptable(f->blocks[b].words)) {
            vm_adopt_large(vm, f->blocks[b].words, f->blocks[b].used);
            f->blocks[b].words = NULL; /* the heap's now, which fragment_free leaves */
        }
    V root = in_value(&in, f->root);
    for (uint64_t *s = to; s < in.next; s += fragment_object_words(s)) {
        if (is_header(*s)) {
            size_t first, count;
            obj_values(*s, &first, &count);
            for (size_t i = 0; i < count; i++)
                s[first + i] = in_value(&in, s[first + i]);
        } else {
            s[0] = in_value(&in, s[0]);
            s[1] = in_value(&in, s[1]);
        }
    }
    return root;
}

static V fragment_in(VM *vm, Fragment *f)
{
    if (!is_ptr(f->root) || in_program(vm, ptr(f->root)))
        return f->root;
    /* Large byte buffers and strings are taken as they are, and the rest copied. Room for both
       is made first, so that nothing collects once a block is taken: a collection would find it
       unreached and free it. */
    size_t large = 0, nlarge = 0;
    for (size_t b = 0; b < f->nblocks; b++)
        if (adoptable(f->blocks[b].words)) {
            large += f->blocks[b].used;
            nlarge++;
        }
    size_t words = f->words - large;
    V root = V_CLEARED;
    size_t stress = vm->stress;
    vm->stress = 0; /* the room made here is used here */
    if ((!nlarge || vm_large_room(vm, f->words, nlarge)) && /* the whole of it, under the heap's limit */
        ((size_t)(vm->hlimit - vm->hp) >= words || vm_collect(vm, words)) &&
        (size_t)(vm->hlimit - vm->hp) >= words) {
        uint64_t *start = vm->hp;
        vm->hp += words;
        root = copy_fragment(vm, f, start, false, true);
    }
    vm->stress = stress;
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
    if (vm->program->owner != vm)
        return NULL;
    /* Every symbol becomes the program's, and none is freed from now on: dead ones go first. */
    vm_collect(vm, 0);
    if (!program_publish_all(vm))
        return NULL;
    Isolates *ps = calloc(1, sizeof *ps);
    Isolate *self = calloc(1, sizeof *self);
    Isolate **table = malloc(16 * sizeof *table);
    if (!ps || !self || !table)
        goto fail;
    ps->stress = vm->stress;
    ps->max_words = vm->max_words;
    ps->self = vm->self;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    ps->seed = (uint32_t)now.tv_nsec ^ (uint32_t)now.tv_sec * 2654435761u ^ (uint32_t)((uintptr_t)ps >> 4);
    self->generation = ps->seed;
    ps->tag_isolate = publish(vm, "shen-jit.print-isolate");
    ps->tag_receiver = publish(vm, "shen-jit.print-receiver");
    ps->tag_sender = publish(vm, "shen-jit.print-sender");
    ps->tag_given = publish(vm, "shen-jit.print-given");
    ps->end = publish(vm, "shen-jit.end-of-stream");
    ps->down = publish(vm, "down");
    ps->normal = publish(vm, "normal");
    ps->killed = publish(vm, "killed");
    ps->ended = publish(vm, "ended");
    ps->start = published_find(vm, "shen-jit.start-isolate", 22);
    ps->ending = published_find(vm, "shen-jit.isolate-ending", 23);
    ps->run = published_find(vm, "shen-jit.run-at-end", 19);
    ps->sweepers = published_find(vm, "shen-jit.*guards-dead*", 22);
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
        ps->killed == V_CLEARED || ps->ended == V_CLEARED)
        goto fail;
    pthread_mutexattr_t recursive;
    pthread_mutexattr_init(&recursive);
    pthread_mutexattr_settype(&recursive, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&ps->compile, &recursive);
    pthread_mutexattr_destroy(&recursive);
    pthread_mutex_init(&ps->lock, NULL);
    pthread_cond_init(&self->wake, NULL);
    self->program = vm->program;
    self->vm = vm;
    table[0] = self;
    ps->table = table;
    ps->n = 1;
    ps->cap = 16;
    ps->globals = vm->program->nglobals;
    vm->isolate = self;
    vm->program->isolates = ps;
    return ps;
fail:
    free(ps);
    free(self);
    free(table);
    return NULL;
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
        Channel *channels = grow_array(ps->channels, &ps->channels_cap, ps->nchannels, sizeof *channels, 64);
        if (!channels) {
            free(queue);
            return SIZE_MAX;
        }
        ps->channels = channels;
        memset(&ps->channels[ps->nchannels], 0, sizeof(Channel));
        ps->channels[ps->nchannels++].generation = ps->seed;
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
   a program ends; one that ran would still use it, so then it is left to the system, and so is the
   program, which it runs: this says whether they can go. An isolate clears its VM under the lock as
   the last thing it does with any of this. */
bool isolates_free(Program *program)
{
    Isolates *ps = program->isolates;
    if (!ps)
        return true;
    pthread_mutex_lock(&ps->lock);
    bool running = false;
    for (size_t i = 1; i < ps->n; i++)
        running = running || ps->table[i]->vm || !ps->table[i]->ended;
    if (running) /* the builder's context goes, as an embedder may end it first: nothing must use it */
        ps->table[0]->vm = NULL;
    pthread_mutex_unlock(&ps->lock);
    if (running) {
        program->owner = NULL;
        return false;
    }
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
    return true;
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

/* [down P Reason], for the isolate of that index and generation, laid out as a copy would be, so
   that it is made with the lock held and no heap: Reason is the symbol given, or else the text, as
   a string. NULL without memory. */
static Fragment *down_fragment(Isolates *ps, size_t index, uint32_t generation, V symbol, const char *text,
                               size_t length)
{
    Fragment *f = calloc(1, sizeof *f);
    uint64_t h = HEADER(T_STRING, length);
    uint64_t *v = f ? fragment_alloc(f, 4) : NULL;
    uint64_t *s = v && text ? fragment_alloc(f, obj_words(h)) : NULL;
    uint64_t *c = v && (s || !text) ? fragment_alloc(f, 6) : NULL;
    if (!c) {
        fragment_free(f);
        return NULL;
    }
    v[0] = HEADER(T_VECTOR, 3);
    v[1] = ps->tag_isolate;
    v[2] = fix((int64_t)index);
    v[3] = fix((int64_t)generation);
    if (s) {
        s[0] = h;
        s[obj_words(h) - 1] = 0; /* the padding of the last word */
        memcpy(s + 1, text, length);
    }
    c[0] = ps->down;
    c[1] = tagged(c + 2, TAG_PAIR);
    c[2] = tagged(v, TAG_OBJECT);
    c[3] = tagged(c + 4, TAG_PAIR);
    c[4] = s ? tagged(s, TAG_OBJECT) : symbol;
    c[5] = V_NIL;
    f->root = tagged(c, TAG_PAIR);
    return f;
}

/* With the lock held: [down P Reason] from p's record, which keeps why it ended, or ended. */
static Fragment *down_of(Isolates *ps, Isolate *p)
{
    return down_fragment(ps, p->index, p->generation, p->end_symbol == V_CLEARED ? ps->ended : p->end_symbol,
                         p->end_text, p->end_length);
}

/* With the lock held: the monitors in m whose channels are still there, moved to its front, and
   how many; a monitor read and closed, as one each request of a server's makes, goes. */
static size_t live_monitors(Isolates *ps, uint64_t *m, size_t n)
{
    size_t kept = 0;
    for (size_t i = 0; i < n; i++)
        if (channel_at(ps, (size_t)(m[i] >> 32), (uint32_t)m[i]))
            m[kept++] = m[i];
    return kept;
}

/* With the lock held: no more is sent on c, which wakes what waits on it. */
static void close_sending(Channel *c)
{
    c->closed = true;
    wake_senders(c);
    if (c->receiver_waiting)
        pthread_cond_signal(&c->receiver->wake);
}

/* With the lock held: tells a monitor its down message, f, if one could be made, and closes it, so
   that what waits on it never waits for ever: a receive after its one message, or after none,
   raises channel closed. */
static void tell_monitor(Channel *c, Fragment *f)
{
    if (!f || !enqueue(c, f))
        fragment_free(f);
    close_sending(c);
}

/* ---------------------------------------------------------------------------------------------
   An isolate's life. */

/* With the lock held: p ends, having run or not. Its monitors are told why, from its record, and
   closed, the channels it receives on are freed, its argument goes, and it counts as ended, all in
   one hold of the lock, so that no monitor is told before, and one made later is told at once. */
static void end_now(Isolates *ps, Isolate *p)
{
    for (size_t i = 0; i < p->nmonitors; i++) {
        Channel *c = channel_at(ps, (size_t)(p->monitors[i] >> 32), (uint32_t)p->monitors[i]);
        if (c)
            tell_monitor(c, down_of(ps, p));
    }
    free(p->monitors);
    p->monitors = NULL;
    p->nmonitors = p->monitors_cap = 0;
    for (size_t i = 0; i < ps->nchannels; i++)
        if (ps->channels[i].used && ps->channels[i].receiver == p)
            channel_free(ps, &ps->channels[i]);
    fragment_free(p->argument);
    p->argument = NULL;
    p->ended = true;
}

/* It closes its files, keeps why it ended in its record, a symbol or an error's text, copied out
   of its heap, ends (end_now), and frees its context. */
static void isolate_end(Isolate *p, V reason)
{
    VM *vm = p->vm;
    Isolates *ps = vm->program->isolates;
    bool text = is_ptr(reason) && obj_type(reason) == T_STRING;
    size_t length = text ? string_length(reason) : 0;
    char *copy = text ? malloc(length ? length : 1) : NULL;
    if (copy)
        memcpy(copy, string_bytes(reason), length);
    for (size_t i = 0; i < vm->nfiles; i++)
        if (ptr(vm->files[i])[STREAM_FLAGS] & STREAM_OPEN) {
            fclose((FILE *)(uintptr_t)ptr(vm->files[i])[STREAM_HANDLE]);
            ptr(vm->files[i])[STREAM_FLAGS] &= ~(uint64_t)STREAM_OPEN;
        }
    pthread_mutex_lock(&ps->lock);
    p->end_symbol = text ? V_CLEARED : reason; /* ended, if the text could not be kept */
    p->end_text = copy;
    p->end_length = copy ? length : 0;
    end_now(ps, p);
    pthread_mutex_unlock(&ps->lock);
    vm->isolate = NULL;
    vm_destroy(vm);
    pthread_mutex_lock(&ps->lock);
    p->vm = NULL;
    pthread_mutex_unlock(&ps->lock);
}

/* Collections and releases, until a collection finds no guard dead, as a release may leave
   another unreached, or make one. Run releases what is on the dead list, through the functions in
   sweepers. What a collection during a release puts there waits for the next round; the batch
   they were given, if they left it there, is dropped, so that a sweeper that takes nothing ends
   the rounds. Before each collection, what a release left in the argument slots of a call to C,
   or the error it caught, is cleared, as it is dead. */
static void release_rounds(VM *vm, V run, V *sweepers)
{
    for (;;) {
        for (size_t i = 0; i < sizeof vm->args / sizeof vm->args[0]; i++)
            vm->args[i] = V_NIL;
        vm->exception = V_NIL;
        vm_collect(vm, 0);
        if (vm->dead == V_NIL)
            return;
        V batch = vm->dead;
        vm_root(vm, &batch);
        jit_call(vm, run, 1, sweepers);
        if (vm->dead == batch)
            vm->dead = V_NIL;
        vm_unroot(vm, 1);
    }
}

/* It starts as a program does (docs/design.md): the program's constants and the standard
   streams, then the port's run state, with its gensyms counted from a base of its own. */
static void *isolate_main(void *argument)
{
    Isolate *p = argument;
    Program *program = p->program;
    Isolates *ps = program->isolates;
    VM *vm = vm_create_context(program, CONTEXT_WORDS, CONTEXT_STACK);
    if (vm) {
        vm->isolate = p;
        vm->stress = ps->stress;
        vm->max_words = ps->max_words;
        vm->self = ps->self;
        vm_note_thread_stack(vm);
    }
    /* Its slots catch up with globals numbered since its context was made, under the lock under
       which another isolate numbering one commits a slot in every context listed. */
    pthread_mutex_lock(&ps->lock);
    size_t numbered = __atomic_load_n(&program->nglobals, __ATOMIC_ACQUIRE);
    if (!vm || !vm_globals_commit(vm, ps->globals > numbered ? ps->globals : numbered)) {
        /* Its context goes before it counts as ended, as what a monitor tells may let the builder
           end the program, which the context's end reads. */
        pthread_mutex_unlock(&ps->lock);
        if (vm) {
            vm->isolate = NULL;
            vm_destroy(vm);
        }
        pthread_mutex_lock(&ps->lock);
        end_now(ps, p); /* as one that ran, with nothing to say why: ended */
        pthread_mutex_unlock(&ps->lock);
        fputs("shen-jit: an isolate cannot start: out of memory\n", stderr);
        return NULL;
    }
    p->vm = vm;
    pthread_mutex_unlock(&ps->lock);

    V reason = ps->normal, value = V_NIL;
    vm_root(vm, &reason);
    vm_root(vm, &value);
    for (size_t i = 0; i < ps->nconstants; i++) {
        V *slot = global_slot_new(vm, ps->constant_symbols[i]);
        if (slot)
            *slot = ps->constant_values[i];
    }
    V proc = ps->start ? *cell_function(vm, symbol_cell(ps->start)) : V_CLEARED;
    V base = fix((int64_t)p->gensym_base);
    bool ok = sj_init_host(vm) && is_proc(proc) && jit_call(vm, proc, 1, &base) != V_CLEARED;
    if (ok) {
        value = fragment_in(vm, p->argument);
        ok = value != V_CLEARED;
    }
    /* A kill that came before it started is raised as any other: at its first channel operation
       or isolate.check-kill, so that what its argument holds, such as a socket, is cleaned up. */
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
    /* As it ends, what it registered with shen-jit.at-end runs, once. Then what its guards hold, as
       the handle library's handles, is released by what it registered with shen-jit.at-guards-dead,
       in rounds, as collections order them: a release may use another handle, which outlives it
       until that release has run. Only what dies is released, so in that order, with the globals
       a release may read still there: what its globals still hold is left to the system, as a
       program's is when it ends. What argument slots of calls to C and the error last caught hold
       is dead by then, and cleared before each round.
       Errors there are dropped, as nothing is left to tell. */
    V ending = ps->ending ? *cell_function(vm, symbol_cell(ps->ending)) : V_CLEARED;
    if (is_proc(ending))
        jit_call(vm, ending, 0, NULL);
    V run = ps->run ? *cell_function(vm, symbol_cell(ps->run)) : V_CLEARED;
    V sweepers = ps->sweepers ? global_value(vm, ps->sweepers) : V_CLEARED;
    if (is_proc(run) && is_pair(sweepers)) {
        vm_root(vm, &sweepers);
        value = V_NIL;
        release_rounds(vm, run, &sweepers);
        vm_unroot(vm, 1);
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
        if (ps->table[i]->ended && !ps->table[i]->vm && !ps->table[i]->argument)
            p = ps->table[i];
    if (p) {
        p->generation++;
    } else {
        Isolate **table = grow_array(ps->table, &ps->cap, ps->n, sizeof *table, 16);
        if (!table)
            return NULL;
        ps->table = table;
        if (!(p = calloc(1, sizeof *p)))
            return NULL;
        pthread_cond_init(&p->wake, NULL);
        p->index = (uint32_t)ps->n;
        p->generation = ps->seed;
        ps->table[ps->n++] = p;
    }
    p->program = program;
    p->vm = NULL;
    p->killed = p->kill_pending = false;
    p->nmonitors = 0;
    free(p->end_text);
    p->end_text = NULL;
    p->end_length = 0;
    p->end_symbol = V_CLEARED;
    p->ended = false;
    p->gensym_base = ++ps->spawned << 32;
    return p;
}

/* ---------------------------------------------------------------------------------------------
   The primitive: (shen-jit.isolate Op A B), which the port's isolate.spawn and the rest call. */

enum { OP_SPAWN, OP_CHANNEL, OP_SENDER, OP_SEND, OP_RECEIVE, OP_RECEIVE_ANY, OP_CLOSE, OP_GIVE, OP_MONITOR,
       OP_KILL, OP_SELF, OP_WAIT_ANY, OP_CHECK_KILL, OP_SHARE, OP_SINCE };

static V raise_copy(VM *vm, const char *error, V offender)
{
    return strstr(error, "~S") ? sj_raise_value(vm, error, offender) : sj_raise(vm, error);
}

static Isolate *isolate_numbered(Isolates *ps, size_t index, uint32_t generation)
{
    return index < ps->n && ps->table[index]->generation == generation ? ps->table[index] : NULL;
}

static Isolate *isolate_at(Isolates *ps, V v)
{
    size_t index;
    uint32_t generation;
    return handle_of(v, ps->tag_isolate, &index, &generation) ? isolate_numbered(ps, index, generation) : NULL;
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
        return sj_raise_value(vm, "isolate.spawn: ~S is not a function of one argument that the builder defined",
                              name);
    const char *error = NULL;
    V offender = V_NIL;
    uint64_t *given = NULL;
    size_t ngiven = 0;
    Fragment *fragment = fragment_out(vm, argument, true, &given, &ngiven, &error, &offender);
    if (!fragment)
        return raise_copy(vm, error, offender);
    pthread_mutex_lock(&ps->lock);
    for (size_t i = 0; i < ngiven; i++) {
        Channel *c = channel_at(ps, (size_t)(given[i] >> 32), (uint32_t)given[i]);
        if (!c || c->receiver != vm->isolate) {
            pthread_mutex_unlock(&ps->lock);
            free(given);
            fragment_free(fragment);
            return sj_raise(vm, "channel.give: only a channel's receiver can give it, while it is open");
        }
    }
    Isolate *p = new_isolate(ps, vm->program);
    uint32_t index = 0, generation = 0; /* taken now: one that ends at once can have its record reused */
    if (p) {
        p->entry = f;
        p->argument = fragment;
        index = p->index;
        generation = p->generation;
        for (size_t i = 0; i < ngiven; i++)
            ps->channels[given[i] >> 32].receiver = p;
    }
    pthread_mutex_unlock(&ps->lock);
    /* Its handle is made before it starts, so that nothing can fail once it runs: one that could
       not be given back would run with nothing to stop it, owning what its argument gave it. The
       record waits meanwhile, its argument keeping it from being used again. */
    V h = p ? handle(vm, ps->tag_isolate, index, generation) : V_CLEARED;
    if (h != V_CLEARED && start_thread(p)) {
        free(given);
        return h;
    }
    pthread_mutex_lock(&ps->lock);
    if (p) {
        for (size_t i = 0; i < ngiven; i++)
            ps->channels[given[i] >> 32].receiver = vm->isolate;
        p->ended = true;
        p->argument = NULL;
    }
    pthread_mutex_unlock(&ps->lock);
    free(given);
    fragment_free(fragment);
    return sj_raise(vm, p && h == V_CLEARED ? "out of memory" : "isolate.spawn: cannot start a thread");
}

/* The time ms milliseconds from now, as condition waits take it. */
static struct timespec after_ms(int64_t ms)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    t.tv_sec += ms / 1000;
    t.tv_nsec += ms % 1000 * 1000000;
    if (t.tv_nsec >= 1000000000) {
        t.tv_sec++;
        t.tv_nsec -= 1000000000;
    }
    return t;
}

/* With the lock held: waiting on its condition until woken, or until the time given. The builder
   waits in slices of 50 ms, as a Ctrl-C, which is its own, cannot wake it from a signal handler. 0
   when woken or between slices, ETIMEDOUT once the time has passed. */
static int wait_turn_until(Isolates *ps, VM *vm, const struct timespec *until)
{
    if (vm != vm->program->owner)
        return until ? pthread_cond_timedwait(&vm->isolate->wake, &ps->lock, until)
                     : pthread_cond_wait(&vm->isolate->wake, &ps->lock);
    struct timespec slice = after_ms(50);
    bool last = until && (until->tv_sec < slice.tv_sec || (until->tv_sec == slice.tv_sec && until->tv_nsec <= slice.tv_nsec));
    int waited = pthread_cond_timedwait(&vm->isolate->wake, &ps->lock, last ? until : &slice);
    return waited == ETIMEDOUT && !last ? 0 : waited;
}

/* With the lock held, which it releases if it gives one: "killed" or "interrupted", to raise now; a
   Ctrl-C is only the builder's. */
static const char *stopped(VM *vm, Isolates *ps)
{
    const char *why = NULL;
    if (vm->isolate->kill_pending) {
        vm->isolate->kill_pending = false;
        why = "killed";
    } else if (vm->interrupted == INTERRUPT && sj_take_interrupt(vm)) {
        why = "interrupted";
    }
    if (why)
        pthread_mutex_unlock(&ps->lock);
    return why;
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

/* Which operation reads endpoints, for its errors. */
enum { BY_RECEIVE, BY_RECEIVE_ANY, BY_WAIT_ANY };
static const char *const not_receive_endpoint[] = {"channel.receive: ~S is not a receive endpoint",
                                                   "channel.receive-any: ~S is not a receive endpoint",
                                                   "channel.wait-any: ~S is not a receive endpoint"};
static const char *const anothers[] = {"channel.receive: ~S belongs to another isolate",
                                       "channel.receive-any: ~S belongs to another isolate",
                                       "channel.wait-any: ~S belongs to another isolate"};

/* With the lock held: the first of the endpoints, a list of them unless by is BY_RECEIVE, that a
   receive would not wait on, as it has a message, is closed or has gone, in *found, and its
   channel, or NULL if it has gone; *found is V_NIL if none is. One that is not this isolate's
   receive endpoint is *found too, with *error saying so. */
static Channel *first_ready(Isolates *ps, VM *vm, V endpoints, int by, V *found, const char **error)
{
    *found = V_NIL;
    for (V l = endpoints;;) {
        V e = l;
        if (by != BY_RECEIVE) {
            if (!is_pair(l))
                return NULL;
            e = ptr(l)[0];
            l = ptr(l)[1];
        }
        size_t index;
        uint32_t generation;
        bool endpoint = handle_of(e, ps->tag_receiver, &index, &generation);
        Channel *c = endpoint ? channel_at(ps, index, generation) : NULL;
        if (!endpoint || (c && c->receiver != vm->isolate)) {
            *found = e;
            *error = c ? anothers[by] : not_receive_endpoint[by];
            return NULL;
        }
        if (!c || c->count || c->closed) {
            *found = e;
            return c;
        }
        if (by == BY_RECEIVE)
            return NULL;
    }
}

/* (channel.receive R), or with `any`, (channel.receive-any Rs), which gives [R Message]; at the end of
   a stream, shen-jit.end-of-stream, which the port turns into what each gives then. */
static V receive(VM *vm, Isolates *ps, V endpoints, bool any)
{
    V from = V_NIL, got = V_NIL;
    vm_root(vm, &endpoints);
    vm_root(vm, &from);
    vm_root(vm, &got);
    const char *error = NULL;
    pthread_mutex_lock(&ps->lock);
    for (;;) {
        if ((error = stopped(vm, ps)))
            break;
        Channel *ready = first_ready(ps, vm, endpoints, any ? BY_RECEIVE_ANY : BY_RECEIVE, &from, &error);
        if (!error && from != V_NIL && !ready)
            error = "channel closed";
        if (!error && any && !is_pair(endpoints))
            error = "channel.receive-any: no channels";
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
        waiting(ps, endpoints, any, true);
        wait_turn_until(ps, vm, NULL);
        waiting(ps, endpoints, any, false);
    }
    V result = got;
    if (error) {
        result = raise_copy(vm, error, from);
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
        return sj_raise_value(vm, "channel.send: ~S is not a send endpoint", sender);
    const char *error = NULL;
    V offender = V_NIL;
    Fragment *f = fragment_out(vm, v, false, NULL, NULL, &error, &offender);
    if (!f)
        return raise_copy(vm, error, offender);
    pthread_mutex_lock(&ps->lock);
    for (;;) {
        const char *why = stopped(vm, ps);
        if (why) {
            fragment_free(f);
            return sj_raise(vm, why);
        }
        Channel *c = channel_at(ps, index, generation);
        if (!c || c->closed) {
            error = "channel closed";
            break;
        }
        if (enqueue(c, f))
            break;
        bool listed = false;
        for (size_t i = 0; i < c->nsenders; i++)
            listed |= c->senders[i] == vm->isolate;
        if (!listed) {
            Isolate **senders = grow_array(c->senders, &c->senders_cap, c->nsenders, sizeof *senders, 4);
            if (!senders) {
                error = "out of memory";
                break;
            }
            c->senders = senders;
            c->senders[c->nsenders++] = vm->isolate;
        }
        wait_turn_until(ps, vm, NULL);
    }
    pthread_mutex_unlock(&ps->lock);
    if (error) {
        fragment_free(f);
        return sj_raise(vm, error);
    }
    return v;
}

/* A channel this isolate receives on: its receive endpoint, or V_CLEARED, with nothing left of it,
   without memory. */
static V new_receiver(VM *vm, Isolates *ps, size_t capacity)
{
    pthread_mutex_lock(&ps->lock);
    size_t i = channel_new(ps, capacity, vm->isolate);
    uint32_t g = i == SIZE_MAX ? 0 : ps->channels[i].generation;
    pthread_mutex_unlock(&ps->lock);
    V r = i == SIZE_MAX ? V_CLEARED : handle(vm, ps->tag_receiver, i, g);
    if (r == V_CLEARED && i != SIZE_MAX) { /* no endpoint reaches it */
        pthread_mutex_lock(&ps->lock);
        Channel *c = channel_at(ps, i, g);
        if (c)
            channel_free(ps, c);
        pthread_mutex_unlock(&ps->lock);
    }
    return r;
}

/* A monitor: listed to be told when the isolate ends (end_now), or, as it has, told at once, with
   why if its record still says, and otherwise ended. The isolate is found by the number its handle
   gave, as making the endpoint may move the handle; nothing allocates in the heap after that. */
static V monitor(VM *vm, Isolates *ps, V isolate)
{
    size_t index;
    uint32_t generation;
    if (!handle_of(isolate, ps->tag_isolate, &index, &generation))
        return sj_raise_value(vm, "isolate.monitor: ~S is not an isolate", isolate);
    V r = new_receiver(vm, ps, 1);
    if (r == V_CLEARED)
        return sj_raise(vm, "out of memory");
    size_t i = (size_t)fixval(ptr(r)[2]);
    uint32_t g = (uint32_t)fixval(ptr(r)[3]);
    pthread_mutex_lock(&ps->lock);
    Channel *c = channel_at(ps, i, g);
    Isolate *p = isolate_numbered(ps, index, generation);
    bool listed = true;
    if (p && !p->ended) {
        if (p->nmonitors == p->monitors_cap)
            p->nmonitors = live_monitors(ps, p->monitors, p->nmonitors);
        uint64_t *monitors = grow_array(p->monitors, &p->monitors_cap, p->nmonitors, sizeof *monitors, 4);
        if (monitors) {
            p->monitors = monitors;
            p->monitors[p->nmonitors++] = (uint64_t)i << 32 | g;
        } else { /* not told at all, nor told while it runs: no monitor */
            channel_free(ps, c);
            listed = false;
        }
    } else {
        tell_monitor(c, p ? down_of(ps, p) : down_fragment(ps, index, generation, ps->ended, NULL, 0));
    }
    pthread_mutex_unlock(&ps->lock);
    return listed ? r : sj_raise(vm, "out of memory");
}

/* (isolate.share V): a copy of V in the program space, which crosses to any isolate by pointer,
   and which nothing changes, as stores refuse its vectors and byte buffers; it is never freed. */
static V share(VM *vm, V v)
{
    const char *error = NULL;
    V offender = V_NIL;
    Fragment *f = fragment_out(vm, v, false, NULL, NULL, &error, &offender);
    if (!f)
        return raise_copy(vm, error, offender);
    V root = f->root;
    if (is_ptr(root) && !in_program(vm, ptr(root))) {
        /* Under the lock that guards the program space while isolates make symbols there, until
           what it takes is whole, as a save or the REPL's walk reads the space under it. */
        program_shared_lock();
        uint64_t *to = program_alloc(vm, f->words);
        root = to ? copy_fragment(vm, f, to, true, false) : V_CLEARED;
        program_shared_unlock();
    }
    fragment_free(f);
    return root == V_CLEARED ? sj_raise(vm, "out of memory") : root;
}

/* (channel.wait-any Rs Ms): the first of the receive endpoints Rs that a receive would not wait
   on, as it has a message or is closed, after at most Ms milliseconds, or () if none is by then.
   It receives nothing. */
static V wait_any(VM *vm, Isolates *ps, V endpoints, V ms)
{
    if (!is_fix(ms) || fixval(ms) < 0 || fixval(ms) > 86400000)
        return sj_raise_value(vm, "channel.wait-any: ~S is not a number of milliseconds up to a day", ms);
    struct timespec until = after_ms(fixval(ms));
    const char *error = NULL;
    V found = V_NIL;
    pthread_mutex_lock(&ps->lock);
    for (bool late = false;; late = true) {
        const char *why = stopped(vm, ps);
        if (why)
            return sj_raise(vm, why);
        first_ready(ps, vm, endpoints, BY_WAIT_ANY, &found, &error);
        if (found != V_NIL || late || fixval(ms) == 0)
            break;
        waiting(ps, endpoints, true, true);
        int waited = 0;
        const char *later = NULL;
        V seen = V_NIL;
        while (waited == 0 && !vm->isolate->kill_pending && vm->interrupted != INTERRUPT &&
               (first_ready(ps, vm, endpoints, BY_WAIT_ANY, &seen, &later), seen == V_NIL))
            waited = wait_turn_until(ps, vm, &until);
        waiting(ps, endpoints, true, false);
    }
    pthread_mutex_unlock(&ps->lock);
    return error ? sj_raise_value(vm, error, found) : found;
}

/* With the lock held: marks an isolate killed, but not the builder or one that has ended, and wakes
   it if it waits on a channel. */
static void kill_isolate(Isolates *ps, Isolate *p)
{
    if (p && p != ps->table[0] && !p->ended) {
        p->killed = p->kill_pending = true;
        pthread_cond_signal(&p->wake);
    }
}

/* Whether a kill came, which the caller then raises: what waits on something else, such as a
   socket or standard input, asks now and then. It does not start isolates. */
bool sj_isolate_killed(VM *vm)
{
    Isolates *ps = vm->program->isolates;
    if (!ps || !vm->isolate)
        return false;
    pthread_mutex_lock(&ps->lock);
    bool killed = vm->isolate->kill_pending;
    vm->isolate->kill_pending = false;
    pthread_mutex_unlock(&ps->lock);
    return killed;
}

V sj_isolate(VM *vm)
{
    if (vm->args[0] == fix(OP_CHECK_KILL))
        return sj_isolate_killed(vm) ? sj_raise(vm, "killed") : V_FALSE;
    /* The REPL marks each input with how many isolates had been spawned, and after a Ctrl-C kills
       those spawned since, but not the caller; neither starts isolates. */
    if (vm->args[0] == fix(OP_SINCE)) {
        Isolates *ps = vm->program->isolates;
        V mark = vm->args[1];
        if (!ps)
            return fix(0);
        pthread_mutex_lock(&ps->lock);
        for (size_t i = 1; is_fix(mark) && i < ps->n; i++)
            if (ps->table[i] != vm->isolate && (ps->table[i]->gensym_base >> 32) > (uint64_t)fixval(mark))
                kill_isolate(ps, ps->table[i]);
        uint64_t spawned = ps->spawned;
        pthread_mutex_unlock(&ps->lock);
        return fix((int64_t)spawned);
    }
    Isolates *ps = isolates_start(vm);
    if (!ps)
        return sj_raise(vm, vm_is_builder(vm) ? "out of memory" : "isolates start in the builder");
    V op = vm->args[0], a = vm->args[1], b = vm->args[2]; /* the first use may have collected */
    size_t index;
    uint32_t generation;
    switch (is_fix(op) ? fixval(op) : -1) {
    case OP_SPAWN: return spawn(vm, ps, a, b);
    case OP_CHANNEL: {
        if (!is_fix(a) || fixval(a) < 1 || fixval(a) > (1 << 24))
            return sj_raise_value(vm, "channel.new: ~S is not a capacity from 1 to 2^24", a);
        return made(vm, new_receiver(vm, ps, (size_t)fixval(a)));
    }
    case OP_SENDER:
    case OP_GIVE:
        if (!handle_of(a, ps->tag_receiver, &index, &generation))
            return sj_raise_value(vm, fixval(op) == OP_SENDER ? "channel.sender: ~S is not a receive endpoint"
                                                              : "channel.give: ~S is not a receive endpoint", a);
        return made(vm, handle(vm, fixval(op) == OP_SENDER ? ps->tag_sender : ps->tag_given, index, generation));
    case OP_SEND: return send(vm, ps, a, b);
    case OP_RECEIVE: return receive(vm, ps, a, false);
    case OP_RECEIVE_ANY: return receive(vm, ps, a, true);
    case OP_CLOSE: {
        bool receiver = handle_of(a, ps->tag_receiver, &index, &generation);
        if (!receiver && !handle_of(a, ps->tag_sender, &index, &generation))
            return sj_raise_value(vm, "channel.close: ~S is not an endpoint", a);
        pthread_mutex_lock(&ps->lock);
        Channel *c = channel_at(ps, index, generation);
        if (c && receiver && c->receiver != vm->isolate) {
            pthread_mutex_unlock(&ps->lock);
            return sj_raise_value(vm, "channel.close: ~S belongs to another isolate", a);
        }
        if (c && receiver)
            channel_free(ps, c);
        else if (c && !c->closed)
            close_sending(c);
        pthread_mutex_unlock(&ps->lock);
        return a;
    }
    case OP_MONITOR: return monitor(vm, ps, a);
    case OP_KILL:
        pthread_mutex_lock(&ps->lock);
        kill_isolate(ps, isolate_at(ps, a));
        pthread_mutex_unlock(&ps->lock);
        return a;
    case OP_SELF: return made(vm, handle(vm, ps->tag_isolate, vm->isolate->index, vm->isolate->generation));
    case OP_WAIT_ANY: return wait_any(vm, ps, a, b);
    case OP_SHARE: return share(vm, a);
    default: return sj_raise_value(vm, "shen-jit.isolate: ~S is not an operation", op);
    }
}

/* ---------------------------------------------------------------------------------------------
   OS threads and the end of the program. */

enum { C_STACK_MARGIN = 256 * 1024 }; /* for what runs past the check on a nested call */

/* Where nested calls stop on a C stack of this size, seen from near its base. */
static uintptr_t c_stack_limit(size_t bytes)
{
    char here;
    return (uintptr_t)&here - bytes + C_STACK_MARGIN;
}

/* The main thread's stack: what the system gives it, with the linker's choice on Windows
   (Makefile). */
void vm_note_main_stack(VM *vm)
{
    size_t bytes = C_STACK_BYTES;
#ifndef _WIN32
    struct rlimit limit;
    if (getrlimit(RLIMIT_STACK, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY)
        bytes = (size_t)limit.rlim_cur;
#endif
    vm->c_stack_limit = bytes > C_STACK_MARGIN ? c_stack_limit(bytes) : 0;
}

void vm_note_thread_stack(VM *vm)
{
    vm->c_stack_limit = c_stack_limit(C_STACK_BYTES);
}

/* Reports for the end of the program, SHEN_JIT_STATS's and the profiler's: at exit, and from
   program_exit, whose _exit skips what atexit registers. */
static void (*reports[4])(void);
static size_t nreports;

/* The first exit takes this and keeps it until the process ends, so that another, from an isolate
   ending the program at once, waits for it rather than running the reports too. */
static pthread_mutex_t exit_lock = PTHREAD_MUTEX_INITIALIZER;

static void reports_run(void)
{
    while (nreports)
        reports[--nreports]();
}

static void run_reports(void)
{
    pthread_mutex_lock(&exit_lock);
    reports_run();
}

void at_program_exit(void (*report)(void))
{
    if (nreports == sizeof reports / sizeof reports[0])
        return;
    if (!nreports)
        atexit(run_reports);
    reports[nreports++] = report;
}

static VM *exiting;

/* The VM that ended the program, if one did through program_exit, for reports that must not
   touch another's heap while it may run. */
VM *program_exiting(void) { return exiting; }

/* Ends the program while isolates may run. exit would flush every stream, waiting on any that
   another isolate is blocked reading, so this flushes what this one wrote and goes. */
void program_exit(VM *vm, int status)
{
    pthread_mutex_lock(&exit_lock);
    exiting = vm;
    reports_run();
    fflush(stdout);
    fflush(stderr);
    for (size_t i = 0; i < vm->nfiles; i++) {
        uint64_t *o = ptr(vm->files[i]);
        if ((o[STREAM_FLAGS] & STREAM_OPEN) && (o[STREAM_FLAGS] & STREAM_OUTPUT))
            fflush((FILE *)(uintptr_t)o[STREAM_HANDLE]);
    }
    _exit(status);
}

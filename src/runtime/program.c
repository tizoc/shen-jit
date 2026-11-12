/* The program space (vm.h): a range of reserved address space, committed as it fills, that
   collections neither copy nor scan. Its start holds every symbol, in slots of SYM_WORDS that
   never move; a collection frees those of symbols that are not published and that nothing
   needs (heap.c). After them come the installed definitions: a definition is copied here when
   it is installed, with everything it reaches, and stays for good. So a collection stops
   copying the program, and none of it ever points into the heap. */
#define _DEFAULT_SOURCE /* MAP_ANON under -std=c11 with glibc */
#include "vm.h"

#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <sys/mman.h>
#endif

#define PROGRAM_BYTES ((size_t)8 << 30) /* reserved: an eighth for symbols, the rest for objects */
#define LEAST_BYTES ((size_t)64 << 20)
#define COMMIT_WORDS ((size_t)1 << 17) /* 1 MiB at a time */

static void *reserve(size_t bytes)
{
#ifdef _WIN32
    return win_reserve(bytes);
#else
    void *p = mmap(NULL, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
#endif
}

static bool commit(uint64_t *at, size_t words)
{
#ifdef _WIN32
    return win_commit(at, words * sizeof(uint64_t));
#else
    return mprotect(at, words * sizeof(uint64_t), PROT_READ | PROT_WRITE) == 0;
#endif
}

bool program_init(Space *p)
{
    memset(p, 0, sizeof *p);
    for (size_t bytes = PROGRAM_BYTES; bytes >= LEAST_BYTES; bytes /= 2)
        if ((p->base = reserve(bytes))) {
            p->bytes = bytes;
            p->objects = p->base + bytes / 8 / sizeof(uint64_t);
            p->end = p->base + bytes / sizeof(uint64_t);
            p->symbols_next = p->symbols_committed = p->base;
            p->objects_next = p->objects_committed = p->objects;
            return true;
        }
    return false;
}

void program_release(Space *p)
{
    if (!p->base)
        return;
#ifdef _WIN32
    win_release(p->base);
#else
    munmap(p->base, p->bytes);
#endif
    p->base = NULL;
    p->bytes = 0;
}

/* Commits up to `want`, which must lie before `limit`, in whole chunks where it can. */
static bool commit_to(uint64_t **committed, uint64_t *want, uint64_t *limit)
{
    if (want <= *committed)
        return true;
    if (want > limit)
        return false;
    size_t words = (size_t)(want - *committed);
    words = (words + COMMIT_WORDS - 1) / COMMIT_WORDS * COMMIT_WORDS;
    if (words > (size_t)(limit - *committed))
        words = (size_t)(limit - *committed);
    if (!commit(*committed, words))
        return false;
    *committed += words;
    return true;
}

uint64_t *program_alloc(VM *vm, size_t words)
{
    Space *p = &vm->program->space;
    if (words > (size_t)(p->end - p->objects_next) ||
        !commit_to(&p->objects_committed, p->objects_next + words, p->end))
        return NULL;
    uint64_t *at = p->objects_next;
    p->objects_next += words;
    return at;
}

/* A free slot holds 0, then the next free slot's index plus one. */
uint64_t *program_symbol_slot(VM *vm)
{
    Space *p = &vm->program->space;
    if (p->free_symbol) {
        uint64_t *slot = p->base + (p->free_symbol - 1) * SYM_WORDS;
        p->free_symbol = (size_t)slot[1];
        return slot;
    }
    if (SYM_WORDS > (size_t)(p->objects - p->symbols_next) ||
        !commit_to(&p->symbols_committed, p->symbols_next + SYM_WORDS, p->objects))
        return NULL;
    uint64_t *slot = p->symbols_next;
    p->symbols_next += SYM_WORDS;
    return slot;
}

void program_free_symbol(VM *vm, uint64_t *slot)
{
    Space *p = &vm->program->space;
    slot[0] = 0;
    slot[1] = p->free_symbol;
    slot[2] = slot[3] = 0;
    p->free_symbol = (size_t)(slot - p->base) / SYM_WORDS + 1;
}

/* For an image: room for what it holds, used. */
bool program_reserve(VM *vm, size_t symbol_words, size_t object_words)
{
    Space *p = &vm->program->space;
    if (!commit_to(&p->symbols_committed, p->base + symbol_words, p->objects) ||
        !commit_to(&p->objects_committed, p->objects + object_words, p->end))
        return false;
    p->symbols_next = p->base + symbol_words;
    p->objects_next = p->objects + object_words;
    return true;
}

/* A published symbol is never dropped, so its name moves here, where nothing points into
   the heap. */
bool program_publish(VM *vm, V sym)
{
    uint64_t *s = ptr(sym);
    if (symbol_published(sym))
        return true;
    V name = s[SYM_NAME];
    if (!in_program(vm, ptr(name))) {
        size_t words = obj_words(ptr(name)[0]);
        uint64_t *q = program_alloc(vm, words);
        if (!q)
            return false;
        memcpy(q, ptr(name), words * sizeof(uint64_t));
        s[SYM_NAME] = tagged(q, TAG_OBJECT);
    }
    if (!symbol_table_put(&vm->program->published, sym))
        return false;
    s[SYM_CELL] = (s[SYM_CELL] & ~(UINT64_C(1) << MARK_BIT)) | UINT64_C(1) << PUBLISHED_BIT;
    if (symbol_cell(sym) >= vm->program->published_top)
        vm->program->published_top = symbol_cell(sym) + 1;
    if (symbol_global(sym) >= vm->program->published_global_top)
        vm->program->published_global_top = symbol_global(sym) + 1;
    return true;
}

/* Promotion: what a definition reaches is copied into the program space, each object once,
   with a table from the old address to the copy, so that sharing is kept. Only what cannot
   change is copied: pairs, strings, reals, code with its bytecode and constant slots, and the
   definition's closure, which captures nothing. A definition that reaches anything else stays
   in the heap, as before. Nothing here allocates in the heap, so nothing moves meanwhile. */
typedef struct {
    VM *vm;
    uintptr_t *keys;
    V *values;
    size_t cap, n;
    size_t *ranges; /* constant slots of code copied: start and length, in pairs */
    size_t nranges, ranges_cap;
    /* What each slot held before it got a copy, to put back if the promotion fails: a slot
       left with a copy would be cleared once the original code, which owns it, is dead. */
    size_t *undo_slot;
    V *undo_value;
    size_t nundo, undo_cap;
    uint64_t **codes; /* the code objects copied, which name no slots if it fails */
    size_t ncodes, codes_cap;
    bool failed;
} Promote;

static size_t moved_index(const Promote *pr, uintptr_t key)
{
    return (size_t)((key >> 3) * 0x9E3779B97F4A7C15u) & (pr->cap - 1);
}

static V moved_get(const Promote *pr, uintptr_t key)
{
    if (!pr->cap)
        return 0;
    for (size_t i = moved_index(pr, key);; i = (i + 1) & (pr->cap - 1)) {
        if (!pr->keys[i])
            return 0;
        if (pr->keys[i] == key)
            return pr->values[i];
    }
}

static bool moved_put(Promote *pr, uintptr_t key, V value)
{
    if (2 * (pr->n + 1) > pr->cap) {
        size_t cap = pr->cap ? 2 * pr->cap : 256;
        uintptr_t *keys = calloc(cap, sizeof *keys);
        V *values = malloc(cap * sizeof *values);
        if (!keys || !values) {
            free(keys);
            free(values);
            return false;
        }
        Promote grown = {.vm = pr->vm, .keys = keys, .values = values, .cap = cap};
        for (size_t i = 0; i < pr->cap; i++)
            if (pr->keys[i])
                moved_put(&grown, pr->keys[i], pr->values[i]);
        free(pr->keys);
        free(pr->values);
        pr->keys = keys;
        pr->values = values;
        pr->cap = cap;
    }
    size_t i = moved_index(pr, key);
    while (pr->keys[i])
        i = (i + 1) & (pr->cap - 1);
    pr->keys[i] = key;
    pr->values[i] = value;
    pr->n++;
    return true;
}

static V fail_promotion(Promote *pr)
{
    pr->failed = true;
    return V_CLEARED;
}

static V promote(Promote *pr, V v);

/* A list's spine is copied in a loop, so a long list takes no C stack. */
static V promote_pair(Promote *pr, V v)
{
    V first = V_CLEARED;
    uint64_t *last = NULL;
    while (is_pair(v) && !in_program(pr->vm, ptr(v))) {
        V known = moved_get(pr, (uintptr_t)ptr(v));
        if (known)
            break;
        uint64_t *q = program_alloc(pr->vm, 2);
        if (!q || !moved_put(pr, (uintptr_t)ptr(v), tagged(q, TAG_PAIR)))
            return fail_promotion(pr);
        q[0] = q[1] = V_NIL;
        if (last)
            last[1] = tagged(q, TAG_PAIR);
        else
            first = tagged(q, TAG_PAIR);
        last = q;
        q[0] = promote(pr, ptr(v)[0]);
        if (pr->failed)
            return V_CLEARED;
        v = ptr(v)[1];
    }
    V tail = promote(pr, v);
    if (!last)
        return tail;
    last[1] = tail;
    return first;
}

static uint64_t *copy_object(Promote *pr, V v)
{
    size_t words = obj_words(ptr(v)[0]);
    uint64_t *q = program_alloc(pr->vm, words);
    if (!q || !moved_put(pr, (uintptr_t)ptr(v), tagged(q, tag3(v)))) {
        pr->failed = true;
        return NULL;
    }
    memcpy(q, ptr(v), words * sizeof(uint64_t));
    return q;
}

static V promote_code(Promote *pr, V v)
{
    VM *vm = pr->vm;
    uint64_t *p = ptr(v);
    /* Native code belongs to the object it was compiled for, which a collection may free. */
    if (p[CODE_NATIVE] || !is_object(p[CODE_BYTECODE]) || obj_type(p[CODE_BYTECODE]) != T_BYTES)
        return fail_promotion(pr);
    uint64_t *q = copy_object(pr, v);
    if (!q)
        return V_CLEARED;
    if (pr->ncodes == pr->codes_cap) {
        size_t cap = pr->codes_cap ? 2 * pr->codes_cap : 16;
        uint64_t **codes = realloc(pr->codes, cap * sizeof *codes);
        if (!codes) {
            q[CODE_NCONST] = q[CODE_NCODE] = 0;
            return fail_promotion(pr);
        }
        pr->codes = codes;
        pr->codes_cap = cap;
    }
    pr->codes[pr->ncodes++] = q;
    uint64_t *bytecode = copy_object(pr, p[CODE_BYTECODE]);
    if (!bytecode)
        return V_CLEARED;
    q[CODE_BYTECODE] = tagged(bytecode, TAG_OBJECT);
    q[CODE_NAME] = promote(pr, p[CODE_NAME]);
    q[CODE_INLINE] = promote(pr, p[CODE_INLINE]);
    /* The constant slots are shared with the original, which goes once nothing reaches it:
       they get the copies of their values, and once all is copied they belong to the program. */
    size_t base = (size_t)q[CODE_CBASE], n = (size_t)(q[CODE_NCONST] + q[CODE_NCODE]);
    for (size_t i = 0; i < n && !pr->failed; i++) {
        V *slot = ra_at(&vm->program->consts, base + i);
        V copy = promote(pr, *slot);
        if (pr->failed || copy == *slot)
            continue;
        if (pr->nundo == pr->undo_cap) {
            size_t cap = pr->undo_cap ? 2 * pr->undo_cap : 64;
            size_t *slots = realloc(pr->undo_slot, cap * sizeof *slots);
            if (slots)
                pr->undo_slot = slots;
            V *values = slots ? realloc(pr->undo_value, cap * sizeof *values) : NULL;
            if (!values)
                return fail_promotion(pr);
            pr->undo_value = values;
            pr->undo_cap = cap;
        }
        pr->undo_slot[pr->nundo] = base + i;
        pr->undo_value[pr->nundo++] = *slot;
        *slot = copy;
    }
    if (n) {
        if (pr->nranges + 2 > pr->ranges_cap) {
            size_t cap = pr->ranges_cap ? 2 * pr->ranges_cap : 32;
            size_t *ranges = realloc(pr->ranges, cap * sizeof *ranges);
            if (!ranges)
                return fail_promotion(pr);
            pr->ranges = ranges;
            pr->ranges_cap = cap;
        }
        pr->ranges[pr->nranges++] = base;
        pr->ranges[pr->nranges++] = n;
    }
    return tagged(q, TAG_OBJECT);
}

static V promote(Promote *pr, V v)
{
    if (pr->failed || !is_ptr(v))
        return v;
    if (in_program(pr->vm, ptr(v))) {
        if (is_symbol(v) && !program_publish(pr->vm, v))
            return fail_promotion(pr);
        return v;
    }
    V known = moved_get(pr, (uintptr_t)ptr(v));
    if (known)
        return known;
    if (is_pair(v))
        return promote_pair(pr, v);
    if (is_proc(v)) {
        if (hdr_type(ptr(v)[0]) != T_CLOSURE || hdr_size(ptr(v)[0]) != 0)
            return fail_promotion(pr);
        uint64_t *q = copy_object(pr, v);
        if (!q)
            return V_CLEARED;
        q[CLO_CODE] = promote(pr, q[CLO_CODE]);
        return tagged(q, TAG_PROC);
    }
    if (!is_object(v))
        return fail_promotion(pr);
    switch (obj_type(v)) {
    case T_STRING:
    case T_REAL: {
        uint64_t *q = copy_object(pr, v);
        return q ? tagged(q, TAG_OBJECT) : V_CLEARED;
    }
    case T_CODE: return promote_code(pr, v);
    default: return fail_promotion(pr);
    }
}

/* Whether all that v reaches may be copied, by the rules above, before anything is: a
   definition that cannot go leaves nothing behind. `seen` holds what was checked. */
static bool promotable(Promote *seen, V v)
{
    VM *vm = seen->vm;
    for (;;) {
        if (!is_ptr(v) || in_program(vm, ptr(v)) || moved_get(seen, (uintptr_t)ptr(v)))
            return true;
        if (!moved_put(seen, (uintptr_t)ptr(v), v))
            return false;
        uint64_t *p = ptr(v);
        if (is_pair(v)) {
            if (!promotable(seen, p[0]))
                return false;
            v = p[1];
            continue;
        }
        if (is_proc(v)) {
            if (hdr_type(p[0]) != T_CLOSURE || hdr_size(p[0]) != 0)
                return false;
            v = p[CLO_CODE];
            continue;
        }
        if (!is_object(v))
            return false;
        switch (obj_type(v)) {
        case T_STRING:
        case T_REAL: return true;
        case T_CODE: {
            if (p[CODE_NATIVE] || !is_object(p[CODE_BYTECODE]) || obj_type(p[CODE_BYTECODE]) != T_BYTES ||
                !promotable(seen, p[CODE_NAME]) || !promotable(seen, p[CODE_INLINE]))
                return false;
            size_t n = (size_t)(p[CODE_NCONST] + p[CODE_NCODE]);
            for (size_t i = 0; i < n; i++)
                if (!promotable(seen, *ra_at(&vm->program->consts, (size_t)p[CODE_CBASE] + i)))
                    return false;
            return true;
        }
        default: return false;
        }
    }
}

/* The closure of a definition being installed, in the program space; or the closure itself
   when it cannot go there. */
V program_promote(VM *vm, V closure)
{
    if (!vm->program->space.base)
        return closure;
    Promote check = {.vm = vm};
    bool ok = promotable(&check, closure);
    free(check.keys);
    free(check.values);
    if (!ok)
        return closure;
    Promote pr = {.vm = vm};
    V copy = promote(&pr, closure);
    /* Slots the owned table cannot mark stay roots, which costs a scan and nothing else. */
    if (!pr.failed)
        for (size_t i = 0; i < pr.nranges; i += 2)
            if (pr.ranges[i] + pr.ranges[i + 1] <= vm->program->owned_cap)
                memset(vm->program->owned + pr.ranges[i], PROGRAM, pr.ranges[i + 1]);
    for (size_t i = pr.nundo; pr.failed && i-- > 0;)
        *ra_at(&vm->program->consts, pr.undo_slot[i]) = pr.undo_value[i];
    for (size_t i = 0; pr.failed && i < pr.ncodes; i++)
        pr.codes[i][CODE_NCONST] = pr.codes[i][CODE_NCODE] = 0;
    free(pr.codes);
    free(pr.keys);
    free(pr.values);
    free(pr.ranges);
    free(pr.undo_slot);
    free(pr.undo_value);
    return pr.failed ? closure : copy;
}

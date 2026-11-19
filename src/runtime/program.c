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

/* Gives back what the last program_alloc took, before anything was written there, as a step after
   it failed: a save and the REPL's walk read every word of the space, and zeros taken for an odd
   number of words would be read as pairs, out of step with what follows. */
void program_unalloc(VM *vm, uint64_t *at, size_t words)
{
    Space *p = &vm->program->space;
    if (at + words == p->objects_next)
        p->objects_next = at;
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
    V name = program_copy_string(vm, s[SYM_NAME]);
    if (name == V_CLEARED)
        return false;
    s[SYM_NAME] = name;
    if (!symbol_table_put(&vm->program->published, sym))
        return false;
    s[SYM_CELL] = (s[SYM_CELL] & ~(UINT64_C(1) << MARK_BIT)) | UINT64_C(1) << PUBLISHED_BIT;
    if (symbol_cell(sym) >= vm->program->published_top)
        vm->program->published_top = symbol_cell(sym) + 1;
    if (symbol_global(sym) >= vm->program->published_global_top)
        vm->program->published_global_top = symbol_global(sym) + 1;
    return true;
}

/* At the first spawn, the builder's own symbols are published, with their names, and from then
   on the published table is shared (objects.c): no symbol is freed again. */
bool program_publish_all(VM *vm)
{
    SymbolTable own = vm->own;
    bool ok = true;
    for (size_t i = 0; ok && i < own.cap; i++)
        if (own.slots[i] && !symbol_published(own.slots[i]))
            ok = program_publish(vm, own.slots[i]);
    if (!ok)
        return false;
    free(own.slots);
    vm->own = (SymbolTable){NULL, 0, 0, false, NULL, 0};
    vm->program->published.shared = true;
    return true;
}

/* Promotion: what a definition reaches is copied into the program space, each object once,
   with a table from the old address to the copy, so that sharing is kept. Only what cannot
   change is copied: pairs, strings, floats, code with its bytecode and constant slots, and the
   definition's closure, which captures nothing. A definition that reaches anything else stays
   in the heap, as before. Nothing here allocates in the heap, so nothing moves meanwhile. */
typedef struct {
    VM *vm;
    AddrMap moved;
    /* What each slot held before it got a copy, to put back if the promotion fails: a slot
       left with a copy would be cleared once the original code, which owns it, is dead. */
    struct Undo {
        size_t slot;
        V value;
    } *undo;
    size_t nundo, undo_cap;
    uint64_t **codes; /* the code objects copied, whose slots are the program's, or none if it fails */
    size_t ncodes, codes_cap;
    bool failed;
} Promote;

/* From an object's old address to its copy (vm.h), here and in isolate.c's copier. */
static size_t addr_map_index(const AddrMap *m, uintptr_t key)
{
    return (size_t)((key >> 3) * UINT64_C(0x9E3779B97F4A7C15) >> 20) & (m->cap - 1);
}

V addr_map_get(const AddrMap *m, uintptr_t key)
{
    if (!m->cap)
        return 0;
    for (size_t i = addr_map_index(m, key);; i = (i + 1) & (m->cap - 1)) {
        if (!m->keys[i])
            return 0;
        if (m->keys[i] == key)
            return m->values[i];
    }
}

bool addr_map_put(AddrMap *m, uintptr_t key, V value)
{
    if (2 * (m->n + 1) > m->cap) {
        size_t cap = m->cap ? 2 * m->cap : 64;
        AddrMap grown = {calloc(cap, sizeof(uintptr_t)), malloc(cap * sizeof(V)), cap, 0};
        if (!grown.keys || !grown.values) {
            addr_map_free(&grown);
            return false;
        }
        for (size_t i = 0; i < m->cap; i++)
            if (m->keys[i])
                addr_map_put(&grown, m->keys[i], m->values[i]);
        addr_map_free(m);
        *m = grown;
    }
    size_t i = addr_map_index(m, key);
    while (m->keys[i])
        i = (i + 1) & (m->cap - 1);
    m->keys[i] = key;
    m->values[i] = value;
    m->n++;
    return true;
}

void addr_map_free(AddrMap *m)
{
    free(m->keys);
    free(m->values);
    m->keys = NULL;
    m->values = NULL;
    m->cap = m->n = 0;
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
        V known = addr_map_get(&pr->moved, (uintptr_t)ptr(v));
        if (known)
            break;
        uint64_t *q = program_alloc(pr->vm, 2);
        if (!q || !addr_map_put(&pr->moved, (uintptr_t)ptr(v), tagged(q, TAG_PAIR)))
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
    if (!q || !addr_map_put(&pr->moved, (uintptr_t)ptr(v), tagged(q, tag3(v)))) {
        if (q)
            program_unalloc(pr->vm, q, words);
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
    uint64_t **codes = grow_array(pr->codes, &pr->codes_cap, pr->ncodes, sizeof *codes, 16);
    if (!codes) {
        q[CODE_NCONST] = q[CODE_NCODE] = 0;
        return fail_promotion(pr);
    }
    pr->codes = codes;
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
        struct Undo *undo = grow_array(pr->undo, &pr->undo_cap, pr->nundo, sizeof *undo, 64);
        if (!undo)
            return fail_promotion(pr);
        pr->undo = undo;
        pr->undo[pr->nundo++] = (struct Undo){base + i, *slot};
        *slot = copy;
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
    V known = addr_map_get(&pr->moved, (uintptr_t)ptr(v));
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
    case T_FLOAT: {
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
        if (!is_ptr(v) || in_program(vm, ptr(v)) || addr_map_get(&seen->moved, (uintptr_t)ptr(v)))
            return true;
        if (!addr_map_put(&seen->moved, (uintptr_t)ptr(v), v))
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
        case T_FLOAT: return true;
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

/* Whether a promotion succeeded, as it ends. If so, the constant slots of the code it copied are
   the program's, those the owned table can mark (the others stay roots, which costs a scan and
   nothing else); if not, each slot gets back what it held, and the copies name none. */
static bool promote_finish(Promote *pr)
{
    VM *vm = pr->vm;
    for (size_t i = pr->nundo; pr->failed && i-- > 0;)
        *ra_at(&vm->program->consts, pr->undo[i].slot) = pr->undo[i].value;
    for (size_t i = 0; i < pr->ncodes; i++) {
        uint64_t *q = pr->codes[i];
        size_t base = (size_t)q[CODE_CBASE], n = (size_t)(q[CODE_NCONST] + q[CODE_NCODE]);
        if (pr->failed)
            q[CODE_NCONST] = q[CODE_NCODE] = 0;
        else if (base + n <= vm->program->owned_cap)
            memset(vm->program->owned + base, PROGRAM, n);
    }
    free(pr->codes);
    free(pr->undo);
    addr_map_free(&pr->moved);
    return !pr->failed;
}

/* A foreign function, copied into the program space when it is defined, so isolates share it.
   Its description is a vector, which promotion refuses as anything may store into one; but only
   the FFI library makes it, once, and nothing reaches it again but the runtime, which only reads
   it. The address found at the first call is a raw field: two isolates finding it at once store
   the same word. */
V program_promote_foreign(VM *vm, V proc, const char **why)
{
    V desc = ptr(proc)[FOREIGN_DESC];
    size_t n = (size_t)hdr_size(ptr(desc)[0]);
    Promote check = {.vm = vm};
    bool ok = true;
    for (size_t i = 0; ok && i < n; i++)
        ok = promotable(&check, ptr(desc)[1 + i]);
    addr_map_free(&check.moved);
    if (!ok) {
        *why = "~S: a foreign description may hold only symbols, numbers, strings and lists of them";
        return V_CLEARED;
    }
    Promote pr = {.vm = vm};
    uint64_t *d = copy_object(&pr, desc);
    for (size_t i = 0; d && i < n; i++)
        d[1 + i] = promote(&pr, d[1 + i]);
    uint64_t *f = d && !pr.failed ? copy_object(&pr, proc) : NULL;
    if (f)
        f[FOREIGN_DESC] = tagged(d, TAG_OBJECT);
    if (!promote_finish(&pr) || !f) {
        *why = "out of memory";
        return V_CLEARED;
    }
    return tagged(f, TAG_PROC);
}

/* The closure of a definition being installed, in the program space; or V_CLEARED, with the reason
   in *why. Code holds only what the reader makes, symbols, numbers, strings, booleans and lists of
   them, which all go there: an object with no syntax, which only gets into a form by building it,
   is refused, so no definition stays in a heap for an isolate to call. */
V program_promote(VM *vm, V closure, const char **why)
{
    Promote check = {.vm = vm};
    bool ok = promotable(&check, closure);
    addr_map_free(&check.moved);
    if (!ok) {
        *why = "~S: code may hold only symbols, numbers, strings, booleans and lists of them";
        return V_CLEARED;
    }
    Promote pr = {.vm = vm};
    V copy = promote(&pr, closure);
    if (!promote_finish(&pr)) {
        *why = "out of memory";
        return V_CLEARED;
    }
    return copy;
}

/* Install a promoted procedure. Record a name the current module seals before
   publishing it, so a failed load can unseal it on retry. */
bool program_install(VM *vm, V name, V proc)
{
    if (vm->seal_user) {
        static const char defined[] = "shen-jit.module.*defined*";
        V log = symbol_find(vm, defined, sizeof defined - 1);
        V *slot = log == V_NIL ? NULL : global_slot(vm, log);
        if (slot && (*slot == V_NIL || is_pair(*slot))) {
            V entry = make_pair(vm, name, *slot);
            if (entry == V_CLEARED)
                return false;
            *slot = entry;
        }
    }
    size_t cell = symbol_cell(name);
    if (vm->program->redefine)
        vm->program->redefine(vm, cell);
    *cell_function(vm, cell) = proc;
    if (vm->seal_user)
        symbol_seal(name);
    return true;
}

/* A string in the program space, for a value every isolate reads, such as *version*; or
   V_CLEARED when there is no room. */
V program_copy_string(VM *vm, V string)
{
    if (in_program(vm, ptr(string)))
        return string;
    size_t words = obj_words(ptr(string)[0]);
    uint64_t *q = program_alloc(vm, words);
    if (!q)
        return V_CLEARED;
    memcpy(q, ptr(string), words * sizeof(uint64_t));
    return tagged(q, TAG_OBJECT);
}

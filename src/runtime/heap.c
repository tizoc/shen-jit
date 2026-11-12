/* Memory: the VM context, root arrays, the guest stack and the semispace
   copying collector (docs/design.md, "Collection"). */
#define _DEFAULT_SOURCE /* clock_gettime and MAP_ANON under -std=c11 with glibc */
#include "vm.h"

#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <sys/mman.h>
#endif
#include <time.h>

static void fatal(const char *message)
{
    fprintf(stderr, "shen-jit: %s\n", message);
    abort();
}

/* A large object's block (vm.h). */
typedef struct Large {
    uint64_t *object;
    size_t words;
    bool reached, spare;
} Large;

static void fill_cleared(V *from, V *to)
{
    for (V *p = from; p < to; p++)
        *p = V_CLEARED;
}

/* The heap is three regions in one block of reserved address space, which takes
   no memory until it is committed and used. So growing commits more of each, and
   nothing moves. A process limited in address space reserves less, and one that
   starts with larger semispaces reserves that. On macOS each process's start
   takes longer with the size: 1.8 ms at 1 TiB each, 0.1 at this. Each starts a
   little past the last one's reservation, so that their addresses differ in their
   low bits: with those equal, collections took up to half as long again on a
   Ryzen 5 5600X.

   New objects always go in the area, and what a collection keeps goes back and
   forth between the two spaces. So the memory written to is the same each time,
   and stays in the cache, where two semispaces taking turns would be twice as
   much. The area lies between the spaces, so that one range holds what a
   collection may move, and not where it copies to: the collector need not know. */
#define RESERVED_WORDS ((size_t)1 << 33) /* 64 GiB for each region */
#define STAGGER_WORDS (((size_t)33 << 17) + (1 << 13)) /* 33 MiB and 64 KiB, so whole pages */
#define HEAP_BYTES(words) ((3 * (words) + 2 * STAGGER_WORDS) * sizeof(uint64_t))

static uint64_t *reserve_heap(size_t min_words, size_t *words)
{
    for (*words = min_words > RESERVED_WORDS ? min_words : RESERVED_WORDS; *words >= min_words; *words /= 2) {
#ifdef _WIN32
        void *p = win_reserve(HEAP_BYTES(*words));
        if (p)
            return p;
#else
        void *p = mmap(NULL, HEAP_BYTES(*words), PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
#ifdef MADV_HUGEPAGE
            /* Touching fresh small pages costs about as much as allocating
               on them. Without this, Linux may not give huge pages at all. */
            madvise(p, HEAP_BYTES(*words), MADV_HUGEPAGE);
#endif
            return p;
        }
#endif
    }
    return NULL;
}

static bool commit_space(uint64_t *space, size_t words)
{
#ifdef _WIN32
    return win_commit(space, words * sizeof(uint64_t));
#else
    return mprotect(space, words * sizeof(uint64_t), PROT_READ | PROT_WRITE) == 0;
#endif
}

/* What holds this much live data: four times as much room for new objects. A collection then copies
   a word for every four allocated, at most. */
size_t vm_semispace_for(size_t live_words) { return live_words * 5; }

/* Empties the area, whose room is what the space's contents leave of a semispace. */
void vm_fresh_area(VM *vm)
{
    vm->hp = vm->area_from = vm->area;
    vm->hlimit = vm->area + (vm->space_words - (size_t)(vm->live_end - vm->space));
}

V *vm_cleared_stack(size_t words)
{
    V *stack = malloc(words * sizeof(V));
    if (stack)
        fill_cleared(stack, stack + words);
    return stack;
}

VM *vm_create(size_t semispace_words, size_t stack_words)
{
    VM *vm = calloc(1, sizeof *vm);
    if (!vm)
        return NULL;
    vm->space = reserve_heap(semispace_words, &vm->reserved_words);
    vm->area = vm->space ? vm->space + vm->reserved_words + STAGGER_WORDS : NULL;
    vm->other = vm->space ? vm->area + vm->reserved_words + STAGGER_WORDS : NULL;
    vm->stack = vm_cleared_stack(stack_words);
    if (!vm->space || !vm->stack || !program_init(&vm->program) || !commit_space(vm->space, semispace_words) ||
        !commit_space(vm->area, semispace_words) || !commit_space(vm->other, semispace_words)) {
        vm_destroy(vm);
        return NULL;
    }
    vm->space_words = semispace_words;
    vm->live_end = vm->space;
    vm_fresh_area(vm);
    vm->stack_words = stack_words;
    vm->stack_max_words = (size_t)1 << 27; /* 1 GiB of slots */
    vm->fp = vm->top = vm->stack;
    vm_set_limit(vm, vm->stack);
    vm->exception = V_NIL;
    vm->api = ffi_api();
    vm->fail = V_NIL;
    vm->chars = V_NIL;
    vm->messages = V_NIL;
    vm->trace = V_NIL;
    vm->dead = V_NIL;
    vm->trace_floor = SIZE_MAX;
    return vm;
}

static void ra_free(RootArray *ra)
{
    for (size_t i = 0; i < ra->nchunks; i++)
        free(ra->chunks[i]);
    free(ra->chunks);
}

void vm_destroy(VM *vm)
{
    if (!vm)
        return;
    ffi_drain_roots(vm);
    thread_free_all(vm);
    if (vm->space) {
#ifdef _WIN32
        win_release(vm->space < vm->other ? vm->space : vm->other);
#else
        munmap(vm->space < vm->other ? vm->space : vm->other, HEAP_BYTES(vm->reserved_words));
#endif
    }
    free(vm->stack);
    program_release(&vm->program);
    free(vm->published.slots);
    free(vm->own.slots);
    for (size_t i = 0; i < vm->nlarge; i++)
        free(vm->large[i].object);
    free(vm->large);
    free(vm->handlers);
    ra_free(&vm->cells);
    ra_free(&vm->consts);
    free(vm->croots);
    for (size_t i = 0; i * FOREIGN_ROOT_CHUNK < vm->nforeign_roots; i++)
        free(vm->foreign_roots[i]);
    free(vm->foreign_roots);
    free(vm->files);
    free(vm->natives);
    free(vm->guards);
    free(vm->free_cells);
    free(vm->owned);
    free(vm->free_consts);
    free(vm);
}

V *ra_at(RootArray *ra, size_t i)
{
    return &ra->chunks[i >> RA_CHUNK_BITS][i & (RA_CHUNK - 1)];
}

bool ra_push(RootArray *ra, V v, size_t *index)
{
    if (ra->count == ra->nchunks * RA_CHUNK) {
        V **chunks = realloc(ra->chunks, (ra->nchunks + 1) * sizeof *chunks);
        if (!chunks)
            return false;
        ra->chunks = chunks;
        if (!(chunks[ra->nchunks] = malloc(RA_CHUNK * sizeof(V))))
            return false;
        ra->nchunks++;
    }
    *index = ra->count++;
    *ra_at(ra, *index) = v;
    return true;
}

/* Weak lists: values that a collection drops when nothing else reaches
   them. */
static bool weak_push(V **list, size_t *n, size_t *cap, V v)
{
    if (*n == *cap) {
        size_t c = *cap ? 2 * *cap : 16;
        V *l = realloc(*list, c * sizeof *l);
        if (!l)
            return false;
        *list = l;
        *cap = c;
    }
    (*list)[(*n)++] = v;
    return true;
}

bool vm_track_file(VM *vm, V stream) { return weak_push(&vm->files, &vm->nfiles, &vm->files_cap, stream); }

bool vm_track_native(VM *vm, V code) { return weak_push(&vm->natives, &vm->nnatives, &vm->natives_cap, code); }

bool vm_guard(VM *vm, V pointer, V value)
{
    if (vm->nguards == vm->guards_cap) {
        size_t cap = vm->guards_cap ? 2 * vm->guards_cap : 16;
        Guard *guards = realloc(vm->guards, cap * sizeof *guards);
        if (!guards)
            return false;
        vm->guards = guards;
        vm->guards_cap = cap;
    }
    vm->guards[vm->nguards++] = (Guard){pointer, value};
    return true;
}

/* Constant slots. A code object owns the range [cbase, cbase + nconst +
   ncode) of vm->consts: the collector copies those slots when it scans the
   code object, and once the code object is dead, clears them and reuses
   them. Its native code still holds their addresses, but cannot run again: a
   running function keeps its closure in its frame. Other slots are roots:
   sealed-call slots, which a load shares, and the ranges of code still being
   loaded. */
static bool add_free_consts(VM *vm, size_t start, size_t len)
{
    if (vm->nfree_consts == vm->free_consts_cap) {
        size_t cap = vm->free_consts_cap ? 2 * vm->free_consts_cap : 256;
        void *ranges = realloc(vm->free_consts, cap * sizeof *vm->free_consts);
        if (!ranges)
            return false; /* the slots are lost, nothing else */
        vm->free_consts = ranges;
        vm->free_consts_cap = cap;
    }
    vm->free_consts[vm->nfree_consts].start = start;
    vm->free_consts[vm->nfree_consts++].len = len;
    return true;
}

/* n cleared slots for a code object being loaded, from the first free range
   that fits or else at the end; they are roots until vm_track_code. */
size_t vm_consts_alloc(VM *vm, size_t n, bool *ok)
{
    *ok = true;
    for (size_t i = 0; n && i < vm->nfree_consts; i++) {
        if (vm->free_consts[i].len < n)
            continue;
        size_t start = vm->free_consts[i].start;
        vm->free_consts[i].start += n;
        vm->free_consts[i].len -= n;
        if (!vm->free_consts[i].len)
            vm->free_consts[i] = vm->free_consts[--vm->nfree_consts];
        return start;
    }
    size_t start = vm->consts.count, slot;
    for (size_t i = 0; i < n && *ok; i++)
        *ok = ra_push(&vm->consts, V_CLEARED, &slot);
    return start;
}

/* Slots that code which could not be built took: cleared, so that what they held can go, and free. */
void vm_consts_release(VM *vm, size_t start, size_t n)
{
    for (size_t i = 0; i < n; i++)
        *ra_at(&vm->consts, start + i) = V_CLEARED;
    if (n)
        add_free_consts(vm, start, n);
}

/* A loaded code object takes over its range. If this fails, the slots stay
   roots, as before there was any of this. */
bool vm_track_code(VM *vm, V code)
{
    uint64_t *o = ptr(code);
    size_t base = o[CODE_CBASE], n = o[CODE_NCONST] + o[CODE_NCODE];
    if (!n || base + n > vm->consts.count)
        return n == 0;
    if (base + n > vm->owned_cap) {
        size_t cap = vm->owned_cap ? vm->owned_cap : 4096;
        while (cap < base + n)
            cap *= 2;
        unsigned char *owned = realloc(vm->owned, cap);
        if (!owned)
            return false;
        memset(owned + vm->owned_cap, 0, cap - vm->owned_cap);
        vm->owned = owned;
        vm->owned_cap = cap;
    }
    memset(vm->owned + base, OWNED, n);
    return true;
}

static bool owned_slot(VM *vm, size_t i) { return i < vm->owned_cap && vm->owned[i]; }

/* Owned by code in the heap, whose collection copies them. */
static bool heap_slot(VM *vm, size_t i) { return owned_slot(vm, i) && vm->owned[i] != PROGRAM; }

/* After an image loads, whose code objects vm_track_code has taken: the
   runs of cleared slots that no code owns are the ranges freed before it was
   written. Sealed-call slots always hold a symbol or a procedure. */
void vm_find_free_consts(VM *vm)
{
    for (size_t i = 0; i < vm->consts.count;) {
        size_t j = i;
        while (j < vm->consts.count && !owned_slot(vm, j) && *ra_at(&vm->consts, j) == V_CLEARED)
            j++;
        if (j > i && !add_free_consts(vm, i, j - i))
            return;
        i = j > i ? j : i + 1;
    }
}

static int by_start(const void *a, const void *b)
{
    size_t x = *(const size_t *)a, y = *(const size_t *)b;
    return (x > y) - (x < y);
}

/* The owned slots of code objects the collection did not reach: cleared,
   then free, with neighbours merged. One pass in slot order, since a dead
   code object's range is just owned slots left unreached. */
static void sweep_code(VM *vm)
{
    size_t freed = 0, n = vm->owned_cap < vm->consts.count ? vm->owned_cap : vm->consts.count;
    for (size_t i = 0; i < n;) {
        if (vm->owned[i] != OWNED) {
            if (vm->owned[i] == REACHED)
                vm->owned[i] = OWNED;
            i++;
            continue;
        }
        size_t j = i;
        for (; j < n && vm->owned[j] == OWNED; j++) {
            vm->owned[j] = 0;
            *ra_at(&vm->consts, j) = V_CLEARED;
        }
        freed += add_free_consts(vm, i, j - i);
        i = j;
    }
    if (!freed)
        return;
    qsort(vm->free_consts, vm->nfree_consts, sizeof *vm->free_consts, by_start);
    size_t m = 0;
    for (size_t i = 0; i < vm->nfree_consts; i++) {
        if (m && vm->free_consts[m - 1].start + vm->free_consts[m - 1].len == vm->free_consts[i].start)
            vm->free_consts[m - 1].len += vm->free_consts[i].len;
        else
            vm->free_consts[m++] = vm->free_consts[i];
    }
    vm->nfree_consts = m;
}

/* Whether an address is in the heap's used part or in a live large object. */
bool vm_in_heap(const VM *vm, const void *at)
{
    const uint64_t *p = at;
    if ((p >= vm->space && p < vm->live_end) || (p >= vm->area_from && p < vm->hp))
        return true;
    size_t lo = 0, hi = vm->nlarge; /* the first large object after p */
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (vm->large[mid].object <= p)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo > 0 && !vm->large[lo - 1].spare && p < vm->large[lo - 1].object + vm->large[lo - 1].words;
}

void vm_root(VM *vm, V *slot)
{
    if (vm->ncroots == vm->croots_cap) {
        size_t cap = vm->croots_cap ? 2 * vm->croots_cap : 64;
        V **roots = realloc(vm->croots, cap * sizeof *roots);
        if (!roots)
            fatal("cannot grow the C root stack");
        vm->croots = roots;
        vm->croots_cap = cap;
    }
    vm->croots[vm->ncroots++] = slot;
}

/* Collection. */

typedef struct {
    uint64_t *from;
    size_t from_words;
    uint64_t *next; /* to-space allocation cursor */
    VM *vm;
    size_t *pending; /* large objects reached and not scanned yet */
    size_t npending, pending_cap;
} Copy;

/* A pointer outside from-space is to a large object, which stays where it
   is: the first time a collection reaches one, it is marked to be scanned. */
static V reach_large(Copy *c, V v)
{
    VM *vm = c->vm;
    uint64_t *p = ptr(v);
    size_t lo = 0, hi = vm->nlarge;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (vm->large[mid].object < p)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == vm->nlarge || vm->large[lo].object != p || vm->large[lo].spare)
        fatal("collector found a pointer outside the heap");
    if (!vm->large[lo].reached) {
        vm->large[lo].reached = true;
        if (c->npending == c->pending_cap) {
            size_t cap = c->pending_cap ? 2 * c->pending_cap : 16;
            size_t *more = realloc(c->pending, cap * sizeof *more);
            if (!more)
                fatal("cannot grow the large object list");
            c->pending = more;
            c->pending_cap = cap;
        }
        c->pending[c->npending++] = lo;
    }
    return v;
}

/* What is in the program space stays where it is, and is not scanned: nothing there points
   into the heap. A symbol that is not published is marked, so that the sweep keeps it. */
static V reach_program(VM *vm, V v)
{
    uint64_t *p = ptr(v);
    if (in_symbols(vm, p) && !((p[SYM_CELL] >> PUBLISHED_BIT) & 1))
        p[SYM_CELL] |= UINT64_C(1) << MARK_BIT;
    return v;
}

static V copy_value(Copy *c, V v)
{
    if (!is_ptr(v))
        return v;
    uint64_t *p = ptr(v);
    if (p < c->from || p >= c->from + c->from_words) {
        if (in_program(c->vm, p))
            return reach_program(c->vm, v);
        if (!c->vm->copy_large)
            return reach_large(c, v);
    }
    if (p[0] == V_FORWARD)
        return p[1];
    /* Every object has at least two words, and most are pairs: copy those
       two directly, since a call to memcpy per object costs more than the
       copy. */
    uint64_t *q = c->next;
    q[0] = p[0];
    q[1] = p[1];
    size_t n = tag3(v) == TAG_PAIR ? 2 : obj_words(p[0]);
    for (size_t i = 2; i < n; i++)
        q[i] = p[i];
    c->next += n;
    V moved = tagged(q, tag3(v));
    p[0] = V_FORWARD;
    p[1] = moved;
    /* A list's spine is copied at once, so that it stays contiguous: a
       breadth-first copy scatters its pairs among everything else live, and
       walking it then misses the cache at every pair. The copies keep their
       old tails, which the scan forwards as usual. */
    for (V t = q[1]; tag3(v) == TAG_PAIR && tag3(t) == TAG_PAIR;) {
        uint64_t *tp = ptr(t);
        if (tp < c->from || tp >= c->from + c->from_words || tp[0] == V_FORWARD)
            break;
        uint64_t *tq = c->next;
        tq[0] = tp[0];
        tq[1] = tp[1];
        c->next += 2;
        tp[0] = V_FORWARD;
        tp[1] = tagged(tq, TAG_PAIR);
        t = tq[1];
    }
    return moved;
}

static void copy_slot(Copy *c, V *slot) { *slot = copy_value(c, *slot); }

static void copy_root_array(Copy *c, RootArray *ra)
{
    for (size_t i = 0; i < ra->count; i++)
        copy_slot(c, ra_at(ra, i));
}

/* Scan to-space linearly. A word at an object boundary is either a header or
   the head of a pair (docs/semantics.md, section 2). Many slots hold no pointer
   (fixnums, booleans, []), so they are tested before the call. A slot that
   holds the same pointer as the object's last one gets the same copy without
   the call: absvector fills every slot with the symbol shen.fail!, and a
   Prolog vector has a million of them. */
static void scan_values(Copy *c, uint64_t *s, uint64_t w)
{
    size_t first, count;
    obj_values(w, &first, &count);
    V last = 0, moved = 0;
    for (size_t i = 0; i < count; i++) {
        V v = s[first + i];
        if (v == last)
            s[first + i] = moved;
        else if (is_ptr(v))
            s[first + i] = moved = copy_value(c, last = v);
    }
}

static void scan(Copy *c, uint64_t *s)
{
    while (s < c->next) {
        uint64_t w = *s;
        if (is_header(w)) {
            scan_values(c, s, w);
            /* A code object's constant slots go with it, when it owns them. */
            if (hdr_type(w) == T_CODE && heap_slot(c->vm, s[CODE_CBASE]))
                for (size_t i = 0; i < s[CODE_NCONST] + s[CODE_NCODE]; i++) {
                    V *slot = ra_at(&c->vm->consts, s[CODE_CBASE] + i);
                    c->vm->owned[s[CODE_CBASE] + i] = REACHED;
                    if (is_ptr(*slot))
                        copy_slot(c, slot);
                }
            s += obj_words(w);
        } else {
            if (is_ptr(s[0]))
                copy_slot(c, &s[0]);
            if (is_ptr(s[1]))
                copy_slot(c, &s[1]);
            s += 2;
        }
    }
}

/* Scan to-space from s, and the large objects reached, until neither has
   anything left to scan. */
static void drain(Copy *c, uint64_t *s)
{
    for (;;) {
        scan(c, s);
        s = c->next;
        if (!c->npending)
            return;
        uint64_t *o = c->vm->large[c->pending[--c->npending]].object;
        scan_values(c, o, o[0]);
    }
}

/* Dead large objects become spares, and the spares from the last collection
   go back to the system. */
static void sweep_large(VM *vm)
{
    size_t kept = 0;
    vm->large_words = 0;
    for (size_t i = 0; i < vm->nlarge; i++) {
        Large l = vm->large[i];
        if (l.spare) {
            free(l.object);
            continue;
        }
        l.spare = !l.reached;
        l.reached = false;
        vm->large[kept++] = l;
        vm->large_words += l.words;
    }
    vm->nlarge = kept;
    vm->large_since = 0;
}

static void free_spares(VM *vm)
{
    size_t kept = 0;
    for (size_t i = 0; i < vm->nlarge; i++)
        if (vm->large[i].spare) {
            free(vm->large[i].object);
            vm->large_words -= vm->large[i].words;
        } else {
            vm->large[kept++] = vm->large[i];
        }
    vm->nlarge = kept;
}

/* The table of symbols that are not published is weak (objects.c): after everything else is
   copied, a new table gets the symbols that were reached, as marked, or that symbol_needed
   keeps, with their names; the others give back their cells and slots. Symbols published
   since the last collection leave the table. */
static void sweep_symbols(VM *vm, Copy *c)
{
    SymbolTable *old = &vm->own;
    size_t live = 0;
    for (size_t i = 0; i < old->cap; i++) {
        V s = old->slots[i];
        if (s && !symbol_published(s) && ((ptr(s)[SYM_CELL] >> MARK_BIT) & 1 || symbol_needed(vm, s)))
            live++;
    }
    size_t m = old->cap;
    while (m > 1024 && 4 * live < m)
        m /= 2;
    V *slots = calloc(m ? m : 1, sizeof *slots);
    if (!slots)
        return; /* everything stays until a collection has room */
    SymbolTable t = {slots, m, 0};
    size_t top = vm->published_top; /* one past the highest cell kept */
    uint64_t *mark = c->next;
    for (size_t i = 0; i < old->cap; i++) {
        V s = old->slots[i];
        if (!s || symbol_published(s))
            continue;
        uint64_t *p = ptr(s);
        if (!((p[SYM_CELL] >> MARK_BIT) & 1) && !symbol_needed(vm, s)) {
            if (vm->nfree_cells == vm->free_cells_cap) {
                size_t cap = vm->free_cells_cap ? 2 * vm->free_cells_cap : 1024;
                size_t *cells = realloc(vm->free_cells, cap * sizeof *cells);
                if (cells) {
                    vm->free_cells = cells;
                    vm->free_cells_cap = cap;
                }
            }
            if (vm->nfree_cells < vm->free_cells_cap) {
                vm->free_cells[vm->nfree_cells++] = symbol_cell(s);
                program_free_symbol(vm, p);
                continue;
            }
            /* Kept, rather than lose its cell. */
        }
        p[SYM_CELL] &= ~(UINT64_C(1) << MARK_BIT);
        if (symbol_cell(s) >= top)
            top = symbol_cell(s) + 1;
        copy_slot(c, &p[SYM_NAME]);
        symbol_table_put(&t, s);
    }
    /* Every cell in use has a symbol in a table, so those above the last one kept are free, and
       they leave the array: every collection walks it, and a burst of new symbols would
       otherwise slow them all for good. */
    size_t free_kept = 0;
    for (size_t i = 0; i < vm->nfree_cells; i++)
        if (vm->free_cells[i] < top)
            vm->free_cells[free_kept++] = vm->free_cells[i];
    vm->nfree_cells = free_kept;
    vm->cells.count = 2 * top;
    drain(c, mark);
    free(old->slots);
    *old = t;
    vm->nsymbols = vm->published.count + t.count;
}

/* Slots above the published top are dead by the call-window invariants.
   Slots at or above the dirty mark are already clear, so clearing up to the
   mark keeps every slot either current or cleared. The mark can then drop to
   FP + max_frame: every suspended frame starts at or below FP, so none extends
   beyond that, and resumed callers write below it. Returns the new mark. */
static V *clear_above_top(const VM *vm, V *stack, size_t words, V *fp, V *top, V *limit)
{
    if (limit > top)
        fill_cleared(top, limit);
    V *mark = fp + vm->max_frame;
    if (mark > stack + words)
        mark = stack + words;
    return mark > top ? mark : top;
}

static void collect_into(VM *vm, uint64_t *to)
{
    uint64_t *from = vm->space < vm->area ? vm->space : vm->area;
    uint64_t *from_end = vm->space < vm->area ? vm->hp : vm->live_end;
    Copy c = {from, (size_t)(from_end - from), to, vm, NULL, 0, 0};
    for (V *p = vm->stack; p < vm->top; p++)
        copy_slot(&c, p);
    for (Thread *t = vm->threads; t; t = t->next) {
        copy_slot(&c, &t->thunk);
        if (t != vm->thread) {
            copy_slot(&c, &t->exception);
            copy_slot(&c, &t->trace);
            for (V *p = t->stack; p < t->top; p++)
                copy_slot(&c, p);
            for (size_t i = 0; i < t->ncroots; i++)
                copy_slot(&c, t->croots[i]);
        }
    }
    copy_root_array(&c, &vm->cells);
    ffi_drain_roots(vm);
    for (size_t i = 0; i < vm->nforeign_roots; i++)
        copy_slot(&c, &vm->foreign_roots[i / FOREIGN_ROOT_CHUNK][i % FOREIGN_ROOT_CHUNK].value);
    for (size_t i = 0; i < vm->consts.count; i++)
        if (!owned_slot(vm, i))
            copy_slot(&c, ra_at(&vm->consts, i));
    for (size_t i = 0; i < vm->ncroots; i++)
        copy_slot(&c, vm->croots[i]);
    for (size_t i = 0; i < sizeof vm->args / sizeof vm->args[0]; i++)
        copy_slot(&c, &vm->args[i]);
    copy_slot(&c, &vm->exception);
    copy_slot(&c, &vm->fail);
    copy_slot(&c, &vm->chars);
    copy_slot(&c, &vm->messages);
    copy_slot(&c, &vm->trace);
    copy_slot(&c, &vm->dead);
    /* A guard's value counts as reached whether or not its pointer is, so what one pointer's
       value uses stays alive until that value has been taken. */
    for (size_t i = 0; i < vm->nguards; i++)
        copy_slot(&c, &vm->guards[i].value);
    drain(&c, to);
    /* The values of pointers that nothing reached go on the list. Each pair fits in the space
       its pointer, which is not copied, leaves in to-space, and holds only what is copied. */
    size_t guarded = 0;
    for (size_t i = 0; i < vm->nguards; i++) {
        uint64_t *o = ptr(vm->guards[i].pointer);
        if (o[0] == V_FORWARD) {
            vm->guards[guarded].pointer = o[1];
            vm->guards[guarded++].value = vm->guards[i].value;
        } else {
            uint64_t *pair = c.next;
            c.next += 2;
            pair[0] = vm->guards[i].value;
            pair[1] = vm->dead;
            vm->dead = tagged(pair, TAG_PAIR);
        }
    }
    vm->nguards = guarded;
    sweep_symbols(vm, &c);
    free(c.pending);
    sweep_large(vm);
    sweep_code(vm);

    /* Sweep the file streams: keep those that were copied and are still
       open, and close those that nothing reached. */
    size_t kept = 0;
    for (size_t i = 0; i < vm->nfiles; i++) {
        uint64_t *o = ptr(vm->files[i]);
        if (o[0] != V_FORWARD) {
            if (o[STREAM_FLAGS] & STREAM_OPEN)
                fclose((FILE *)(uintptr_t)o[STREAM_HANDLE]);
        } else if (ptr(o[1])[STREAM_FLAGS] & STREAM_OPEN) {
            vm->files[kept++] = o[1];
        }
    }
    vm->nfiles = kept;
    /* The native code of code objects that nothing reached goes back to the
       JIT. */
    kept = 0;
    for (size_t i = 0; i < vm->nnatives; i++) {
        uint64_t *o = ptr(vm->natives[i]);
        if (o[0] == V_FORWARD)
            vm->natives[kept++] = o[1];
        else if (in_program(vm, o))
            vm->natives[kept++] = vm->natives[i];
        else if (vm->free_native)
            vm->free_native(vm, o);
    }
    vm->nnatives = kept;

    vm->space = to;
    vm->live_end = c.next;
    vm_fresh_area(vm);
    vm->collections++;
    vm_set_limit(vm, clear_above_top(vm, vm->stack, vm->stack_words, vm->fp, vm->top, vm->stack_limit));
    for (Thread *t = vm->threads; t; t = t->next)
        if (t != vm->thread)
            t->stack_limit = clear_above_top(vm, t->stack, t->stack_words, t->fp, t->top, t->stack_limit);
}

static double seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

bool vm_collect(VM *vm, size_t need_words)
{
    double start = seconds();
    uint64_t *old = vm->space, *old_end = vm->live_end, *area_from = vm->area_from, *area_end = vm->hp;
    collect_into(vm, vm->other);
    vm->other = old;
    /* Under stress nothing is left to read where objects were, so that a stale pointer
       fails at once instead of finding what it pointed to still there. Not an address
       on any target, and tagged as a procedure if it is ever read as a value. */
    if (vm->stress) {
        for (uint64_t *p = old; p < old_end; p++)
            *p = UINT64_C(0xDEADDEADDEADDEAD);
        for (uint64_t *p = area_from; p < area_end; p++)
            *p = UINT64_C(0xDEADDEADDEADDEAD);
    }

    /* Grow so that live data and the request are a fifth of a semispace at most, up to
       the limit. Live large objects count: every collection scans them. With its own
       area the heap need not grow in steps, which made the cost of what is live a
       sawtooth: right after a doubling, half of what it is just before. */
    size_t kept = (size_t)(vm->live_end - vm->space);
    size_t live = kept;
    for (size_t i = 0; i < vm->nlarge; i++)
        if (!vm->large[i].spare)
            live += vm->large[i].words;
    size_t want = vm_semispace_for(live + need_words);
    size_t limit = vm->max_words && vm->max_words < vm->reserved_words ? vm->max_words : vm->reserved_words;
    if (want > limit)
        want = limit;
    if (want < vm->space_words)
        want = vm->space_words;
    if (want != vm->space_words && commit_space(vm->space, want) && commit_space(vm->area, want) &&
        commit_space(vm->other, want)) {
        vm->space_words = want;
        vm_fresh_area(vm);
    }
    /* At SHEN_JIT_MAX_HEAP, the last tenth of the heap is a reserve: an
       allocation that does not fit below it fails, and raising the "out of
       memory" error may then use it. Without it, a heap full of live data
       would leave no room for the error. */
    if (vm->max_words && vm->space_words * 2 > vm->max_words) {
        size_t usable = vm->space_words / 10 * 9;
        vm->hlimit = vm->area + (live < usable ? usable - live : 0);
    }
    /* Under stress, new objects go past the words just overwritten for as long as
       they fit, or they would land on what a stale pointer points to and hide it.
       And leave room for this request or vm->stress words, so inline allocation in
       native code also collects. */
    size_t room = need_words > vm->stress ? need_words : vm->stress;
    if (vm->stress) {
        if (room <= (size_t)(vm->hlimit - vm->area) &&
            (size_t)(area_end - vm->area) <= (size_t)(vm->hlimit - vm->area) - room)
            vm->hp = vm->area_from = area_end;
        if ((size_t)(vm->hlimit - vm->hp) >= room)
            vm->hlimit = vm->hp + room;
    }
    double pause = seconds() - start;
    vm->gc_seconds += pause;
    if (pause > vm->gc_longest)
        vm->gc_longest = pause;
    if ((size_t)(vm->hlimit - vm->hp) < need_words) {
        vm_fresh_area(vm); /* the reserve, for the error */
        return false;
    }
    return true;
}

uint64_t *vm_alloc(VM *vm, size_t words)
{
    if ((size_t)(vm->hlimit - vm->hp) < words ||
        (vm->stress && (size_t)(vm->hlimit - vm->hp) > vm->stress)) {
        if (!vm_collect(vm, words))
            return NULL;
    }
    uint64_t *p = vm->hp;
    vm->hp += words;
    return p;
}

/* Whether this would take what the heap holds past SHEN_JIT_MAX_HEAP, less its reserve. What
   it holds and not what it has room for: semispaces never shrink, so one grown to the limit
   would refuse every large object from then on, with nothing live. */
static bool past_limit(VM *vm, size_t words)
{
    size_t held = (size_t)(vm->live_end - vm->space) + (size_t)(vm->hp - vm->area_from) + vm->large_words;
    return held + words > vm->max_words / 10 * 9;
}

/* A large object: a spare block of the same size if there is one, or a new
   one. Large allocations count toward the next collection, which frees the
   dead ones, and toward SHEN_JIT_MAX_HEAP. */
static uint64_t *alloc_large(VM *vm, size_t words)
{
    if (vm->large_since + words > vm->space_words || vm->stress)
        vm_collect(vm, 0);
    if (vm->max_words && past_limit(vm, words)) {
        free_spares(vm);
        if (past_limit(vm, words)) {
            vm_collect(vm, 0);
            free_spares(vm);
            if (past_limit(vm, words))
                return NULL;
        }
    }
    vm->large_since += words;
    for (size_t i = 0; i < vm->nlarge; i++)
        if (vm->large[i].spare && vm->large[i].words == words) {
            vm->large[i].spare = false;
            return vm->large[i].object;
        }
    if (vm->nlarge == vm->large_cap) {
        size_t cap = vm->large_cap ? 2 * vm->large_cap : 16;
        Large *more = realloc(vm->large, cap * sizeof *more);
        if (!more)
            return NULL;
        vm->large = more;
        vm->large_cap = cap;
    }
    uint64_t *p = malloc(words * sizeof(uint64_t));
    if (!p)
        return NULL;
    size_t i = vm->nlarge++;
    for (; i > 0 && vm->large[i - 1].object > p; i--)
        vm->large[i] = vm->large[i - 1];
    vm->large[i] = (Large){p, words, false, false};
    vm->large_words += words;
    return p;
}

uint64_t *vm_alloc_object(VM *vm, size_t words)
{
    if (words < LARGE_WORDS)
        return vm_alloc(vm, words);
    uint64_t *p = alloc_large(vm, words);
    /* At SHEN_JIT_MAX_HEAP, the area's room is what the limit left at the last collection, and
       a large object takes its words from it: the limit is on small and large objects together. */
    if (p && vm->max_words) {
        size_t room = (size_t)(vm->hlimit - vm->hp);
        vm->hlimit -= words < room ? words : room;
    }
    return p;
}

/* The live heap by object type, for SHEN_JIT_STATS: count[0] and words[0] are
   pairs, count[T] and words[T] objects of type T, after a collection. */
void vm_census(VM *vm, size_t count[T_LIMIT], size_t words[T_LIMIT])
{
    vm_collect(vm, 0);
    for (size_t i = 0; i < vm->nlarge; i++)
        if (!vm->large[i].spare) {
            count[hdr_type(vm->large[i].object[0])]++;
            words[hdr_type(vm->large[i].object[0])] += vm->large[i].words;
        }
    for (uint64_t *s = vm->space; s < vm->live_end;) {
        unsigned t = is_header(*s) ? hdr_type(*s) : 0;
        size_t n = t ? obj_words(*s) : 2;
        count[t]++;
        words[t] += n;
        s += n;
    }
}

/* Guest stack growth: copy the scanned part, clear the rest and rebase the
   frame pointer. The stack never shrinks while guest code runs. */
bool vm_stack_grow(VM *vm, size_t need_words)
{
    size_t used = (size_t)(vm->top - vm->stack);
    size_t want = vm->stack_words;
    while (want < need_words)
        want *= 2;
    if (want > vm->stack_max_words)
        return false;
    V *stack = malloc(want * sizeof(V));
    if (!stack)
        return false;
    memcpy(stack, vm->stack, used * sizeof(V));
    fill_cleared(stack + used, stack + want);
    vm->fp = stack + (vm->fp - vm->stack);
    vm->top = stack + used;
    free(vm->stack);
    vm->stack = stack;
    vm->stack_words = want;
    vm_set_limit(vm, vm->top);
    return true;
}

/* Makes the first need_words slots usable by frames: grows the stack if it
   must, and raises the dirty mark, with a margin so that deepening recursion
   reaches the growth stub only now and then. Slots above the mark are clear,
   so raising it needs no clearing. */
#define STACK_MARGIN 1024
bool vm_stack_reserve(VM *vm, size_t need_words)
{
    if (need_words > vm->stack_words && !vm_stack_grow(vm, need_words))
        return false;
    size_t mark = need_words + STACK_MARGIN;
    if (mark > vm->stack_words)
        mark = vm->stack_words;
    if (vm->stack + mark > vm->stack_limit)
        vm_set_limit(vm, vm->stack + mark);
    return true;
}

/* Sets the dirty mark, and the limit compiled code checks, which stays NULL
   while an interrupt is pending. The signal handler sets interrupted before
   clearing check_limit, so testing it after the store loses no interrupt. */
void vm_set_limit(VM *vm, V *mark)
{
    vm->stack_limit = mark;
    vm->check_limit = mark;
    if (vm->interrupted)
        vm->check_limit = NULL;
}

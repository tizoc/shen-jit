/* Object constructors and the symbol table. Every constructor roots its value
   arguments while it allocates; a NULL allocation returns V_CLEARED, which no
   Shen value equals, so callers can raise "out of memory". */
#include "vm.h"

#include <pthread.h>

#include <string.h>

#define XXH_INLINE_ALL
#include "../../vendor/xxhash/xxhash.h"

#define FAILED V_CLEARED

V make_pair(VM *vm, V head, V tail)
{
    vm_root(vm, &head);
    vm_root(vm, &tail);
    uint64_t *p = vm_alloc(vm, 2);
    vm_unroot(vm, 2);
    if (!p)
        return FAILED;
    p[0] = head;
    p[1] = tail;
    return tagged(p, TAG_PAIR);
}

static V make_byte_object(VM *vm, unsigned type, const void *bytes, size_t len)
{
    if (len >= HEADER_SIZE_LIMIT)
        return FAILED;
    uint64_t h = HEADER(type, len);
    uint64_t *p = vm_alloc_object(vm, obj_words(h));
    if (!p)
        return FAILED;
    p[0] = h;
    p[obj_words(h) - 1] = 0; /* zero the padding of the last word */
    if (bytes && len)
        memcpy(p + 1, bytes, len);
    else if (len)
        memset(p + 1, 0, len);
    return tagged(p, TAG_OBJECT);
}

/* The bytes must not be inside the heap, since allocation can move them. */
V make_string(VM *vm, const char *bytes, size_t len)
{
    return make_byte_object(vm, T_STRING, bytes, len);
}

/* All zero when bytes is NULL. */
V make_bytes(VM *vm, const void *bytes, size_t len)
{
    return make_byte_object(vm, T_BYTES, bytes, len);
}

V make_real(VM *vm, double d)
{
    uint64_t *p = vm_alloc(vm, REAL_WORDS);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_REAL, 0);
    memcpy(p + REAL_VALUE, &d, sizeof d);
    return tagged(p, TAG_OBJECT);
}

V make_vector(VM *vm, size_t n, V fill)
{
    if (n >= HEADER_SIZE_LIMIT)
        return FAILED;
    uint64_t h = HEADER(T_VECTOR, n);
    vm_root(vm, &fill);
    uint64_t *p = vm_alloc_object(vm, obj_words(h));
    vm_unroot(vm, 1);
    if (!p)
        return FAILED;
    p[0] = h;
    p[1] = V_NIL; /* padding of an empty vector */
    for (size_t i = 0; i < n; i++)
        p[1 + i] = fill;
    return tagged(p, TAG_OBJECT);
}

/* The captures are read after allocating, so they must be rooted by the
   caller, normally in guest stack slots. */
V make_closure(VM *vm, V code, size_t ncaps, const V *caps)
{
    vm_root(vm, &code);
    uint64_t *p = vm_alloc(vm, CLO_CAPS + ncaps);
    vm_unroot(vm, 1);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_CLOSURE, ncaps);
    p[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->compile_stub;
    p[CLO_CODE] = code;
    for (size_t i = 0; i < ncaps; i++)
        p[CLO_CAPS + i] = caps[i];
    return tagged(p, TAG_PROC);
}

V make_foreign(VM *vm, V desc, size_t arity)
{
    vm_root(vm, &desc);
    uint64_t *p = vm_alloc(vm, FOREIGN_WORDS);
    vm_unroot(vm, 1);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_FOREIGN, 0);
    p[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->foreign_stub;
    p[FOREIGN_DESC] = desc;
    p[FOREIGN_ADDRESS] = 0; /* found on the first call */
    p[FOREIGN_ARITY] = arity;
    return tagged(p, TAG_PROC);
}

V make_pointer(VM *vm, uint64_t address, V kind)
{
    vm_root(vm, &kind);
    uint64_t *p = vm_alloc(vm, POINTER_WORDS);
    vm_unroot(vm, 1);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_POINTER, 0);
    p[POINTER_KIND] = kind;
    p[POINTER_OWNER] = V_NIL;
    p[POINTER_ADDRESS] = address;
    p[POINTER_LENGTH] = 0;
    return tagged(p, TAG_OBJECT);
}

V make_code(VM *vm, V name, V bytecode, size_t arity, size_t frame,
            size_t cbase, size_t nconst, size_t ncode, V inline_body)
{
    vm_root(vm, &name);
    vm_root(vm, &bytecode);
    vm_root(vm, &inline_body);
    uint64_t *p = vm_alloc(vm, CODE_WORDS);
    vm_unroot(vm, 3);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_CODE, 0);
    p[CODE_NATIVE] = 0;
    p[CODE_ARITY] = arity;
    p[CODE_FRAME] = frame;
    p[CODE_CBASE] = cbase;
    p[CODE_NCONST] = nconst;
    p[CODE_NCODE] = ncode;
    p[CODE_NAME] = name;
    p[CODE_BYTECODE] = bytecode;
    p[CODE_INLINE] = inline_body;
    return tagged(p, TAG_OBJECT);
}

/* value is V_CLEARED for none; see exception_message. */
V make_exception(VM *vm, V message, V value)
{
    vm_root(vm, &message);
    vm_root(vm, &value);
    uint64_t *p = vm_alloc(vm, EXC_WORDS);
    vm_unroot(vm, 2);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_EXCEPTION, 0);
    p[EXC_MESSAGE] = message;
    p[EXC_VALUE] = value;
    return tagged(p, TAG_OBJECT);
}

V make_stream(VM *vm, uint64_t flags, void *handle)
{
    uint64_t *p = vm_alloc(vm, STREAM_WORDS);
    if (!p)
        return FAILED;
    p[0] = HEADER(T_STREAM, 0);
    p[STREAM_FLAGS] = flags;
    p[STREAM_HANDLE] = (uint64_t)(uintptr_t)handle;
    return tagged(p, TAG_OBJECT);
}

/* Symbols. The hash is computed from the name once, so it never depends on an
   address. Every symbol has a slot of the program space, where it never moves
   (program.c), and is in one of two tables: the published ones, which stay,
   and the others, held weakly: a collection drops those that nothing else
   reaches and that symbol_needed does not keep (heap.c). */

uint64_t hash_bytes(const void *bytes, size_t len) { return XXH3_64bits(bytes, len); }

/* The word at SYM_CELL holds the function cell's index, and the global's
   number above it. Above those (vm.h): the
   symbol's kind for shen-jit.symbol-kind (bits 56-57), whether the function
   it names is sealed (bit 58): calls to it may be bound once, and it cannot
   be redefined; whether compiled code calls it by name (bit 59), through its
   cell's index rather than the symbol; whether it is published (bit 60); and
   the collector's mark (bit 61). */
size_t symbol_cell(V sym) { return (size_t)(ptr(sym)[SYM_CELL] & CELL_MASK); }

bool symbol_sealed(V sym) { return (ptr(sym)[SYM_CELL] >> SEALED_BIT) & 1; }

void symbol_seal(V sym) { __atomic_fetch_or(&ptr(sym)[SYM_CELL], UINT64_C(1) << SEALED_BIT, __ATOMIC_RELAXED); }

void symbol_mark_called(V sym) { __atomic_fetch_or(&ptr(sym)[SYM_CELL], UINT64_C(1) << CALLED_BIT, __ATOMIC_RELAXED); }

/* Whether a symbol stays although only the table reaches it: interning
   its name again must find its value and function, and code that calls it by
   name holds its cell. Any other can go, and come back as a new symbol. */
bool symbol_needed(VM *vm, V sym)
{
    return (ptr(sym)[SYM_CELL] >> CALLED_BIT) & 1 || global_value(vm, sym) != V_CLEARED ||
           *cell_function(vm, symbol_cell(sym)) != V_CLEARED || *cell_arity(vm, symbol_cell(sym)) != V_CLEARED;
}

/* The kind of a symbol named s: 0 if the kernel's symbol? rejects it, 1 for
   a symbol, 2 for a variable. The kernel accepts the names { } : ; , and
   names of its symbol characters that do not start with a digit; a variable
   starts with A-Z. */
static bool symbol_char(unsigned char ch)
{
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
           (ch && strchr("=-*/+_?$!@~.><&%'#`", ch));
}

static uint64_t name_kind(const unsigned char *s, size_t n)
{
    if (n == 1 && s[0] && strchr("{}:;,", s[0]))
        return 1;
    if (n == 0 || (s[0] >= '0' && s[0] <= '9'))
        return 0;
    for (size_t i = 0; i < n; i++)
        if (!symbol_char(s[i]))
            return 0;
    return s[0] >= 'A' && s[0] <= 'Z' ? 2 : 1;
}

/* Adds a symbol that is not in the table, growing it past half full. */
bool symbol_table_put(SymbolTable *t, V sym)
{
    if (2 * (t->count + 1) > t->cap) {
        size_t cap = t->cap ? 2 * t->cap : 1024;
        if (t->shared) { /* kept as soon as it moves, whatever fails next */
            V **retired = realloc(t->retired, (t->nretired + 1) * sizeof *retired);
            if (!retired)
                return false;
            t->retired = retired;
        }
        V *slots = calloc(cap, sizeof *slots);
        if (!slots)
            return false;
        SymbolTable grown = {slots, cap, 0, false, NULL, 0};
        for (size_t i = 0; i < t->cap; i++)
            if (t->slots[i])
                symbol_table_put(&grown, t->slots[i]);
        if (t->shared) {
            t->retired[t->nretired++] = t->slots;
        } else {
            free(t->slots);
        }
        t->count = grown.count;
        __atomic_store_n(&t->slots, slots, __ATOMIC_RELEASE);
        __atomic_store_n(&t->cap, cap, __ATOMIC_RELEASE);
    }
    size_t i = ptr(sym)[SYM_HASH] & (t->cap - 1);
    while (t->slots[i])
        i = (i + 1) & (t->cap - 1);
    __atomic_store_n(&t->slots[i], sym, __ATOMIC_RELEASE);
    t->count++;
    return true;
}

/* The symbol of that name in the table, or 0: what the probe read, as the empty entry where it
   stopped may meanwhile take another name's symbol. Once isolates exist, the published table is
   read without a lock while another isolate adds to it: the capacity is read first, then the
   array, which a growth stores in the other order, and an entry is stored only once its symbol is
   whole. A reader that sees the new array with the old capacity may miss a symbol, which interning
   then finds under the lock. */
static V table_find(SymbolTable *t, uint64_t hash, const char *bytes, size_t len)
{
    size_t cap = __atomic_load_n(&t->cap, __ATOMIC_ACQUIRE);
    V *slots = __atomic_load_n(&t->slots, __ATOMIC_ACQUIRE);
    if (!cap)
        return 0;
    for (size_t i = hash & (cap - 1);; i = (i + 1) & (cap - 1)) {
        V s = __atomic_load_n(&slots[i], __ATOMIC_ACQUIRE);
        if (!s)
            return 0;
        V name = ptr(s)[SYM_NAME];
        if (ptr(s)[SYM_HASH] == hash && string_length(name) == len && memcmp(string_bytes(name), bytes, len) == 0)
            return s;
    }
}

/* The symbol of that name, published or not, or 0. */
static V find(VM *vm, uint64_t hash, const char *bytes, size_t len)
{
    V s = table_find(&vm->program->published, hash, bytes, len);
    return s ? s : table_find(&vm->own, hash, bytes, len);
}

/* The symbol whose cell is `cell`, or [] if none: a search of the symbol
   tables, for error messages. */
V cell_symbol(VM *vm, size_t cell)
{
    SymbolTable *tables[2] = {&vm->program->published, &vm->own};
    for (int k = 0; k < 2; k++) { /* as table_find reads them, as another isolate may add */
        size_t cap = __atomic_load_n(&tables[k]->cap, __ATOMIC_ACQUIRE);
        V *slots = __atomic_load_n(&tables[k]->slots, __ATOMIC_ACQUIRE);
        for (size_t i = 0; i < cap; i++) {
            V s = __atomic_load_n(&slots[i], __ATOMIC_ACQUIRE);
            if (s && symbol_cell(s) == cell)
                return s;
        }
    }
    return V_NIL;
}

/* New symbols and global numbers, once isolates exist: any isolate makes them. */
static pthread_mutex_t shared_lock = PTHREAD_MUTEX_INITIALIZER;

/* For a walk of the program space that must not meet an object half made (jit.c). */
void program_shared_lock(void) { pthread_mutex_lock(&shared_lock); }
void program_shared_unlock(void) { pthread_mutex_unlock(&shared_lock); }

/* For a lookup that makes nothing and must not miss: a miss while another isolate grows the
   published table is looked up again under the lock that growth takes. */
static V published_sure(VM *vm, V found, uint64_t hash, const char *bytes, size_t len)
{
    if (found || !vm->program->isolates)
        return found;
    pthread_mutex_lock(&shared_lock);
    found = table_find(&vm->program->published, hash, bytes, len);
    pthread_mutex_unlock(&shared_lock);
    return found;
}

V published_find(VM *vm, const char *bytes, size_t len)
{
    uint64_t hash = hash_bytes(bytes, len);
    return published_sure(vm, table_find(&vm->program->published, hash, bytes, len), hash, bytes, len);
}

/* A new cell, both entries cleared, or SIZE_MAX. */
static size_t new_cell(VM *vm)
{
    size_t reserved, entry, entry2;
    /* Cell 0 is none's. */
    if (vm->program->cells.count == 0 &&
        (!ra_push(&vm->program->cells, V_CLEARED, &reserved) || !ra_push(&vm->program->cells, V_CLEARED, &reserved)))
        return SIZE_MAX;
    if (vm->program->nfree_cells)
        return vm->program->free_cells[--vm->program->nfree_cells];
    if (vm->program->cells.count / 2 > CELL_MASK || !ra_push(&vm->program->cells, V_CLEARED, &entry) ||
        !ra_push(&vm->program->cells, V_CLEARED, &entry2))
        return SIZE_MAX;
    return entry / 2;
}

/* Once isolates exist, a new symbol is published as it is made, its name copied into the program
   space, under the lock: every isolate sees one symbol for a name. */
static V intern_shared(VM *vm, V name, uint64_t hash)
{
    pthread_mutex_lock(&shared_lock);
    V found = table_find(&vm->program->published, hash, string_bytes(name), string_length(name));
    V sym = found;
    uint64_t *p = found ? NULL : program_symbol_slot(vm);
    size_t words = obj_words(ptr(name)[0]);
    uint64_t *copy = p ? program_alloc(vm, words) : NULL;
    size_t cell = copy ? new_cell(vm) : SIZE_MAX;
    if (p && cell == SIZE_MAX) { /* what it took goes back, as the space's walks read every word */
        if (copy)
            program_unalloc(vm, copy, words);
        program_free_symbol(vm, p);
    }
    if (cell != SIZE_MAX) {
        memcpy(copy, ptr(name), words * sizeof(uint64_t));
        p[0] = HEADER(T_SYMBOL, 0);
        p[SYM_NAME] = tagged(copy, TAG_OBJECT);
        p[SYM_HASH] = hash;
        p[SYM_CELL] = cell | UINT64_C(1) << PUBLISHED_BIT |
                      name_kind((const unsigned char *)string_bytes(name), string_length(name)) << KIND_SHIFT;
        sym = tagged(p, TAG_SYMBOL);
        if (symbol_table_put(&vm->program->published, sym)) {
            if (cell >= vm->program->published_top)
                vm->program->published_top = cell + 1;
        } else {
            sym = 0;
        }
    }
    pthread_mutex_unlock(&shared_lock);
    return sym ? sym : FAILED;
}

/* A new symbol takes a slot of the program space and keeps its name where it is; publishing
   it moves the name there too. Nothing here allocates in the heap. */
static V intern_name(VM *vm, V name)
{
    uint64_t hash = hash_bytes(string_bytes(name), string_length(name));
    V found = find(vm, hash, string_bytes(name), string_length(name));
    if (found)
        return found;
    if (vm->program->isolates)
        return intern_shared(vm, name, hash);
    uint64_t *p = program_symbol_slot(vm);
    if (!p)
        return FAILED;
    size_t cell = new_cell(vm);
    if (cell == SIZE_MAX) {
        program_free_symbol(vm, p);
        return FAILED;
    }
    p[0] = HEADER(T_SYMBOL, 0);
    p[SYM_NAME] = name;
    p[SYM_HASH] = hash;
    p[SYM_CELL] = cell | name_kind((const unsigned char *)string_bytes(name),
                                   string_length(name)) << KIND_SHIFT;
    V sym = tagged(p, TAG_SYMBOL);
    if (!symbol_table_put(&vm->own, sym)) {
        program_free_symbol(vm, p);
        return FAILED;
    }
    return sym;
}

/* A global gets a number when code names it or it is set (vm.h), the next free one; once isolates
   exist, under the lock, and with a slot in every isolate before the symbol shows it. Nothing here
   allocates in the heap. */
V *global_slot_new(VM *vm, V sym)
{
    size_t n = symbol_global(sym);
    if (n)
        return &vm->globals[n];
    bool shared = vm->program->isolates != NULL;
    if (shared) {
        pthread_mutex_lock(&shared_lock);
        if ((n = symbol_global(sym))) {
            pthread_mutex_unlock(&shared_lock);
            return &vm->globals[n];
        }
    }
    V *slot = NULL;
    if (vm->program->nfree_globals) {
        n = vm->program->free_globals[--vm->program->nfree_globals];
    } else if (vm->program->nglobals <= CELL_MASK && vm_globals_commit(vm, vm->program->nglobals + 1) &&
               isolates_commit_globals(vm->program, vm->program->nglobals + 1)) { /* before any code can use it */
        n = vm->program->nglobals;
        __atomic_store_n(&vm->program->nglobals, n + 1, __ATOMIC_RELEASE); /* collections read it */
    } else {
        n = 0;
    }
    if (n) {
        __atomic_fetch_or(&ptr(sym)[SYM_CELL], (uint64_t)n << CELL_BITS, __ATOMIC_RELEASE);
        if (symbol_published(sym) && n >= vm->program->published_global_top)
            vm->program->published_global_top = n + 1;
        slot = &vm->globals[n];
    }
    if (shared)
        pthread_mutex_unlock(&shared_lock);
    return slot;
}

/* Interns bytes that are outside the heap. Shen strings must be interned with
   intern_string, which reuses the string as the name. */
V intern(VM *vm, const char *bytes, size_t len)
{
    V found = find(vm, hash_bytes(bytes, len), bytes, len);
    if (found)
        return found;
    V name = make_string(vm, bytes, len);
    return name == FAILED ? FAILED : intern_name(vm, name);
}

V intern_string(VM *vm, V string) { return intern_name(vm, string); }

/* The symbol of that name if there is one, or []: this makes nothing. */
V symbol_find(VM *vm, const char *bytes, size_t len)
{
    uint64_t hash = hash_bytes(bytes, len);
    V s = published_sure(vm, find(vm, hash, bytes, len), hash, bytes, len);
    return s ? s : V_NIL;
}

V intern_cstr(VM *vm, const char *s) { return intern(vm, s, strlen(s)); }

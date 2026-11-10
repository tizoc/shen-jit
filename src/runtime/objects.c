/* Object constructors and the symbol table. Every constructor roots its value
   arguments while it allocates; a NULL allocation returns V_CLEARED, which no
   Shen value equals, so callers can raise "out of memory". */
#include "vm.h"

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
    p[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->compile_stub;
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
    p[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->foreign_stub;
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
   address. The intern table is a vector used as an open-addressing hash set,
   held weakly: a collection drops the symbols that nothing else reaches and
   that symbol_needed does not keep (heap.c). */

uint64_t hash_bytes(const void *bytes, size_t len) { return XXH3_64bits(bytes, len); }

/* The word at SYM_CELL holds the global cell index. Its top byte holds the
   symbol's kind for shen-jit.symbol-kind (bits 56-57), whether the function
   it names is sealed (bit 58): calls to it may be bound once, and it cannot
   be redefined; and whether compiled code calls it by name (bit 59), through
   its cell's index rather than the symbol. */
enum { KIND_SHIFT = 56, SEALED_BIT = 58, CALLED_BIT = 59 };

size_t symbol_cell(V sym) { return (size_t)(ptr(sym)[SYM_CELL] & ((UINT64_C(1) << KIND_SHIFT) - 1)); }

bool symbol_sealed(V sym) { return (ptr(sym)[SYM_CELL] >> SEALED_BIT) & 1; }

void symbol_seal(V sym) { ptr(sym)[SYM_CELL] |= UINT64_C(1) << SEALED_BIT; }

void symbol_mark_called(V sym) { ptr(sym)[SYM_CELL] |= UINT64_C(1) << CALLED_BIT; }

/* Whether a symbol stays although only the intern table reaches it: interning
   its name again must find its value and function, and code that calls it by
   name holds its cell. Any other can go, and come back as a new symbol. */
bool symbol_needed(VM *vm, V sym)
{
    size_t cell = symbol_cell(sym);
    return (ptr(sym)[SYM_CELL] >> CALLED_BIT) & 1 || *cell_value(vm, cell) != V_CLEARED ||
           *cell_function(vm, cell) != V_CLEARED;
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

static size_t table_size(VM *vm) { return (size_t)hdr_size(ptr(vm->intern)[0]); }

static V *table_slot(VM *vm, uint64_t hash, const char *bytes, size_t len)
{
    size_t n = table_size(vm);
    V *slots = (V *)(ptr(vm->intern) + 1);
    for (size_t i = hash & (n - 1);; i = (i + 1) & (n - 1)) {
        V s = slots[i];
        if (s == V_NIL)
            return &slots[i];
        V name = ptr(s)[SYM_NAME];
        if (ptr(s)[SYM_HASH] == hash && string_length(name) == len &&
            memcmp(string_bytes(name), bytes, len) == 0)
            return &slots[i];
    }
}

/* The symbol whose cell is `cell`, or [] if none: a search of the symbol
   table, for error messages. */
V cell_symbol(VM *vm, size_t cell)
{
    size_t n = vm->intern == V_NIL ? 0 : table_size(vm);
    for (size_t i = 0; i < n; i++) {
        V s = ptr(vm->intern)[1 + i];
        if (s != V_NIL && symbol_cell(s) == cell)
            return s;
    }
    return V_NIL;
}

/* The new table goes in the semispace even when it is large: every collection builds the next
   one in to-space, in the room the old one leaves there. */
static bool table_grow(VM *vm)
{
    size_t n = vm->intern == V_NIL ? 0 : table_size(vm), m = n ? 2 * n : 1024;
    uint64_t *p = vm_alloc(vm, 1 + m);
    if (!p)
        return false;
    p[0] = HEADER(T_VECTOR, m);
    for (size_t i = 0; i < m; i++)
        p[1 + i] = V_NIL;
    /* The allocation may have collected, and the collection shrunk the table. */
    V old = vm->intern;
    n = old == V_NIL ? 0 : table_size(vm);
    vm->intern = tagged(p, TAG_OBJECT);
    for (size_t i = 0; i < n; i++) {
        V s = ((V *)(ptr(old) + 1))[i];
        if (s != V_NIL) {
            V name = ptr(s)[SYM_NAME];
            *table_slot(vm, ptr(s)[SYM_HASH], string_bytes(name), string_length(name)) = s;
        }
    }
    return true;
}

static V intern_name(VM *vm, V name)
{
    uint64_t hash = hash_bytes(string_bytes(name), string_length(name));
    V found = vm->intern == V_NIL ? V_NIL : *table_slot(vm, hash, string_bytes(name), string_length(name));
    if (found != V_NIL)
        return found;
    /* Only a new symbol can take the table past half full. */
    if (vm->intern == V_NIL || 2 * (vm->nsymbols + 1) > table_size(vm)) {
        vm_root(vm, &name);
        bool grown = table_grow(vm);
        vm_unroot(vm, 1);
        if (!grown)
            return FAILED;
    }

    vm_root(vm, &name);
    uint64_t *p = vm_alloc(vm, SYM_WORDS);
    vm_unroot(vm, 1);
    if (!p)
        return FAILED;
    /* After the allocation: a collection frees the cells of symbols not in the table,
       and this one is not in it yet. */
    size_t cell, cell2;
    if (vm->nfree_cells)
        cell = 2 * vm->free_cells[--vm->nfree_cells]; /* both entries are cleared */
    else if (!ra_push(&vm->cells, V_CLEARED, &cell) || !ra_push(&vm->cells, V_CLEARED, &cell2))
        return FAILED;
    p[0] = HEADER(T_SYMBOL, 0);
    p[SYM_NAME] = name;
    p[SYM_HASH] = hash;
    p[SYM_CELL] = cell / 2 | name_kind((const unsigned char *)string_bytes(name),
                                       string_length(name)) << KIND_SHIFT;
    V sym = tagged(p, TAG_SYMBOL);
    /* The allocation may have moved the table, so find the slot again. */
    *table_slot(vm, hash, string_bytes(name), string_length(name)) = sym;
    vm->nsymbols++;
    return sym;
}

/* Interns bytes that are outside the heap. Shen strings must be interned with
   intern_string, which reuses the string as the name. */
V intern(VM *vm, const char *bytes, size_t len)
{
    if (vm->intern != V_NIL) {
        V found = *table_slot(vm, hash_bytes(bytes, len), bytes, len);
        if (found != V_NIL)
            return found;
    }
    V name = make_string(vm, bytes, len);
    return name == FAILED ? FAILED : intern_name(vm, name);
}

V intern_string(VM *vm, V string) { return intern_name(vm, string); }

/* The symbol of that name if there is one, or []: this makes nothing. */
V symbol_find(VM *vm, const char *bytes, size_t len)
{
    return vm->intern == V_NIL ? V_NIL : *table_slot(vm, hash_bytes(bytes, len), bytes, len);
}

V intern_cstr(VM *vm, const char *s) { return intern(vm, s, strlen(s)); }

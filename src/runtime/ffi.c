/* C functions called from Shen (docs/ffi.md). Every one enters through the same stub
   (jit.c), which calls h_foreign. It converts the arguments as the description says and
   calls the function by casting it to a type that fills every argument register, so there is
   no code per signature. Functions are found by name on their first call, so an image saved
   with some finds them again in the next process. */
#include "../../include/shen.h"
#include "ops.h"
#include "vm.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32) && !defined(SHEN_JIT_STATIC)
#include <dlfcn.h>
#endif

/* A description is an absvector, built by lib/ffi.shen: */
enum {
    DESC_NAME,    /* the symbol defined; jit_backtrace reads it too */
    DESC_LIBRARY, /* the symbol naming the library, for messages */
    DESC_FILES,   /* the list of file names to try; [] for the executable */
    DESC_SYMBOL,  /* the function's name in C */
    DESC_RESULT,  /* a type */
    DESC_FLAGS,   /* below */
    DESC_KIND,    /* the kind of a pointer returned */
    DESC_TYPES    /* a type for each argument */
};
/* Types, as lib/ffi.shen numbers them. A procedure, C written for Shen, has F_LIMIT in place of
   its result and every argument. */
enum { F_VOID, F_INT64, F_INT32, F_UINT32, F_DOUBLE, F_STRING, F_POINTER, F_BYTES, F_BOOL, F_LIMIT };
enum { MAX_PROCEDURE_ARGUMENTS = 8 };
/* Flags: this bit, and above it the number of fixed arguments of a variadic function. */
enum { FLAG_BLOCKING = 1, FLAG_FIXED_SHIFT = 1, MAX_FIXED = 3 };
enum { MAX_WORDS = 6, MAX_DOUBLES = 8, MAX_ARGUMENTS = MAX_WORDS + MAX_DOUBLES };
enum { STRING_SPACE = 1024 }; /* for a call's strings, before it needs malloc */

typedef uint64_t W;
typedef double D;

/* Clang's function sanitizer checks a call's type against the callee's, which is what casting
   gets wrong on purpose. */
#ifdef __clang__
#define CASTS __attribute__((no_sanitize("function")))
#else
#define CASTS
#endif

#ifdef _WIN32
/* The first four arguments each take a register by position, a general one or a floating
   one, so there are 16 types of call, by which of them are doubles. The rest go on the stack
   as raw words, whatever they hold. */
typedef union { W w; D d; } Word;
typedef struct {
    Word at[MAX_ARGUMENTS];
    unsigned count, mask;
} Call;

static void put_word(Call *c, W w)
{
    c->at[c->count++].w = w;
}

static void put_double(Call *c, D d)
{
    if (c->count < 4)
        c->mask |= 1u << c->count;
    c->at[c->count++].d = d;
}

#define STACK_TYPES W, W, W, W, W, W, W, W, W, W
#define STACK_WORDS a[4].w, a[5].w, a[6].w, a[7].w, a[8].w, a[9].w, a[10].w, a[11].w, a[12].w, a[13].w
#define CASE(M, R, T0, F0, T1, F1, T2, F2, T3, F3) \
    case M: return ((R(*)(T0, T1, T2, T3, STACK_TYPES))f)(a[0].F0, a[1].F1, a[2].F2, a[3].F3, STACK_WORDS);
#define MASKS(R)                                                                                        \
    CASE(0, R, W, w, W, w, W, w, W, w) CASE(1, R, D, d, W, w, W, w, W, w)                               \
    CASE(2, R, W, w, D, d, W, w, W, w) CASE(3, R, D, d, D, d, W, w, W, w)                               \
    CASE(4, R, W, w, W, w, D, d, W, w) CASE(5, R, D, d, W, w, D, d, W, w)                               \
    CASE(6, R, W, w, D, d, D, d, W, w) CASE(7, R, D, d, D, d, D, d, W, w)                               \
    CASE(8, R, W, w, W, w, W, w, D, d) CASE(9, R, D, d, W, w, W, w, D, d)                               \
    CASE(10, R, W, w, D, d, W, w, D, d) CASE(11, R, D, d, D, d, W, w, D, d)                             \
    CASE(12, R, W, w, W, w, D, d, D, d) CASE(13, R, D, d, W, w, D, d, D, d)                             \
    CASE(14, R, W, w, D, d, D, d, D, d) default: CASE(15, R, D, d, D, d, D, d, D, d)

CASTS static W call_word(void *f, const Call *c)
{
    const Word *a = c->at;
    switch (c->mask) { MASKS(W) }
}

CASTS static D call_double(void *f, const Call *c)
{
    const Word *a = c->at;
    switch (c->mask) { MASKS(D) }
}

#define WORD(c, i) ((c)->at[i].w)

#else
/* Integers and doubles take their registers independently, so one type of call fills all of
   them, and a function reads those it has. */
typedef struct {
    W words[MAX_WORDS];
    D doubles[MAX_DOUBLES];
    unsigned nwords, ndoubles;
} Call;

static void put_word(Call *c, W w)
{
    c->words[c->nwords++] = w;
}

static void put_double(Call *c, D d)
{
    c->doubles[c->ndoubles++] = d;
}

#define TYPES W, W, W, W, W, W, D, D, D, D, D, D, D, D
#define VALUES                                                                       \
    c->words[0], c->words[1], c->words[2], c->words[3], c->words[4], c->words[5],    \
    c->doubles[0], c->doubles[1], c->doubles[2], c->doubles[3], c->doubles[4],       \
    c->doubles[5], c->doubles[6], c->doubles[7]

CASTS static W call_word(void *f, const Call *c) { return ((W(*)(TYPES))f)(VALUES); }

CASTS static D call_double(void *f, const Call *c) { return ((D(*)(TYPES))f)(VALUES); }

#define WORD(c, i) ((c)->words[i])
#endif

/* A variadic function takes its variable arguments elsewhere on some targets: on Apple's
   arm64, always on the stack. Its arguments are all integers here. Functions apart, and not
   inlined: as cases of one switch, clang made one call of the three, with the last's type. */
#define NOT_INLINED __attribute__((noinline))
#define WORDS WORD(c, 0), WORD(c, 1), WORD(c, 2), WORD(c, 3), WORD(c, 4), WORD(c, 5)

CASTS NOT_INLINED static W call_variadic1(void *f, const Call *c) { return ((W(*)(W, ...))f)(WORDS); }

CASTS NOT_INLINED static W call_variadic2(void *f, const Call *c) { return ((W(*)(W, W, ...))f)(WORDS); }

CASTS NOT_INLINED static W call_variadic3(void *f, const Call *c) { return ((W(*)(W, W, W, ...))f)(WORDS); }

static W call_variadic(void *f, const Call *c, unsigned fixed)
{
    return fixed == 1 ? call_variadic1(f, c) : fixed == 2 ? call_variadic2(f, c) : call_variadic3(f, c);
}

/* Loading. Libraries are remembered by the file names they were declared with, since trying
   names that do not exist is slow and a library has many functions. The lock guards them. */
#ifdef SHEN_JIT_STATIC
static void *resolve(VM *vm, uint64_t *f)
{
    (void)f;
    sj_raise(vm, "foreign: this static build cannot load libraries");
    return NULL;
}
#else
#ifndef _WIN32
static void *library_open(const char *file) { return dlopen(file, RTLD_NOW | RTLD_LOCAL); }
static void *library_find(void *library, const char *name) { return dlsym(library, name); }
#else
#define library_open win_library_open
#define library_find win_library_find
#endif

typedef struct {
    char *files;
    size_t length;
    void *library;
} Library;

static Library *libraries;
static size_t nlibraries;
static pthread_mutex_t library_lock = PTHREAD_MUTEX_INITIALIZER;

static void *open_library_locked(V files)
{
    char key[2048];
    size_t length = 0;
    for (; is_pair(files); files = ptr(files)[1]) {
        V file = ptr(files)[0];
        if (length + string_length(file) + 1 > sizeof key)
            return NULL;
        memcpy(key + length, string_bytes(file), string_length(file));
        length += string_length(file);
        key[length++] = 0;
    }
    for (size_t i = 0; i < nlibraries; i++)
        if (libraries[i].length == length && memcmp(libraries[i].files, key, length) == 0)
            return libraries[i].library;
    void *library = length ? NULL : library_open(NULL);
    for (size_t at = 0; at < length && !library; at += strlen(key + at) + 1)
        library = library_open(key + at);
    if (!library)
        return NULL;
    Library *more = realloc(libraries, (nlibraries + 1) * sizeof *more);
    char *copy = malloc(length + 1);
    if (more)
        libraries = more;
    if (more && copy) {
        memcpy(copy, key, length);
        libraries[nlibraries++] = (Library){copy, length, library};
    } else {
        free(copy);
    }
    return library;
}

static void *open_library(V files)
{
    pthread_mutex_lock(&library_lock);
    void *library = open_library_locked(files);
    pthread_mutex_unlock(&library_lock);
    return library;
}

static void *resolve(VM *vm, uint64_t *f)
{
    const uint64_t *desc = ptr(f[FOREIGN_DESC]) + 1;
    V symbol = desc[DESC_SYMBOL], name = ptr(desc[DESC_LIBRARY])[SYM_NAME];
    char c_name[256];
    snprintf(c_name, sizeof c_name, "%.*s", string_length(symbol) < 255 ? (int)string_length(symbol) : 255,
             string_bytes(symbol));
    void *library = open_library(desc[DESC_FILES]);
    void *address = library ? library_find(library, c_name) : NULL;
    if (!address) {
        char text[400];
        snprintf(text, sizeof text, "foreign: cannot find %s in %.*s", c_name,
                 string_length(name) < 64 ? (int)string_length(name) : 64, string_bytes(name));
        sj_raise_text(vm, text);
        return NULL;
    }
    f[FOREIGN_ADDRESS] = (uint64_t)(uintptr_t)address;
    return address;
}
#endif

/* What a call's arguments became. Strings go in space, or in blocks if they are too long. A
   call that gives up the lock works on copies of its byte buffers, in blocks too, since another
   thread's collection may move them: argument says which each one copies, or -1. */
typedef struct {
    Call call;
    char space[STRING_SPACE];
    size_t used;
    char *block[MAX_WORDS];
    int argument[MAX_WORDS];
    unsigned nblocks;
    bool copy_buffers;
} Converted;

static char *new_block(Converted *c, size_t size, int argument)
{
    char *p = malloc(size ? size : 1);
    if (p) {
        c->block[c->nblocks] = p;
        c->argument[c->nblocks++] = argument;
    }
    return p;
}

static void free_blocks(Converted *c)
{
    while (c->nblocks)
        free(c->block[--c->nblocks]);
}

/* Returns V_NIL, or V_CLEARED with the error raised. Allocates only to raise. */
static V convert(VM *vm, Converted *c, unsigned type, V v, int i)
{
    switch (type) {
    case F_INT64:
        if (!is_fix(v))
            return sj_raise_value(vm, "foreign: ~S is not an integer", v);
        put_word(&c->call, (W)fixval(v));
        return V_NIL;
    case F_INT32:
        if (!is_fix(v) || fixval(v) < INT32_MIN || fixval(v) > INT32_MAX)
            return sj_raise_value(vm, "foreign: ~S is not an int32", v);
        put_word(&c->call, (W)fixval(v));
        return V_NIL;
    case F_UINT32:
        if (!is_fix(v) || fixval(v) < 0 || fixval(v) > UINT32_MAX)
            return sj_raise_value(vm, "foreign: ~S is not a uint32", v);
        put_word(&c->call, (W)fixval(v));
        return V_NIL;
    case F_DOUBLE:
        if (is_fix(v))
            put_double(&c->call, (D)fixval(v));
        else if (is_object(v) && obj_type(v) == T_REAL)
            put_double(&c->call, real_value(v));
        else
            return sj_raise_value(vm, "foreign: ~S is not a number", v);
        return V_NIL;
    case F_BOOL:
        if (!is_boolean(v))
            return sj_raise_value(vm, "foreign: ~S is not a boolean", v);
        put_word(&c->call, v == V_TRUE);
        return V_NIL;
    case F_STRING: {
        if (!is_object(v) || obj_type(v) != T_STRING)
            return sj_raise_value(vm, "foreign: ~S is not a string", v);
        size_t length = string_length(v);
        if (memchr(string_bytes(v), 0, length))
            return sj_raise_value(vm, "foreign: ~S has a NUL in it", v);
        char *to;
        if (c->used + length + 1 <= STRING_SPACE) {
            to = c->space + c->used;
            c->used += length + 1;
        } else if (!(to = new_block(c, length + 1, -1))) {
            return sj_raise(vm, "out of memory");
        }
        memcpy(to, string_bytes(v), length);
        to[length] = 0;
        put_word(&c->call, (W)(uintptr_t)to);
        return V_NIL;
    }
    case F_POINTER:
        if (v == V_NIL)
            put_word(&c->call, 0);
        else if (!is_object(v) || obj_type(v) != T_POINTER)
            return sj_raise_value(vm, "foreign: ~S is not a pointer", v);
        else if (!ptr(v)[POINTER_ADDRESS])
            return sj_raise_value(vm, "foreign: ~S is dead: it was closed, or came from an image", v);
        else
            put_word(&c->call, ptr(v)[POINTER_ADDRESS]);
        return V_NIL;
    case F_BYTES: {
        if (!is_object(v) || obj_type(v) != T_BYTES)
            return sj_raise_value(vm, "foreign: ~S is not a byte buffer", v);
        char *to = string_bytes(v);
        if (c->copy_buffers) {
            /* A buffer given twice is one copy, which goes back once. */
            for (unsigned k = 0; k < c->nblocks; k++)
                if (c->argument[k] >= 0 && vm->fp[2 + c->argument[k]] == v) {
                    put_word(&c->call, (W)(uintptr_t)c->block[k]);
                    return V_NIL;
                }
            if (!(to = new_block(c, string_length(v), i)))
                return sj_raise(vm, "out of memory");
            memcpy(to, string_bytes(v), string_length(v));
        }
        put_word(&c->call, (W)(uintptr_t)to);
        return V_NIL;
    }
    default:
        return sj_raise(vm, "foreign: a description with a type it should not have");
    }
}

static V result_string(VM *vm, const char *s, bool may_be_in_heap)
{
    if (!s)
        return V_NIL;
    size_t length = strlen(s);
    char *copy = NULL;
    /* A function may return a pointer into a byte buffer it was given, which allocating may move. */
    if (may_be_in_heap && (copy = malloc(length ? length : 1))) {
        memcpy(copy, s, length);
        s = copy;
    }
    V string = make_string(vm, s, length);
    free(copy);
    return string;
}

static V call_procedure(VM *vm, void *function, size_t n);

V h_foreign(VM *vm)
{
    uint64_t *f = ptr(vm->fp[1]);
    const uint64_t *desc = ptr(f[FOREIGN_DESC]) + 1;
    size_t n = vm->count;
    if (n != f[FOREIGN_ARITY])
        return sj_raise_arity(vm, desc[DESC_NAME], (size_t)f[FOREIGN_ARITY], n);
    void *function = (void *)(uintptr_t)f[FOREIGN_ADDRESS];
    if (!function && !(function = resolve(vm, f)))
        return V_CLEARED;
    int64_t flags = fixval(desc[DESC_FLAGS]);
    unsigned result = (unsigned)fixval(desc[DESC_RESULT]), fixed = (unsigned)(flags >> FLAG_FIXED_SHIFT);
    if (result == F_LIMIT && vm->worker_owner)
        return sj_raise(vm, "worker: C API procedures and callbacks are not supported");
    if (result == F_LIMIT)
        return call_procedure(vm, function, n);
    Converted c;
    memset(&c.call, 0, sizeof c.call);
    c.used = 0;
    c.nblocks = 0;
    /* Without other threads, nothing can happen while it waits, so it just waits. */
    bool blocking = (flags & FLAG_BLOCKING) && vm->threads;
    c.copy_buffers = blocking;
    bool buffers = false;
    for (size_t i = 0; i < n; i++) {
        unsigned type = (unsigned)fixval(desc[DESC_TYPES + i]);
        buffers |= type == F_BYTES;
        if (convert(vm, &c, type, vm->fp[2 + i], (int)i) == V_CLEARED) {
            free_blocks(&c);
            return V_CLEARED;
        }
    }

    Thread *t = blocking ? thread_leave(vm) : NULL;
    W word = 0;
    D real = 0;
    if (fixed)
        word = call_variadic(function, &c.call, fixed);
    else if (result == F_DOUBLE)
        real = call_double(function, &c.call);
    else
        word = call_word(function, &c.call);
#ifdef _WIN32
    int error = win_last_error(), c_error = errno;
#else
    int error = errno, c_error = error;
#endif
    if (t)
        thread_enter(t);
    vm->foreign_error = error;
    vm->foreign_c_error = c_error;

    /* Everything read from the heap before the call may have moved, but the slots are up to date. */
    for (unsigned i = 0; i < c.nblocks; i++)
        if (c.argument[i] >= 0) {
            V buffer = vm->fp[2 + c.argument[i]];
            memcpy(string_bytes(buffer), c.block[i], string_length(buffer));
        }

    V out;
    switch (result) {
    case F_VOID: out = V_NIL; break;
    case F_INT32: out = fix((int32_t)word); break;
    case F_UINT32: out = fix((uint32_t)word); break;
    case F_BOOL: out = (word & 0xFF) ? V_TRUE : V_FALSE; break;
    case F_DOUBLE: out = make_real(vm, real); break;
    case F_STRING: out = result_string(vm, (const char *)(uintptr_t)word, buffers && !blocking); break;
    case F_POINTER:
        out = word ? make_pointer(vm, word, ptr(ptr(vm->fp[1])[FOREIGN_DESC])[1 + DESC_KIND]) : V_NIL;
        break;
    default: /* F_INT64 */
        if (!fix_fits((int64_t)word)) {
            free_blocks(&c);
            char text[80];
            snprintf(text, sizeof text, "foreign: the result %lld is too big for an integer", (long long)word);
            return sj_raise_text(vm, text);
        }
        out = fix((int64_t)word);
        break;
    }
    free_blocks(&c); /* only now: a result may point into a string given to the call */
    return out == V_CLEARED ? sj_raise(vm, "out of memory") : out;
}

/* (shen-jit.foreign Name Desc): checks the description, as the code above trusts it, and makes
   Name that function. A foreign procedure is only ever called by name. */
static V define_foreign(VM *vm)
{
    V name = vm->args[0], desc = vm->args[1];
    if (!is_symbol(name))
        return sj_raise_value(vm, "shen-jit.foreign: ~S is not a symbol", name);
    if (symbol_sealed(name))
        return sj_raise_value(vm, "~S is sealed and cannot be redefined", name);
    if (!is_object(desc) || obj_type(desc) != T_VECTOR || hdr_size(ptr(desc)[0]) < DESC_TYPES)
        return sj_raise_value(vm, "shen-jit.foreign: ~S is not a description", desc);
    const uint64_t *d = ptr(desc) + 1;
    size_t arity = (size_t)hdr_size(ptr(desc)[0]) - DESC_TYPES;
    bool files = true;
    V l = d[DESC_FILES];
    for (; is_pair(l); l = ptr(l)[1])
        files = files && is_object(ptr(l)[0]) && obj_type(ptr(l)[0]) == T_STRING;
    if (l != V_NIL || !files || !is_symbol(d[DESC_LIBRARY]) || !is_symbol(d[DESC_NAME]) || !is_symbol(d[DESC_KIND]) ||
        !is_object(d[DESC_SYMBOL]) || obj_type(d[DESC_SYMBOL]) != T_STRING || !is_fix(d[DESC_FLAGS]) ||
        !is_fix(d[DESC_RESULT]) || fixval(d[DESC_RESULT]) < 0 || fixval(d[DESC_RESULT]) > F_LIMIT ||
        fixval(d[DESC_RESULT]) == F_BYTES)
        return sj_raise_value(vm, "shen-jit.foreign: ~S is not a description", desc);
    bool procedure = fixval(d[DESC_RESULT]) == F_LIMIT;
    size_t words = 0, doubles = 0;
    for (size_t i = 0; i < arity; i++) {
        V type = d[DESC_TYPES + i];
        if (!is_fix(type) || fixval(type) <= F_VOID || fixval(type) > F_LIMIT ||
            (fixval(type) == F_LIMIT) != procedure)
            return sj_raise_value(vm, "shen-jit.foreign: ~S is not a description", desc);
        if (fixval(type) == F_DOUBLE)
            doubles++;
        else
            words++;
    }
    if (procedure ? arity > MAX_PROCEDURE_ARGUMENTS : words > MAX_WORDS || doubles > MAX_DOUBLES)
        return sj_raise_value(vm, procedure ? "foreign: ~S has too many arguments: at most 8"
                                            : "foreign: ~S has too many arguments: at most 6, and 8 doubles", name);
    int64_t fixed = fixval(d[DESC_FLAGS]) >> FLAG_FIXED_SHIFT;
    if (fixed < 0 || fixed > MAX_FIXED || (size_t)fixed > arity)
        return sj_raise_value(vm, "foreign: ~S takes 1 to 3 fixed arguments, and no more than it has", name);
    if (fixed && (doubles || fixval(d[DESC_RESULT]) == F_DOUBLE))
        return sj_raise_value(vm, "foreign: ~S is variadic, so it cannot use doubles", name);
    V proc = make_foreign(vm, desc, arity);
    if (proc == V_CLEARED)
        return sj_raise(vm, "out of memory");
    name = vm->args[0]; /* it may have moved */
    size_t cell = symbol_cell(name);
    if (vm->redefine)
        vm->redefine(vm, cell);
    *cell_function(vm, cell) = proc;
    if (vm->seal_user)
        symbol_seal(name);
    return name;
}

static bool is_pointer(V v) { return is_object(v) && obj_type(v) == T_POINTER; }

/* A new pointer to what the first argument points to, as it is, and which keeps it alive. */
static V copy_pointer(VM *vm)
{
    V p = make_pointer(vm, ptr(vm->args[0])[POINTER_ADDRESS], ptr(vm->args[0])[POINTER_KIND]);
    if (p == V_CLEARED)
        return p;
    ptr(p)[0] = ptr(vm->args[0])[0];
    ptr(p)[POINTER_LENGTH] = ptr(vm->args[0])[POINTER_LENGTH];
    ptr(p)[POINTER_OWNER] = vm->args[0];
    return p;
}

V ffi_primitive(VM *vm, unsigned prim)
{
    V a = vm->args[0], b = vm->args[1], k = vm->args[2];
    switch (prim) {
    case P_FOREIGN: return define_foreign(vm);
    case P_POINTERP: return is_pointer(a) ? V_TRUE : V_FALSE;
    case P_POINTER_KIND:
        return is_pointer(a) ? ptr(a)[POINTER_KIND] : sj_raise_value(vm, "shen-jit.pointer-kind: ~S is not a pointer", a);
    case P_POINTER_ADDRESS: {
        if (!is_pointer(a))
            return sj_raise_value(vm, "shen-jit.pointer-address: ~S is not a pointer", a);
        int64_t address = (int64_t)ptr(a)[POINTER_ADDRESS];
        return fix_fits(address) ? fix(address) : sj_raise_value(vm, "shen-jit.pointer-address: ~S is out of range", a);
    }
    case P_BYTES_POINTER: {
        char *base;
        size_t length;
        if (!memory_of(a, &base, &length))
            return sj_raise_value(vm, "shen-jit.bytes->pointer: ~S is not a byte buffer", a);
        if (!is_fix(b) || fixval(b) < 0 || (uint64_t)fixval(b) + sizeof(W) > length)
            return sj_raise_value(vm, "shen-jit.bytes->pointer: ~S is not a valid offset", b);
        if (!is_symbol(k))
            return sj_raise_value(vm, "shen-jit.bytes->pointer: ~S is not a symbol", k);
        W address;
        memcpy(&address, base + fixval(b), sizeof address);
        if (!address)
            return V_NIL;
        V p = make_pointer(vm, address, k);
        return p == V_CLEARED ? sj_raise(vm, "out of memory") : p;
    }
    case P_POINTER_STRING: {
        if (!is_pointer(a) || !ptr(a)[POINTER_ADDRESS])
            return sj_raise_value(vm, "shen-jit.pointer->string: ~S is not a live pointer", a);
        V s = result_string(vm, (const char *)(uintptr_t)ptr(a)[POINTER_ADDRESS], false);
        return s == V_CLEARED ? sj_raise(vm, "out of memory") : s;
    }
    case P_POINTER_BYTES: {
        if (!is_pointer(a) || !ptr(a)[POINTER_ADDRESS])
            return sj_raise_value(vm, "shen-jit.pointer->bytes: ~S is not a live pointer", a);
        if (!is_fix(b) || fixval(b) < 0)
            return sj_raise_value(vm, "shen-jit.pointer->bytes: ~S is not a valid offset", b);
        if (!is_fix(k) || fixval(k) < 0)
            return sj_raise_value(vm, "shen-jit.pointer->bytes: ~S is not a valid length", k);
        V bytes = make_bytes(vm, (const char *)(uintptr_t)ptr(a)[POINTER_ADDRESS] + fixval(b), (size_t)fixval(k));
        return bytes == V_CLEARED ? sj_raise(vm, "out of memory") : bytes;
    }
    case P_POINTER_KILL: /* for a library, once C has freed what it points to */
        if (!is_pointer(a))
            return sj_raise_value(vm, "shen-jit.pointer-kill: ~S is not a pointer", a);
        ptr(a)[POINTER_ADDRESS] = 0;
        ptr(a)[POINTER_LENGTH] = 0;
        return a;
    case P_POINTER_SIZED: { /* a new pointer to the same address, whose bytes can be read */
        if (!is_pointer(a) || !ptr(a)[POINTER_ADDRESS])
            return sj_raise_value(vm, "shen-jit.pointer-sized: ~S is not a live pointer", a);
        if (!is_fix(b) || fixval(b) < 0)
            return sj_raise_value(vm, "shen-jit.pointer-sized: ~S is not a valid length", b);
        V p = copy_pointer(vm);
        if (p == V_CLEARED)
            return sj_raise(vm, "out of memory");
        ptr(p)[POINTER_LENGTH] = (uint64_t)fixval(b);
        return p;
    }
    case P_POINTER_READ_ONLY: {
        if (!is_pointer(a) || !ptr(a)[POINTER_ADDRESS])
            return sj_raise_value(vm, "shen-jit.pointer-read-only: ~S is not a live pointer", a);
        V p = copy_pointer(vm);
        if (p == V_CLEARED)
            return sj_raise(vm, "out of memory");
        ptr(p)[0] = HEADER(T_POINTER, 1);
        return p;
    }
    case P_POINTER_GUARD: { /* a copy with the same length, whose value is taken once it dies */
        if (!is_pointer(a) || !ptr(a)[POINTER_ADDRESS])
            return sj_raise_value(vm, "shen-jit.pointer-guard: ~S is not a live pointer", a);
        V p = copy_pointer(vm);
        if (p == V_CLEARED)
            return sj_raise(vm, "out of memory");
        ptr(p)[POINTER_OWNER] = vm->args[1];
        return vm_guard(vm, p, vm->args[1]) ? p : sj_raise(vm, "out of memory");
    }
    case P_POINTER_OWNER:
        return is_pointer(a) ? ptr(a)[POINTER_OWNER] : sj_raise_value(vm, "shen-jit.pointer-owner: ~S is not a pointer", a);
    case P_POINTERS_DEAD: {
        V dead = vm->dead;
        vm->dead = V_NIL;
        return dead;
    }
    case P_SET_POINTER: { /* a pointer field: the buffer or memory, the offset, a pointer or [] */
        char *base;
        size_t length;
        if (!memory_of(a, &base, &length))
            return sj_raise_value(vm, "shen-jit.pointer!: ~S is not a byte buffer", a);
        if (is_read_only(a))
            return sj_raise_value(vm, "shen-jit.pointer!: ~S is read only", a);
        if (!is_fix(b) || fixval(b) < 0 || (uint64_t)fixval(b) + sizeof(W) > length)
            return sj_raise_value(vm, "shen-jit.pointer!: ~S is not a valid offset", b);
        if (k != V_NIL && (!is_pointer(k) || !ptr(k)[POINTER_ADDRESS]))
            return sj_raise_value(vm, "shen-jit.pointer!: ~S is not a live pointer or []", k);
        W address = k == V_NIL ? 0 : ptr(k)[POINTER_ADDRESS];
        memcpy(base + fixval(b), &address, sizeof address);
        return a;
    }
    case P_ERRNO: return fix(vm->foreign_error);
    case P_C_ERRNO: return fix(vm->foreign_c_error);
    default: return sj_raise(vm, "unknown primitive");
    }
}

/* C written for Shen (include/shen.h). What it is given is the address of vm->api, so that it
   links against nothing, and it comes back here through the table. */
_Static_assert(SHEN_NIL == V_NIL && SHEN_FALSE == V_FALSE && SHEN_TRUE == V_TRUE && SHEN_ERROR == V_CLEARED &&
               SHEN_NONE == V_NONE, "shen.h has the constants of value.h");

static VM *vm_of(shen_vm *v) { return (VM *)(void *)((char *)v - offsetof(VM, api)); }

/* Using the API wrongly ends the process, naming the procedure that did. Not by abort, which would
   bring up a crash report, or on Windows perhaps a dialog, for what the message already says. */
static void misuse(VM *vm, const char *who, const char *what)
{
    V f = vm && vm->fp ? vm->fp[1] : V_NIL;
    V name = is_proc(f) && hdr_type(ptr(f)[0]) == T_FOREIGN ? ptr(ptr(ptr(f)[FOREIGN_DESC])[1 + DESC_NAME])[SYM_NAME] : V_NIL;
    fflush(stdout);
    fprintf(stderr, "shen-jit: foreign function %.*s: %s %s\n", name == V_NIL ? 1 : (int)string_length(name),
            name == V_NIL ? "?" : string_bytes(name), who, what);
    _Exit(70);
}

static void check_pointer(VM *vm, V v, const char *who)
{
    if (is_ptr(v) && !vm_in_heap(vm, ptr(v)) && !in_program(vm, ptr(v)))
        misuse(vm, who, "a value from before a collection: see rule 1 in shen.h");
}

/* A value going into anything that keeps or passes it on. */
static V checked(VM *vm, V v, const char *who)
{
    if (v == V_NONE)
        misuse(vm, who, "SHEN_NONE, from a read of the wrong type");
    if (v == V_CLEARED)
        misuse(vm, who, "SHEN_ERROR, which must be returned, not passed on");
    check_pointer(vm, v, who);
    return v;
}

/* A read checks only under stress, where a value left over from before an allocation is certain
   to show: reads are what a loop over a list is made of. */
#define READ(v, who)            \
    VM *vm = vm_of(sv);         \
    if (vm->stress)             \
        check_pointer(vm, v, who)

static bool has_type(V v, unsigned type) { return is_object(v) && obj_type(v) == type; }

static int api_is_string(shen_vm *sv, shen_value v) { READ(v, "shen_is_string was given"); return has_type(v, T_STRING); }
static int api_is_pair(shen_vm *sv, shen_value v) { READ(v, "shen_is_pair was given"); return is_pair(v); }
static int api_is_vector(shen_vm *sv, shen_value v) { READ(v, "shen_is_vector was given"); return has_type(v, T_VECTOR); }
static int api_is_symbol(shen_vm *sv, shen_value v) { READ(v, "shen_is_symbol was given"); return is_symbol(v); }
static int api_is_real(shen_vm *sv, shen_value v) { READ(v, "shen_is_real was given"); return has_type(v, T_REAL); }
static int api_is_bytes(shen_vm *sv, shen_value v) { READ(v, "shen_is_bytes was given"); return has_type(v, T_BYTES); }
static int api_is_procedure(shen_vm *sv, shen_value v) { READ(v, "shen_is_procedure was given"); return is_proc(v); }

static double api_number(shen_vm *sv, shen_value v)
{
    READ(v, "shen_number was given");
    return is_fix(v) ? (double)fixval(v) : has_type(v, T_REAL) ? real_value(v) : __builtin_nan("");
}

static shen_value api_head(shen_vm *sv, shen_value v)
{
    READ(v, "shen_head was given");
    return is_pair(v) ? ptr(v)[0] : V_NONE;
}

static shen_value api_tail(shen_vm *sv, shen_value v)
{
    READ(v, "shen_tail was given");
    return is_pair(v) ? ptr(v)[1] : V_NONE;
}

static int64_t api_vector_length(shen_vm *sv, shen_value v)
{
    READ(v, "shen_vector_length was given");
    return has_type(v, T_VECTOR) ? (int64_t)hdr_size(ptr(v)[0]) : -1;
}

static shen_value api_vector_ref(shen_vm *sv, shen_value v, int64_t i)
{
    READ(v, "shen_vector_ref was given");
    return has_type(v, T_VECTOR) && i >= 0 && (uint64_t)i < hdr_size(ptr(v)[0]) ? ptr(v)[1 + i] : V_NONE;
}

static shen_value api_symbol_name(shen_vm *sv, shen_value v)
{
    READ(v, "shen_symbol_name was given");
    return is_symbol(v) ? ptr(v)[SYM_NAME] : V_NONE;
}

static const char *api_string_bytes(shen_vm *sv, shen_value v, size_t *length)
{
    READ(v, "shen_string_bytes was given");
    if (!has_type(v, T_STRING))
        return NULL;
    if (length)
        *length = string_length(v);
    return string_bytes(v);
}

static int64_t api_string_copy(shen_vm *sv, shen_value v, char *to, size_t size)
{
    READ(v, "shen_string_copy was given");
    if (!has_type(v, T_STRING))
        return -1;
    if (size) {
        size_t n = string_length(v) < size - 1 ? string_length(v) : size - 1;
        memcpy(to, string_bytes(v), n);
        to[n] = 0;
    }
    return (int64_t)string_length(v);
}

static unsigned char *api_bytes_data(shen_vm *sv, shen_value v, size_t *length)
{
    READ(v, "shen_bytes_data was given");
    if (!has_type(v, T_BYTES))
        return NULL;
    if (length)
        *length = string_length(v);
    return (unsigned char *)string_bytes(v);
}

static void *api_pointer(shen_vm *sv, shen_value v, const char *kind)
{
    READ(v, "shen_pointer was given");
    if (!has_type(v, T_POINTER))
        return NULL;
    if (kind) {
        V name = ptr(ptr(v)[POINTER_KIND])[SYM_NAME];
        if (string_length(name) != strlen(kind) || memcmp(string_bytes(name), kind, strlen(kind)) != 0)
            return NULL;
    }
    return (void *)(uintptr_t)ptr(v)[POINTER_ADDRESS];
}

static shen_value api_global(shen_vm *sv, const char *name)
{
    VM *vm = vm_of(sv);
    V symbol = symbol_find(vm, name, strlen(name));
    V value = symbol == V_NIL ? V_CLEARED : global_value(vm, symbol);
    return value == V_CLEARED ? V_NONE : value;
}

static shen_value api_function(shen_vm *sv, const char *name)
{
    VM *vm = vm_of(sv);
    V symbol = symbol_find(vm, name, strlen(name));
    V value = symbol == V_NIL ? V_CLEARED : *cell_function(vm, symbol_cell(symbol));
    return value == V_CLEARED ? V_NONE : value;
}

/* What the makers below come to. */
static V made(VM *vm, V v) { return v == V_CLEARED ? sj_raise(vm, "out of memory") : v; }

static shen_value api_make_real(shen_vm *sv, double d)
{
    VM *vm = vm_of(sv);
    return made(vm, make_real(vm, d));
}

/* Bytes from a string or buffer would move in the allocation, so they are copied first. */
static V make_from_bytes(VM *vm, V (*make)(VM *, const char *, size_t), const char *bytes, size_t length)
{
    char *copy = NULL;
    if (bytes && length && vm_in_heap(vm, bytes)) {
        if (!(copy = malloc(length)))
            return sj_raise(vm, "out of memory");
        memcpy(copy, bytes, length);
    }
    V v = make(vm, copy ? copy : bytes, length);
    free(copy);
    return made(vm, v);
}

static V make_bytes_of_chars(VM *vm, const char *bytes, size_t length) { return make_bytes(vm, bytes, length); }

static shen_value api_make_string(shen_vm *sv, const char *bytes, size_t length)
{
    return make_from_bytes(vm_of(sv), make_string, bytes, length);
}

static shen_value api_make_bytes(shen_vm *sv, const void *bytes, size_t length)
{
    return make_from_bytes(vm_of(sv), make_bytes_of_chars, bytes, length);
}

static shen_value api_cons(shen_vm *sv, shen_value head, shen_value tail)
{
    VM *vm = vm_of(sv);
    checked(vm, head, "shen_cons was given");
    checked(vm, tail, "shen_cons was given");
    return made(vm, make_pair(vm, head, tail));
}

static shen_value api_make_vector(shen_vm *sv, int64_t length, shen_value fill)
{
    VM *vm = vm_of(sv);
    checked(vm, fill, "shen_make_vector was given");
    if (length < 0)
        return sj_raise(vm, "shen_make_vector: a negative length");
    return made(vm, make_vector(vm, (size_t)length, fill));
}

/* Text from a buffer in the heap would move in an allocation, so it is copied first, into *copy,
   which the caller frees. False if it cannot be. */
static bool outside_heap(VM *vm, const char **text, char **copy)
{
    *copy = NULL;
    if (!*text || !vm_in_heap(vm, *text))
        return true;
    size_t n = strlen(*text) + 1;
    if (!(*copy = malloc(n)))
        return false;
    *text = memcpy(*copy, *text, n);
    return true;
}

/* As intern does in Shen: these two are not symbols. */
static shen_value api_intern(shen_vm *sv, const char *name)
{
    VM *vm = vm_of(sv);
    if (strcmp(name, "true") == 0)
        return V_TRUE;
    if (strcmp(name, "false") == 0)
        return V_FALSE;
    char *copy;
    if (!outside_heap(vm, &name, &copy))
        return sj_raise(vm, "out of memory");
    V symbol = intern_cstr(vm, name);
    free(copy);
    return made(vm, symbol);
}

static shen_value api_make_pointer(shen_vm *sv, void *address, const char *kind)
{
    VM *vm = vm_of(sv);
    if (!address)
        return V_NIL;
    char *copy;
    if (!outside_heap(vm, &kind, &copy))
        return sj_raise(vm, "out of memory");
    V symbol = intern_cstr(vm, kind);
    free(copy);
    if (symbol == V_CLEARED)
        return sj_raise(vm, "out of memory");
    return made(vm, make_pointer(vm, (uint64_t)(uintptr_t)address, symbol));
}

static int api_vector_set(shen_vm *sv, shen_value v, int64_t i, shen_value x)
{
    VM *vm = vm_of(sv);
    checked(vm, x, "shen_vector_set was given");
    if (!has_type(v, T_VECTOR) || i < 0 || (uint64_t)i >= hdr_size(ptr(v)[0]))
        return 0;
    ptr(v)[1 + i] = x;
    return 1;
}

static void api_root(shen_vm *sv, shen_value *local)
{
    VM *vm = vm_of(sv);
    checked(vm, *local, "shen_root was given");
    vm_root(vm, local);
}

static void api_unroot(shen_vm *sv, size_t how_many)
{
    VM *vm = vm_of(sv);
    if (how_many > vm->ncroots)
        misuse(vm, "shen_unroot was given", "more than are rooted");
    vm->ncroots -= how_many;
}

/* Deletes can arrive from another OS thread, but only the owning VM drains its
   queue. The adapter must delete its boxes before that VM is destroyed. */

void ffi_drain_roots(VM *vm)
{
    if (!__atomic_load_n(&vm->deleted_foreign_roots, __ATOMIC_RELAXED))
        return;
    ForeignRoot *r = __atomic_exchange_n(&vm->deleted_foreign_roots, NULL, __ATOMIC_ACQUIRE);
    while (r) {
        ForeignRoot *next = r->next;
        r->value = V_NIL;
        r->next = vm->free_foreign_roots;
        vm->free_foreign_roots = r;
        r = next;
    }
}

static shen_root_box *api_root_new(shen_vm *sv, shen_value v)
{
    VM *vm = vm_of(sv);
    checked(vm, v, "shen_root_new was given");
    ffi_drain_roots(vm);
    ForeignRoot *r = vm->free_foreign_roots;
    if (r) {
        vm->free_foreign_roots = r->next;
    } else {
        size_t i = vm->nforeign_roots;
        if (i % FOREIGN_ROOT_CHUNK == 0) {
            ForeignRoot **chunks = realloc(vm->foreign_roots, (i / FOREIGN_ROOT_CHUNK + 1) * sizeof *chunks);
            if (!chunks)
                return NULL;
            vm->foreign_roots = chunks;
            if (!(chunks[i / FOREIGN_ROOT_CHUNK] = malloc(FOREIGN_ROOT_CHUNK * sizeof **chunks)))
                return NULL;
            for (size_t k = 0; k < FOREIGN_ROOT_CHUNK; k++)
                chunks[i / FOREIGN_ROOT_CHUNK][k].value = V_NIL; /* so a collection can scan them */
        }
        r = &vm->foreign_roots[i / FOREIGN_ROOT_CHUNK][i % FOREIGN_ROOT_CHUNK];
        vm->nforeign_roots = i + 1;
    }
    r->api = vm->api;
    r->owner = vm;
    r->value = v;
    r->next = NULL;
    return (shen_root_box *)r;
}

static shen_value api_root_get(shen_root_box *box) { return ((ForeignRoot *)box)->value; }

static void api_root_set(shen_root_box *box, shen_value v)
{
    if (v == V_NONE || v == V_CLEARED)
        misuse(NULL, "shen_root_set was given", v == V_NONE ? "SHEN_NONE" : "SHEN_ERROR");
    ((ForeignRoot *)box)->value = v;
}

static void api_root_delete(shen_root_box *box)
{
    ForeignRoot *r = (ForeignRoot *)box;
    ForeignRoot **queue = &r->owner->deleted_foreign_roots;
    ForeignRoot *head = __atomic_load_n(queue, __ATOMIC_RELAXED);
    do
        r->next = head;
    while (!__atomic_compare_exchange_n(queue, &head, r, true, __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}

static shen_value api_call(shen_vm *sv, shen_value f, size_t n, const shen_value *args)
{
    VM *vm = vm_of(sv);
    checked(vm, f, "shen_call was given");
    for (size_t i = 0; i < n; i++)
        checked(vm, args[i], "shen_call was given");
    return jit_call_nested(vm, f, n, args);
}

/* v is V_CLEARED for none. */
static V raise_text(VM *vm, const char *message, V v)
{
    char *copy;
    if (!outside_heap(vm, &message, &copy))
        return sj_raise(vm, "out of memory");
    V e = sj_raise_text_value(vm, message, v);
    free(copy);
    return e;
}

static shen_value api_raise(shen_vm *sv, const char *message) { return raise_text(vm_of(sv), message, V_CLEARED); }

static shen_value api_raise_value(shen_vm *sv, const char *message, shen_value v)
{
    VM *vm = vm_of(sv);
    return raise_text(vm, message, checked(vm, v, "shen_raise_value was given"));
}

static shen_value api_exception(shen_vm *sv)
{
    V e = vm_of(sv)->exception;
    return e == V_NIL ? V_NONE : e;
}

static shen_value api_exception_message(shen_vm *sv)
{
    VM *vm = vm_of(sv);
    if (vm->exception == V_NIL)
        return V_NONE;
    return made(vm, exception_message(vm, vm->exception));
}

static void *api_release(shen_vm *sv)
{
    VM *vm = vm_of(sv);
    return vm->threads ? thread_leave(vm) : NULL;
}

static void api_acquire(shen_vm *sv, void *token)
{
    if (token)
        thread_enter(token);
}

static const struct shen_api api_table = {
    .version = SHEN_API_VERSION,
    .is_string = api_is_string, .is_pair = api_is_pair, .is_vector = api_is_vector, .is_symbol = api_is_symbol,
    .is_real = api_is_real, .is_bytes = api_is_bytes, .is_procedure = api_is_procedure,
    .number = api_number, .head = api_head, .tail = api_tail,
    .vector_length = api_vector_length, .vector_ref = api_vector_ref, .symbol_name = api_symbol_name,
    .string_bytes = api_string_bytes, .string_copy = api_string_copy, .bytes_data = api_bytes_data,
    .pointer = api_pointer, .global = api_global, .function = api_function,
    .make_real = api_make_real, .make_string = api_make_string, .make_bytes = api_make_bytes,
    .cons = api_cons, .make_vector = api_make_vector, .intern = api_intern, .make_pointer = api_make_pointer,
    .vector_set = api_vector_set,
    .root = api_root, .unroot = api_unroot,
    .root_new = api_root_new, .root_get = api_root_get, .root_set = api_root_set, .root_delete = api_root_delete,
    .call = api_call,
    .raise = api_raise, .raise_value = api_raise_value,
    .exception = api_exception, .exception_message = api_exception_message,
    .release = api_release, .acquire = api_acquire,
};

const struct shen_api *ffi_api(void) { return &api_table; }

/* Arguments in an array that stays up to date, as the guest stack may move. Returning unroots what
   C rooted, so an early return is safe. */
CASTS static V call_procedure(VM *vm, void *function, size_t n)
{
    V args[MAX_PROCEDURE_ARGUMENTS];
    size_t roots = vm->ncroots;
    for (size_t i = 0; i < n; i++) {
        args[i] = vm->fp[2 + i];
        vm_root(vm, &args[i]);
    }
    V out = ((shen_value(*)(shen_vm *, shen_value *))function)(&vm->api, args);
    vm->ncroots = roots;
    if (out == V_CLEARED)
        return out;
    return checked(vm, out, "it returned");
}


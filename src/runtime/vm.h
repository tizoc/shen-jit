/* The VM context: heap, guest stack and roots. */
#ifndef SJ_VM_H
#define SJ_VM_H

#include "value.h"

#include <stdio.h>
#include <string.h>

/* Root arrays: values outside the heap whose cells never move. They grow by
   adding chunks; the chunk directory is replaced when it fills, and the old one
   is kept, since another isolate may still read it (heap.c). */
#define RA_CHUNK_BITS 12
#define RA_CHUNK (1u << RA_CHUNK_BITS)

typedef struct {
    V **chunks;
    size_t nchunks, chunks_cap;
    size_t count;
    V ***retired; /* directories replaced, freed with the array */
    size_t nretired;
} RootArray;

/* Roots C keeps beyond a call (ffi.c), where they never move: what include/shen.h calls a
   shen_root_box, whose first field is api. next links the free ones. */
enum { FOREIGN_ROOT_CHUNK = 256, C_STACK_BYTES = 8 * 1024 * 1024 };

typedef struct ForeignRoot {
    const struct shen_api *api;
    V value;
    struct ForeignRoot *next;
    struct VM *owner;
} ForeignRoot;

typedef struct Guard {
    V pointer, value;
} Guard;

/* The program space (program.c): one reserved range that collections neither copy nor scan,
   holding every symbol, in fixed slots at its start, and after them the installed definitions
   with what they reach. Nothing in it points into the heap except the names of symbols that
   are not published yet, and nothing in it moves. */
typedef struct Space {
    uint64_t *base;      /* the range: symbols from base, objects from objects, up to end */
    size_t bytes;
    uint64_t *objects, *end;
    uint64_t *symbols_next, *symbols_committed; /* symbol slots used, and committed */
    uint64_t *objects_next, *objects_committed;
    size_t free_symbol;  /* the first free symbol slot, as its index plus one; 0 for none */
} Space;

/* An open-addressing hash set of symbols, outside the heap: 0 marks an empty entry. */
typedef struct SymbolTable {
    V *slots;
    size_t cap, count;
    /* Once isolates exist, the published table is read without a lock while it grows, so an
       array it replaces is kept until the program ends (objects.c). */
    bool shared;
    V **retired;
    size_t nretired;
} SymbolTable;

struct VM;

/* The program (docs/design.md, "The builder and isolates"): what every VM running it shares,
   which only the builder changes. A VM is a context of its own: heap, stack, global slots and
   the rest. The program's roots, its cells and constant slots, may point into the heap of one
   context, its owner, the builder's, whose collections scan and sweep them. */
typedef struct Program {
    struct VM *owner;
    Space space;
    SymbolTable published;
    size_t published_top; /* one past the highest cell of a published symbol */
    /* Roots: function cells, with the function's arity beside each (two entries per symbol),
       and constant slots. They grow by adding chunks, so none ever moves. */
    RootArray cells;
    RootArray consts;
    size_t *free_cells; /* cells of dropped symbols, for new symbols */
    size_t nfree_cells, free_cells_cap;
    size_t max_frame; /* largest frame size of any code object */
    /* Global numbers (objects.c): each VM has a slot for each, by number. Number 0 is none.
       Numbers of dropped symbols are reused, and those above the last one kept leave the
       range that collections walk, as cells do. */
    size_t nglobals;           /* one past the highest number in use, at least 1 */
    size_t *free_globals;
    size_t nfree_globals, free_globals_cap;
    size_t published_global_top; /* one past the highest number of a published symbol */
    /* Constant slots owned by code objects (heap.c): owned[i] marks a slot
       that the collector copies with its code object rather than as a root;
       free_consts holds the ranges of dead code, for reuse. */
    unsigned char *owned;
    size_t owned_cap;
    struct { size_t start, len; } *free_consts;
    size_t nfree_consts, free_consts_cap;
    /* Code objects with native code, held weakly: a collection hands
       those that nothing else reaches to free_native, which the JIT sets. */
    V *natives;
    size_t nnatives, natives_cap;
    void (*free_native)(struct VM *vm, uint64_t *code);
    /* Called with a name's cell before a new definition replaces it. */
    void (*redefine)(struct VM *vm, size_t cell);
    /* Process-specific addresses restored when an image loads. */
    void *compile_stub;
    void *foreign_stub;
    struct Jit *jit;
    /* The isolates running it, their channels and the locks they share (isolate.c): NULL until
       the first spawn. */
    struct Isolates *isolates;
} Program;

typedef struct VM {
    /* Fields read by emitted code first, at fixed offsets. */
    uint64_t *hp;      /* allocation cursor */
    uint64_t *hlimit;  /* where the room in the allocation area ends */
    V *fp;             /* frame pointer published at a safepoint */
    V *top;            /* scanned stack top published at a safepoint */
    V *stack_limit;    /* dirty mark: slots at or above it are cleared */
    V *volatile check_limit; /* frames that would end above it, and loops whose
                          frame is not below it, go through the growth stub:
                          stack_limit, or NULL while an interrupt is pending */
    size_t count;      /* argument count passed through C */
    V args[5];         /* operands passed to C helpers; scanned as roots */

    /* Handler stack: frame offsets and catch addresses, no values. */
    struct Handler *handlers;
    size_t nhandlers, handlers_cap;

    /* Heap. */
    uint64_t *area;     /* where new objects go, from its start after every collection */
    uint64_t *area_from; /* where they start: area, except under stress (vm_collect) */
    uint64_t *space;    /* holds what the last collection kept, up to live_end */
    uint64_t *live_end;
    uint64_t *other;    /* where the next collection copies to */
    size_t space_words; /* what the space holds and the area's room add up to */
    size_t reserved_words; /* the most it can grow to (heap.c) */
    size_t max_words;   /* SHEN_JIT_MAX_HEAP: semispaces grow no larger; 0 for no limit */
    uint64_t *scan_hp;  /* to-space cursor during collection */
    size_t stress;      /* collect after this many words; 1: before every allocation */
    size_t collections;
    double gc_seconds, gc_longest; /* time spent collecting, and the longest pause */
    /* Large objects: vectors and strings of LARGE_WORDS words or more, each
       in a block of its own that collections mark in place instead of
       copying. Sorted by address. A dead one's block is kept until the next
       collection, for an object of the same size. */
    struct Large *large;
    size_t nlarge, large_cap;
    size_t large_words; /* in the blocks, spare ones included */
    size_t large_since; /* allocated since the last collection */
    bool copy_large;    /* the next collection copies them into the heap */

    /* Guest stack. */
    V *stack;
    size_t stack_words;
    size_t stack_max_words;

    /* Roots: the program's (see Program), C locals and a few runtime values. Global values are
       in `globals`, at the end. */
    struct Program *program;
    V **croots;
    size_t ncroots, croots_cap;
    ForeignRoot **foreign_roots; /* chunks of FOREIGN_ROOT_CHUNK */
    size_t nforeign_roots;       /* in use or free */
    ForeignRoot *free_foreign_roots;
    ForeignRoot *deleted_foreign_roots; /* deleted from any thread; this VM drains them */
    V exception; /* the exception being raised or handled */
    /* The symbols that are not published, which a collection drops once nothing else needs
       them (objects.c). An entry may be a symbol published since, until the next collection
       rebuilds the table. */
    SymbolTable own;
    V fail;      /* shen.fail!, which fills new absvectors; [] until first used */
    V chars;     /* the 256 one-byte strings; [] until first used */
    /* The strings of C error messages, which are literals, cached by address:
       an absvector of MESSAGE_CACHE strings, [] until first used. */
    V messages;
    const char *message_keys[64];
    /* The backtrace of an error that the program does not catch: an
       absvector of the frame count and the innermost frames' names, or [].
       trace_floor is the REPL's frame, as an offset in the stack (SIZE_MAX
       outside the REPL): handlers of frames at or below it are the REPL's,
       and backtraces stop there. */
    V trace;
    size_t trace_floor;
    /* The executable's file, or NULL when not started from one; and where on
       the stack main keeps *hush* and *argv* as the image had them. For
       shen-jit.save-executable. */
    const char *self;
    size_t launch_base;
    /* Ctrl-C at the REPL: the signal handler sets interrupted to INTERRUPT and clears
       check_limit. */
    volatile int interrupted;
    size_t repl_handlers; /* handlers active when the REPL's is the innermost */
    uintptr_t c_stack_limit; /* nested calls stop before the C stack reaches this; 0: never */
    bool seal_user; /* definitions installed now are sealed (shen-jit.seal) */
    /* The isolate this VM runs (isolate.c), the builder's included once isolates exist, or NULL. */
    struct Isolate *isolate;
    /* Open file streams, held weakly: a collection closes those that nothing
       else reaches. */
    V *files;
    size_t nfiles, files_cap;
    /* Guarded pointers (shen-jit.pointer-guard), held weakly, each with a value held strongly.
       Once nothing else reaches the pointer, a collection puts its value on the list `dead`,
       for Shen to take. */
    Guard *guards;
    size_t nguards, guards_cap;
    V dead;
    /* Where native code inside an inlined body called the C helper now
       running, for backtraces; NULL outside such a call. */
    void *site;
    /* What the last foreign call on this thread left in errno and, on Windows,
       GetLastError: saved at once, since anything after it may overwrite them. */
    int foreign_error, foreign_c_error;

    /* What C written for Shen is given a pointer to (include/shen.h), so that it links against
       nothing: its first word is the table of functions, and ffi.c finds the VM from it. */
    const struct shen_api *api;


    /* Global values, by the number a symbol gets once code names it as a global or it is set
       (objects.c, Program): the slots lie in the VM's own block of address space, committed as
       numbers grow, so emitted code reads one at a fixed offset from the VM's register. */
    size_t globals_committed;  /* slots committed, all holding a value or V_CLEARED */
    size_t block_bytes;        /* the reserved block the VM lies in */
    V globals[];
} VM;

enum { INTERRUPT = 1 }; /* vm->interrupted */

typedef struct Handler {
    /* Frame of the trap-error, as an offset in the stack, shifted left by 1;
       bit 0 is set when the handler never reads the exception (quiet), so an
       error raised while it is innermost needs no exception object. */
    size_t fp_offset;
    void *catch_addr;
} Handler;

/* Raising: sets vm->exception and returns V_CLEARED, which native code and C
   callers treat as "an error is propagating". The message is a string
   literal; with a value, ~S in it marks where the value is shown. */
V sj_raise(VM *vm, const char *message);
bool sj_take_interrupt(VM *vm);
V jit_call_nested(VM *vm, V proc, size_t n, const V *args);
V sj_raise_arity(VM *vm, V name, size_t arity, size_t given);
#include "win32.h"
V sj_raise_value(VM *vm, const char *message, V value);
V sj_raise_text(VM *vm, const char *text);
V sj_raise_text_value(VM *vm, const char *text, V value);

/* vm.c */
VM *vm_create(size_t semispace_words, size_t stack_words);
void vm_fresh_area(VM *vm);
size_t vm_semispace_for(size_t live_words);
V *vm_cleared_stack(size_t words);

/* OS threads (isolate.c): where nested calls stop on the main thread's C stack and on an
   isolate's; reports for the end of the program; and its end while isolates may be blocked,
   which flushes what was written and leaves without waiting for them. */
void vm_note_main_stack(VM *vm);
void vm_note_thread_stack(VM *vm);
void at_program_exit(void (*report)(void));
void program_exit(VM *vm, int status);
void vm_destroy(VM *vm);
V *ra_at(RootArray *ra, size_t i);
bool ra_push(RootArray *ra, V v, size_t *index);
static inline V *cell_function(VM *vm, size_t cell) { return ra_at(&vm->program->cells, 2 * cell); }
/* A name's arity, a fixnum, or V_CLEARED for none: program, as functions are. */
static inline V *cell_arity(VM *vm, size_t cell) { return ra_at(&vm->program->cells, 2 * cell + 1); }

/* program.c */
static inline bool in_program(const VM *vm, const void *at)
{
    return (uintptr_t)at - (uintptr_t)vm->program->space.base < vm->program->space.bytes;
}
static inline bool in_symbols(const VM *vm, const void *at)
{
    const Space *p = &vm->program->space;
    return (uintptr_t)at - (uintptr_t)p->base < (uintptr_t)p->objects - (uintptr_t)p->base;
}
bool program_init(Space *p);
void program_release(Space *p);
uint64_t *program_alloc(VM *vm, size_t words);
uint64_t *program_alloc_shared(VM *vm, size_t words);
uint64_t *program_symbol_slot(VM *vm);
void program_free_symbol(VM *vm, uint64_t *slot);
bool program_reserve(VM *vm, size_t symbol_words, size_t object_words);
bool program_publish(VM *vm, V sym);
bool program_publish_all(VM *vm);
V program_promote(VM *vm, V closure, const char **why);
V program_promote_foreign(VM *vm, V proc, const char **why);

/* From an object's old address to its copy, so that a copy keeps sharing and cycles (program.c). */
typedef struct {
    uintptr_t *keys;
    V *values;
    size_t cap, n;
} AddrMap;
V addr_map_get(const AddrMap *m, uintptr_t key);
bool addr_map_put(AddrMap *m, uintptr_t key, V value);
void addr_map_free(AddrMap *m);

/* Whether this VM is the builder, which alone defines functions: the program's owner, as an isolate's
   context is not. */
static inline bool vm_is_builder(const VM *vm) { return vm->program->owner == vm; }

/* Isolates over one program (docs/design.md, "The builder and isolates"): isolate.c, with their
   contexts made in heap.c and the published names and strings they read in objects.c and program.c. */
VM *vm_create_context(Program *program, size_t semispace_words, size_t stack_words);
V sj_isolate(VM *vm);
void isolates_commit_globals(Program *program, size_t n);
void isolates_free(Program *program);
bool isolates_running(Program *program);
void program_compile_lock(VM *vm);
void program_compile_unlock(VM *vm);
void program_shared_lock(void);
void program_shared_unlock(void);
V published_find(VM *vm, const char *bytes, size_t len);
V program_copy_string(VM *vm, V string);

/* C locals that hold values across an allocation must be registered. */
void vm_root(VM *vm, V *slot);
static inline void vm_unroot(VM *vm, size_t n) { vm->ncroots -= n; }

/* profile.c: SHEN_JIT_PROFILE. */
bool profile_start(void);
bool profile_running(void);
void profile_code(const void *start, size_t size, const char *name, size_t len);

/* heap.c: allocation may collect, so every value a caller still needs must be
   in a root. Returns NULL when the heap cannot grow. */
uint64_t *vm_alloc(VM *vm, size_t words);
enum { LARGE_WORDS = 1 << 15 }; /* 256 KB */
uint64_t *vm_alloc_object(VM *vm, size_t words); /* a vector or string, maybe large */
bool vm_large_room(VM *vm, size_t words, size_t n);
void vm_adopt_large(VM *vm, uint64_t *p, size_t words);
bool vm_collect(VM *vm, size_t need_words);
bool vm_guard(VM *vm, V pointer, V value);
bool vm_in_heap(const VM *vm, const void *at);
void vm_census(VM *vm, size_t count[T_LIMIT], size_t words[T_LIMIT]);
bool vm_stack_grow(VM *vm, size_t need_words);
bool vm_stack_reserve(VM *vm, size_t need_words);
size_t vm_consts_alloc(VM *vm, size_t n, bool *ok);
void vm_consts_release(VM *vm, size_t start, size_t n);
bool vm_track_code(VM *vm, V code);
/* vm->program->owned: 0 for a root or free slot, OWNED for one in the range of a code object in the
   heap, REACHED while a collection has copied that code object, and PROGRAM for one of code
   in the program space, which collections neither scan nor free. */
enum { OWNED = 1, REACHED = 2, PROGRAM = 3 };
void vm_find_free_consts(VM *vm);
void vm_set_limit(VM *vm, V *mark);

/* objects.c */
V make_pair(VM *vm, V head, V tail);
V make_string(VM *vm, const char *bytes, size_t len);
V make_bytes(VM *vm, const void *bytes, size_t len);
V make_real(VM *vm, double d);
V make_vector(VM *vm, size_t n, V fill);
V make_closure(VM *vm, V code, size_t ncaps, const V *caps);
V make_foreign(VM *vm, V desc, size_t arity);
V make_pointer(VM *vm, uint64_t address, V kind);
V make_code(VM *vm, V name, V bytecode, size_t arity, size_t frame,
            size_t cbase, size_t nconst, size_t ncode, V inline_body);
V make_exception(VM *vm, V message, V value);
V exception_message(VM *vm, V e);
/* Prints the error in vm->exception, with its backtrace, to stderr. */
void sj_report(VM *vm, const char *what);
size_t jit_backtrace(VM *vm, V *names, size_t max, bool *evaluated);
size_t sj_trace_text(VM *vm, char *text, size_t size, bool newline_first);
V make_stream(VM *vm, uint64_t flags, void *handle);
bool vm_track_file(VM *vm, V stream);
bool vm_track_native(VM *vm, V code);
V intern(VM *vm, const char *bytes, size_t len);
V intern_string(VM *vm, V string);
V symbol_find(VM *vm, const char *bytes, size_t len);
V intern_cstr(VM *vm, const char *s);
size_t symbol_cell(V sym);
V cell_symbol(VM *vm, size_t cell);
bool symbol_sealed(V sym);
void symbol_seal(V sym);
void symbol_mark_called(V sym);
bool symbol_needed(VM *vm, V sym);
/* The word at SYM_CELL holds the function cell's index in its low CELL_BITS, the global's
   number above that, and flags from bit 56 (objects.c). A published symbol is never dropped, and
   its name is in the program space; a collection marks the others it reaches. */
enum { CELL_BITS = 28, KIND_SHIFT = 56, SEALED_BIT = 58, CALLED_BIT = 59, PUBLISHED_BIT = 60, MARK_BIT = 61 };
#define CELL_MASK ((UINT64_C(1) << CELL_BITS) - 1)
static inline bool symbol_published(V sym) { return (ptr(sym)[SYM_CELL] >> PUBLISHED_BIT) & 1; }
/* A number is given once, perhaps by another isolate meanwhile (objects.c). */
static inline size_t symbol_global(V sym)
{
    return (size_t)(__atomic_load_n(&ptr(sym)[SYM_CELL], __ATOMIC_ACQUIRE) >> CELL_BITS & CELL_MASK);
}
/* A global's slot, or NULL when it has none and so no value; global_slot_new makes one first,
   and is NULL only when it cannot. Any VM may number a symbol. */
static inline V *global_slot(VM *vm, V sym)
{
    size_t n = symbol_global(sym);
    return n ? &vm->globals[n] : NULL;
}
static inline V global_value(VM *vm, V sym)
{
    V *slot = global_slot(vm, sym);
    return slot ? *slot : V_CLEARED;
}
V *global_slot_new(VM *vm, V sym);
bool vm_globals_commit(VM *vm, size_t n);
bool symbol_table_put(SymbolTable *t, V sym);
uint64_t hash_bytes(const void *bytes, size_t len);

static inline size_t string_length(V s) { return (size_t)hdr_size(ptr(s)[0]); }
static inline char *string_bytes(V s) { return (char *)(ptr(s) + 1); }

/* Whether v is the symbol of this name, by the name and not by interning it, as
   a prover may ask for the time at every inference. */
static inline bool symbol_named(V v, const char *name)
{
    if (!is_symbol(v))
        return false;
    V s = ptr(v)[SYM_NAME];
    size_t n = strlen(name);
    return string_length(s) == n && memcmp(string_bytes(s), name, n) == 0;
}

/* What the byte primitives read and write: a byte buffer, a string, which they only read, or
   the memory a pointer was given a length for. A pointer that has none, or is dead, has length
   0, so that the ordinary bounds check refuses it. A buffer's or string's base lasts until the
   next allocation. */
static inline bool memory_of(V v, char **base, size_t *length)
{
    if (!is_object(v))
        return false;
    if (obj_type(v) == T_BYTES || obj_type(v) == T_STRING) {
        *base = string_bytes(v);
        *length = string_length(v);
        return true;
    }
    if (obj_type(v) == T_POINTER) {
        *base = (char *)(uintptr_t)ptr(v)[POINTER_ADDRESS];
        *length = (size_t)ptr(v)[POINTER_LENGTH];
        return true;
    }
    return false;
}

/* Whether stores to v are refused: a string, which never changes, a shared buffer, or a pointer
   marked so, by the size in its header. */
static inline bool is_read_only(V v)
{
    return obj_type(v) == T_STRING || hdr_shared(ptr(v)[0]) ||
           (obj_type(v) == T_POINTER && hdr_size(ptr(v)[0]));
}

static inline double real_value(V r)
{
    double d;
    __builtin_memcpy(&d, ptr(r) + REAL_VALUE, sizeof d);
    return d;
}

/* ffi.c: C functions called from Shen (docs/ffi.md). */
V h_foreign(VM *vm);
V ffi_primitive(VM *vm, unsigned prim);
const struct shen_api *ffi_api(void);
void ffi_drain_roots(VM *vm);

/* image.c */
typedef struct {
    const char *name;
    int arity;
    void *entry;
} Primitive;

extern const Primitive primitive_table[];
extern const size_t primitive_count;

bool image_dump(VM *vm, const char *path);
bool image_append(VM *vm, const char *path);
bool image_copy_runtime(const char *from, const char *to);
VM *image_load(const char *path, size_t min_semispace_words, size_t stack_words,
               void *compile_stub, void *foreign_stub);

#endif

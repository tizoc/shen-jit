/* The VM context: heap, guest stack and roots. */
#ifndef SJ_VM_H
#define SJ_VM_H

#include "value.h"

#include <stdio.h>
#include <string.h>

/* Root arrays: values outside the heap whose cells never move. They grow by
   adding chunks; the chunk directory may move, the chunks never do. */
#define RA_CHUNK_BITS 12
#define RA_CHUNK (1u << RA_CHUNK_BITS)

typedef struct {
    V **chunks;
    size_t nchunks;
    size_t count;
} RootArray;

/* Roots C keeps beyond a call (ffi.c), where they never move: what include/shen.h calls a
   shen_root_box, whose first field is api. next links the free ones. */
enum { FOREIGN_ROOT_CHUNK = 256 };

typedef struct ForeignRoot {
    const struct shen_api *api;
    V value;
    struct ForeignRoot *next;
} ForeignRoot;

typedef struct Guard {
    V pointer, value;
} Guard;

/* What a thread keeps of its own (thread.c). The running thread's stack and
   handlers are in the VM's fields; these hold them while it waits. */
typedef struct Thread {
    struct Thread *next;
    struct VM *vm;
    bool main;
    V thunk; /* what it will run, until it starts */
    V exception, trace; /* its vm->exception and vm->trace while another thread runs */
    V *stack, *fp, *top, *stack_limit;
    size_t stack_words;
    struct Handler *handlers;
    size_t nhandlers, handlers_cap;
    size_t trace_floor;
    void *site;
    uintptr_t c_stack_limit;
    V **croots;
    size_t ncroots, croots_cap;
    int foreign_error, foreign_c_error;
} Thread;

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
    size_t max_frame; /* largest frame size of any code object */

    /* Roots: global cells (value and function per symbol, two entries each),
       constant slots, C locals and a few runtime values. */
    RootArray cells;
    RootArray consts;
    V **croots;
    size_t ncroots, croots_cap;
    ForeignRoot **foreign_roots; /* chunks of FOREIGN_ROOT_CHUNK */
    size_t nforeign_roots;       /* in use or free */
    ForeignRoot *free_foreign_roots;
    V exception; /* the exception being raised or handled */
    V intern;    /* intern table: an open-addressing vector of symbols, held weakly
                    (vm_collect drops symbols nothing else needs) */
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
    /* Ctrl-C at the REPL: the signal
       handler sets interrupted to INTERRUPT and clears check_limit. The thread
       ticker does the same with PREEMPT. */
    volatile int interrupted;
    size_t repl_handlers; /* handlers active when the REPL's is the innermost */
    uintptr_t c_stack_limit; /* nested calls stop before the C stack reaches this; 0: never */
    bool interruptible; /* the REPL catches SIGINT: loops test interrupted */
    bool seal_user; /* definitions installed now are sealed (shen-jit.seal) */
    size_t nsymbols;
    size_t *free_cells; /* global cells of dropped symbols, for new symbols */
    size_t nfree_cells, free_cells_cap;
    /* Open file streams, held weakly: a collection closes those that nothing
       else reaches. */
    V *files;
    size_t nfiles, files_cap;
    /* Code objects with native code, held weakly too: a collection hands
       those that nothing else reaches to free_native, which the JIT sets. */
    V *natives;
    size_t nnatives, natives_cap;
    void (*free_native)(struct VM *vm, uint64_t *code);
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
    /* All threads, the running one included, and the running one: NULL until
       the first (thread F). */
    Thread *threads, *thread;
    /* Called with a name's cell before a new definition replaces it. */
    void (*redefine)(struct VM *vm, size_t cell);
    /* Constant slots owned by code objects (heap.c): owned[i] marks a slot
       that the collector copies with its code object rather than as a root;
       free_consts holds the ranges of dead code, for reuse. */
    unsigned char *owned;
    size_t owned_cap;
    struct { size_t start, len; } *free_consts;
    size_t nfree_consts, free_consts_cap;

    /* What C written for Shen is given a pointer to (include/shen.h), so that it links against
       nothing: its first word is the table of functions, and ffi.c finds the VM from it. */
    const struct shen_api *api;

    /* Process-specific addresses restored when an image loads. */
    void *compile_stub;
    void *foreign_stub;
    struct Jit *jit;
} VM;

enum { INTERRUPT = 1, PREEMPT = 2 }; /* vm->interrupted */

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

/* Threads (thread.c): real ones, of which one runs at a time. (thread F) starts
   one with F in vm->args[0]. thread_leave lets others run, for a thread about
   to block, until thread_enter. */
V thread_start(VM *vm);
Thread *thread_leave(VM *vm);
void thread_enter(Thread *t);
void thread_yield(VM *vm);
void thread_preempted(VM *vm);
void thread_exit(VM *vm, int status);
void thread_at_exit(void (*report)(void));
void thread_forget_others(VM *vm);
bool thread_is_only(const VM *vm);
void thread_free_all(VM *vm);
void thread_note_main_stack(VM *vm);
void vm_destroy(VM *vm);
V *ra_at(RootArray *ra, size_t i);
bool ra_push(RootArray *ra, V v, size_t *index);
static inline V *cell_value(VM *vm, size_t cell) { return ra_at(&vm->cells, 2 * cell); }
static inline V *cell_function(VM *vm, size_t cell) { return ra_at(&vm->cells, 2 * cell + 1); }

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
bool vm_collect(VM *vm, size_t need_words);
bool vm_guard(VM *vm, V pointer, V value);
bool vm_in_heap(const VM *vm, const void *at);
void vm_census(VM *vm, size_t count[T_LIMIT], size_t words[T_LIMIT]);
bool vm_stack_grow(VM *vm, size_t need_words);
bool vm_stack_reserve(VM *vm, size_t need_words);
size_t vm_consts_alloc(VM *vm, size_t n, bool *ok);
void vm_consts_release(VM *vm, size_t start, size_t n);
bool vm_track_code(VM *vm, V code);
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

/* What the byte primitives read and write: a byte buffer, or the memory a pointer was given
   a length for. A pointer that has none, or is dead, has length 0, so that the ordinary
   bounds check refuses it. A buffer's base lasts until the next allocation. */
static inline bool memory_of(V v, char **base, size_t *length)
{
    if (!is_object(v))
        return false;
    if (obj_type(v) == T_BYTES) {
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

/* Whether stores to v are refused: a pointer marked so, by the size in its header. */
static inline bool is_read_only(V v) { return obj_type(v) == T_POINTER && hdr_size(ptr(v)[0]); }

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

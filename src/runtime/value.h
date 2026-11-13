/* Values and object layouts (docs/semantics.md, section 2). */
#ifndef SJ_VALUE_H
#define SJ_VALUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef uint64_t V;

/* Low three bits. Fixnums use only the low two (..00). */
enum {
    TAG_OBJECT = 1,
    TAG_SPECIAL = 2,
    TAG_PAIR = 3,
    TAG_PROC = 5,
    TAG_SYMBOL = 6,
    TAG_HEADER = 7
};

#define SPECIAL(n) ((V)(((uint64_t)(n) << 3) | TAG_SPECIAL))
#define V_NIL SPECIAL(0)
#define V_FALSE SPECIAL(1)
#define V_TRUE SPECIAL(2)
/* Never visible to Shen code: the value of cleared stack slots and unbound
   cells, and the marker left in a copied object during collection. */
#define V_CLEARED SPECIAL(3)
#define V_FORWARD SPECIAL(4)
/* What a read of the wrong type gives C (include/shen.h). Never visible to Shen code. */
#define V_NONE SPECIAL(5)
/* A Prolog variable (shen-jit.pvar) is a special too: this low byte, and above
   it the offset of its binding. It takes no memory, and two of them with the
   same offset are identical. */
enum { PVAR_TAG = 31 << 3 | TAG_SPECIAL };
#define PVAR_MAX_OFFSET ((UINT64_C(1) << 56) - 1)

#define FIX_MIN (-(INT64_C(1) << 61))
#define FIX_MAX ((INT64_C(1) << 61) - 1)

static inline bool is_fix(V v) { return (v & 3) == 0; }
static inline V fix(int64_t n) { return (V)((uint64_t)n << 2); }
static inline int64_t fixval(V v) { return (int64_t)v >> 2; }
static inline bool fix_fits(int64_t n) { return n >= FIX_MIN && n <= FIX_MAX; }

static inline unsigned tag3(V v) { return (unsigned)(v & 7); }
static inline bool is_pair(V v) { return tag3(v) == TAG_PAIR; }
static inline bool is_symbol(V v) { return tag3(v) == TAG_SYMBOL; }
static inline bool is_proc(V v) { return tag3(v) == TAG_PROC; }
static inline bool is_object(V v) { return tag3(v) == TAG_OBJECT; }
static inline bool is_boolean(V v) { return v == V_TRUE || v == V_FALSE; }
static inline bool is_pvar(V v) { return (v & 0xFF) == PVAR_TAG; }
static inline uint64_t pvar_offset(V v) { return v >> 8; }

/* Pairs, objects, procedures and symbols point into the heap. */
static inline bool is_ptr(V v)
{
    unsigned t = tag3(v);
    return t == TAG_OBJECT || t == TAG_PAIR || t == TAG_PROC || t == TAG_SYMBOL;
}

static inline uint64_t *ptr(V v) { return (uint64_t *)(uintptr_t)(v & ~(V)7); }
static inline V tagged(const uint64_t *p, unsigned tag) { return (V)(uintptr_t)p | tag; }

/* Object headers: 111 in the low bits, the type in bits 3-6, bit 7 set in a vector or byte
   buffer that is shared (isolate.share), and a size field in bits 8-63 whose meaning depends
   on the type. Code that stores into a vector or buffer tests the whole low byte, which a shared
   one fails, and code that reads tests it without bit 7, so neither costs an instruction. */
enum {
    T_STRING = 1, /* size: byte length; bytes follow */
    T_BYTES,      /* size: byte length; raw bytes (bytecode, and byte buffers) */
    T_SYMBOL,     /* [name][hash raw][cell raw] */
    T_REAL,       /* [double raw] */
    T_VECTOR,     /* size: length; values follow */
    T_CLOSURE,    /* size: capture count; [entry raw][code][captures...] */
    T_FOREIGN,    /* [entry raw][desc][address raw][arity raw]: a C function (ffi.c) */
    T_CODE,       /* [native raw][arity][frame][cbase][nconst][ncode] raw,
                     then [name][bytecode] */
    T_EXCEPTION,  /* [message][value]: the value goes before the message */
    T_STREAM,     /* [flags raw][handle raw] */
    T_POINTER,    /* [kind][owner][address raw][length raw]: a C pointer, read only if its size is 1; an image clears all but the kind */
    T_LIMIT       /* at most 16, below the shared bit */
};
#define SHARED_BIT (UINT64_C(1) << 7)

#define HEADER(type, size) \
    ((((uint64_t)(size)) << 8) | (((uint64_t)(type)) << 3) | TAG_HEADER)
/* The least size the field cannot hold: constructors refuse it rather than cut it short. */
#define HEADER_SIZE_LIMIT (UINT64_C(1) << 56)

static inline bool is_header(uint64_t w) { return (w & 7) == TAG_HEADER; }
static inline unsigned hdr_type(uint64_t h) { return (unsigned)((h >> 3) & 15); }
static inline bool hdr_shared(uint64_t h) { return (h & SHARED_BIT) != 0; }
static inline uint64_t hdr_size(uint64_t h) { return h >> 8; }

/* Word offsets of fields after the header. */
enum {
    SYM_NAME = 1, SYM_HASH = 2, SYM_CELL = 3, SYM_WORDS = 4,
    REAL_VALUE = 1, REAL_WORDS = 2,
    PROC_ENTRY = 1,
    CLO_CODE = 2, CLO_CAPS = 3,
    FOREIGN_DESC = 2, FOREIGN_ADDRESS = 3, FOREIGN_ARITY = 4, FOREIGN_WORDS = 5,
    CODE_NATIVE = 1, CODE_ARITY = 2, CODE_FRAME = 3, CODE_CBASE = 4,
    CODE_NCONST = 5, CODE_NCODE = 6, CODE_NAME = 7, CODE_BYTECODE = 8,
    CODE_INLINE = 9, /* (Params Body) of a small sealed definition, or [] */
    CODE_WORDS = 10,
    EXC_MESSAGE = 1, EXC_VALUE = 2, EXC_WORDS = 3,
    STREAM_FLAGS = 1, STREAM_HANDLE = 2, STREAM_WORDS = 3,
    POINTER_KIND = 1, POINTER_OWNER = 2, POINTER_ADDRESS = 3, POINTER_LENGTH = 4, POINTER_WORDS = 5
};

/* Every object is at least two words, so a copied object always has room
   for the forwarding marker and its new address. */
static inline size_t at_least_two(size_t words) { return words < 2 ? 2 : words; }

static inline size_t byte_object_words(uint64_t bytes)
{
    return at_least_two(1 + (size_t)((bytes + 7) / 8));
}

static inline size_t obj_words(uint64_t h)
{
    uint64_t n = hdr_size(h);
    switch (hdr_type(h)) {
    case T_STRING:
    case T_BYTES: return byte_object_words(n);
    case T_SYMBOL: return SYM_WORDS;
    case T_REAL: return REAL_WORDS;
    case T_VECTOR: return at_least_two(1 + (size_t)n);
    case T_CLOSURE: return CLO_CAPS + (size_t)n;
    case T_FOREIGN: return FOREIGN_WORDS;
    case T_CODE: return CODE_WORDS;
    case T_EXCEPTION: return EXC_WORDS;
    case T_STREAM: return STREAM_WORDS;
    case T_POINTER: return POINTER_WORDS;
    default: return 0;
    }
}

/* The fields of an object that hold values: [first, first + count). */
static inline void obj_values(uint64_t h, size_t *first, size_t *count)
{
    uint64_t n = hdr_size(h);
    *first = 1;
    *count = 0;
    switch (hdr_type(h)) {
    case T_SYMBOL: *first = SYM_NAME; *count = 1; break;
    case T_VECTOR: *count = (size_t)n; break;
    case T_CLOSURE: *first = CLO_CODE; *count = 1 + (size_t)n; break;
    case T_CODE: *first = CODE_NAME; *count = 3; break;
    case T_EXCEPTION: *first = EXC_MESSAGE; *count = 2; break;
    case T_FOREIGN: *first = FOREIGN_DESC; *count = 1; break;
    case T_POINTER: *first = POINTER_KIND; *count = 2; break;
    default: break;
    }
}

static inline unsigned obj_type(V v) { return hdr_type(ptr(v)[0]); }

/* Stream flags. */
enum {
    STREAM_STDIN = 0, STREAM_STDOUT = 1, STREAM_STDERR = 2, STREAM_FILE = 3,
    STREAM_KIND_MASK = 3,
    STREAM_OUTPUT = 4,
    STREAM_OPEN = 8
};

#endif

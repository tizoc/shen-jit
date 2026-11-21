/* The opcode table (docs/bytecode.md). Encoded code is a sequence of 32-bit words:
   the opcode, then its operands. CLOSURE and PRIM carry their operand count
   before the variable part. */
#ifndef SJ_OPS_H
#define SJ_OPS_H

#include "vm.h"

/* X(name, symbolic name, fixed operand count) */
#define SJ_OPCODES(X)                         \
    X(OP_MOVE, "move", 2)                     \
    X(OP_CONST, "const", 2)                   \
    X(OP_CAPTURE, "capture", 2)               \
    X(OP_CLOSURE, "closure", 2)               \
    X(OP_PRIM, "prim", 2)                     \
    X(OP_LABEL, "label", 1)                   \
    X(OP_JUMP, "jump", 1)                     \
    X(OP_JUMP_IF_FALSE, "jump-if-false", 2)   \
    X(OP_CALL, "call", 4)                     \
    X(OP_CALL_SEALED, "call-sealed", 4)       \
    X(OP_CALL_VALUE, "call-value", 3)         \
    X(OP_TAIL_CALL, "tail-call", 3)           \
    X(OP_TAIL_CALL_SEALED, "tail-call-sealed", 3) \
    X(OP_TAIL_CALL_VALUE, "tail-call-value", 2)   \
    X(OP_RETURN, "return", 1)                 \
    X(OP_PUSH_HANDLER, "push-handler", 1)     \
    X(OP_POP_HANDLER, "pop-handler", 0)       \
    X(OP_EXCEPTION, "exception", 1)           \
    X(OP_ENTRY, "entry", 2)                   \
    X(OP_JUMP_UNLESS_ENTRY, "jump-unless-entry", 3) \
    X(OP_INLINE, "inline", 2)                 \
    X(OP_LOOP, "loop", 1)                     \
    X(OP_AGAIN, "again", 1)                   \
    X(OP_FLOAT_NUMBER, "float-number", 2)       \
    X(OP_FLOAT_BOX, "float-box", 2)             \
    X(OP_FLOAT_MOVE, "float-move", 2)           \
    X(OP_FLOAT_NEG, "float-neg", 2)             \
    X(OP_FLOAT_ABS, "float-abs", 2)             \
    X(OP_FLOAT_SQRT, "float-sqrt", 2)           \
    X(OP_FLOAT_ADD, "float+", 3)                \
    X(OP_FLOAT_SUB, "float-", 3)                \
    X(OP_FLOAT_MUL, "float*", 3)                \
    X(OP_FLOAT_DIV, "float/", 3)                \
    X(OP_FLOAT_UNLESS_LT, "float-unless<", 3)   \
    X(OP_FLOAT_UNLESS_GT, "float-unless>", 3)   \
    X(OP_FLOAT_UNLESS_LE, "float-unless<=", 3)  \
    X(OP_FLOAT_UNLESS_GE, "float-unless>=", 3)  \
    X(OP_FLOAT_UNLESS_EQ, "float-unless=", 3)   \
    X(OP_FLOAT_LOAD, "float-load", 3)           \
    X(OP_FLOAT_STORE, "float-store", 3)         \
    X(OP_FLOAT_LOAD_AT, "float-load-at", 3)     \
    X(OP_FLOAT_STORE_AT, "float-store-at", 3)   \
    X(OP_FLOAT_FROM_WORD, "float-from-word", 2) \
    X(OP_WORD_FROM_FLOAT, "word-from-float", 2) \
    X(OP_WORD_NUMBER, "word-number", 2)       \
    X(OP_WORD_BOX, "word-box", 2)             \
    X(OP_WORD_MOVE, "word-move", 2)           \
    X(OP_WORD_ADD, "word+", 3)                \
    X(OP_WORD_SUB, "word-", 3)                \
    X(OP_WORD_MUL, "word*", 3)                \
    X(OP_WORD_AND, "word-and", 3)             \
    X(OP_WORD_OR, "word-or", 3)               \
    X(OP_WORD_XOR, "word-xor", 3)             \
    X(OP_WORD_SHL, "word-shl", 3)             \
    X(OP_WORD_SHR, "word-shr", 3)             \
    X(OP_WORD_SAR, "word-sar", 3)             \
    X(OP_WORD_ROTL, "word-rotl", 3)           \
    X(OP_WORD_ROTR, "word-rotr", 3)           \
    X(OP_WORD_UNLESS_LT, "word-unless<", 3)   \
    X(OP_WORD_UNLESS_GT, "word-unless>", 3)   \
    X(OP_WORD_UNLESS_LE, "word-unless<=", 3)  \
    X(OP_WORD_UNLESS_GE, "word-unless>=", 3)  \
    X(OP_WORD_UNLESS_EQ, "word-unless=", 3)   \
    X(OP_WORD_UNLESS_ULT, "word-unless-u<", 3) \
    X(OP_WORD_UNLESS_UGT, "word-unless-u>", 3) \
    X(OP_WORD_UNLESS_ULE, "word-unless-u<=", 3) \
    X(OP_WORD_UNLESS_UGE, "word-unless-u>=", 3) \
    X(OP_WORD_LOAD8, "word-load8", 3)         \
    X(OP_WORD_LOAD16, "word-load16", 3)       \
    X(OP_WORD_LOAD32, "word-load32", 3)       \
    X(OP_WORD_LOAD_S32, "word-load-s32", 3)   \
    X(OP_WORD_LOAD64, "word-load64", 3)       \
    X(OP_WORD_STORE8, "word-store8", 3)       \
    X(OP_WORD_STORE16, "word-store16", 3)     \
    X(OP_WORD_STORE32, "word-store32", 3)     \
    X(OP_WORD_STORE64, "word-store64", 3)     \
    X(OP_FIX_ADD, "fix+", 3)                  \
    X(OP_FIX_SUB, "fix-", 3)                  \
    X(OP_FIX_MUL, "fix*", 3)                  \
    X(OP_FLOAT_CALL1, "float-call1", 3)         \
    X(OP_FLOAT_CALL2, "float-call2", 4)         \
    X(OP_FLOAT_CALL3, "float-call3", 5)         \
    X(OP_FLOAT_DIVIDE, "float-divide", 3)       \
    X(OP_FLOAT_LOAD_INDEX, "float-load-index", 3) \
    X(OP_FLOAT_STORE_INDEX, "float-store-index", 3) \
    X(OP_FIX_STORE8, "fix-store8", 3)         \
    X(OP_FIX_STORE16, "fix-store16", 3)       \
    X(OP_FIX_STORE32, "fix-store32", 3)       \
    X(OP_FIX_STORE_S32, "fix-store-s32", 3)   \
    X(OP_FIX_FROM_FLOAT, "fix-from-float", 2) \
    X(OP_WORD_LOAD_INDEX, "word-load-index", 3) \
    X(OP_WORD_STORE_INDEX, "word-store-index", 3) \
    X(OP_FIX_SHL, "fix-shl", 3)               \
    X(OP_FIX_SAR, "fix-sar", 3)               \
    X(OP_FIX_CLZ, "fix-clz", 2)               \
    X(OP_FIX_CTZ, "fix-ctz", 2)               \
    X(OP_FIX_POPCOUNT, "fix-popcount", 2)     \
    X(OP_VEC_LOAD, "vec-load", 3)             \
    X(OP_VEC_STORE, "vec-store", 3)           \
    X(OP_VEC_SPLAT, "vec-splat", 2)           \
    X(OP_VEC_MOVE, "vec-move", 2)             \
    X(OP_VEC_EQ, "vec=", 3)                   \
    X(OP_VEC_AND, "vec-and", 3)               \
    X(OP_VEC_OR, "vec-or", 3)                 \
    X(OP_VEC_XOR, "vec-xor", 3)               \
    X(OP_VEC_MASK, "vec-mask", 2)             \
    X(OP_WORD_CTZ, "word-ctz", 2)             \
    X(OP_WORD_CLZ, "word-clz", 2)             \
    X(OP_VEC_SHR, "vec-shr", 3)               \
    X(OP_VEC_LOOKUP, "vec-lookup", 3)

enum {
#define SJ_OP_ENUM(op, name, n) op,
    SJ_OPCODES(SJ_OP_ENUM)
#undef SJ_OP_ENUM
    OP_COUNT
};

/* The length in words of the encoded instruction at p. */
static inline size_t insn_length(const uint32_t *p)
{
    static const unsigned char fixed[] = {
#define SJ_OP_FIXED(op, name, n) n,
        SJ_OPCODES(SJ_OP_FIXED)
#undef SJ_OP_FIXED
    };
    if (p[0] == OP_CLOSURE || p[0] == OP_PRIM || p[0] == OP_FLOAT_LOAD || p[0] == OP_FLOAT_STORE)
        return 4 + p[3];
    return 1 + fixed[p[0]];
}

/* The registers of code written by hand (docs/bytecode.md). */
#define FLOAT_REGISTERS 64
#define WORD_REGISTERS 16
#define VECTOR_REGISTERS 16

/* What each operand of the instructions on them is: s a slot written, o a slot or constant read,
   r a float register, w a word register written, W a word register or constant read, v a vector
   register written, V one read, l a label jumped to on a test, h a loop's head, which defines a label,
   b a label jumped back to.
   float-load and float-store are laid out as prim is, with the float register first. */
static inline const char *raw_kinds(unsigned op)
{
    switch (op) {
    case OP_LOOP: return "h";
    case OP_AGAIN: return "b";
    case OP_FLOAT_NUMBER: return "ro";
    case OP_FLOAT_BOX: return "sr";
    case OP_FLOAT_MOVE: case OP_FLOAT_NEG: case OP_FLOAT_ABS: case OP_FLOAT_SQRT: return "rr";
    case OP_FLOAT_ADD: case OP_FLOAT_SUB: case OP_FLOAT_MUL: case OP_FLOAT_DIV: case OP_FLOAT_DIVIDE: return "rrr";
    case OP_FLOAT_UNLESS_LT: case OP_FLOAT_UNLESS_GT: case OP_FLOAT_UNLESS_LE: case OP_FLOAT_UNLESS_GE:
    case OP_FLOAT_UNLESS_EQ: return "rrl";
    case OP_FLOAT_LOAD: case OP_FLOAT_STORE: return "r";
    case OP_FLOAT_LOAD_AT: case OP_FLOAT_LOAD_INDEX: return "roW";
    case OP_FLOAT_STORE_AT: case OP_FLOAT_STORE_INDEX: return "oWr";
    case OP_FLOAT_FROM_WORD: return "rW";
    case OP_WORD_FROM_FLOAT: return "wr";
    case OP_WORD_NUMBER: return "wo";
    case OP_WORD_BOX: return "sW";
    case OP_WORD_MOVE: return "wW";
    case OP_WORD_ADD: case OP_WORD_SUB: case OP_WORD_MUL: case OP_WORD_AND: case OP_WORD_OR: case OP_WORD_XOR:
    case OP_WORD_SHL: case OP_WORD_SHR: case OP_WORD_SAR: case OP_WORD_ROTL: case OP_WORD_ROTR: return "wWW";
    case OP_WORD_UNLESS_LT: case OP_WORD_UNLESS_GT: case OP_WORD_UNLESS_LE: case OP_WORD_UNLESS_GE:
    case OP_WORD_UNLESS_EQ: case OP_WORD_UNLESS_ULT: case OP_WORD_UNLESS_UGT: case OP_WORD_UNLESS_ULE:
    case OP_WORD_UNLESS_UGE: return "WWl";
    case OP_WORD_LOAD8: case OP_WORD_LOAD16: case OP_WORD_LOAD32: case OP_WORD_LOAD_S32: case OP_WORD_LOAD64:
    case OP_WORD_LOAD_INDEX:
        return "woW";
    case OP_WORD_STORE8: case OP_WORD_STORE16: case OP_WORD_STORE32: case OP_WORD_STORE64: case OP_WORD_STORE_INDEX:
    case OP_FIX_STORE8: case OP_FIX_STORE16: case OP_FIX_STORE32: case OP_FIX_STORE_S32: return "oWW";
    case OP_FIX_ADD: case OP_FIX_SUB: case OP_FIX_MUL: case OP_FIX_SHL: case OP_FIX_SAR: return "wWW";
    case OP_FIX_CLZ: case OP_FIX_CTZ: case OP_FIX_POPCOUNT: return "wW";
    case OP_FIX_FROM_FLOAT: return "wr";
    case OP_VEC_LOAD: return "voW";
    case OP_VEC_STORE: return "oWV";
    case OP_VEC_SPLAT: return "vW";
    case OP_VEC_MOVE: return "vV";
    case OP_VEC_EQ: case OP_VEC_AND: case OP_VEC_OR: case OP_VEC_XOR: case OP_VEC_LOOKUP: return "vVV";
    case OP_VEC_SHR: return "vVW";
    case OP_VEC_MASK: return "wV";
    case OP_WORD_CTZ: case OP_WORD_CLZ: return "wW";
    case OP_FLOAT_CALL1: return "rfr";
    case OP_FLOAT_CALL2: return "rfrr";
    case OP_FLOAT_CALL3: return "rfrrr";
    default: return NULL;
    }
}

/* An operand of prim, jump-if-false or return is a slot, or a constant of
   the code object with this bit set (docs/bytecode.md). */
#define OPERAND_CONST 0x80000000u

/* Code objects keep their words packed: each rotated left by one, so that
   OPERAND_CONST becomes bit 0 and constant operands stay small, then written
   seven bits at a time, low first, with the top bit set on all but the last
   byte. Nearly every word takes one byte. out needs 5 bytes per word. */
static inline size_t bytecode_pack(const uint32_t *w, size_t n, uint8_t *out)
{
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t x = w[i] << 1 | w[i] >> 31;
        for (; x >= 0x80; x >>= 7)
            out[k++] = (uint8_t)(x | 0x80);
        out[k++] = (uint8_t)x;
    }
    return k;
}

/* The words of n packed bytes, at most n of them. */
static inline size_t bytecode_unpack(const uint8_t *in, size_t n, uint32_t *w)
{
    size_t k = 0;
    for (size_t i = 0; i < n;) {
        uint32_t x = 0;
        for (unsigned shift = 0; i < n; shift += 7) {
            uint8_t b = in[i++];
            x |= (uint32_t)(b & 0x7f) << shift;
            if (!(b & 0x80))
                break;
        }
        w[k++] = x >> 1 | x << 31;
    }
    return k;
}

/* Primitive operands index the primitive table (prims.c, same order);
   raise-cond and shen-jit.field, which only the lowerer emits, follow it. */
enum Prim {
    P_ADD, P_SUB, P_MUL, P_DIV, P_LT, P_GT, P_LE, P_GE, P_EQ, P_NUMBERP,
    P_CONS, P_HD, P_TL, P_CONSP, P_CN, P_POS, P_TLSTR, P_STR, P_STRINGP,
    P_N_STRING, P_STRING_N, P_INTERN, P_ABSVECTOR, P_ABSVECTORP,
    P_GET_ADDRESS, P_SET_ADDRESS, P_SET, P_VALUE, P_SIMPLE_ERROR,
    P_ERROR_TO_STRING, P_EVAL_KL, P_GET_TIME, P_OPEN, P_CLOSE, P_READ_BYTE,
    P_WRITE_BYTE, P_CHAR_STREAMP, P_READ_UNIT_STRING, P_WRITE_STRING,
    P_INSTALL, /* port primitive behind eval-kl */
    P_FIXNUMP, /* shen-jit.fixnum?: an immediate integer */
    P_SYMBOLP, /* shen-jit.symbol?: exactly the symbol objects */
    P_HASH,    /* shen-jit.hash: the hash override */
    P_EXIT,    /* shen-jit.exit: ends the process with a status */
    P_SYMBOL_KIND, /* shen-jit.symbol-kind: the kernel's symbol? and variable? */
    P_FILLED_VECTOR, /* shen-jit.filled-vector: an absvector filled with a value */
    P_DICT_FIND, P_DICT_PUT, P_DICT_REMOVE, P_DICT_ENTRIES, /* native dictionaries */
    P_TAGGEDP, /* shen-jit.tagged?: an absvector whose element 0 is a given symbol */
    P_SEALEDP, /* shen-jit.sealed?: whether calls to a name may be sealed */
    P_SEALING, /* shen-jit.sealing: turns sealing of new definitions on or off, or unseals a name */
    P_INLINE_BODY, /* shen-jit.inline-body: (Params Body) of a small definition, or [] */
    P_VECTORP, /* shen-jit.vector?: the kernel's vector?, without its trap-error */
    P_ABSVECTOR3, /* shen-jit.absvector3: a new absvector of three given values */
    P_QUIETP, /* shen-jit.quiet?: whether the innermost handler ignores errors */
    P_MARK_TOPLEVEL, /* shen-jit.mark-toplevel: the innermost handler is the REPL's */
    P_TRACE_TEXT, /* shen-jit.trace-text: the last captured backtrace, as text */
    P_BACKTRACE, /* shen-jit.backtrace: the frames on the stack now */
    P_READ_FILE, /* shen-jit.read-file: a whole file, as bytes or a string */
    P_INTEGERP, /* shen-jit.integer?: the port's integer? */
    P_APPEND, /* shen-jit.append: the port's append */
    P_ARITYP, /* shen-jit.arity?: whether a name's function is a closure of an arity */
    P_INLINEDP, /* shen-jit.inlined?: whether a name's definition has a given inline body */
    P_SAVE_EXECUTABLE, /* shen-jit.save-executable: writes a binary and exits */
    /* Byte buffers (docs/bytecode.md). */
    P_BYTES, P_BYTESP, P_BYTES_LENGTH,
    P_U8, P_U16, P_U32, P_SET_U8, P_SET_U16, P_SET_U32, /* in this order */
    P_S32, P_S64, P_F32, P_F64, P_SET_S32, P_SET_S64, P_SET_F32, P_SET_F64,
    P_STRING_BYTES, P_BYTES_STRING, P_COPY_BYTES,
    /* Bit operations on fixnums (docs/bytecode.md). */
    P_BIT_AND, P_BIT_OR, P_BIT_XOR, P_BIT_NOT, P_SHIFT_LEFT, P_SHIFT_RIGHT,
    P_ROTATE32, P_BSWAP32, P_POPCOUNT, P_CLZ, P_CTZ,
    P_DECIMAL, /* shen-jit.decimal: a literal past the fixnum range, for the reader */
    /* Prolog variables as immediate values (docs/bytecode.md). */
    P_PVAR, P_PVARP, P_PVAR_OFFSET, P_DEREF, P_SAMEP, P_NEWPV, P_GC,
    /* C functions and pointers (ffi.c), in this order. */
    P_FOREIGN, /* shen-jit.foreign: makes a name a C function */
    P_POINTERP, P_POINTER_KIND, P_POINTER_ADDRESS, P_BYTES_POINTER, P_POINTER_STRING, P_POINTER_BYTES,
    P_ERRNO, P_C_ERRNO, P_POINTER_KILL, P_POINTER_SIZED, P_SET_POINTER,
    P_POINTER_GUARD, P_POINTER_OWNER, P_POINTERS_DEAD, P_POINTER_READ_ONLY,
    P_COLLECT, /* shen-jit.collect */
    P_WRITE_BYTES, /* shen-jit.write-bytes: a range of a buffer to a stream, at once */
    /* Arities, which are program, and calls by name, for fn (docs/design.md, "The builder and isolates"). */
    P_ARITY,     /* shen-jit.arity: a name's arity, or -1 */
    P_SET_ARITY, /* shen-jit.set-arity: records a name's arity, -1 for none; the builder's alone */
    P_FUNCTION,  /* shen-jit.function: the procedure a name has now, inline (jit.c) */
    P_APPLY,     /* shen-jit.apply: calls a name's procedure, or a procedure, with a list */
    P_ISOLATE,   /* shen-jit.isolate: spawning, channels, monitors and kill (isolate.c) */
    P_FLOAT,     /* shen-jit.float: a number as a float, which the lowerer reads into a float register */
    P_SQRT,      /* shen-jit.sqrt: a number's square root, a float; float-sqrt in a float register */
    P_QUOTIENT, P_REMAINDER, /* shen-jit.quotient and remainder: of two fixnums, truncating */
    P_WORD_OP,   /* shen-jit.word-op: 64-bit words, boxed as 8 bytes (lib/word.shen) */
    P_TRUNCATE,  /* shen-jit.truncate: a number truncated to a fixnum; fix-from-float in registers */
    P_STRUCT_REF, /* shen-jit.struct-ref: a struct's field, the struct tested once for a slot (jit.c) */
    P_XXH64,     /* shen-jit.xxh64: the XXH64 of consecutive keys, stored as 8 bytes each */
    P_COUNT
};
#define PRIM_RAISE_COND P_COUNT
/* (prim D shen-jit.field O (const K)): element K of the vector in O, read with no check, where
   typechecked code calls a struct's reader (docs/bytecode.md). Not a function, and the checker of
   hand-written code refuses it; with a K that is not a constant, it reads as <-address does. */
#define PRIM_FIELD (P_COUNT + 1)

bool sj_equal_at(V a, V b, unsigned depth);
/* Keep the ordinary entry in the caller: no extra out-of-line wrapper before
   the recursive comparator. Depth belongs to this call, not the OS thread. */
static inline bool sj_equal(V a, V b) { return sj_equal_at(a, b, 0); }
uint64_t sj_hash(V v);
V sj_dict_find(VM *vm);
V sj_dict_put(VM *vm);
V sj_dict_remove(VM *vm);
V sj_dict_entries(VM *vm);
V sj_primitive(VM *vm, size_t index);
bool sj_init_host(VM *vm);

#endif

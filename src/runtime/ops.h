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
    X(OP_REAL_NUMBER, "real-number", 2)       \
    X(OP_REAL_BOX, "real-box", 2)             \
    X(OP_REAL_MOVE, "real-move", 2)           \
    X(OP_REAL_NEG, "real-neg", 2)             \
    X(OP_REAL_ABS, "real-abs", 2)             \
    X(OP_REAL_SQRT, "real-sqrt", 2)           \
    X(OP_REAL_ADD, "real+", 3)                \
    X(OP_REAL_SUB, "real-", 3)                \
    X(OP_REAL_MUL, "real*", 3)                \
    X(OP_REAL_DIV, "real/", 3)                \
    X(OP_REAL_UNLESS_LT, "real-unless<", 3)   \
    X(OP_REAL_UNLESS_GT, "real-unless>", 3)   \
    X(OP_REAL_UNLESS_LE, "real-unless<=", 3)  \
    X(OP_REAL_UNLESS_GE, "real-unless>=", 3)  \
    X(OP_REAL_UNLESS_EQ, "real-unless=", 3)   \
    X(OP_REAL_LOAD, "real-load", 3)           \
    X(OP_REAL_STORE, "real-store", 3)         \
    X(OP_REAL_LOAD_AT, "real-load-at", 3)     \
    X(OP_REAL_STORE_AT, "real-store-at", 3)   \
    X(OP_REAL_FROM_WORD, "real-from-word", 2) \
    X(OP_WORD_FROM_REAL, "word-from-real", 2) \
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
    X(OP_WORD_STORE64, "word-store64", 3)

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
    if (p[0] == OP_CLOSURE || p[0] == OP_PRIM || p[0] == OP_REAL_LOAD || p[0] == OP_REAL_STORE)
        return 4 + p[3];
    return 1 + fixed[p[0]];
}

/* The registers of code written by hand (docs/bytecode.md). */
#define REAL_REGISTERS 48
#define WORD_REGISTERS 16

/* What each operand of the instructions on them is: s a slot written, o a slot or constant read,
   r a real register, w a word register written, W a word register or constant read, l a label jumped
   to on a test, h a loop's head, which defines a label, b a label jumped back to.
   real-load and real-store are laid out as prim is, with the real register first. */
static inline const char *raw_kinds(unsigned op)
{
    switch (op) {
    case OP_LOOP: return "h";
    case OP_AGAIN: return "b";
    case OP_REAL_NUMBER: return "ro";
    case OP_REAL_BOX: return "sr";
    case OP_REAL_MOVE: case OP_REAL_NEG: case OP_REAL_ABS: case OP_REAL_SQRT: return "rr";
    case OP_REAL_ADD: case OP_REAL_SUB: case OP_REAL_MUL: case OP_REAL_DIV: return "rrr";
    case OP_REAL_UNLESS_LT: case OP_REAL_UNLESS_GT: case OP_REAL_UNLESS_LE: case OP_REAL_UNLESS_GE:
    case OP_REAL_UNLESS_EQ: return "rrl";
    case OP_REAL_LOAD: case OP_REAL_STORE: return "r";
    case OP_REAL_LOAD_AT: return "roW";
    case OP_REAL_STORE_AT: return "oWr";
    case OP_REAL_FROM_WORD: return "rW";
    case OP_WORD_FROM_REAL: return "wr";
    case OP_WORD_NUMBER: return "wo";
    case OP_WORD_BOX: return "sW";
    case OP_WORD_MOVE: return "wW";
    case OP_WORD_ADD: case OP_WORD_SUB: case OP_WORD_MUL: case OP_WORD_AND: case OP_WORD_OR: case OP_WORD_XOR:
    case OP_WORD_SHL: case OP_WORD_SHR: case OP_WORD_SAR: case OP_WORD_ROTL: case OP_WORD_ROTR: return "wWW";
    case OP_WORD_UNLESS_LT: case OP_WORD_UNLESS_GT: case OP_WORD_UNLESS_LE: case OP_WORD_UNLESS_GE:
    case OP_WORD_UNLESS_EQ: case OP_WORD_UNLESS_ULT: case OP_WORD_UNLESS_UGT: case OP_WORD_UNLESS_ULE:
    case OP_WORD_UNLESS_UGE: return "WWl";
    case OP_WORD_LOAD8: case OP_WORD_LOAD16: case OP_WORD_LOAD32: case OP_WORD_LOAD_S32: case OP_WORD_LOAD64:
        return "woW";
    case OP_WORD_STORE8: case OP_WORD_STORE16: case OP_WORD_STORE32: case OP_WORD_STORE64: return "oWW";
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
   raise-cond follows it. */
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
    P_SEALING, /* shen-jit.sealing: turns sealing of new definitions on or off */
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
    P_THREAD, /* shen-jit.thread: runs a procedure in a new thread (thread.c) */
    /* C functions and pointers (ffi.c), in this order. */
    P_FOREIGN, /* shen-jit.foreign: makes a name a C function */
    P_POINTERP, P_POINTER_KIND, P_POINTER_ADDRESS, P_BYTES_POINTER, P_POINTER_STRING, P_POINTER_BYTES,
    P_ERRNO, P_C_ERRNO, P_POINTER_KILL, P_POINTER_SIZED, P_SET_POINTER,
    P_POINTER_GUARD, P_POINTER_OWNER, P_POINTERS_DEAD, P_POINTER_READ_ONLY,
    P_COLLECT, /* shen-jit.collect */
    P_WRITE_BYTES, /* shen-jit.write-bytes: a range of a buffer to a stream, at once */
    P_WORKER_SCOPE, P_WORKER_BATCH, P_WORKER_INDEX, P_WORKER_LIVE, P_WORKER_CANCELLED, P_WORKER_SHARED_VIEW,
    /* Arities, which are program, and calls by name, for fn (docs/design.md, "The builder and isolates"). */
    P_ARITY,     /* shen-jit.arity: a name's arity, or -1 */
    P_SET_ARITY, /* shen-jit.set-arity: records a name's arity, -1 for none; the builder's alone */
    P_FUNCTION,  /* shen-jit.function: the procedure a name has now, inline (jit.c) */
    P_APPLY,     /* shen-jit.apply: calls a name's procedure, or a procedure, with a list */
    P_COUNT
};
#define PRIM_RAISE_COND P_COUNT

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
bool sj_start_isolate(VM *vm, V gensym_base);

#endif

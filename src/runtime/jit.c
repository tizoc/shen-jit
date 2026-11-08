/* Baseline JIT. Every compiled function shares one SLJIT context: S0 holds the
   guest frame pointer, S1 the VM, and compiled code never pushes anything on
   the C stack, so all of it runs inside the adapter's frame. A call stores a
   return label in the callee's slot 0 and the callee in slot 1, moves the
   frame pointer to the window and jumps; a return jumps through slot 0. The
   argument count travels in R2 and the callee checks it. */
#include "file.h"
#include "jit.h"
#include "ops.h"

#include "../../vendor/sljit/sljit_src/sljitLir.h"

#ifdef __APPLE__
#include <pthread.h>
#endif
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FP SLJIT_S0
#define VMR SLJIT_S1
/* The last result: holds slot Emit.cached, while that is not NONE. */
#define CACHE SLJIT_S2, 0
/* The heap pointer, vm->hp, while compiled code runs: call_c writes it back
   before calling C, which may allocate or collect, and loads it after. */
#define HP SLJIT_S3, 0
#define NONE UINT32_MAX
/* The registers of code written by hand. Three float registers are for one instruction's work;
   assign_places gives the next ones, and the integer registers this leaves, to what is used most,
   and the others live in the native frame. Neither the collector nor C sees them, and what is in a
   scratch register waits in the native frame around a call to C that returns. */
#define REAL_FLOATS (SLJIT_NUMBER_OF_FLOAT_REGISTERS - 3)
#define WORD_GPRS (SLJIT_NUMBER_OF_REGISTERS - SAVEDS - 5)
/* Where integer registers are many, as on arm64, memory is kept for eight parameters, and a word
   counts twice what its base and limits do. Where they are few, as on x86-64, the hottest of all
   keep them, and four are kept: there, each change cost some loop more than it gave. */
#define MANY_GPRS (WORD_GPRS >= 8)
#define CACHED_MEMORY (MANY_GPRS ? 8 : 4)
#define RAW_INTEGERS (WORD_REGISTERS + 3 * CACHED_MEMORY)
#define SCRATCHES ((5 + WORD_GPRS) | SLJIT_ENTER_FLOAT(3 + REAL_FLOATS))
#define LOCALS ((REAL_REGISTERS + RAW_INTEGERS) * (sljit_s32)sizeof(sljit_sw))
/* Registers S4 and up hold the slots of a loop that keeps them in registers
   (Emit.homes): six on arm64, fewer where SLJIT has fewer saved registers. Where
   that leaves fewer than six, scratch registers R5 and up serve too, if code written
   by hand has not taken them: two on x86-64 outside Windows, and none on Windows.
   Those wait in the frame around any call to C. */
#define SAVED_HOMES (SLJIT_NUMBER_OF_SAVED_REGISTERS - 4 < 6 ? SLJIT_NUMBER_OF_SAVED_REGISTERS - 4 : 6)
#define SAVEDS (4 + SAVED_HOMES)
#define HOMES (SAVED_HOMES + (WORD_GPRS < 6 - SAVED_HOMES ? WORD_GPRS : 6 - SAVED_HOMES))
#define HOME_REG(k) ((k) < SAVED_HOMES ? SLJIT_S(4 + (k)) : SLJIT_R(5 + (k) - SAVED_HOMES))
/* Where code without homes keeps results it reads again soon (Emit.kept). */
#define KEPT 2
#define KEPT_REG(k) SLJIT_S(4 + (k))
/* Loop heads start on a 32-byte boundary: with 16, a 32-item list walk took
   12 or 17 ms depending on what was compiled before it. */
#define LOOP_ALIGN SLJIT_LABEL_ALIGN_32
/* The largest frame of code that calls nothing, which then skips the stack
   check: within what its caller's check or jit_call reserved beyond their own. */
#define LEAF_FRAME 64
#define ARG_TYPES SLJIT_ARGS1(W, P)
#define WORD ((sljit_sw)sizeof(V))
#define SLOT(n) SLJIT_MEM1(FP), (sljit_sw)(n) * WORD
#define VMF(field) SLJIT_MEM1(VMR), (sljit_sw)offsetof(VM, field)
#define IMM(x) SLJIT_IMM, (sljit_sw)(x)
#define R0 SLJIT_R0, 0
#define R1 SLJIT_R1, 0
#define R2 SLJIT_R2, 0
#define R3 SLJIT_R3, 0
#define R4 SLJIT_R4, 0
#define ENTRY_OF(reg) SLJIT_MEM1(reg), (sljit_sw)(PROC_ENTRY * sizeof(V)) - TAG_PROC

/* A real register, or a raw integer, in its place (see Emit), and the word of the native frame a
   place has. */
#define REAL(e, n) real_kind(e, n), real_offset(e, n)
#define REAL_SAVED(place) SLJIT_MEM1(SLJIT_SP), (sljit_sw)(place) * WORD
#define RAW(e, n) raw_kind(e, n), raw_offset(e, n)
#define RAW_SAVED(place) SLJIT_MEM1(SLJIT_SP), (sljit_sw)(REAL_REGISTERS + (place)) * WORD
#define WORD_OPERAND(e, x) word_kind(e, x), word_offset(e, x)


/* A branch that a redefinition of the name in cell rewrites: an open self
   tail call's jump back, or the nop that runs an open callee's inlined body. */
typedef struct {
    uintptr_t native; /* the entry of the code it is in */
    size_t cell;
    uint8_t *at;             /* the bytes rewritten */
    uint8_t size, bytes[5];  /* how many, and what they become */
} Patch;

struct Jit {
    V (*adapter)(VM *);
    void *unwind;
    void *arity;
    void *compile;
    void *foreign;
    void *stubs;
    FILE *perf_map; /* address, size and name of each compiled code object */
    /* For backtraces: the return address of every call in compiled code,
       with the call's window offset in slots, in an open-addressing table
       (0 is an empty entry). */
    uintptr_t *site_addr;
    uint32_t *site_window;
    /* With each site, the bodies inlined there, as an index plus one into
       chains: a count, then the callees' cells, innermost first. Also kept
       for where slow paths call C helpers that may raise (window 0). */
    uint32_t *site_chain;
    size_t nsites, sites_cap;
    size_t *chains;
    size_t nchains, chains_cap;
    Patch *patches; /* see redefine */
    size_t npatches, patches_cap;
    size_t ncompiled, nfreed;
};

/* A jump on whether v's tag is `tag` (type: SLJIT_EQUAL or SLJIT_NOT_EQUAL), with
   t for scratch. Subtracting the tag leaves the low bits zero exactly then: on
   x86-64 a lea and a test, against a move, a mask and a compare. */
static struct sljit_jump *tag_cmp(struct sljit_compiler *c, sljit_s32 type, sljit_s32 t, sljit_sw tw,
                                  sljit_s32 v, sljit_sw vw, sljit_sw tag)
{
    sljit_emit_op2(c, SLJIT_SUB, t, tw, v, vw, SLJIT_IMM, tag);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, t, tw, SLJIT_IMM, 7);
    return sljit_emit_jump(c, type == SLJIT_EQUAL ? SLJIT_ZERO : SLJIT_NOT_ZERO);
}

static size_t site_index(uintptr_t addr, size_t cap) { return (size_t)((addr >> 2) * 0x9E3779B97F4A7C15u) & (cap - 1); }

static void site_put(Jit *jit, uintptr_t addr, uint32_t window, uint32_t chain)
{
    if (2 * (jit->nsites + 1) > jit->sites_cap) {
        size_t cap = jit->sites_cap ? 2 * jit->sites_cap : 1024;
        uintptr_t *addrs = calloc(cap, sizeof *addrs);
        uint32_t *windows = calloc(cap, sizeof *windows), *chains = calloc(cap, sizeof *chains);
        if (!addrs || !windows || !chains) {
            free(addrs);
            free(windows);
            free(chains);
            return; /* backtraces then stop at this call */
        }
        for (size_t i = 0; i < jit->sites_cap; i++)
            if (jit->site_addr[i]) {
                size_t j = site_index(jit->site_addr[i], cap);
                while (addrs[j])
                    j = (j + 1) & (cap - 1);
                addrs[j] = jit->site_addr[i];
                windows[j] = jit->site_window[i];
                chains[j] = jit->site_chain[i];
            }
        free(jit->site_addr);
        free(jit->site_window);
        free(jit->site_chain);
        jit->site_addr = addrs;
        jit->site_window = windows;
        jit->site_chain = chains;
        jit->sites_cap = cap;
    }
    size_t j = site_index(addr, jit->sites_cap);
    while (jit->site_addr[j] && jit->site_addr[j] != addr)
        j = (j + 1) & (jit->sites_cap - 1);
    if (!jit->site_addr[j])
        jit->nsites++;
    jit->site_addr[j] = addr;
    jit->site_window[j] = window;
    jit->site_chain[j] = chain;
}

static bool site_get(const Jit *jit, uintptr_t addr, uint32_t *window, uint32_t *chain)
{
    if (!jit->sites_cap || !addr)
        return false;
    for (size_t j = site_index(addr, jit->sites_cap); jit->site_addr[j]; j = (j + 1) & (jit->sites_cap - 1))
        if (jit->site_addr[j] == addr) {
            *window = jit->site_window[j];
            *chain = jit->site_chain[j];
            return true;
        }
    return false;
}

/* The names of the bodies inlined at a site, innermost first. */
static size_t chain_names(VM *vm, uint32_t chain, V *names, size_t n, size_t max)
{
    if (!chain)
        return n;
    const size_t *c = vm->jit->chains + chain - 1;
    for (size_t k = 0; k < c[0]; k++, n++)
        if (n < max)
            names[n] = cell_symbol(vm, c[1 + k]);
    return n;
}

static void fatal(const char *message);

/* An open self tail call jumps straight back to its body, and an open
   callee's inlined body runs after a nop; a redefinition of the name
   rewrites that one instruction into a jump to the call through the name.
   On arm64 both are one instruction. On x86-64 the jump back is a short or
   a near jmp, whose displacement is rewritten, and the nop takes five bytes,
   room for a near jmp. Elsewhere both compare the name's procedure each
   time. */
#if (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
#define PATCH_SELF 1
#define ARM64_B 0x14000000u /* b, with a 26-bit word offset */
#define ARM64_NOP 0xD503201Fu
/* SLJIT gives a jump's address as that of its instruction. */
#define JUMP_INSN(jump) sljit_get_jump_addr(jump)
#elif (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
#define PATCH_SELF 1
#define X86_JMP8 0xEBu  /* jmp, with an 8-bit displacement */
#define X86_JMP32 0xE9u /* jmp, with a 32-bit displacement */
static const uint8_t X86_NOP5[5] = {0x0F, 0x1F, 0x44, 0x00, 0x00}; /* nop dword [rax+rax] */
/* SLJIT gives a jump's address as that of its displacement, after the
   one-byte opcode. */
#define JUMP_INSN(jump) (sljit_get_jump_addr(jump) - 1)
#else
#define PATCH_SELF 0
#define JUMP_INSN(jump) sljit_get_jump_addr(jump)
#endif

/* The nop of a patch site. */
static void emit_patch_nop(struct sljit_compiler *c)
{
#if (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
    sljit_emit_op_custom(c, (void *)X86_NOP5, sizeof X86_NOP5);
#else
    sljit_emit_op0(c, SLJIT_NOP);
#endif
}

static void patch_put(VM *vm, void *native, size_t cell, sljit_uw at, sljit_uw target)
{
#if PATCH_SELF
    Jit *jit = vm->jit;
    Patch p = {(uintptr_t)native, cell, (uint8_t *)at, 0, {0}};
#if (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    uint32_t insn;
    memcpy(&insn, p.at, 4);
    if ((insn & 0xFC000000u) != ARM64_B && insn != ARM64_NOP)
        fatal("a patch site is not one branch or nop");
    insn = ARM64_B | ((uint32_t)(((intptr_t)target - (intptr_t)at) >> 2) & 0x03FFFFFFu);
    p.size = 4;
    memcpy(p.bytes, &insn, 4);
#else
    /* A displacement counts from the end of its jmp: the nop becomes a near
       jmp, and a jmp keeps its opcode. Both lie in one block of code, well
       within a near jmp's reach. */
    int32_t near = (int32_t)((intptr_t)target - (intptr_t)(at + 5));
    intptr_t short_rel = (intptr_t)target - (intptr_t)(at + 2);
    if (memcmp(p.at, X86_NOP5, sizeof X86_NOP5) == 0) {
        p.bytes[0] = X86_JMP32;
        memcpy(p.bytes + 1, &near, 4);
        p.size = 5;
    } else if (p.at[0] == X86_JMP32) {
        memcpy(p.bytes, &near, 4);
        p.at++;
        p.size = 4;
    } else if (p.at[0] == X86_JMP8 && short_rel >= -128 && short_rel <= 127) {
        p.bytes[0] = (uint8_t)(int8_t)short_rel;
        p.at++;
        p.size = 1;
    } else {
        fatal("a patch site is not one jmp or nop");
    }
#endif
    if (jit->npatches == jit->patches_cap) {
        size_t cap = jit->patches_cap ? 2 * jit->patches_cap : 64;
        void *patches = realloc(jit->patches, cap * sizeof *jit->patches);
        if (!patches)
            fatal("out of memory");
        jit->patches = patches;
        jit->patches_cap = cap;
    }
    jit->patches[jit->npatches++] = p;
#else
    (void)vm, (void)native, (void)cell, (void)at, (void)target;
#endif
}

/* Drops the patches of native code being freed, or rewrites and drops those
   a redefinition of the name in a cell undoes. */
static void patches_drop(Jit *jit, bool redefined, uintptr_t key)
{
    for (size_t i = 0; i < jit->npatches; i++) {
        if ((redefined ? jit->patches[i].cell : jit->patches[i].native) != key)
            continue;
#if PATCH_SELF
        if (redefined) {
            Patch *p = &jit->patches[i];
#if defined __APPLE__ && (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
            pthread_jit_write_protect_np(0);
#endif
            memcpy(p->at, p->bytes, p->size);
#if defined __APPLE__ && (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
            pthread_jit_write_protect_np(1);
#endif
            __builtin___clear_cache((char *)p->at, (char *)p->at + p->size);
        }
#endif
        jit->patches[i--] = jit->patches[--jit->npatches];
    }
}

static void redefine(VM *vm, size_t cell)
{
    if (vm->jit->npatches)
        patches_drop(vm->jit, true, cell);
}

/* The names of the frames on the stack, innermost first: from vm->fp, each
   frame's slot 1 is its procedure and slot 0 its return address, which the
   call-site table maps to the caller's window offset. The walk stops at the
   expression being evaluated, whose code is named eval-kl, or at the port's
   shen-jit.eval-kl below it, which calls it; both are left out. It also
   stops at the REPL's frame (vm->trace_floor) and at the first frame that
   is not a compiled call. Up to max names are stored; the number of frames
   is returned, and *evaluated says whether the walk reached the expression
   being evaluated, so that the error came from running code rather than,
   say, the reader or the typechecker working on the input. */
size_t jit_backtrace(VM *vm, V *names, size_t max, bool *evaluated)
{
    size_t n = 0;
    *evaluated = false;
    if (!vm->jit)
        return 0;
    V *floor = vm->trace_floor == SIZE_MAX ? vm->stack : vm->stack + vm->trace_floor + 1;
    /* Each frame's code may have inlined bodies where it is: at the site of
       the C helper that raised, for the innermost, and at its call for the
       others. Their names come first. */
    uint32_t window, chain = 0;
    if (!vm->site || !site_get(vm->jit, (uintptr_t)vm->site, &window, &chain))
        chain = 0;
    for (V *fp = vm->fp; fp >= floor && fp + 1 < vm->stack + vm->stack_words;) {
        V proc = fp[1];
        if (!is_proc(proc))
            break;
        V name;
        if (hdr_type(ptr(proc)[0]) == T_CLOSURE)
            name = ptr(ptr(proc)[CLO_CODE])[CODE_NAME];
        else if (hdr_type(ptr(proc)[0]) == T_FOREIGN)
            name = ptr(ptr(proc)[FOREIGN_DESC])[1];
        else
            break;
        n = chain_names(vm, chain, names, n, max);
        if (symbol_named(name, "eval-kl") || symbol_named(name, "shen-jit.eval-kl")) {
            *evaluated = true;
            break;
        }
        if (n < max)
            names[n] = name;
        n++;
        if (!site_get(vm->jit, (uintptr_t)fp[0], &window, &chain) || window == 0 ||
            window > (size_t)(fp - vm->stack))
            break;
        fp -= window;
    }
    return n;
}

static void fatal(const char *message)
{
    fprintf(stderr, "shen-jit: %s\n", message);
    abort();
}

/* Helpers called from compiled code. Those that raise return V_CLEARED. */

static void *h_unwind(VM *vm)
{
    if (vm->nhandlers == 0)
        return NULL;
    Handler *h = &vm->handlers[--vm->nhandlers];
    vm->fp = vm->stack + (h->fp_offset >> 1);
    return h->catch_addr;
}

V sj_raise_arity(VM *vm, V symbol, size_t arity, size_t given)
{
    V name = ptr(symbol)[SYM_NAME];
    char text[160];
    snprintf(text, sizeof text, "%.*s: expected %zu argument%s, got %zu",
             (int)(string_length(name) > 64 ? 64 : string_length(name)), string_bytes(name),
             arity, arity == 1 ? "" : "s", given);
    return sj_raise_text(vm, text);
}

/* The arity stub publishes the callee's window: slot 1 holds the callee,
   and vm->count the number of arguments it was given. */
static V h_arity_error(VM *vm)
{
    V f = vm->fp[1];
    if (!is_proc(f) || hdr_type(ptr(f)[0]) != T_CLOSURE || !is_symbol(ptr(ptr(f)[CLO_CODE])[CODE_NAME]))
        return sj_raise(vm, "wrong number of arguments");
    uint64_t *code = ptr(ptr(f)[CLO_CODE]);
    return sj_raise_arity(vm, code[CODE_NAME], code[CODE_ARITY] & UINT32_MAX, vm->count);
}

/* A named call reaches here only when its cell holds no function. */
static V h_not_procedure(VM *vm, V p, size_t cell)
{
    return p == V_CLEARED ? sj_raise_value(vm, "undefined function ~S", cell_symbol(vm, cell))
                          : sj_raise_value(vm, "~S is not a function", p);
}

static V h_boolean_error(VM *vm, V v) { return sj_raise_value(vm, "~S is not a boolean", v); }
static V h_not_number(VM *vm, V v) { return sj_raise_value(vm, "~S is not a number", v); }
static V h_not_integer(VM *vm, V v) { return sj_raise_value(vm, "~S is not an integer", v); }

static V h_too_big(VM *vm, sljit_sw word)
{
    char text[80];
    snprintf(text, sizeof text, "the word %lld does not fit in an integer", (long long)word);
    return sj_raise_text(vm, text);
}

/* What is wrong with an access at a word index that failed its check. */
static V h_memory_error(VM *vm, V memory, sljit_sw index, sljit_sw store)
{
    char *base, text[80];
    size_t length;
    if (!memory_of(memory, &base, &length))
        return sj_raise_value(vm, "bytes: ~S is not a byte buffer", memory);
    if (store && is_read_only(memory))
        return sj_raise_value(vm, "bytes: ~S is read only", memory);
    snprintf(text, sizeof text, "bytes: %lld is not a valid index", (long long)index);
    return sj_raise_text(vm, text);
}

/* A sealed call whose target was not defined when its code was installed:
   the slot holds the target's symbol until this binds it, once. */
static V h_resolve(VM *vm, V *slot)
{
    V target = is_symbol(*slot) ? *cell_function(vm, symbol_cell(*slot)) : *slot;
    if (!is_proc(target))
        return sj_raise_value(vm, "undefined function ~S", *slot);
    return *slot = target;
}

/* Ctrl-C clears check_limit, so the next
   frame or loop check comes here. */
static V h_grow(VM *vm, size_t frame)
{
    if (vm->interrupted == PREEMPT) {
        thread_preempted(vm);
    } else if (vm->interrupted && vm->thread && !vm->thread->main) {
        thread_yield(vm); /* a Ctrl-C is for the main thread, which the REPL runs in */
    } else if (vm->interrupted && sj_take_interrupt(vm)) {
        return sj_raise(vm, "interrupted");
    }
    size_t need = (size_t)(vm->fp - vm->stack) + frame;
    return vm_stack_reserve(vm, need) ? V_NIL : sj_raise(vm, "stack overflow");
}

static V h_alloc(VM *vm, size_t words)
{
    return vm_collect(vm, words) ? V_NIL : sj_raise(vm, "out of memory");
}

static V h_prim(VM *vm, size_t index) { return sj_primitive(vm, index); }

/* cn's copy, for native code that allocated the string itself: a's bytes,
   then b's, with zeros to the end of the last word. Strings are padded with
   zeros to a whole word, so the copy is whole words: a's, then b's shifted
   to follow a's last byte, each word of the result stored once and nothing
   past it. It calls nothing, so it needs no frame: libc's memcpy cost more
   than the copy for the few bytes cn usually moves, and the compiler turns
   the plain loops into wide copies for long strings. */
static V h_cn_bytes(uint64_t *p, V a, V b)
{
    const uint64_t *x = ptr(a) + 1, *y = ptr(b) + 1;
    uint64_t *d = p + 1;
    size_t la = string_length(a), lb = string_length(b);
    size_t nb = (lb + 7) / 8, n = (la + lb + 7) / 8, q = la / 8;
    unsigned shift = (unsigned)(la % 8) * 8;
    if (!n)
        d[0] = 0;
    for (size_t i = 0; i < q; i++)
        d[i] = x[i];
    if (!shift) {
        for (size_t i = 0; i < nb; i++)
            d[q + i] = y[i];
        return tagged(p, TAG_OBJECT);
    }
    uint64_t w = x[q]; /* a's last bytes, then zeros */
    for (size_t i = 0; i < nb; i++) {
        uint64_t v = y[i];
        d[q + i] = w | v << shift;
        w = v >> (64 - shift);
    }
    if (q + nb < n)
        d[q + nb] = w;
    return tagged(p, TAG_OBJECT);
}

/* = where the inline tests could not settle it. Equality allocates nothing on
   the heap and does not raise, so it needs no published frame. */
static V h_equal(V a, V b) { return sj_equal(a, b) ? V_TRUE : V_FALSE; }

/* A closure of the code object in constant slot `code_slot`, capturing the
   given slots of the current frame. The slots are read after allocating. */
static V h_push_handler(VM *vm, void *catch_addr, size_t quiet)
{
    if (vm->nhandlers == vm->handlers_cap) {
        size_t cap = vm->handlers_cap ? 2 * vm->handlers_cap : 64;
        Handler *h = realloc(vm->handlers, cap * sizeof *h);
        if (!h)
            return sj_raise(vm, "out of memory");
        vm->handlers = h;
        vm->handlers_cap = cap;
    }
    vm->handlers[vm->nhandlers++] = (Handler){(size_t)(vm->fp - vm->stack) << 1 | quiet, catch_addr};
    return V_NIL;
}

static void *compile_code(VM *vm, V code);

/* Entered through a closure whose entry is still the compile stub. */
static void *h_compile(VM *vm)
{
    uint64_t *p = ptr(vm->fp[1]);
    uint64_t *code = ptr(p[CLO_CODE]);
    if (!code[CODE_NATIVE]) {
        void *native = compile_code(vm, p[CLO_CODE]);
        if (!native)
            fatal("native compilation failed");
        code[CODE_NATIVE] = (uint64_t)(uintptr_t)native;
    }
    p[PROC_ENTRY] = code[CODE_NATIVE];
    return (void *)(uintptr_t)code[CODE_NATIVE];
}

/* Emitting a code object. */

typedef enum { SLOW_PRIM, SLOW_ALLOC, SLOW_BOOLEAN, SLOW_NOT_PROC, SLOW_GROW, SLOW_LOOP, SLOW_RESOLVE, SLOW_GUARD,
               SLOW_RETURN, SLOW_POINTER, SLOW_NOT_NUMBER, SLOW_NOT_INTEGER, SLOW_TOO_BIG, SLOW_MEMORY } SlowKind;

typedef struct Slow {
    SlowKind kind;
    struct sljit_jump *from[5];
    struct sljit_label *back;
    const uint32_t *insn; /* for SLOW_PRIM and SLOW_BOOLEAN */
    uint64_t words;       /* for SLOW_ALLOC; the slot's address for SLOW_RESOLVE */
    uint32_t branch;      /* for a fused SLOW_PRIM: the label to take on false */
    uint32_t restore;     /* the slot CACHE holds again before going back, or NONE */
    uint32_t catch_label; /* for SLOW_PRIM: a quiet handler of this code to jump to, or NONE */
    struct sljit_label *start; /* where the slow path's code begins */
    uint32_t chain;            /* the bodies inlined where it comes from */
    struct Slow *exit;         /* for an exit test's SLOW_PRIM: its return, taken on true */
    struct Slow *prim;         /* for SLOW_POINTER: the slow path of the instruction, emitted before it */
    bool store;                /* for SLOW_POINTER and SLOW_MEMORY: the access is a store */
    uint32_t memory, index;    /* for SLOW_MEMORY: operands, the second a word */
    uint32_t kept[KEPT];  /* what the kept registers hold again before going back */
} Slow;

typedef struct {
    VM *vm;
    struct sljit_compiler *c;
    uint32_t reals, word_regs; /* how many of each register the code uses */
    uint32_t memory[CACHED_MEMORY], nmemory; /* the slots whose memory is cached (emit_memory_caches) */
    bool uncached;                           /* for bytes-length, which must see what is there */
    /* Where memory is reached at one width and at word indices alone, the log2 of that width, and
       its lengths are limits on the index; else -1. */
    int8_t limit_size[CACHED_MEMORY];
    /* What assign_places chose: real registers are numbered as the code does, and raw integers too,
       with kept memory after the word registers, three each: base, read length, store length. A
       place is a float register, or for raw integers a scratch register and then any of raw_saved
       saved ones, and past those a word of the native frame. */
    uint8_t real_place[REAL_REGISTERS], raw_place[RAW_INTEGERS];
    sljit_s32 raw_saved;
    uint64_t frame, arity, cbase, nconst;
    struct sljit_label **labels;
    struct {
        struct sljit_jump *jump;
        uint32_t label;
    } *fixups;
    size_t nfixups;
    Slow *slow;
    size_t nslow;
    V code;                    /* the code object being compiled */
    struct sljit_label *body;  /* after the entry checks */
    struct {
        struct sljit_label *back; /* the return address of a call */
        uint32_t window, chain;
    } *calls;
    size_t ncalls;
    /* The bodies inlined around the instruction being compiled (OP_INLINE),
       innermost last: each callee's cell and the offset where it ends; and
       the stack interned in the Jit's chains, or 0 for none or not yet. */
    size_t inl_cell[8], inl_end[8];
    uint32_t ninl, chain;
    /* Where slow paths inside inlined bodies call helpers that may raise. */
    struct {
        struct sljit_label *ret;
        uint32_t chain;
    } *raises;
    size_t nraises;
    /* The last result kept in a register: before an instruction, CACHE holds slot `cached`, which every
       operand read of that slot uses; an instruction sets `post` to the slot
       CACHE holds after it. Slots are still written, so a slow path can read
       them, and it loads CACHE again before going back, since a collection
       may have moved the value. */
    uint32_t cached, post;
    /* Two more registers the same way, for code that keeps no slots in registers and has no raw
       values: the slot each holds before this instruction and after it, or NONE. Slots are still
       written, as for CACHE. A label keeps what all the ways into it agree on, and a call drops them. A
       slow path that may have collected loads them again, and reads operands from their slots. */
    uint32_t kept[KEPT], kept_post[KEPT];
    bool keeps;
    /* Callers leave the first argument in CACHE too; the body starts with
       slot 2 cached only if it reads it soon. Self tail calls skip the load
       when it does not. */
    uint32_t entry;
    /* A loop that keeps its slots in registers (home_count): slots 2 to
       homes + 1 live in S4 and up, and CACHE is not used. */
    uint32_t homes;
    bool loops; /* whether it loops through a self tail call */
    const uint32_t *words; /* the bytecode, and the next instruction's offset */
    size_t nwords, next;
    /* Slots below 64 known to hold a pair: set where a cons? test falls
       through, cleared when the slot is written, at labels and after calls.
       hd and tl of such a slot need no tag check. */
    uint64_t pairs;
    /* What the jumps to each label agree on. Jumps only go forward, so all
       those from the code before a label are known where it is placed; with
       falling through, they decide what CACHE and the pairs hold there.
       Slow paths come later and load CACHE before jumping. */
    struct {
        bool seen;
        uint32_t cached;
        uint32_t kept[KEPT];
        uint64_t pairs;
    } *at_label;
    const size_t *label_pos; /* each label's offset in the bytecode */
    /* Scratch buffers shared by dead_after's walks of this code. */
    size_t *todo;
    unsigned char *seen;
    /* The handlers pushed by this code that are active here, innermost
       last: each one's label, with NONE for one that reads the exception. */
    uint32_t *handlers;
    size_t nhandlers;
    /* Words a run of conses has checked room for and not yet taken. */
    size_t reserved;
    /* Open self tail calls: the jump back, and the code that replaces it. */
    struct {
        struct sljit_jump *jump;
        struct sljit_label *other;
    } *selfs;
    size_t nselfs;
    /* Inlined open callees: the nop, its stub, and the callee's cell. */
    struct {
        struct sljit_label *at;
        Slow *stub;
        size_t cell;
    } *guards;
    size_t nguards;
} Emit;

static sljit_s32 real_kind(const Emit *e, uint32_t n)
{
    return e->real_place[n] < REAL_FLOATS ? SLJIT_FR(3 + e->real_place[n]) : SLJIT_MEM1(SLJIT_SP);
}

static sljit_sw real_offset(const Emit *e, uint32_t n)
{
    return e->real_place[n] < REAL_FLOATS ? 0 : (sljit_sw)e->real_place[n] * WORD;
}

/* The float register a real register is in, or FR0 for one to go through. */
static sljit_s32 real_register(const Emit *e, uint32_t n)
{
    return e->real_place[n] < REAL_FLOATS ? real_kind(e, n) : SLJIT_FR0;
}

/* C keeps saved registers, and these are the ones it does not. */
static bool raw_scratch(uint32_t place) { return (sljit_s32)place < WORD_GPRS; }

static sljit_s32 raw_kind(const Emit *e, uint32_t n)
{
    sljit_s32 place = e->raw_place[n];
    return place < WORD_GPRS ? SLJIT_R(5 + place)
         : place < WORD_GPRS + e->raw_saved ? SLJIT_S(4 + place - WORD_GPRS) : SLJIT_MEM1(SLJIT_SP);
}

static sljit_sw raw_offset(const Emit *e, uint32_t n)
{
    sljit_s32 place = e->raw_place[n];
    return place < WORD_GPRS + e->raw_saved ? 0 : (sljit_sw)(REAL_REGISTERS + place) * WORD;
}

/* The register a raw integer is in, or one for it to go through. */
static sljit_s32 raw_register(const Emit *e, uint32_t n, sljit_s32 through)
{
    return raw_kind(e, n) & SLJIT_MEM ? through : raw_kind(e, n);
}

/* A word operand: a word register, or a constant integer. Anything else reads as 0: the checker
   lets a program build only integers, and shen-jit.install checks shapes alone. */
static sljit_s32 word_kind(const Emit *e, uint32_t x) { return x & OPERAND_CONST ? SLJIT_IMM : raw_kind(e, x); }

/* One more way into a label, with the current state. */
static void reach_label(Emit *e, uint32_t label)
{
    if (!e->at_label[label].seen) {
        e->at_label[label].seen = true;
        e->at_label[label].cached = e->cached;
        e->at_label[label].pairs = e->pairs;
        for (int k = 0; k < KEPT; k++)
            e->at_label[label].kept[k] = e->kept[k];
    } else {
        if (e->at_label[label].cached != e->cached)
            e->at_label[label].cached = NONE;
        for (int k = 0; k < KEPT; k++)
            if (e->at_label[label].kept[k] != e->kept[k])
                e->at_label[label].kept[k] = NONE;
        e->at_label[label].pairs &= e->pairs;
    }
}

static void to_label(Emit *e, struct sljit_jump *jump, uint32_t label)
{
    e->fixups[e->nfixups].jump = jump;
    e->fixups[e->nfixups++].label = label;
    reach_label(e, label);
}

/* Before a jump from a slow path, where CACHE may be stale: load what the
   label expects. */
static void load_for_label(Emit *e, uint32_t label)
{
    if (e->at_label[label].cached != NONE)
        sljit_emit_op1(e->c, SLJIT_MOV, CACHE, SLJIT_MEM1(FP), (sljit_sw)e->at_label[label].cached * WORD);
    for (int k = 0; k < KEPT; k++)
        if (e->at_label[label].kept[k] != NONE)
            sljit_emit_op1(e->c, SLJIT_MOV, KEPT_REG(k), 0, SLJIT_MEM1(FP), (sljit_sw)e->at_label[label].kept[k] * WORD);
}

static void to_unwind(Emit *e, struct sljit_jump *jump)
{
    sljit_set_target(jump, (sljit_uw)e->vm->jit->unwind);
}

/* Slot n where the code keeps it: its register in a loop that keeps its
   slots in registers, else its frame word. HOME gives SLJIT's operand pair. */
static sljit_s32 slot_kind(const Emit *e, uint32_t n)
{
    return n >= 2 && n < e->homes + 2 ? HOME_REG((sljit_s32)n - 2) : SLJIT_MEM1(FP);
}

static sljit_sw slot_offset(const Emit *e, uint32_t n)
{
    return n >= 2 && n < e->homes + 2 ? 0 : (sljit_sw)n * WORD;
}

#define HOME(e, n) slot_kind(e, n), slot_offset(e, n)

/* Operands of prim, jump-if-false and return (docs/bytecode.md): a slot, or a
   constant of the code with OPERAND_CONST set. A constant that is not a
   pointer is an immediate; any other is read from its constant cell, which
   never moves. OPND gives SLJIT's operand pair. */
static V *operand_cell(const Emit *e, uint32_t x)
{
    return ra_at(&e->vm->consts, e->cbase + (x & ~OPERAND_CONST));
}

static sljit_s32 operand_kind(const Emit *e, uint32_t x)
{
    if (x == e->cached)
        return SLJIT_S2;
    for (int k = 0; k < KEPT; k++)
        if (x == e->kept[k])
            return KEPT_REG(k);
    if (!(x & OPERAND_CONST))
        return slot_kind(e, x);
    return is_ptr(*operand_cell(e, x)) ? SLJIT_MEM0() : SLJIT_IMM;
}

static sljit_sw operand_offset(const Emit *e, uint32_t x)
{
    if (x == e->cached || x == e->kept[0] || x == e->kept[1])
        return 0;
    if (!(x & OPERAND_CONST))
        return slot_offset(e, x);
    V *cell = operand_cell(e, x);
    return is_ptr(*cell) ? (sljit_sw)cell : (sljit_sw)*cell;
}

#define OPND(e, x) operand_kind(e, x), operand_offset(e, x)

static sljit_sw word_offset(const Emit *e, uint32_t x)
{
    if (!(x & OPERAND_CONST))
        return raw_offset(e, x);
    V k = *operand_cell(e, x);
    return is_fix(k) ? (sljit_sw)fixval(k) : 0;
}

/* The register that holds operand x: CACHE or a home register when it is in
   one, else R0, loaded. For reads only, since CACHE and homes must not
   change. */
static sljit_s32 operand_reg(Emit *e, uint32_t x)
{
    sljit_s32 k = operand_kind(e, x);
    if (k >= SLJIT_R0 && k <= SLJIT_S0)
        return k;
    sljit_emit_op1(e->c, SLJIT_MOV, SLJIT_R0, 0, k, operand_offset(e, x));
    return SLJIT_R0;
}

/* = with a constant symbol, special or procedure is identity. */
static bool identity_operand(const Emit *e, uint32_t x)
{
    if (!(x & OPERAND_CONST))
        return false;
    unsigned t = tag3(*operand_cell(e, x));
    return t == TAG_SYMBOL || t == TAG_SPECIAL || t == TAG_PROC;
}

/* A fixnum constant: a value not identical to it equals it only if it is an
   object, which may be an equal real. */
static bool fixnum_operand(const Emit *e, uint32_t x)
{
    return (x & OPERAND_CONST) && (tag3(*operand_cell(e, x)) & 3) == 0;
}

/* The label of the innermost handler of this code, when it ignores the
   exception, or NONE. A primitive whose fast path fails only where C would
   raise can then pop that handler and jump to it, as the unwinder would,
   without making an exception. */
static uint32_t quiet_catch(const Emit *e)
{
    return e->nhandlers ? e->handlers[e->nhandlers - 1] : NONE;
}

/* A quiet handler that is never pushed (virtual_handler) is marked by this
   bit in e->handlers and catch_label: its errors jump to it, and there is
   nothing to pop. */
#define VIRTUAL 0x80000000u

static void jump_to_catch(Emit *e, uint32_t label)
{
    if (!(label & VIRTUAL))
        sljit_emit_op2(e->c, SLJIT_SUB, VMF(nhandlers), VMF(nhandlers), IMM(1));
    e->fixups[e->nfixups].jump = sljit_emit_jump(e->c, SLJIT_JUMP);
    e->fixups[e->nfixups++].label = label & ~VIRTUAL;
}

/* Whether the quiet handler pushed at words[i] can stay off the handler
   stack: up to its pop-handler there are only moves, constants, jumps
   within, and primitives that either never raise or, under a quiet handler
   of this code, raise by jumping to it. Nothing there can then reach the
   handler but those jumps, and nothing reads the handler stack. */
static bool virtual_handler(const uint32_t *w, size_t i, size_t n, const size_t *label_pos)
{
    size_t far = 0;
    for (i += insn_length(w + i); i < n; i += insn_length(w + i)) {
        const uint32_t *p = w + i;
        switch (p[0]) {
        case OP_POP_HANDLER:
            return far < i;
        case OP_JUMP:
            far = label_pos[p[1]] > far ? label_pos[p[1]] : far;
            break;
        case OP_JUMP_IF_FALSE:
            far = label_pos[p[2]] > far ? label_pos[p[2]] : far;
            break;
        case OP_MOVE: case OP_CONST: case OP_CAPTURE: case OP_LABEL:
            break;
        case OP_PRIM:
            switch (p[2]) {
            case P_HD: case P_TL: case P_GET_ADDRESS: case P_SET_ADDRESS: case P_VALUE:
            case P_SET: case P_SIMPLE_ERROR: case P_EQ: case P_CONSP: case P_SYMBOLP:
            case P_ABSVECTORP: case P_STRINGP: case P_NUMBERP: case P_TAGGEDP: case P_VECTORP:
            case P_PVAR: case P_PVARP: case P_PVAR_OFFSET: case P_SAMEP:
                break;
            default:
                return false;
            }
            break;
        default:
            return false;
        }
    }
    return false;
}

/* The bodies inlined at this point, interned once per stack. */
static uint32_t inline_chain(Emit *e)
{
    if (!e->ninl || e->chain)
        return e->ninl ? e->chain : 0;
    Jit *jit = e->vm->jit;
    if (jit->nchains + 1 + e->ninl > jit->chains_cap) {
        size_t cap = jit->chains_cap ? 2 * jit->chains_cap : 256;
        size_t *chains = realloc(jit->chains, cap * sizeof *chains);
        if (!chains)
            return 0; /* backtraces then leave these bodies out */
        jit->chains = chains;
        jit->chains_cap = cap;
    }
    jit->chains[jit->nchains] = e->ninl;
    for (uint32_t k = 0; k < e->ninl; k++)
        jit->chains[jit->nchains + 1 + k] = e->inl_cell[e->ninl - 1 - k];
    e->chain = (uint32_t)jit->nchains + 1;
    jit->nchains += 1 + e->ninl;
    return e->chain;
}

static Slow *slow_path(Emit *e, SlowKind kind, struct sljit_jump *from)
{
    Slow *s = &e->slow[e->nslow++];
    *s = (Slow){kind, {from}, NULL, NULL, 0, UINT32_MAX, NONE, NONE, NULL, inline_chain(e), NULL, NULL, false, 0, 0, {NONE, NONE}};
    return s;
}

static bool reads_slot(const uint32_t *p, uint32_t s);
static bool writes_slot(const uint32_t *p, uint32_t s);
/* SHEN_JIT_SLOW_PRIMS sends every primitive to C, so that make test-differential can compare
   what the JIT inlines with sj_primitive. */
static bool slow_prims;

static bool fusable(uint32_t prim);

/* A tail call to the running code reuses the frame as it is, so it can skip
   the entry checks: SEALED_SELF when sealed and bound, OPEN_SELF to the name
   of code that is its current definition, which loops until the name is
   redefined. A sealed call is still unbound when it calls the definition
   being compiled, which is only installed afterwards. */
enum { OTHER_CALLEE, SEALED_SELF, OPEN_SELF };

static int self_tail_call(const Emit *e, const uint32_t *p)
{
    uint32_t op = p[0], n = op == OP_TAIL_CALL_VALUE ? p[2] : p[3];
    if (n != e->arity || op == OP_TAIL_CALL_VALUE)
        return OTHER_CALLEE;
    V self = op == OP_TAIL_CALL_SEALED ? *ra_at(&e->vm->consts, p[2]) : V_NIL;
    if (is_proc(self) && hdr_type(ptr(self)[0]) == T_CLOSURE && ptr(self)[CLO_CODE] == e->code)
        return SEALED_SELF;
    if (op == OP_TAIL_CALL_SEALED && self == ptr(e->code)[CODE_NAME])
        return SEALED_SELF; /* this definition, not installed yet when compiled */
    if (op == OP_TAIL_CALL && p[2] == symbol_cell(ptr(e->code)[CODE_NAME])) {
        /* Its name's definition, unless redefined before its first call. */
        V f = *cell_function(e->vm, p[2]);
        if (is_proc(f) && hdr_type(ptr(f)[0]) == T_CLOSURE && ptr(f)[CLO_CODE] == e->code)
            return OPEN_SELF;
    }
    return OTHER_CALLEE;
}

/* Whether slot s only ever holds the result of a test fused with the jump
   on it: every write to it is a fusable primitive that does not read it,
   followed by a jump-if-false on it, and nothing else reads it. Such a
   result is never stored. */
static bool fused_only(const uint32_t *words, size_t nwords, uint32_t s)
{
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i, *next = p + insn_length(p);
        if (p[0] == OP_PRIM && p[1] == s && fusable(p[2]) && !reads_slot(p, s) &&
            i + insn_length(p) < nwords && next[0] == OP_JUMP_IF_FALSE && next[1] == s) {
            i += insn_length(p); /* the loop then steps over the jump */
            continue;
        }
        if (reads_slot(p, s) || writes_slot(p, s))
            return false;
    }
    return true;
}

/* Loop arguments in registers:
   code that loops through a self tail call and makes no other call but tail
   calls, with no handlers, keeps slots 2 and up in registers when they fit.
   The top slots that only hold fused tests' results do not count: they stay
   in the frame, where nothing touches them. Returns how many, or 0. */
static uint32_t home_count(const Emit *e, const uint32_t *words, size_t nwords)
{
    if (e->frame < 3)
        return 0;
    bool loop = false;
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i;
        switch (p[0]) {
        case OP_CALL: case OP_CALL_SEALED: case OP_CALL_VALUE: case OP_TAIL_CALL_VALUE:
        case OP_PUSH_HANDLER: case OP_POP_HANDLER: case OP_EXCEPTION:
            return 0;
        case OP_TAIL_CALL: case OP_TAIL_CALL_SEALED:
            loop = loop || self_tail_call(e, p) != OTHER_CALLEE;
            break;
        case OP_LOOP:
            loop = true;
            break;
        default:
            break;
        }
    }
    uint32_t top = (uint32_t)e->frame;
    while (loop && top > 2 + HOMES && fused_only(words, nwords, top - 1))
        top--;
    return loop && top > 2 && top - 2 <= HOMES ? top - 2 : 0;
}

/* How many registers of each kind the code uses: one more than the highest. */
static void count_registers(Emit *e, const uint32_t *words, size_t nwords)
{
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i;
        const char *kinds = raw_kinds(p[0]);
        for (size_t k = 0; kinds && kinds[k]; k++) {
            uint32_t x = p[1 + k];
            if (kinds[k] == 'r' && x + 1 > e->reals)
                e->reals = x + 1;
            else if ((kinds[k] == 'w' || kinds[k] == 'W') && !(x & OPERAND_CONST) && x + 1 > e->word_regs)
                e->word_regs = x + 1;
        }
    }
}

/* The memory operand of an access with an index, or NONE. */
static uint32_t memory_operand(const uint32_t *p)
{
    switch (p[0]) {
    case OP_PRIM:
        switch (p[2]) {
        case P_U8: case P_U16: case P_U32: case P_S32: case P_F64:
        case P_SET_U8: case P_SET_U16: case P_SET_U32: case P_SET_F64:
            return p[4];
        default:
            return NONE;
        }
    case OP_REAL_LOAD: case OP_REAL_STORE: return p[4];
    case OP_REAL_LOAD_AT: case OP_WORD_LOAD8: case OP_WORD_LOAD16: case OP_WORD_LOAD32: case OP_WORD_LOAD_S32:
    case OP_WORD_LOAD64:
        return p[2];
    case OP_REAL_STORE_AT: case OP_WORD_STORE8: case OP_WORD_STORE16: case OP_WORD_STORE32: case OP_WORD_STORE64:
        return p[1];
    default:
        return NONE;
    }
}

static bool store_prim(uint32_t prim)
{
    return prim == P_SET_U8 || prim == P_SET_U16 || prim == P_SET_U32 || prim == P_SET_F64;
}

/* Whether an access with an index writes. */
static bool store_access(const uint32_t *p)
{
    switch (p[0]) {
    case OP_PRIM: return store_prim(p[2]);
    case OP_REAL_STORE: case OP_REAL_STORE_AT:
    case OP_WORD_STORE8: case OP_WORD_STORE16: case OP_WORD_STORE32: case OP_WORD_STORE64:
        return true;
    default:
        return false;
    }
}

/* The log2 of how many bytes an access at a word index takes; -1 for one at a slot's index. */
static int word_access_size(uint32_t op)
{
    switch (op) {
    case OP_WORD_LOAD8: case OP_WORD_STORE8: return 0;
    case OP_WORD_LOAD16: case OP_WORD_STORE16: return 1;
    case OP_WORD_LOAD32: case OP_WORD_LOAD_S32: case OP_WORD_STORE32: return 2;
    case OP_WORD_LOAD64: case OP_WORD_STORE64: case OP_REAL_LOAD_AT: case OP_REAL_STORE_AT: return 3;
    default: return -1;
    }
}

/* Memory in a loop: a parameter that a loop calling nothing never changes, and reads or stores
   through, has its base and lengths worked out once, on the way in. They hold until C runs, as
   only C can collect or kill a pointer, and fill works them out again after that. Anything else
   gets length 0, so that its first access takes the slow path, which says what is wrong; and a
   read-only pointer gets 0 for stores. */
static void choose_cached_memory(Emit *e, const uint32_t *words, size_t nwords)
{
    bool loop = false;
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i;
        switch (p[0]) {
        case OP_CALL: case OP_CALL_SEALED: case OP_CALL_VALUE: case OP_TAIL_CALL_VALUE: case OP_PUSH_HANDLER:
        case OP_ENTRY:
            return;
        case OP_TAIL_CALL: case OP_TAIL_CALL_SEALED:
            if (self_tail_call(e, p) != OTHER_CALLEE) {
                if (p[1] != 0) /* its arguments are copied, and could be anything */
                    return;
                loop = true;
            }
            break;
        case OP_LOOP:
            loop = true;
            break;
        default:
            break;
        }
    }
    for (size_t i = 0; loop && i < nwords && e->nmemory < CACHED_MEMORY; i += insn_length(words + i)) {
        uint32_t m = memory_operand(words + i);
        bool usable = m != NONE && !(m & OPERAND_CONST) && m >= 2 && m < e->arity + 2;
        for (uint32_t k = 0; usable && k < e->nmemory; k++)
            usable = e->memory[k] != m;
        for (size_t j = 0; usable && j < nwords; j += insn_length(words + j))
            usable = !writes_slot(words + j, m);
        if (usable)
            e->memory[e->nmemory++] = m;
    }
}

/* What a length becomes when one width reaches the memory: an index below it has room for that
   width, so that one comparison is the whole check, and 0 if nothing has. */
static void emit_limit(struct sljit_compiler *c, sljit_s32 length, sljit_sw width)
{
    struct sljit_jump *small = sljit_emit_cmp(c, SLJIT_LESS, length, 0, IMM(width));
    sljit_emit_op2(c, SLJIT_SUB, length, 0, length, 0, IMM(width - 1));
    struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(small, sljit_emit_label(c));
    sljit_emit_op1(c, SLJIT_MOV, length, 0, IMM(0));
    sljit_set_label(done, sljit_emit_label(c));
}

/* Uses R1 to R4, as R0 may hold what C returned. */
static void emit_memory_caches(Emit *e)
{
    struct sljit_compiler *c = e->c;
    for (uint32_t k = 0; k < e->nmemory; k++) {
        uint32_t at = WORD_REGISTERS + 3 * k;
        sljit_emit_op1(c, SLJIT_MOV, R1, HOME(e, e->memory[k]));
        struct sljit_jump *object = tag_cmp(c, SLJIT_EQUAL, R2, R1, TAG_OBJECT);
        struct sljit_jump *none[1];
        sljit_emit_op1(c, SLJIT_MOV, R1, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R3, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R4, IMM(0));
        none[0] = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(object, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R1), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
        struct sljit_jump *bytes = sljit_emit_cmp(c, SLJIT_EQUAL, R3, IMM(T_BYTES << 3 | TAG_HEADER));
        struct sljit_jump *pointer = sljit_emit_cmp(c, SLJIT_EQUAL, R3, IMM(T_POINTER << 3 | TAG_HEADER));
        sljit_emit_op1(c, SLJIT_MOV, R1, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R3, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R4, IMM(0));
        struct sljit_jump *other = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(pointer, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM1(SLJIT_R1), POINTER_LENGTH * WORD - TAG_OBJECT);
        sljit_emit_op1(c, SLJIT_MOV, R4, R3);
        struct sljit_jump *writable = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(T_POINTER << 3 | TAG_HEADER));
        sljit_emit_op1(c, SLJIT_MOV, R4, IMM(0));
        sljit_set_label(writable, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R1), POINTER_ADDRESS * WORD - TAG_OBJECT);
        struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(bytes, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_LSHR, R3, R2, IMM(8));
        sljit_emit_op1(c, SLJIT_MOV, R4, R3);
        sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(WORD - TAG_OBJECT));
        struct sljit_label *store = sljit_emit_label(c);
        sljit_set_label(done, store);
        sljit_set_label(other, store);
        sljit_set_label(none[0], store);
        if (e->limit_size[k] > 0) {
            emit_limit(c, SLJIT_R3, (sljit_sw)1 << e->limit_size[k]);
            emit_limit(c, SLJIT_R4, (sljit_sw)1 << e->limit_size[k]);
        }
        sljit_emit_op1(c, SLJIT_MOV, RAW(e, at), R1);
        sljit_emit_op1(c, SLJIT_MOV, RAW(e, at + 1), R3);
        sljit_emit_op1(c, SLJIT_MOV, RAW(e, at + 2), R4);
    }
}

/* Whether the code has a loop instruction. */
static bool raw_loop(const uint32_t *words, size_t nwords)
{
    for (size_t i = 0; i < nwords; i += insn_length(words + i))
        if (words[i] == OP_LOOP)
            return true;
    return false;
}

/* Numbers each of n things by use, most used first, in the order they come among equals. */
static void places_by_use(const uint64_t *use, uint8_t *place, uint32_t n)
{
    uint8_t order[REAL_REGISTERS + RAW_INTEGERS];
    for (uint32_t k = 0; k < n; k++) {
        uint32_t at = k;
        for (; at > 0 && use[order[at - 1]] < use[k]; at--)
            order[at] = order[at - 1];
        order[at] = (uint8_t)k;
    }
    for (uint32_t k = 0; k < n; k++)
        place[order[k]] = (uint8_t)k;
}

/* The words a loop reads before it writes them, and writes: what it carries from one iteration to
   the next, a bit for each. */
static uint32_t carried_words(const uint32_t *words, size_t head, size_t end)
{
    uint32_t read = 0, written = 0;
    for (size_t j = head; j <= end; j += insn_length(words + j)) {
        const char *kinds = raw_kinds(words[j]);
        for (size_t k = 0; kinds && kinds[k]; k++)
            if (kinds[k] == 'W' && !(words[j + 1 + k] & OPERAND_CONST))
                read |= ~written & UINT32_C(1) << words[j + 1 + k];
        for (size_t k = 0; kinds && kinds[k]; k++)
            if (kinds[k] == 'w')
                written |= UINT32_C(1) << words[j + 1 + k];
    }
    return read & written;
}

/* Machine registers go to what is used most, each loop counting 8 times what is around it, base
   and limits of kept memory competing with word registers. Where registers are many, the last ones
   decide between those and a word: the base and limits never change in a loop, so a load of one
   from the native frame waits on nothing, while a word the loop writes puts a store and a load in
   the way of the next iteration. So a word counts twice what they do, and a word a loop carries
   counts as used once more in a loop inside it. A loop runs from its head to its last jump back.
   Code that loops and has more than fits takes the saved registers too, which slots would otherwise
   have: its work is in these, and they need no saving around C. */
static void assign_places(Emit *e, const uint32_t *words, size_t nwords)
{
    if (!e->reals && !e->word_regs && !e->nmemory)
        return;
    uint64_t real_use[REAL_REGISTERS] = {0}, raw_use[RAW_INTEGERS] = {0};
    size_t ends[8];
    uint32_t depth = 0;
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i;
        while (depth && i > ends[depth - 1])
            depth--;
        if (p[0] == OP_LOOP && depth < sizeof ends / sizeof *ends) {
            ends[depth] = i;
            for (size_t j = i; j < nwords; j += insn_length(words + j))
                if (words[j] == OP_AGAIN && words[j + 1] == p[1])
                    ends[depth] = j;
            uint32_t carried = MANY_GPRS ? carried_words(words, i, ends[depth]) : 0;
            depth++;
            for (uint32_t x = 0; x < WORD_REGISTERS; x++)
                if (carried >> x & 1)
                    raw_use[x] += 2 * (UINT64_C(1) << (3 * depth + 3));
        }
        uint64_t use = UINT64_C(1) << (3 * depth);
        const char *kinds = raw_kinds(p[0]);
        for (size_t k = 0; kinds && kinds[k]; k++) {
            uint32_t x = p[1 + k];
            if (kinds[k] == 'r')
                real_use[x] += use;
            else if ((kinds[k] == 'w' || kinds[k] == 'W') && !(x & OPERAND_CONST))
                raw_use[x] += MANY_GPRS ? 2 * use : use;
        }
        uint32_t memory = memory_operand(p);
        for (uint32_t k = 0; k < e->nmemory; k++)
            if (e->memory[k] == memory) {
                uint32_t at = WORD_REGISTERS + 3 * k;
                int size = word_access_size(p[0]);
                e->limit_size[k] = !raw_use[at] || e->limit_size[k] == size ? (int8_t)size : -1;
                raw_use[at] += use;
                raw_use[at + (store_access(p) ? 2 : 1)] += use;
            }
    }
    places_by_use(real_use, e->real_place, REAL_REGISTERS);
    places_by_use(raw_use, e->raw_place, RAW_INTEGERS);
    sljit_s32 used = 0;
    for (uint32_t k = 0; k < RAW_INTEGERS; k++)
        used += raw_use[k] != 0;
    if (used > WORD_GPRS && raw_loop(words, nwords)) {
        e->homes = 0;
        e->raw_saved = SAVED_HOMES;
    } else if (used && e->homes > SAVED_HOMES) {
        e->homes = 0; /* R5 and up are taken */
    }
}

/* Whether the code loops to its own body, which is then a loop head. */
static bool loops(const Emit *e, const uint32_t *words, size_t nwords)
{
    for (size_t i = 0; i < nwords; i += insn_length(words + i))
        if ((words[i] == OP_TAIL_CALL || words[i] == OP_TAIL_CALL_SEALED) &&
            self_tail_call(e, words + i) != OTHER_CALLEE)
            return true;
    return false;
}

/* Calls pass their first argument in CACHE as well as in its slot, so that
   the callee does not read back what was just stored: the slot it is read
   from, or NONE. A loop into a body that does not expect it reads none. */
static uint32_t first_argument(const Emit *e, const uint32_t *q)
{
    switch (q[0]) {
    case OP_CALL: case OP_CALL_SEALED: return q[4] ? q[2] + 2 : NONE;
    case OP_CALL_VALUE: return q[3] ? q[2] + 2 : NONE;
    case OP_TAIL_CALL: case OP_TAIL_CALL_SEALED: case OP_TAIL_CALL_VALUE: {
        uint32_t n = q[0] == OP_TAIL_CALL_VALUE ? q[2] : q[3];
        bool loop = self_tail_call(e, q) != OTHER_CALLEE && e->entry != 2;
        return n && !loop ? q[1] + 2 : NONE;
    }
    default: return NONE;
    }
}

/* Whether an instruction soon reads slot s as an operand, before anything
   that would drop CACHE or write s: only then is s worth keeping. With
   past_branches, the look goes on along the fall-through of a branch; it
   always goes past an inlined open callee's guard, taken only once the
   callee is redefined. */
static bool read_soon(const Emit *e, uint32_t s, bool past_branches)
{
    if (e->homes)
        return false;
    size_t j = e->next;
    uint32_t guard = NONE;
    for (int k = 0; k < 4 && j < e->nwords; k++, j += insn_length(e->words + j)) {
        const uint32_t *q = e->words + j;
        bool operand = q[0] == OP_MOVE || q[0] == OP_PRIM || q[0] == OP_JUMP_IF_FALSE ||
                       q[0] == OP_RETURN;
        if ((operand && reads_slot(q, s)) || first_argument(e, q) == s)
            return true;
        bool guarded = q[0] == OP_JUMP_IF_FALSE && q[1] == guard;
        guard = q[0] == OP_PRIM && q[2] == P_INLINEDP ? q[1] : NONE;
        if (writes_slot(q, s) ||
            !((q[0] == OP_JUMP_IF_FALSE && (past_branches || guarded)) || q[0] == OP_POP_HANDLER ||
              q[0] == OP_MOVE || q[0] == OP_CONST || (q[0] == OP_PRIM && fusable(q[2]))))
            return false;
    }
    return false;
}

/* Whether slot s is read as an operand a little further on, along the fall-through of branches,
   before anything that would drop the kept registers or write s. */
static bool read_later(const Emit *e, uint32_t s)
{
    size_t j = e->next;
    for (int k = 0; k < 8 && j < e->nwords; k++) {
        const uint32_t *q = e->words + j;
        bool operand = q[0] == OP_MOVE || q[0] == OP_PRIM || q[0] == OP_JUMP_IF_FALSE || q[0] == OP_RETURN;
        if (operand && reads_slot(q, s))
            return true;
        if (writes_slot(q, s) || !(q[0] == OP_MOVE || q[0] == OP_CONST || q[0] == OP_PRIM || q[0] == OP_JUMP_IF_FALSE ||
                                   q[0] == OP_POP_HANDLER || q[0] == OP_INLINE))
            return false;
        j += insn_length(q);
    }
    return false;
}

/* A kept register to hold slot s after this instruction, or -1: a free one, or one whose slot is not
   read again soon. */
static int kept_for(const Emit *e, uint32_t s)
{
    if (!e->keeps || !read_later(e, s))
        return -1;
    int free = -1;
    for (int k = 0; k < KEPT; k++) {
        if (e->kept_post[k] == s)
            return k;
        if (free < 0 && (e->kept_post[k] == NONE || !read_later(e, e->kept_post[k])))
            free = k;
    }
    return free;
}

static bool dead_after(Emit *e, size_t after, uint32_t target, uint32_t s);
static bool type_test(uint32_t prim);
static bool identity_operand(const Emit *e, uint32_t x);
static bool string_operand(const Emit *e, uint32_t x);

/* = with this operand is a test without a slow path. */
static bool inline_eq_operand(const Emit *e, uint32_t x)
{
    return identity_operand(e, x) || string_operand(e, x);
}

/* Whether the store of a result to slot dst can be skipped, the result
   staying in CACHE. The next instruction tests dst, fused with its branch:
   a type test, or = with a constant that compares by identity or is a short
   string. After cons?, the instruction after may also take hd or tl of dst,
   which the test showed is a pair. None of these has a slow path, so
   nothing reads the slot or collects while only CACHE holds the value; and
   dst must be dead after them and where the test jumps. That is the shape
   of factorised pattern matching. */
static bool dead_store(Emit *e, uint32_t dst)
{
    const uint32_t *w = e->words;
    size_t n = e->nwords, i = e->next;
    if (slow_prims || slot_kind(e, dst) != SLJIT_MEM1(FP) || i >= n)
        return false;
    const uint32_t *test = w + i, *branch = test + insn_length(test);
    if (test[0] != OP_PRIM || (size_t)(branch - w) >= n || branch[0] != OP_JUMP_IF_FALSE ||
        branch[1] != test[1])
        return false;
    bool by_type = type_test(test[2]) && test[4] == dst && (test[3] == 1 || test[5] != dst);
    bool by_identity = test[2] == P_EQ && ((test[4] == dst && inline_eq_operand(e, test[5])) ||
                                           (test[5] == dst && inline_eq_operand(e, test[4])));
    size_t after = (size_t)(branch - w) + insn_length(branch);
    if (!(by_type || by_identity) || after >= n ||
        !dead_after(e, after, branch[2], test[1]))
        return false;
    const uint32_t *take = w + after;
    if (test[2] == P_CONSP && take[0] == OP_PRIM && (take[2] == P_HD || take[2] == P_TL) && take[4] == dst)
        after += insn_length(take);
    return dead_after(e, after, branch[2], dst);
}

/* Whether the next instruction is the only one to read slot dst, from
   CACHE, with nothing between that could collect or read the frame: a
   return of it, or the next cons of a run, which has room already, when
   that cons overwrites dst or dst is dead after it. */
static bool consumed_next(Emit *e, uint32_t dst)
{
    const uint32_t *w = e->words, *q = w + e->next;
    if (slot_kind(e, dst) != SLJIT_MEM1(FP) || e->next >= e->nwords)
        return false;
    if (q[0] == OP_RETURN)
        return q[1] == dst;
    return q[0] == OP_PRIM && q[2] == P_CONS && e->reserved && (q[4] == dst || q[5] == dst) &&
           (q[1] == dst || dead_after(e, e->next + insn_length(q), NONE, dst));
}

/* Whether a result for slot dst can go straight to its register: a loop
   that keeps its slots in registers keeps nothing in CACHE. */
static bool to_home(const Emit *e, uint32_t dst)
{
    return e->homes && slot_kind(e, dst) != SLJIT_MEM1(FP);
}

/* Put what k, w holds in slot dst, and keep it in CACHE if it is read soon. A load goes straight
   to CACHE, unless CACHE is its base: over list patterns, that load takes an M3 about 15% longer
   than one to another register and a move. */
static void put_result(Emit *e, uint32_t dst, sljit_s32 k, sljit_sw w)
{
    if (!read_soon(e, dst, true)) {
        int to = kept_for(e, dst);
        if (to < 0) {
            sljit_emit_op1(e->c, SLJIT_MOV, HOME(e, dst), k, w);
            return;
        }
        sljit_emit_op1(e->c, SLJIT_MOV, KEPT_REG(to), 0, k, w);
        sljit_emit_op1(e->c, SLJIT_MOV, HOME(e, dst), KEPT_REG(to), 0);
        e->kept_post[to] = dst;
        return;
    }
    /* CACHE is about to change: what it holds moves to a kept register if it is read again. */
    if (e->cached != NONE && e->cached != dst) {
        int to = kept_for(e, e->cached);
        if (to >= 0 && e->kept_post[to] != e->cached) {
            if (k == KEPT_REG(to) || k == SLJIT_MEM1(KEPT_REG(to))) { /* what this reads, before that goes */
                sljit_emit_op1(e->c, SLJIT_MOV, R0, k, w);
                k = SLJIT_R0;
                w = 0;
            }
            sljit_emit_op1(e->c, SLJIT_MOV, KEPT_REG(to), 0, CACHE);
            e->kept_post[to] = e->cached;
        }
    }
    if (k == SLJIT_MEM1(SLJIT_S2)) {
        sljit_emit_op1(e->c, SLJIT_MOV, R0, k, w);
        k = SLJIT_R0;
        w = 0;
    }
    if (k != SLJIT_S2)
        sljit_emit_op1(e->c, SLJIT_MOV, CACHE, k, w);
    if (!(dead_store(e, dst) || consumed_next(e, dst)))
        sljit_emit_op1(e->c, SLJIT_MOV, HOME(e, dst), CACHE);
    e->post = dst;
}

/* The same for R0, the result. */
static void store_result(Emit *e, uint32_t dst)
{
    put_result(e, dst, R0);
}

/* Instructions that write at most one slot and call no guest code: CACHE
   still holds its slot after them, unless they write it. */
static bool keeps_cache(const uint32_t *p)
{
    switch (p[0]) {
    case OP_MOVE: case OP_CONST: case OP_CAPTURE: case OP_CLOSURE: case OP_PRIM:
    case OP_JUMP_IF_FALSE: case OP_POP_HANDLER: case OP_EXCEPTION:
    case OP_ENTRY: case OP_JUMP_UNLESS_ENTRY: case OP_INLINE:
        return true;
    default:
        return false;
    }
}

/* A loop that keeps its slots in registers stores them to the frame before
   C may collect or raise, and loads them again after a collection, which
   may have moved what they point to. The frame words always hold valid
   values: those from entry or from the last store. */
static void spill(Emit *e)
{
    for (uint32_t k = 0; k < e->homes; k++)
        sljit_emit_op1(e->c, SLJIT_MOV, SLOT(2 + k), HOME_REG((sljit_s32)k), 0);
}

/* C keeps few float registers, so all of them wait in the frame, and it keeps no scratch integer
   register, memory kept for a loop among them. */
static void save_raw(Emit *e)
{
    for (uint32_t k = 0; k < e->reals; k++)
        if (e->real_place[k] < REAL_FLOATS)
            sljit_emit_fop1(e->c, SLJIT_MOV_F64, REAL_SAVED(e->real_place[k]), REAL(e, k));
    for (uint32_t k = 0; k < WORD_REGISTERS + 3 * e->nmemory; k++)
        if ((k < e->word_regs || k >= WORD_REGISTERS) && raw_scratch(e->raw_place[k]))
            sljit_emit_op1(e->c, SLJIT_MOV, RAW_SAVED(e->raw_place[k]), RAW(e, k));
}

static void load_raw(Emit *e)
{
    for (uint32_t k = 0; k < e->reals; k++)
        if (e->real_place[k] < REAL_FLOATS)
            sljit_emit_fop1(e->c, SLJIT_MOV_F64, REAL(e, k), REAL_SAVED(e->real_place[k]));
    for (uint32_t k = 0; k < WORD_REGISTERS + 3 * e->nmemory; k++)
        if ((k < e->word_regs || k >= WORD_REGISTERS) && raw_scratch(e->raw_place[k]))
            sljit_emit_op1(e->c, SLJIT_MOV, RAW(e, k), RAW_SAVED(e->raw_place[k]));
}

static void emit_memory_caches(Emit *e);

/* R0 may hold what C returned. */
static void fill(Emit *e)
{
    for (uint32_t k = 0; k < e->homes; k++)
        sljit_emit_op1(e->c, SLJIT_MOV, HOME_REG((sljit_s32)k), 0, SLOT(2 + k));
    load_raw(e);
    emit_memory_caches(e);
}

/* At entry only the arguments are loaded; the other slots are written
   before they are read, and start as [] so that a store before a
   collection writes a valid value. In a test harness, loading them too,
   after one 128-bit store had written both, made reverse's loop twice as
   slow on Apple silicon. */
static void enter(Emit *e)
{
    for (uint32_t k = 0; k < e->homes; k++)
        if (2 + k < e->arity + 2)
            sljit_emit_op1(e->c, SLJIT_MOV, HOME_REG((sljit_s32)k), 0, SLOT(2 + k));
        else
            sljit_emit_op1(e->c, SLJIT_MOV, HOME_REG((sljit_s32)k), 0, IMM(V_NIL));
}

/* Publish the frame pointer and the scanned top before a call into C that
   may collect, grow the stack or raise. */
static void publish(Emit *e)
{
    struct sljit_compiler *c = e->c;
    spill(e);
    save_raw(e);
    sljit_emit_op1(c, SLJIT_MOV, VMF(fp), FP, 0);
    sljit_emit_op2(c, SLJIT_ADD, R3, FP, 0, IMM(e->frame * sizeof(V)));
    sljit_emit_op1(c, SLJIT_MOV, VMF(top), R3);
}

static void call_c(struct sljit_compiler *c, sljit_s32 arg_types, void *fn)
{
    sljit_emit_op1(c, SLJIT_MOV, VMF(hp), HP);
    sljit_emit_icall(c, SLJIT_CALL, arg_types, SLJIT_IMM, SLJIT_FUNC_ADDR(fn));
    sljit_emit_op1(c, SLJIT_MOV, HP, VMF(hp));
}

/* call_c from a slow path to a helper that may raise: inside an inlined
   body, the call's return address goes to vm->site for the call, and in
   the site table with that body's names, for backtraces. */
static void call_c_raising(Emit *e, const Slow *s, sljit_s32 arg_types, void *fn)
{
    struct sljit_compiler *c = e->c;
    struct sljit_jump *site = s->chain ? sljit_emit_op_addr(c, SLJIT_MOV_ADDR, VMF(site)) : NULL;
    sljit_emit_op1(c, SLJIT_MOV, VMF(hp), HP);
    sljit_emit_icall(c, SLJIT_CALL, arg_types, SLJIT_IMM, SLJIT_FUNC_ADDR(fn));
    if (site) {
        struct sljit_label *ret = sljit_emit_label(c);
        sljit_set_label(site, ret);
        e->raises[e->nraises].ret = ret;
        e->raises[e->nraises++].chain = s->chain;
        sljit_emit_op1(c, SLJIT_MOV, VMF(site), IMM(0));
    }
    sljit_emit_op1(c, SLJIT_MOV, HP, VMF(hp));
}

/* A call to C that neither allocates nor collects: the heap pointer stays in
   its register, which C preserves, rather than going through memory, where
   a loop that calls would wait on it. */
static void call_leaf(Emit *e, sljit_s32 arg_types, void *fn)
{
    for (sljit_s32 k = SAVED_HOMES; k < (sljit_s32)e->homes; k++)
        sljit_emit_op1(e->c, SLJIT_MOV, SLOT(2 + k), HOME_REG(k), 0);
    save_raw(e);
    sljit_emit_icall(e->c, SLJIT_CALL, arg_types, SLJIT_IMM, SLJIT_FUNC_ADDR(fn));
    /* C keeps no scratch register, whether or not this call happened to touch them. */
    if (e->vm->stress)
        for (sljit_s32 k = SAVED_HOMES; k < HOMES; k++)
            sljit_emit_op1(e->c, SLJIT_MOV, HOME_REG(k), 0, IMM(UINT64_C(0xDEADDEADDEADDEAD)));
    load_raw(e);
    for (sljit_s32 k = SAVED_HOMES; k < (sljit_s32)e->homes; k++)
        sljit_emit_op1(e->c, SLJIT_MOV, HOME_REG(k), 0, SLOT(2 + k));
}

static void check_raise(Emit *e)
{
    to_unwind(e, sljit_emit_cmp(e->c, SLJIT_EQUAL, R0, IMM(V_CLEARED)));
}

static void store_boolean_from_flags(Emit *e, sljit_s32 type, uint32_t dst)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op_flags(c, SLJIT_MOV, R0, type);
    sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(3));
    sljit_emit_op2(c, SLJIT_ADD, HOME(e, dst), R0, IMM(V_FALSE));
}

/* Raises unless R1 is a procedure; target is the cell of a named call. */
static void check_proc(Emit *e, uint32_t target)
{
    Slow *s = slow_path(e, SLOW_NOT_PROC, tag_cmp(e->c, SLJIT_NOT_EQUAL, R0, R1, TAG_PROC));
    s->words = target;
}

/* Loads the callee for a named call into R1, checking that it is a procedure
   unless the call is sealed. */
static void load_callee(Emit *e, uint32_t op, uint32_t target, uint32_t window)
{
    struct sljit_compiler *c = e->c;
    if (op == OP_CALL || op == OP_TAIL_CALL)
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)cell_function(e->vm, target));
    else if (op == OP_CALL_SEALED || op == OP_TAIL_CALL_SEALED) {
        V *slot = ra_at(&e->vm->consts, target);
        if (is_symbol(*slot) && is_proc(*cell_function(e->vm, symbol_cell(*slot))))
            *slot = *cell_function(e->vm, symbol_cell(*slot)); /* defined since */
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)slot);
        if (!is_proc(*slot)) {
            Slow *s = slow_path(e, SLOW_RESOLVE, tag_cmp(c, SLJIT_NOT_EQUAL, R0, R1, TAG_PROC));
            s->words = (uint64_t)(uintptr_t)slot;
            s->back = sljit_emit_label(c);
        }
    } else
        sljit_emit_op1(c, SLJIT_MOV, R1, SLOT(window + 1));
    if (op != OP_CALL_SEALED && op != OP_TAIL_CALL_SEALED)
        check_proc(e, target);
}

static void emit_call(Emit *e, const uint32_t *p)
{
    struct sljit_compiler *c = e->c;
    uint32_t op = p[0], dst = p[1], a = p[2];
    uint32_t n = op == OP_CALL_VALUE ? p[3] : p[4];
    load_callee(e, op, p[3], a);
    sljit_emit_op1(c, SLJIT_MOV, SLOT(a + 1), R1);
    struct sljit_jump *ret = sljit_emit_op_addr(c, SLJIT_MOV_ADDR, SLOT(a));
    sljit_emit_op2(c, SLJIT_ADD, FP, 0, FP, 0, IMM(a * sizeof(V)));
    if (n && e->cached != a + 2)
        sljit_emit_op1(c, SLJIT_MOV, CACHE, SLOT(2));
    sljit_emit_op1(c, SLJIT_MOV, R2, IMM(n));
    sljit_emit_ijump(c, SLJIT_JUMP, ENTRY_OF(SLJIT_R1));
    /* Return labels are 4-byte aligned, so they scan as fixnums. */
    struct sljit_label *back = sljit_emit_aligned_label(c, SLJIT_LABEL_ALIGN_4, NULL);
    sljit_set_label(ret, back);
    e->calls[e->ncalls].back = back;
    e->calls[e->ncalls].chain = inline_chain(e);
    e->calls[e->ncalls++].window = a;
    sljit_emit_op2(c, SLJIT_SUB, FP, 0, FP, 0, IMM(a * sizeof(V)));
    e->cached = NONE; /* the callee's now */
    store_result(e, dst);
}

/* A loop back to the body skips the entry checks, so it tests for a pending
   interrupt itself, in code compiled once the REPL catches Ctrl-C or the first
   thread starts: elsewhere SIGINT ends the process, and the test would only
   cost time. Either one has everything compiled again (jit_recompile). */
static void emit_loop_check(Emit *e)
{
    if (!e->vm->interruptible)
        return;
    Slow *s = slow_path(e, SLOW_LOOP, sljit_emit_cmp(e->c, SLJIT_NOT_EQUAL | SLJIT_32, VMF(interrupted), IMM(0)));
    s->back = sljit_emit_label(e->c);
}

static void emit_tail_call(Emit *e, const uint32_t *p)
{
    struct sljit_compiler *c = e->c;
    uint32_t op = p[0], a = p[1];
    uint32_t n = op == OP_TAIL_CALL_VALUE ? p[2] : p[3];
    int self = self_tail_call(e, p);
    bool sealed_self = self == SEALED_SELF, open_self = self == OPEN_SELF;
    if (open_self && !PATCH_SELF) /* tested to be a procedure below, unless it is this one */
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)cell_function(e->vm, p[2]));
    else if (!sealed_self && !open_self)
        load_callee(e, op, p[2], a);
    /* Window 0 means the arguments are already in place. Otherwise the
       window is above slot 1, so ascending copies are safe. The first goes
       through CACHE, where callees expect it; this code's own body may not
       (e->entry), and then a loop does not load it. */
    bool via_cache = n && (!(sealed_self || open_self) || e->entry == 2);
    if (via_cache && e->cached != a + 2)
        sljit_emit_op1(c, SLJIT_MOV, CACHE, HOME(e, a + 2));
    for (uint32_t i = 0; a && i < n; i++) {
        if (i == 0 && via_cache)
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, 2), CACHE);
        else
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, 2 + i), HOME(e, a + 2 + i));
    }
    if (sealed_self) {
        emit_loop_check(e);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), e->body);
        return;
    }
    if (open_self && PATCH_SELF) {
        /* Straight back, until a redefinition of the name patches the jump
           to go on to the code after it, which calls the name's
           procedure. */
        emit_loop_check(e);
        struct sljit_jump *back = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(back, e->body);
        e->selfs[e->nselfs].jump = back;
        e->selfs[e->nselfs++].other = sljit_emit_label(c);
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)cell_function(e->vm, p[2]));
        check_proc(e, p[2]);
    } else if (open_self) {
        /* A branch not taken, then the jump back: with the compare's own
           branch taken back instead, a loop whose = called C ran 1.5
           times as long at most code addresses. */
        struct sljit_jump *other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, SLOT(1));
        emit_loop_check(e);
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), e->body);
        sljit_set_label(other, sljit_emit_label(c));
        check_proc(e, p[2]);
    }
    if (n && !via_cache && (a || e->cached != 2)) /* another callee, after all */
        sljit_emit_op1(c, SLJIT_MOV, CACHE, HOME(e, 2));
    spill(e); /* the callee reads its arguments from the frame */
    sljit_emit_op1(c, SLJIT_MOV, SLOT(1), R1);
    sljit_emit_op1(c, SLJIT_MOV, R2, IMM(n));
    sljit_emit_ijump(c, SLJIT_JUMP, ENTRY_OF(SLJIT_R1));
}

/* For = on two values that are not identical: jumps when the contents must be
   compared in C, and falls through when the values are certainly different.
   Only two pairs, two objects, or a fixnum (tag 0 or 4) and an object, which
   may be an equal real, need C; a bit per pair of tags says which. */
#define EQ_PAIR(a, b) (UINT64_C(1) << (8 * (a) + (b)))
#define EQ_NEEDS_C (EQ_PAIR(TAG_PAIR, TAG_PAIR) | EQ_PAIR(TAG_OBJECT, TAG_OBJECT) | \
                    EQ_PAIR(0, TAG_OBJECT) | EQ_PAIR(4, TAG_OBJECT) |                 \
                    EQ_PAIR(TAG_OBJECT, 0) | EQ_PAIR(TAG_OBJECT, 4))

static struct sljit_jump *eq_needs_c(struct sljit_compiler *c, struct sljit_jump **plain)
{
    /* Fixnums, specials and symbols have tag bit 0 clear: two of them that
       are not identical differ, without the table. Only where differing
       takes a jump anyway (plain, for a test fused with its branch), since
       an extra jump taken costs more than the table. */
    if (plain) {
        sljit_emit_op2(c, SLJIT_OR, R2, R0, R1);
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R2, IMM(1));
        *plain = sljit_emit_jump(c, SLJIT_ZERO);
    }
    sljit_emit_op2(c, SLJIT_AND, R2, R0, IMM(7));
    sljit_emit_op2(c, SLJIT_SHL, R2, R2, IMM(3));
    sljit_emit_op2(c, SLJIT_AND, R3, R1, IMM(7));
    sljit_emit_op2(c, SLJIT_OR, R2, R2, R3);
    sljit_emit_op1(c, SLJIT_MOV, R3, IMM(EQ_NEEDS_C));
    sljit_emit_op2(c, SLJIT_LSHR, R3, R3, R2);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R3, IMM(1));
    return sljit_emit_jump(c, SLJIT_NOT_ZERO);
}

/* = on two values: jumps through `same` when they are identical, and returns
   the jump taken when C must compare them; falling through means they
   differ, and so does a jump through *plain when plain is given (else it is
   NULL). Against a fixnum constant only an object, which may be an equal
   real, needs C. */
static struct sljit_jump *emit_eq(Emit *e, const uint32_t *arg, struct sljit_jump **same,
                                  struct sljit_jump **plain)
{
    struct sljit_compiler *c = e->c;
    if (fixnum_operand(e, arg[0]) || fixnum_operand(e, arg[1])) {
        uint32_t k = fixnum_operand(e, arg[0]) ? 0 : 1;
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1 - k]));
        *same = sljit_emit_cmp(c, SLJIT_EQUAL, R1, OPND(e, arg[k]));
        if (plain)
            *plain = NULL;
        return tag_cmp(c, SLJIT_EQUAL, R2, R1, TAG_OBJECT);
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
    sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
    *same = sljit_emit_cmp(c, SLJIT_EQUAL, R0, R1);
    return eq_needs_c(c, plain);
}

/* A constant string of at most STRING_EQ_WORDS words of bytes: = compares a
   value with it inline, as an object with the same header and words. */
#define STRING_EQ_WORDS 4

static bool string_operand(const Emit *e, uint32_t x)
{
    if (!(x & OPERAND_CONST))
        return false;
    V v = *operand_cell(e, x);
    return is_object(v) && obj_type(v) == T_STRING && string_length(v) <= STRING_EQ_WORDS * sizeof(V);
}

/* = with a constant string, one of arg[0] and arg[1]: falls through when the
   other value equals it, and leaves the jumps taken when it does not in
   differ, ended by NULL. An identical value passes the same tests. */
static void emit_string_eq(Emit *e, const uint32_t *arg, struct sljit_jump **differ)
{
    struct sljit_compiler *c = e->c;
    uint32_t k = string_operand(e, arg[0]) ? 0 : 1;
    const uint64_t *s = ptr(*operand_cell(e, arg[k]));
    size_t words = (string_length(tagged(s, TAG_OBJECT)) + sizeof(V) - 1) / sizeof(V), n = 0;
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[1 - k]));
    differ[n++] = tag_cmp(c, SLJIT_NOT_EQUAL, R1, R0, TAG_OBJECT);
    for (size_t i = 0; i <= words; i++) { /* the header, then the words with their zero padding */
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R0), (sljit_sw)(i * sizeof(V)) - TAG_OBJECT);
        differ[n++] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(s[i]));
    }
    differ[n] = NULL;
}

/* The operands of fixnum arithmetic: a in R0, and b in R1 or, for a fixnum
   constant, as an immediate in *bk, *bw that needs no test. Returns the jump
   taken when an operand is not a fixnum. */
static struct sljit_jump *fixnum_operands(Emit *e, uint32_t a, uint32_t b, sljit_s32 *bk, sljit_sw *bw)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, a));
    if (fixnum_operand(e, b)) {
        *bk = operand_kind(e, b);
        *bw = operand_offset(e, b);
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
    } else {
        *bk = SLJIT_R1;
        *bw = 0;
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, b));
        sljit_emit_op2(c, SLJIT_OR, R2, R0, R1);
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R2, IMM(3));
    }
    return sljit_emit_jump(c, SLJIT_NOT_ZERO);
}

/* Whether operand x is a fixnum constant that a double holds exactly. */
static bool exact_constant(const Emit *e, uint32_t x)
{
    if (!fixnum_operand(e, x))
        return false;
    int64_t k = fixval(*operand_cell(e, x));
    return k >= -(INT64_C(1) << 53) && k <= INT64_C(1) << 53;
}

/* The number at operand x in a float register: a real's value, or a fixnum's, converted. Anything
   else jumps away, through other[0] and other[1], and so does, if inexact is not NULL, through it, a
   fixnum that a double may not hold exactly. An exact constant is loaded as a double, with no tests
   and no jumps set. Uses R0 and R1. */
static void load_number(Emit *e, uint32_t x, sljit_s32 f, struct sljit_jump **other, struct sljit_jump **inexact)
{
    struct sljit_compiler *c = e->c;
    if (exact_constant(e, x)) {
        sljit_emit_fset64(c, f, (double)fixval(*operand_cell(e, x)));
        return;
    }
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, x));
    struct sljit_jump *not_object = tag_cmp(c, SLJIT_NOT_EQUAL, R1, R0, TAG_OBJECT);
    sljit_emit_op1(c, SLJIT_MOV_U8, R1, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
    other[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(T_REAL << 3 | TAG_HEADER));
    sljit_emit_fop1(c, SLJIT_MOV_F64, f, 0, SLJIT_MEM1(SLJIT_R0), REAL_VALUE * WORD - TAG_OBJECT);
    struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
    sljit_set_label(not_object, sljit_emit_label(c));
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
    other[1] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
    sljit_emit_op2(c, SLJIT_ASHR, R0, R0, IMM(2));
    if (inexact) {
        sljit_emit_op2(c, SLJIT_ADD, R1, R0, IMM(INT64_C(1) << 53));
        *inexact = sljit_emit_cmp(c, SLJIT_GREATER, R1, IMM(INT64_C(1) << 54));
    }
    sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, f, 0, R0);
    sljit_set_label(done, sljit_emit_label(c));
}

/* Type tests: cons?, shen-jit.symbol? and the tag, absvector?, string? and
   number? also the header's type, shen-jit.tagged? an absvector's length and
   element 0, and shen-jit.pvar? the low byte. Falling through means yes; the test leaves its jumps
   to no in `no`, and number? jumps to yes early for a fixnum. */
typedef struct {
    struct sljit_jump *no[4], *yes;
} Test;

static bool type_test(uint32_t prim)
{
    return prim == P_CONSP || prim == P_SYMBOLP || prim == P_ABSVECTORP || prim == P_STRINGP ||
           prim == P_NUMBERP || prim == P_TAGGEDP || prim == P_PVARP || prim == P_SAMEP;
}

static Test emit_type_test(Emit *e, uint32_t prim, const uint32_t *arg)
{
    struct sljit_compiler *c = e->c;
    Test t = {{NULL, NULL, NULL, NULL}, NULL};
    if (prim == P_SAMEP) {
        t.no[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, OPND(e, arg[0]), OPND(e, arg[1]));
        return t;
    }
    sljit_s32 r = operand_reg(e, arg[0]);
    if (prim == P_PVARP) {
        sljit_emit_op2(c, SLJIT_AND, R1, r, 0, IMM(0xFF));
        t.no[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(PVAR_TAG));
        return t;
    }
    if (prim == P_TAGGEDP) {
        t.no[0] = tag_cmp(c, SLJIT_NOT_EQUAL, R1, r, 0, TAG_OBJECT);
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(r), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R1, R2, IMM(0xFF));
        t.no[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(T_VECTOR << 3 | TAG_HEADER));
        t.no[2] = sljit_emit_cmp(c, SLJIT_LESS, R2, IMM(1 << 8)); /* length 0 */
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        t.no[3] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, SLJIT_MEM1(r), sizeof(V) - TAG_OBJECT);
        return t;
    }
    if (prim == P_NUMBERP) {
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, r, 0, IMM(3));
        t.yes = sljit_emit_jump(c, SLJIT_ZERO);
    }
    unsigned tag = prim == P_CONSP ? TAG_PAIR : prim == P_SYMBOLP ? TAG_SYMBOL : TAG_OBJECT;
    t.no[0] = tag_cmp(c, SLJIT_NOT_EQUAL, R1, r, 0, tag);
    if (tag == TAG_OBJECT) {
        unsigned type = prim == P_ABSVECTORP ? T_VECTOR : prim == P_STRINGP ? T_STRING : T_REAL;
        /* The header's low byte holds its tag and the type. */
        sljit_emit_op1(c, SLJIT_MOV_U8, R1, SLJIT_MEM1(r), -TAG_OBJECT);
        t.no[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(type << 3 | TAG_HEADER));
    }
    return t;
}

/* shen-jit.vector?: an absvector whose element 0 is a fixnum at least 0.
   Falling through means yes; the jumps to no are left in `no`, and the one
   returned is taken for any other element 0, which C tests, accepting a
   real at least 0 too. */
static struct sljit_jump *emit_vector_test(Emit *e, const uint32_t *arg, struct sljit_jump **no)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
    no[0] = tag_cmp(c, SLJIT_NOT_EQUAL, R1, R0, TAG_OBJECT);
    sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
    sljit_emit_op2(c, SLJIT_AND, R1, R2, IMM(0xFF));
    no[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(T_VECTOR << 3 | TAG_HEADER));
    no[2] = sljit_emit_cmp(c, SLJIT_LESS, R2, IMM(1 << 8)); /* length 0 */
    sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R0), sizeof(V) - TAG_OBJECT);
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
    struct sljit_jump *other = sljit_emit_jump(c, SLJIT_NOT_ZERO);
    no[3] = sljit_emit_cmp(c, SLJIT_SIG_LESS, R1, IMM(0));
    return other;
}

/* shen-jit.arity? of a constant name and count, as the lowerer emits it:
   whether the name's function is now a closure taking that many arguments.
   Falling through means yes. */
static bool arity_operands(const Emit *e, const uint32_t *arg)
{
    return (arg[0] & OPERAND_CONST) && is_symbol(*operand_cell(e, arg[0])) && fixnum_operand(e, arg[1]);
}

static void emit_arity_test(Emit *e, const uint32_t *arg, struct sljit_jump **no)
{
    struct sljit_compiler *c = e->c;
    V *cell = cell_function(e->vm, symbol_cell(*operand_cell(e, arg[0])));
    sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)cell);
    no[0] = tag_cmp(c, SLJIT_NOT_EQUAL, R0, R1, TAG_PROC);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, SLJIT_MEM1(SLJIT_R1), -TAG_PROC);
    no[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, IMM(T_CLOSURE << 3 | TAG_HEADER));
    sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R1), CLO_CODE * sizeof(V) - TAG_PROC);
    sljit_emit_op1(c, SLJIT_MOV_U32, R0, SLJIT_MEM1(SLJIT_R0), CODE_ARITY * sizeof(V) - TAG_OBJECT);
    no[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, IMM(fixval(*operand_cell(e, arg[1]))));
}

/* Whether the function in cell is a closure of code whose inline body is
   the constant at operand body. Falling through means yes. */
static void emit_inlined_test(Emit *e, size_t cell, uint32_t body, struct sljit_jump **no)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)cell_function(e->vm, cell));
    no[0] = tag_cmp(c, SLJIT_NOT_EQUAL, R0, R1, TAG_PROC);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, SLJIT_MEM1(SLJIT_R1), -TAG_PROC);
    no[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, IMM(T_CLOSURE << 3 | TAG_HEADER));
    sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R1), CLO_CODE * sizeof(V) - TAG_PROC);
    sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0), CODE_INLINE * sizeof(V) - TAG_OBJECT);
    no[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, OPND(e, body));
}

/* A byte buffer in reach of an instruction: its base in R0 and its length in R2. Anything else
   leaves this path. A pointer with a length comes back to it from SLOW_POINTER, with its length
   and base in the same registers, and anything else takes the slow path, which raises. */
static Slow *emit_memory_base(Emit *e, uint32_t memory, SlowKind kind, bool store)
{
    struct sljit_compiler *c = e->c;
    for (uint32_t k = 0; k < e->nmemory && !(kind == SLOW_PRIM && e->uncached); k++)
        if (e->memory[k] == memory) { /* checked already: length 0 sends anything else to its slow path */
            uint32_t at = WORD_REGISTERS + 3 * k;
            sljit_emit_op1(c, SLJIT_MOV, R0, RAW(e, at));
            sljit_emit_op1(c, SLJIT_MOV, R2, RAW(e, at + (store ? 2 : 1)));
            return slow_path(e, kind, NULL);
        }
    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, memory));
    Slow *slow = slow_path(e, kind, tag_cmp(c, SLJIT_NOT_EQUAL, R2, R0, TAG_OBJECT));
    sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
    sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
    Slow *pointer = slow_path(e, SLOW_POINTER, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_BYTES << 3 | TAG_HEADER)));
    pointer->prim = slow;
    pointer->store = store;
    sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8)); /* the length */
    sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V) - TAG_OBJECT)); /* the base */
    pointer->back = sljit_emit_label(c);
    return slow;
}

/* A fixnum index with room for the width, in R1. */
static void emit_memory_index(Emit *e, Slow *slow, uint32_t index, unsigned size)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, index));
    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
    slow->from[2] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
    sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(2)); /* a negative index becomes huge */
    sljit_emit_op2(c, SLJIT_ADD, R3, R1, IMM(((sljit_sw)1 << size) - 1));
    slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, R2);
}

/* The same for a word index, which has no tag to test and may be anything, in R1. */
static void emit_word_index(Emit *e, Slow *slow, uint32_t index, unsigned size)
{
    struct sljit_compiler *c = e->c;
    sljit_emit_op1(c, SLJIT_MOV, R1, WORD_OPERAND(e, index));
    slow->from[2] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, R2);
    if (size) {
        sljit_emit_op2(c, SLJIT_ADD, R3, R1, IMM(((sljit_sw)1 << size) - 1));
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, R2);
    }
}

/* The check of a word-indexed access, and the operand that makes it, with a slow path that says
   what is wrong. Memory with a limit takes one comparison, and what is in registers stays there. */
static sljit_s32 emit_word_access(Emit *e, uint32_t memory, uint32_t index, unsigned size, bool store)
{
    struct sljit_compiler *c = e->c;
    for (uint32_t k = 0; k < e->nmemory; k++)
        if (e->memory[k] == memory && e->limit_size[k] >= 0) {
            uint32_t at = WORD_REGISTERS + 3 * k;
            Slow *slow = slow_path(e, SLOW_MEMORY, NULL);
            slow->memory = memory;
            slow->index = index;
            slow->store = store;
            sljit_s32 i = index & OPERAND_CONST ? SLJIT_R1 : raw_register(e, index, SLJIT_R1);
            sljit_s32 base = raw_register(e, at, SLJIT_R0);
            if (i == SLJIT_R1)
                sljit_emit_op1(c, SLJIT_MOV, R1, WORD_OPERAND(e, index));
            slow->from[2] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, i, 0, RAW(e, at + (store ? 2 : 1)));
            if (base == SLJIT_R0)
                sljit_emit_op1(c, SLJIT_MOV, R0, RAW(e, at));
            return SLJIT_MEM2(base, i);
        }
    Slow *slow = emit_memory_base(e, memory, SLOW_MEMORY, store);
    slow->memory = memory;
    slow->index = index;
    slow->store = store;
    emit_word_index(e, slow, index, size);
    return SLJIT_MEM2(SLJIT_R0, SLJIT_R1);
}

/* SLJIT has no square root, and both targets do. */
static void emit_sqrt(struct sljit_compiler *c, sljit_s32 d, sljit_s32 s)
{
    sljit_u32 rd = (sljit_u32)sljit_get_register_index(SLJIT_FLOAT_REGISTER, d);
    sljit_u32 rs = (sljit_u32)sljit_get_register_index(SLJIT_FLOAT_REGISTER, s);
#if (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    sljit_u32 fsqrt = 0x1E61C000u | rs << 5 | rd;
    sljit_emit_op_custom(c, &fsqrt, sizeof fsqrt);
#elif (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
    sljit_u8 sqrtsd[] = {0xF2, (sljit_u8)(0x40 | (rd >> 3) << 2 | rs >> 3), 0x0F, 0x51,
                         (sljit_u8)(0xC0 | (rd & 7) << 3 | (rs & 7))};
    sljit_emit_op_custom(c, sqrtsd, sizeof sqrtsd);
#else
#error "no square root for this target"
#endif
}

/* Instructions on real registers. They are only in code written by hand, which the checker
   holds to making no calls, and neither the collector nor a raise looks at the registers. */
static void emit_raw(Emit *e, const uint32_t *p)
{
    struct sljit_compiler *c = e->c;
    switch (p[0]) {
    case OP_REAL_NUMBER: {
        /* Through a float register: fset64 and load_number take nothing else. */
        sljit_s32 f = real_register(e, p[1]);
        V k = p[2] & OPERAND_CONST ? *operand_cell(e, p[2]) : V_NIL;
        if (is_fix(k) || (is_object(k) && obj_type(k) == T_REAL)) {
            sljit_emit_fset64(c, f, is_fix(k) ? (double)fixval(k) : real_value(k));
        } else {
            struct sljit_jump *other[2];
            load_number(e, p[2], f, other, NULL);
            Slow *s = slow_path(e, SLOW_NOT_NUMBER, other[0]);
            s->from[1] = other[1];
            s->insn = p;
        }
        if (f == SLJIT_FR0)
            sljit_emit_fop1(c, SLJIT_MOV_F64, REAL(e, p[1]), SLJIT_FR0, 0);
        break;
    }
    case OP_REAL_BOX: {
        struct sljit_label *restart = sljit_emit_label(c);
        sljit_emit_op2(c, SLJIT_ADD, R1, HP, IMM(REAL_WORDS * sizeof(V)));
        Slow *alloc = slow_path(e, SLOW_ALLOC, sljit_emit_cmp(c, SLJIT_GREATER, R1, VMF(hlimit)));
        alloc->words = REAL_WORDS;
        alloc->back = restart;
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), 0, IMM(HEADER(T_REAL, 0)));
        sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM1(SLJIT_S3), REAL_VALUE * WORD, REAL(e, p[2]));
        sljit_emit_op2(c, SLJIT_ADD, R0, HP, IMM(TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, HP, R1);
        store_result(e, p[1]);
        break;
    }
    case OP_REAL_MOVE: sljit_emit_fop1(c, SLJIT_MOV_F64, REAL(e, p[1]), REAL(e, p[2])); break;
    case OP_REAL_NEG: sljit_emit_fop1(c, SLJIT_NEG_F64, REAL(e, p[1]), REAL(e, p[2])); break;
    case OP_REAL_ABS: sljit_emit_fop1(c, SLJIT_ABS_F64, REAL(e, p[1]), REAL(e, p[2])); break;
    case OP_REAL_SQRT: {
        sljit_s32 d = real_register(e, p[1]), s = real_register(e, p[2]);
        if (s == SLJIT_FR0)
            sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_FR0, 0, REAL(e, p[2]));
        emit_sqrt(c, d, s);
        if (d == SLJIT_FR0)
            sljit_emit_fop1(c, SLJIT_MOV_F64, REAL(e, p[1]), SLJIT_FR0, 0);
        break;
    }
    case OP_REAL_ADD: sljit_emit_fop2(c, SLJIT_ADD_F64, REAL(e, p[1]), REAL(e, p[2]), REAL(e, p[3])); break;
    case OP_REAL_SUB: sljit_emit_fop2(c, SLJIT_SUB_F64, REAL(e, p[1]), REAL(e, p[2]), REAL(e, p[3])); break;
    case OP_REAL_MUL: sljit_emit_fop2(c, SLJIT_MUL_F64, REAL(e, p[1]), REAL(e, p[2]), REAL(e, p[3])); break;
    case OP_REAL_DIV: sljit_emit_fop2(c, SLJIT_DIV_F64, REAL(e, p[1]), REAL(e, p[2]), REAL(e, p[3])); break;
    case OP_REAL_UNLESS_LT: case OP_REAL_UNLESS_GT: case OP_REAL_UNLESS_LE: case OP_REAL_UNLESS_GE:
    case OP_REAL_UNLESS_EQ: {
        /* NaN compares as false, so it jumps. */
        static const sljit_s32 unless[] = {SLJIT_UNORDERED_OR_GREATER_EQUAL, SLJIT_UNORDERED_OR_LESS_EQUAL,
                                           SLJIT_UNORDERED_OR_GREATER, SLJIT_UNORDERED_OR_LESS,
                                           SLJIT_UNORDERED_OR_NOT_EQUAL};
        to_label(e, sljit_emit_fcmp(c, unless[p[0] - OP_REAL_UNLESS_LT], REAL(e, p[1]), REAL(e, p[2])), p[3]);
        break;
    }
    case OP_REAL_LOAD_AT: {
        sljit_s32 at = emit_word_access(e, p[2], p[3], 3, false);
        sljit_emit_fop1(c, SLJIT_MOV_F64, REAL(e, p[1]), at, 0);
        break;
    }
    case OP_REAL_STORE_AT: {
        sljit_s32 at = emit_word_access(e, p[1], p[2], 3, true);
        sljit_emit_fop1(c, SLJIT_MOV_F64, at, 0, REAL(e, p[3]));
        break;
    }
    case OP_REAL_FROM_WORD: sljit_emit_fop1(c, SLJIT_CONV_F64_FROM_SW, REAL(e, p[1]), WORD_OPERAND(e, p[2])); break;
    case OP_WORD_FROM_REAL: sljit_emit_fop1(c, SLJIT_CONV_SW_FROM_F64, RAW(e, p[1]), REAL(e, p[2])); break;
    case OP_WORD_NUMBER: {
        V k = p[2] & OPERAND_CONST ? *operand_cell(e, p[2]) : V_NIL;
        if (is_fix(k)) {
            sljit_emit_op1(c, SLJIT_MOV, RAW(e, p[1]), IMM(fixval(k)));
            break;
        }
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, p[2]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
        slow_path(e, SLOW_NOT_INTEGER, sljit_emit_jump(c, SLJIT_NOT_ZERO))->insn = p;
        sljit_emit_op2(c, SLJIT_ASHR, RAW(e, p[1]), R0, IMM(2));
        break;
    }
    case OP_WORD_BOX: {
        sljit_emit_op1(c, SLJIT_MOV, R1, WORD_OPERAND(e, p[2]));
        sljit_emit_op2(c, SLJIT_SHL, R0, R1, IMM(2));
        sljit_emit_op2(c, SLJIT_ASHR, R2, R0, IMM(2));
        slow_path(e, SLOW_TOO_BIG, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, R1))->insn = p;
        store_result(e, p[1]);
        break;
    }
    case OP_WORD_MOVE: sljit_emit_op1(c, SLJIT_MOV, RAW(e, p[1]), WORD_OPERAND(e, p[2])); break;
    case OP_WORD_ADD: case OP_WORD_SUB: case OP_WORD_MUL: case OP_WORD_AND: case OP_WORD_OR: case OP_WORD_XOR:
    case OP_WORD_SHL: case OP_WORD_SHR: case OP_WORD_SAR: case OP_WORD_ROTL: case OP_WORD_ROTR: {
        static const sljit_s32 op[] = {SLJIT_ADD, SLJIT_SUB, SLJIT_MUL, SLJIT_AND, SLJIT_OR, SLJIT_XOR,
                                       SLJIT_MSHL, SLJIT_MLSHR, SLJIT_MASHR, SLJIT_ROTL, SLJIT_ROTR};
        sljit_emit_op2(c, op[p[0] - OP_WORD_ADD], RAW(e, p[1]), WORD_OPERAND(e, p[2]), WORD_OPERAND(e, p[3]));
        break;
    }
    case OP_WORD_UNLESS_LT: case OP_WORD_UNLESS_GT: case OP_WORD_UNLESS_LE: case OP_WORD_UNLESS_GE:
    case OP_WORD_UNLESS_EQ: case OP_WORD_UNLESS_ULT: case OP_WORD_UNLESS_UGT: case OP_WORD_UNLESS_ULE:
    case OP_WORD_UNLESS_UGE: {
        static const sljit_s32 unless[] = {SLJIT_SIG_GREATER_EQUAL, SLJIT_SIG_LESS_EQUAL, SLJIT_SIG_GREATER, SLJIT_SIG_LESS,
                                           SLJIT_NOT_EQUAL, SLJIT_GREATER_EQUAL, SLJIT_LESS_EQUAL, SLJIT_GREATER, SLJIT_LESS};
        to_label(e, sljit_emit_cmp(c, unless[p[0] - OP_WORD_UNLESS_LT], WORD_OPERAND(e, p[1]), WORD_OPERAND(e, p[2])), p[3]);
        break;
    }
    case OP_WORD_LOAD8: case OP_WORD_LOAD16: case OP_WORD_LOAD32: case OP_WORD_LOAD_S32: case OP_WORD_LOAD64: {
        static const struct { sljit_s32 op; unsigned size; } load[] = {
            {SLJIT_MOV_U8, 0}, {SLJIT_MOV_U16, 1}, {SLJIT_MOV_U32, 2}, {SLJIT_MOV_S32, 2}, {SLJIT_MOV, 3}};
        unsigned w = p[0] - OP_WORD_LOAD8;
        sljit_s32 at = emit_word_access(e, p[2], p[3], load[w].size, false);
        sljit_s32 d = raw_register(e, p[1], SLJIT_R0); /* to memory, it would write only its width */
        sljit_emit_op1(c, load[w].op, d, 0, at, 0);
        if (d == SLJIT_R0)
            sljit_emit_op1(c, SLJIT_MOV, RAW(e, p[1]), R0);
        break;
    }
    case OP_WORD_STORE8: case OP_WORD_STORE16: case OP_WORD_STORE32: case OP_WORD_STORE64: {
        static const sljit_s32 store[] = {SLJIT_MOV_U8, SLJIT_MOV_U16, SLJIT_MOV_U32, SLJIT_MOV};
        unsigned w = p[0] - OP_WORD_STORE8;
        sljit_s32 at = emit_word_access(e, p[1], p[2], w, true);
        sljit_s32 s = p[3] & OPERAND_CONST ? SLJIT_R2 : raw_register(e, p[3], SLJIT_R2);
        if (s == SLJIT_R2)
            sljit_emit_op1(c, SLJIT_MOV, R2, WORD_OPERAND(e, p[3]));
        sljit_emit_op1(c, store[w], at, 0, s, 0);
        break;
    }
    default: { /* OP_REAL_LOAD, OP_REAL_STORE: laid out as prim is */
        Slow *slow = emit_memory_base(e, p[4], SLOW_PRIM, p[0] == OP_REAL_STORE);
        emit_memory_index(e, slow, p[5], 3);
        if (p[0] == OP_REAL_LOAD)
            sljit_emit_fop1(c, SLJIT_MOV_F64, REAL(e, p[1]), SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0);
        else
            sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0, REAL(e, p[1]));
        slow->insn = p;
        slow->back = sljit_emit_label(c);
    }
    }
}

/* Primitives with inline fast paths; everything else, and every slow path,
   goes through sj_primitive. */
static void emit_prim(Emit *e, const uint32_t *p)
{
    struct sljit_compiler *c = e->c;
    /* prim: opcode, destination, primitive, count, arguments. */
    uint32_t dst = p[1], prim = p[2];
    const uint32_t *arg = p + 4;
    Slow *slow = NULL;
    struct sljit_label *restart = sljit_emit_label(c);

    if (slow_prims) {
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_JUMP));
        slow->insn = p;
        slow->back = sljit_emit_label(c);
        return;
    }
    switch (prim) {
    case P_ADD:
    case P_SUB:
    case P_MUL: {
        /* For * (a >> 2) * b is the tagged product; overflow means a result
           outside the fixnum range. + and * take a constant first operand
           second. */
        bool swap = prim != P_SUB && fixnum_operand(e, arg[0]) && !fixnum_operand(e, arg[1]);
        sljit_s32 bk;
        sljit_sw bw;
        slow = slow_path(e, SLOW_PRIM, fixnum_operands(e, arg[swap], arg[!swap], &bk, &bw));
        if (prim == P_MUL)
            sljit_emit_op2(c, SLJIT_ASHR, R0, R0, IMM(2));
        static const sljit_s32 op[] = {[P_ADD] = SLJIT_ADD, [P_SUB] = SLJIT_SUB, [P_MUL] = SLJIT_MUL};
        sljit_emit_op2(c, op[prim] | SLJIT_SET_OVERFLOW, R0, R0, bk, bw);
        slow->from[1] = sljit_emit_jump(c, SLJIT_OVERFLOW);
        store_result(e, dst);
        break;
    }
    case P_LT:
    case P_GT:
    case P_LE:
    case P_GE: {
        static const sljit_s32 set[] = {SLJIT_SET_SIG_LESS, SLJIT_SET_SIG_GREATER,
                                        SLJIT_SET_SIG_GREATER, SLJIT_SET_SIG_LESS};
        static const sljit_s32 type[] = {SLJIT_SIG_LESS, SLJIT_SIG_GREATER,
                                         SLJIT_SIG_LESS_EQUAL, SLJIT_SIG_GREATER_EQUAL};
        sljit_s32 bk;
        sljit_sw bw;
        slow = slow_path(e, SLOW_PRIM, fixnum_operands(e, arg[0], arg[1], &bk, &bw));
        sljit_emit_op2u(c, SLJIT_SUB | set[prim - P_LT], R0, bk, bw);
        store_boolean_from_flags(e, type[prim - P_LT], dst);
        break;
    }
    case P_EQ: {
        if (identity_operand(e, arg[0]) || identity_operand(e, arg[1])) {
            uint32_t k = identity_operand(e, arg[1]) ? 1 : 0;
            sljit_emit_op2u(c, SLJIT_SUB | SLJIT_SET_Z, OPND(e, arg[1 - k]), OPND(e, arg[k]));
            store_boolean_from_flags(e, SLJIT_ZERO, dst);
            break;
        }
        if (string_operand(e, arg[0]) || string_operand(e, arg[1])) {
            struct sljit_jump *differ[STRING_EQ_WORDS + 3];
            emit_string_eq(e, arg, differ);
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
            struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
            struct sljit_label *no = sljit_emit_label(c);
            for (int i = 0; differ[i]; i++)
                sljit_set_label(differ[i], no);
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_FALSE));
            sljit_set_label(done, sljit_emit_label(c));
            break;
        }
        if (fixnum_operand(e, arg[0]) || fixnum_operand(e, arg[1])) {
            /* Only an object, which may be an equal real, leaves; anything
               else is equal only if identical, a Boolean from the flags
               with no branch taken. */
            uint32_t k = fixnum_operand(e, arg[0]) ? 0 : 1;
            sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1 - k]));
            slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_EQUAL, R2, R1, TAG_OBJECT));
            sljit_emit_op2u(c, SLJIT_SUB | SLJIT_SET_Z, R1, OPND(e, arg[k]));
            store_boolean_from_flags(e, SLJIT_ZERO, dst);
            break;
        }
        struct sljit_jump *same;
        slow = slow_path(e, SLOW_PRIM, emit_eq(e, arg, &same, NULL));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_FALSE));
        struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
        sljit_set_label(same, sljit_emit_label(c));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
        sljit_set_label(done, sljit_emit_label(c));
        break;
    }
    case P_HD:
    case P_TL: {
        sljit_s32 r = operand_reg(e, arg[0]);
        if (!(arg[0] < 64 && (e->pairs >> arg[0]) & 1)) {
            slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R1, r, 0, TAG_PAIR));
            slow->catch_label = quiet_catch(e);
        }
        put_result(e, dst, SLJIT_MEM1(r), (sljit_sw)(prim == P_HD ? 0 : sizeof(V)) - TAG_PAIR);
        break;
    }
    case P_CONSP:
    case P_SYMBOLP:
    case P_ABSVECTORP:
    case P_STRINGP:
    case P_NUMBERP:
    case P_TAGGEDP:
    case P_PVARP:
    case P_SAMEP: {
        Test t = emit_type_test(e, prim, arg);
        struct sljit_label *yes = sljit_emit_label(c);
        if (t.yes)
            sljit_set_label(t.yes, yes);
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
        struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
        struct sljit_label *no = sljit_emit_label(c);
        for (int i = 0; i < 4; i++)
            if (t.no[i])
                sljit_set_label(t.no[i], no);
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_FALSE));
        sljit_set_label(done, sljit_emit_label(c));
        break;
    }
    case P_CN: {
        /* Two strings, a result below a large object's, and room in the
           semispace: allocate here and copy in C, without the primitive
           dispatcher. Anything else takes the slow path, which raises,
           collects or allocates a large string. The result's header is the
           first's plus the second's length. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        sljit_emit_op2(c, SLJIT_AND, R2, R0, IMM(7));
        sljit_emit_op2(c, SLJIT_AND, R3, R1, IMM(7));
        sljit_emit_op2(c, SLJIT_SHL, R3, R3, IMM(3));
        sljit_emit_op2(c, SLJIT_OR, R2, R2, R3);
        slow = slow_path(e, SLOW_PRIM, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(TAG_OBJECT << 3 | TAG_OBJECT)));
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
        sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM1(SLJIT_R1), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_XOR, R4, R2, IMM(T_STRING << 3 | TAG_HEADER));
        sljit_emit_op2(c, SLJIT_OR, R4, R4, R3);
        sljit_emit_op2(c, SLJIT_XOR, R4, R4, IMM(T_STRING << 3 | TAG_HEADER));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R4, IMM(0xFF));
        slow->from[1] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        sljit_emit_op2(c, SLJIT_AND, R3, R3, IMM(~(sljit_sw)0xFF));
        sljit_emit_op2(c, SLJIT_ADD, R2, R2, R3); /* the result's header */
        sljit_emit_op2(c, SLJIT_LSHR, R3, R2, IMM(8));
        sljit_emit_op2(c, SLJIT_ADD, R3, R3, IMM(15));
        sljit_emit_op2(c, SLJIT_AND, R3, R3, IMM(~(sljit_sw)7)); /* bytes with the header */
        struct sljit_jump *two = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, IMM(2 * sizeof(V)));
        sljit_emit_op1(c, SLJIT_MOV, R3, IMM(2 * sizeof(V))); /* at least two words */
        sljit_set_label(two, sljit_emit_label(c));
        slow->from[2] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, IMM(LARGE_WORDS * sizeof(V)));
        sljit_emit_op1(c, SLJIT_MOV, R4, HP);
        sljit_emit_op2(c, SLJIT_ADD, R3, R3, HP);
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER, R3, VMF(hlimit));
        sljit_emit_op1(c, SLJIT_MOV, HP, R3);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R4), 0, R2);
        sljit_emit_op1(c, SLJIT_MOV, R2, R1);
        sljit_emit_op1(c, SLJIT_MOV, R1, R0);
        sljit_emit_op1(c, SLJIT_MOV, R0, R4);
        call_leaf(e, SLJIT_ARGS3(W, P, W, W), (void *)h_cn_bytes);
        store_result(e, dst);
        break;
    }
    case P_QUIETP: {
        /* Whether the innermost handler ignores errors, as prims.c's
           quiet_handler: bit 0 of its frame offset. Behind the port's get
           and shen.<-dict, which build no message for such a handler. */
        sljit_emit_op1(c, SLJIT_MOV, R0, VMF(nhandlers));
        struct sljit_jump *none = sljit_emit_cmp(c, SLJIT_EQUAL, R0, IMM(0));
        sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(4)); /* 16-byte handlers, as at push */
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, VMF(handlers));
        sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0),
                       (sljit_sw)offsetof(Handler, fp_offset) - (sljit_sw)sizeof(Handler));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(1));
        struct sljit_jump *loud = sljit_emit_jump(c, SLJIT_ZERO);
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
        struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
        struct sljit_label *no = sljit_emit_label(c);
        sljit_set_label(none, no);
        sljit_set_label(loud, no);
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_FALSE));
        sljit_set_label(done, sljit_emit_label(c));
        break;
    }
    case P_ABSVECTOR:
    case P_FILLED_VECTOR: {
        /* Inline for a length n below a large object's when the semispace
           has room and, for absvector, vm->fail is set to fill it; the slow
           path allocates large objects, checks, collects and raises.
           The tagged length is n << 2, so the header is that << 6 with the
           type and tag, and the elements end n << 3 bytes after it, or one
           word for n = 0, since objects take at least two words. */
        if (fixnum_operand(e, arg[0]) && fixval(*operand_cell(e, arg[0])) >= 0 &&
            fixval(*operand_cell(e, arg[0])) <= 15) {
            /* A constant length: the words stored one pair at a time, with
               no loop and no tests of the length. */
            int64_t n = fixval(*operand_cell(e, arg[0])), words = 1 + (n > 0 ? n : 1);
            if (n == 0)
                sljit_emit_op1(c, SLJIT_MOV, R3, IMM(V_NIL)); /* the padding, as in C */
            else if (prim == P_ABSVECTOR) {
                sljit_emit_op1(c, SLJIT_MOV, R3, VMF(fail));
                slow = slow_path(e, SLOW_PRIM, sljit_emit_cmp(c, SLJIT_EQUAL, R3, IMM(V_NIL)));
            } else
                sljit_emit_op1(c, SLJIT_MOV, R3, OPND(e, arg[1]));
            sljit_emit_op1(c, SLJIT_MOV, R0, HP);
            sljit_emit_op2(c, SLJIT_ADD, R2, R0, IMM(words * sizeof(V)));
            struct sljit_jump *full = sljit_emit_cmp(c, SLJIT_GREATER, R2, VMF(hlimit));
            if (slow)
                slow->from[1] = full;
            else
                slow = slow_path(e, SLOW_PRIM, full);
            sljit_emit_op1(c, SLJIT_MOV, HP, R2);
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM((uint64_t)n << 8 | T_VECTOR << 3 | TAG_HEADER));
            sljit_emit_mem(c, SLJIT_MOV | SLJIT_MEM_STORE, SLJIT_REG_PAIR(SLJIT_R1, SLJIT_R3), SLJIT_MEM1(SLJIT_R0), 0);
            if (words >= 4)
                sljit_emit_op1(c, SLJIT_MOV, R4, R3); /* a pair is two registers */
            int64_t k = 2;
            for (; k + 1 < words; k += 2)
                sljit_emit_mem(c, SLJIT_MOV | SLJIT_MEM_STORE, SLJIT_REG_PAIR(SLJIT_R3, SLJIT_R4), SLJIT_MEM1(SLJIT_R0),
                               k * (sljit_sw)sizeof(V));
            if (k < words)
                sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), k * (sljit_sw)sizeof(V), R3);
            sljit_emit_op2(c, SLJIT_ADD, HOME(e, dst), R0, IMM(TAG_OBJECT));
            break;
        }
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[0]));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, IMM((uint64_t)(LARGE_WORDS - 1) << 2)));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
        slow->from[1] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        if (prim == P_ABSVECTOR) {
            sljit_emit_op1(c, SLJIT_MOV, R3, VMF(fail));
            slow->from[2] = sljit_emit_cmp(c, SLJIT_EQUAL, R3, IMM(V_NIL));
        } else {
            sljit_emit_op1(c, SLJIT_MOV, R3, OPND(e, arg[1]));
        }
        sljit_emit_op1(c, SLJIT_MOV, R0, HP);
        sljit_emit_op2(c, SLJIT_SHL, R2, R1, IMM(1));
        struct sljit_jump *nonempty = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R2, IMM(sizeof(V)));
        sljit_emit_op1(c, SLJIT_MOV, R3, IMM(V_NIL)); /* the padding, as in C */
        sljit_set_label(nonempty, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_ADD, R2, R2, R0);
        sljit_emit_op2(c, SLJIT_ADD, R2, R2, IMM(sizeof(V)));
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER, R2, VMF(hlimit));
        sljit_emit_op1(c, SLJIT_MOV, HP, R2);
        sljit_emit_op2(c, SLJIT_SHL, R1, R1, IMM(6));
        sljit_emit_op2(c, SLJIT_OR, R1, R1, IMM(T_VECTOR << 3 | TAG_HEADER));
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), 0, R1);
        sljit_emit_op2(c, SLJIT_ADD, R1, R0, IMM(sizeof(V)));
        /* Two words at a time while two remain, then the last one when the
           count is odd; there is always one, the padding when n is 0. R2
           becomes the address of the last word. The loop is aligned, so that
           its speed does not depend on the code before it. */
        sljit_emit_op2(c, SLJIT_SUB, R2, R2, IMM(sizeof(V)));
        sljit_emit_op1(c, SLJIT_MOV, R4, R3); /* a pair is two registers */
        struct sljit_jump *one = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, R2);
        struct sljit_label *fill = sljit_emit_aligned_label(c, LOOP_ALIGN, NULL);
        sljit_emit_mem(c, SLJIT_MOV | SLJIT_MEM_STORE, SLJIT_REG_PAIR(SLJIT_R3, SLJIT_R4), SLJIT_MEM1(SLJIT_R1), 0);
        sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(2 * sizeof(V)));
        sljit_set_label(sljit_emit_cmp(c, SLJIT_LESS, R1, R2), fill);
        sljit_set_label(one, sljit_emit_label(c));
        struct sljit_jump *even = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, R2);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R1), 0, R3);
        sljit_set_label(even, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_ADD, HOME(e, dst), R0, IMM(TAG_OBJECT));
        break;
    }
    case P_VALUE:
    case P_SET: {
        /* Global cells never move (vm.h): a constant symbol's value cell has
           a fixed address, and another symbol's is found from the index in
           its cell word, through the chunk directory, which may move.
           Anything but a symbol, and an unbound symbol for value, goes to
           C, which raises. */
        sljit_s32 cell = SLJIT_MEM1(SLJIT_R3);
        sljit_sw at = 0;
        if ((arg[0] & OPERAND_CONST) && is_symbol(*operand_cell(e, arg[0]))) {
            cell = SLJIT_MEM0();
            at = (sljit_sw)cell_value(e->vm, symbol_cell(*operand_cell(e, arg[0])));
        } else {
            sljit_s32 r = operand_reg(e, arg[0]);
            slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R1, r, 0, TAG_SYMBOL));
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(r), SYM_CELL * sizeof(V) - TAG_SYMBOL);
            sljit_emit_op2(c, SLJIT_AND, R1, R1, IMM((UINT64_C(1) << 56) - 1));
            sljit_emit_op2(c, SLJIT_SHL, R1, R1, IMM(1)); /* the value cell, 2 * index */
            sljit_emit_op2(c, SLJIT_LSHR, R2, R1, IMM(RA_CHUNK_BITS));
            sljit_emit_op2(c, SLJIT_AND, R1, R1, IMM(RA_CHUNK - 1));
            sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM1(VMR), (sljit_sw)offsetof(VM, cells.chunks));
            sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM2(SLJIT_R3, SLJIT_R2), 3);
            sljit_emit_op2(c, SLJIT_SHL, R1, R1, IMM(3));
            sljit_emit_op2(c, SLJIT_ADD, R3, R3, R1);
        }
        if (prim == P_VALUE) {
            sljit_emit_op1(c, SLJIT_MOV, R0, cell, at);
            struct sljit_jump *unbound = sljit_emit_cmp(c, SLJIT_EQUAL, R0, IMM(V_CLEARED));
            if (slow)
                slow->from[1] = unbound;
            else
                slow = slow_path(e, SLOW_PRIM, unbound);
        } else {
            sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[1]));
            sljit_emit_op1(c, SLJIT_MOV, cell, at, R0);
        }
        if (slow)
            slow->catch_label = quiet_catch(e);
        store_result(e, dst);
        break;
    }
    case P_INTEGERP: {
        /* A fixnum is one; anything else goes to C, which checks a real. */
        sljit_s32 r = operand_reg(e, arg[0]);
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, r, 0, IMM(3));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_NOT_ZERO));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
        break;
    }
    case P_SIMPLE_ERROR:
        /* Under a quiet handler of this code an error is just a jump. */
        if (quiet_catch(e) != NONE) {
            jump_to_catch(e, quiet_catch(e));
            return;
        }
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_JUMP));
        break;
    case P_SYMBOL_KIND: {
        /* The kind is in the top byte of a symbol's cell word (objects.c). */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op2(c, SLJIT_AND, R1, R0, IMM(7));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(fix(0)));
        struct sljit_jump *other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(TAG_SYMBOL));
        sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0), SYM_CELL * sizeof(V) - TAG_SYMBOL);
        sljit_emit_op2(c, SLJIT_LSHR, R0, R0, IMM(56));
        sljit_emit_op2(c, SLJIT_AND, R0, R0, IMM(3));
        sljit_emit_op2(c, SLJIT_SHL, HOME(e, dst), R0, IMM(2));
        sljit_set_label(other, sljit_emit_label(c));
        break;
    }
    case P_POS:
    case P_STRING_N:
        /* A string and, for pos, a fixnum index within it: pos returns the
           shared one-byte string from vm->chars, string->n the first byte.
           Anything else, or vm->chars not made yet, goes to C. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R2, R0, TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
        slow->from[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_STRING << 3 | TAG_HEADER));
        sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8)); /* the length */
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V) - TAG_OBJECT));
        if (prim == P_STRING_N) {
            slow->from[2] = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(0));
            sljit_emit_op1(c, SLJIT_MOV_U8, R0, SLJIT_MEM1(SLJIT_R0), 0);
            sljit_emit_op2(c, SLJIT_SHL, HOME(e, dst), R0, IMM(2));
            break;
        }
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
        slow->from[2] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(2)); /* a negative index becomes huge */
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, R2);
        sljit_emit_op1(c, SLJIT_MOV_U8, R0, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0);
        sljit_emit_op1(c, SLJIT_MOV, R2, VMF(chars));
        slow->from[4] = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(V_NIL));
        sljit_emit_op2(c, SLJIT_ADD, R2, R2, IMM(sizeof(V) - TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), SLJIT_MEM2(SLJIT_R2, SLJIT_R0), 3);
        break;
    case P_HASH:
        /* A symbol hashes to its stored name hash modulo the bound, with 0
           taken as 1, as in C; any other key or bound goes to C. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R2, R0, TAG_SYMBOL));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
        slow->from[1] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        slow->from[2] = sljit_emit_cmp(c, SLJIT_SIG_LESS_EQUAL, R1, IMM(0));
        sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(2));
        sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0), SYM_HASH * sizeof(V) - TAG_SYMBOL);
        sljit_emit_op0(c, SLJIT_DIVMOD_UW);
        struct sljit_jump *nonzero = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R1, IMM(1));
        sljit_set_label(nonzero, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_SHL, HOME(e, dst), R1, IMM(2));
        break;
    case P_GET_ADDRESS:
    case P_SET_ADDRESS:
        /* An absvector and a fixnum index within it. Anything else takes the
           slow path, which raises. The index, i << 2, compares unsigned with
           length << 2, and addresses element i at offset (i << 2) << 1. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R2, R0, TAG_OBJECT));
        slow->catch_label = quiet_catch(e); /* C raises wherever these checks fail */
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
        slow->from[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_VECTOR << 3 | TAG_HEADER));
        sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8));
        if (fixnum_operand(e, arg[1]) && (uint64_t)*operand_cell(e, arg[1]) < fix(4096)) {
            /* A small constant index i: the length must exceed it, and the
               element is at a constant offset. */
            sljit_sw i = fixval(*operand_cell(e, arg[1]));
            slow->from[2] = sljit_emit_cmp(c, SLJIT_LESS_EQUAL, R2, IMM(i));
            sljit_sw at = (1 + i) * (sljit_sw)sizeof(V) - TAG_OBJECT;
            if (prim == P_GET_ADDRESS) {
                put_result(e, dst, SLJIT_MEM1(SLJIT_R0), at);
            } else {
                sljit_emit_op1(c, SLJIT_MOV, R2, OPND(e, arg[2]));
                sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), at, R2);
                sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), OPND(e, arg[0]));
            }
            break;
        }
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(3));
        slow->from[2] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        sljit_emit_op2(c, SLJIT_SHL, R2, R2, IMM(2));
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, R2);
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V) - TAG_OBJECT));
        if (prim == P_GET_ADDRESS) {
            put_result(e, dst, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 1);
        } else {
            sljit_emit_op1(c, SLJIT_MOV, R2, OPND(e, arg[2]));
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 1, R2);
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), OPND(e, arg[0]));
        }
        break;
    case P_BYTES_LENGTH:
    case P_U8: case P_U16: case P_U32: case P_S32: case P_F64:
    case P_SET_U8: case P_SET_U16: case P_SET_U32: case P_SET_F64: {
        /* A value to store must fit in the width, and one mask tests that and its tag
           together; f64! takes a real here, and leaves a fixnum to C. */
        e->uncached = prim == P_BYTES_LENGTH;
        slow = emit_memory_base(e, arg[0], SLOW_PRIM, store_prim(prim));
        e->uncached = false;
        if (prim == P_BYTES_LENGTH) {
            sljit_emit_op2(c, SLJIT_SHL, R0, R2, IMM(2));
            store_result(e, dst);
            break;
        }
        static const sljit_s32 mov[] = {SLJIT_MOV_U8, SLJIT_MOV_U16, SLJIT_MOV_U32};
        unsigned size = prim == P_F64 || prim == P_SET_F64 ? 3 : prim == P_S32 ? 2 : (prim - P_U8) % 3;
        emit_memory_index(e, slow, arg[1], size);
        if (prim == P_F64) {
            /* A real holds the word as it is in memory, so this takes no floating point. With
               no room for one, the slow path reads it again and collects. */
            sljit_emit_op2(c, SLJIT_ADD, R3, HP, IMM(REAL_WORDS * sizeof(V)));
            slow->from[4] = sljit_emit_cmp(c, SLJIT_GREATER, R3, VMF(hlimit));
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0);
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), 0, IMM(HEADER(T_REAL, 0)));
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), REAL_VALUE * sizeof(V), R1);
            sljit_emit_op2(c, SLJIT_ADD, R0, HP, IMM(TAG_OBJECT));
            sljit_emit_op1(c, SLJIT_MOV, HP, R3);
            store_result(e, dst);
        } else if (prim == P_SET_F64) {
            sljit_emit_op1(c, SLJIT_MOV, R2, OPND(e, arg[2]));
            slow->from[1] = tag_cmp(c, SLJIT_NOT_EQUAL, R3, R2, TAG_OBJECT);
            sljit_emit_op1(c, SLJIT_MOV_U8, R3, SLJIT_MEM1(SLJIT_R2), -TAG_OBJECT);
            slow->from[4] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_REAL << 3 | TAG_HEADER));
            sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R2), REAL_VALUE * WORD - TAG_OBJECT);
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0, R2);
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), OPND(e, arg[0]));
        } else if (prim <= P_U32 || prim == P_S32) {
            sljit_emit_op1(c, prim == P_S32 ? SLJIT_MOV_S32 : mov[size], R0, SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0);
            sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(2));
            store_result(e, dst);
        } else {
            sljit_emit_op1(c, SLJIT_MOV, R2, OPND(e, arg[2]));
            sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R2, IMM((sljit_sw)~(((UINT64_C(1) << (8 << size)) - 1) << 2)));
            slow->from[4] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
            sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(2));
            sljit_emit_op1(c, mov[size], SLJIT_MEM2(SLJIT_R0, SLJIT_R1), 0, R2);
            sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), OPND(e, arg[0]));
        }
        break;
    }
    case P_PVAR:
        /* One mask tests that the offset is a fixnum and in range. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM((sljit_sw)~(PVAR_MAX_OFFSET << 2)));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_NOT_ZERO));
        slow->catch_label = quiet_catch(e); /* C raises wherever this fails */
        sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(6));
        sljit_emit_op2(c, SLJIT_OR, R0, R0, IMM(PVAR_TAG));
        store_result(e, dst);
        break;
    case P_PVAR_OFFSET:
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op2(c, SLJIT_AND, R1, R0, IMM(0xFF));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(PVAR_TAG)));
        slow->catch_label = quiet_catch(e); /* C raises wherever this fails */
        sljit_emit_op2(c, SLJIT_LSHR, R0, R0, IMM(8));
        sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(2));
        store_result(e, dst);
        break;
    case P_DEREF: {
        /* A value that is no variable is the result, and so is a variable
           with no binding, or what the chain of variables from it ends in.
           Anything else takes the slow path, which raises. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        struct sljit_label *next = sljit_emit_label(c);
        sljit_emit_op2(c, SLJIT_AND, R1, R0, IMM(0xFF));
        struct sljit_jump *plain = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(PVAR_TAG));
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R2, R1, TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R1), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
        slow->from[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_VECTOR << 3 | TAG_HEADER));
        sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8));
        sljit_emit_op2(c, SLJIT_LSHR, R3, R0, IMM(8));
        slow->from[2] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R3, R2);
        sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(sizeof(V) - TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM2(SLJIT_R1, SLJIT_R3), 3);
        struct sljit_jump *unbound = sljit_emit_cmp(c, SLJIT_EQUAL, R1, OPND(e, arg[2]));
        sljit_emit_op2(c, SLJIT_AND, R2, R1, IMM(0xFF));
        sljit_emit_op1(c, SLJIT_MOV, R0, R1);
        sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(PVAR_TAG)), next);
        struct sljit_label *done = sljit_emit_label(c);
        sljit_set_label(plain, done);
        sljit_set_label(unbound, done);
        store_result(e, dst);
        break;
    }
    case P_BIT_AND:
    case P_BIT_OR:
    case P_BIT_XOR: {
        /* A fixnum's tag bits are zero, so these work on the words as they are. */
        static const sljit_s32 op[] = {[P_BIT_AND] = SLJIT_AND, [P_BIT_OR] = SLJIT_OR, [P_BIT_XOR] = SLJIT_XOR};
        sljit_s32 bk;
        sljit_sw bw;
        slow = slow_path(e, SLOW_PRIM, fixnum_operands(e, arg[0], arg[1], &bk, &bw));
        sljit_emit_op2(c, op[prim], R0, R0, bk, bw);
        store_result(e, dst);
        break;
    }
    case P_BIT_NOT:
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_NOT_ZERO));
        sljit_emit_op2(c, SLJIT_XOR, R0, R0, IMM(~(sljit_sw)3));
        store_result(e, dst);
        break;
    case P_SHIFT_LEFT:
    case P_SHIFT_RIGHT:
        /* A count from 0 to 63, which a mask tests along with its tag. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_NOT_ZERO));
        sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1]));
        sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R1, IMM(~(sljit_sw)(63 << 2)));
        slow->from[1] = sljit_emit_jump(c, SLJIT_NOT_ZERO);
        sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(2));
        if (prim == P_SHIFT_LEFT) {
            sljit_emit_op2(c, SLJIT_SHL, R0, R0, R1);
        } else {
            sljit_emit_op2(c, SLJIT_ASHR, R0, R0, R1);
            sljit_emit_op2(c, SLJIT_AND, R0, R0, IMM(~(sljit_sw)3));
        }
        store_result(e, dst);
        break;
    case P_CONS: {
        /* Inline bump allocation; the slow path collects and restarts. The
           first of a run of conses checks the room for all of them, since
           nothing between them can collect; the run restarts from it. */
        if (!e->reserved) {
            size_t n = 2;
            for (size_t i = e->next; i < e->nwords && e->words[i] == OP_PRIM && e->words[i + 2] == P_CONS;
                 i += insn_length(e->words + i))
                n += 2;
            sljit_emit_op2(c, SLJIT_ADD, R1, HP, IMM(n * sizeof(V)));
            Slow *alloc = slow_path(e, SLOW_ALLOC, sljit_emit_cmp(c, SLJIT_GREATER, R1, VMF(hlimit)));
            alloc->words = n;
            alloc->back = restart;
            e->reserved = n;
        }
        e->reserved -= 2;
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), 0, OPND(e, arg[0]));
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), sizeof(V), OPND(e, arg[1]));
        if (to_home(e, dst)) {
            sljit_emit_op2(c, SLJIT_ADD, HOME(e, dst), HP, IMM(TAG_PAIR));
        } else {
            sljit_emit_op2(c, SLJIT_ADD, R0, HP, IMM(TAG_PAIR));
            store_result(e, dst);
        }
        sljit_emit_op2(c, SLJIT_ADD, HP, HP, IMM(2 * sizeof(V)));
        break;
    }
    case P_ABSVECTOR3: {
        /* As for cons: inline bump allocation of the header and three values. */
        sljit_emit_op1(c, SLJIT_MOV, R0, HP);
        sljit_emit_op2(c, SLJIT_ADD, R1, R0, IMM(4 * sizeof(V)));
        Slow *alloc = slow_path(e, SLOW_ALLOC, sljit_emit_cmp(c, SLJIT_GREATER, R1, VMF(hlimit)));
        alloc->words = 4;
        alloc->back = restart;
        sljit_emit_op1(c, SLJIT_MOV, HP, R1);
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), 0, IMM(HEADER(T_VECTOR, 3)));
        for (int i = 0; i < 3; i++)
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), (1 + i) * sizeof(V), OPND(e, arg[i]));
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(TAG_OBJECT));
        store_result(e, dst);
        break;
    }
    case P_VECTORP: {
        struct sljit_jump *no[4];
        slow = slow_path(e, SLOW_PRIM, emit_vector_test(e, arg, no));
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_TRUE));
        struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
        struct sljit_label *false_ = sljit_emit_label(c);
        for (int i = 0; i < 4; i++)
            sljit_set_label(no[i], false_);
        sljit_emit_op1(c, SLJIT_MOV, HOME(e, dst), IMM(V_FALSE));
        sljit_set_label(done, sljit_emit_label(c));
        break;
    }
    case P_TLSTR: {
        /* A new string of all but the first of m+1 bytes, copied a word at a
           time (little-endian): the m >> 3 full words each take the rest of a
           source word and the first byte of the next. Unless m is a positive
           multiple of 8, a last word takes the rest of the last source word,
           whose zero padding becomes its own. Every read is inside the
           source. A string that is empty, or no room in the semispace, goes
           to C. */
        sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, arg[0]));
        slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_NOT_EQUAL, R1, R0, TAG_OBJECT));
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
        sljit_emit_op2(c, SLJIT_AND, R1, R2, IMM(0xFF));
        slow->from[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(T_STRING << 3 | TAG_HEADER));
        sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8));
        slow->from[2] = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(0));
        sljit_emit_op2(c, SLJIT_SUB, R2, R2, IMM(1)); /* m */
        /* The object's size: a header and max(1, ceil(m / 8)) words. */
        sljit_emit_op2(c, SLJIT_ADD, R3, R2, IMM(7));
        sljit_emit_op2(c, SLJIT_LSHR, R3, R3, IMM(3));
        struct sljit_jump *nonempty = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(0));
        sljit_emit_op1(c, SLJIT_MOV, R3, IMM(1));
        sljit_set_label(nonempty, sljit_emit_label(c));
        sljit_emit_op2(c, SLJIT_SHL, R3, R3, IMM(3));
        sljit_emit_op1(c, SLJIT_MOV, R4, HP);
        sljit_emit_op2(c, SLJIT_ADD, R1, R4, R3);
        sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(sizeof(V)));
        slow->from[3] = sljit_emit_cmp(c, SLJIT_GREATER, R1, VMF(hlimit));
        sljit_emit_op1(c, SLJIT_MOV, HP, R1);
        sljit_emit_op2(c, SLJIT_SHL, R3, R2, IMM(8));
        sljit_emit_op2(c, SLJIT_OR, R3, R3, IMM(T_STRING << 3 | TAG_HEADER));
        sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R4), 0, R3);
        sljit_emit_op2(c, SLJIT_ADD, HOME(e, dst), R4, IMM(TAG_OBJECT)); /* R0 keeps the source */
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V) - TAG_OBJECT));
        sljit_emit_op2(c, SLJIT_ADD, R1, R4, IMM(sizeof(V)));
        sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(~(sljit_sw)7));
        sljit_emit_op2(c, SLJIT_ADD, R4, R1, R3); /* the end of the full words */
        struct sljit_label *loop = sljit_emit_aligned_label(c, LOOP_ALIGN, NULL);
        struct sljit_jump *full = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, R4);
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), 0);
        sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8));
        sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM1(SLJIT_R0), sizeof(V));
        sljit_emit_op2(c, SLJIT_SHL, R3, R3, IMM(56));
        sljit_emit_op2(c, SLJIT_OR, SLJIT_MEM1(SLJIT_R1), 0, R2, R3);
        sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V)));
        sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(sizeof(V)));
        sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), loop);
        sljit_set_label(full, sljit_emit_label(c));
        struct sljit_jump *exact = sljit_emit_cmp(c, SLJIT_EQUAL, R1, HP);
        sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), 0);
        sljit_emit_op2(c, SLJIT_LSHR, SLJIT_MEM1(SLJIT_R1), 0, R2, IMM(8));
        sljit_set_label(exact, sljit_emit_label(c));
        break;
    }
    default:
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_JUMP));
        break;
    }
    if (slow) {
        slow->insn = p;
        slow->back = sljit_emit_label(c);
    }
}

/* A Boolean primitive followed by a jump-if-false on its result, when the
   result is dead afterwards: branch on the comparison instead of storing and
   testing a Boolean. */
static bool fusable(uint32_t prim)
{
    return !slow_prims && (prim == P_LT || prim == P_GT || prim == P_LE || prim == P_GE ||
           prim == P_EQ || prim == P_VECTORP || prim == P_ARITYP || prim == P_INLINEDP || type_test(prim));
}

/* An exit test: = with a constant, fused with its branch, whose true branch
   is only a return, as a loop's base case is. Taken the other way round,
   true jumps to the return, out of line, and false falls into the code
   after it (label), so that a loop takes one jump a turn instead of two.
   Returns false, emitting nothing, for any other test. */
static bool emit_exit_test(Emit *e, const uint32_t *p, const uint32_t *ret, uint32_t label)
{
    struct sljit_compiler *c = e->c;
    const uint32_t *arg = p + 4;
    if (p[2] != P_EQ)
        return false;
    if (identity_operand(e, arg[0]) || identity_operand(e, arg[1])) {
        uint32_t k = identity_operand(e, arg[1]) ? 1 : 0;
        slow_path(e, SLOW_RETURN, sljit_emit_cmp(c, SLJIT_EQUAL, OPND(e, arg[1 - k]), OPND(e, arg[k])))->insn = ret;
        return true;
    }
    if (!fixnum_operand(e, arg[0]) && !fixnum_operand(e, arg[1]))
        return false;
    /* As emit_eq: only an object, which may be an equal real, needs C. */
    uint32_t k = fixnum_operand(e, arg[0]) ? 0 : 1;
    sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, arg[1 - k]));
    Slow *exit = slow_path(e, SLOW_RETURN, sljit_emit_cmp(c, SLJIT_EQUAL, R1, OPND(e, arg[k])));
    exit->insn = ret;
    Slow *slow = slow_path(e, SLOW_PRIM, tag_cmp(c, SLJIT_EQUAL, R2, R1, TAG_OBJECT));
    slow->insn = p;
    slow->branch = label;
    slow->exit = exit;
    return true;
}

static void emit_fused(Emit *e, const uint32_t *p, uint32_t label)
{
    static const sljit_s32 when_false[] = {SLJIT_SIG_GREATER_EQUAL, SLJIT_SIG_LESS_EQUAL,
                                           SLJIT_SIG_GREATER, SLJIT_SIG_LESS};
    struct sljit_compiler *c = e->c;
    uint32_t prim = p[2];
    const uint32_t *arg = p + 4;
    Slow *slow = NULL;
    if (prim == P_EQ && (identity_operand(e, arg[0]) || identity_operand(e, arg[1]))) {
        /* The other value where it is, against the constant as an
           immediate where it can be one. */
        uint32_t k = identity_operand(e, arg[1]) ? 1 : 0;
        to_label(e, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, OPND(e, arg[1 - k]), OPND(e, arg[k])), label);
        return;
    }
    if (prim == P_EQ && (string_operand(e, arg[0]) || string_operand(e, arg[1]))) {
        struct sljit_jump *differ[STRING_EQ_WORDS + 3];
        emit_string_eq(e, arg, differ);
        for (int i = 0; differ[i]; i++)
            to_label(e, differ[i], label);
        return;
    }
    if (type_test(prim)) {
        /* A slot read again right after the test, as hd and tl read the pair
           cons? tested, stays in CACHE instead of being loaded each time. */
        if (!(arg[0] & OPERAND_CONST) && arg[0] != e->cached && read_soon(e, arg[0], false)) {
            sljit_emit_op1(c, SLJIT_MOV, CACHE, SLOT(arg[0]));
            e->cached = e->post = arg[0];
        }
        Test t = emit_type_test(e, prim, arg);
        for (int i = 0; i < 4; i++)
            if (t.no[i])
                to_label(e, t.no[i], label);
        if (t.yes)
            sljit_set_label(t.yes, sljit_emit_label(c));
        return;
    }
    struct sljit_jump *same = NULL;
    if (prim == P_ARITYP && arity_operands(e, arg)) {
        struct sljit_jump *no[3];
        emit_arity_test(e, arg, no);
        for (int i = 0; i < 3; i++)
            to_label(e, no[i], label);
        return;
    }
    if (prim == P_INLINEDP && (arg[0] & OPERAND_CONST) && is_symbol(*operand_cell(e, arg[0])) &&
        (arg[1] & OPERAND_CONST)) {
        /* Still the definition whose body follows: on arm64 and x86-64 a nop
           that its redefinition patches, elsewhere a test each time. */
        size_t cell = symbol_cell(*operand_cell(e, arg[0]));
        V f = *cell_function(e->vm, cell), body = *operand_cell(e, arg[1]);
        bool now = is_proc(f) && hdr_type(ptr(f)[0]) == T_CLOSURE && ptr(ptr(f)[CLO_CODE])[CODE_INLINE] == body;
        if (!now) {
            to_label(e, sljit_emit_jump(c, SLJIT_JUMP), label);
        } else if (PATCH_SELF) {
            reach_label(e, label);
            e->guards[e->nguards].at = sljit_emit_label(c);
            emit_patch_nop(c);
            Slow *stub = slow_path(e, SLOW_GUARD, NULL);
            stub->branch = label;
            e->guards[e->nguards].stub = stub;
            e->guards[e->nguards++].cell = cell;
        } else {
            struct sljit_jump *no[3];
            emit_inlined_test(e, cell, arg[1], no);
            for (int i = 0; i < 3; i++)
                to_label(e, no[i], label);
        }
        return;
    }
    if (prim == P_ARITYP || prim == P_INLINEDP) {
        slow = slow_path(e, SLOW_PRIM, sljit_emit_jump(c, SLJIT_JUMP));
    } else if (prim == P_VECTORP) {
        struct sljit_jump *no[4];
        slow = slow_path(e, SLOW_PRIM, emit_vector_test(e, arg, no));
        for (int i = 0; i < 4; i++)
            to_label(e, no[i], label);
    } else if (prim == P_EQ) {
        struct sljit_jump *plain;
        slow = slow_path(e, SLOW_PRIM, emit_eq(e, arg, &same, &plain));
        if (plain)
            to_label(e, plain, label);
        to_label(e, sljit_emit_jump(c, SLJIT_JUMP), label);
    } else {
        sljit_s32 bk;
        sljit_sw bw;
        slow = slow_path(e, SLOW_PRIM, fixnum_operands(e, arg[0], arg[1], &bk, &bw));
        to_label(e, sljit_emit_cmp(c, when_false[prim - P_LT], R0, bk, bw), label);
    }
    slow->insn = p;
    slow->branch = label;
    slow->back = sljit_emit_label(c);
    if (same)
        sljit_set_label(same, slow->back);
}

static bool reads_slot(const uint32_t *p, uint32_t s)
{
    switch (p[0]) {
    case OP_MOVE: return p[2] == s;
    case OP_CAPTURE: return s == 1;
    case OP_CLOSURE:
    case OP_PRIM:
    case OP_REAL_LOAD:
    case OP_REAL_STORE:
        for (uint32_t i = 0; i < p[3]; i++)
            if (p[4 + i] == s)
                return true;
        return false;
    case OP_JUMP_IF_FALSE:
    case OP_JUMP_UNLESS_ENTRY:
    case OP_RETURN: return p[1] == s;
    case OP_CALL:
    case OP_CALL_SEALED: return s >= p[2] + 2 && s < p[2] + 2 + p[4];
    case OP_CALL_VALUE: return s >= p[2] + 1 && s < p[2] + 2 + p[3];
    case OP_TAIL_CALL:
    case OP_TAIL_CALL_SEALED: return s >= p[1] + 2 && s < p[1] + 2 + p[3];
    case OP_TAIL_CALL_VALUE: return s >= p[1] + 1 && s < p[1] + 2 + p[2];
    default: {
        const char *kinds = raw_kinds(p[0]);
        for (size_t i = 0; kinds && kinds[i]; i++)
            if (kinds[i] == 'o' && p[1 + i] == s)
                return true;
        return false;
    }
    }
}

static bool writes_slot(const uint32_t *p, uint32_t s)
{
    switch (p[0]) {
    case OP_MOVE: case OP_CONST: case OP_CAPTURE: case OP_CLOSURE: case OP_PRIM:
    case OP_CALL: case OP_CALL_SEALED: case OP_CALL_VALUE: case OP_EXCEPTION: case OP_REAL_BOX: case OP_WORD_BOX:
        return p[1] == s;
    default: return false;
    }
}

/* Whether slot s is written before it is read on every path from the two
   successors of a jump-if-false, or from after alone when target is NONE.
   It visits each instruction once, so the walk ends, also round a loop. */
static bool dead_after(Emit *e, size_t after, uint32_t target, uint32_t s)
{
    const uint32_t *w = e->words;
    const size_t *label_pos = e->label_pos;
    size_t n = e->nwords, *todo = e->todo, ntodo = 0;
    unsigned char *seen = e->seen;
    bool dead = seen && todo;
    if (dead) {
        memset(seen, 0, n);
        todo[ntodo++] = after;
        if (target != NONE)
            todo[ntodo++] = label_pos[target];
    }
    while (dead && ntodo) {
        size_t i = todo[--ntodo];
        if (i >= n || seen[i])
            continue;
        seen[i] = 1;
        const uint32_t *p = w + i;
        if (reads_slot(p, s))
            dead = false;
        else if (!writes_slot(p, s)) {
            size_t next = i + insn_length(p);
            switch (p[0]) {
            case OP_RETURN: case OP_TAIL_CALL: case OP_TAIL_CALL_SEALED: case OP_TAIL_CALL_VALUE:
                break;
            case OP_JUMP: case OP_AGAIN: todo[ntodo++] = label_pos[p[1]]; break;
            case OP_JUMP_IF_FALSE: case OP_ENTRY:
                todo[ntodo++] = next;
                todo[ntodo++] = label_pos[p[2]];
                break;
            case OP_JUMP_UNLESS_ENTRY: todo[ntodo++] = next; todo[ntodo++] = label_pos[p[3]]; break;
            case OP_PUSH_HANDLER: todo[ntodo++] = next; todo[ntodo++] = label_pos[p[1]]; break;
            default:
                todo[ntodo++] = next;
                if (raw_kinds(p[0]) && strchr(raw_kinds(p[0]), 'l'))
                    todo[ntodo++] = label_pos[p[3]];
            }
            if (ntodo > n)
                dead = false; /* the stack is full, so assume the worst */
        }
    }
    return dead;
}

static void go_back(Emit *e, const Slow *s)
{
    if (s->exit) { /* an exit test's true: its return, emitted before this */
        sljit_set_label(sljit_emit_jump(e->c, SLJIT_JUMP), s->exit->start);
        return;
    }
    if (s->restore != NONE)
        sljit_emit_op1(e->c, SLJIT_MOV, CACHE, SLOT(s->restore));
    for (int k = 0; k < KEPT; k++)
        if (s->kept[k] != NONE)
            sljit_emit_op1(e->c, SLJIT_MOV, KEPT_REG(k), 0, SLOT(s->kept[k]));
    sljit_set_label(sljit_emit_jump(e->c, SLJIT_JUMP), s->back);
}

static void emit_slow_paths(Emit *e)
{
    struct sljit_compiler *c = e->c;
    for (size_t i = 0; i < e->nslow; i++) {
        Slow *s = &e->slow[i];
        struct sljit_label *here = s->start = sljit_emit_label(c);
        for (int j = 0; j < 5; j++)
            if (s->from[j])
                sljit_set_label(s->from[j], here);
        switch (s->kind) {
        case SLOW_POINTER:
            /* Not a byte buffer, with its header in R2 and that's low byte in R3. A pointer goes
               back to the byte primitive with its length and base, and the rest to raise. A store
               tests the whole header, which a read-only pointer's differs in. */
            sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, s->store ? SLJIT_R2 : SLJIT_R3, 0,
                                           IMM(T_POINTER << 3 | TAG_HEADER)), s->prim->start);
            sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), POINTER_LENGTH * (sljit_sw)sizeof(V) - TAG_OBJECT);
            sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0), POINTER_ADDRESS * (sljit_sw)sizeof(V) - TAG_OBJECT);
            go_back(e, s);
            break;
        case SLOW_PRIM: {
            const uint32_t *p = s->insn;
            if (s->catch_label != NONE) {
                jump_to_catch(e, s->catch_label);
                break;
            }
            struct sljit_jump *differ[3] = {NULL, NULL, NULL}, *same[2] = {NULL, NULL};
            bool compare = !slow_prims && (p[2] == P_LT || p[2] == P_GT || p[2] == P_LE || p[2] == P_GE);
            if (compare || (!slow_prims && (p[2] == P_ADD || p[2] == P_SUB || p[2] == P_MUL || p[2] == P_DIV))) {
                /* With a real among the operands, the work is done here. What is left is for
                   the dispatcher: what is not a number, division by zero, no room for the
                   result, two fixnums, which overflowed or divide exactly, and comparing a
                   real with a fixnum that a double may not hold. */
                static const sljit_s32 fop[] = {[P_ADD] = SLJIT_ADD_F64, [P_SUB] = SLJIT_SUB_F64,
                                                [P_MUL] = SLJIT_MUL_F64, [P_DIV] = SLJIT_DIV_F64};
                static const sljit_s32 ftype[] = {[P_LT] = SLJIT_ORDERED_LESS, [P_GT] = SLJIT_ORDERED_GREATER,
                                                  [P_LE] = SLJIT_ORDERED_LESS_EQUAL,
                                                  [P_GE] = SLJIT_ORDERED_GREATER_EQUAL};
                struct sljit_jump *other[9] = {NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL};
                if (!compare) {
                    sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, p[4]));
                    sljit_emit_op2(c, SLJIT_OR, R0, R0, OPND(e, p[5]));
                    sljit_emit_op2u(c, SLJIT_AND | SLJIT_SET_Z, R0, IMM(3));
                    other[0] = sljit_emit_jump(c, SLJIT_ZERO);
                }
                load_number(e, p[4], SLJIT_FR0, other + 1, compare ? other + 7 : NULL);
                load_number(e, p[5], SLJIT_FR1, other + 3, compare ? other + 8 : NULL);
                if (compare) {
                    same[0] = sljit_emit_fcmp(c, ftype[p[2]], SLJIT_FR0, 0, SLJIT_FR1, 0);
                    differ[0] = sljit_emit_jump(c, SLJIT_JUMP);
                } else {
                    if (p[2] == P_DIV) {
                        sljit_emit_fset64(c, SLJIT_FR2, 0.0);
                        other[5] = sljit_emit_fcmp(c, SLJIT_ORDERED_EQUAL, SLJIT_FR1, 0, SLJIT_FR2, 0);
                    }
                    sljit_emit_op2(c, SLJIT_ADD, R0, HP, IMM(REAL_WORDS * sizeof(V)));
                    other[6] = sljit_emit_cmp(c, SLJIT_GREATER, R0, VMF(hlimit));
                    sljit_emit_fop2(c, fop[p[2]], SLJIT_FR0, 0, SLJIT_FR0, 0, SLJIT_FR1, 0);
                    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_S3), 0, IMM(HEADER(T_REAL, 0)));
                    sljit_emit_fop1(c, SLJIT_MOV_F64, SLJIT_MEM1(SLJIT_S3), REAL_VALUE * WORD, SLJIT_FR0, 0);
                    sljit_emit_op2(c, SLJIT_ADD, HOME(e, p[1]), HP, IMM(TAG_OBJECT));
                    sljit_emit_op1(c, SLJIT_MOV, HP, R0);
                    go_back(e, s);
                }
                struct sljit_label *dispatch = sljit_emit_label(c);
                for (int j = 0; j < 9; j++)
                    sljit_set_label(other[j], dispatch);
            }
            if (!slow_prims && p[2] == P_EQ && (fixnum_operand(e, p[4]) || fixnum_operand(e, p[5]))) {
                /* Against a fixnum constant the value here is an object,
                   which can be equal only as a real. */
                uint32_t k = fixnum_operand(e, p[4]) ? 0 : 1;
                sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, p[5 - k]));
                sljit_emit_op1(c, SLJIT_MOV_U8, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
                if (s->branch == UINT32_MAX) { /* any other object is unequal: back at once */
                    struct sljit_jump *real = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(T_REAL << 3 | TAG_HEADER));
                    sljit_emit_op1(c, SLJIT_MOV, HOME(e, p[1]), IMM(V_FALSE));
                    go_back(e, s);
                    sljit_set_label(real, sljit_emit_label(c));
                } else {
                    differ[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(T_REAL << 3 | TAG_HEADER));
                }
                sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, p[4 + k]));
                call_leaf(e, SLJIT_ARGS2(W, W, W), (void *)h_equal);
            } else if (!slow_prims && p[2] == P_EQ) {
                /* Before calling C: two objects with different headers
                   (types or lengths), or a fixnum and an object that is not
                   a real, are not equal. Here the values are two pairs, two
                   objects, or a fixnum and an object. */
                sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, p[4]));
                sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, p[5]));
                sljit_emit_op2(c, SLJIT_AND, R2, R0, IMM(7));
                struct sljit_jump *pairs = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(TAG_PAIR));
                struct sljit_jump *object = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(TAG_OBJECT));
                sljit_emit_op1(c, SLJIT_MOV, R2, R0); /* put the object in R0 */
                sljit_emit_op1(c, SLJIT_MOV, R0, R1);
                sljit_emit_op1(c, SLJIT_MOV, R1, R2);
                sljit_set_label(object, sljit_emit_label(c));
                sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_OBJECT);
                struct sljit_jump *two = tag_cmp(c, SLJIT_EQUAL, R3, R1, TAG_OBJECT);
                sljit_emit_op2(c, SLJIT_AND, R2, R2, IMM(0xFF));
                differ[0] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(T_REAL << 3 | TAG_HEADER));
                struct sljit_jump *real = sljit_emit_jump(c, SLJIT_JUMP);
                sljit_set_label(two, sljit_emit_label(c));
                differ[1] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, SLJIT_MEM1(SLJIT_R1), -TAG_OBJECT);
                /* Two strings with the same header: compare the words, whose
                   padding is always 0. */
                sljit_emit_op2(c, SLJIT_AND, R3, R2, IMM(0xFF));
                struct sljit_jump *other = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, IMM(T_STRING << 3 | TAG_HEADER));
                sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(8));
                sljit_emit_op2(c, SLJIT_ADD, R2, R2, IMM(7));
                sljit_emit_op2(c, SLJIT_LSHR, R2, R2, IMM(3));
                sljit_emit_op2(c, SLJIT_SHL, R2, R2, IMM(3));
                sljit_emit_op2(c, SLJIT_ADD, R2, R2, R0); /* where R0 ends */
                struct sljit_label *word = sljit_emit_aligned_label(c, LOOP_ALIGN, NULL);
                same[0] = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, R2);
                sljit_emit_op1(c, SLJIT_MOV, R3, SLJIT_MEM1(SLJIT_R0), sizeof(V) - TAG_OBJECT);
                differ[2] = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R3, SLJIT_MEM1(SLJIT_R1), sizeof(V) - TAG_OBJECT);
                sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(sizeof(V)));
                sljit_emit_op2(c, SLJIT_ADD, R1, R1, IMM(sizeof(V)));
                sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), word);
                /* Two pairs: walk the tails while the heads are identical.
                   Loop heads are aligned, as function bodies are. */
                struct sljit_label *pair = sljit_emit_aligned_label(c, LOOP_ALIGN, NULL);
                sljit_set_label(pairs, pair);
                sljit_emit_op1(c, SLJIT_MOV, R2, SLJIT_MEM1(SLJIT_R0), -TAG_PAIR);
                struct sljit_jump *heads = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, SLJIT_MEM1(SLJIT_R1), -TAG_PAIR);
                sljit_emit_op1(c, SLJIT_MOV, R0, SLJIT_MEM1(SLJIT_R0), sizeof(V) - TAG_PAIR);
                sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R1), sizeof(V) - TAG_PAIR);
                same[1] = sljit_emit_cmp(c, SLJIT_EQUAL, R0, R1);
                struct sljit_jump *end0 = tag_cmp(c, SLJIT_NOT_EQUAL, R2, R0, TAG_PAIR);
                sljit_set_label(tag_cmp(c, SLJIT_EQUAL, R2, R1, TAG_PAIR), pair);
                struct sljit_label *call = sljit_emit_label(c);
                sljit_set_label(other, call);
                sljit_set_label(heads, call);
                sljit_set_label(end0, call);
                sljit_set_label(real, call);
                call_leaf(e, SLJIT_ARGS2(W, W, W), (void *)h_equal);
            } else {
                publish(e);
                for (uint32_t k = 0; k < p[3]; k++)
                    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(VMR),
                                   (sljit_sw)(offsetof(VM, args) + k * sizeof(V)), OPND(e, p[4 + k]));
                sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
                sljit_emit_op1(c, SLJIT_MOV, R1, IMM(p[2]));
                call_c_raising(e, s, SLJIT_ARGS2(W, P, W), (void *)h_prim);
                if (p[0] != OP_PRIM) { /* a real register's: it only comes here to raise */
                    to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
                    break;
                }
                check_raise(e);
                fill(e);
            }
            if (s->branch == UINT32_MAX)
                sljit_emit_op1(c, SLJIT_MOV, HOME(e, p[1]), R0);
            else { /* fused with a branch: these primitives return Booleans */
                load_for_label(e, s->branch);
                to_label(e, sljit_emit_cmp(c, SLJIT_EQUAL, R0, IMM(V_FALSE)), s->branch);
            }
            go_back(e, s);
            if (same[0]) {
                struct sljit_label *yes = sljit_emit_label(c);
                sljit_set_label(same[0], yes);
                sljit_set_label(same[1], yes);
                if (s->branch == UINT32_MAX)
                    sljit_emit_op1(c, SLJIT_MOV, HOME(e, p[1]), IMM(V_TRUE));
                go_back(e, s);
            }
            if (differ[0]) {
                struct sljit_label *no = sljit_emit_label(c);
                sljit_set_label(differ[0], no);
                sljit_set_label(differ[1], no);
                sljit_set_label(differ[2], no);
                if (s->branch == UINT32_MAX) {
                    sljit_emit_op1(c, SLJIT_MOV, HOME(e, p[1]), IMM(V_FALSE));
                    go_back(e, s);
                } else {
                    load_for_label(e, s->branch);
                    to_label(e, sljit_emit_jump(c, SLJIT_JUMP), s->branch);
                }
            }
            break;
        }
        case SLOW_RESOLVE:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM(s->words));
            call_c(c, SLJIT_ARGS2(W, P, P), (void *)h_resolve);
            check_raise(e);
            fill(e);
            sljit_emit_op1(c, SLJIT_MOV, R1, R0);
            sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), s->back);
            break;
        case SLOW_ALLOC:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM(s->words));
            call_c(c, SLJIT_ARGS2(W, P, W), (void *)h_alloc);
            check_raise(e);
            fill(e);
            go_back(e, s);
            break;
        case SLOW_BOOLEAN:
            if (s->catch_label != NONE) {
                jump_to_catch(e, s->catch_label);
                break;
            }
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, s->insn[1]));
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            call_c_raising(e, s, SLJIT_ARGS2(W, P, W), (void *)h_boolean_error);
            to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
            break;
        case SLOW_NOT_NUMBER:
        case SLOW_NOT_INTEGER:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, s->insn[2]));
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            call_c_raising(e, s, SLJIT_ARGS2(W, P, W), s->kind == SLOW_NOT_NUMBER ? (void *)h_not_number : (void *)h_not_integer);
            to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
            break;
        case SLOW_TOO_BIG:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R1, WORD_OPERAND(e, s->insn[2]));
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            call_c_raising(e, s, SLJIT_ARGS2(W, P, W), (void *)h_too_big);
            to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
            break;
        case SLOW_MEMORY:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R1, OPND(e, s->memory));
            sljit_emit_op1(c, SLJIT_MOV, R2, WORD_OPERAND(e, s->index));
            sljit_emit_op1(c, SLJIT_MOV, R3, IMM(s->store));
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            call_c_raising(e, s, SLJIT_ARGS4(W, P, W, W, W), (void *)h_memory_error);
            to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
            break;
        case SLOW_NOT_PROC:
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R2, IMM(s->words));
            call_c_raising(e, s, SLJIT_ARGS3(W, P, W, W), (void *)h_not_procedure);
            to_unwind(e, sljit_emit_jump(c, SLJIT_JUMP));
            break;
        case SLOW_RETURN:
            /* An exit test's return, out of the way of the code after it. */
            sljit_emit_op1(c, SLJIT_MOV, R0, OPND(e, s->insn[1]));
            sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_MEM1(FP), 0);
            break;
        case SLOW_GUARD:
            /* The inlined callee was redefined: take the call. */
            load_for_label(e, s->branch);
            to_label(e, sljit_emit_jump(c, SLJIT_JUMP), s->branch);
            break;
        case SLOW_GROW:
            /* The frame is not set up yet: only the window is live. */
            sljit_emit_op1(c, SLJIT_MOV, VMF(fp), FP, 0);
            sljit_emit_op2(c, SLJIT_ADD, R3, FP, 0, IMM((s->words + 2) * sizeof(V)));
            sljit_emit_op1(c, SLJIT_MOV, VMF(top), R3);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM(e->frame + LEAF_FRAME));
            call_c(c, SLJIT_ARGS2(W, P, W), (void *)h_grow);
            check_raise(e);
            sljit_emit_op1(c, SLJIT_MOV, FP, 0, VMF(fp));
            if (s->words) /* the body expects the first argument in CACHE */
                sljit_emit_op1(c, SLJIT_MOV, CACHE, SLOT(2));
            sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), s->back);
            break;
        case SLOW_LOOP:
            /* A loop's check, with the arguments in place: another thread may
               collect here, so all that is live goes to the frame and back. */
            if (e->entry == 2)
                sljit_emit_op1(c, SLJIT_MOV, HOME(e, 2), CACHE);
            publish(e);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM(e->frame + LEAF_FRAME));
            call_c(c, SLJIT_ARGS2(W, P, W), (void *)h_grow);
            check_raise(e);
            sljit_emit_op1(c, SLJIT_MOV, FP, 0, VMF(fp));
            fill(e);
            if (e->entry == 2)
                sljit_emit_op1(c, SLJIT_MOV, CACHE, HOME(e, 2));
            sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), s->back);
            break;
        }
    }
}

/* Code that calls nothing. With tails, tail calls do not count: they run
   their callee in this frame's place, and the callee checks its own frame.
   Without, they do, since functions that call each other in tail position
   loop, and the entry check is where such a loop sees an interrupt. */
static bool leaf(const uint32_t *words, size_t nwords, bool tails)
{
    for (size_t i = 0; i < nwords; i += insn_length(words + i))
        switch (words[i]) {
        case OP_CALL: case OP_CALL_SEALED: case OP_CALL_VALUE:
            return false;
        case OP_TAIL_CALL: case OP_TAIL_CALL_SEALED: case OP_TAIL_CALL_VALUE:
            if (!tails)
                return false;
        }
    return true;
}

/* Takes the (inline F N) markers out of the n words, compacting them, and
   returns their regions in the code that remains, in the order of their
   starts (outer first): {start, end, cell} each, in a malloc'd *out. */
static size_t strip_marks(uint32_t *words, size_t *n, void **out)
{
    size_t count = 0;
    for (size_t i = 0; i < *n; i += insn_length(words + i))
        count += words[i] == OP_INLINE;
    *out = NULL;
    if (!count)
        return 0;
    size_t *marks = malloc(3 * count * sizeof *marks), *ends = malloc(count * sizeof *ends);
    uint32_t *to = malloc((*n + 1) * sizeof *to); /* each old offset's new one */
    if (!marks || !ends || !to) {
        free(marks), free(ends), free(to);
        return 0; /* the markers then stay, which only slows the code */
    }
    size_t k = 0, kept = 0;
    for (size_t i = 0; i < *n; i += insn_length(words + i))
        if (words[i] == OP_INLINE) { /* its region ends N instructions on */
            size_t end = i + insn_length(words + i);
            for (uint32_t j = 0; j < words[i + 2] && end < *n; j++)
                end += insn_length(words + end);
            marks[3 * k + 2] = words[i + 1];
            ends[k++] = end;
        }
    k = 0;
    for (size_t i = 0; i < *n;) {
        size_t len = insn_length(words + i);
        to[i] = (uint32_t)kept;
        if (words[i] == OP_INLINE)
            marks[3 * k++] = kept;
        else {
            memmove(words + kept, words + i, len * sizeof *words);
            kept += len;
        }
        i += len;
    }
    to[*n] = (uint32_t)kept;
    for (size_t j = 0; j < count; j++)
        marks[3 * j + 1] = to[ends[j]];
    *n = kept;
    free(ends);
    free(to);
    *out = marks;
    return count;
}

static void *compile_code(VM *vm, V code)
{
    uint64_t *co = ptr(code);
    V bytecode = co[CODE_BYTECODE];
    uint32_t *words = malloc((string_length(bytecode) + 1) * sizeof *words);
    if (!words)
        return NULL;
    size_t nwords = bytecode_unpack((const uint8_t *)string_bytes(bytecode), string_length(bytecode), words);
    /* (inline F N) marks out inlined bodies for backtraces: they are taken
       out, so that every analysis sees the code as without them, and kept
       as regions of the instructions that remain. */
    struct {
        size_t start, end, cell;
    } *marks = NULL;
    size_t nmarks = strip_marks(words, &nwords, (void **)&marks);

    uint32_t nlabels = 0;
    size_t ninsns = 0;
    for (size_t i = 0; i < nwords; i += insn_length(words + i), ninsns++)
        if ((words[i] == OP_LABEL || words[i] == OP_LOOP) && words[i + 1] + 1 > nlabels)
            nlabels = words[i + 1] + 1;
    size_t *label_pos = calloc(nlabels + 1, sizeof *label_pos);
    if (label_pos)
        for (size_t i = 0; i < nwords; i += insn_length(words + i))
            if (words[i] == OP_LABEL || words[i] == OP_LOOP)
                label_pos[words[i + 1]] = i;

    Emit e = {.vm = vm, .c = sljit_create_compiler(NULL), .frame = co[CODE_FRAME],
              .arity = co[CODE_ARITY] & UINT32_MAX, .cbase = co[CODE_CBASE], .nconst = co[CODE_NCONST],
              .code = code, .cached = NONE, .post = NONE, .kept = {NONE, NONE}, .kept_post = {NONE, NONE},
              .entry = NONE, .label_pos = label_pos};
    e.seen = calloc(nwords + 1, sizeof *e.seen);
    e.todo = malloc((nwords + 2) * sizeof *e.todo);
    e.labels = calloc(nlabels + 1, sizeof *e.labels);
    e.fixups = calloc(6 * ninsns + 2, sizeof *e.fixups);
    e.handlers = calloc(ninsns + 1, sizeof *e.handlers);
    e.calls = calloc(ninsns + 1, sizeof *e.calls);
    e.selfs = calloc(ninsns + 1, sizeof *e.selfs);
    e.guards = calloc(ninsns + 1, sizeof *e.guards);
    e.raises = calloc(2 * ninsns + 2, sizeof *e.raises);
    e.slow = calloc(2 * ninsns + 2, sizeof *e.slow);
    e.at_label = calloc(nlabels + 1, sizeof *e.at_label);
    struct sljit_compiler *c = e.c;
    void *native = NULL, *generated = NULL;
    if (!c || !e.labels || !e.fixups || !e.slow || !e.calls || !label_pos || !e.at_label || !e.handlers ||
        !e.selfs || !e.guards || !e.raises)
        goto done;
    sljit_set_context(c, 0, ARG_TYPES, SCRATCHES, SAVEDS, LOCALS);

    /* Entry: check the argument count and that the frame fits. A lambda
       that returns lambdas also takes all their arguments at once (entry N
       L, first): that call goes to label L, with the arguments in slots 2
       to N+1 and the first in CACHE, and nothing cached there yet. */
    struct sljit_label *entry = sljit_emit_label(c);
    uint64_t all = co[CODE_ARITY] >> 32;
    struct sljit_jump *one = NULL;
    if (all) {
        one = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(e.arity));
        sljit_set_target(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(all)), (sljit_uw)vm->jit->arity);
        sljit_emit_op2(c, SLJIT_ADD, R0, FP, 0, IMM((e.frame + LEAF_FRAME) * sizeof(V)));
        Slow *s = slow_path(&e, SLOW_GROW, sljit_emit_cmp(c, SLJIT_GREATER, R0, VMF(check_limit)));
        s->words = all;
        s->back = sljit_emit_label(c);
        e.cached = NONE;
        to_label(&e, sljit_emit_jump(c, SLJIT_JUMP), (uint32_t)words[2]);
        sljit_set_label(one, sljit_emit_label(c));
    } else {
        sljit_set_target(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R2, IMM(e.arity)),
                         (sljit_uw)vm->jit->arity);
    }
    /* Every frame that calls reserves a leaf's frame beyond its own, so code
       that calls nothing, with a frame no larger, needs no check: it runs
       below a caller's reservation, or jit_call's margin. Unless the REPL
       catches Ctrl-C, tail calls do not count. */
    Slow *grow = NULL;
    if (!leaf(words, nwords, !vm->interruptible) || e.frame > LEAF_FRAME) {
        sljit_emit_op2(c, SLJIT_ADD, R0, FP, 0, IMM((e.frame + LEAF_FRAME) * sizeof(V)));
        grow = slow_path(&e, SLOW_GROW, sljit_emit_cmp(c, SLJIT_GREATER, R0, VMF(check_limit)));
        grow->words = e.arity;
    }
    /* A loop that keeps its slots in registers loads them first. The body
       is where self tail calls loop to: aligned when they do, so that a
       tight loop's speed does not depend on where the code before it ends,
       and plain otherwise, so that a call runs no padding. */
    e.homes = home_count(&e, words, nwords);
    count_registers(&e, words, nwords);
    choose_cached_memory(&e, words, nwords);
    assign_places(&e, words, nwords);
    e.keeps = !e.homes && !e.reals && !e.word_regs && !e.nmemory && !e.raw_saved && SAVED_HOMES >= KEPT;
    struct sljit_label *start = sljit_emit_label(c);
    enter(&e);
    emit_memory_caches(&e);
    e.loops = loops(&e, words, nwords) || raw_loop(words, nwords);
    e.body = e.loops ? sljit_emit_aligned_label(c, LOOP_ALIGN, NULL) : sljit_emit_label(c);
    if (grow)
        grow->back = e.homes || e.nmemory ? start : e.body;

    e.words = words;
    e.nwords = nwords;
    e.next = 0;
    /* Not past a branch: the first branch of a loop usually leads to its
       exit, and what that reads does not count. */
    e.cached = e.entry = e.arity && !raw_loop(words, nwords) && read_soon(&e, 2, false) ? 2 : NONE;
    bool falls = true;
    size_t mark = 0;
    for (size_t i = 0; i < nwords; i += insn_length(words + i)) {
        const uint32_t *p = words + i;
        uint32_t pre = e.cached;
        size_t first_slow = e.nslow;
        while (e.ninl && e.inl_end[e.ninl - 1] <= i) { /* past the end of an inlined body */
            e.ninl--;
            e.chain = 0;
        }
        for (; mark < nmarks && marks[mark].start <= i; mark++) /* the bodies that start here */
            if (e.ninl < 8 && marks[mark].end > i) {
                e.inl_cell[e.ninl] = marks[mark].cell;
                e.inl_end[e.ninl++] = marks[mark].end;
                e.chain = 0;
            }
        e.post = NONE;
        e.next = i + insn_length(p);
        for (int k = 0; k < KEPT; k++)
            e.kept_post[k] = keeps_cache(p) && !writes_slot(p, e.kept[k]) ? e.kept[k] : NONE;
        const uint32_t kept_pre[KEPT] = {e.kept[0], e.kept[1]};
        switch (p[0]) {
        case OP_MOVE:
            put_result(&e, p[1], OPND(&e, p[2]));
            break;
        case OP_CONST: {
            V *cell = ra_at(&vm->consts, e.cbase + p[2]);
            if (is_ptr(*cell))
                put_result(&e, p[1], SLJIT_MEM0(), (sljit_sw)cell);
            else
                put_result(&e, p[1], IMM(*cell));
            break;
        }
        case OP_CAPTURE:
            sljit_emit_op1(c, SLJIT_MOV, R0, SLOT(1));
            put_result(&e, p[1], SLJIT_MEM1(SLJIT_R0), (sljit_sw)((CLO_CAPS + p[2]) * sizeof(V)) - TAG_PROC);
            break;
        case OP_CLOSURE: {
            /* Inline bump allocation, as for cons. The entry is the code's
               native code once compiled, so later closures skip the stub. */
            uint32_t n = p[3];
            struct sljit_label *restart = sljit_emit_label(c);
            sljit_emit_op1(c, SLJIT_MOV, R0, HP);
            sljit_emit_op2(c, SLJIT_ADD, R1, R0, IMM((CLO_CAPS + n) * sizeof(V)));
            Slow *alloc = slow_path(&e, SLOW_ALLOC, sljit_emit_cmp(c, SLJIT_GREATER, R1, VMF(hlimit)));
            alloc->words = CLO_CAPS + n;
            alloc->back = restart;
            sljit_emit_op1(c, SLJIT_MOV, HP, R1);
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), 0, IMM(HEADER(T_CLOSURE, n)));
            V *code_cell = ra_at(&vm->consts, e.cbase + e.nconst + p[2]);
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM0(), (sljit_sw)code_cell);
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), CLO_CODE * sizeof(V), R1);
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R1), CODE_NATIVE * sizeof(V) - TAG_OBJECT);
            struct sljit_jump *compiled = sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(0));
            sljit_emit_op1(c, SLJIT_MOV, R1, IMM(vm->compile_stub));
            sljit_set_label(compiled, sljit_emit_label(c));
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), PROC_ENTRY * sizeof(V), R1);
            for (uint32_t i = 0; i < n; i++) {
                sljit_emit_op1(c, SLJIT_MOV, R1, HOME(&e, p[4 + i]));
                sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), (CLO_CAPS + i) * sizeof(V), R1);
            }
            sljit_emit_op2(c, SLJIT_ADD, R0, R0, IMM(TAG_PROC));
            store_result(&e, p[1]);
            break;
        }
        case OP_PRIM: {
            const uint32_t *next = p + insn_length(p);
            size_t after = i + insn_length(p);
            if (fusable(p[2]) && after < nwords && next[0] == OP_JUMP_IF_FALSE &&
                next[1] == p[1] &&
                dead_after(&e, after + insn_length(next), next[2], p[1])) {
                /* An exit test, in code that loops: the jump's fall-through
                   is only a return, followed by the label it jumps to.
                   Elsewhere the return is as likely as the rest, as in the
                   clauses of a pattern. */
                const uint32_t *ret = next + insn_length(next);
                size_t ret_at = after + insn_length(next);
                size_t label_at = ret_at < nwords ? ret_at + insn_length(ret) : nwords;
                if (e.loops && ret_at < nwords && ret[0] == OP_RETURN && label_at < nwords &&
                    words[label_at] == OP_LABEL && words[label_at + 1] == next[2]) {
                    e.next = label_at;
                    if (emit_exit_test(&e, p, ret, next[2])) {
                        e.post = e.cached; /* the test leaves CACHE as it is */
                        i = ret_at;        /* the loop then steps over the return */
                        break;
                    }
                }
                e.next = after + insn_length(next);
                emit_fused(&e, p, next[2]);
                i = after; /* the loop then steps over the jump */
                if (p[2] == P_CONSP && p[4] < 64)
                    e.pairs |= UINT64_C(1) << p[4];
            } else {
                emit_prim(&e, p);
            }
            break;
        }
        case OP_LABEL:
            e.labels[p[1]] = sljit_emit_label(c);
            if (falls)
                reach_label(&e, p[1]);
            e.post = e.at_label[p[1]].seen ? e.at_label[p[1]].cached : NONE;
            for (int k = 0; k < KEPT; k++)
                e.kept_post[k] = e.at_label[p[1]].seen ? e.at_label[p[1]].kept[k] : NONE;
            break;
        case OP_JUMP:
            to_label(&e, sljit_emit_jump(c, SLJIT_JUMP), p[1]);
            break;
        case OP_ENTRY: /* dispatched at entry */
            break;
        case OP_INLINE: /* left only if strip_marks could not allocate */
            break;
        case OP_LOOP: /* nothing is assumed of CACHE here, as a jump back has it as it may */
            e.labels[p[1]] = sljit_emit_aligned_label(c, LOOP_ALIGN, NULL);
            e.post = NONE;
            break;
        case OP_AGAIN:
            emit_loop_check(&e);
            sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), e.labels[p[1]]);
            break;
        default:
            emit_raw(&e, p);
            break;
        case OP_JUMP_UNLESS_ENTRY: {
            /* Falls through only for a closure whose code takes p[2]
               arguments at once (OP_ENTRY). */
            sljit_emit_op1(c, SLJIT_MOV, R0, OPND(&e, p[1]));
            to_label(&e, tag_cmp(c, SLJIT_NOT_EQUAL, R1, R0, TAG_PROC), p[3]);
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R0), -TAG_PROC);
            sljit_emit_op2(c, SLJIT_AND, R1, R1, IMM(0xFF));
            to_label(&e, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(T_CLOSURE << 3 | TAG_HEADER)), p[3]);
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R0), CLO_CODE * sizeof(V) - TAG_PROC);
            sljit_emit_op1(c, SLJIT_MOV, R1, SLJIT_MEM1(SLJIT_R1), CODE_ARITY * sizeof(V) - TAG_OBJECT);
            sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(32));
            to_label(&e, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, IMM(p[2])), p[3]);
            break;
        }
        case OP_JUMP_IF_FALSE: {
            sljit_s32 r = operand_reg(&e, p[1]);
            to_label(&e, sljit_emit_cmp(c, SLJIT_EQUAL, r, 0, IMM(V_FALSE)), p[2]);
            Slow *s = slow_path(&e, SLOW_BOOLEAN, sljit_emit_cmp(c, SLJIT_NOT_EQUAL, r, 0, IMM(V_TRUE)));
            s->insn = p;
            s->catch_label = quiet_catch(&e);
            break;
        }
        case OP_CALL:
        case OP_CALL_SEALED:
        case OP_CALL_VALUE:
            emit_call(&e, p);
            break;
        case OP_TAIL_CALL:
        case OP_TAIL_CALL_SEALED:
        case OP_TAIL_CALL_VALUE:
            emit_tail_call(&e, p);
            break;
        case OP_RETURN:
            sljit_emit_op1(c, SLJIT_MOV, R0, OPND(&e, p[1]));
            sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_MEM1(FP), 0);
            break;
        case OP_PUSH_HANDLER: {
            /* Inline while the handler array has room; C grows it. A handler
               whose code does not start with exception never reads it. */
            const uint32_t *h = words + label_pos[p[1]];
            h += insn_length(h);
            size_t quiet = h >= words + nwords || h[0] != OP_EXCEPTION;
            if (quiet && !slow_prims && virtual_handler(words, i, nwords, label_pos)) {
                e.handlers[e.nhandlers++] = p[1] | VIRTUAL;
                e.at_label[p[1]].seen = true;
                e.at_label[p[1]].cached = NONE; /* reached by jumps from slow paths */
                e.at_label[p[1]].kept[0] = e.at_label[p[1]].kept[1] = NONE;
                e.at_label[p[1]].pairs = 0;
                break;
            }
            e.handlers[e.nhandlers++] = quiet ? p[1] : NONE;
            sljit_emit_op1(c, SLJIT_MOV, R0, VMF(nhandlers));
            struct sljit_jump *full = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R0, VMF(handlers_cap));
            sljit_emit_op2(c, SLJIT_ADD, R1, R0, IMM(1));
            sljit_emit_op1(c, SLJIT_MOV, VMF(nhandlers), R1);
            sljit_emit_op2(c, SLJIT_SHL, R0, R0, IMM(4));
            sljit_emit_op2(c, SLJIT_ADD, R0, R0, VMF(handlers));
            sljit_emit_op2(c, SLJIT_SUB, R1, FP, 0, VMF(stack));
            sljit_emit_op2(c, SLJIT_LSHR, R1, R1, IMM(2));
            if (quiet)
                sljit_emit_op2(c, SLJIT_OR, R1, R1, IMM(1));
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), offsetof(Handler, fp_offset), R1);
            to_label(&e, sljit_emit_op_addr(c, SLJIT_MOV_ADDR, R1), p[1]);
            e.at_label[p[1]].cached = NONE; /* reached by unwinding */
            e.at_label[p[1]].kept[0] = e.at_label[p[1]].kept[1] = NONE;
            e.at_label[p[1]].pairs = 0;
            sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), offsetof(Handler, catch_addr), R1);
            struct sljit_jump *done = sljit_emit_jump(c, SLJIT_JUMP);
            sljit_set_label(full, sljit_emit_label(c));
            sljit_emit_op1(c, SLJIT_MOV, VMF(fp), FP, 0);
            to_label(&e, sljit_emit_op_addr(c, SLJIT_MOV_ADDR, R1), p[1]);
            sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
            sljit_emit_op1(c, SLJIT_MOV, R2, IMM(quiet));
            call_c(c, SLJIT_ARGS3(W, P, P, W), (void *)h_push_handler);
            check_raise(&e);
            sljit_set_label(done, sljit_emit_label(c));
            break;
        }
        case OP_POP_HANDLER: {
            uint32_t top = e.handlers[--e.nhandlers];
            if (top == NONE || !(top & VIRTUAL)) /* NONE: a handler that reads the exception */
                sljit_emit_op2(c, SLJIT_SUB, VMF(nhandlers), VMF(nhandlers), IMM(1));
            break;
        }
        case OP_EXCEPTION:
            sljit_emit_op1(c, SLJIT_MOV, HOME(&e, p[1]), VMF(exception));
            break;
        }
        if (e.post == NONE && pre != NONE && keeps_cache(p) && !writes_slot(p, pre))
            e.post = pre;
        if (p[0] == OP_LABEL)
            e.pairs = e.at_label[p[1]].seen ? e.at_label[p[1]].pairs : 0;
        else if (!keeps_cache(p))
            e.pairs = 0; /* a call, tail call, return or handler push */
        else if (p[0] != OP_JUMP_IF_FALSE && p[0] != OP_POP_HANDLER && p[0] != OP_ENTRY &&
                 p[0] != OP_JUMP_UNLESS_ENTRY && p[0] != OP_INLINE && p[1] < 64 &&
                 !(p[0] == OP_PRIM && i != (size_t)(p - words)))
            e.pairs &= ~(UINT64_C(1) << p[1]);
        falls = !(p[0] == OP_RETURN || p[0] == OP_JUMP || p[0] == OP_AGAIN || p[0] == OP_TAIL_CALL ||
                  p[0] == OP_TAIL_CALL_SEALED || p[0] == OP_TAIL_CALL_VALUE);
        /* A restart after a collection runs the instruction again from the
           state before it; going back after a slow path continues from the
           state after it. Other slow paths raise, or come before a call. */
        for (size_t k = first_slow; k < e.nslow; k++) {
            Slow *s = &e.slow[k];
            if (s->kind == SLOW_ALLOC) {
                s->restore = pre;
                s->kept[0] = kept_pre[0];
                s->kept[1] = kept_pre[1];
            } else if (s->kind == SLOW_PRIM) {
                s->restore = e.post;
                s->kept[0] = e.kept_post[0];
                s->kept[1] = e.kept_post[1];
            }
        }
        e.cached = e.post;
        e.kept[0] = e.kept_post[0];
        e.kept[1] = e.kept_post[1];
    }
    e.cached = NONE; /* slow paths read operands from their slots */
    e.kept[0] = e.kept[1] = NONE;
    emit_slow_paths(&e);
    for (size_t i = 0; i < e.nfixups; i++) {
        if (e.fixups[i].label >= nlabels || !e.labels[e.fixups[i].label]) {
            fprintf(stderr, "shen-jit: jump to undefined label %u\n", e.fixups[i].label);
            goto done;
        }
        sljit_set_label(e.fixups[i].jump, e.labels[e.fixups[i].label]);
    }
    if (sljit_get_compiler_error(c) != SLJIT_SUCCESS)
        fprintf(stderr, "shen-jit: SLJIT error %d\n", sljit_get_compiler_error(c));
    else if ((generated = sljit_generate_code(c, 0, NULL))) {
        native = (void *)sljit_get_label_addr(entry);
        vm->jit->ncompiled++;
        /* The entry starts the code, so a collection can free it once the
           code object is dead. */
        if (native == generated)
            vm_track_native(vm, code);
    }
    if (native)
        for (size_t i = 0; i < e.ncalls; i++)
            site_put(vm->jit, (uintptr_t)sljit_get_label_addr(e.calls[i].back), e.calls[i].window,
                     e.calls[i].chain);
    for (size_t i = 0; native && i < e.nraises; i++)
        site_put(vm->jit, (uintptr_t)sljit_get_label_addr(e.raises[i].ret), 0, e.raises[i].chain);
    for (size_t i = 0; native && i < e.nselfs; i++)
        patch_put(vm, native, symbol_cell(co[CODE_NAME]), JUMP_INSN(e.selfs[i].jump),
                  sljit_get_label_addr(e.selfs[i].other));
    for (size_t i = 0; native && i < e.nguards; i++)
        patch_put(vm, native, e.guards[i].cell, sljit_get_label_addr(e.guards[i].at),
                  sljit_get_label_addr(e.guards[i].stub->start));
    if (native && is_symbol(co[CODE_NAME])) {
        V name = ptr(co[CODE_NAME])[SYM_NAME];
        size_t size = sljit_get_generated_code_size(c);
        profile_code(native, size, string_bytes(name), string_length(name));
        if (vm->jit->perf_map) {
            fprintf(vm->jit->perf_map, "%llx %llx %.*s\n", (unsigned long long)(uintptr_t)native, (unsigned long long)size,
                    (int)string_length(name), string_bytes(name));
            fflush(vm->jit->perf_map);
        }
    }

done:
    if (c)
        sljit_free_compiler(c);
    free(words);
    free(label_pos);
    free(e.labels);
    free(e.fixups);
    free(e.calls);
    free(e.slow);
    free(e.at_label);
    free(e.handlers);
    free(e.selfs);
    free(e.guards);
    free(e.raises);
    free(e.seen);
    free(e.todo);
    free(marks);
    return native;
}

/* The adapter and the shared stubs, compiled once per process. They hold no
   VM address, so they can exist before an image loads, which needs the
   compile stub's address. */
Jit *jit_create(void)
{
    Jit *jit = calloc(1, sizeof *jit);
    struct sljit_compiler *c = sljit_create_compiler(NULL);
    if (!jit || !c) {
        free(jit);
        return NULL;
    }
    sljit_emit_enter(c, 0, ARG_TYPES, SCRATCHES, SAVEDS, LOCALS);

    /* Adapter, entered at the start of the code so the prologue runs: the
       VM arrives in S0; vm->fp is a frame whose slot 1 holds the callee and
       whose arguments follow; vm->count is their number. */
    sljit_emit_op1(c, SLJIT_MOV, VMR, 0, SLJIT_S0, 0);
    sljit_emit_op1(c, SLJIT_MOV, HP, VMF(hp));
    sljit_emit_op1(c, SLJIT_MOV, FP, 0, VMF(fp));
    sljit_emit_op1(c, SLJIT_MOV, R2, VMF(count));
    sljit_emit_op1(c, SLJIT_MOV, R1, SLOT(1));
    struct sljit_jump *no_arguments = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(0));
    sljit_emit_op1(c, SLJIT_MOV, CACHE, SLOT(2)); /* the first argument */
    sljit_set_label(no_arguments, sljit_emit_label(c));
    struct sljit_jump *exit_addr = sljit_emit_op_addr(c, SLJIT_MOV_ADDR, SLOT(0));
    sljit_emit_ijump(c, SLJIT_JUMP, ENTRY_OF(SLJIT_R1));
    sljit_set_label(exit_addr, sljit_emit_aligned_label(c, SLJIT_LABEL_ALIGN_4, NULL));
    sljit_emit_op1(c, SLJIT_MOV, VMF(hp), HP);
    sljit_emit_return(c, SLJIT_MOV, R0);
    struct sljit_label *error_exit = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, VMF(hp), HP);
    sljit_emit_op1(c, SLJIT_MOV, R0, IMM(V_CLEARED));
    sljit_emit_return(c, SLJIT_MOV, R0);

    /* Unwind: resume at the innermost handler, or leave the adapter. */
    struct sljit_label *unwind = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
    call_c(c, SLJIT_ARGS1(P, P), (void *)h_unwind);
    sljit_emit_op1(c, SLJIT_MOV, FP, 0, VMF(fp));
    sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R0, IMM(0)), error_exit);
    sljit_emit_ijump(c, SLJIT_JUMP, R0);

    /* Before the callee's frame exists only the window is live: publish
       FP + count + 2 as the top. */
#define PUBLISH_WINDOW()                                              \
    sljit_emit_op1(c, SLJIT_MOV, VMF(fp), FP, 0);                     \
    sljit_emit_op1(c, SLJIT_MOV, VMF(count), R2);                     \
    sljit_emit_op2(c, SLJIT_ADD, R3, R2, IMM(2));                     \
    sljit_emit_op2(c, SLJIT_SHL, R3, R3, IMM(3));                     \
    sljit_emit_op2(c, SLJIT_ADD, R3, R3, FP, 0);                      \
    sljit_emit_op1(c, SLJIT_MOV, VMF(top), R3)

    struct sljit_label *arity = sljit_emit_label(c);
    PUBLISH_WINDOW();
    sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
    call_c(c, SLJIT_ARGS1(W, P), (void *)h_arity_error);
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), unwind);

    struct sljit_label *compile = sljit_emit_label(c);
    PUBLISH_WINDOW();
    sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
    call_c(c, SLJIT_ARGS1(P, P), (void *)h_compile);
    sljit_emit_op1(c, SLJIT_MOV, R2, VMF(count));
    no_arguments = sljit_emit_cmp(c, SLJIT_EQUAL, R2, IMM(0));
    sljit_emit_op1(c, SLJIT_MOV, CACHE, SLOT(2)); /* compiling may collect */
    sljit_set_label(no_arguments, sljit_emit_label(c));
    sljit_emit_ijump(c, SLJIT_JUMP, R0);

    /* The entry of every C function: h_foreign reads what it needs from the window. A nested
       call may have moved the guest stack, so the frame is found again before returning. */
    struct sljit_label *foreign = sljit_emit_label(c);
    PUBLISH_WINDOW();
    sljit_emit_op1(c, SLJIT_MOV, R0, VMR, 0);
    call_c(c, SLJIT_ARGS1(W, P), (void *)h_foreign);
    sljit_set_label(sljit_emit_cmp(c, SLJIT_EQUAL, R0, IMM(V_CLEARED)), unwind);
    sljit_emit_op1(c, SLJIT_MOV, FP, 0, VMF(fp));
    sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_MEM1(FP), 0);
#undef PUBLISH_WINDOW

    jit->stubs = sljit_get_compiler_error(c) == SLJIT_SUCCESS ? sljit_generate_code(c, 0, NULL) : NULL;
    if (jit->stubs) {
        jit->adapter = (V(*)(VM *))jit->stubs;
        jit->unwind = (void *)sljit_get_label_addr(unwind);
        jit->arity = (void *)sljit_get_label_addr(arity);
        jit->compile = (void *)sljit_get_label_addr(compile);
        jit->foreign = (void *)sljit_get_label_addr(foreign);
    }
    sljit_free_compiler(c);
    if (!jit->stubs) {
        free(jit);
        return NULL;
    }
    return jit;
}

void *jit_compile_stub(Jit *jit) { return jit->compile; }

void *jit_foreign_stub(Jit *jit) { return jit->foreign; }

/* A collection found this code object dead (heap.c), so nothing can run its
   native code again. Kept while something names code by address: the
   profiler and the perf map. */
static void free_native(VM *vm, uint64_t *code)
{
    if (vm->jit->perf_map || profile_running())
        return;
    patches_drop(vm->jit, false, (uintptr_t)code[CODE_NATIVE]);
    sljit_free_code((void *)(uintptr_t)code[CODE_NATIVE], NULL);
    vm->jit->nfreed++;
}

void jit_stats(VM *vm, size_t *compiled, size_t *freed)
{
    *compiled = vm->jit ? vm->jit->ncompiled : 0;
    *freed = vm->jit ? vm->jit->nfreed : 0;
}

void jit_recompile(VM *vm)
{
    vm_collect(vm, 0); /* so that the heap can be walked */
    for (uint64_t *s = vm->space; s < vm->live_end;) {
        if (!is_header(*s)) {
            s += 2;
            continue;
        }
        if (hdr_type(*s) == T_CLOSURE)
            s[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->compile_stub;
        else if (hdr_type(*s) == T_CODE)
            s[CODE_NATIVE] = 0;
        s += obj_words(*s);
    }
    vm->nnatives = 0; /* never freed: frames may be running it */
}

void jit_attach(VM *vm, Jit *jit)
{
    /* For profilers: SHEN_JIT_PERF_MAP writes the perf map of this process
       (/tmp/perf-PID.map), so samples in native code can be named. */
    if (getenv("SHEN_JIT_PERF_MAP")) {
        char path[64];
        snprintf(path, sizeof path, "/tmp/perf-%d.map", (int)getpid());
        jit->perf_map = sj_fopen(path, "w");
    }
    slow_prims = getenv("SHEN_JIT_SLOW_PRIMS") != NULL;
    vm->jit = jit;
    vm->compile_stub = jit->compile;
    vm->foreign_stub = jit->foreign;
    vm->free_native = free_native;
    vm->redefine = redefine;
}

bool jit_init(VM *vm)
{
    Jit *jit = jit_create();
    if (jit)
        jit_attach(vm, jit);
    return jit != NULL;
}

void jit_destroy(VM *vm)
{
    if (vm->jit) {
        for (size_t i = 0; i < vm->nnatives; i++)
            sljit_free_code((void *)(uintptr_t)ptr(vm->natives[i])[CODE_NATIVE], NULL);
        vm->nnatives = 0;
        vm->free_native = NULL;
        vm->redefine = NULL;
        free(vm->jit->patches);
        free(vm->jit->site_addr);
        free(vm->jit->site_window);
        free(vm->jit->site_chain);
        free(vm->jit->chains);
        if (vm->jit->perf_map)
            fclose(vm->jit->perf_map);
        sljit_free_code(vm->jit->stubs, NULL);
        free(vm->jit);
        vm->jit = NULL;
    }
}

V jit_call(VM *vm, V proc, size_t n, const V *args)
{
    if (!is_proc(proc))
        return sj_raise_value(vm, "~S is not a function", proc);
    size_t offset = (size_t)(vm->top - vm->stack), fp_offset = (size_t)(vm->fp - vm->stack);
    /* The callee's window, and room for a leaf, which does not check its frame. */
    if (!vm_stack_reserve(vm, offset + n + 2 + LEAF_FRAME))
        return sj_raise(vm, "stack overflow");
    V *base = vm->stack + offset;
    base[1] = proc;
    for (size_t i = 0; i < n; i++)
        base[2 + i] = args[i];
    vm->fp = base;
    vm->count = n;
    vm->top = base + n + 2;
    size_t handlers = vm->nhandlers;
    V result = vm->jit->adapter(vm);
    vm->nhandlers = handlers;
    /* The stack may have moved while guest code ran. */
    vm->top = vm->stack + offset;
    vm->fp = vm->stack + fp_offset;
    return result;
}

/* jit_call from C that guest code called. A handler with no address stops an error
   here: h_unwind pops it and returns NULL, so the adapter returns V_CLEARED instead
   of jumping to a handler across the C frames, and C decides. It is never quiet, so
   the message is built for C to read. A backtrace stops here too. */
V jit_call_nested(VM *vm, V proc, size_t n, const V *args)
{
    char here;
    if ((uintptr_t)&here < vm->c_stack_limit)
        return sj_raise(vm, "stack overflow");
    size_t handlers = vm->nhandlers;
    if (h_push_handler(vm, NULL, 0) == V_CLEARED)
        return V_CLEARED;
    V result = jit_call(vm, proc, n, args);
    vm->nhandlers = handlers;
    return result;
}

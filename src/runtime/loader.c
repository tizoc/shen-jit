/* Installing lowered code: encodes the symbolic instructions of docs/bytecode.md
   into code objects. Stage 0 loading and, later, the install primitive behind
   eval-kl share this path. The checks here are the only validation lowered
   code gets, so they cover operand shapes and ranges. */
#include "ops.h"
#include "reader.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_CAPTURES = 4096, LOOKUP_SIZE = 512 };

typedef struct {
    VM *vm;
    LoadStats *stats;
    const char *error;
    uint32_t *buf; /* encoding buffer, outside the heap */
    size_t len, cap;
    uint8_t *packed; /* packing buffer, reused across code objects */
    size_t packed_cap;
    size_t *touched; /* cells whose sealed slots need binding after this load */
    size_t ntouched, touched_cap;
} Loader;

static const char *const op_names[] = {
#define SJ_OP_NAME(op, name, n) name,
    SJ_OPCODES(SJ_OP_NAME)
#undef SJ_OP_NAME
};
static const unsigned op_fixed[] = {
#define SJ_OP_FIXED(op, name, n) n,
    SJ_OPCODES(SJ_OP_FIXED)
#undef SJ_OP_FIXED
};

static int16_t op_table[LOOKUP_SIZE];
static int16_t prim_table[LOOKUP_SIZE];
static pthread_once_t tables_once = PTHREAD_ONCE_INIT;

static void table_put(int16_t *table, const char *name, int16_t value)
{
    size_t i = (size_t)hash_bytes(name, strlen(name)) & (LOOKUP_SIZE - 1);
    while (table[i] >= 0)
        i = (i + 1) & (LOOKUP_SIZE - 1);
    table[i] = value;
}

static void init_tables(void)
{
    for (size_t i = 0; i < LOOKUP_SIZE; i++)
        op_table[i] = prim_table[i] = -1;
    for (unsigned op = 0; op < OP_COUNT; op++)
        table_put(op_table, op_names[op], (int16_t)op);
    for (size_t i = 0; i < primitive_count; i++)
        table_put(prim_table, primitive_table[i].name, (int16_t)i);
    table_put(prim_table, "raise-cond", (int16_t)PRIM_RAISE_COND);
    table_put(prim_table, "shen-jit.field", (int16_t)PRIM_FIELD);
}

static bool fail(Loader *l, const char *message)
{
    if (!l->error)
        l->error = message;
    return false;
}

static size_t list_length(V list)
{
    size_t n = 0;
    for (; is_pair(list); list = ptr(list)[1])
        n++;
    return list == V_NIL ? n : (size_t)-1;
}

static V list_drop(V list, size_t n)
{
    while (n--)
        list = ptr(list)[1];
    return list;
}

static V nth(V list, size_t i)
{
    return ptr(list_drop(list, i))[0];
}

static bool emit(Loader *l, uint64_t word)
{
    if (word > UINT32_MAX)
        return fail(l, "operand out of range");
    uint32_t *buf = grow_array(l->buf, &l->cap, l->len, sizeof *buf, 256);
    if (!buf)
        return fail(l, "out of memory");
    l->buf = buf;
    l->buf[l->len++] = (uint32_t)word;
    return true;
}

static bool small_int(V v, uint64_t limit, uint64_t *out)
{
    if (!is_fix(v) || fixval(v) < 0 || (uint64_t)fixval(v) >= limit)
        return false;
    *out = (uint64_t)fixval(v);
    return true;
}

static bool byte_count(Loader *l, V v, uint64_t *out, const char *limit_error)
{
    if (is_fix(v) && fixval(v) > 255)
        return fail(l, limit_error);
    return small_int(v, 256, out);
}

/* An operand: a slot, or (const K), encoded with OPERAND_CONST. */
static bool operand(V v, uint64_t frame, uint64_t nconst, uint64_t *out)
{
    if (is_pair(v)) {
        if (list_length(v) != 2 || !symbol_named(nth(v, 0), "const") || !small_int(nth(v, 1), nconst, out))
            return false;
        *out |= OPERAND_CONST;
        return true;
    }
    return small_int(v, frame, out);
}

static unsigned opcode_index(V head)
{
    if (!is_symbol(head))
        return OP_COUNT;
    for (size_t i = (size_t)ptr(head)[SYM_HASH] & (LOOKUP_SIZE - 1); op_table[i] >= 0; i = (i + 1) & (LOOKUP_SIZE - 1)) {
        unsigned op = (unsigned)op_table[i];
        if (symbol_named(head, op_names[op]))
            return op;
    }
    return OP_COUNT;
}

static const char *prim_name(unsigned idx)
{
    return idx == PRIM_RAISE_COND ? "raise-cond"
         : idx == PRIM_FIELD ? "shen-jit.field" : primitive_table[idx].name;
}

static long primitive_index(V name)
{
    if (!is_symbol(name))
        return -1;
    for (size_t i = (size_t)ptr(name)[SYM_HASH] & (LOOKUP_SIZE - 1); prim_table[i] >= 0; i = (i + 1) & (LOOKUP_SIZE - 1)) {
        unsigned idx = (unsigned)prim_table[i];
        if (symbol_named(name, prim_name(idx)))
            return (long)idx;
    }
    return -1;
}

static int primitive_arity(size_t index)
{
    return index == PRIM_RAISE_COND ? 0 : index == PRIM_FIELD ? 2 : primitive_table[index].arity;
}

static bool touch_sealed(Loader *l, size_t cell)
{
    size_t *t = grow_array(l->touched, &l->touched_cap, l->ntouched, sizeof *t, 32);
    if (!t)
        return fail(l, "out of memory");
    l->touched = t;
    l->touched[l->ntouched++] = cell;
    return true;
}

/* The constant slot of sealed calls to sym, cached on the program by cell index.
   It holds sym until bind_sealed (or the first call) puts the procedure there. */
static bool sealed_slot(Loader *l, V sym, size_t *slot)
{
    Program *p = l->vm->program;
    size_t cell = symbol_cell(sym);
    if (cell >= p->sealed_cap) {
        size_t cap = p->sealed_cap ? p->sealed_cap : 256;
        while (cap <= cell)
            cap *= 2;
        size_t *s = realloc(p->sealed_slot, cap * sizeof *s);
        if (!s)
            return fail(l, "out of memory");
        for (size_t i = p->sealed_cap; i < cap; i++)
            s[i] = SIZE_MAX;
        p->sealed_slot = s;
        p->sealed_cap = cap;
    }
    if (p->sealed_slot[cell] == SIZE_MAX) {
        if (!ra_push(&p->consts, sym, &p->sealed_slot[cell]) || !touch_sealed(l, cell))
            return fail(l, "out of memory");
    } else if (!is_proc(*ra_at(&p->consts, p->sealed_slot[cell]))) {
        if (!touch_sealed(l, cell))
            return false;
    }
    *slot = p->sealed_slot[cell];
    return true;
}

/* Encodes one instruction. Slots are checked against the frame size, indices
   against the code object's tables. */
static bool encode(Loader *l, V insn, uint64_t frame, uint64_t nconst, uint64_t ncode)
{
    size_t n = list_length(insn);
    if (n == (size_t)-1 || n == 0)
        return fail(l, "malformed instruction");
    unsigned op = opcode_index(nth(insn, 0));
    if (op == OP_COUNT)
        return fail(l, "unknown instruction");
    if (!emit(l, op))
        return false;
    uint64_t x;
    /* Each operand position has a kind: s slot, o slot or constant (an
       operand), k constant, c code, i capture index, l label, f function symbol,
       n count, r a float register, w a word register, W a word register or a constant. */
    static const char *const kinds[OP_COUNT] = {
        [OP_MOVE] = "ss", [OP_CONST] = "sk", [OP_CAPTURE] = "si",
        [OP_CLOSURE] = "sc", [OP_PRIM] = "s", [OP_LABEL] = "l", [OP_JUMP] = "l",
        [OP_JUMP_IF_FALSE] = "ol", [OP_CALL] = "ssfn", [OP_CALL_SEALED] = "ssfn",
        [OP_CALL_VALUE] = "ssn", [OP_TAIL_CALL] = "sfn", [OP_TAIL_CALL_SEALED] = "sfn",
        [OP_TAIL_CALL_VALUE] = "sn", [OP_RETURN] = "o", [OP_PUSH_HANDLER] = "l",
        [OP_POP_HANDLER] = "", [OP_EXCEPTION] = "s", [OP_ENTRY] = "nl",
        [OP_JUMP_UNLESS_ENTRY] = "snl", [OP_INLINE] = "fl"};
    /* What reads or writes memory is laid out as prim is, in the words the JIT reads: the
       register, the primitive that raises what is wrong with it, a count and the operands. */
    if (op == OP_FLOAT_LOAD || op == OP_FLOAT_STORE) {
        uint64_t reg, m, i;
        bool store = op == OP_FLOAT_STORE;
        if (n != 4 || !small_int(nth(insn, store ? 3 : 1), FLOAT_REGISTERS, &reg) ||
            !operand(nth(insn, store ? 1 : 2), frame, nconst, &m) ||
            !operand(nth(insn, store ? 2 : 3), frame, nconst, &i))
            return fail(l, "bad operand");
        if (!emit(l, reg) || !emit(l, store ? P_SET_F64 : P_F64) || !emit(l, store ? 3 : 2) || !emit(l, m) ||
            !emit(l, i) || (store && !emit(l, m)))
            return false;
        l->stats->instructions++;
        return true;
    }
    const char *kind = raw_kinds(op) ? raw_kinds(op) : kinds[op];
    size_t fixed = strlen(kind);
    if (op == OP_PRIM)
        fixed = 2;
    if (n < 1 + fixed || ((op != OP_CLOSURE && op != OP_PRIM) && n != 1 + op_fixed[op]))
        return fail(l, "wrong operand count");

    for (size_t i = 0; i < strlen(kind); i++) {
        V v = nth(insn, 1 + i);
        bool ok;
        switch (kind[i]) {
        case 's': ok = small_int(v, frame, &x); break;
        case 'o': ok = operand(v, frame, nconst, &x); break;
        case 'k': ok = small_int(v, nconst, &x); break;
        case 'c': ok = small_int(v, ncode, &x); break;
        case 'i':
            if (is_fix(v) && fixval(v) >= MAX_CAPTURES)
                return fail(l, "capture index exceeds 4095");
            ok = small_int(v, MAX_CAPTURES, &x);
            break;
        case 'l': case 'h': case 'b': ok = small_int(v, UINT32_MAX, &x); break;
        case 'n':
            ok = byte_count(l, v, &x, op == OP_ENTRY ? "entry has more than 255 parameters" :
                                                       "call has more than 255 arguments");
            break;
        case 'r': ok = small_int(v, FLOAT_REGISTERS, &x); break;
        case 'w': ok = small_int(v, WORD_REGISTERS, &x); break;
        case 'W': ok = operand(v, WORD_REGISTERS, nconst, &x); break;
        case 'v': case 'V': ok = small_int(v, VECTOR_REGISTERS, &x); break;
        default: /* 'f' */
            ok = is_symbol(v);
            if (ok && (op == OP_CALL_SEALED || op == OP_TAIL_CALL_SEALED)) {
                size_t slot = 0;
                ok = sealed_slot(l, v, &slot);
                x = slot;
            } else if (ok) {
                x = symbol_cell(v);
                symbol_mark_called(v); /* the code holds its cell */
            }
        }
        if (!ok || !emit(l, x))
            return fail(l, "bad operand");
    }

    if (op >= OP_CALL && op <= OP_TAIL_CALL_VALUE) {
        /* The window A, A+1 and A+2..A+1+N must lie inside the frame. */
        int64_t a = fixval(nth(insn, op <= OP_CALL_VALUE ? 2 : 1));
        int64_t count = fixval(nth(insn, n - 1));
        if ((uint64_t)(a + 1 + count) >= frame)
            return fail(l, "call window outside the frame");
    }
    if (op == OP_PRIM) {
        long p = primitive_index(nth(insn, 2));
        if (p < 0 || (size_t)primitive_arity((size_t)p) != n - 3)
            return fail(l, "unknown primitive or wrong arity");
        if (!emit(l, (uint64_t)p) || !emit(l, n - 3))
            return false;
    } else if (op == OP_CLOSURE) {
        if (n - 3 > MAX_CAPTURES)
            return fail(l, "closure has more than 4096 captures");
        if (!emit(l, n - 3))
            return false;
    }
    if (op == OP_PRIM || op == OP_CLOSURE) {
        for (V args = list_drop(insn, 3); args != V_NIL; args = ptr(args)[1]) {
            V v = ptr(args)[0];
            bool ok = op == OP_PRIM ? operand(v, frame, nconst, &x) : small_int(v, frame, &x);
            if (!ok || !emit(l, x))
                return fail(l, "bad operand");
        }
    }
    l->stats->instructions++;
    return true;
}

/* Labels are defined once and every target is defined, so native code never
   jumps to an undefined label; and code ends in a transfer, so it never runs
   off its end. */
static bool check_control(Loader *l)
{
    uint32_t *buf = l->buf;
    size_t len = l->len, last = 0;
    uint32_t nlabels = 0;
    for (size_t i = 0; i < len; i += insn_length(buf + i))
        if ((buf[i] == OP_LABEL || buf[i] == OP_LOOP) && buf[i + 1] >= nlabels)
            nlabels = buf[i + 1] + 1;
    if (nlabels > (1u << 20))
        return fail(l, "too many labels");
    unsigned char small[256];
    size_t need = 2 * (size_t)(nlabels + 1);
    unsigned char *defined = need <= sizeof small ? memset(small, 0, need) : calloc(need, 1);
    if (!defined)
        return fail(l, "out of memory");
    unsigned char *head = defined + nlabels + 1; /* the loops passed so far */
    bool ok = len > 0;
    for (size_t i = 0; ok && i < len; i += insn_length(buf + i)) {
        last = i;
        if (buf[i] == OP_LABEL || buf[i] == OP_LOOP)
            ok = !defined[buf[i + 1]]++;
    }
    for (size_t i = 0; ok && i < len; i += insn_length(buf + i)) {
        uint32_t target = buf[i] == OP_JUMP || buf[i] == OP_PUSH_HANDLER ? buf[i + 1]
                        : buf[i] == OP_JUMP_IF_FALSE || buf[i] == OP_ENTRY ? buf[i + 2]
                        : buf[i] == OP_JUMP_UNLESS_ENTRY || (raw_kinds(buf[i]) && strchr(raw_kinds(buf[i]), 'l'))
                            ? buf[i + 3] : UINT32_MAX;
        if (target != UINT32_MAX)
            ok = target < nlabels && defined[target];
        if (buf[i] == OP_LOOP)
            head[buf[i + 1]] = 1;
        if (buf[i] == OP_AGAIN) /* back to a loop this code has passed, and nothing else */
            ok = ok && buf[i + 1] < nlabels && head[buf[i + 1]];
        if (buf[i] == OP_ENTRY) /* first, for more arguments than the arity */
            ok = ok && i == 0;
    }
    if (ok) {
        uint32_t op = buf[last];
        ok = op == OP_RETURN || op == OP_JUMP || op == OP_AGAIN || op == OP_TAIL_CALL ||
             op == OP_TAIL_CALL_SEALED || op == OP_TAIL_CALL_VALUE;
    }
    if (defined != small)
        free(defined);
    return ok || fail(l, "bad control flow: labels or the final instruction");
}

/* A closure that captures nothing is made once, here: the slot of its code holds it instead,
   and the closure instruction gives it (jit.c). Lowered code closes over each nested code once;
   code written by hand may also close over one with captures, and its slot then keeps the code.
   Making a closure may collect, which updates the slots, roots until the code is built. */
static bool make_empty_closures(Loader *l, size_t codes)
{
    for (size_t i = 0; i < l->len; i += insn_length(l->buf + i)) {
        const uint32_t *p = l->buf + i;
        V *slot = p[0] == OP_CLOSURE && !p[3] ? ra_at(&l->vm->program->consts, codes + p[2]) : NULL;
        if (!slot || is_proc(*slot))
            continue;
        V closure = make_closure(l->vm, *slot, 0, NULL);
        if (closure == V_CLEARED)
            return fail(l, "out of memory");
        *slot = closure;
    }
    for (size_t i = 0; i < l->len; i += insn_length(l->buf + i)) {
        const uint32_t *p = l->buf + i;
        V *slot = p[0] == OP_CLOSURE && p[3] ? ra_at(&l->vm->program->consts, codes + p[2]) : NULL;
        if (slot && is_proc(*slot))
            *slot = ptr(*slot)[CLO_CODE];
    }
    return true;
}

/* (code Name Arity FrameSize Constants Instructions Codes) */
static V build_code(Loader *l, V form)
{
    VM *vm = l->vm;
    uint64_t arity, frame;
    /* (code Name Arity Frame Constants Instructions Codes [Inline]) */
    size_t n = list_length(form);
    if ((n != 7 && n != 8) || !symbol_named(nth(form, 0), "code") ||
        !byte_count(l, nth(form, 2), &arity, "function has more than 255 parameters") ||
        !small_int(nth(form, 3), 1u << 20, &frame) ||
        frame < arity + 2 || list_length(nth(form, 4)) == (size_t)-1 ||
        list_length(nth(form, 5)) == (size_t)-1 || list_length(nth(form, 6)) == (size_t)-1) {
        fail(l, "malformed code object");
        return V_CLEARED;
    }
    vm_root(vm, &form);
    V result = V_CLEARED;
    size_t nconst = list_length(nth(form, 4)), ncode = list_length(nth(form, 6));
    bool allocated;
    size_t cbase = vm_consts_alloc(vm, nconst + ncode, &allocated);
    if (!allocated)
        goto done;
    /* Nothing here allocates, so the list stays where it is. */
    V consts = nth(form, 4);
    for (size_t i = 0; i < nconst; i++, consts = ptr(consts)[1])
        *ra_at(&vm->program->consts, cbase + i) = ptr(consts)[0];
    l->stats->constants += nconst;
    for (size_t i = 0; i < ncode; i++) {
        V nested = build_code(l, nth(nth(form, 6), i));
        if (nested == V_CLEARED)
            goto done;
        *ra_at(&vm->program->consts, cbase + nconst + i) = nested;
    }

    l->len = 0;
    for (V insns = nth(form, 5); insns != V_NIL; insns = ptr(insns)[1])
        if (!encode(l, ptr(insns)[0], frame, nconst, ncode))
            goto done;
    if (!check_control(l) || !make_empty_closures(l, cbase + nconst))
        goto done;
    /* entry N L: a call with N arguments starts at L, with them in slots
       2 to N+1. The code's arity word carries N above the arity. */
    if (l->buf[0] == OP_ENTRY) {
        if (l->buf[1] <= arity || frame < l->buf[1] + 2u) {
            fail(l, "entry outside the frame or not above the arity");
            goto done;
        }
        arity |= (uint64_t)l->buf[1] << 32;
    }
    size_t need = 5 * l->len + 1;
    if (need > l->packed_cap) {
        size_t cap = l->packed_cap ? l->packed_cap : 1024;
        while (cap < need)
            cap *= 2;
        uint8_t *packed = realloc(l->packed, cap);
        if (!packed)
            goto done;
        l->packed = packed;
        l->packed_cap = cap;
    }
    size_t packed_len = bytecode_pack(l->buf, l->len, l->packed);
    V bytes = make_bytes(vm, l->packed, packed_len);
    if (bytes == V_CLEARED)
        goto done;
    l->stats->bytecode_bytes += packed_len;
    result = make_code(vm, nth(form, 1), bytes, arity, frame, cbase, nconst, ncode,
                       n == 8 ? nth(form, 7) : V_NIL);
    if (result != V_CLEARED)
        vm_track_code(vm, result); /* its slots go with it from now on */
    if (frame > vm->program->max_frame)
        vm->program->max_frame = frame;
    l->stats->codes++;
done:
    vm_unroot(vm, 1);
    if (result == V_CLEARED) {
        if (allocated)
            vm_consts_release(vm, cbase, nconst + ncode);
        fail(l, "cannot build code object");
    }
    return result;
}

static V build_closure(Loader *l, V code_form)
{
    V code = build_code(l, code_form);
    if (code == V_CLEARED)
        return V_CLEARED;
    V closure = make_closure(l->vm, code, 0, NULL);
    if (closure == V_CLEARED)
        fail(l, "out of memory");
    return closure;
}

static bool is_defun_form(V form)
{
    return list_length(form) == 3 && symbol_named(nth(form, 0), "defun") && is_symbol(nth(form, 1));
}

/* Binds sealed calls touched by this load to the current function bindings of
   their targets. A target not defined yet keeps its symbol in the slot when
   forward is true: the first call binds it (jit.c); at stage 0 every target
   must exist. A slot left unbound, or touched by a load that failed, leaves the
   program's cache and stays this load's: a later load would otherwise bind it
   under callers whose first call would find another definition. So a slot that
   loads share is always bound to its target's current definition, and a
   redefinition takes it out of the cache (program_install). */
static void bind_sealed(Loader *l, bool forward)
{
    Program *p = l->vm->program;
    for (size_t i = 0; i < l->ntouched; i++) {
        size_t cell = l->touched[i];
        if (cell >= p->sealed_cap || p->sealed_slot[cell] == SIZE_MAX)
            continue;
        V target = *cell_function(l->vm, cell);
        V *slot = ra_at(&p->consts, p->sealed_slot[cell]);
        if (!l->error && is_proc(target)) {
            if (*slot != target) /* not rewritten under code already bound to it */
                *slot = target;
            continue;
        }
        if (!l->error && !forward)
            fail(l, "sealed call to a function that is not defined");
        p->sealed_slot[cell] = SIZE_MAX;
    }
}

bool load_stage0(VM *vm, const char *text, size_t len, LoadStats *stats, const char **error)
{
    return load_stage0_sealed(vm, text, len, len, stats, error);
}

/* Definitions that start before seal_until are sealed: the kernel, port code
   and the lowerer. Stage 1 puts the extensions after them, so they stay open,
   as their own tests reload their sources. */
bool load_stage0_sealed(VM *vm, const char *text, size_t len, size_t seal_until, LoadStats *stats,
                        const char **error)
{
    pthread_once(&tables_once, init_tables);
    Loader l = {0};
    l.vm = vm;
    l.stats = stats;
    Reader r = {vm, text, text + len, NULL, false};
    V form = V_NIL;
    vm_root(vm, &form);
    while (!l.error && !reader_at_end(&r)) {
        size_t at = (size_t)(r.p - text);
        form = reader_read(&r);
        if (form == V_CLEARED) {
            fail(&l, r.error);
            break;
        }
        if (!is_defun_form(form)) {
            fail(&l, "expected (defun Name Code)");
            break;
        }
        V closure = build_closure(&l, nth(form, 2));
        if (closure == V_CLEARED)
            break;
        const char *why = NULL;
        closure = program_promote(vm, closure, &why);
        if (closure == V_CLEARED) {
            fail(&l, why);
            break;
        }
        size_t cell = symbol_cell(nth(form, 1));
        if (vm->program->redefine)
            vm->program->redefine(vm, cell);
        *cell_function(vm, cell) = closure;
        program_clear_sealed_slot(vm->program, cell, true);
        if (at < seal_until)
            symbol_seal(nth(form, 1));
        stats->defuns++;
    }
    vm_unroot(vm, 1);
    /* Sealed calls bind once everything is loaded, so they may refer forward. */
    bind_sealed(&l, false);
    free(l.buf);
    free(l.packed);
    free(l.touched);
    *error = l.error;
    return !l.error;
}

/* The install primitive behind eval-kl: (defun F Code) publishes F and
   returns it; a code object returns a closure of it. Nothing is published
   unless the whole definition was built and its sealed calls bound. */
V sj_install(VM *vm, V form)
{
    pthread_once(&tables_once, init_tables);
    LoadStats stats = {0};
    Loader l = {0};
    l.vm = vm;
    l.stats = &stats;
    if (!vm_is_builder(vm))
        return sj_raise(vm, "only the builder can define functions");
    vm_root(vm, &form);
    bool defun = is_defun_form(form);
    V result = V_CLEARED;
    if (defun && symbol_sealed(nth(form, 1))) {
        V name = nth(form, 1);
        vm_unroot(vm, 1);
        return sj_raise_value(vm, "~S is sealed and cannot be redefined", name);
    }
    /* The program is fixed while other isolates run, as they run it (isolate.c). */
    if (defun && isolates_running(vm->program)) {
        vm_unroot(vm, 1);
        return sj_raise(vm, "the program cannot change while other isolates run");
    }
    if (defun)
        result = build_closure(&l, nth(form, 2));
    else if (is_pair(form) && symbol_named(nth(form, 0), "code"))
        result = build_closure(&l, form);
    else
        fail(&l, "install: expected (defun Name Code) or a code object");
    bind_sealed(&l, true);
    const char *refused = NULL;
    if (!l.error && defun) {
        result = program_promote(vm, result, &refused);
        if (result != V_CLEARED && !program_install(vm, nth(form, 1), result))
            refused = "out of memory";
        result = nth(form, 1);
    }
    vm_unroot(vm, 1);
    free(l.buf);
    free(l.packed);
    free(l.touched);
    if (refused)
        return sj_raise_text_value(vm, refused, result);
    return l.error ? sj_raise(vm, l.error) : result;
}

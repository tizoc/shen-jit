/* Installing lowered code: encodes the symbolic instructions of docs/bytecode.md
   into code objects. Stage 0 loading and, later, the install primitive behind
   eval-kl share this path. The checks here are the only validation lowered
   code gets, so they cover operand shapes and ranges. */
#include "ops.h"
#include "reader.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    VM *vm;
    LoadStats *stats;
    const char *error;
    uint32_t *buf; /* encoding buffer, outside the heap */
    size_t len, cap;
    size_t *sealed_slot; /* const slot of each sealed target, by cell index */
    size_t sealed_cap;
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

static V nth(V list, size_t i)
{
    while (i--)
        list = ptr(list)[1];
    return ptr(list)[0];
}

static bool symbol_is(V v, const char *name)
{
    if (!is_symbol(v))
        return false;
    V s = ptr(v)[SYM_NAME];
    return string_length(s) == strlen(name) && memcmp(string_bytes(s), name, string_length(s)) == 0;
}

static bool emit(Loader *l, uint64_t word)
{
    if (word > UINT32_MAX)
        return fail(l, "operand out of range");
    if (l->len == l->cap) {
        size_t cap = l->cap ? 2 * l->cap : 256;
        uint32_t *buf = realloc(l->buf, cap * sizeof *buf);
        if (!buf)
            return fail(l, "out of memory");
        l->buf = buf;
        l->cap = cap;
    }
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
        if (list_length(v) != 2 || !symbol_is(nth(v, 0), "const") || !small_int(nth(v, 1), nconst, out))
            return false;
        *out |= OPERAND_CONST;
        return true;
    }
    return small_int(v, frame, out);
}

static long primitive_index(V name)
{
    for (size_t i = 0; i < primitive_count; i++)
        if (symbol_is(name, primitive_table[i].name))
            return (long)i;
    return symbol_is(name, "raise-cond") ? (long)PRIM_RAISE_COND : -1;
}

static int primitive_arity(size_t index)
{
    return index == PRIM_RAISE_COND ? 0 : primitive_table[index].arity;
}

/* The constant slot of sealed calls to sym, shared within one load. It holds
   sym until bind_sealed puts the procedure there. */
static bool sealed_slot(Loader *l, V sym, size_t *slot)
{
    size_t cell = symbol_cell(sym);
    if (cell >= l->sealed_cap) {
        size_t cap = 2 * cell + 64;
        size_t *s = realloc(l->sealed_slot, cap * sizeof *s);
        if (!s)
            return fail(l, "out of memory");
        for (size_t i = l->sealed_cap; i < cap; i++)
            s[i] = SIZE_MAX;
        l->sealed_slot = s;
        l->sealed_cap = cap;
    }
    if (l->sealed_slot[cell] == SIZE_MAX &&
        !ra_push(&l->vm->program->consts, sym, &l->sealed_slot[cell]))
        return fail(l, "out of memory");
    *slot = l->sealed_slot[cell];
    return true;
}

/* Encodes one instruction. Slots are checked against the frame size, indices
   against the code object's tables. */
static bool encode(Loader *l, V insn, uint64_t frame, uint64_t nconst, uint64_t ncode)
{
    size_t n = list_length(insn);
    if (n == (size_t)-1 || n == 0)
        return fail(l, "malformed instruction");
    V head = nth(insn, 0);
    unsigned op = 0;
    while (op < OP_COUNT && !symbol_is(head, op_names[op]))
        op++;
    if (op == OP_COUNT)
        return fail(l, "unknown instruction");
    if (!emit(l, op))
        return false;
    uint64_t x;
    /* Each operand position has a kind: s slot, o slot or constant (an
       operand), k constant, c code, l label, f function symbol, n count, r a real
       register, w a word register, W a word register or a constant. */
    static const char *const kinds[OP_COUNT] = {
        [OP_MOVE] = "ss", [OP_CONST] = "sk", [OP_CAPTURE] = "sn",
        [OP_CLOSURE] = "sc", [OP_PRIM] = "s", [OP_LABEL] = "l", [OP_JUMP] = "l",
        [OP_JUMP_IF_FALSE] = "ol", [OP_CALL] = "ssfn", [OP_CALL_SEALED] = "ssfn",
        [OP_CALL_VALUE] = "ssn", [OP_TAIL_CALL] = "sfn", [OP_TAIL_CALL_SEALED] = "sfn",
        [OP_TAIL_CALL_VALUE] = "sn", [OP_RETURN] = "o", [OP_PUSH_HANDLER] = "l",
        [OP_POP_HANDLER] = "", [OP_EXCEPTION] = "s", [OP_ENTRY] = "nl",
        [OP_JUMP_UNLESS_ENTRY] = "snl", [OP_INLINE] = "fl"};
    /* What reads or writes memory is laid out as prim is, in the words the JIT reads: the
       register, the primitive that raises what is wrong with it, a count and the operands. */
    if (op == OP_REAL_LOAD || op == OP_REAL_STORE) {
        uint64_t reg, m, i;
        bool store = op == OP_REAL_STORE;
        if (n != 4 || !small_int(nth(insn, store ? 3 : 1), REAL_REGISTERS, &reg) ||
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
        case 'l': case 'h': case 'b': ok = small_int(v, UINT32_MAX, &x); break;
        case 'n':
            ok = byte_count(l, v, &x, op == OP_CAPTURE ? "capture index exceeds 255" :
                                      op == OP_ENTRY ? "entry has more than 255 parameters" :
                                                       "call has more than 255 arguments");
            break;
        case 'r': ok = small_int(v, REAL_REGISTERS, &x); break;
        case 'w': ok = small_int(v, WORD_REGISTERS, &x); break;
        case 'W': ok = operand(v, WORD_REGISTERS, nconst, &x); break;
        default: /* 'f' */
            ok = is_symbol(v);
            if (ok && (op == OP_CALL_SEALED || op == OP_TAIL_CALL_SEALED)) {
                size_t slot;
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
        if (!emit(l, n - 3))
            return false;
    }
    if (op == OP_PRIM || op == OP_CLOSURE) {
        for (size_t i = 3; i < n; i++) {
            V v = nth(insn, i);
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
    unsigned char *defined = calloc(2 * (nlabels + 1), 1);
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
    free(defined);
    return ok || fail(l, "bad control flow: labels or the final instruction");
}

/* (code Name Arity FrameSize Constants Instructions Codes) */
static V build_code(Loader *l, V form)
{
    VM *vm = l->vm;
    uint64_t arity, frame;
    /* (code Name Arity Frame Constants Instructions Codes [Inline]) */
    size_t n = list_length(form);
    if ((n != 7 && n != 8) || !symbol_is(nth(form, 0), "code") ||
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
    if (!check_control(l))
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
    uint8_t *packed = malloc(5 * l->len + 1);
    if (!packed)
        goto done;
    size_t packed_len = bytecode_pack(l->buf, l->len, packed);
    V bytes = make_bytes(vm, packed, packed_len);
    free(packed);
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
    return list_length(form) == 3 && symbol_is(nth(form, 0), "defun") && is_symbol(nth(form, 1));
}

/* Binds sealed calls to the current function bindings of their targets. A
   target not defined yet keeps its symbol in the slot when forward is true:
   the first call binds it (jit.c); at stage 0 every target must exist. */
static void bind_sealed(Loader *l, bool forward)
{
    for (size_t cell = 0; !l->error && cell < l->sealed_cap; cell++) {
        if (l->sealed_slot[cell] == SIZE_MAX)
            continue;
        V target = *cell_function(l->vm, cell);
        if (is_proc(target))
            *ra_at(&l->vm->program->consts, l->sealed_slot[cell]) = target;
        else if (!forward)
            fail(l, "sealed call to a function that is not defined");
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
    Loader l = {vm, stats, NULL, NULL, 0, 0, NULL, 0};
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
        if (vm->program->redefine)
            vm->program->redefine(vm, symbol_cell(nth(form, 1)));
        *cell_function(vm, symbol_cell(nth(form, 1))) = closure;
        if (at < seal_until)
            symbol_seal(nth(form, 1));
        stats->defuns++;
    }
    vm_unroot(vm, 1);
    /* Sealed calls bind once everything is loaded, so they may refer forward. */
    bind_sealed(&l, false);
    free(l.buf);
    free(l.sealed_slot);
    *error = l.error;
    return !l.error;
}

/* The install primitive behind eval-kl: (defun F Code) publishes F and
   returns it; a code object returns a closure of it. Nothing is published
   unless the whole definition was built and its sealed calls bound. */
V sj_install(VM *vm, V form)
{
    LoadStats stats = {0};
    Loader l = {vm, &stats, NULL, NULL, 0, 0, NULL, 0};
    if (!vm->builder)
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
    else if (is_pair(form) && symbol_is(nth(form, 0), "code"))
        result = build_closure(&l, form);
    else
        fail(&l, "install: expected (defun Name Code) or a code object");
    if (!l.error)
        bind_sealed(&l, true);
    const char *refused = NULL;
    if (!l.error && defun) {
        result = program_promote(vm, result, &refused);
        if (result != V_CLEARED) {
            if (vm->program->redefine)
                vm->program->redefine(vm, symbol_cell(nth(form, 1)));
            *cell_function(vm, symbol_cell(nth(form, 1))) = result;
            if (vm->seal_user)
                symbol_seal(nth(form, 1));
        }
        result = nth(form, 1);
    }
    vm_unroot(vm, 1);
    free(l.buf);
    free(l.sealed_slot);
    if (refused)
        return sj_raise_text_value(vm, refused, result);
    return l.error ? sj_raise(vm, l.error) : result;
}

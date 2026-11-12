/* The primitive table and the general implementations that native code falls
   back to (docs/semantics.md). */
#define _DEFAULT_SOURCE /* sigaction under -std=c11 with glibc */
#include "file.h"
#include "jit.h"
#include "ops.h"
#include "reader.h"
#include "vm.h"
#include "worker.h"

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <sys/select.h>
#endif
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* The order matches enum Prim in ops.h. Images record a checksum of the
   names, so an image cannot load into a build with a different table. */
const Primitive primitive_table[] = {
    {"+", 2, NULL},           {"-", 2, NULL},
    {"*", 2, NULL},           {"/", 2, NULL},
    {"<", 2, NULL},           {">", 2, NULL},
    {"<=", 2, NULL},          {">=", 2, NULL},
    {"=", 2, NULL},           {"number?", 1, NULL},
    {"cons", 2, NULL},        {"hd", 1, NULL},
    {"tl", 1, NULL},          {"cons?", 1, NULL},
    {"cn", 2, NULL},          {"pos", 2, NULL},
    {"tlstr", 1, NULL},       {"str", 1, NULL},
    {"string?", 1, NULL},     {"n->string", 1, NULL},
    {"string->n", 1, NULL},   {"intern", 1, NULL},
    {"absvector", 1, NULL},   {"absvector?", 1, NULL},
    {"<-address", 2, NULL},   {"address->", 3, NULL},
    {"set", 2, NULL},         {"value", 1, NULL},
    {"simple-error", 1, NULL}, {"error-to-string", 1, NULL},
    {"eval-kl", 1, NULL},     {"get-time", 1, NULL},
    {"open", 2, NULL},        {"close", 1, NULL},
    {"read-byte", 1, NULL},   {"write-byte", 2, NULL},
    {"char-stream?", 1, NULL}, {"read-unit-string", 1, NULL},
    {"write-string", 2, NULL},
    {"shen-jit.install", 1, NULL},
    {"shen-jit.fixnum?", 1, NULL},
    {"shen-jit.symbol?", 1, NULL},
    {"shen-jit.hash", 2, NULL},
    {"shen-jit.exit", 1, NULL},
    {"shen-jit.symbol-kind", 1, NULL},
    {"shen-jit.filled-vector", 2, NULL},
    {"shen-jit.dict-find", 2, NULL},
    {"shen-jit.dict-put", 3, NULL},
    {"shen-jit.dict-remove", 2, NULL},
    {"shen-jit.dict-entries", 1, NULL},
    {"shen-jit.tagged?", 2, NULL},
    {"shen-jit.sealed?", 1, NULL},
    {"shen-jit.sealing", 1, NULL},
    {"shen-jit.inline-body", 1, NULL},
    {"shen-jit.vector?", 1, NULL},
    {"shen-jit.absvector3", 3, NULL},
    {"shen-jit.quiet?", 0, NULL},
    {"shen-jit.mark-toplevel", 0, NULL},
    {"shen-jit.trace-text", 1, NULL},
    {"shen-jit.backtrace", 0, NULL},
    {"shen-jit.read-file", 2, NULL},
    {"shen-jit.integer?", 1, NULL},
    {"shen-jit.append", 2, NULL},
    {"shen-jit.arity?", 2, NULL},
    {"shen-jit.inlined?", 2, NULL},
    {"shen-jit.save-executable", 2, NULL},
    {"shen-jit.bytes", 1, NULL},
    {"shen-jit.bytes?", 1, NULL},
    {"shen-jit.bytes-length", 1, NULL},
    {"shen-jit.u8", 2, NULL},
    {"shen-jit.u16", 2, NULL},
    {"shen-jit.u32", 2, NULL},
    {"shen-jit.u8!", 3, NULL},
    {"shen-jit.u16!", 3, NULL},
    {"shen-jit.u32!", 3, NULL},
    {"shen-jit.s32", 2, NULL},
    {"shen-jit.s64", 2, NULL},
    {"shen-jit.f32", 2, NULL},
    {"shen-jit.f64", 2, NULL},
    {"shen-jit.s32!", 3, NULL},
    {"shen-jit.s64!", 3, NULL},
    {"shen-jit.f32!", 3, NULL},
    {"shen-jit.f64!", 3, NULL},
    {"shen-jit.string->bytes", 1, NULL},
    {"shen-jit.bytes->string", 3, NULL},
    {"shen-jit.copy-bytes", 5, NULL},
    {"shen-jit.bit-and", 2, NULL},
    {"shen-jit.bit-or", 2, NULL},
    {"shen-jit.bit-xor", 2, NULL},
    {"shen-jit.bit-not", 1, NULL},
    {"shen-jit.shift-left", 2, NULL},
    {"shen-jit.shift-right", 2, NULL},
    {"shen-jit.rotate32", 2, NULL},
    {"shen-jit.bswap32", 1, NULL},
    {"shen-jit.popcount", 1, NULL},
    {"shen-jit.clz", 1, NULL},
    {"shen-jit.ctz", 1, NULL},
    {"shen-jit.decimal", 2, NULL},
    {"shen-jit.pvar", 1, NULL},
    {"shen-jit.pvar?", 1, NULL},
    {"shen-jit.pvar-offset", 1, NULL},
    {"shen-jit.deref", 3, NULL},
    {"shen-jit.same?", 2, NULL},
    {"shen-jit.newpv", 2, NULL},
    {"shen-jit.gc", 2, NULL},
    {"shen-jit.thread", 1, NULL},
    {"shen-jit.foreign", 2, NULL},
    {"shen-jit.pointer?", 1, NULL},
    {"shen-jit.pointer-kind", 1, NULL},
    {"shen-jit.pointer-address", 1, NULL},
    {"shen-jit.bytes->pointer", 3, NULL},
    {"shen-jit.pointer->string", 1, NULL},
    {"shen-jit.pointer->bytes", 3, NULL},
    {"shen-jit.errno", 0, NULL},
    {"shen-jit.c-errno", 0, NULL},
    {"shen-jit.pointer-kill", 1, NULL},
    {"shen-jit.pointer-sized", 2, NULL},
    {"shen-jit.pointer!", 3, NULL},
    {"shen-jit.pointer-guard", 2, NULL},
    {"shen-jit.pointer-owner", 1, NULL},
    {"shen-jit.pointers-dead", 0, NULL},
    {"shen-jit.pointer-read-only", 1, NULL},
    {"shen-jit.collect", 0, NULL},
    {"shen-jit.write-bytes", 4, NULL},
    {"shen-jit.worker-scope", 5, NULL},
    {"shen-jit.worker-batch", 2, NULL},
    {"shen-jit.worker-index", 0, NULL},
    {"shen-jit.worker-live", 0, NULL},
    {"shen-jit.worker-cancelled?", 0, NULL},
    {"shen-jit.worker-shared-view", 0, NULL},
    {"shen-jit.arity", 1, NULL},
    {"shen-jit.set-arity", 2, NULL},
    {"shen-jit.function", 1, NULL},
    {"shen-jit.apply", 2, NULL},
};

const size_t primitive_count = sizeof primitive_table / sizeof primitive_table[0];

/* Raising from C costs one small allocation. The message is a string
   literal, whose string is made once and cached by address; an offending
   value is kept beside it, and exception_message puts the two together only
   when the text is asked for. */
enum { MESSAGE_CACHE = sizeof ((VM *)0)->message_keys / sizeof (const char *) };

static V message_string(VM *vm, const char *message)
{
    size_t i = ((uintptr_t)message >> 3) % MESSAGE_CACHE;
    if (vm->messages != V_NIL && vm->message_keys[i] == message && ptr(vm->messages)[1 + i] != V_NIL)
        return ptr(vm->messages)[1 + i];
    if (vm->messages == V_NIL) {
        V cache = make_vector(vm, MESSAGE_CACHE, V_NIL);
        if (cache == V_CLEARED)
            return V_CLEARED;
        vm->messages = cache;
    }
    V s = make_string(vm, message, strlen(message));
    if (s != V_CLEARED) {
        ptr(vm->messages)[1 + i] = s;
        vm->message_keys[i] = message;
    }
    return s;
}

/* An error raised while the innermost handler is quiet needs no exception:
   that handler's code never reads it (Handler, vm.h). */
static bool quiet_handler(VM *vm)
{
    return vm->nhandlers && (vm->handlers[vm->nhandlers - 1].fp_offset & 1);
}

/* Backtraces: an error that the program does not
   catch records the frames on the stack, which the REPL or main prints: one
   raised with no handler active, or whose innermost handler is the REPL's
   (its frame is at or below the REPL's floor). Only the first such error in
   each REPL evaluation is kept, since the kernel's REPL raises some again
   from its own frames. Errors that the program catches record nothing, so
   they stay as cheap as before. */
enum { TRACE_FRAMES = 256, TRACE_LINES = 24 };

static void capture_trace(VM *vm)
{
    if (vm->trace != V_NIL ||
        (vm->nhandlers && (vm->trace_floor == SIZE_MAX ||
                           (vm->handlers[vm->nhandlers - 1].fp_offset >> 1) > vm->trace_floor)))
        return;
    bool evaluated;
    size_t n = jit_backtrace(vm, NULL, 0, &evaluated);
    if (!evaluated || n == 0)
        return; /* not from running code, or raised where it was written */
    size_t k = n < TRACE_FRAMES ? n : TRACE_FRAMES;
    V t = make_vector(vm, 1 + k, V_NIL);
    if (t == V_CLEARED)
        return;
    ptr(t)[1] = fix((int64_t)n);
    jit_backtrace(vm, ptr(t) + 2, k, &evaluated); /* after the allocation, which may move them */
    vm->trace = t;
}

/* The captured backtrace as lines "  in NAME", innermost first, a run of
   one name being one line with its count, at most TRACE_LINES of them.
   Empty when nothing was captured. */
size_t sj_trace_text(VM *vm, char *text, size_t size, bool newline_first)
{
    size_t len = 0;
    text[0] = 0;
    if (vm->trace == V_NIL)
        return 0;
    size_t total = (size_t)fixval(ptr(vm->trace)[1]), k = hdr_size(ptr(vm->trace)[0]) - 1, lines = 0, i = 0;
    while (i < k && lines < TRACE_LINES && len + 128 < size) {
        V name = ptr(vm->trace)[2 + i];
        size_t run = 1;
        while (i + run < k && ptr(vm->trace)[2 + i + run] == name)
            run++;
        int namelen = is_symbol(name) ? (int)string_length(ptr(name)[SYM_NAME]) : 1;
        const char *bytes = is_symbol(name) ? string_bytes(ptr(name)[SYM_NAME]) : "?";
        len += (size_t)snprintf(text + len, size - len, "%s  in %.*s", (len || newline_first) ? "\n" : "",
                                namelen > 64 ? 64 : namelen, bytes);
        if (run > 1)
            len += (size_t)snprintf(text + len, size - len, " (%zu times)", run);
        i += run;
        lines++;
    }
    if (i < total)
        len += (size_t)snprintf(text + len, size - len, "%s  ... %zu more", len ? "\n" : "", total - i);
    return len;
}

/* The value, if any, takes the place of ~S in the message when the text is
   read (exception_message). */
V sj_raise_value(VM *vm, const char *message, V value)
{
    if (quiet_handler(vm)) {
        vm->exception = V_NIL;
        return V_CLEARED;
    }
    vm_root(vm, &value);
    capture_trace(vm);
    V s = message_string(vm, message);
    V e = s == V_CLEARED ? V_CLEARED : make_exception(vm, s, value);
    vm_unroot(vm, 1);
    vm->exception = e == V_CLEARED ? V_NIL : e;
    return V_CLEARED;
}

V sj_raise(VM *vm, const char *message) { return sj_raise_value(vm, message, V_CLEARED); }

/* What a constructor made, or "out of memory" raised when it could not (objects.c). */
static V made(VM *vm, V v) { return v == V_CLEARED ? sj_raise(vm, "out of memory") : v; }

/* For rare errors whose text is built when they are raised, or lasts no longer. */
V sj_raise_text_value(VM *vm, const char *text, V value)
{
    if (quiet_handler(vm)) {
        vm->exception = V_NIL;
        return V_CLEARED;
    }
    vm_root(vm, &value);
    capture_trace(vm);
    V s = make_string(vm, text, strlen(text));
    V e = s == V_CLEARED ? V_CLEARED : make_exception(vm, s, value);
    vm_unroot(vm, 1);
    vm->exception = e == V_CLEARED ? V_NIL : e;
    return V_CLEARED;
}

V sj_raise_text(VM *vm, const char *text) { return sj_raise_text_value(vm, text, V_CLEARED); }

static bool is_real(V v) { return is_object(v) && obj_type(v) == T_REAL; }
static bool is_number(V v) { return is_fix(v) || is_real(v); }
static double number(V v) { return is_fix(v) ? (double)fixval(v) : real_value(v); }
static bool is_type(V v, unsigned type) { return is_object(v) && obj_type(v) == type; }

static void pointer_text(V v, char *text, size_t size)
{
    V kind = ptr(ptr(v)[POINTER_KIND])[SYM_NAME];
    snprintf(text, size, "#<pointer %.*s 0x%llx>", string_length(kind) < 40 ? (int)string_length(kind) : 40,
             string_bytes(kind), (unsigned long long)ptr(v)[POINTER_ADDRESS]);
}

/* Two values that are not identical, each a fixnum, a symbol or another
   immediate, are not equal: only a real can equal a fixnum it is not. */
static bool distinct_atoms(V a, V b)
{
    return (!is_ptr(a) || is_symbol(a)) && (!is_ptr(b) || is_symbol(b));
}

/* Where fixnum i lies against real d, exactly: a double cannot hold every
   fixnum from 2^53 up, so converting i would round it. -1, 0 or 1, as i is
   below, equal to or above d, and 2 if d is NaN. The truncated part of a d in
   range is exact, and what it drops, if anything, says which way a tie goes. */
static int compare_fix_real(int64_t i, double d)
{
    if (d != d)
        return 2;
    if (d >= 0x1p63)
        return -1;
    if (d < -0x1p63)
        return 1;
    int64_t t = (int64_t)d;
    if (i != t)
        return i < t ? -1 : 1;
    double rest = d - (double)t;
    return rest > 0 ? -1 : rest < 0 ? 1 : 0;
}

/* Equality needs no ordering result. Truncate only inside int64_t range,
   then require both an exact integer match and no fractional remainder. */
static bool equal_fix_real(int64_t i, double d)
{
    return d >= -0x1p63 && d < 0x1p63 && (int64_t)d == i && (double)(int64_t)d == d;
}

/* Heads and elements are compared by recursion up to a depth that the margin
   of a C stack can hold, and past it by equal_deep. */
enum { EQUAL_DEPTH = 256 };

static bool equal_deep(V a, V b);

static bool equal_pairs(V a, V b, unsigned depth);

static bool equal_part(V a, V b, unsigned depth)
{
    if (depth >= EQUAL_DEPTH)
        return equal_deep(a, b);
    return is_pair(a) ? is_pair(b) && equal_pairs(a, b, depth + 1) : sj_equal_at(a, b, depth + 1);
}

/* = (docs/semantics.md, section 6). Lists are walked along their tails, and a
   head identical to the other is not compared further, nor are two distinct
   atoms. Strings compare whole words: equal headers mean equal lengths, and
   the padding is always 0. */
/* a and b are distinct pairs; tails stay in this loop, heads use equal_part. */
static __attribute__((noinline)) bool equal_pairs(V a, V b, unsigned depth)
{
    for (;;) {
        V ha = ptr(a)[0], hb = ptr(b)[0];
        if (ha != hb && (distinct_atoms(ha, hb) || !equal_part(ha, hb, depth)))
            return false;
        a = ptr(a)[1];
        b = ptr(b)[1];
        if (a == b)
            return true;
        if (!is_pair(a))
            return sj_equal_at(a, b, depth);
        if (!is_pair(b))
            return false;
    }
}

bool sj_equal_at(V a, V b, unsigned depth)
{
    if (a == b)
        return true;
    if (is_pair(a))
        return is_pair(b) && equal_pairs(a, b, depth);
    if (is_number(a) && is_number(b))
        return is_fix(a) ? is_real(b) && equal_fix_real(fixval(a), real_value(b))
               : is_fix(b) ? equal_fix_real(fixval(b), real_value(a))
                           : real_value(a) == real_value(b);
    if ((is_type(a, T_STRING) && is_type(b, T_STRING)) || (is_type(a, T_BYTES) && is_type(b, T_BYTES))) {
        if (ptr(a)[0] != ptr(b)[0])
            return false;
        for (size_t i = 1, n = byte_object_words(hdr_size(ptr(a)[0])); i < n; i++)
            if (ptr(a)[i] != ptr(b)[i])
                return false;
        return true;
    }
    if (is_type(a, T_VECTOR) && is_type(b, T_VECTOR)) {
        size_t n = (size_t)hdr_size(ptr(a)[0]);
        if (n != hdr_size(ptr(b)[0]))
            return false;
        for (size_t i = 0; i < n; i++) {
            V x = ptr(a)[1 + i], y = ptr(b)[1 + i];
            if (x != y && (distinct_atoms(x, y) || !equal_part(x, y, depth)))
                return false;
        }
        return true;
    }
    if (is_type(a, T_POINTER) && is_type(b, T_POINTER))
        return ptr(a)[0] == ptr(b)[0] && ptr(a)[POINTER_KIND] == ptr(b)[POINTER_KIND] &&
               ptr(a)[POINTER_ADDRESS] == ptr(b)[POINTER_ADDRESS];
    return false;
}

/* = with the pairs still to compare in a list of its own, so no deeper on the C
   stack however deep the terms. What is neither two pairs nor two absvectors
   does not recurse, and values that settle at once, as in sj_equal, never go on
   the list. It cannot raise, having no frame (jit.c, h_equal), so what looks
   like a cycle ends the process, as overflowing the C stack did. */
enum { EQUAL_DEEP_ROOM = 1 << 28 }; /* words: 2 GiB */

static void equal_deep_fail(const char *why)
{
    fprintf(stderr, "shen-jit: =: %s\n", why);
    exit(1);
}

static bool equal_deep(V a, V b)
{
    size_t room = 64, count = 0, steps = 0;
    V *todo = malloc(room * sizeof(V));
    if (!todo)
        equal_deep_fail("out of memory");
    todo[count++] = a;
    todo[count++] = b;
    bool same = true;
    while (same && count) {
        b = todo[--count];
        a = todo[--count];
        bool pairs = is_pair(a) && is_pair(b);
        bool vectors = is_type(a, T_VECTOR) && is_type(b, T_VECTOR);
        if (!pairs && !vectors) {
            same = sj_equal(a, b);
            continue;
        }
        size_t n = pairs ? 2 : (size_t)hdr_size(ptr(a)[0]);
        if (vectors && n != hdr_size(ptr(b)[0])) {
            same = false;
            continue;
        }
        if (count + 2 * n > room) {
            room = (count + 2 * n) * 2;
            todo = room <= EQUAL_DEEP_ROOM ? realloc(todo, room * sizeof(V)) : NULL;
            if (!todo)
                equal_deep_fail("the term is cyclic or too large");
        }
        if (++steps > (size_t)1 << 31) /* a cycle may not grow the list */
            equal_deep_fail("the term is cyclic or too large");
        for (size_t i = n; i-- > 0;) {
            V x = ptr(a)[(pairs ? 0 : 1) + i], y = ptr(b)[(pairs ? 0 : 1) + i];
            if (x == y)
                continue;
            if (distinct_atoms(x, y)) {
                same = false;
                break;
            }
            todo[count++] = x;
            todo[count++] = y;
        }
    }
    free(todo);
    return same;
}

static V boolean(bool b) { return b ? V_TRUE : V_FALSE; }

static V arithmetic(VM *vm, unsigned prim, V a, V b)
{
    if (!is_number(a))
        return sj_raise_value(vm, "~S is not a number", a);
    if (!is_number(b))
        return sj_raise_value(vm, "~S is not a number", b);
    if (prim == P_DIV && (is_fix(b) ? fixval(b) == 0 : real_value(b) == 0.0))
        return sj_raise(vm, "division by zero");
    if (is_fix(a) && is_fix(b)) {
        int64_t x = fixval(a), y = fixval(b), r = 0;
        bool overflow = false;
        switch (prim) {
        case P_ADD: overflow = __builtin_add_overflow(x, y, &r); break;
        case P_SUB: overflow = __builtin_sub_overflow(x, y, &r); break;
        case P_MUL: overflow = __builtin_mul_overflow(x, y, &r); break;
        default: /* P_DIV */
            if (x % y != 0)
                return made(vm, make_real(vm, (double)x / (double)y));
            r = x / y;
        }
        if (overflow || !fix_fits(r))
            return sj_raise(vm, "integer overflow");
        return fix(r);
    }
    double x = number(a), y = number(b);
    switch (prim) {
    case P_ADD: return made(vm, make_real(vm, x + y));
    case P_SUB: return made(vm, make_real(vm, x - y));
    case P_MUL: return made(vm, make_real(vm, x * y));
    default: return made(vm, make_real(vm, x / y));
    }
}

static V comparison(VM *vm, unsigned prim, V a, V b)
{
    if (!is_number(a))
        return sj_raise_value(vm, "~S is not a number", a);
    if (!is_number(b))
        return sj_raise_value(vm, "~S is not a number", b);
    /* Reduced to a comparison of doubles that is exact, and false for NaN. */
    double x, y = 0;
    if (is_fix(a) && is_fix(b)) {
        x = (double)((fixval(a) > fixval(b)) - (fixval(a) < fixval(b)));
    } else if (is_fix(a)) {
        int order = compare_fix_real(fixval(a), real_value(b));
        x = order == 2 ? NAN : order;
    } else if (is_fix(b)) {
        int order = compare_fix_real(fixval(b), real_value(a));
        x = order == 2 ? NAN : -order;
    } else {
        x = real_value(a);
        y = real_value(b);
    }
    switch (prim) {
    case P_LT: return boolean(x < y);
    case P_GT: return boolean(x > y);
    case P_LE: return boolean(x <= y);
    default: return boolean(x >= y);
    }
}

static V fail_symbol(VM *vm)
{
    if (vm->fail == V_NIL)
        vm->fail = intern_cstr(vm, "shen.fail!");
    V fail = vm->fail;
    if (fail == V_CLEARED)
        vm->fail = V_NIL;
    return fail;
}

/* hash (docs/semantics.md, section 6): consistent with =, so numbers hash by
   mathematical value, strings by bytes, symbols by their stored name hash,
   and pairs and absvectors by their elements. Procedures, streams and
   exceptions hash by family, since they have no stable address. A budget
   bounds the work on large structures; equal values are walked the same way,
   so they spend it identically. */
static uint64_t mix(uint64_t x)
{
    x ^= x >> 33;
    x *= UINT64_C(0xff51afd7ed558ccd);
    x ^= x >> 33;
    x *= UINT64_C(0xc4ceb9fe1a85ec53);
    return x ^ (x >> 33);
}

static uint64_t hash_value(V v, int *budget)
{
    if (--*budget < 0)
        return 0;
    if (is_fix(v))
        return mix((uint64_t)fixval(v));
    if (is_real(v)) {
        double d = real_value(v);
        if (d == trunc(d) && fabs(d) < 9.2e18)
            return mix((uint64_t)(int64_t)d); /* 8.0 like 8, -0.0 like 0 */
        uint64_t bits;
        memcpy(&bits, &d, sizeof bits);
        return mix(bits);
    }
    if (is_symbol(v))
        return ptr(v)[SYM_HASH];
    if (is_pair(v)) {
        uint64_t h = 0x70;
        for (; is_pair(v) && *budget > 0; v = ptr(v)[1])
            h = mix(h ^ hash_value(ptr(v)[0], budget));
        return mix(h ^ hash_value(v, budget));
    }
    if (is_type(v, T_STRING) || is_type(v, T_BYTES))
        return hash_bytes(string_bytes(v), string_length(v));
    if (is_type(v, T_VECTOR)) {
        uint64_t h = 0x76;
        for (size_t i = 0; i < hdr_size(ptr(v)[0]) && *budget > 0; i++)
            h = mix(h ^ hash_value(ptr(v)[1 + i], budget));
        return h;
    }
    if (is_type(v, T_POINTER))
        return mix(ptr(ptr(v)[POINTER_KIND])[SYM_HASH] ^ ptr(v)[POINTER_ADDRESS]);
    if (!is_ptr(v))
        return mix(v); /* specials */
    return mix(is_proc(v) ? 0x50 : obj_type(v));
}

/* The 256 one-byte strings, made on first use and shared by pos and
   n->string; strings are immutable, so sharing them is invisible. */
static V byte_string(VM *vm, unsigned byte)
{
    if (vm->chars == V_NIL) {
        V chars = make_vector(vm, 256, V_NIL);
        if (chars == V_CLEARED)
            return sj_raise(vm, "out of memory");
        vm->chars = chars;
        for (unsigned i = 0; i < 256; i++) {
            char c = (char)i;
            V s = make_string(vm, &c, 1);
            if (s == V_CLEARED) {
                vm->chars = V_NIL;
                return sj_raise(vm, "out of memory");
            }
            ptr(vm->chars)[1 + i] = s;
        }
    }
    return ptr(vm->chars)[1 + byte];
}

uint64_t sj_hash(V v)
{
    int budget = 256;
    return hash_value(v, &budget);
}

/* shen-jit.symbol-kind: 0 for what the kernel's symbol? rejects, 1 for a
   symbol, 2 for a variable, computed when the symbol was made (objects.c). */
static V symbol_kind(V v) { return fix(is_symbol(v) ? (int64_t)((ptr(v)[SYM_CELL] >> 56) & 3) : 0); }

/* The kernel's portable hash returns 1 to Bound - 1, never 0. */
static V hash(VM *vm, V v, V bound)
{
    if (!is_fix(bound) || fixval(bound) <= 0)
        return sj_raise_value(vm, "hash: ~S is not a valid bound", bound);
    uint64_t h = sj_hash(v) % (uint64_t)fixval(bound);
    return fix(h == 0 ? 1 : (int64_t)h);
}

/* Strings (docs/semantics.md, section 4): immutable byte sequences. */

static V alloc_string(VM *vm, size_t len)
{
    uint64_t h = HEADER(T_STRING, len);
    uint64_t *p = vm_alloc_object(vm, obj_words(h));
    if (!p)
        return sj_raise(vm, "out of memory");
    p[0] = h;
    p[obj_words(h) - 1] = 0;
    return tagged(p, TAG_OBJECT);
}

/* A substring of vm->args[0], copied after allocating. */
static V substring(VM *vm, size_t from, size_t len)
{
    V s = alloc_string(vm, len);
    if (s != V_CLEARED)
        memcpy(string_bytes(s), string_bytes(vm->args[0]) + from, len);
    return s;
}

static V concatenate(VM *vm)
{
    size_t la = string_length(vm->args[0]), lb = string_length(vm->args[1]);
    V s = alloc_string(vm, la + lb);
    if (s != V_CLEARED) {
        memcpy(string_bytes(s), string_bytes(vm->args[0]), la);
        memcpy(string_bytes(s) + la, string_bytes(vm->args[1]), lb);
    }
    return s;
}

/* Reals print with the shortest digits that read back exactly, always with a
   decimal point or an exponent, and exponents as Chez prints them. */
static void format_real(double d, char *out, size_t cap)
{
    if (isnan(d)) {
        snprintf(out, cap, "+nan.0");
        return;
    }
    if (isinf(d)) {
        snprintf(out, cap, d > 0 ? "+inf.0" : "-inf.0");
        return;
    }
    char buf[48];
    for (int precision = 15; precision <= 17; precision++) {
        snprintf(buf, sizeof buf, "%.*g", precision, d);
        if (strtod(buf, NULL) == d)
            break;
    }
    char *e = strchr(buf, 'e');
    if (e) {
        char mantissa[48], *digits = e + 1;
        bool negative = *digits == '-';
        if (*digits == '+' || *digits == '-')
            digits++;
        while (digits[0] == '0' && digits[1])
            digits++;
        *e = 0;
        snprintf(mantissa, sizeof mantissa, "%s", buf);
        snprintf(out, cap, "%se%s%s", mantissa, negative ? "-" : "", digits);
    } else {
        snprintf(out, cap, strchr(buf, '.') ? "%s" : "%s.0", buf);
    }
}

/* Error messages show the offending value in Shen notation, cut after
   SHOW_MAX bytes so that a large or circular value cannot flood them. */
enum { SHOW_MAX = 60 };

typedef struct {
    char text[SHOW_MAX + 3];
    size_t len;
    bool cut;
} Show;

static void put(Show *s, const char *bytes, size_t n)
{
    if (s->len + n > SHOW_MAX) {
        n = SHOW_MAX - s->len;
        s->cut = true;
    }
    memcpy(s->text + s->len, bytes, n);
    s->len += n;
}

static void put_text(Show *s, const char *text) { put(s, text, strlen(text)); }

/* Error-to-string is on the path of some handlers, so integers avoid
   snprintf, which is slow. */
static void put_int(Show *s, int64_t n)
{
    char digits[24], *p = digits + sizeof digits;
    uint64_t u = n < 0 ? -(uint64_t)n : (uint64_t)n;
    do
        *--p = (char)('0' + u % 10);
    while (u /= 10);
    if (n < 0)
        *--p = '-';
    put(s, p, (size_t)(digits + sizeof digits - p));
}

static void show(VM *vm, Show *s, V v)
{
    if (s->cut)
        return;
    if (is_pair(v)) {
        put_text(s, "[");
        for (show(vm, s, ptr(v)[0]); is_pair(v = ptr(v)[1]) && !s->cut; show(vm, s, ptr(v)[0]))
            put_text(s, " ");
        if (v != V_NIL && !s->cut) {
            put_text(s, " | ");
            show(vm, s, v);
        }
        put_text(s, "]");
    } else if (is_type(v, T_VECTOR) && hdr_size(ptr(v)[0]) == 3 && is_symbol(ptr(v)[1]) &&
               string_length(ptr(ptr(v)[1])[SYM_NAME]) == 10 &&
               memcmp(string_bytes(ptr(ptr(v)[1])[SYM_NAME]), "shen.tuple", 10) == 0) {
        put_text(s, "(@p ");
        show(vm, s, ptr(v)[2]);
        put_text(s, " ");
        show(vm, s, ptr(v)[3]);
        put_text(s, ")");
    } else if (is_type(v, T_VECTOR)) {
        /* A vector is <1 2 3>, with ... for an element not set; any other
           absvector is <<...>> with all its elements. */
        size_t n = (size_t)hdr_size(ptr(v)[0]), first = 0;
        bool vector = n > 0 && is_fix(ptr(v)[1]) && fixval(ptr(v)[1]) >= 0 &&
                      (size_t)fixval(ptr(v)[1]) < n;
        if (vector) {
            first = 1;
            n = 1 + (size_t)fixval(ptr(v)[1]);
        }
        put_text(s, vector ? "<" : "<<");
        for (size_t i = first; i < n && !s->cut; i++) {
            if (i > first)
                put_text(s, " ");
            if (vector && ptr(v)[1 + i] == vm->fail)
                put_text(s, "...");
            else
                show(vm, s, ptr(v)[1 + i]);
        }
        put_text(s, vector ? ">" : ">>");
    } else if (is_type(v, T_STRING)) {
        put_text(s, "\"");
        put(s, string_bytes(v), string_length(v));
        put_text(s, "\"");
    } else if (is_symbol(v)) {
        put(s, string_bytes(ptr(v)[SYM_NAME]), string_length(ptr(v)[SYM_NAME]));
    } else if (is_fix(v)) {
        put_int(s, fixval(v));
    } else if (is_real(v)) {
        char small[48];
        format_real(real_value(v), small, sizeof small);
        put_text(s, small);
    } else if (is_pvar(v)) {
        put_text(s, "Var");
        put_int(s, (int64_t)pvar_offset(v));
    } else if (is_type(v, T_POINTER)) {
        char small[80];
        pointer_text(v, small, sizeof small);
        put_text(s, small);
    } else {
        put_text(s, v == V_TRUE ? "true" : v == V_FALSE ? "false" : v == V_NIL ? "[]"
                    : is_proc(v) ? "#<procedure>" : is_type(v, T_STREAM) ? "#<stream>"
                    : is_type(v, T_BYTES) ? "#<bytes>"
                    : is_type(v, T_SHARED_BYTES) ? "#<shared-bytes>"
                    : is_type(v, T_EXCEPTION) ? "#<exception>" : "#<value>");
    }
}

/* An exception's message text, completed with its value on first use, or
   V_CLEARED if there is no memory for it. */
V exception_message(VM *vm, V e)
{
    V value = ptr(e)[EXC_VALUE], m = ptr(e)[EXC_MESSAGE];
    if (value == V_CLEARED)
        return m;
    Show s = {.len = 0};
    show(vm, &s, value);
    if (s.cut) {
        memcpy(s.text + s.len, "...", 3);
        s.len += 3;
    }
    const char *bytes = string_bytes(m);
    size_t len = string_length(m), at = 0, n;
    if (len > 180)
        len = 180; /* messages are literals in the runtime, much shorter */
    while (at + 1 < len && !(bytes[at] == '~' && bytes[at + 1] == 'S'))
        at++;
    bool found = at + 1 < len;
    char text[256];
    if (found) {
        memcpy(text, bytes, at);
        n = at;
    } else { /* the value follows the message */
        memcpy(text, bytes, len);
        text[len] = ' ';
        n = at = len + 1;
    }
    memcpy(text + n, s.text, s.len);
    n += s.len;
    if (found) {
        memcpy(text + n, bytes + at + 2, len - at - 2);
        n += len - at - 2;
    }
    vm_root(vm, &e);
    V string = make_string(vm, text, n);
    vm_unroot(vm, 1);
    if (string != V_CLEARED) {
        ptr(e)[EXC_MESSAGE] = string;
        ptr(e)[EXC_VALUE] = V_CLEARED;
    }
    return string;
}

static V to_string(VM *vm, V v)
{
    char small[80];
    const char *text = small;
    size_t len;
    if (is_fix(v))
        snprintf(small, sizeof small, "%lld", (long long)fixval(v));
    else if (v == V_TRUE || v == V_FALSE)
        text = v == V_TRUE ? "true" : "false";
    else if (v == V_NIL)
        text = "()";
    else if (is_pvar(v))
        snprintf(small, sizeof small, "Var%llu", (unsigned long long)pvar_offset(v));
    else if (is_symbol(v)) /* strings are immutable, so the name itself */
        return ptr(v)[SYM_NAME];
    else if (is_type(v, T_STRING)) {
        size_t n = string_length(v);
        V s = alloc_string(vm, n + 2);
        if (s != V_CLEARED) {
            string_bytes(s)[0] = '"';
            memcpy(string_bytes(s) + 1, string_bytes(vm->args[0]), n);
            string_bytes(s)[n + 1] = '"';
        }
        return s;
    } else if (is_real(v))
        format_real(real_value(v), small, sizeof small);
    else if (is_pair(v))
        text = "#<pair>";
    else if (is_proc(v))
        text = "#<procedure>";
    else if (is_type(v, T_VECTOR))
        text = "#<absvector>";
    else if (is_type(v, T_STREAM))
        text = "#<stream>";
    else if (is_type(v, T_BYTES))
        text = "#<bytes>";
    else if (is_type(v, T_SHARED_BYTES))
        text = "#<shared-bytes>";
    else if (is_type(v, T_EXCEPTION))
        text = "#<exception>";
    else if (is_type(v, T_POINTER))
        pointer_text(v, small, sizeof small);
    else
        text = "#<value>";
    len = strlen(text);
    return made(vm, make_string(vm, text, len));
}

/* Streams (docs/semantics.md, section 12). */

static FILE *stream_file(VM *vm, V s, bool output)
{
    /* An image can retain aliases to its original standard streams, even
       after sj_init_host replaces the three standard-stream globals. */
    if (vm->worker_owner)
        return NULL;
    if (!is_type(s, T_STREAM))
        return NULL;
    uint64_t flags = ptr(s)[STREAM_FLAGS];
    if (!(flags & STREAM_OPEN) || !(flags & STREAM_OUTPUT) != !output)
        return NULL;
    return (FILE *)(uintptr_t)ptr(s)[STREAM_HANDLE];
}

/* Interning can allocate and move symbols, so intern first and read the
   operands from their rooted slots afterwards. */
/* vm->args[0], a path relative to *home-directory*, as open takes it: a
   malloc'd name, or NULL. */
static char *home_path(VM *vm)
{
    V home_symbol = intern_cstr(vm, "*home-directory*");
    if (home_symbol == V_CLEARED)
        return NULL;
    V home = global_value(vm, home_symbol), path = vm->args[0];
    size_t lh = is_type(home, T_STRING) ? string_length(home) : 0, lp = string_length(path);
    char *name = malloc(lh + lp + 1);
    if (!name)
        return NULL;
    if (lh)
        memcpy(name, string_bytes(home), lh);
    memcpy(name + lh, string_bytes(path), lp);
    name[lh + lp] = 0;
    return name;
}

static FILE *open_path(VM *vm, const char *mode)
{
    char *name = home_path(vm);
    FILE *f = name ? sj_fopen(name, mode) : NULL;
    free(name);
    return f;
}

/* (shen-jit.save-executable Path Entry) writes a binary at Path, relative to
   *home-directory* as open is: the runtime of this one and an image of the
   heap. Entry is a function of no arguments to run instead of the launcher, or
   []. It does not return. As for --save, the image holds what the cells,
   constants and symbols reach and no frames, so there is nothing to go on
   with: here the frames are dropped, as the launcher's return does. The file
   is written beside Path and renamed, so a binary can replace itself. */
static V save_executable(VM *vm)
{
    if (vm->worker_owner || vm->worker_scope)
        return sj_raise(vm, "worker: saving an executable is a host-only operation");
    if (!thread_is_only(vm))
        return sj_raise(vm, "save-executable: other threads are running");
    V path = vm->args[0], entry = vm->args[1];
    if (!is_type(path, T_STRING))
        return sj_raise_value(vm, "~S is not a path", path);
    if (entry != V_NIL) {
        V f = is_symbol(entry) ? *cell_function(vm, symbol_cell(entry)) : V_NIL;
        if (!is_proc(f) || hdr_type(ptr(f)[0]) != T_CLOSURE ||
            (ptr(ptr(f)[CLO_CODE])[CODE_ARITY] & UINT32_MAX) != 0)
            return sj_raise_value(vm, "~S is not a function of no arguments", entry);
    }
    if (!vm->self)
        return sj_raise(vm, "save-executable: not running from an executable");
    char *name = home_path(vm), *temporary = name ? malloc(strlen(name) + 5) : NULL;
    if (temporary)
        sprintf(temporary, "%s.tmp", name);
    /* Symbols never move, and these have values, so nothing drops them. */
    V *home = global_slot_new(vm, intern_cstr(vm, "*home-directory*"));
    V *hush = global_slot_new(vm, intern_cstr(vm, "*hush*"));
    V *argv = global_slot_new(vm, intern_cstr(vm, "*argv*"));
    V empty = make_string(vm, "", 0);
    if (!temporary || !home || !hush || !argv || empty == V_CLEARED || !image_copy_runtime(vm->self, temporary)) {
        free(name);
        free(temporary);
        return sj_raise_value(vm, "save-executable: cannot write ~S", vm->args[0]);
    }
    *home = empty; /* where it was built means nothing where it runs */
    /* Nothing else keeps this symbol alive, so its value is set before anything can
       collect, which would drop it. */
    V *entry_slot = global_slot_new(vm, intern_cstr(vm, "shen-jit.*entry*"));
    if (!entry_slot) {
        free(name);
        free(temporary);
        return sj_raise(vm, "out of memory");
    }
    *entry_slot = vm->args[1];
    V *base = vm->stack + vm->launch_base; /* as the launcher's caller keeps them */
    *hush = base[0];
    *argv = base[1];
    vm->fp = vm->top = base;
    /* The old file is replaced only by a whole new one. */
    bool written = image_append(vm, temporary) && chmod(temporary, 0755) == 0;
#ifdef _WIN32
    written = written && win_replace(temporary, name);
#else
    written = written && rename(temporary, name) == 0;
#endif
    if (!written) {
        fprintf(stderr, "shen-jit: cannot write %s\n", name);
        remove(temporary);
        exit(1);
    }
    exit(0); /* flushes every open stream */
}

static V open_file(VM *vm)
{
    if (vm->worker_owner)
        return sj_raise(vm, "worker: a worker cannot open streams");
    V out = intern_cstr(vm, "out"), in = intern_cstr(vm, "in");
    V path = vm->args[0], direction = vm->args[1];
    if (out == V_CLEARED || in == V_CLEARED)
        return sj_raise(vm, "out of memory");
    if (!is_type(path, T_STRING))
        return sj_raise_value(vm, "open: ~S is not a string", path);
    bool output = direction == out;
    if (!output && direction != in)
        return sj_raise_value(vm, "open: the direction ~S is not in or out", direction);
    FILE *f = open_path(vm, output ? "wb" : "rb");
    if (!f)
        return sj_raise_value(vm, "open: cannot open ~S", vm->args[0]);
    V s = make_stream(vm, STREAM_FILE | STREAM_OPEN | (output ? STREAM_OUTPUT : 0), f);
    if (s == V_CLEARED || !vm_track_file(vm, s)) {
        fclose(f);
        return sj_raise(vm, "out of memory");
    }
    return s;
}

/* A failed file operation, with its error saved before cleanup. */
static V raise_io_failed(VM *vm, const char *who, int error)
{
    char text[128];
    snprintf(text, sizeof text, "%s: %s", who, strerror(error ? error : EIO));
    return sj_raise_text(vm, text);
}

/* shen-jit.read-file, behind the port's read-file-as-bytelist and
   read-file-as-string: a whole file, read in C, as a list of its bytes when
   the second argument is true and as a string otherwise. The kernel's read
   one read-byte at a time. */
static V read_file(VM *vm)
{
    if (!is_type(vm->args[0], T_STRING))
        return sj_raise_value(vm, "open: ~S is not a string", vm->args[0]);
    bool bytes = vm->args[1] == V_TRUE;
    FILE *f = open_path(vm, "rb");
    if (!f)
        return sj_raise_value(vm, "open: cannot open ~S", vm->args[0]);
    size_t len = 0, cap = 1 << 16;
    char *text = malloc(cap);
    int read_error = 0;
    while (text) {
        size_t n = fread(text + len, 1, cap - len, f);
        if (ferror(f)) {
            read_error = errno ? errno : EIO;
            break;
        }
        len += n;
        if (!n)
            break;
        if (len == cap) {
            char *more = realloc(text, cap *= 2);
            if (!more)
                free(text);
            text = more;
        }
    }
    fclose(f);
    if (!text)
        return sj_raise(vm, "out of memory");
    if (read_error) {
        free(text);
        return raise_io_failed(vm, "read-file", read_error);
    }
    V v = V_NIL;
    if (!bytes) {
        v = make_string(vm, text, len);
    } else if (len) {
        /* The pairs in one block, from the last byte back. */
        uint64_t *p = vm_alloc(vm, 2 * len);
        if (!p)
            v = V_CLEARED;
        for (size_t i = len; p && i-- > 0;) {
            p[2 * i] = fix((unsigned char)text[i]);
            p[2 * i + 1] = v;
            v = tagged(p + 2 * i, TAG_PAIR);
        }
    }
    free(text);
    return made(vm, v);
}

/* shen-jit.append, behind the port's append: a copy of the first list,
   ending in the second. The kernel's builds one pair per call, on its way
   back from a recursion as deep as the list. The copy goes straight into
   the free space in one pass, and is kept by moving the heap pointer past
   it once the list proves proper; without room for it, or under GC stress,
   the list is counted first and the copy allocated as one block. */
static V append(VM *vm)
{
    V x = vm->args[0];
    uint64_t *start = vm->hp, *q = start;
    if (!vm->stress) {
        for (; is_pair(x) && vm->hlimit - q >= 2; x = ptr(x)[1], q += 2) {
            q[0] = ptr(x)[0];
            q[1] = tagged(q + 2, TAG_PAIR);
        }
        if (x == V_NIL) {
            if (q == start)
                return vm->args[1];
            q[-1] = vm->args[1];
            vm->hp = q;
            return tagged(start, TAG_PAIR);
        }
    }
    size_t n = 0;
    for (x = vm->args[0]; is_pair(x); x = ptr(x)[1])
        n++;
    if (x != V_NIL)
        return sj_raise(vm, "attempt to append a non-list");
    if (n == 0)
        return vm->args[1];
    uint64_t *p = vm_alloc(vm, 2 * n);
    if (!p)
        return sj_raise(vm, "out of memory");
    x = vm->args[0]; /* the allocation may have moved it */
    for (size_t i = 0; i < n; i++, x = ptr(x)[1]) {
        p[2 * i] = ptr(x)[0];
        p[2 * i + 1] = tagged(p + 2 * i + 2, TAG_PAIR);
    }
    p[2 * n - 1] = vm->args[1];
    return tagged(p, TAG_PAIR);
}

static V close_stream(VM *vm, V s)
{
    if (vm->worker_owner)
        return sj_raise(vm, "worker: a worker cannot close streams");
    if (!is_type(s, T_STREAM))
        return sj_raise_value(vm, "close: ~S is not a stream", s);
    uint64_t *o = ptr(s);
    if (o[STREAM_FLAGS] & STREAM_OPEN) {
        FILE *f = (FILE *)(uintptr_t)o[STREAM_HANDLE];
        int failed = (o[STREAM_FLAGS] & STREAM_KIND_MASK) == STREAM_FILE ? fclose(f) : fflush(f);
        o[STREAM_FLAGS] &= ~(uint64_t)STREAM_OPEN;
        if (failed == EOF)
            return raise_io_failed(vm, "close", errno);
    }
    return V_NIL;
}

/* Whether to raise "interrupted" for a pending Ctrl-C. It is raised again from
   every check until the REPL's handler is the innermost, so the program's own
   handlers cannot keep it from reaching the REPL. Outside that handler the REPL
   is printing its prompt or an error, with nothing to stop and nothing to
   catch the error: the Ctrl-C is dropped. */
bool sj_take_interrupt(VM *vm)
{
    if (vm->nhandlers <= vm->repl_handlers) {
        vm->interrupted = 0;
        vm_set_limit(vm, vm->stack_limit);
    }
    return vm->nhandlers >= vm->repl_handlers;
}

/* Standard input is read here rather than through stdio, whose read would
   restart after a Ctrl-C (SA_RESTART, which writes need) and which does not say
   when it is about to wait. The wait is in select, which a signal always ends.
   Only the wait is without the lock, so threads reading at once take turns over
   the buffer: others run meanwhile, and whoever gets the lock first reads. */
static unsigned char input[4096];
static size_t input_next, input_end;

#ifndef _WIN32
static bool input_ready(bool wait)
{
    fd_set in;
    FD_ZERO(&in);
    FD_SET(STDIN_FILENO, &in);
    struct timeval now = {0, 0};
    int ready = select(STDIN_FILENO + 1, &in, NULL, NULL, wait ? NULL : &now);
    return ready > 0 || (ready < 0 && errno != EINTR); /* a bad descriptor: read reports it */
}
#endif

static V read_stdin(VM *vm)
{
    fflush(stdout);
    while (input_next == input_end) {
        /* A Ctrl-C is for the main thread, which the REPL runs in. */
        if (vm->interrupted == INTERRUPT && (!vm->thread || vm->thread->main) && sj_take_interrupt(vm))
            return sj_raise(vm, "interrupted");
#ifdef _WIN32
        /* select is for sockets there, so the read itself waits, without the lock,
           and a Ctrl-C ends it. One thread reads at a time; the others look again. */
        static bool input_busy;
        Thread *t = vm->threads ? thread_leave(vm) : NULL;
        long n = 1;
        if (input_busy) {
            win_sleep_briefly();
        } else {
            input_busy = true;
            n = win_read_input(input, sizeof input);
            input_busy = false;
            if (n > 0) {
                input_next = 0;
                input_end = (size_t)n;
            }
        }
        if (t)
            thread_enter(t);
        if (n == 0)
            return fix(-1);
#else
        if (input_ready(false)) {
            ssize_t n = read(STDIN_FILENO, input, sizeof input);
            if (n <= 0)
                return fix(-1);
            input_next = 0;
            input_end = (size_t)n;
        } else {
            Thread *t = vm->threads ? thread_leave(vm) : NULL;
            input_ready(true);
            if (t)
                thread_enter(t);
        }
#endif
    }
    return fix(input[input_next++]);
}

static V read_byte(VM *vm, V s)
{
    FILE *f = stream_file(vm, s, false);
    if (!f)
        return sj_raise_value(vm, "read-byte: ~S is not an open input stream", s);
    if (f == stdin)
        return read_stdin(vm);
    int c = fgetc(f);
    if (c == EOF && ferror(f))
        return raise_io_failed(vm, "read-byte", errno);
    return fix(c == EOF ? -1 : c);
}

/* Ctrl-C at the REPL, which installs this when it starts (P_MARK_TOPLEVEL):
   it only marks the interrupt and clears the limit compiled code checks
   (vm.h), and ends a wait for input (read_stdin). Elsewhere SIGINT keeps its
   default and ends the process. */
static VM *interrupt_vm;

static void on_interrupt(int sig)
{
    (void)sig;
    interrupt_vm->interrupted = INTERRUPT;
    interrupt_vm->check_limit = NULL;
}

/* Code compiled so far has no loop checks, and from here on a loop without them
   could not be stopped at all: it may have run while a file loaded, before
   the REPL started. */
static void catch_interrupts(VM *vm)
{
    if (interrupt_vm == vm)
        return;
    interrupt_vm = vm;
    if (!vm->interruptible) {
        vm->interruptible = true;
        jit_recompile(vm);
    }
#ifdef _WIN32
    win_catch_interrupts(on_interrupt);
#else
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_interrupt;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
#endif
}

static V write_byte(VM *vm, V b, V s)
{
    FILE *f = stream_file(vm, s, true);
    if (!f)
        return sj_raise_value(vm, "write-byte: ~S is not an open output stream", s);
    if (!is_fix(b) || fixval(b) < 0 || fixval(b) > 255)
        return sj_raise_value(vm, "write-byte: ~S is not a byte", b);
    if (fputc((int)fixval(b), f) == EOF)
        return raise_io_failed(vm, "write-byte", errno);
    return b;
}

static V get_time(VM *vm)
{
    V kind = vm->args[0];
#ifdef _WIN32
    if (symbol_named(kind, "run"))
        return made(vm, make_real(vm, win_run_seconds()));
    if (symbol_named(kind, "unix"))
        return made(vm, make_real(vm, win_unix_seconds()));
#else
    if (symbol_named(kind, "run"))
        return made(vm, make_real(vm, (double)clock() / CLOCKS_PER_SEC));
    if (symbol_named(kind, "unix")) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        return made(vm, make_real(vm, (double)tv.tv_sec + tv.tv_usec * 1e-6));
    }
#endif
    return sj_raise_value(vm, "get-time: ~S is not run or unix", vm->args[0]);
}

/* The standard streams and the host globals the runtime owns. */
bool sj_init_host(VM *vm)
{
    static const struct {
        const char *global;
        uint64_t flags;
    } std[] = {{"*stinput*", STREAM_STDIN | STREAM_OPEN},
               {"*stoutput*", STREAM_STDOUT | STREAM_OUTPUT | STREAM_OPEN},
               {"*sterror*", STREAM_STDERR | STREAM_OUTPUT | STREAM_OPEN}};
    FILE *files[] = {stdin, stdout, stderr};
    for (size_t i = 0; i < 3; i++) {
        V s = make_stream(vm, vm->worker_owner ? 0 : std[i].flags,
                         vm->worker_owner ? NULL : files[i]);
        if (s == V_CLEARED)
            return false;
        vm_root(vm, &s); /* interning may collect */
        V g = intern_cstr(vm, std[i].global);
        vm_unroot(vm, 1);
        V *slot = g == V_CLEARED ? NULL : global_slot_new(vm, g);
        if (!slot)
            return false;
        *slot = s;
    }
    V home = intern_cstr(vm, "*home-directory*");
    if (home == V_CLEARED)
        return false;
    if (global_value(vm, home) == V_CLEARED) {
        V empty = make_string(vm, "", 0);
        if (empty == V_CLEARED)
            return false;
        /* The symbol, with no value yet, may have gone in that allocation, and interning it
           again may collect. */
        vm_root(vm, &empty);
        home = intern_cstr(vm, "*home-directory*");
        vm_unroot(vm, 1);
        V *slot = home == V_CLEARED ? NULL : global_slot_new(vm, home);
        if (!slot)
            return false;
        *slot = empty;
    }
    return true;
}

/* (shen-jit.apply F Args): F's procedure, or F if it is one, called with the elements of a
   list, through a nested call. fn's templates use it for arities above those they spell out. */
static V apply_function(VM *vm, V f, V list)
{
    V proc = is_symbol(f) ? *cell_function(vm, symbol_cell(f)) : f;
    if (!is_proc(proc))
        return is_symbol(f) ? sj_raise_value(vm, "undefined function ~S", f)
                            : sj_raise_value(vm, "~S is not a function", f);
    V args[256];
    size_t n = 0;
    for (; is_pair(list); list = ptr(list)[1]) {
        if (n == 256)
            return sj_raise(vm, "shen-jit.apply: more than 256 arguments");
        args[n++] = ptr(list)[0];
    }
    if (list != V_NIL)
        return sj_raise_value(vm, "shen-jit.apply: ~S is not a list", vm->args[1]);
    return jit_call_nested(vm, proc, n, args);
}

/* An isolate starts as a program does (docs/design.md, "The builder and isolates"): nothing of the builder or
   of its parent, but the program's constants, the standard streams and the run state the
   port's shen-jit.start-isolate sets, its gensyms numbered from gensym_base. Here it starts
   in a VM that was the builder, as a test: its globals are cleared, constants put back as
   the builder would publish them, and it can no longer define. */
bool sj_start_isolate(VM *vm, V gensym_base)
{
    static const char *const constants[] = {"*language*", "*implementation*", "*release*", "*port*",
                                            "*porters*", "*os*", "*version*"};
    enum { N = sizeof constants / sizeof constants[0] };
    V sym[N], value[N];
    for (size_t i = 0; i < N; i++) {
        sym[i] = symbol_find(vm, constants[i], strlen(constants[i]));
        value[i] = sym[i] == V_NIL ? V_CLEARED : global_value(vm, sym[i]);
        vm_root(vm, &value[i]);
    }
    vm->builder = false;
    for (size_t n = 1; n < vm->nglobals; n++)
        vm->globals[n] = V_CLEARED;
    for (size_t i = 0; i < vm->local_cap; i++)
        vm->local_keys[i] = 0;
    vm->local_count = 0;
    bool ok = true;
    for (size_t i = 0; i < N; i++)
        if (sym[i] != V_NIL && value[i] != V_CLEARED)
            *global_slot_new(vm, sym[i]) = value[i]; /* numbered, so a slot */
    vm_unroot(vm, N);
    V start = symbol_find(vm, "shen-jit.start-isolate", 22);
    V proc = start == V_NIL ? V_CLEARED : *cell_function(vm, symbol_cell(start));
    return ok && sj_init_host(vm) && is_proc(proc) && jit_call(vm, proc, 1, &gensym_base) != V_CLEARED;
}

static bool vector_index(V v, V i)
{
    return is_type(v, T_VECTOR) && is_fix(i) && fixval(i) >= 0 &&
           (uint64_t)fixval(i) < hdr_size(ptr(v)[0]);
}

/* The general implementation of every primitive. Operands are in
   vm->args[0..2], where they stay rooted while this allocates. Returns
   V_CLEARED after raising. */
/* shen-jit.trace-text and shen-jit.backtrace. Their buffers are kept
   out of sj_primitive, whose frame every primitive call pays for. */
static __attribute__((noinline)) V trace_text(VM *vm, V message)
{
    char text[4096];
    bool newline = is_type(message, T_STRING) && string_length(message) > 0 &&
                   string_bytes(message)[string_length(message) - 1] != '\n';
    size_t len = sj_trace_text(vm, text, sizeof text, newline);
    return made(vm, make_string(vm, text, len));
}

static __attribute__((noinline)) V backtrace(VM *vm)
{
    bool evaluated;
    size_t n = jit_backtrace(vm, NULL, 0, &evaluated);
    if (n > TRACE_FRAMES)
        n = TRACE_FRAMES;
    uint64_t *p = vm_alloc(vm, 2 * n);
    if (!p && n)
        return sj_raise(vm, "out of memory");
    V names[TRACE_FRAMES];
    jit_backtrace(vm, names, n, &evaluated); /* after the allocation, which may move them */
    V list = V_NIL;
    for (size_t i = n; i-- > 0;) {
        p[2 * i] = names[i];
        p[2 * i + 1] = list;
        list = tagged(p + 2 * i, TAG_PAIR);
    }
    return list;
}

/* Byte buffers and sized pointers (docs/bytecode.md). Values are little-endian, as on every
   target. */
static V bytes_access(VM *vm, unsigned prim)
{
    V b = vm->args[0], i = vm->args[1], x = vm->args[2];
    size_t width = (size_t)1 << ((prim - P_U8) % 3), length;
    char *base;
    if (!memory_of(b, &base, &length))
        return sj_raise_value(vm, "bytes: ~S is not a byte buffer", b);
    if (!is_fix(i) || fixval(i) < 0 || (uint64_t)fixval(i) + width > length)
        return sj_raise_value(vm, "bytes: ~S is not a valid index", i);
    uint64_t n = 0;
    if (prim <= P_U32) {
        memcpy(&n, base + fixval(i), width);
        return fix((int64_t)n);
    }
    if (is_read_only(b))
        return sj_raise_value(vm, "bytes: ~S is read only", b);
    if (!is_fix(x) || fixval(x) < 0 || (uint64_t)fixval(x) >> (8 * width))
        return sj_raise_value(vm, "bytes: ~S does not fit", x);
    n = (uint64_t)fixval(x);
    memcpy(base + fixval(i), &n, width);
    return b;
}

/* The widths C structs have beyond those above: signed integers and floating point. */
static V wide_access(VM *vm, unsigned prim)
{
    V b = vm->args[0], i = vm->args[1], x = vm->args[2];
    bool narrow = prim == P_S32 || prim == P_F32 || prim == P_SET_S32 || prim == P_SET_F32;
    size_t width = narrow ? 4 : 8, length;
    char *base;
    if (!memory_of(b, &base, &length))
        return sj_raise_value(vm, "bytes: ~S is not a byte buffer", b);
    if (!is_fix(i) || fixval(i) < 0 || (uint64_t)fixval(i) + width > length)
        return sj_raise_value(vm, "bytes: ~S is not a valid index", i);
    char *at = base + fixval(i);
    if (prim >= P_SET_S32 && is_read_only(b))
        return sj_raise_value(vm, "bytes: ~S is read only", b);
    switch (prim) {
    case P_S32: {
        int32_t n;
        memcpy(&n, at, sizeof n);
        return fix(n);
    }
    case P_S64: {
        int64_t n;
        memcpy(&n, at, sizeof n);
        return fix_fits(n) ? fix(n) : sj_raise_value(vm, "shen-jit.s64: the value at ~S does not fit in an integer", i);
    }
    case P_F32: {
        float f;
        memcpy(&f, at, sizeof f);
        return made(vm, make_real(vm, f));
    }
    case P_F64: {
        double d;
        memcpy(&d, at, sizeof d);
        return made(vm, make_real(vm, d));
    }
    case P_SET_S32: {
        if (!is_fix(x) || fixval(x) < INT32_MIN || fixval(x) > INT32_MAX)
            return sj_raise_value(vm, "bytes: ~S does not fit", x);
        int32_t n = (int32_t)fixval(x);
        memcpy(at, &n, sizeof n);
        return b;
    }
    case P_SET_S64: {
        if (!is_fix(x))
            return sj_raise_value(vm, "bytes: ~S does not fit", x);
        int64_t n = fixval(x);
        memcpy(at, &n, sizeof n);
        return b;
    }
    case P_SET_F32: {
        if (!is_number(x))
            return sj_raise_value(vm, "bytes: ~S is not a number", x);
        float f = (float)number(x);
        memcpy(at, &f, sizeof f);
        return b;
    }
    default: { /* P_SET_F64 */
        if (!is_number(x))
            return sj_raise_value(vm, "bytes: ~S is not a number", x);
        double d = number(x);
        memcpy(at, &d, sizeof d);
        return b;
    }
    }
}

/* Whether the n bytes from start lie within what has this length. */
static bool bytes_range(size_t length, V start, V n)
{
    return is_fix(start) && is_fix(n) && fixval(start) >= 0 && fixval(n) >= 0 &&
           (uint64_t)fixval(start) + (uint64_t)fixval(n) <= length;
}

/* The double nearest to the decimal number in s, times 10^e, for a literal past the
   fixnum range: arithmetic on doubles would only land near it. s may have an exponent
   of its own, as str prints a large real. */
static V decimal(VM *vm, V s, V e)
{
    if (!is_type(s, T_STRING) || !is_fix(e))
        return sj_raise_value(vm, "shen-jit.decimal: ~S is not a string and an exponent", s);
    size_t n = string_length(s);
    char *text = malloc(n + 32);
    if (!text)
        return sj_raise(vm, "out of memory");
    memcpy(text, string_bytes(s), n);
    text[n] = 0;
    long long exponent = fixval(e);
    char *own = strchr(text, 'e');
    if (own) {
        exponent += strtoll(own + 1, NULL, 10);
        *own = 0;
    }
    snprintf(text + strlen(text), 32, "e%lld", exponent);
    double d = strtod(text, NULL);
    free(text);
    return made(vm, make_real(vm, d));
}

static V bytes_primitive(VM *vm, unsigned prim)
{
    V a = vm->args[0], b = vm->args[1], c = vm->args[2];
    V d = vm->args[3], n = vm->args[4];
    V v;
    char *base, *from;
    size_t length, from_length;
    switch (prim) {
    case P_BYTES:
        if (!is_fix(a) || fixval(a) < 0 || fixval(a) >> 48)
            return sj_raise_value(vm, "shen-jit.bytes: ~S is not a valid length", a);
        v = make_bytes(vm, NULL, (size_t)fixval(a));
        return made(vm, v);
    case P_BYTES_LENGTH:
        return memory_of(a, &base, &length) ? fix((int64_t)length)
                                            : sj_raise_value(vm, "bytes: ~S is not a byte buffer", a);
    case P_STRING_BYTES:
        if (!is_type(a, T_STRING))
            return sj_raise_value(vm, "shen-jit.string->bytes: ~S is not a string", a);
        v = make_bytes(vm, NULL, string_length(a));
        if (v == V_CLEARED)
            return sj_raise(vm, "out of memory");
        memcpy(string_bytes(v), string_bytes(vm->args[0]), string_length(v));
        return v;
    case P_BYTES_STRING:
        if (!memory_of(a, &base, &length))
            return sj_raise_value(vm, "bytes: ~S is not a byte buffer", a);
        if (!bytes_range(length, b, c))
            return sj_raise_value(vm, "shen-jit.bytes->string: ~S is not a valid range", b);
        /* substring reads the buffer again after allocating, which may move it. A pointer's
           memory stays where it is. */
        return is_type(a, T_BYTES) ? substring(vm, (size_t)fixval(b), (size_t)fixval(c))
                                   : made(vm, make_string(vm, base + fixval(b), (size_t)fixval(c)));
    default: /* P_COPY_BYTES: to, its start, from, its start, how many */
        if (!memory_of(a, &base, &length))
            return sj_raise_value(vm, "bytes: ~S is not a byte buffer", a);
        if (!memory_of(c, &from, &from_length))
            return sj_raise_value(vm, "bytes: ~S is not a byte buffer", c);
        if (is_read_only(a))
            return sj_raise_value(vm, "bytes: ~S is read only", a);
        if (!bytes_range(length, b, n) || !bytes_range(from_length, d, n))
            return sj_raise_value(vm, "shen-jit.copy-bytes: ~S is not a valid count", n);
        memmove(base + fixval(b), from + fixval(d), (size_t)fixval(n));
        return a;
    }
}

/* shen-jit.write-bytes: N bytes of a buffer from I, to an output stream, by one write,
   where write-byte takes a call each. */
static V write_bytes(VM *vm)
{
    V b = vm->args[0], i = vm->args[1], n = vm->args[2];
    char *base;
    size_t length;
    if (!memory_of(b, &base, &length))
        return sj_raise_value(vm, "bytes: ~S is not a byte buffer", b);
    if (!bytes_range(length, i, n))
        return sj_raise_value(vm, "shen-jit.write-bytes: ~S is not a valid range", i);
    FILE *f = stream_file(vm, vm->args[3], true);
    if (!f)
        return sj_raise_value(vm, "shen-jit.write-bytes: ~S is not an open output stream", vm->args[3]);
    if (fixval(n) > 0 && fwrite(base + fixval(i), 1, (size_t)fixval(n), f) != (size_t)fixval(n))
        return raise_io_failed(vm, "shen-jit.write-bytes", errno);
    return n;
}

/* Bit operations (docs/bytecode.md), on the 62 bits of a fixnum. A fixnum's tag bits
   are zero, so its value shifted left by two is its own word. */
static V bit_operation(VM *vm, unsigned prim)
{
    V a = vm->args[0], b = vm->args[1];
    if (!is_fix(a))
        return sj_raise_value(vm, "bit operation: ~S is not an integer", a);
    switch (prim) {
    case P_BIT_NOT: return ~a & ~(V)3;
    case P_POPCOUNT: return fix(__builtin_popcountll(a));
    case P_CLZ: return fix(a ? __builtin_clzll(a) : 62);
    case P_CTZ: return fix(a ? __builtin_ctzll(a) - 2 : 62);
    case P_BSWAP32:
        if ((uint64_t)fixval(a) >> 32)
            return sj_raise_value(vm, "shen-jit.bswap32: ~S does not fit in 32 bits", a);
        return fix(__builtin_bswap32((uint32_t)fixval(a)));
    default: break;
    }
    if (!is_fix(b))
        return sj_raise_value(vm, "bit operation: ~S is not an integer", b);
    switch (prim) {
    case P_BIT_AND: return a & b;
    case P_BIT_OR: return a | b;
    case P_BIT_XOR: return a ^ b;
    default: break;
    }
    if ((uint64_t)fixval(b) > 63)
        return sj_raise_value(vm, "bit operation: ~S is not a valid shift", b);
    unsigned k = (unsigned)fixval(b);
    if (prim == P_SHIFT_LEFT)
        return a << k;
    if (prim == P_SHIFT_RIGHT)
        return (V)((int64_t)a >> k) & ~(V)3;
    /* P_ROTATE32: left */
    if ((uint64_t)fixval(a) >> 32)
        return sj_raise_value(vm, "shen-jit.rotate32: ~S does not fit in 32 bits", a);
    uint32_t x = (uint32_t)fixval(a);
    k &= 31;
    return fix((uint32_t)(x << k | x >> ((32 - k) & 31)));
}

void sj_report(VM *vm, const char *what)
{
    V e = vm->exception;
    if (is_object(e) && obj_type(e) == T_EXCEPTION) {
        V m = exception_message(vm, e);
        if (m == V_CLEARED)
            m = ptr(vm->exception)[EXC_MESSAGE];
        int len = (int)string_length(m);
        if (len > 0 && string_bytes(m)[len - 1] == '\n')
            len--; /* some of the kernel's messages end with one */
        fprintf(stderr, "shen-jit: %s: %.*s\n", what, len, string_bytes(m));
        char trace[4096];
        if (sj_trace_text(vm, trace, sizeof trace, false))
            fprintf(stderr, "%s\n", trace);
    } else {
        fprintf(stderr, "shen-jit: %s failed\n", what);
    }
}

V sj_primitive(VM *vm, size_t index)
{
    V a = vm->args[0], b = vm->args[1];
    switch (index) {
    case P_ADD: case P_SUB: case P_MUL: case P_DIV:
        return arithmetic(vm, (unsigned)index, a, b);
    case P_LT: case P_GT: case P_LE: case P_GE:
        return comparison(vm, (unsigned)index, a, b);
    case P_EQ: return boolean(sj_equal(a, b));
    case P_NUMBERP: return boolean(is_number(a));
    case P_CONS: {
        V pair = make_pair(vm, a, b);
        return pair == V_CLEARED ? sj_raise(vm, "out of memory") : pair;
    }
    case P_HD: return is_pair(a) ? ptr(a)[0] : sj_raise_value(vm, "hd: ~S is not a pair", a);
    case P_TL: return is_pair(a) ? ptr(a)[1] : sj_raise_value(vm, "tl: ~S is not a pair", a);
    case P_CONSP: return boolean(is_pair(a));
    case P_STRINGP: return boolean(is_type(a, T_STRING));
    case P_ABSVECTOR:
        if (!is_fix(a) || fixval(a) < 0 || fixval(a) >> 48)
            return sj_raise_value(vm, "absvector: ~S is not a valid length", a);
        else {
            V fail = fail_symbol(vm);
            V v = fail == V_CLEARED ? V_CLEARED : make_vector(vm, (size_t)fixval(vm->args[0]), fail);
            return made(vm, v);
        }
    case P_ABSVECTORP: return boolean(is_type(a, T_VECTOR));
    case P_GET_ADDRESS:
        if (vector_index(a, b))
            return ptr(a)[1 + fixval(b)];
        return is_type(a, T_VECTOR) ? sj_raise_value(vm, "<-address: ~S is not a valid index", b)
                                    : sj_raise_value(vm, "<-address: ~S is not an absvector", a);
    case P_SET_ADDRESS:
        if (!vector_index(a, b))
            return is_type(a, T_VECTOR) ? sj_raise_value(vm, "address->: ~S is not a valid index", b)
                                        : sj_raise_value(vm, "address->: ~S is not an absvector", a);
        ptr(a)[1 + fixval(b)] = vm->args[2];
        return a;
    case P_SET: {
        if (!is_symbol(a))
            return sj_raise_value(vm, "set: ~S is not a symbol", a);
        V *slot = global_slot_new(vm, a);
        return slot ? (*slot = b) : sj_raise(vm, "out of memory");
    }
    case P_VALUE:
        if (!is_symbol(a))
            return sj_raise_value(vm, "value: ~S is not a symbol", a);
        if (global_value(vm, a) == V_CLEARED)
            return sj_raise_value(vm, "~S has no value", a);
        return global_value(vm, a);
    case P_SIMPLE_ERROR:
        if (!is_type(a, T_STRING))
            return sj_raise_value(vm, "simple-error: ~S is not a string", a);
        else if (quiet_handler(vm)) {
            vm->exception = V_NIL;
            return V_CLEARED;
        } else {
            capture_trace(vm);
            V e = make_exception(vm, vm->args[0], V_CLEARED);
            vm->exception = e == V_CLEARED ? V_NIL : e;
            return V_CLEARED;
        }
    case P_ERROR_TO_STRING:
        if (!is_type(a, T_EXCEPTION))
            return sj_raise_value(vm, "error-to-string: ~S is not an exception", a);
        else {
            V s = exception_message(vm, a);
            return made(vm, s);
        }
    case P_CN:
        if (!is_type(a, T_STRING) || !is_type(b, T_STRING))
            return sj_raise_value(vm, "cn: ~S is not a string", is_type(a, T_STRING) ? b : a);
        return concatenate(vm);
    case P_POS:
        if (!is_type(a, T_STRING) || !is_fix(b) || fixval(b) < 0 ||
            (uint64_t)fixval(b) >= string_length(a))
            return is_type(a, T_STRING) ? sj_raise_value(vm, "pos: ~S is not a valid index", b)
                                        : sj_raise_value(vm, "pos: ~S is not a string", a);
        return byte_string(vm, (unsigned char)string_bytes(a)[fixval(b)]);
    case P_TLSTR:
        if (!is_type(a, T_STRING) || string_length(a) == 0)
            return sj_raise_value(vm, "tlstr: ~S is not a non-empty string", a);
        return substring(vm, 1, string_length(a) - 1);
    case P_STR: return to_string(vm, a);
    case P_N_STRING: {
        /* A byte as itself, as the reader passes source bytes through here, and
           what is past a byte, as from a c#N; escape, as UTF-8. */
        int64_t n = is_fix(a) ? fixval(a) : -1;
        if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF))
            return sj_raise_value(vm, "n->string: ~S is not a byte or a Unicode scalar value", a);
        if (n <= 255)
            return byte_string(vm, (unsigned)n);
        char utf8[4];
        size_t len = n <= 0x7FF ? 2 : n <= 0xFFFF ? 3 : 4;
        static const unsigned char lead[] = {0, 0, 0xC0, 0xE0, 0xF0};
        for (size_t i = len - 1; i > 0; i--, n >>= 6)
            utf8[i] = (char)(0x80 | (n & 0x3F));
        utf8[0] = (char)(lead[len] | n);
        V s = make_string(vm, utf8, len);
        return made(vm, s);
    }
    case P_STRING_N:
        if (!is_type(a, T_STRING) || string_length(a) == 0)
            return sj_raise_value(vm, "string->n: ~S is not a non-empty string", a);
        return fix((unsigned char)string_bytes(a)[0]);
    case P_INTERN:
        if (!is_type(a, T_STRING))
            return sj_raise_value(vm, "intern: ~S is not a string", a);
        if (string_length(a) == 4 && memcmp(string_bytes(a), "true", 4) == 0)
            return V_TRUE;
        if (string_length(a) == 5 && memcmp(string_bytes(a), "false", 5) == 0)
            return V_FALSE;
        else {
            V sym = intern_string(vm, a);
            return sym == V_CLEARED ? sj_raise(vm, "out of memory") : sym;
        }
    case P_GET_TIME: return get_time(vm);
    case P_OPEN: return open_file(vm);
    case P_CLOSE: return close_stream(vm, a);
    case P_READ_BYTE: return read_byte(vm, a);
    case P_WRITE_BYTE: return write_byte(vm, a, b);
    case P_CHAR_STREAMP: return V_FALSE;
    case P_READ_UNIT_STRING:
    case P_WRITE_STRING: return sj_raise(vm, "character streams are not supported");
    case P_INSTALL: return sj_install(vm, a);
    case P_FIXNUMP: return boolean(is_fix(a));
    case P_SYMBOLP: return boolean(is_symbol(a));
    case P_HASH: return hash(vm, a, b);
    case P_SYMBOL_KIND: return symbol_kind(a);
    case P_SEALEDP:
        /* A sealed name; or, while sealing is on, a name not defined yet,
           which the first sealed call will bind (jit.c). */
        return boolean(is_symbol(a) && (symbol_sealed(a) ||
                                        (vm->seal_user && !is_proc(*cell_function(vm, symbol_cell(a))))));
    case P_INLINE_BODY:
        if (is_symbol(a)) {
            V f = *cell_function(vm, symbol_cell(a));
            if (is_proc(f) && hdr_type(ptr(f)[0]) == T_CLOSURE)
                return ptr(ptr(f)[CLO_CODE])[CODE_INLINE];
        }
        return V_NIL;
    case P_SEALING:
        if (!is_boolean(a))
            return sj_raise_value(vm, "~S is not a boolean", a);
        vm->seal_user = a == V_TRUE;
        return a;
    case P_TAGGEDP:
        return boolean(is_type(a, T_VECTOR) && hdr_size(ptr(a)[0]) > 0 && ptr(a)[1] == b);
    case P_VECTORP: /* an absvector whose element 0 is a number, at least 0 */
        return boolean(is_type(a, T_VECTOR) && hdr_size(ptr(a)[0]) > 0 && is_number(ptr(a)[1]) &&
                       number(ptr(a)[1]) >= 0);
    case P_QUIETP: return boolean(quiet_handler(vm));
    case P_MARK_TOPLEVEL:
        if (vm->worker_owner)
            return sj_raise(vm, "worker: a worker cannot install a REPL interrupt handler");
        vm->trace_floor = (size_t)(vm->fp - vm->stack);
        vm->trace = V_NIL;
        vm->repl_handlers = vm->nhandlers;
        catch_interrupts(vm);
        return V_TRUE;
    case P_TRACE_TEXT: return trace_text(vm, a);
    case P_BACKTRACE: return backtrace(vm);
    case P_READ_FILE: return read_file(vm);
    case P_APPEND: return append(vm);
    case P_INLINEDP: {
        if (!is_symbol(a))
            return V_FALSE;
        V f = *cell_function(vm, symbol_cell(a));
        return boolean(is_proc(f) && hdr_type(ptr(f)[0]) == T_CLOSURE && ptr(ptr(f)[CLO_CODE])[CODE_INLINE] == b);
    }
    case P_ARITYP: {
        if (!is_symbol(a) || !is_fix(b))
            return V_FALSE;
        V f = *cell_function(vm, symbol_cell(a));
        return boolean(is_proc(f) && hdr_type(ptr(f)[0]) == T_CLOSURE &&
                       (ptr(ptr(f)[CLO_CODE])[CODE_ARITY] & UINT32_MAX) == (uint64_t)fixval(b));
    }
    case P_INTEGERP: /* a fixnum, or a finite real without a fraction */
        return is_fix(a) || (is_type(a, T_REAL) && isfinite(real_value(a)) && real_value(a) == floor(real_value(a)))
                   ? V_TRUE
                   : V_FALSE;
    case P_ABSVECTOR3: {
        V v = make_vector(vm, 3, V_NIL);
        if (v != V_CLEARED)
            for (int i = 0; i < 3; i++)
                ptr(v)[1 + i] = vm->args[i];
        return v;
    }
    case P_DICT_FIND: return sj_dict_find(vm);
    case P_DICT_PUT: return sj_dict_put(vm);
    case P_DICT_REMOVE: return sj_dict_remove(vm);
    case P_DICT_ENTRIES: return sj_dict_entries(vm);
    case P_FILLED_VECTOR:
        if (!is_fix(a) || fixval(a) < 0 || fixval(a) >> 48)
            return sj_raise_value(vm, "shen-jit.filled-vector: ~S is not a valid length", a);
        else {
            V v = make_vector(vm, (size_t)fixval(a), b);
            return made(vm, v);
        }
    case P_EXIT:
        if (vm->worker_owner || vm->worker_scope)
            return sj_raise(vm, "worker: exit is a host-only operation");
        if (!is_fix(a) || fixval(a) < 0 || fixval(a) > 255)
            return sj_raise_value(vm, "~S is not an exit status", a);
        if (vm->threads)
            thread_exit(vm, (int)fixval(a));
        exit((int)fixval(a)); /* flushes every open stream */
    case P_SAVE_EXECUTABLE: return save_executable(vm);
    case P_BYTESP: return boolean(is_type(a, T_BYTES));
    case P_BYTES: case P_BYTES_LENGTH: case P_STRING_BYTES: case P_BYTES_STRING: case P_COPY_BYTES:
        return bytes_primitive(vm, (unsigned)index);
    case P_U8: case P_U16: case P_U32: case P_SET_U8: case P_SET_U16: case P_SET_U32:
        return bytes_access(vm, (unsigned)index);
    case P_S32: case P_S64: case P_F32: case P_F64: case P_SET_S32: case P_SET_S64: case P_SET_F32: case P_SET_F64:
        return wide_access(vm, (unsigned)index);
    case P_BIT_AND: case P_BIT_OR: case P_BIT_XOR: case P_BIT_NOT: case P_SHIFT_LEFT: case P_SHIFT_RIGHT:
    case P_ROTATE32: case P_BSWAP32: case P_POPCOUNT: case P_CLZ: case P_CTZ:
        return bit_operation(vm, (unsigned)index);
    case P_DECIMAL: return decimal(vm, a, b);
    case P_PVAR:
        if (!is_fix(a) || fixval(a) < 0 || (uint64_t)fixval(a) > PVAR_MAX_OFFSET)
            return sj_raise_value(vm, "shen-jit.pvar: ~S is not a valid offset", a);
        return (uint64_t)fixval(a) << 8 | PVAR_TAG;
    case P_PVARP: return boolean(is_pvar(a));
    case P_SAMEP: return boolean(a == b);
    case P_NEWPV: {
        /* A new variable in the vector of bindings a, whose element 1 is the
           next offset: its binding becomes b, which marks none, and the
           offset moves on, as the kernel's shen.newpv does. */
        if (!is_type(a, T_VECTOR) || hdr_size(ptr(a)[0]) < 2)
            return sj_raise_value(vm, "shen-jit.newpv: ~S is not a vector of bindings", a);
        V n = ptr(a)[2];
        if (!is_fix(n) || fixval(n) < 0 || (uint64_t)fixval(n) >= hdr_size(ptr(a)[0]))
            return sj_raise_value(vm, "shen-jit.newpv: no room for a variable at ~S", n);
        ptr(a)[1 + fixval(n)] = b;
        ptr(a)[2] = fix(fixval(n) + 1);
        return (uint64_t)fixval(n) << 8 | PVAR_TAG;
    }
    case P_GC:
        /* b, the result of the code that used the last variable made in the
           vector of bindings a; if it failed, the next offset moves back to
           that variable's, as the kernel's shen.gc does. */
        if (b != V_FALSE)
            return b;
        if (!is_type(a, T_VECTOR) || hdr_size(ptr(a)[0]) < 2 || !is_fix(ptr(a)[2]))
            return sj_raise_value(vm, "shen-jit.gc: ~S is not a vector of bindings", a);
        ptr(a)[2] = fix(fixval(ptr(a)[2]) - 1);
        return V_FALSE;
    case P_THREAD: return thread_start(vm);
    case P_WORKER_SCOPE: return worker_scope(vm);
    case P_WORKER_BATCH: return worker_batch(vm);
    case P_WORKER_INDEX: return worker_index(vm);
    case P_WORKER_LIVE: return worker_live(vm);
    case P_WORKER_CANCELLED: return worker_cancelled(vm);
    case P_WORKER_SHARED_VIEW: return worker_shared_view(vm);
    case P_FOREIGN: case P_POINTERP: case P_POINTER_KIND: case P_POINTER_ADDRESS: case P_BYTES_POINTER:
    case P_POINTER_STRING: case P_POINTER_BYTES: case P_ERRNO: case P_C_ERRNO: case P_POINTER_KILL:
    case P_POINTER_SIZED: case P_SET_POINTER: case P_POINTER_GUARD: case P_POINTER_OWNER: case P_POINTERS_DEAD:
    case P_POINTER_READ_ONLY:
        return ffi_primitive(vm, (unsigned)index);
    case P_ARITY: {
        V n = is_symbol(a) ? *cell_arity(vm, symbol_cell(a)) : V_CLEARED;
        return n == V_CLEARED ? fix(-1) : n;
    }
    case P_SET_ARITY:
        if (!vm->builder)
            return sj_raise(vm, "only the builder can define functions");
        if (!is_symbol(a))
            return sj_raise_value(vm, "shen-jit.set-arity: ~S is not a symbol", a);
        if (!is_fix(b) || fixval(b) < -1 || fixval(b) > 255)
            return sj_raise_value(vm, "shen-jit.set-arity: ~S is not an arity", b);
        *cell_arity(vm, symbol_cell(a)) = fixval(b) < 0 ? V_CLEARED : b;
        return b;
    case P_FUNCTION: {
        V f = is_symbol(a) ? *cell_function(vm, symbol_cell(a)) : V_CLEARED;
        if (is_proc(f))
            return f;
        return is_symbol(a) ? sj_raise_value(vm, "undefined function ~S", a)
                            : sj_raise_value(vm, "~S is not a symbol", a);
    }
    case P_APPLY: return apply_function(vm, a, b);
    case P_COLLECT:
        vm_collect(vm, 0);
        return V_TRUE;
    case P_WRITE_BYTES: return write_bytes(vm);
    case P_DEREF: {
        /* What X is bound to in the vector b, along a chain of variables; the
           third argument marks a variable with no binding. */
        V x = a;
        while (is_pvar(x)) {
            if (!is_type(b, T_VECTOR) || pvar_offset(x) >= hdr_size(ptr(b)[0]))
                return sj_raise_value(vm, "shen-jit.deref: ~S has no binding here", x);
            V bound = ptr(b)[1 + pvar_offset(x)];
            if (bound == vm->args[2])
                return x;
            x = bound;
        }
        return x;
    }
    case P_PVAR_OFFSET:
        return is_pvar(a) ? fix((int64_t)pvar_offset(a))
                          : sj_raise_value(vm, "shen-jit.pvar-offset: ~S is not a Prolog variable", a);
    case P_EVAL_KL: return sj_raise(vm, "eval-kl is lowered as a call to shen-jit.eval-kl");
    default:
        if (index == PRIM_RAISE_COND)
            return sj_raise(vm, "cond: no clause applies");
        return sj_raise(vm, "unknown primitive");
    }
}

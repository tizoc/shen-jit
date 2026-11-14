/* The library that tests/ffi.shen and tests/ffi_c.shen call. Built by make test-ffi. The first
   part is plain C, as a real library's would be, and knows nothing of Shen: every type, every way
   of passing arguments, and what can go wrong. The second is C written for Shen. */
#define _DEFAULT_SOURCE
#include "shen.h"

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#endif

/* Memory that C owns, read and written from Shen in place (tests/memory.shen). */
typedef struct {
    double x, y;
    int32_t id;
} point;

point *make_points(int32_t n)
{
    point *p = calloc((size_t)n, sizeof *p);
    for (int32_t i = 0; p && i < n; i++) {
        p[i].x = i + 0.5;
        p[i].y = -i;
        p[i].id = i - 1;
    }
    return p;
}

double sum_x(const point *p, int32_t n)
{
    double sum = 0;
    for (int32_t i = 0; i < n; i++)
        sum += p[i].x;
    return sum;
}

void free_points(point *p) { free(p); }

void fill_bytes(unsigned char *p, int32_t n, int32_t value) { memset(p, value, (size_t)n); }

void *pointer_in(void **slot) { return *slot; }

/* Each type, as a result. */
int64_t add64(int64_t a, int64_t b) { return a + b; }
int64_t too_big(void) { return INT64_C(1) << 61; }
int64_t biggest(void) { return (INT64_C(1) << 61) - 1; }
int64_t smallest(void) { return -(INT64_C(1) << 61); }
int32_t neg32(void) { return -5; }
uint32_t big32(void) { return 4000000000u; }
/* An int returned leaves the upper half undefined, which this makes certain. */
uint64_t dirty32(void) { return UINT64_C(0xABCDEF0100000007); }
double half(double x) { return x / 2; }
bool yes(void) { return true; }
bool no(void) { return false; }
/* A C bool is the low byte alone. */
uint64_t low_byte_clear(void) { return 0x100; }
uint64_t low_byte_set(void) { return 0xFF01; }
const char *hello(void) { return "hello"; }
const char *no_string(void) { return NULL; }
void *no_pointer(void) { return NULL; }
static int nothing_ran;
void nothing(void) { nothing_ran++; }
int32_t times_nothing_ran(void) { return nothing_ran; }

/* Each type, as an argument. */
int32_t add32(int32_t a, int32_t b) { return a + b; }
uint32_t echo_u32(uint32_t a) { return a; }
int32_t negate_bool(bool b) { return !b; }
int64_t length(const char *s) { return (int64_t)strlen(s); }
/* The result points into the argument, whose memory lasts only for the call. */
const char *rest(const char *s) { return s + 1; }
int32_t is_null(const void *p) { return p == NULL; }
void *pointer_id(void *p) { return p; }

/* Byte buffers, written in place. */
void fill(unsigned char *to, int64_t n, int32_t byte) { memset(to, byte, (size_t)n); }
int64_t sum_bytes(const unsigned char *from, int64_t n)
{
    int64_t sum = 0;
    for (int64_t i = 0; i < n; i++)
        sum += from[i];
    return sum;
}
/* As fgets does: the result is the buffer. */
const char *write_text(char *to)
{
    strcpy(to, "written");
    return to;
}

/* Pointers: a thing C owns, and an out-parameter. */
static const char thing[] = "a thing in C\0and more";
const void *a_thing(void) { return thing; }
int32_t is_thing(const void *p) { return p == thing; }
void thing_out(const void **out) { *out = thing; }
void null_out(const void **out) { *out = NULL; }

/* The error codes. */
void set_c_error(int32_t n) { errno = n; }
void set_system_error(int32_t n)
{
#ifdef _WIN32
    SetLastError((DWORD)n);
#else
    errno = n;
#endif
}

/* Every position of doubles among the first four arguments, for each kind of result: on
   Windows, each of these is a different call. */
#define WITH_RESULT(name, T0, T1, T2, T3)                                                      \
    int64_t name##_word(T0 a, T1 b, T2 c, T3 d) { return (int64_t)(a * 1000 + b * 100 + c * 10 + d); } \
    double name##_real(T0 a, T1 b, T2 c, T3 d) { return (double)a * 1000 + (double)b * 100 + (double)c * 10 + (double)d; }
#define I int64_t
#define D double
WITH_RESULT(mask0, I, I, I, I)
WITH_RESULT(mask1, D, I, I, I)
WITH_RESULT(mask2, I, D, I, I)
WITH_RESULT(mask3, D, D, I, I)
WITH_RESULT(mask4, I, I, D, I)
WITH_RESULT(mask5, D, I, D, I)
WITH_RESULT(mask6, I, D, D, I)
WITH_RESULT(mask7, D, D, D, I)
WITH_RESULT(mask8, I, I, I, D)
WITH_RESULT(mask9, D, I, I, D)
WITH_RESULT(mask10, I, D, I, D)
WITH_RESULT(mask11, D, D, I, D)
WITH_RESULT(mask12, I, I, D, D)
WITH_RESULT(mask13, D, I, D, D)
WITH_RESULT(mask14, I, D, D, D)
WITH_RESULT(mask15, D, D, D, D)

/* The most it takes, past the registers on every target. */
int64_t six_words(I a, I b, I c, I d, I e, I f) { return a * 100000 + b * 10000 + c * 1000 + d * 100 + e * 10 + f; }
double eight_doubles(D a, D b, D c, D d, D e, D f, D g, D h)
{
    return a * 10000000 + b * 1000000 + c * 100000 + d * 10000 + e * 1000 + f * 100 + g * 10 + h;
}
double all_fourteen(I a, D b, I c, D d, I e, D f, I g, D h, I i, D j, I k, D l, D m, D n)
{
    return (double)a * 1e13 + b * 1e12 + (double)c * 1e11 + d * 1e10 + (double)e * 1e9 + f * 1e8 + (double)g * 1e7 +
           h * 1e6 + (double)i * 1e5 + j * 1e4 + (double)k * 1e3 + l * 1e2 + m * 10 + n;
}

/* Variadic functions, which Apple's arm64 passes differently from any other. */
int64_t var_one(int32_t n, ...)
{
    va_list v;
    va_start(v, n);
    int64_t sum = 0;
    for (int32_t i = 0; i < n; i++)
        sum = sum * 10 + va_arg(v, int);
    va_end(v);
    return sum;
}
int32_t var_two(int32_t a, int32_t b, ...)
{
    va_list v;
    va_start(v, b);
    int32_t c = va_arg(v, int);
    va_end(v);
    return a * 100 + b * 10 + c;
}
int32_t var_three(int32_t a, int32_t b, int32_t c, ...)
{
    va_list v;
    va_start(v, c);
    int32_t d = va_arg(v, int), e = va_arg(v, int);
    va_end(v);
    return a * 10000 + b * 1000 + c * 100 + d * 10 + e;
}

/* A call that waits, then writes to its buffer, as recv does. */
static void wait_ms(int32_t ms)
{
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000};
    nanosleep(&t, NULL);
#endif
}
int64_t slow_fill(unsigned char *to, int64_t n, int32_t byte, int32_t ms)
{
    int64_t before = sum_bytes(to, n);
    wait_ms(ms);
    fill(to, n, byte);
    return before;
}

/* Given one buffer twice, what it writes through the first it reads through the second. */
int32_t alias_bytes(unsigned char *a, unsigned char *b)
{
    a[0] = 42;
    return b[0];
}

/* ---------------------------------------------------------------------------
   C written for Shen (include/shen.h). */

shen_value sum_list(shen_vm *vm, shen_value *args)
{
    int64_t sum = 0;
    for (shen_value l = args[0]; shen_is_pair(vm, l); l = shen_tail(vm, l)) {
        shen_value x = shen_head(vm, l);
        if (!shen_is_fixnum(x))
            return shen_raise_value(vm, "sum_list: ~S is not an integer", x);
        sum += shen_fixnum(x);
    }
    return shen_make_fixnum(sum);
}

/* Calls args[1] on each element of args[0]; an error in the callback propagates. */
shen_value on_each(shen_vm *vm, shen_value *args)
{
    shen_value l = args[0];
    shen_root(vm, &l); /* args[] is rooted already; l is not */
    while (shen_is_pair(vm, l)) {
        shen_value x = shen_head(vm, l);
        if (shen_call(vm, args[1], 1, &x) == SHEN_ERROR)
            return SHEN_ERROR;
        l = shen_tail(vm, l);
    }
    return SHEN_TRUE;
}

/* [X | (F X)], with X held in C across the call. */
shen_value call_in_c(shen_vm *vm, shen_value *args)
{
    shen_value r = shen_call(vm, args[0], 1, &args[1]);
    return r == SHEN_ERROR ? r : shen_cons(vm, args[1], r);
}

shen_value forty_two(shen_vm *vm, shen_value *args) { return shen_make_fixnum(42); }

shen_value eight_arguments(shen_vm *vm, shen_value *args)
{
    int64_t digits = 0;
    for (int i = 0; i < 8; i++)
        digits = digits * 10 + shen_fixnum(args[i]);
    return shen_make_fixnum(digits);
}

shen_value kind_of(shen_vm *vm, shen_value *args)
{
    shen_value v = args[0];
    return shen_intern(vm, shen_is_fixnum(v) ? "fixnum"
                         : v == SHEN_NIL ? "nil"
                         : v == SHEN_TRUE || v == SHEN_FALSE ? "boolean"
                         : shen_is_string(vm, v) ? "string"
                         : shen_is_pair(vm, v) ? "pair"
                         : shen_is_vector(vm, v) ? "vector"
                         : shen_is_symbol(vm, v) ? "symbol"
                         : shen_is_real(vm, v) ? "real"
                         : shen_is_bytes(vm, v) ? "bytes"
                         : shen_is_procedure(vm, v) ? "procedure"
                         : shen_pointer(vm, v, NULL) ? "pointer" : "other");
}

/* 0 if every read is right, and otherwise the line of the first that is not. Writes 77 at the
   end of the buffer, which Shen then looks at. */
#define CHECK(c) if (!(c)) return shen_make_fixnum(__LINE__)
shen_value reads_right(shen_vm *vm, shen_value *args)
{
    shen_value pair = args[0], vector = args[1], string = args[2], bytes = args[3], symbol = args[4], real = args[5];
    CHECK(shen_fixnum(shen_head(vm, pair)) == 1);
    CHECK(shen_is_pair(vm, shen_tail(vm, pair)));
    CHECK(shen_vector_length(vm, vector) == 3);
    CHECK(shen_vector_ref(vm, vector, 2) == shen_make_fixnum(7));
    CHECK(shen_vector_ref(vm, vector, 3) == SHEN_NONE);
    CHECK(shen_vector_ref(vm, vector, -1) == SHEN_NONE);
    size_t n;
    const char *s = shen_string_bytes(vm, string, &n);
    CHECK(s && n == 8 && memcmp(s, "abcdefgh", 8) == 0);
    char small[4], big[32];
    CHECK(shen_string_copy(vm, string, small, sizeof small) == 8 && strcmp(small, "abc") == 0);
    CHECK(shen_string_copy(vm, string, big, sizeof big) == 8 && strcmp(big, "abcdefgh") == 0);
    unsigned char *b = shen_bytes_data(vm, bytes, &n);
    CHECK(b && n == 3);
    b[2] = 77;
    s = shen_string_bytes(vm, shen_symbol_name(vm, symbol), &n);
    CHECK(s && n == 3 && memcmp(s, "foo", 3) == 0);
    CHECK(shen_number(vm, real) == 1.5);
    CHECK(shen_number(vm, shen_make_fixnum(3)) == 3.0);
    /* The wrong type never raises. */
    shen_value one = shen_make_fixnum(1);
    double nan = shen_number(vm, string);
    CHECK(nan != nan);
    CHECK(shen_head(vm, one) == SHEN_NONE && shen_tail(vm, one) == SHEN_NONE);
    CHECK(shen_vector_length(vm, one) == -1 && shen_vector_ref(vm, one, 0) == SHEN_NONE);
    CHECK(shen_symbol_name(vm, one) == SHEN_NONE && shen_string_bytes(vm, one, NULL) == NULL);
    CHECK(shen_string_copy(vm, one, big, sizeof big) == -1 && shen_bytes_data(vm, one, NULL) == NULL);
    CHECK(shen_pointer(vm, one, NULL) == NULL && shen_pointer(vm, string, "thing") == NULL);
    CHECK(shen_head(vm, SHEN_NONE) == SHEN_NONE && !shen_is_pair(vm, SHEN_ERROR));
    return shen_make_fixnum(0);
}

/* The address, if P is a pointer of the kind named. */
shen_value pointer_of_kind(shen_vm *vm, shen_value *args)
{
    char kind[32];
    shen_string_copy(vm, args[1], kind, sizeof kind);
    return shen_make_bool(shen_pointer(vm, args[0], kind) == (void *)thing);
}

/* One of each thing C can make, with what it needs in roots: rule 2 is the two statements a line. */
shen_value make_all(shen_vm *vm, shen_value *args)
{
    shen_value list = SHEN_NIL, v = SHEN_NIL;
    shen_root(vm, &list);
    shen_root(vm, &v);
    v = shen_make_pointer(vm, (void *)thing, "thing");
    list = shen_cons(vm, v, list);
    v = shen_make_pointer(vm, NULL, "thing");
    list = shen_cons(vm, v, list);
    v = shen_make_vector(vm, 3, shen_make_fixnum(7));
    shen_vector_set(vm, v, 1, list); /* a pointer, which a collection must then see */
    list = shen_cons(vm, v, list);
    v = shen_intern(vm, "a-symbol");
    list = shen_cons(vm, v, list);
    v = shen_intern(vm, "true");
    list = shen_cons(vm, v, list);
    v = shen_make_bytes(vm, NULL, 3);
    shen_bytes_data(vm, v, NULL)[1] = 9;
    list = shen_cons(vm, v, list);
    v = shen_make_bytes(vm, "\1\2", 2);
    list = shen_cons(vm, v, list);
    v = shen_make_string(vm, "abc", 3);
    list = shen_cons(vm, v, list);
    v = shen_make_real(vm, 1.5);
    return shen_cons(vm, v, list);
}

/* A name, a kind or a message in a buffer in the heap, which interning, making a pointer or
   raising may move before reading it. */
shen_value heap_text(shen_vm *vm, shen_value *args)
{
    static int object;
    int64_t mode = shen_fixnum(args[0]);
    const char *text = mode == 0 ? "ffi-heap-intern-93817" : mode == 1 ? "ffi-heap-kind-93817" : "ffi-heap-message-93817";
    shen_value b = shen_make_bytes(vm, text, strlen(text) + 1);
    if (b == SHEN_ERROR)
        return b;
    shen_root(vm, &b);
    const char *s = (const char *)shen_bytes_data(vm, b, NULL);
    if (mode == 0)
        return shen_intern(vm, s);
    if (mode == 1)
        return shen_make_pointer(vm, &object, s);
    return shen_raise(vm, s);
}

/* From bytes in the heap, which the allocation may move. */
shen_value copy_string(shen_vm *vm, shen_value *args)
{
    size_t n;
    const char *s = shen_string_bytes(vm, args[0], &n);
    return shen_make_string(vm, s, n);
}

/* A store of args[1] at element 0 of args[0], and whether it was made. */
shen_value vector_set_first(shen_vm *vm, shen_value *args)
{
    return shen_make_bool(shen_vector_set(vm, args[0], 0, args[1]));
}

shen_value vector_set_out_of_range(shen_vm *vm, shen_value *args)
{
    return shen_make_bool(shen_vector_set(vm, args[0], 99, SHEN_NIL) || shen_vector_set(vm, shen_make_fixnum(1), 0, SHEN_NIL));
}

/* Lengths past what an object's header holds. */
shen_value huge_vector(shen_vm *vm, shen_value *args)
{
    return shen_make_vector(vm, (int64_t)1 << 56, SHEN_NIL);
}

shen_value huge_bytes(shen_vm *vm, shen_value *args)
{
    return shen_make_bytes(vm, NULL, (size_t)1 << 56);
}

/* Named by a string from Shen: none if there is no such thing. */
shen_value global_named(shen_vm *vm, shen_value *args)
{
    char name[64];
    shen_string_copy(vm, args[0], name, sizeof name);
    shen_value v = shen_global(vm, name);
    return v == SHEN_NONE ? shen_intern(vm, "none") : v;
}

shen_value call_named(shen_vm *vm, shen_value *args)
{
    char name[64];
    shen_string_copy(vm, args[0], name, sizeof name);
    shen_value f = shen_function(vm, name);
    return f == SHEN_NONE ? shen_intern(vm, "none") : shen_call(vm, f, 1, &args[1]);
}

shen_value raises(shen_vm *vm, shen_value *args)
{
    char message[32];
    strcpy(message, "from C"); /* not a literal: the runtime keeps no pointer to it */
    return shen_raise(vm, message);
}

shen_value raises_value(shen_vm *vm, shen_value *args) { return shen_raise_value(vm, "C refuses ~S here", args[0]); }

/* An error caught in C, which goes on: its message, then the same call again. */
shen_value caught_message(shen_vm *vm, shen_value *args)
{
    shen_value message = SHEN_NIL;
    shen_root(vm, &message);
    if (shen_call(vm, args[0], 1, &args[1]) != SHEN_ERROR)
        return shen_intern(vm, "no-error");
    message = shen_exception_message(vm);
    if (shen_call(vm, args[0], 1, &args[1]) != SHEN_ERROR)
        return shen_intern(vm, "no-error-the-second-time");
    return message;
}

/* The error itself, for Shen to look at. */
shen_value caught_exception(shen_vm *vm, shen_value *args)
{
    return shen_call(vm, args[0], 1, &args[1]) == SHEN_ERROR ? shen_exception(vm) : shen_intern(vm, "no-error");
}

/* Returning with locals still rooted, whose frame is gone by the next collection. */
shen_value early_return(shen_vm *vm, shen_value *args)
{
    shen_value a = shen_make_string(vm, "a", 1);
    shen_root(vm, &a);
    shen_value b = shen_make_string(vm, "b", 1);
    shen_root(vm, &b);
    if (shen_is_pair(vm, args[0]))
        return shen_raise(vm, "and with an error");
    return a;
}

/* Rooted, then unrooted by hand, with others below it. */
shen_value root_and_unroot(shen_vm *vm, shen_value *args)
{
    shen_value a = shen_make_string(vm, "kept", 4);
    shen_root(vm, &a);
    shen_value b = shen_make_string(vm, "dropped", 7);
    shen_root(vm, &b);
    shen_unroot(vm, 1);
    shen_make_string(vm, "x", 1);
    shen_unroot(vm, 1);
    return shen_cons(vm, a, args[0]);
}

/* A root that outlives the call. */
static shen_root_box *kept;

shen_value keep(shen_vm *vm, shen_value *args)
{
    kept = shen_root_new(vm, args[0]);
    return shen_make_bool(kept != NULL);
}

shen_value kept_value(shen_vm *vm, shen_value *args) { return shen_root_get(kept); }

shen_value kept_set(shen_vm *vm, shen_value *args)
{
    shen_root_set(kept, args[0]);
    return SHEN_TRUE;
}

shen_value kept_delete(shen_vm *vm, shen_value *args)
{
    shen_root_delete(kept);
    return SHEN_TRUE;
}

/* More than a chunk of them, each holding a different string, which collections move: half are
   deleted, and those made next take their places. Gives 0, or the line that failed. */
enum { MANY = 300 };
static shen_value numbered(shen_vm *vm, int i)
{
    char text[16];
    snprintf(text, sizeof text, "%d", i);
    return shen_make_string(vm, text, strlen(text));
}

static int is_numbered(shen_vm *vm, shen_value v, int i)
{
    char text[16], got[16];
    snprintf(text, sizeof text, "%d", i);
    return shen_string_copy(vm, v, got, sizeof got) >= 0 && strcmp(text, got) == 0;
}

shen_value many_roots(shen_vm *vm, shen_value *args)
{
    shen_root_box *boxes[MANY];
    for (int i = 0; i < MANY; i++) {
        shen_value v = numbered(vm, i);
        boxes[i] = shen_root_new(vm, v);
        CHECK(boxes[i]);
    }
    for (int i = 0; i < MANY; i++)
        CHECK(is_numbered(vm, shen_root_get(boxes[i]), i));
    shen_root_box *spare[MANY / 2];
    for (int i = 0; i < MANY / 2; i++) {
        spare[i] = boxes[2 * i];
        shen_root_delete(boxes[2 * i]);
    }
    for (int i = 0; i < MANY / 2; i++) {
        shen_value v = numbered(vm, MANY + i);
        boxes[2 * i] = shen_root_new(vm, v);
        CHECK(boxes[2 * i]);
        int reused = 0; /* none is made while any deleted one is free */
        for (int k = 0; k < MANY / 2; k++)
            reused |= boxes[2 * i] == spare[k];
        CHECK(reused);
    }
    for (int i = 0; i < MANY / 2; i++) {
        CHECK(is_numbered(vm, shen_root_get(boxes[2 * i]), MANY + i));
        CHECK(is_numbered(vm, shen_root_get(boxes[2 * i + 1]), 2 * i + 1));
    }
    for (int i = 0; i < MANY; i++)
        shen_root_delete(boxes[i]);
    return shen_make_fixnum(0);
}

/* shen_release and shen_acquire around a wait, with a value in a root, which they leave as it was. */
shen_value released_wait(shen_vm *vm, shen_value *args)
{
    int32_t ms = (int32_t)shen_fixnum(args[1]);
    void *token = shen_release(vm);
    wait_ms(ms);
    shen_acquire(vm, token);
    return args[0];
}

/* A root deleted between shen_release and shen_acquire, with no shen_vm: the next one made has its place. */
shen_value delete_when_released(shen_vm *vm, shen_value *args)
{
    shen_root_box *r = shen_root_new(vm, args[0]);
    void *token = shen_release(vm);
    shen_root_delete(r);
    shen_acquire(vm, token);
    shen_root_box *again = shen_root_new(vm, args[0]);
    int same = again == r;
    shen_root_delete(again);
    return shen_make_bool(same);
}

/* Roots deleted on a thread that the runtime knows nothing about, all at once with this one. */
enum { DELETED = 200 };
static shen_root_box *to_delete[DELETED];

#ifdef _WIN32
static DWORD WINAPI deleter(LPVOID unused)
#else
static void *deleter(void *unused)
#endif
{
    for (int i = 0; i < DELETED; i += 2)
        shen_root_delete(to_delete[i]);
    return 0;
}

shen_value delete_on_another_thread(shen_vm *vm, shen_value *args)
{
    for (int i = 0; i < DELETED; i++)
        CHECK(to_delete[i] = shen_root_new(vm, args[0]));
#ifdef _WIN32
    HANDLE t = CreateThread(NULL, 0, deleter, NULL, 0, NULL);
    CHECK(t);
#else
    pthread_t t;
    CHECK(pthread_create(&t, NULL, deleter, NULL) == 0);
#endif
    for (int i = 1; i < DELETED; i += 2)
        shen_root_delete(to_delete[i]);
#ifdef _WIN32
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
#else
    pthread_join(t, NULL);
#endif
    for (int i = 0; i < DELETED; i++) {
        shen_root_box *r = shen_root_new(vm, args[0]);
        CHECK(r);
        int reused = 0;
        for (int k = 0; k < DELETED; k++)
            reused |= r == to_delete[k];
        CHECK(reused);
        shen_root_delete(r);
    }
    return shen_make_fixnum(0);
}

/* A library's callback with userdata, as sqlite3_exec has: the library knows nothing of Shen, and
   the closure lives in a root. A false from Shen stops it, and so does an error. */
static int count_to(int n, int (*callback)(void *, int), void *data)
{
    for (int i = 0; i < n; i++)
        if (callback(data, i))
            return i;
    return n;
}

struct walk {
    shen_vm *vm;
    shen_root_box *fn;
    int failed;
};

static int walk_callback(void *data, int i)
{
    struct walk *w = data;
    shen_value x = shen_make_fixnum(i);
    shen_value r = shen_call(w->vm, shen_root_get(w->fn), 1, &x);
    if (r == SHEN_ERROR)
        w->failed = 1;
    return r == SHEN_ERROR || r == SHEN_FALSE;
}

shen_value walk(shen_vm *vm, shen_value *args)
{
    struct walk w = {vm, shen_root_new(vm, args[1]), 0};
    int reached = count_to((int)shen_fixnum(args[0]), walk_callback, &w);
    shen_root_delete(w.fn);
    return w.failed ? SHEN_ERROR : shen_make_fixnum(reached);
}

/* What the API refuses, each ending the process: tests/cli.sh runs them one at a time. */
shen_value returns_none(shen_vm *vm, shen_value *args) { return shen_head(vm, shen_make_fixnum(1)); }

shen_value cons_none(shen_vm *vm, shen_value *args) { return shen_cons(vm, shen_head(vm, shen_make_fixnum(1)), SHEN_NIL); }

shen_value cons_error(shen_vm *vm, shen_value *args) { return shen_cons(vm, SHEN_ERROR, SHEN_NIL); }

/* A value from just before a collection, which a rooted copy of it shows has happened. Only an odd
   number of them shows in the value itself, as the two semispaces take turns. */
static shen_value allocated_past(shen_vm *vm)
{
    shen_value now = shen_make_string(vm, "old", 3), before = now;
    shen_root(vm, &now);
    while (now == before)
        shen_make_string(vm, "x", 1);
    return before;
}

shen_value returns_stale(shen_vm *vm, shen_value *args) { return allocated_past(vm); }

shen_value reads_stale(shen_vm *vm, shen_value *args) { return shen_make_bool(shen_is_string(vm, allocated_past(vm))); }


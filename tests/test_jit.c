/* Calling-convention tests and measurements: loads the lowered
   benchmark programs (tests/bench/programs.kl), checks their results, runs them
   under GC stress and times them. */
#define _DEFAULT_SOURCE /* clock_gettime under -std=c11 with glibc */
#include "../src/runtime/jit.h"
#include "../src/runtime/reader.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;
#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static VM *vm;

static V call(const char *name, size_t n, ...)
{
    V args[8];
    va_list ap;
    va_start(ap, n);
    for (size_t i = 0; i < n; i++)
        args[i] = va_arg(ap, V);
    va_end(ap);
    V f = *cell_function(vm, symbol_cell(intern_cstr(vm, name)));
    return jit_call(vm, f, n, args);
}

static bool raised(V v, const char *message)
{
    if (v != V_CLEARED)
        return false;
    V e = vm->exception;
    if (!is_object(e) || obj_type(e) != T_EXCEPTION)
        return false;
    V m = exception_message(vm, e);
    return !message || (string_length(m) == strlen(message) &&
                        memcmp(string_bytes(m), message, strlen(message)) == 0);
}

static long list_length(V l)
{
    long n = 0;
    for (; is_pair(l); l = ptr(l)[1])
        n++;
    return n;
}

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void correctness(const char *label)
{
    CHECK(call("fib", 1, fix(20)) == fix(6765));
    CHECK(call("tak", 3, fix(18), fix(12), fix(6)) == fix(7));
    V l = call("iota", 2, fix(30), V_NIL);
    CHECK(list_length(l) == 30);
    vm->stack[vm->top - vm->stack] = l; /* keep it rooted below the next call */
    vm->top++;
    V r = call("nrev", 1, l);
    CHECK(list_length(r) == 30 && ptr(r)[0] == fix(30));
    vm->top--;
    CHECK(call("even?", 1, fix(100001)) == V_FALSE);
    CHECK(call("closure-calls", 1, fix(1000)) == fix(1000));
    CHECK(call("trap-loop", 2, fix(1000), fix(0)) == fix(1000));
    CHECK(call("raise-loop", 2, fix(1000), fix(0)) == fix(1000));
    CHECK(call("deep", 1, fix(100000)) == fix(100000));
    V s = call("catch-deep", 1, fix(1000));
    CHECK(is_object(s) && obj_type(s) == T_STRING && string_length(s) == 6);
    V b = call("big-frame", 5, fix(1), fix(2), fix(3), fix(4), fix(5));
    CHECK(list_length(b) == 3 && fixval(ptr(ptr(ptr(b)[1])[1])[1]) == 10);
    CHECK(call("alloc-loop", 2, fix(2000), V_NIL) == fix(2));
    CHECK(raised(call("wrong-arity", 0), "fib: expected 1 argument, got 2"));
    CHECK(raised(call("not-boolean", 0), NULL));
    V half = call("add-float", 0);
    CHECK(is_object(half) && obj_type(half) == T_FLOAT && float_value(half) == 1.5);
    CHECK(raised(call("overflow", 0), "integer overflow"));
    CHECK(raised(call("deep-raise", 1, fix(10)), "bottom"));
    CHECK(vm->nhandlers == 0);
    printf("%s: correctness checks done (%zu collections so far)\n", label, vm->collections);
}

static void timed(const char *what, double calls, V result, double start)
{
    double t = now() - start;
    char shown[32];
    if (result == V_CLEARED)
        snprintf(shown, sizeof shown, "raised!");
    else if (is_fix(result))
        snprintf(shown, sizeof shown, "= %lld", (long long)fixval(result));
    else if (is_boolean(result))
        snprintf(shown, sizeof shown, "= %s", result == V_TRUE ? "true" : "false");
    else
        snprintf(shown, sizeof shown, "list of %ld", list_length(result));
    printf("  %-34s %8.3f s  %7.2f ns/call  %s\n", what, t, t / calls * 1e9, shown);
}

static void measurements(void)
{
    printf("measurements (ARM64):\n");
    double t;
    t = now();
    timed("fib 30", 2692537, call("fib", 1, fix(30)), t);
    t = now();
    timed("tak 24 16 8 (x1)", 1, call("tak", 3, fix(24), fix(16), fix(8)), t);
    t = now();
    timed("even?/odd? 10^7 tail calls", 1e7, call("even?", 1, fix(10000000)), t);
    t = now();
    timed("closure calls 10^7", 1e7, call("closure-calls", 1, fix(10000000)), t);
    V l = call("iota", 2, fix(30), V_NIL);
    vm->stack[vm->top - vm->stack] = l;
    vm->top++;
    t = now();
    timed("nrev 30 x 10^5 (496 calls each)", 496e5, call("nrev-loop", 3, fix(100000), l, V_NIL), t);
    vm->top--;
    t = now();
    timed("trap-error, no raise, 10^6", 1e6, call("trap-loop", 2, fix(1000000), fix(0)), t);
    t = now();
    timed("trap-error, raise, 10^6", 1e6, call("raise-loop", 2, fix(1000000), fix(0)), t);
    t = now();
    timed("non-tail recursion 10^6 deep", 1e6, call("deep", 1, fix(1000000)), t);
    printf("  stack grew to %zu slots; %zu collections\n", vm->stack_words, vm->collections);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "bench/programs.sbc";
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return 1;
    }
    static char text[1 << 20];
    size_t len = fread(text, 1, sizeof text, f);
    fclose(f);

    vm = vm_create(1 << 16, 1 << 16);
    if (!vm || !jit_init(vm)) {
        fprintf(stderr, "cannot create the VM\n");
        return 1;
    }
    vm->max_words = (size_t)1 << 27; /* 1 GiB: a bug may allocate without end */
    LoadStats stats = {0};
    const char *error = NULL;
    if (!load_stage0(vm, text, len, &stats, &error)) {
        fprintf(stderr, "load failed: %s\n", error);
        return 1;
    }
    correctness("normal");
    vm->stress = true;
    correctness("GC stress");
    vm->stress = false;
    vm_collect(vm, 0);
    jit_destroy(vm);
    vm_destroy(vm);
    if (argc > 2 && strcmp(argv[2], "--measure") == 0) {
        /* Measure with the specified 32 MiB semispaces, twice: the first
           run includes one-time stack growth. */
        vm = vm_create(1 << 22, 1 << 16);
        if (!vm || !jit_init(vm) || !load_stage0(vm, text, len, &stats, &error))
            return 1;
        measurements();
        measurements();
        jit_destroy(vm);
        vm_destroy(vm);
    }
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("jit tests passed");
    return 0;
}

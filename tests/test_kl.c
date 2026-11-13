/* The complete KLambda engine, with the lowerer running inside
   shen-jit.

   1. eval-kl cases (tests/kl/eval-cases.kl), each evaluated through the
      port's shen-jit.eval-kl, so the lowerer, install and every primitive
      run as they will at runtime.
   2. The self-hosting check: shen-jit lowers every defun of the kernel,
      the port and the lowerer itself, and compares the result with the
      stage 0 output produced by the same lowerer under a host. It reads
      the defuns that stage 0 wrote exactly as Shen read them (*.forms), so
      both lowerers see the same data.

   Usage: test_kl STAGE0-DIR CASES [--stress]
   With --stress, the cases run with a collection before every allocation
   and the self-hosting check is skipped. */
#define _DEFAULT_SOURCE /* clock_gettime under -std=c11 with glibc */
#include "../src/runtime/jit.h"
#include "../src/runtime/ops.h"
#include "../src/runtime/reader.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

static VM *vm;
static int failures;

static const char *const kernel_files[] = {
    "toplevel", "core", "sys", "dict", "sequent", "yacc", "reader", "prolog", "track", "load",
    "writer", "macros", "declarations", "types", "t-star", "init",
    "extension-features", "extension-launcher", "extension-programmable-pattern-matching",
    "extension-namespaces", "extension-expand-dynamic", "extension-type-annotations"};

static char *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *text = malloc((size_t)n + 1);
    if (text && fread(text, 1, (size_t)n, f) != (size_t)n) {
        free(text);
        text = NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return text;
}

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* Exact structural equality: integers and reals differ, reals compare by
   bits. */
static bool same(V a, V b)
{
    for (;;) {
        if (a == b)
            return true;
        if (is_pair(a) && is_pair(b)) {
            if (!same(ptr(a)[0], ptr(b)[0]))
                return false;
            a = ptr(a)[1];
            b = ptr(b)[1];
            continue;
        }
        if (!is_object(a) || !is_object(b) || obj_type(a) != obj_type(b))
            return false;
        switch (obj_type(a)) {
        case T_STRING:
            return string_length(a) == string_length(b) &&
                   memcmp(string_bytes(a), string_bytes(b), string_length(a)) == 0;
        case T_REAL: return ptr(a)[REAL_VALUE] == ptr(b)[REAL_VALUE];
        default: return false;
        }
    }
}

/* Prints the first place two values differ. */
static void print_value(V v, int depth);
static bool show_difference(V a, V b)
{
    if (same(a, b))
        return false;
    if (is_pair(a) && is_pair(b)) {
        V whole_a = a, whole_b = b;
        for (; is_pair(a) && is_pair(b); a = ptr(a)[1], b = ptr(b)[1])
            if (show_difference(ptr(a)[0], ptr(b)[0])) {
                if (!is_pair(ptr(a)[0]) && !is_pair(ptr(b)[0])) {
                    fputs("    in shen-jit: ", stderr);
                    print_value(whole_a, 0);
                    fputs("\n    in stage 0:    ", stderr);
                    print_value(whole_b, 0);
                    fputc('\n', stderr);
                }
                return true;
            }
        if (!same(a, b)) {
            fputs("    tails differ\n", stderr);
            return true;
        }
        return false;
    }
    fputs("    shen-jit: ", stderr);
    print_value(a, 0);
    fputs("\n    stage 0:    ", stderr);
    print_value(b, 0);
    fputc('\n', stderr);
    return true;
}

/* Writes a value in full, for comparing mismatches outside the test. */
static void dump(FILE *f, V v)
{
    if (is_pair(v)) {
        fputc('(', f);
        for (bool first = true; is_pair(v); v = ptr(v)[1], first = false) {
            if (!first)
                fputc(' ', f);
            dump(f, ptr(v)[0]);
        }
        fputc(')', f);
    } else if (is_fix(v))
        fprintf(f, "%lld", (long long)fixval(v));
    else if (v == V_NIL)
        fputs("()", f);
    else if (v == V_TRUE || v == V_FALSE)
        fputs(v == V_TRUE ? "true" : "false", f);
    else if (is_symbol(v))
        fprintf(f, "%.*s", (int)string_length(ptr(v)[SYM_NAME]), string_bytes(ptr(v)[SYM_NAME]));
    else if (is_object(v) && obj_type(v) == T_STRING)
        fprintf(f, "\"%.*s\"", (int)string_length(v), string_bytes(v));
    else if (is_object(v) && obj_type(v) == T_REAL)
        fprintf(f, "%.17g", real_value(v));
    else
        fputs("#<object>", f);
}

static V function(const char *name)
{
    return *cell_function(vm, symbol_cell(intern_cstr(vm, name)));
}

/* Reads every form of a file onto the front of a rooted list, in order. */
static bool read_all(const char *path, bool kl, V *out)
{
    size_t len;
    char *text = slurp(path, &len);
    if (!text) {
        fprintf(stderr, "cannot read %s\n", path);
        return false;
    }
    Reader r = {vm, text, text + len, NULL, kl};
    V items = V_NIL;
    vm_root(vm, &items);
    while (!reader_at_end(&r)) {
        V form = reader_read(&r);
        if (form == V_CLEARED || (items = make_pair(vm, form, items)) == V_CLEARED) {
            fprintf(stderr, "%s: %s\n", path, r.error ? r.error : "out of memory");
            vm_unroot(vm, 1);
            free(text);
            return false;
        }
    }
    vm_unroot(vm, 1);
    free(text);
    V reversed = V_NIL;
    while (items != V_NIL) {
        V next = ptr(items)[1];
        ptr(items)[1] = reversed;
        reversed = items;
        items = next;
    }
    *out = reversed;
    return true;
}

static bool load_stage0_dir(const char *dir)
{
    char path[1024];
    size_t count = sizeof kernel_files / sizeof kernel_files[0];
    char *all = NULL;
    size_t all_len = 0;
    for (size_t i = 0; i < count + 2; i++) {
        const char *name = i < count ? kernel_files[i] : i == count ? "shen-jit" : "lower";
        snprintf(path, sizeof path, "%s/%s.sbc", dir, name);
        size_t len;
        char *text = slurp(path, &len);
        if (!text) {
            fprintf(stderr, "cannot read %s\n", path);
            return false;
        }
        all = realloc(all, all_len + len + 1);
        memcpy(all + all_len, text, len);
        all_len += len;
        all[all_len++] = '\n';
        free(text);
    }
    LoadStats stats = {0};
    const char *error = NULL;
    bool ok = load_stage0(vm, all, all_len, &stats, &error);
    if (!ok)
        fprintf(stderr, "stage 0 load failed: %s\n", error);
    free(all);
    return ok;
}

static const char *message(void)
{
    static char text[256];
    V e = vm->exception;
    if (!is_object(e) || obj_type(e) != T_EXCEPTION)
        return "(no exception)";
    V m = exception_message(vm, e);
    snprintf(text, sizeof text, "%.*s", (int)string_length(m), string_bytes(m));
    return text;
}

static void print_value(V v, int depth)
{
    if (depth > 4) {
        fputs("...", stderr);
        return;
    }
    if (is_fix(v))
        fprintf(stderr, "%lld", (long long)fixval(v));
    else if (v == V_NIL)
        fputs("()", stderr);
    else if (v == V_TRUE || v == V_FALSE)
        fputs(v == V_TRUE ? "true" : "false", stderr);
    else if (is_symbol(v))
        fprintf(stderr, "%.*s", (int)string_length(ptr(v)[SYM_NAME]), string_bytes(ptr(v)[SYM_NAME]));
    else if (is_pair(v)) {
        fputc('(', stderr);
        for (int n = 0; is_pair(v) && n < 12; v = ptr(v)[1], n++) {
            if (n)
                fputc(' ', stderr);
            print_value(ptr(v)[0], depth + 1);
        }
        fputs(v == V_NIL ? ")" : " ...)", stderr);
    } else if (is_object(v) && obj_type(v) == T_STRING)
        fprintf(stderr, "\"%.*s\"", (int)string_length(v), string_bytes(v));
    else if (is_object(v) && obj_type(v) == T_REAL)
        fprintf(stderr, "%.17g", real_value(v));
    else
        fputs("#<object>", stderr);
}

/* Cases are kept on the stack while they run, so collections update them. */
static void run_cases(const char *path)
{
    V *slot = vm->top;
    vm_stack_reserve(vm, (size_t)(slot - vm->stack) + 2);
    vm->top = slot + 2;
    if (!read_all(path, true, &slot[0]))
        exit(1);
    size_t n = 0, failed = 0;
    for (; slot[0] != V_NIL; slot[0] = ptr(slot[0])[1], n++) {
        slot[1] = ptr(slot[0])[0];
        if (!is_pair(slot[1])) /* documentation strings */
            continue;
        V error_symbol = intern_cstr(vm, "error"); /* may allocate: intern first */
        V c = slot[1];
        bool is_error = ptr(c)[0] == error_symbol;
        size_t len = 0;
        for (V l = c; is_pair(l); l = ptr(l)[1])
            len++;
        V form = len == 3 ? ptr(ptr(ptr(c)[1])[1])[0] : ptr(ptr(c)[1])[0];
        V result = jit_call(vm, function("shen-jit.eval-kl"), 1, &form);
        c = slot[1];
        const char *problem = NULL;
        if (is_error) {
            if (result != V_CLEARED)
                problem = "no error raised";
            else if (len == 3) {
                /* The message first: making it may collect and move the case,
                   and argument order is unspecified (gcc on x86-64 read the
                   expected text before). */
                const char *got = message();
                c = slot[1];
                V prefix = ptr(ptr(c)[1])[0];
                if (strncmp(got, string_bytes(prefix), string_length(prefix)) != 0)
                    problem = "wrong error message";
            }
        } else if (result == V_CLEARED) {
            problem = message();
        } else if (!same(result, ptr(ptr(c)[1])[0])) {
            problem = "wrong value";
        }
        if (problem) {
            failed++;
            fprintf(stderr, "case %zu: %s: ", n + 1, problem);
            print_value(slot[1], 0);
            if (result != V_CLEARED && !is_error) {
                fputs("  got ", stderr);
                print_value(result, 0);
            }
            fputc('\n', stderr);
        }
    }
    vm->top = slot;
    failures += (int)failed;
    printf("eval-kl cases: %zu run, %zu failed\n", n, failed);
}

/* The self-hosting check. Kernel source is read as KLambda, the stage 0
   output as stage 0 text; both lists live on the stack. */
static void self_host(const char *stage0)
{
    char path[1024];
    size_t nfiles = sizeof kernel_files / sizeof kernel_files[0] + 2;
    V *slot = vm->top;
    vm_stack_reserve(vm, (size_t)(slot - vm->stack) + 4);
    vm->top = slot + 4;
    /* slot 0: source forms of all files; slot 1: stage 0 forms; slot 2: the
       sealed names; slot 3: scratch. */
    slot[0] = slot[1] = slot[2] = V_NIL;
    for (size_t i = nfiles; i-- > 0;) {
        const char *name = i < nfiles - 2 ? kernel_files[i] : i == nfiles - 2 ? "shen-jit" : "lower";
        snprintf(path, sizeof path, "%s/%s.forms", stage0, name);
        if (!read_all(path, false, &slot[3]))
            exit(1);
        /* Keep defuns only, prepended file by file from the last. The loop
           variables are rooted, since make_pair can move everything. */
        V defun = intern_cstr(vm, "defun"), l = V_NIL, acc = V_NIL;
        vm_root(vm, &defun);
        vm_root(vm, &l);
        vm_root(vm, &acc);
        for (l = slot[3]; is_pair(l); l = ptr(l)[1])
            if (is_pair(ptr(l)[0]) && ptr(ptr(l)[0])[0] == defun)
                acc = make_pair(vm, ptr(l)[0], acc); /* reversed */
        for (l = acc; is_pair(l); l = ptr(l)[1])
            slot[0] = make_pair(vm, ptr(l)[0], slot[0]);
        snprintf(path, sizeof path, "%s/%s.sbc", stage0, name);
        if (!read_all(path, false, &slot[3]))
            exit(1);
        acc = V_NIL;
        for (l = slot[3]; is_pair(l); l = ptr(l)[1])
            acc = make_pair(vm, ptr(l)[0], acc);
        for (l = acc; is_pair(l); l = ptr(l)[1])
            slot[1] = make_pair(vm, ptr(l)[0], slot[1]);
        vm_unroot(vm, 3);
    }
    {
        V l = V_NIL;
        vm_root(vm, &l);
        for (l = slot[0]; is_pair(l); l = ptr(l)[1])
            slot[2] = make_pair(vm, ptr(ptr(ptr(l)[0])[1])[0], slot[2]);
        vm_unroot(vm, 1);
    }

    size_t n = 0, differ = 0;
    double start = now();
    for (; is_pair(slot[0]) && is_pair(slot[1]); slot[0] = ptr(slot[0])[1], slot[1] = ptr(slot[1])[1], n++) {
        V args[2] = {ptr(slot[0])[0], slot[2]};
        V result = jit_call(vm, function("shen-jit.lower.defun"), 2, args);
        if (result == V_CLEARED) {
            if (differ++ < 5)
                fprintf(stderr, "self-host: defun %zu raised: %s\n", n, message());
        } else if (!same(result, ptr(slot[1])[0])) {
            if (differ++ < 5) {
                fprintf(stderr, "self-host: defun %zu differs: ", n);
                print_value(ptr(ptr(ptr(slot[1])[0])[1])[0], 0);
                fputc('\n', stderr);
                show_difference(result, ptr(slot[1])[0]);
                char name[64];
                snprintf(name, sizeof name, "selfhost-%zu-shen-jit.txt", n);
                FILE *f = fopen(name, "w");
                dump(f, result);
                fclose(f);
                snprintf(name, sizeof name, "selfhost-%zu-stage0.txt", n);
                f = fopen(name, "w");
                dump(f, ptr(slot[1])[0]);
                fclose(f);
            }
        }
    }
    double t = now() - start;
    if (slot[0] != V_NIL || slot[1] != V_NIL) {
        fprintf(stderr, "self-host: different numbers of defuns\n");
        differ++;
    }
    vm->top = slot;
    failures += (int)differ;
    printf("self-hosting: %zu defuns lowered in shen-jit in %.3f s, %zu differ\n", n, t, differ);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: test_kl STAGE0-DIR CASES\n");
        return 2;
    }
    vm = vm_create(1 << 22, 1 << 16);
    if (!vm || !jit_init(vm) || !load_stage0_dir(argv[1]) || !sj_init_host(vm))
        return 1;
    *global_slot_new(vm, intern_cstr(vm, "shen.*gensym*")) = fix(0);
    bool stress = argc > 3 && strcmp(argv[3], "--stress") == 0;
    vm->stress = stress;
    run_cases(argv[2]);
    vm->stress = false;
    if (!stress)
        self_host(argv[1]);
    printf("%zu collections\n", vm->collections);
    jit_destroy(vm);
    vm_destroy(vm);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("kl tests passed");
    return 0;
}

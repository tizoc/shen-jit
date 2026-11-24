/* Independent tests for each instruction and primitive path (tests/kl/ops.kl),
   run normally and under GC stress. */
#include "../src/runtime/jit.h"
#include "../src/runtime/reader.h"

#include <stdlib.h>
#include <string.h>

enum Kind { FIX, BOOL, SYM, FLOAT, ERR };

typedef struct {
    const char *name;
    int nargs;
    long long args[8];
    enum Kind kind;
    long long value; /* FIX value, BOOL 0/1 */
    const char *text; /* SYM name, or ERR message prefix (NULL: any) */
} Case;

#define T true
#define F false
static const Case cases[] = {
    {"t-move", 2, {3, 4}, FIX, 26, NULL},
    {"t-consts", 0, {0}, FIX, 6, NULL},
    {"t-const-values", 0, {0}, FIX, 3, NULL},
    {"t-captures", 8, {1, 2, 3, 4, 5, 6, 7, 8}, FIX, 136, NULL},
    {"t-nested-captures", 1, {1}, FIX, 4321, NULL},
    {"t-thunk", 1, {5}, FIX, 6, NULL},
    {"t-curried", 0, {0}, FIX, 42, NULL},
    {"t-call-tail-value", 0, {0}, FIX, 42, NULL},
    {"t-apply-non-procedure", 0, {0}, ERR, 0, NULL},
    {"t-apply-symbol", 0, {0}, ERR, 0, NULL},
    {"t-undefined", 0, {0}, ERR, 0, "undefined function no-such-function"},
    {"t-thunk-with-arg", 0, {0}, ERR, 0, "freeze: expected 0 arguments, got 1"},
    {"t-lambda-no-arg", 0, {0}, ERR, 0, "lambda: expected 1 argument, got 0"},
    {"t-cond-1", 0, {0}, FIX, 10, NULL},
    {"t-cond-2", 0, {0}, FIX, 20, NULL},
    {"t-cond-none", 0, {0}, ERR, 0, "cond: no clause applies"},
    {"t-handler-literal", 0, {0}, FIX, 7, NULL},
    {"t-handler-closure", 0, {0}, FIX, 8, NULL},
    {"t-handler-nested", 0, {0}, FIX, 9, NULL},
    {"t-handler-message", 0, {0}, FIX, 3, NULL},
    {"t-handler-escapes", 0, {0}, ERR, 0, "hd"},
    {"t-handler-not-procedure", 0, {0}, ERR, 0, NULL},
    {"t-handler-unused", 0, {0}, FIX, 5, NULL},
    {"t-handler-depth", 1, {5}, FIX, 1, NULL},
    {"t-and", 2, {T, T}, BOOL, 1, NULL},
    {"t-and", 2, {T, F}, BOOL, 0, NULL},
    {"t-and", 2, {F, -1}, BOOL, 0, NULL},
    {"t-or", 2, {T, -1}, BOOL, 1, NULL},
    {"t-or", 2, {F, F}, BOOL, 0, NULL},
    {"t-and-bad", 0, {0}, ERR, 0, "1 is not a boolean"},
    {"t-or-bad", 0, {0}, ERR, 0, "1 is not a boolean"},
    {"t-if-bad", 0, {0}, ERR, 0, "1 is not a boolean"},
    {"t-add-float", 0, {0}, FLOAT, 0, NULL},
    {"t-add-float-check", 0, {0}, FIX, 1, NULL},
    {"t-sub-overflow", 0, {0}, ERR, 0, "integer overflow"},
    {"t-add-overflow", 0, {0}, ERR, 0, "integer overflow"},
    {"t-mul", 0, {0}, FIX, -5535, NULL},
    {"t-mul-overflow", 0, {0}, ERR, 0, "integer overflow"},
    {"t-div-exact", 0, {0}, FIX, 42, NULL},
    {"t-div-float", 0, {0}, FIX, 1, NULL},
    {"t-div-zero", 0, {0}, ERR, 0, "division by zero"},
    {"t-add-non-number", 0, {0}, ERR, 0, NULL},
    {"t-less-non-number", 0, {0}, ERR, 0, NULL},
    {"t-compare", 2, {1, 2}, FIX, 101, NULL},
    {"t-compare", 2, {2, 1}, FIX, 1010, NULL},
    {"t-compare", 2, {2, 2}, FIX, 1100, NULL},
    {"t-compare-float", 0, {0}, FIX, 101, NULL},
    {"t-eq-fixnums", 0, {0}, FIX, 1, NULL},
    {"t-eq-int-float", 0, {0}, BOOL, 1, NULL},
    {"t-eq-strings", 0, {0}, BOOL, 1, NULL},
    {"t-eq-lists", 0, {0}, BOOL, 1, NULL},
    {"t-eq-lists-differ", 0, {0}, BOOL, 0, NULL},
    {"t-eq-vectors", 0, {0}, BOOL, 1, NULL},
    {"t-eq-symbols", 0, {0}, BOOL, 1, NULL},
    {"t-eq-mixed", 0, {0}, BOOL, 0, NULL},
    {"t-hd-bad", 0, {0}, ERR, 0, "hd"},
    {"t-tl-bad", 0, {0}, ERR, 0, "tl"},
    {"t-consp", 0, {0}, FIX, 1, NULL},
    {"t-vector", 0, {0}, FIX, 42, NULL},
    {"t-vector-fresh", 0, {0}, BOOL, 1, NULL},
    {"t-vector-bad-index", 0, {0}, ERR, 0, NULL},
    {"t-vector-bad-length", 0, {0}, ERR, 0, NULL},
    {"t-globals", 0, {0}, FIX, 10, NULL},
    {"t-unbound", 0, {0}, ERR, 0, NULL},
    {"t-number?", 0, {0}, FIX, 11, NULL},
    {"t-error-to-string-bad", 0, {0}, ERR, 0, NULL},
    {"t-tail-loop", 1, {1000000}, SYM, 0, "done"},
    {"t-call-tail-value-loop", 0, {0}, SYM, 0, "done"},
};

static VM *vm;
static int failures;

static bool text_is(V s, const char *text, bool prefix)
{
    size_t n = strlen(text);
    return (prefix ? string_length(s) >= n : string_length(s) == n) &&
           memcmp(string_bytes(s), text, n) == 0;
}

static const char *check(const Case *c)
{
    /* t-and and t-or take Booleans (T, F) or a non-Boolean (-1). */
    bool booleans = strcmp(c->name, "t-and") == 0 || strcmp(c->name, "t-or") == 0;
    V args[8];
    for (int i = 0; i < c->nargs; i++) {
        long long a = c->args[i];
        args[i] = booleans && a == T ? V_TRUE : booleans && a == F ? V_FALSE : fix(a);
    }
    size_t handlers = vm->nhandlers, top = (size_t)(vm->top - vm->stack);
    V f = *cell_function(vm, symbol_cell(intern_cstr(vm, c->name)));
    V r = jit_call(vm, f, (size_t)c->nargs, args);
    if (vm->nhandlers != handlers || (size_t)(vm->top - vm->stack) != top)
        return "handler stack or stack top not restored";
    switch (c->kind) {
    case FIX: return r == fix(c->value) ? NULL : "wrong fixnum";
    case BOOL: return r == (c->value ? V_TRUE : V_FALSE) ? NULL : "wrong boolean";
    case SYM: return is_symbol(r) && text_is(ptr(r)[SYM_NAME], c->text, false) ? NULL : "wrong symbol";
    case FLOAT: return is_object(r) && obj_type(r) == T_FLOAT ? NULL : "not a float";
    case ERR:
        if (r != V_CLEARED)
            return "no error raised";
        if (c->text && !(is_object(vm->exception) && obj_type(vm->exception) == T_EXCEPTION &&
                         text_is(exception_message(vm, vm->exception), c->text, true)))
            return "wrong error message";
        return NULL;
    }
    return "bad case";
}

static void run(const char *label)
{
    size_t before = vm->stack_words;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        const char *problem = check(&cases[i]);
        if (problem) {
            fprintf(stderr, "%s: %s: %s\n", label, cases[i].name, problem);
            failures++;
        }
    }
    if (vm->stack_words != before) {
        fprintf(stderr, "%s: tail calls grew the stack\n", label);
        failures++;
    }
    printf("%s: %zu cases run\n", label, sizeof cases / sizeof cases[0]);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "kl/ops.sbc";
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return 1;
    }
    static char text[1 << 20];
    size_t len = fread(text, 1, sizeof text, f);
    fclose(f);
    vm = vm_create(1 << 16, 1 << 16);
    LoadStats stats = {0};
    const char *error = NULL;
    if (vm)
        vm->max_words = (size_t)1 << 27; /* 1 GiB: a bug may allocate without end */
    if (!vm || !jit_init(vm) || !load_stage0(vm, text, len, &stats, &error)) {
        fprintf(stderr, "setup failed: %s\n", error ? error : "VM");
        return 1;
    }
    run("normal");
    vm->stress = true;
    run("GC stress");
    jit_destroy(vm);
    vm_destroy(vm);
    if (failures) {
        fprintf(stderr, "%d case(s) failed\n", failures);
        return 1;
    }
    puts("op tests passed");
    return 0;
}

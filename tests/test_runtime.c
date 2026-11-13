/* Runtime tests: collector, stack invariants, symbols and the image
   round trip over every object family; and the file stream sweep. */
#include "../src/runtime/reader.h"
#include "../src/runtime/ops.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                          \
        }                                                                        \
    } while (0)

/* A canonical rendering of a value graph, used to compare it before and after
   collections and images. Shared and cyclic structure is rendered by depth. */
typedef struct {
    char *text;
    size_t len, cap;
} Buf;

static void put(Buf *b, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char tmp[512];
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (b->len + (size_t)n + 1 > b->cap) {
        b->cap = 2 * (b->len + (size_t)n + 1);
        b->text = realloc(b->text, b->cap);
    }
    memcpy(b->text + b->len, tmp, (size_t)n + 1);
    b->len += (size_t)n;
}

static void describe(Buf *b, V v, int depth)
{
    if (depth > 12) {
        put(b, "...");
        return;
    }
    if (is_fix(v)) {
        put(b, "%lld", (long long)fixval(v));
        return;
    }
    if (v == V_NIL) { put(b, "[]"); return; }
    if (v == V_TRUE) { put(b, "true"); return; }
    if (v == V_FALSE) { put(b, "false"); return; }
    if (v == V_CLEARED) { put(b, "<cleared>"); return; }
    if (is_pair(v)) {
        put(b, "(");
        describe(b, ptr(v)[0], depth + 1);
        put(b, " . ");
        describe(b, ptr(v)[1], depth + 1);
        put(b, ")");
        return;
    }
    uint64_t *o = ptr(v);
    switch (hdr_type(o[0])) {
    case T_STRING: put(b, "\"%.*s\"", (int)string_length(v), string_bytes(v)); break;
    case T_BYTES:
        put(b, "#bytes[");
        for (size_t i = 0; i < string_length(v); i++)
            put(b, "%02x", (unsigned char)string_bytes(v)[i]);
        put(b, "]");
        break;
    case T_SYMBOL:
        put(b, "%.*s/%llx/%llu", (int)string_length(o[SYM_NAME]), string_bytes(o[SYM_NAME]),
            (unsigned long long)o[SYM_HASH], (unsigned long long)o[SYM_CELL]);
        break;
    case T_REAL: put(b, "%.17g", real_value(v)); break;
    case T_VECTOR:
        put(b, "#(");
        for (size_t i = 0; i < hdr_size(o[0]); i++) {
            describe(b, o[1 + i], depth + 1);
            put(b, " ");
        }
        put(b, ")");
        break;
    case T_CLOSURE:
        put(b, "<closure ");
        describe(b, o[CLO_CODE], depth + 1);
        for (size_t i = 0; i < hdr_size(o[0]); i++) {
            put(b, " ");
            describe(b, o[CLO_CAPS + i], depth + 1);
        }
        put(b, ">");
        break;
    case T_FOREIGN:
        put(b, "<foreign %llu ", (unsigned long long)o[FOREIGN_ARITY]);
        describe(b, o[FOREIGN_DESC], depth + 1);
        put(b, ">");
        break;
    case T_POINTER:
        put(b, "<pointer ");
        describe(b, o[POINTER_KIND], depth + 1);
        put(b, ">");
        break;
    case T_CODE:
        put(b, "<code %llu %llu %llu %llu %llu ", (unsigned long long)o[CODE_ARITY],
            (unsigned long long)o[CODE_FRAME], (unsigned long long)o[CODE_CBASE],
            (unsigned long long)o[CODE_NCONST], (unsigned long long)o[CODE_NCODE]);
        describe(b, o[CODE_NAME], depth + 1);
        put(b, " ");
        describe(b, o[CODE_BYTECODE], depth + 1);
        put(b, ">");
        break;
    case T_EXCEPTION:
        put(b, "<exception ");
        describe(b, o[EXC_MESSAGE], depth + 1);
        put(b, ">");
        break;
    case T_STREAM: put(b, "<stream %llu>", (unsigned long long)(o[STREAM_FLAGS] & STREAM_KIND_MASK)); break;
    default: put(b, "<bad object>"); break;
    }
}

static char *render(V v)
{
    Buf b = {0};
    describe(&b, v, 0);
    return b.text;
}

/* Guest stack slots serve as rooted temporaries, as they do for emitted code. */
static V *slots(VM *vm, size_t n)
{
    vm_stack_reserve(vm, n); /* frames write only below the dirty mark */
    vm->top = vm->stack + n;
    return vm->stack;
}

static void test_long_list(void)
{
    VM *vm = vm_create(4096, 1024);
    V *s = slots(vm, 1);
    s[0] = V_NIL;
    for (int i = 0; i < 100000; i++)
        s[0] = make_pair(vm, fix(i), s[0]);
    long long sum = 0, n = 0;
    for (V l = s[0]; is_pair(l); l = ptr(l)[1], n++)
        sum += fixval(ptr(l)[0]);
    CHECK(n == 100000);
    CHECK(sum == 4999950000LL);
    CHECK(vm->collections > 0);
    vm_destroy(vm);
}

/* One value of every family, with sharing and a cycle. */
static V build_world(VM *vm, V *s)
{
    s[0] = make_vector(vm, 13, V_NIL);
    s[1] = make_pair(vm, fix(1), V_NIL);
    s[2] = make_real(vm, 3.25); /* first: argument order is unspecified, and s[1] must be read after
                                   the allocation that may move it (gcc on x86-64 read it before) */
    s[1] = make_pair(vm, s[2], s[1]);
    ptr(s[0])[1] = s[1];
    s[2] = make_string(vm, "hello, world", 12);
    ptr(s[0])[2] = s[2];
    s[3] = make_bytes(vm, "\x01\x02\x03\xff", 4);
    ptr(s[0])[3] = s[3];
    s[4] = intern_cstr(vm, "world-symbol");
    ptr(s[0])[4] = s[4];
    s[5] = make_code(vm, s[4], s[3], 2, 9, 0, 3, 1, V_NIL);
    ptr(s[0])[5] = s[5];
    s[6] = make_closure(vm, s[5], 2, &s[1]); /* captures s[1] and s[2] */
    ptr(s[0])[6] = s[6];
    ptr(s[0])[7] = make_foreign(vm, s[2], 1);
    ptr(s[0])[12] = make_pointer(vm, 0x1234, s[4]);
    s[7] = make_string(vm, "boom", 4);
    ptr(s[0])[8] = make_exception(vm, s[7], V_CLEARED);
    ptr(s[0])[9] = make_stream(vm, STREAM_STDOUT | STREAM_OUTPUT | STREAM_OPEN, stdout);
    ptr(s[0])[10] = make_stream(vm, STREAM_FILE | STREAM_OPEN, (void *)0x1234);
    ptr(s[0])[11] = s[0]; /* a cycle */
    return s[0];
}

static void test_world_under_stress(void)
{
    VM *vm = vm_create(256, 1024);
    vm->stress = true;
    V *s = slots(vm, 8);
    build_world(vm, s);
    char *before = render(s[0]);
    for (int i = 0; i < 5; i++)
        vm_collect(vm, 0);
    char *after = render(s[0]);
    CHECK(strcmp(before, after) == 0);
    CHECK(ptr(s[0])[11] == s[0]); /* the cycle survives as one object */
    CHECK(ptr(ptr(s[0])[6])[CLO_CAPS] == ptr(s[0])[1]); /* sharing survives */
    free(before);
    free(after);
    vm_destroy(vm);
}

/* Under stress a stale pointer fails at once: a new object never lands on the
   overwritten words it points to, and they no longer count as the heap. */
static void test_stale_under_stress(void)
{
    VM *vm = vm_create(1024, 64);
    vm->stress = 1;
    uint64_t *a = vm_alloc(vm, 2);
    a[0] = fix(1);
    a[1] = V_NIL;
    CHECK(vm_in_heap(vm, a));
    uint64_t *b = vm_alloc(vm, 2); /* collects, and nothing reaches a */
    CHECK(b != a);
    CHECK(a[0] == UINT64_C(0xDEADDEADDEADDEAD));
    CHECK(!vm_in_heap(vm, a));
    CHECK(vm_in_heap(vm, b));
    vm_destroy(vm);
}

/* A large caller calls a small callee that collects; the caller then resumes
   with its larger extent and collects again. */
static void test_clear_above_top(void)
{
    VM *vm = vm_create(1024, 64);
    vm->program->max_frame = 10; /* the caller's frame size */
    V *s = slots(vm, 10);
    for (int i = 0; i < 10; i++)
        s[i] = make_pair(vm, fix(i), V_NIL);
    vm->top = vm->stack + 5; /* the callee's extent */
    vm_collect(vm, 0);
    for (int i = 5; i < 64; i++)
        CHECK(vm->stack[i] == V_CLEARED);
    vm->top = vm->stack + 10; /* the caller resumes */
    vm_collect(vm, 0);        /* would abort on a stale pointer */
    for (int i = 0; i < 5; i++)
        CHECK(is_pair(vm->stack[i]) && fixval(ptr(vm->stack[i])[0]) == i);
    vm_destroy(vm);
}

static void test_stack_growth(void)
{
    VM *vm = vm_create(1024, 64);
    V *s = slots(vm, 40);
    for (int i = 0; i < 40; i++)
        s[i] = fix(i);
    vm->fp = vm->stack + 30;
    CHECK(vm_stack_grow(vm, 200));
    CHECK(vm->stack_words >= 200);
    CHECK(vm->fp == vm->stack + 30);
    for (int i = 0; i < 40; i++)
        CHECK(vm->stack[i] == fix(i));
    for (size_t i = 40; i < vm->stack_words; i++)
        CHECK(vm->stack[i] == V_CLEARED);
    vm->stack_max_words = 256;
    CHECK(!vm_stack_grow(vm, 1000));
    vm_destroy(vm);
}

static void test_symbols(void)
{
    VM *vm = vm_create(1024, 64);
    V *s = slots(vm, 1);
    s[0] = intern_cstr(vm, "abc");
    uint64_t hash = ptr(s[0])[SYM_HASH];
    CHECK(intern_cstr(vm, "abc") == s[0]);
    char name[32];
    for (int i = 0; i < 20000; i++) {
        snprintf(name, sizeof name, "sym-%d", i);
        intern_cstr(vm, name);
    }
    /* The table is weak: a collection keeps a symbol that something else
       reaches, has a value or function, or that code calls by name. */
    V valued = intern_cstr(vm, "valued");
    *global_slot_new(vm, valued) = fix(7);
    symbol_mark_called(intern_cstr(vm, "called"));
    vm_collect(vm, 0);
    CHECK(vm->nsymbols == 3);
    CHECK(vm->program->nfree_cells > 0);
    CHECK(intern_cstr(vm, "abc") == s[0]);
    CHECK(ptr(s[0])[SYM_HASH] == hash);
    CHECK(global_value(vm, intern_cstr(vm, "valued")) == fix(7));
    size_t cell = symbol_cell(intern_cstr(vm, "called"));
    vm_collect(vm, 0);
    CHECK(symbol_cell(intern_cstr(vm, "called")) == cell);
    s[0] = intern_cstr(vm, "sym-1");
    CHECK(symbol_cell(s[0]) != symbol_cell(intern_cstr(vm, "sym-2")));
    vm_destroy(vm);
}

/* Cells above the last one kept leave the array, which every collection walks. A name kept above
   dead ones holds them in it, for new symbols to reuse. */
static void test_symbol_cells_trimmed(void)
{
    VM *vm = vm_create(1 << 20, 1024);
    V *s = slots(vm, 1);
    s[0] = intern_cstr(vm, "kept");
    vm_collect(vm, 0);
    size_t base = vm->program->cells.count;
    char name[32];
    for (int i = 0; i < 5000; i++) {
        snprintf(name, sizeof name, "dies-%d", i);
        intern_cstr(vm, name);
    }
    CHECK(vm->program->cells.count == base + 2 * 5000);
    vm_collect(vm, 0);
    CHECK(vm->program->cells.count == base);
    CHECK(vm->program->nfree_cells == 0);
    CHECK(intern_cstr(vm, "kept") == s[0]);
    for (int i = 0; i < 5000; i++) {
        snprintf(name, sizeof name, "dies-%d", i);
        intern_cstr(vm, name);
    }
    V high = intern_cstr(vm, "high");
    size_t cell = symbol_cell(high);
    CHECK(2 * cell >= base + 2 * 5000);
    *global_slot_new(vm, high) = fix(7);
    vm_collect(vm, 0);
    CHECK(vm->program->cells.count == 2 * (cell + 1));
    CHECK(vm->program->nfree_cells == 5000);
    CHECK(global_value(vm, intern_cstr(vm, "high")) == fix(7));
    V reused = intern_cstr(vm, "reused");
    CHECK(symbol_cell(reused) < cell);
    CHECK(global_value(vm, reused) == V_CLEARED);
    vm_destroy(vm);
}

/* A collection while a symbol is being made leaves its cell its own. The names exist already, as
   an allocation between the two symbols would repair the array, and there are no free cells. */
static void test_symbol_cell_while_collecting(void)
{
    VM *vm = vm_create(1 << 20, 1024);
    V *s = slots(vm, 2);
    s[0] = make_string(vm, "stress-a", 8);
    s[1] = make_string(vm, "stress-b", 8);
    vm_collect(vm, 0);
    CHECK(vm->program->nfree_cells == 0);
    vm->stress = 1;
    V a = intern_string(vm, s[0]);
    *global_slot_new(vm, a) = fix(1);
    V b = intern_string(vm, s[1]);
    *global_slot_new(vm, b) = fix(2);
    CHECK(symbol_cell(a) != symbol_cell(b));
    CHECK(symbol_global(a) != symbol_global(b));
    CHECK(global_value(vm, a) == fix(1));
    vm_destroy(vm);
}

static bool same_file(const char *a, const char *b)
{
    FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
    bool same = fa && fb;
    while (same) {
        int ca = fgetc(fa), cb = fgetc(fb);
        if (ca != cb)
            same = false;
        if (ca == EOF || cb == EOF)
            break;
    }
    if (fa)
        fclose(fa);
    if (fb)
        fclose(fb);
    return same;
}

static void test_image_round_trip(void)
{
    static char stub;
    VM *vm = vm_create(1024, 64);
    vm->program->compile_stub = vm->program->foreign_stub = &stub;
    V *s = slots(vm, 8);
    build_world(vm, s);
    size_t k;
    CHECK(ra_push(&vm->program->consts, s[0], &k) && k == 0);
    *global_slot_new(vm, s[4]) = s[0];
    *cell_arity(vm, symbol_cell(s[4])) = fix(2); /* a function cell holds only program code */
    char *before = render(s[0]);
    vm->top = vm->stack; /* nothing on the stack at a dump */
    CHECK(image_dump(vm, "test.img"));
    vm_destroy(vm);

    VM *loaded = image_load("test.img", 1024, 64, &stub, &stub);
    CHECK(loaded != NULL);
    if (!loaded)
        return;
    V world = *ra_at(&loaded->program->consts, 0);
    char *after = render(world);
    CHECK(strcmp(before, after) == 0);
    V sym = intern_cstr(loaded, "world-symbol");
    CHECK(sym == ptr(world)[4]);
    CHECK(global_value(loaded, sym) == world);
    CHECK(*cell_arity(loaded, symbol_cell(sym)) == fix(2));
    CHECK(ptr(ptr(world)[6])[PROC_ENTRY] == (uint64_t)(uintptr_t)&stub);
    CHECK(ptr(ptr(world)[5])[CODE_NATIVE] == 0);
    CHECK(ptr(ptr(world)[7])[PROC_ENTRY] == (uint64_t)(uintptr_t)&stub);
    CHECK(ptr(ptr(world)[7])[FOREIGN_ADDRESS] == 0);
    CHECK(ptr(ptr(world)[12])[POINTER_ADDRESS] == 0); /* it loads dead */
    CHECK(ptr(ptr(world)[12])[POINTER_KIND] == sym);
    CHECK(ptr(ptr(world)[9])[STREAM_HANDLE] == (uint64_t)(uintptr_t)stdout);
    CHECK(ptr(ptr(world)[9])[STREAM_FLAGS] & STREAM_OPEN);
    CHECK(ptr(ptr(world)[10])[STREAM_HANDLE] == 0);
    CHECK(!(ptr(ptr(world)[10])[STREAM_FLAGS] & STREAM_OPEN));
    CHECK(image_dump(loaded, "test2.img"));
    CHECK(same_file("test.img", "test2.img"));
    free(before);
    free(after);
    vm_destroy(loaded);
}

static const char sample_stage0[] =
    "[defun add1 [code add1 1 5 [1] [[const 3 0] [prim 4 + 2 3] [return 4]] []]]\n"
    "[defun twice [code twice 1 6 [] [[move 5 2] [call-sealed 5 3 add1 1]\n"
    "                                 [tail-call 3 add1 1]] []]]\n"
    "[defun mk [code mk 1 4 [] [[closure 3 0 2] [return 3]]\n"
    "  [[code lambda 1 4 [] [[capture 3 0] [prim 3 + 3 2] [return 3]] []]]]]\n"
    "[defun k [code k 0 3 [\"\\\"hi\" 1.5 sym true [] -7] [[const 2 0] [return 2]] []]]\n";

static void test_loader(void)
{
    VM *vm = vm_create(256, 64);
    vm->stress = true;
    LoadStats stats = {0};
    const char *error = NULL;
    CHECK(load_stage0(vm, sample_stage0, sizeof sample_stage0 - 1, &stats, &error));
    if (error)
        fprintf(stderr, "load error: %s\n", error);
    CHECK(stats.defuns == 4 && stats.codes == 5 && stats.instructions == 13);
    V add1 = *cell_function(vm, symbol_cell(intern_cstr(vm, "add1")));
    CHECK(is_proc(add1) && obj_type(add1) == T_CLOSURE);
    V add1_code = ptr(add1)[CLO_CODE];
    CHECK(ptr(add1_code)[CODE_ARITY] == 1 && ptr(add1_code)[CODE_FRAME] == 5);
    /* The sealed call's slot holds add1's stage 0 closure. */
    bool bound = false;
    for (size_t i = 0; i < vm->program->consts.count; i++)
        bound |= *ra_at(&vm->program->consts, i) == add1;
    CHECK(bound);
    V k = ptr(*cell_function(vm, symbol_cell(intern_cstr(vm, "k"))))[CLO_CODE];
    V hi = *ra_at(&vm->program->consts, ptr(k)[CODE_CBASE]);
    CHECK(string_length(hi) == 3 && memcmp(string_bytes(hi), "\"hi", 3) == 0);
    CHECK(real_value(*ra_at(&vm->program->consts, ptr(k)[CODE_CBASE] + 1)) == 1.5);
    CHECK(*ra_at(&vm->program->consts, ptr(k)[CODE_CBASE] + 3) == V_TRUE);
    CHECK(*ra_at(&vm->program->consts, ptr(k)[CODE_CBASE] + 4) == V_NIL);
    CHECK(*ra_at(&vm->program->consts, ptr(k)[CODE_CBASE] + 5) == fix(-7));

    static const char *const bad[] = {
        "[defun f [code f 0 3 [] [[frobnicate 2]] []]]",
        "[defun f [code f 0 3 [] [[move 3 2]] []]]",
        "[defun f [code f 0 4 [] [[prim 2 + 2]] []]]",
        "[defun f [code f 0 4 [] [[call 2 2 g 1]] []]]",
        "[defun f [code f 0 4 [] [[call-sealed 2 0 undefined-g 0]] []]]",
        "[defun f [code f 0 4 [] [[const 2 0]] []]]",
        "[defun f [code f 0 4 [] [[return 2]] []]",
        "[defun f [code f 0 4 [] [[jump 3] [label 0] [return 2]] []]]",
        "[defun f [code f 0 4 [] [[label 0] [label 0] [return 2]] []]]",
        "[defun f [code f 0 4 [] [[move 2 2]] []]]",
        "[defun f [code f 0 4 [] [[push-handler 9] [return 2]] []]]",
        "[defun f [code f 0 4 [] [[return [const 0]]] []]]",
        "[defun f [code f 0 4 [a] [[return [const 1]]] []]]",
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        error = NULL;
        CHECK(!load_stage0(vm, bad[i], strlen(bad[i]), &stats, &error) && error);
    }
    vm_destroy(vm);
}

/* A collection closes a file stream that nothing reaches and keeps one that
   is rooted. */
static void test_file_sweep(void)
{
    VM *vm = vm_create(1024, 1024);
    FILE *dropped = tmpfile(), *kept = tmpfile();
    V a = make_stream(vm, STREAM_FILE | STREAM_OPEN, dropped);
    CHECK(vm_track_file(vm, a));
    V b = make_stream(vm, STREAM_FILE | STREAM_OPEN, kept);
    CHECK(vm_track_file(vm, b));
    vm_root(vm, &b);
    vm_collect(vm, 0);
    CHECK(vm->nfiles == 1 && vm->files[0] == b);
    CHECK(fputc('x', kept) == 'x');
    vm_unroot(vm, 1);
    vm_collect(vm, 0);
    CHECK(vm->nfiles == 0);
    vm_destroy(vm);
}

/* A failed stdio read must not look like EOF. A write-only file gives a
   read error on every platform, including those that cannot open directories. */
static void test_file_read_error(void)
{
    VM *vm = vm_create(1024, 1024);
    const char *path = "runtime-read-error.tmp";
    FILE *f = fopen(path, "wb");
    CHECK(f);
    if (!f) {
        vm_destroy(vm);
        return;
    }
    vm->args[0] = make_stream(vm, STREAM_FILE | STREAM_OPEN, f);
    CHECK(sj_primitive(vm, P_READ_BYTE) == V_CLEARED);
    CHECK(ferror(f));
    if (is_object(vm->exception) && obj_type(vm->exception) == T_EXCEPTION) {
        V message = ptr(vm->exception)[EXC_MESSAGE];
        CHECK(string_length(message) > 11 && memcmp(string_bytes(message), "read-byte: ", 11) == 0);
    } else {
        CHECK(false);
    }
    CHECK(sj_primitive(vm, P_CLOSE) == V_NIL);
    CHECK(remove(path) == 0);
    vm_destroy(vm);
}

int main(void)
{
    test_file_read_error();
    test_file_sweep();
    test_loader();
    test_long_list();
    test_world_under_stress();
    test_stale_under_stress();
    test_clear_above_top();
    test_stack_growth();
    test_symbols();
    test_symbol_cells_trimmed();
    test_symbol_cell_while_collecting();
    test_image_round_trip();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("runtime tests passed");
    return 0;
}

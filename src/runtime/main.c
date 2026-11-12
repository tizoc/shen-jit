/* The shen-jit executable.

     runtime --stage1 STAGE0-DIR IMAGE
         Stage 1: installs the stage 0 definitions, initialises the kernel and
         the selected extensions, and writes the image (docs/design.md,
         "Build stages and startup"). The build appends the image to this
         executable to make shen-jit.

     shen-jit [--seal] [--save IMAGE] [ARGS...]
         Loads the image named by SHEN_JIT_IMAGE, or else the last image
         appended to the executable, and passes the arguments to the kernel's
         launcher, which provides repl, script and eval. --seal, or
         SHEN_JIT_SEAL=1, seals user definitions (shen-jit.seal). --save
         writes the heap as a new image once the launcher returns, as eval
         and script do, so that what they defined loads with the kernel.
         A binary saved with an entry point (shen-jit.save-executable) runs
         that instead of the launcher, and takes no options here.
         SHEN_JIT_GC_STRESS=N collects after every N words allocated;
         SHEN_JIT_STATS prints collection statistics at exit.
         SHEN_JIT_SEMISPACE=SIZE (bytes, or with K, M or G) starts each
         semispace at SIZE instead of 32 MB, or at what the image needs if
         that is more: less collects more often and uses less memory.
         SHEN_JIT_MAX_HEAP=SIZE stops the heap growing past SIZE, at least the
         initial semispace: an allocation that does not fit then raises "out
         of memory". The collector copies, so the process can use two to three
         times SIZE. */
#define _DEFAULT_SOURCE /* access, sigaction */
#include "file.h"
#include "jit.h"
#include "ops.h"
#include "reader.h"
#include <errno.h>
#include <signal.h>

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* The release, from the VERSION file through the Makefile. */
#ifndef SJ_VERSION
#define SJ_VERSION "unknown"
#endif

/* The kernel, port and lowerer come first and are sealed; the extensions
   after them stay open. */
static const char *const stage0_files[] = {
    "toplevel", "core", "sys", "dict", "sequent", "yacc", "reader", "prolog", "track", "load",
    "writer", "macros", "declarations", "types", "t-star", "init", "shen-jit", "lower",
    "extension-features", "extension-launcher", "extension-programmable-pattern-matching",
    "extension-namespaces", "extension-expand-dynamic", "extension-type-annotations"};
enum { SEALED_FILES = 18 };

static char *slurp(const char *path, size_t *len)
{
    FILE *f = sj_fopen(path, "rb");
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

static V function(VM *vm, const char *name)
{
    return *cell_function(vm, symbol_cell(intern_cstr(vm, name)));
}

static bool set_string(VM *vm, const char *global, const char *text)
{
    V s = make_string(vm, text, strlen(text));
    V g = s == V_CLEARED ? V_CLEARED : intern_cstr(vm, global);
    if (g == V_CLEARED)
        return false;
    vm->args[0] = s; /* keep it rooted while interning */
    V *slot = global_slot_new(vm, g);
    if (!slot)
        return false;
    *slot = vm->args[0];
    return true;
}

static bool call0(VM *vm, const char *name)
{
    if (jit_call(vm, function(vm, name), 0, NULL) == V_CLEARED) {
        sj_report(vm, name);
        return false;
    }
    return true;
}

static int stage1(const char *dir, const char *image)
{
    VM *vm = vm_create(1 << 22, 1 << 16);
    if (!vm || !jit_init(vm))
        return 1;

    /* The stage 0 definitions, loaded together so sealed calls can refer
       forward. */
    char path[4096], *all = NULL;
    size_t all_len = 0, seal_until = 0;
    for (size_t i = 0; i < sizeof stage0_files / sizeof stage0_files[0]; i++) {
        if (i == SEALED_FILES)
            seal_until = all_len;
        snprintf(path, sizeof path, "%s/%s.sbc", dir, stage0_files[i]);
        size_t len;
        char *text = slurp(path, &len);
        if (!text) {
            fprintf(stderr, "shen-jit: cannot read %s\n", path);
            return 1;
        }
        all = realloc(all, all_len + len + 1);
        memcpy(all + all_len, text, len);
        all_len += len;
        all[all_len++] = '\n';
        free(text);
    }
    LoadStats stats = {0};
    const char *error = NULL;
    if (!load_stage0_sealed(vm, all, all_len, seal_until, &stats, &error)) {
        fprintf(stderr, "shen-jit: stage 0: %s\n", error);
        return 1;
    }
    free(all);

#if defined(__APPLE__)
    const char *os = "macOS";
#elif defined(__linux__)
    const char *os = "Linux";
#elif defined(_WIN32)
    const char *os = "Windows";
#else
    const char *os = "Unix";
#endif
    if (!sj_init_host(vm) || !set_string(vm, "*language*", "native") ||
        !set_string(vm, "*implementation*", "shen-jit") ||
        !set_string(vm, "*release*", SJ_VERSION) || !set_string(vm, "*port*", SJ_VERSION) ||
        !set_string(vm, "*porters*", "Bruno Deferrari") || !set_string(vm, "*os*", os))
        return 1;

    if (!call0(vm, "shen.initialise"))
        return 1;
    /* The extensions Shen/Scheme initialises (docs/semantics.md, section 13). */
    V features = make_pair(vm, intern_cstr(vm, "shen/shen-jit"), V_NIL);
    if (features == V_CLEARED ||
        jit_call(vm, function(vm, "shen.x.features.initialise"), 1, &features) == V_CLEARED) {
        sj_report(vm, "shen.x.features.initialise");
        return 1;
    }
    if (!call0(vm, "shen.x.programmable-pattern-matching.initialise") ||
        !call0(vm, "shen.x.namespaces.initialise") || !call0(vm, "shen-jit.initialise"))
        return 1;

    if (!image_dump(vm, image)) {
        fprintf(stderr, "shen-jit: cannot write %s\n", image);
        return 1;
    }
    jit_destroy(vm);
    vm_destroy(vm);
    return 0;
}

/* SHEN_JIT_STATS prints collection statistics when the process ends,
   however it ends. */
static VM *stats_vm;

static void print_stats(void)
{
    double cpu = (double)clock() / CLOCKS_PER_SEC;
    if (stats_vm->ncroots)
        fprintf(stderr, "shen-jit: %zu C roots still registered\n", stats_vm->ncroots);
    fprintf(stderr, "shen-jit: %zu collections, %.3f s of %.3f s CPU (%.1f%%), longest %.2f ms; "
            "semispace %zu KB\n", stats_vm->collections, stats_vm->gc_seconds, cpu,
            cpu > 0 ? 100 * stats_vm->gc_seconds / cpu : 0, 1000 * stats_vm->gc_longest,
            stats_vm->space_words * sizeof(uint64_t) / 1024);
    /* What stays live, by type, to help find memory growth. */
    static const char *const names[T_LIMIT] = {"pairs", "strings", "bytecode", "symbols", "reals",
                                               "absvectors", "closures", "foreign functions", "code",
                                               "exceptions", "streams", "pointers", "shared views"};
    size_t count[T_LIMIT] = {0}, words[T_LIMIT] = {0}, total = 0;
    vm_census(stats_vm, count, words);
    for (int t = 0; t < T_LIMIT; t++)
        total += words[t];
    fprintf(stderr, "shen-jit: live heap %zu KB:", total * sizeof(uint64_t) / 1024);
    for (int t = 0; t < T_LIMIT; t++)
        if (count[t])
            fprintf(stderr, " %s %zu (%zu KB)%s", names[t], count[t], words[t] * sizeof(uint64_t) / 1024,
                    t + 1 < T_LIMIT ? "," : "");
    fprintf(stderr, "\nshen-jit: roots: %zu symbols, %zu function cells, %zu global slots, %zu constant slots\n",
            stats_vm->nsymbols, stats_vm->program->cells.count / 2, stats_vm->program->nglobals - 1, stats_vm->program->consts.count);
    const Space *p = &stats_vm->program->space;
    fprintf(stderr, "shen-jit: program space: %zu KB of objects, %zu symbols published, %zu KB of symbol slots\n",
            (size_t)(p->objects_next - p->objects) * sizeof(uint64_t) / 1024, stats_vm->program->published.count,
            (size_t)(p->symbols_next - p->base) * sizeof(uint64_t) / 1024);
    size_t compiled, freed;
    jit_stats(stats_vm, &compiled, &freed);
    fprintf(stderr, "shen-jit: native code: %zu code objects compiled, %zu freed\n", compiled, freed);
}

/* The executable's file, looked up on PATH as the shell did when its name has
   no directory. */
static const char *executable_file(const char *name, char *path, size_t size)
{
#ifdef _WIN32
    if (win_executable(path, size))
        return path;
#endif
    const char *dirs = strchr(name, '/') ? NULL : getenv("PATH");
    while (dirs && *dirs) {
        int n = (int)strcspn(dirs, ":");
        snprintf(path, size, "%.*s/%s", n ? n : 1, n ? dirs : ".", name);
        struct stat s; /* the shell passes over a directory of that name */
        if (access(path, X_OK) == 0 && stat(path, &s) == 0 && S_ISREG(s.st_mode))
            return path;
        dirs += n + (dirs[n] == ':');
    }
    return name;
}

/* A size setting in words: bytes, or with K, M or G, rounded up to a word. 0 when it is not set or
   empty. Anything else ends the process, as it would otherwise mean another size or none. */
static size_t size_setting(const char *name)
{
    const char *text = getenv(name);
    if (!text || !*text)
        return 0;
    char *unit;
    errno = 0;
    unsigned long long bytes = strtoull(text, &unit, 10);
    int shift = *unit == 'K' || *unit == 'k' ? 10 : *unit == 'M' || *unit == 'm' ? 20
              : *unit == 'G' || *unit == 'g' ? 30 : 0;
    if (text[0] < '0' || text[0] > '9' || errno || unit[shift != 0] || bytes > (SIZE_MAX - 7) >> shift) {
        fprintf(stderr, "shen-jit: %s is not a size: %s\n", name, text);
        exit(1);
    }
    return (size_t)(((bytes << shift) + 7) / sizeof(uint64_t));
}

static int run(int argc, char **argv)
{
#ifdef _WIN32
    win_startup();
#endif
    char path[4096];
    const char *self = executable_file(argv[0], path, sizeof path);
    const char *image = getenv("SHEN_JIT_IMAGE") ? getenv("SHEN_JIT_IMAGE") : self;
    Jit *jit = jit_create();
    size_t semispace = size_setting("SHEN_JIT_SEMISPACE");
    VM *vm = jit ? image_load(image, semispace ? semispace : 1 << 22, 1 << 16, jit_compile_stub(jit), jit_foreign_stub(jit)) : NULL;
    if (!vm) {
        fprintf(stderr, "shen-jit: cannot load an image from %s\n", image);
        return 1;
    }
    jit_attach(vm, jit);
    vm->self = self;
    thread_note_main_stack(vm);
    /* For testing: collect after every N words allocated. */
    const char *stress = getenv("SHEN_JIT_GC_STRESS");
    vm->stress = stress ? strtoul(stress, NULL, 10) : 0;
    vm->max_words = size_setting("SHEN_JIT_MAX_HEAP");
    /* A binary with an entry point (shen-jit.save-executable) is a program:
       its arguments are all its own, and it runs instead of the launcher. */
    V entry = intern_cstr(vm, "shen-jit.*entry*");
    bool program = entry != V_CLEARED && is_symbol(global_value(vm, entry));
    /* Options before the launcher's arguments, which it does not see:
       sealing of user definitions (shen-jit.seal), also SHEN_JIT_SEAL=1,
       and saving an image. */
    const char *seal = getenv("SHEN_JIT_SEAL"), *save = NULL;
    bool seal_flag = false;
    int first = 1;
    while (!program) {
        if (first < argc && strcmp(argv[first], "--seal") == 0) {
            seal_flag = true;
            first++;
        } else if (first + 1 < argc && strcmp(argv[first], "--save") == 0) {
            save = argv[first + 1];
            first += 2;
        } else {
            break;
        }
    }
    vm->seal_user = (seal && *seal && strcmp(seal, "0") != 0) || seal_flag;
    if (getenv("SHEN_JIT_STATS")) {
        stats_vm = vm;
        thread_at_exit(print_stats);
    }
    if (getenv("SHEN_JIT_PROFILE") && !profile_start())
        fprintf(stderr, "shen-jit: cannot start the profiler\n");

    /* The launcher takes the executable's name and the arguments as strings.
       Below them on the stack, where they stay rooted, are *hush* and *argv*
       as the image had them: -q and script set them for this run only, so a
       saved image gets them back. */
    /* Symbols never move, and these have values, so nothing drops them or their slots. */
    V *hush = global_slot_new(vm, intern_cstr(vm, "*hush*"));
    V *argv_slot = global_slot_new(vm, intern_cstr(vm, "*argv*"));
    if (!hush || !argv_slot)
        return 1;
    size_t base = (size_t)(vm->top - vm->stack);
    vm_stack_reserve(vm, base + 3);
    vm->launch_base = base;
    V *args = vm->stack + base;
    args[0] = *hush;
    args[1] = *argv_slot;
    args[2] = V_NIL;
    vm->top = args + 3;
    for (int i = argc - 1; i >= 0; i--) {
        if (i > 0 && i < first)
            continue;
        V s = make_string(vm, argv[i], strlen(argv[i]));
        if (s == V_CLEARED || (args[2] = make_pair(vm, s, args[2])) == V_CLEARED)
            return 1;
    }
    V list = args[2];
    vm->top = args + 2;
    V result;
    if (program) {
        *argv_slot = list;
        result = jit_call(vm, *cell_function(vm, symbol_cell(global_value(vm, entry))), 0, NULL);
    } else {
        result = jit_call(vm, function(vm, "shen.x.launcher.main"), 1, &list);
    }
    fflush(stdout);
    if (result == V_CLEARED) {
        sj_report(vm, "uncaught error");
        if (vm->threads)
            thread_exit(vm, 1);
        return 1;
    }
    if (save) {
        thread_forget_others(vm);
        args = vm->stack + base; /* the run may have moved the stack */
        *hush = args[0];
        *argv_slot = args[1];
        /* No frames are live here, so the image holds just what the cells,
           constants and symbols reach. */
        vm->top = args;
        if (!image_dump(vm, save)) {
            fprintf(stderr, "shen-jit: cannot write %s\n", save);
            return 1;
        }
    }
    if (vm->threads)
        thread_exit(vm, 0); /* the other threads end with the process */
    return 0;
}

#ifndef _WIN32
static void on_broken_pipe(int sig) { (void)sig; }

/* A write to a pipe that nobody reads then fails and raises, where it would end the process.
   A handler and not SIG_IGN: exec resets a handler and keeps an ignored signal, and a child
   should find the default. */
static void raise_on_broken_pipes(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_broken_pipe;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPIPE, &sa, NULL);
}
#else
static void raise_on_broken_pipes(void) {}
#endif

static int start(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "--stage1") == 0)
        return stage1(argv[2], argv[3]);
    raise_on_broken_pipes();
    return run(argc, argv);
}

#ifdef _WIN32
int wmain(int argc, wchar_t **wide)
{
    char **argv = win_arguments(argc, wide);
    if (!argv) {
        fprintf(stderr, "shen-jit: cannot encode Windows command-line arguments as UTF-8\n");
        return 1;
    }
    int result = start(argc, argv);
    win_arguments_free(argc, argv);
    return result;
}
#else
int main(int argc, char **argv) { return start(argc, argv); }
#endif

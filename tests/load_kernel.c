/* Loads every stage 0 file given on the command line into one VM, reports
   what was loaded, then checks an image round trip of the result.
   With --image IMAGE, reloads a written image and dumps it as image2.img. */
#define _DEFAULT_SOURCE /* clock_gettime under -std=c11 with glibc */
#include "../src/runtime/reader.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

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

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--image") == 0) {
        VM *vm = image_load(argv[2], 1 << 20, 1 << 16, NULL, NULL);
        return vm && image_dump(vm, "image2.img") ? 0 : 1;
    }
    VM *vm = vm_create(1 << 20, 1 << 16);
    LoadStats stats = {0};
    size_t text_bytes = 0;
    double start = now();
    /* Load everything first; sealed calls bind once, after all files. */
    char *all = NULL;
    size_t all_len = 0;
    for (int i = 1; i < argc; i++) {
        size_t len;
        char *text = slurp(argv[i], &len);
        if (!text) {
            fprintf(stderr, "cannot read %s\n", argv[i]);
            return 1;
        }
        all = realloc(all, all_len + len + 1);
        memcpy(all + all_len, text, len);
        all_len += len;
        all[all_len++] = '\n';
        text_bytes += len;
        free(text);
    }
    const char *error = NULL;
    if (!load_stage0(vm, all, all_len, &stats, &error)) {
        fprintf(stderr, "load failed: %s\n", error);
        return 1;
    }
    double loaded = now();
    vm_collect(vm, 0);
    printf("stage 0 text:     %zu bytes\n", text_bytes);
    printf("defuns:           %zu\n", stats.defuns);
    printf("code objects:     %zu\n", stats.codes);
    printf("instructions:     %zu\n", stats.instructions);
    printf("bytecode:         %zu bytes\n", stats.bytecode_bytes);
    printf("constants:        %zu (%zu const slots)\n", stats.constants, vm->program->consts.count);
    printf("symbols:          %zu\n", vm->nsymbols);
    printf("live heap:        %zu bytes\n", (size_t)((vm->live_end - vm->space) + (vm->hp - vm->area)) * 8);
    printf("load time:        %.3f s\n", loaded - start);

    if (!image_dump(vm, "kernel-code.img")) {
        fprintf(stderr, "image dump failed\n");
        return 1;
    }
    double dumped = now();
    VM *again = image_load("kernel-code.img", 1 << 20, 1 << 16, NULL, NULL);
    double reloaded = now();
    if (!again || !image_dump(again, "kernel-code2.img")) {
        fprintf(stderr, "image reload failed\n");
        return 1;
    }
    FILE *f = fopen("kernel-code.img", "rb");
    fseek(f, 0, SEEK_END);
    printf("image:            %ld bytes\n", ftell(f));
    fclose(f);
    printf("image load time:  %.3f s (dump %.3f s)\n", reloaded - dumped, dumped - loaded);
    vm_destroy(again);
    vm_destroy(vm);
    free(all);
    return 0;
}

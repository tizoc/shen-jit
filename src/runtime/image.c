/* Heap images (docs/semantics.md, section 15). An image is the live heap after a
   collection, with pointers stored relative to the heap base and raw native
   fields stored as 0, followed by the root arrays and a trailer. Loading adds
   the new base to every pointer and then rebuilds what is specific to the
   process. */
#include "file.h"
#include "vm.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#ifndef SJ_BUILD_ID
#define SJ_BUILD_ID "development"
#endif

enum { IMAGE_VERSION = 2 };

typedef struct {
    char magic[4];
    uint32_t version;
    char build[32];
    uint64_t word_size;
    uint64_t heap_words;
    uint64_t cell_entries;
    uint64_t const_entries;
    uint64_t nsymbols;
    uint64_t intern;
    uint64_t primitive_count;
    uint64_t primitive_checksum;
} ImageHeader;

/* The trailer ends every image, so that an image appended to a file, such as
   the executable, is found from the end of that file. */
typedef struct {
    uint64_t length; /* of the whole image, header to trailer */
    char magic[8];
} ImageTrailer;

static uint64_t image_length(uint64_t heap_words, uint64_t cell_entries, uint64_t const_entries)
{
    return sizeof(ImageHeader) + (heap_words + cell_entries + const_entries) * sizeof(V) +
           sizeof(ImageTrailer);
}

static uint64_t primitive_checksum(void)
{
    uint64_t h = 0;
    for (size_t i = 0; i < primitive_count; i++)
        h = h * 31 + hash_bytes(primitive_table[i].name, strlen(primitive_table[i].name));
    return h;
}

/* Rebase every value of a heap laid out at `heap`: add `delta` to each
   pointer. `raw` is called on each object so raw fields can be cleared or
   rebuilt. */
typedef void RawFields(VM *vm, uint64_t *object);

static V rebase(V v, intptr_t delta)
{
    return is_ptr(v) ? (V)((intptr_t)v + delta) : v;
}

static void rebase_heap(VM *vm, uint64_t *heap, size_t words, intptr_t delta, RawFields *raw)
{
    uint64_t *s = heap;
    while (s < heap + words) {
        uint64_t w = *s;
        if (is_header(w)) {
            size_t first, count;
            obj_values(w, &first, &count);
            for (size_t i = 0; i < count; i++)
                s[first + i] = rebase(s[first + i], delta);
            raw(vm, s);
            s += obj_words(w);
        } else {
            s[0] = rebase(s[0], delta);
            s[1] = rebase(s[1], delta);
            s += 2;
        }
    }
}

static void clear_raw(VM *vm, uint64_t *o)
{
    (void)vm;
    switch (hdr_type(o[0])) {
    case T_CLOSURE: o[PROC_ENTRY] = 0; break;
    case T_FOREIGN:
        o[PROC_ENTRY] = 0;
        o[FOREIGN_ADDRESS] = 0;
        break;
    case T_POINTER:
        o[POINTER_OWNER] = V_NIL;
        o[POINTER_ADDRESS] = 0;
        o[POINTER_LENGTH] = 0;
        break;
    case T_CODE: o[CODE_NATIVE] = 0; break;
    case T_STREAM:
        /* File streams always load closed, so write them closed. */
        o[STREAM_HANDLE] = 0;
        if ((o[STREAM_FLAGS] & STREAM_KIND_MASK) == STREAM_FILE)
            o[STREAM_FLAGS] &= ~(uint64_t)STREAM_OPEN;
        break;
    default: break;
    }
}

/* The reconstruction rules of docs/design.md, "Build stages and startup". */
static void restore_raw(VM *vm, uint64_t *o)
{
    switch (hdr_type(o[0])) {
    case T_CLOSURE: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->compile_stub; break;
    case T_FOREIGN: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->foreign_stub; break;
    case T_CODE:
        o[CODE_NATIVE] = 0;
        if (o[CODE_FRAME] > vm->max_frame)
            vm->max_frame = o[CODE_FRAME];
        break;
    case T_STREAM: {
        uint64_t kind = o[STREAM_FLAGS] & STREAM_KIND_MASK;
        FILE *handle = kind == STREAM_STDIN ? stdin
                     : kind == STREAM_STDOUT ? stdout
                     : kind == STREAM_STDERR ? stderr : NULL;
        o[STREAM_HANDLE] = (uint64_t)(uintptr_t)handle;
        if (!handle)
            o[STREAM_FLAGS] &= ~(uint64_t)STREAM_OPEN;
        break;
    }
    default: break;
    }
}

static bool write_root_array(FILE *f, RootArray *ra, intptr_t delta)
{
    for (size_t i = 0; i < ra->count; i++) {
        V v = rebase(*ra_at(ra, i), delta);
        if (fwrite(&v, sizeof v, 1, f) != 1)
            return false;
    }
    return true;
}

static bool write_image(VM *vm, const char *path, const char *mode)
{
    /* An image holds what the cells, constants and symbol table reach. Drop
       the transient roots, which it does not save, so that a reloaded image
       dumps unchanged. */
    for (size_t i = 0; i < sizeof vm->args / sizeof vm->args[0]; i++)
        vm->args[i] = V_NIL;
    vm->exception = V_NIL;
    vm->fail = V_NIL; /* found again when needed */
    vm->chars = V_NIL;
    vm->messages = V_NIL;
    vm->trace = V_NIL;
    /* Large objects go into the heap, so that the image holds them as it
       does any other object: one collection makes room, the next copies
       them. */
    if (vm->large_words && (!vm_collect(vm, vm->large_words) ||
                            (size_t)(vm->live_end - vm->space) + vm->large_words > vm->space_words))
        return false;
    vm->copy_large = true;
    vm_collect(vm, 0);
    vm->copy_large = false;
    size_t words = (size_t)(vm->live_end - vm->space);
    uint64_t *copy = malloc((words ? words : 1) * sizeof(uint64_t));
    if (!copy)
        return false;
    memcpy(copy, vm->space, words * sizeof(uint64_t));
    intptr_t delta = -(intptr_t)(uintptr_t)vm->space;
    rebase_heap(vm, copy, words, delta, clear_raw);

    ImageHeader h = {{'S', 'J', 'H', 'I'}, IMAGE_VERSION, {0}, sizeof(V), words,
                     vm->cells.count, vm->consts.count, vm->nsymbols,
                     rebase(vm->intern, delta), primitive_count, primitive_checksum()};
    strncpy(h.build, SJ_BUILD_ID, sizeof h.build - 1);
    ImageTrailer t = {image_length(words, vm->cells.count, vm->consts.count), {0}};
    memcpy(t.magic, "SJHI-END", sizeof t.magic);

    FILE *f = sj_fopen(path, mode);
    bool ok = f && fwrite(&h, sizeof h, 1, f) == 1 &&
              fwrite(copy, sizeof(uint64_t), words, f) == words &&
              write_root_array(f, &vm->cells, delta) &&
              write_root_array(f, &vm->consts, delta) && fwrite(&t, sizeof t, 1, f) == 1;
    if (f && fclose(f) != 0)
        ok = false;
    free(copy);
    return ok;
}

bool image_dump(VM *vm, const char *path)
{
    return write_image(vm, path, "wb");
}

bool image_append(VM *vm, const char *path)
{
    return write_image(vm, path, "ab");
}

/* Writes a new file at to with the runtime in the executable at from: what
   comes before the images that end it, if any. */
bool image_copy_runtime(const char *from, const char *to)
{
    FILE *f = sj_fopen(from, "rb");
    if (!f)
        return false;
    ImageTrailer t;
    long end = fseek(f, 0, SEEK_END) == 0 ? ftell(f) : -1;
    while (end >= (long)sizeof t && fseek(f, end - (long)sizeof t, SEEK_SET) == 0 &&
           fread(&t, sizeof t, 1, f) == 1 && memcmp(t.magic, "SJHI-END", sizeof t.magic) == 0 &&
           t.length > 0 && t.length <= (uint64_t)end)
        end -= (long)t.length;
    FILE *out = end >= 0 ? sj_fopen(to, "wb") : NULL;
    bool ok = out && fseek(f, 0, SEEK_SET) == 0;
    char buffer[65536];
    for (long left = end; ok && left > 0;) {
        size_t n = left < (long)sizeof buffer ? (size_t)left : sizeof buffer;
        ok = fread(buffer, 1, n, f) == n && fwrite(buffer, 1, n, out) == n;
        left -= (long)n;
    }
    if (out && fclose(out) != 0)
        ok = false;
    fclose(f);
    if (!ok)
        remove(to);
    return ok;
}

static bool read_root_array(FILE *f, RootArray *ra, size_t count, intptr_t delta)
{
    for (size_t i = 0; i < count; i++) {
        V v;
        size_t index;
        if (fread(&v, sizeof v, 1, f) != 1 || !ra_push(ra, rebase(v, delta), &index))
            return false;
    }
    return true;
}

VM *image_load(const char *path, size_t min_semispace_words, size_t stack_words,
               void *compile_stub, void *foreign_stub)
{
    FILE *f = sj_fopen(path, "rb");
    if (!f)
        return NULL;
    ImageHeader h;
    ImageTrailer t;
    VM *vm = NULL;
    char build[sizeof h.build] = {0};
    strncpy(build, SJ_BUILD_ID, sizeof build - 1);
    /* The image is the last one in the file. */
    if (fseek(f, -(long)sizeof t, SEEK_END) != 0 || fread(&t, sizeof t, 1, f) != 1 ||
        memcmp(t.magic, "SJHI-END", sizeof t.magic) != 0 || t.length > LONG_MAX ||
        fseek(f, -(long)t.length, SEEK_END) != 0 ||
        fread(&h, sizeof h, 1, f) != 1 || memcmp(h.magic, "SJHI", 4) != 0 ||
        h.version != IMAGE_VERSION || memcmp(h.build, build, sizeof build) != 0 ||
        h.word_size != sizeof(V) || h.primitive_count != primitive_count ||
        h.primitive_checksum != primitive_checksum() ||
        t.length != image_length(h.heap_words, h.cell_entries, h.const_entries))
        goto fail;

    size_t words = vm_semispace_for(h.heap_words);
    if (words < min_semispace_words)
        words = min_semispace_words;
    if (!(vm = vm_create(words, stack_words)))
        goto fail;
    vm->compile_stub = compile_stub;
    vm->foreign_stub = foreign_stub;
    if (fread(vm->space, sizeof(uint64_t), h.heap_words, f) != h.heap_words)
        goto fail;
    vm->live_end = vm->space + h.heap_words;
    vm_fresh_area(vm);
    intptr_t delta = (intptr_t)(uintptr_t)vm->space;
    rebase_heap(vm, vm->space, h.heap_words, delta, restore_raw);
    if (!read_root_array(f, &vm->cells, h.cell_entries, delta) ||
        !read_root_array(f, &vm->consts, h.const_entries, delta))
        goto fail;
    vm->intern = rebase(h.intern, delta);
    vm->nsymbols = h.nsymbols;
    /* The code objects take their constant slots again (heap.c). */
    for (uint64_t *s = vm->space; s < vm->live_end; s += is_header(*s) ? obj_words(*s) : 2)
        if (is_header(*s) && hdr_type(*s) == T_CODE)
            vm_track_code(vm, tagged(s, TAG_OBJECT));
    vm_find_free_consts(vm);
    fclose(f);
    return vm;

fail:
    fclose(f);
    vm_destroy(vm);
    return NULL;
}

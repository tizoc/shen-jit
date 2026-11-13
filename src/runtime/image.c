/* Heap images (docs/semantics.md, section 15). An image is the program space's
   symbols and objects, then the live heap after a collection, with pointers
   stored relative to the start of the space or the heap and raw native fields
   stored as 0, followed by the root arrays and a trailer. Loading adds the new
   bases to every pointer and then rebuilds what is specific to the process. */
#include "file.h"
#include "vm.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#ifndef SJ_BUILD_ID
#define SJ_BUILD_ID "development"
#endif

enum { IMAGE_VERSION = 5 };

typedef struct {
    char magic[4];
    uint32_t version;
    char build[32];
    uint64_t word_size;
    uint64_t symbol_words;  /* the program space's symbol slots, used or free */
    uint64_t program_words; /* and its objects */
    uint64_t heap_words;
    uint64_t cell_entries;
    uint64_t const_entries;
    uint64_t global_entries; /* global slots, number 0 included */
    uint64_t free_symbol;
    uint64_t primitive_count;
    uint64_t primitive_checksum;
} ImageHeader;

/* The trailer ends every image, so that an image appended to a file, such as
   the executable, is found from the end of that file. */
typedef struct {
    uint64_t length; /* of the whole image, header to trailer */
    char magic[8];
} ImageTrailer;

static uint64_t image_length(const ImageHeader *h)
{
    return sizeof(ImageHeader) +
           (h->symbol_words + h->program_words + h->heap_words + h->cell_entries + h->const_entries +
            h->global_entries) *
               sizeof(V) +
           sizeof(ImageTrailer);
}

static uint64_t primitive_checksum(void)
{
    uint64_t h = 0;
    for (size_t i = 0; i < primitive_count; i++)
        h = h * 31 + hash_bytes(primitive_table[i].name, strlen(primitive_table[i].name));
    return h;
}

/* In an image a pointer is an offset from the start of the heap, or with one of these bits set,
   from the start of the program space's symbols or of its objects. Where the objects start
   depends on how much address space the process could reserve, so an offset from one start
   would not do for both. */
#define IN_SYMBOLS (UINT64_C(1) << 62)
#define IN_OBJECTS (UINT64_C(1) << 61)

typedef V Rebase(const VM *vm, V v);

static V to_image(const VM *vm, V v)
{
    if (!is_ptr(v))
        return v;
    const Space *p = &vm->program->space;
    if (in_program(vm, ptr(v)))
        return ptr(v) < p->objects ? (v - (V)(uintptr_t)p->base) | IN_SYMBOLS
                                   : (v - (V)(uintptr_t)p->objects) | IN_OBJECTS;
    return v - (V)(uintptr_t)vm->space;
}

static V from_image(const VM *vm, V v)
{
    if (!is_ptr(v))
        return v;
    const Space *p = &vm->program->space;
    if (v & IN_SYMBOLS)
        return (v & ~IN_SYMBOLS) + (V)(uintptr_t)p->base;
    if (v & IN_OBJECTS)
        return (v & ~IN_OBJECTS) + (V)(uintptr_t)p->objects;
    return v + (V)(uintptr_t)vm->space;
}

/* Rebase every value of objects laid out from `at`. `raw` is called on each object so raw
   fields can be cleared or rebuilt. */
typedef void RawFields(VM *vm, uint64_t *object);

static void rebase_objects(VM *vm, uint64_t *at, size_t words, Rebase *rebase, RawFields *raw)
{
    uint64_t *s = at;
    while (s < at + words) {
        uint64_t w = *s;
        if (is_header(w)) {
            size_t first, count;
            obj_values(w, &first, &count);
            for (size_t i = 0; i < count; i++)
                s[first + i] = rebase(vm, s[first + i]);
            raw(vm, s);
            s += obj_words(w);
        } else {
            s[0] = rebase(vm, s[0]);
            s[1] = rebase(vm, s[1]);
            s += 2;
        }
    }
}

/* Symbol slots: a free one holds 0 first. */
static void rebase_symbols(VM *vm, uint64_t *at, size_t words, Rebase *rebase)
{
    for (uint64_t *s = at; s < at + words; s += SYM_WORDS)
        if (s[0]) {
            s[SYM_NAME] = rebase(vm, s[SYM_NAME]);
            s[SYM_CELL] &= ~(UINT64_C(1) << MARK_BIT);
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
    case T_CLOSURE: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->compile_stub; break;
    case T_FOREIGN: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->foreign_stub; break;
    case T_CODE:
        o[CODE_NATIVE] = 0;
        if (o[CODE_FRAME] > vm->program->max_frame)
            vm->program->max_frame = o[CODE_FRAME];
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

static bool write_root_array(FILE *f, VM *vm, RootArray *ra)
{
    for (size_t i = 0; i < ra->count; i++) {
        V v = to_image(vm, *ra_at(ra, i));
        if (fwrite(&v, sizeof v, 1, f) != 1)
            return false;
    }
    return true;
}

static bool write_globals(FILE *f, VM *vm)
{
    for (size_t n = 0; n < vm->program->nglobals; n++) {
        V v = to_image(vm, vm->globals[n]);
        if (fwrite(&v, sizeof v, 1, f) != 1)
            return false;
    }
    return true;
}

static bool write_copy(VM *vm, const char *path, const char *mode);

static bool write_image(VM *vm, const char *path, const char *mode)
{
    /* An image holds what the cells, constants and symbol table reach. Drop
       the transient roots, which it does not save, so that a reloaded image
       dumps unchanged. Guards, the values of dead pointers, pointers' owners
       and roots held by C stay: what only they reach is written but cannot be
       reached in the image, so the next image leaves it out. */
    for (size_t i = 0; i < sizeof vm->args / sizeof vm->args[0]; i++)
        vm->args[i] = V_NIL;
    vm->exception = V_NIL;
    vm->fail = V_NIL; /* found again when needed */
    vm->chars = V_NIL;
    vm->messages = V_NIL;
    vm->trace = V_NIL;
    /* Large objects go into the heap, so that the image holds them as it
       does any other object: one collection makes room, the next copies
       them. The room is in to-space, so what the first says of the area,
       where it counts them twice, does not matter. */
    if (vm->large_words) {
        vm_collect(vm, vm->large_words);
        if ((size_t)(vm->live_end - vm->space) + vm->large_words > vm->space_words)
            return false;
    }
    vm->copy_large = true;
    vm_collect(vm, 0);
    vm->copy_large = false;
    /* Isolates still running, as they may be when --save writes the builder's image, add symbols,
       cells and shared data to the program space under this lock: held while it is copied and
       written, the image is whole. */
    bool shared = vm->program->isolates != NULL;
    if (shared)
        program_shared_lock();
    bool ok = write_copy(vm, path, mode);
    if (shared)
        program_shared_unlock();
    return ok;
}

/* The program space and the collected heap, rebased, with the root arrays. */
static bool write_copy(VM *vm, const char *path, const char *mode)
{
    Space *p = &vm->program->space;
    size_t words = (size_t)(vm->live_end - vm->space);
    size_t symbol_words = (size_t)(p->symbols_next - p->base);
    size_t program_words = (size_t)(p->objects_next - p->objects);
    size_t all = symbol_words + program_words + words;
    uint64_t *copy = malloc((all ? all : 1) * sizeof(uint64_t));
    if (!copy)
        return false;
    uint64_t *symbols = copy, *program = copy + symbol_words, *heap = program + program_words;
    memcpy(symbols, p->base, symbol_words * sizeof(uint64_t));
    memcpy(program, p->objects, program_words * sizeof(uint64_t));
    memcpy(heap, vm->space, words * sizeof(uint64_t));
    rebase_symbols(vm, symbols, symbol_words, to_image);
    rebase_objects(vm, program, program_words, to_image, clear_raw);
    rebase_objects(vm, heap, words, to_image, clear_raw);

    ImageHeader h = {{'S', 'J', 'H', 'I'}, IMAGE_VERSION, {0}, sizeof(V), symbol_words, program_words,
                     words, vm->program->cells.count, vm->program->consts.count, vm->program->nglobals, p->free_symbol,
                     primitive_count, primitive_checksum()};
    strncpy(h.build, SJ_BUILD_ID, sizeof h.build - 1);
    ImageTrailer t = {image_length(&h), {0}};
    memcpy(t.magic, "SJHI-END", sizeof t.magic);

    FILE *f = sj_fopen(path, mode);
    bool ok = f && fwrite(&h, sizeof h, 1, f) == 1 &&
              fwrite(copy, sizeof(uint64_t), all, f) == all &&
              write_root_array(f, vm, &vm->program->cells) &&
              write_root_array(f, vm, &vm->program->consts) && write_globals(f, vm) &&
              fwrite(&t, sizeof t, 1, f) == 1;
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

static bool read_root_array(FILE *f, VM *vm, RootArray *ra, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        V v;
        size_t index;
        if (fread(&v, sizeof v, 1, f) != 1 || !ra_push(ra, from_image(vm, v), &index))
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
        t.length != image_length(&h))
        goto fail;

    size_t words = vm_semispace_for(h.heap_words);
    if (words < min_semispace_words)
        words = min_semispace_words;
    if (!(vm = vm_create(words, stack_words)))
        goto fail;
    vm->program->compile_stub = compile_stub;
    vm->program->foreign_stub = foreign_stub;
    Space *p = &vm->program->space;
    if (!program_reserve(vm, h.symbol_words, h.program_words) ||
        fread(p->base, sizeof(uint64_t), h.symbol_words, f) != h.symbol_words ||
        fread(p->objects, sizeof(uint64_t), h.program_words, f) != h.program_words ||
        fread(vm->space, sizeof(uint64_t), h.heap_words, f) != h.heap_words)
        goto fail;
    p->free_symbol = h.free_symbol;
    vm->live_end = vm->space + h.heap_words;
    vm_fresh_area(vm);
    rebase_symbols(vm, p->base, h.symbol_words, from_image);
    rebase_objects(vm, p->objects, h.program_words, from_image, restore_raw);
    rebase_objects(vm, vm->space, h.heap_words, from_image, restore_raw);
    if (!read_root_array(f, vm, &vm->program->cells, h.cell_entries) ||
        !read_root_array(f, vm, &vm->program->consts, h.const_entries) || h.global_entries < 1 ||
        !vm_globals_commit(vm, h.global_entries) ||
        fread(vm->globals, sizeof(V), h.global_entries, f) != h.global_entries)
        goto fail;
    vm->program->nglobals = h.global_entries;
    for (size_t n = 0; n < vm->program->nglobals; n++)
        vm->globals[n] = from_image(vm, vm->globals[n]);
    /* The symbol tables, again. */
    for (uint64_t *s = p->base; s < p->symbols_next; s += SYM_WORDS) {
        V sym = tagged(s, TAG_SYMBOL);
        if (!s[0])
            continue;
        if (!symbol_table_put(symbol_published(sym) ? &vm->program->published : &vm->own, sym))
            goto fail;
        if (symbol_published(sym) && symbol_cell(sym) >= vm->program->published_top)
            vm->program->published_top = symbol_cell(sym) + 1;
        if (symbol_published(sym) && symbol_global(sym) >= vm->program->published_global_top)
            vm->program->published_global_top = symbol_global(sym) + 1;
    }
    /* The numbers no symbol holds are free. */
    unsigned char *held = calloc(vm->program->nglobals, 1);
    if (!held)
        goto fail;
    for (uint64_t *s = p->base; s < p->symbols_next; s += SYM_WORDS)
        if (s[0] && symbol_global(tagged(s, TAG_SYMBOL)) < vm->program->nglobals)
            held[symbol_global(tagged(s, TAG_SYMBOL))] = 1;
    for (size_t n = 1; n < vm->program->nglobals; n++) {
        if (held[n])
            continue;
        if (vm->program->nfree_globals == vm->program->free_globals_cap) {
            size_t cap = 2 * vm->program->free_globals_cap + 64;
            size_t *list = realloc(vm->program->free_globals, cap * sizeof *list);
            if (!list) {
                free(held);
                goto fail;
            }
            vm->program->free_globals = list;
            vm->program->free_globals_cap = cap;
        }
        vm->program->free_globals[vm->program->nfree_globals++] = n;
    }
    free(held);
    /* The code objects take their constant slots again (heap.c), those of the program for good. */
    for (uint64_t *s = vm->space; s < vm->live_end; s += is_header(*s) ? obj_words(*s) : 2)
        if (is_header(*s) && hdr_type(*s) == T_CODE)
            vm_track_code(vm, tagged(s, TAG_OBJECT));
    for (uint64_t *s = p->objects; s < p->objects_next; s += is_header(*s) ? obj_words(*s) : 2)
        if (is_header(*s) && hdr_type(*s) == T_CODE && vm_track_code(vm, tagged(s, TAG_OBJECT)) &&
            s[CODE_NCONST] + s[CODE_NCODE])
            memset(vm->program->owned + s[CODE_CBASE], PROGRAM, s[CODE_NCONST] + s[CODE_NCODE]);
    vm_find_free_consts(vm);
    fclose(f);
    return vm;

fail:
    fclose(f);
    vm_destroy(vm);
    return NULL;
}

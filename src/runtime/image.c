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

enum { IMAGE_VERSION = 6 };

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

static const char plain_end[] = "SJHI-END", program_end[] = "SJHP-END";

/* A root array holds the ranges of its slots that are in use, in order, and then an empty one at 0.
   The header counts every slot. */
typedef struct {
    uint64_t start, count;
} SlotRange;
enum { RANGE_WORDS = sizeof(SlotRange) / sizeof(V) };

static bool read_trailer(FILE *f, long end, ImageTrailer *t)
{
    return end >= (long)sizeof *t && fseek(f, end - (long)sizeof *t, SEEK_SET) == 0 &&
           fread(t, sizeof *t, 1, f) == 1 && t->length > 0 && t->length <= (uint64_t)end &&
           (memcmp(t->magic, plain_end, sizeof t->magic) == 0 ||
            memcmp(t->magic, program_end, sizeof t->magic) == 0);
}

bool image_is_program(const char *path)
{
    FILE *f = sj_fopen(path, "rb");
    if (!f)
        return false;
    ImageTrailer t;
    bool program = fseek(f, 0, SEEK_END) == 0 && read_trailer(f, ftell(f), &t) &&
                   memcmp(t.magic, program_end, sizeof t.magic) == 0;
    fclose(f);
    return program;
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
static inline V to_image(const VM *vm, V v)
{
    if (!is_ptr(v))
        return v;
    const Space *p = &vm->program->space;
    if (in_program(vm, ptr(v)))
        return ptr(v) < p->objects ? (v - (V)(uintptr_t)p->base) | IMAGE_IN_SYMBOLS
                                   : (v - (V)(uintptr_t)p->objects) | IMAGE_IN_OBJECTS;
    return v - (V)(uintptr_t)vm->space;
}

static inline V from_image(const VM *vm, V v)
{
    if (!is_ptr(v))
        return v;
    const Space *p = &vm->program->space;
    if (v & IMAGE_IN_SYMBOLS)
        return (v & ~IMAGE_IN_SYMBOLS) + (V)(uintptr_t)p->base;
    if (v & IMAGE_IN_OBJECTS)
        return (v & ~IMAGE_IN_OBJECTS) + (V)(uintptr_t)p->objects;
    return v + (V)(uintptr_t)vm->space;
}

void image_clear_raw(uint64_t *o)
{
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
static void restore_raw(VM *vm, uint64_t *o, bool in_prog)
{
    switch (hdr_type(o[0])) {
    case T_CLOSURE: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->compile_stub; break;
    case T_FOREIGN: o[PROC_ENTRY] = (uint64_t)(uintptr_t)vm->program->foreign_stub; break;
    case T_CODE:
        o[CODE_NATIVE] = 0;
        if (o[CODE_FRAME] > vm->program->max_frame)
            vm->program->max_frame = o[CODE_FRAME];
        /* Code objects take their constant slots again (heap.c), those of the program for good. */
        if (vm_track_code(vm, tagged(o, TAG_OBJECT)) && in_prog && o[CODE_NCONST] + o[CODE_NCODE])
            memset(vm->program->owned + o[CODE_CBASE], PROGRAM, o[CODE_NCONST] + o[CODE_NCODE]);
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

static void rebase_save_objects(const VM *vm, uint64_t *at, size_t words)
{
    uint64_t *s = at;
    while (s < at + words) {
        uint64_t w = *s;
        if (is_header(w)) {
            size_t first, count;
            obj_values(w, &first, &count);
            for (size_t i = 0; i < count; i++)
                s[first + i] = to_image(vm, s[first + i]);
            image_clear_raw(s);
            s += obj_words(w);
        } else {
            s[0] = to_image(vm, s[0]);
            s[1] = to_image(vm, s[1]);
            s += 2;
        }
    }
}

static void restore_objects(VM *vm, uint64_t *at, size_t words, bool in_prog)
{
    uint64_t *s = at;
    while (s < at + words) {
        uint64_t w = *s;
        if (is_header(w)) {
            size_t first, count;
            obj_values(w, &first, &count);
            for (size_t i = 0; i < count; i++)
                s[first + i] = from_image(vm, s[first + i]);
            restore_raw(vm, s, in_prog);
            s += obj_words(w);
        } else {
            s[0] = from_image(vm, s[0]);
            s[1] = from_image(vm, s[1]);
            s += 2;
        }
    }
}

/* Symbol slots: a free one holds 0 first. */
static void rebase_save_symbols(const VM *vm, uint64_t *at, size_t words)
{
    for (uint64_t *s = at; s < at + words; s += SYM_WORDS)
        if (s[0]) {
            s[SYM_NAME] = to_image(vm, s[SYM_NAME]);
            s[SYM_CELL] &= ~(UINT64_C(1) << MARK_BIT);
        }
}

/* The next range of slots to store, from at on. One that is not in use but is among those that are
   goes with them, where a range of its own would take as much. */
static SlotRange next_range(const V *slots, size_t count, size_t at)
{
    while (at < count && slots[at] == V_CLEARED)
        at++;
    size_t end = at;
    for (size_t i = at; i < count && i - end <= RANGE_WORDS; i++)
        if (slots[i] != V_CLEARED)
            end = i + 1;
    return (SlotRange){end > at ? at : 0, end - at};
}

static bool write_slots(FILE *f, const V *slots, size_t count, uint64_t *words)
{
    SlotRange range;
    size_t at = 0;
    do {
        range = next_range(slots, count, at);
        if (fwrite(&range, sizeof range, 1, f) != 1 ||
            fwrite(slots + range.start, sizeof *slots, range.count, f) != range.count)
            return false;
        at = range.start + range.count;
        *words += RANGE_WORDS + range.count;
    } while (range.count);
    return true;
}

static bool write_contents(const char *path, const char *mode, const ImageContents *c, bool program)
{
    ImageHeader h = {{'S', 'J', 'H', 'I'}, IMAGE_VERSION, {0}, sizeof(V), c->words[IMAGE_SYMBOLS],
                     c->words[IMAGE_PROGRAM], c->words[IMAGE_HEAP], c->words[IMAGE_CELLS],
                     c->words[IMAGE_CONSTS], c->words[IMAGE_GLOBALS], c->free_symbol,
                     primitive_count, primitive_checksum()};
    strncpy(h.build, SJ_BUILD_ID, sizeof h.build - 1);
    FILE *f = sj_fopen(path, mode);
    bool ok = f && fwrite(&h, sizeof h, 1, f) == 1;
    uint64_t words = 0;
    for (size_t part = 0; ok && part < IMAGE_PARTS; part++)
        if (part >= IMAGE_CELLS) {
            ok = write_slots(f, c->parts[part], c->words[part], &words);
        } else {
            ok = fwrite(c->parts[part], sizeof(V), c->words[part], f) == c->words[part];
            words += c->words[part];
        }
    ImageTrailer t = {sizeof h + words * sizeof(V) + sizeof t, {0}};
    memcpy(t.magic, program ? program_end : plain_end, sizeof t.magic);
    ok = ok && fwrite(&t, sizeof t, 1, f) == 1;
    if (f && fclose(f) != 0)
        ok = false;
    return ok;
}

bool image_append_contents(const char *path, const ImageContents *image, bool program)
{
    return write_contents(path, "ab", image, program);
}

/* The root array, or the globals without one, rebased. */
static void copy_slots(const VM *vm, RootArray *ra, V *out, size_t count)
{
    for (size_t i = 0; i < count; i++)
        out[i] = to_image(vm, ra ? *ra_at(ra, i) : vm->globals[i]);
}

static bool write_copy(VM *vm, const char *path, const char *mode, bool program);

/* An image holds what the cells, constants and symbol table reach. Drop
   the transient roots, which it does not save, so that a reloaded image
   dumps unchanged. Guards, the values of dead pointers, pointers' owners
   and roots held by C stay: what only they reach is written but cannot be
   reached in the image, so the next image leaves it out. */
bool image_collect(VM *vm)
{
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
    return true;
}

static bool write_image(VM *vm, const char *path, const char *mode, bool program)
{
    if (!image_collect(vm))
        return false;
    /* Isolates still running, as they may be when --save writes the builder's image, add symbols,
       cells and shared data to the program space under this lock: held while it is copied and
       written, the image is whole. */
    bool shared = vm->program->isolates != NULL;
    if (shared)
        program_shared_lock();
    bool ok = write_copy(vm, path, mode, program);
    if (shared)
        program_shared_unlock();
    return ok;
}

/* The program space and the collected heap, rebased, with the root arrays. */
static bool write_copy(VM *vm, const char *path, const char *mode, bool program)
{
    Space *p = &vm->program->space;
    ImageContents c = {.words = {[IMAGE_SYMBOLS] = (size_t)(p->symbols_next - p->base),
                                 [IMAGE_PROGRAM] = (size_t)(p->objects_next - p->objects),
                                 [IMAGE_HEAP] = (size_t)(vm->live_end - vm->space),
                                 [IMAGE_CELLS] = vm->program->cells.count,
                                 [IMAGE_CONSTS] = vm->program->consts.count,
                                 [IMAGE_GLOBALS] = vm->program->nglobals},
                       .free_symbol = p->free_symbol};
    size_t all = 0;
    for (size_t part = 0; part < IMAGE_PARTS; part++)
        all += c.words[part];
    V *copy = malloc((all ? all : 1) * sizeof *copy);
    if (!copy)
        return false;
    V *next = copy;
    for (size_t part = 0; part < IMAGE_PARTS; next += c.words[part++])
        c.parts[part] = next;
    memcpy(c.parts[IMAGE_SYMBOLS], p->base, c.words[IMAGE_SYMBOLS] * sizeof(V));
    memcpy(c.parts[IMAGE_PROGRAM], p->objects, c.words[IMAGE_PROGRAM] * sizeof(V));
    memcpy(c.parts[IMAGE_HEAP], vm->space, c.words[IMAGE_HEAP] * sizeof(V));
    rebase_save_symbols(vm, c.parts[IMAGE_SYMBOLS], c.words[IMAGE_SYMBOLS]);
    rebase_save_objects(vm, c.parts[IMAGE_PROGRAM], c.words[IMAGE_PROGRAM]);
    rebase_save_objects(vm, c.parts[IMAGE_HEAP], c.words[IMAGE_HEAP]);
    copy_slots(vm, &vm->program->cells, c.parts[IMAGE_CELLS], c.words[IMAGE_CELLS]);
    copy_slots(vm, &vm->program->consts, c.parts[IMAGE_CONSTS], c.words[IMAGE_CONSTS]);
    copy_slots(vm, NULL, c.parts[IMAGE_GLOBALS], c.words[IMAGE_GLOBALS]);
    bool ok = write_contents(path, mode, &c, program);
    free(copy);
    return ok;
}

bool image_dump(VM *vm, const char *path)
{
    return write_image(vm, path, "wb", false);
}

bool image_append(VM *vm, const char *path, bool program)
{
    return write_image(vm, path, "ab", program);
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
    while (end >= 0 && read_trailer(f, end, &t))
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

static bool read_values(FILE *f, const VM *vm, V *values, size_t count)
{
    if (fread(values, sizeof *values, count, f) != count)
        return false;
    for (size_t i = 0; i < count; i++)
        values[i] = from_image(vm, values[i]);
    return true;
}

/* The ranges of the count slots of ra, or of the globals without one, which are cleared. A range may
   cross the array's chunks. left is how many words of the image remain. */
static bool read_slots(FILE *f, VM *vm, RootArray *ra, size_t count, uint64_t *left)
{
    for (uint64_t at = 0;;) {
        SlotRange range;
        if (*left < RANGE_WORDS || fread(&range, sizeof range, 1, f) != 1)
            return false;
        *left -= RANGE_WORDS;
        if (!range.count)
            return range.start == 0;
        if (range.start < at || range.start > count || range.count > count - range.start ||
            range.count > *left)
            return false;
        *left -= range.count;
        at = range.start;
        uint64_t end = at + range.count;
        while (at < end) {
            size_t n = (size_t)(end - at);
            if (ra && n > RA_CHUNK - (at & (RA_CHUNK - 1)))
                n = RA_CHUNK - (at & (RA_CHUNK - 1));
            if (!read_values(f, vm, ra ? ra_at(ra, at) : vm->globals + at, n))
                return false;
            at += n;
        }
    }
}

static bool read_root_array(FILE *f, VM *vm, RootArray *ra, size_t count, uint64_t *left)
{
    size_t nchunks = (count + RA_CHUNK - 1) / RA_CHUNK;
    size_t cap = 8;
    while (cap < nchunks)
        cap *= 2;
    V **chunks = count ? malloc(cap * sizeof *chunks) : NULL;
    if (count && !chunks)
        return false;
    ra->chunks = chunks;
    ra->chunks_cap = count ? cap : 0;
    for (size_t c = 0; c < nchunks; c++) {
        V *chunk = malloc(RA_CHUNK * sizeof *chunk);
        if (!chunk)
            return false;
        for (size_t i = 0; i < RA_CHUNK; i++)
            chunk[i] = V_CLEARED;
        ra->chunks[ra->nchunks++] = chunk;
    }
    ra->count = count;
    return read_slots(f, vm, ra, count, left);
}

static bool symbol_table_reserve(SymbolTable *t, size_t count)
{
    if (!count)
        return true;
    size_t cap = 1024;
    while (2 * count > cap)
        cap *= 2;
    V *slots = calloc(cap, sizeof *slots);
    if (!slots)
        return false;
    t->slots = slots;
    t->cap = cap;
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
    long end = fseek(f, 0, SEEK_END) == 0 ? ftell(f) : -1;
    if (!read_trailer(f, end, &t) || t.length < sizeof h + sizeof t ||
        fseek(f, end - (long)t.length, SEEK_SET) != 0 ||
        fread(&h, sizeof h, 1, f) != 1 || memcmp(h.magic, "SJHI", 4) != 0 ||
        h.version != IMAGE_VERSION || memcmp(h.build, build, sizeof build) != 0 ||
        h.word_size != sizeof(V) || h.primitive_count != primitive_count ||
        h.primitive_checksum != primitive_checksum())
        goto fail;
    uint64_t left = (t.length - sizeof h - sizeof t) / sizeof(V);
    if (h.symbol_words > left || h.program_words > left - h.symbol_words ||
        h.heap_words > left - h.symbol_words - h.program_words ||
        h.cell_entries > 2 * CELL_MASK || h.const_entries > UINT32_MAX ||
        h.global_entries < 1 || h.global_entries > CELL_MASK)
        goto fail;
    left -= h.symbol_words + h.program_words + h.heap_words;

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
        fread(vm->space, sizeof(uint64_t), h.heap_words, f) != h.heap_words ||
        !vm_globals_commit(vm, h.global_entries) ||
        !read_root_array(f, vm, &vm->program->cells, h.cell_entries, &left) ||
        !read_root_array(f, vm, &vm->program->consts, h.const_entries, &left) ||
        !read_slots(f, vm, NULL, h.global_entries, &left) || left)
        goto fail;
    p->free_symbol = h.free_symbol;
    vm->live_end = vm->space + h.heap_words;
    vm_fresh_area(vm);
    vm->program->nglobals = h.global_entries;
    /* Rebase symbols, then rebuild the symbol tables at their final sizes. */
    size_t npub = 0, nown = 0;
    for (uint64_t *s = p->base; s < p->symbols_next; s += SYM_WORDS)
        if (s[0]) {
            s[SYM_NAME] = from_image(vm, s[SYM_NAME]);
            s[SYM_CELL] &= ~(UINT64_C(1) << MARK_BIT);
            if (symbol_published(tagged(s, TAG_SYMBOL)))
                npub++;
            else
                nown++;
        }
    if (!symbol_table_reserve(&vm->program->published, npub) ||
        !symbol_table_reserve(&vm->own, nown))
        goto fail;
    for (uint64_t *s = p->base; s < p->symbols_next; s += SYM_WORDS) {
        if (!s[0])
            continue;
        V sym = tagged(s, TAG_SYMBOL);
        bool pub = symbol_published(sym);
        if (!symbol_table_put(pub ? &vm->program->published : &vm->own, sym))
            goto fail;
        if (pub && symbol_cell(sym) >= vm->program->published_top)
            vm->program->published_top = symbol_cell(sym) + 1;
        if (pub && symbol_global(sym) >= vm->program->published_global_top)
            vm->program->published_global_top = symbol_global(sym) + 1;
    }
    /* The heap first: a promoted copy shares its original's constant slots (program.c), and those
       of the program are its for good. */
    restore_objects(vm, vm->space, h.heap_words, false);
    restore_objects(vm, p->objects, h.program_words, true);
    vm_find_free_consts(vm);
    fclose(f);
    return vm;

fail:
    fclose(f);
    vm_destroy(vm);
    return NULL;
}

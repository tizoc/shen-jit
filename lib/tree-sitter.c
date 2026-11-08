/* Complete-input Tree-sitter snapshots. No parser, tree, node or query escapes this call. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0600
#endif
#include "shen.h"
#include <tree_sitter/api.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#define EXPORT __declspec(dllexport)
#else
#include <time.h>
#define EXPORT __attribute__((visibility("default")))
#endif

#if TREE_SITTER_LANGUAGE_VERSION < 15
#error "The adapter needs Tree-sitter 0.25 or later"
#endif

enum { NODE_WORDS = 12, CAPTURE_WORDS = 4 };
enum { NATIVE = 1, TIMEOUT, LIMIT, QUERY, PREDICATE, LANGUAGE };
typedef struct {
    int domain;
    uint32_t code, offset;
    const char *message;
} Error;
typedef struct {
    const void *key;
    uint32_t value;
} Entry;
typedef struct {
    char **text;
    uint32_t count;
} Names;
typedef struct {
    const TSLanguage *language;
    TSParser *parser;
    TSTree *tree;
    TSQuery *query;
    TSQueryCursor *cursor;
    char *source, *query_text;
    uint32_t length, query_length, nodes, captures, capture_capacity, matches;
    uint32_t *records, *capture_records;
    Entry *index;
    size_t index_size;
    Names kinds, fields, capture_names;
    uint32_t node_limit, capture_limit, match_limit;
    size_t remaining;
    uint64_t end;
    Error error;
} Work;

static bool fail(Work *w, int domain, uint32_t code, uint32_t offset, const char *message)
{
    if (!w->error.domain)
        w->error = (Error){domain, code, offset, message};
    return false;
}

static uint64_t now_ms(void)
{
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t))
        return UINT64_MAX;
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
#endif
}

static bool expired(Work *w)
{
    if (now_ms() < w->end)
        return false;
    fail(w, TIMEOUT, 0, 0, "Tree-sitter operation timed out");
    return true;
}

static bool charge(Work *w, size_t n)
{
    if (n > w->remaining)
        return fail(w, LIMIT, 0, 0, "snapshot exceeds result byte limit");
    w->remaining -= n;
    return true;
}

static bool integer(shen_value v, uint32_t max, uint32_t *out)
{
    if (!shen_is_fixnum(v) || shen_fixnum(v) < 0 || (uint64_t)shen_fixnum(v) > max)
        return false;
    *out = (uint32_t)shen_fixnum(v);
    return true;
}

static bool copy_input(shen_vm *vm, shen_value input, Work *w)
{
    if (shen_vector_length(vm, input) != 5)
        return fail(w, NATIVE, 0, 0, "invalid input descriptor");
    uint32_t start;
    size_t length = 0;
    unsigned char *data = shen_bytes_data(vm, shen_vector_ref(vm, input, 0), &length);
    if (!data || !integer(shen_vector_ref(vm, input, 1), UINT32_MAX, &start) ||
        !integer(shen_vector_ref(vm, input, 2), 268435456, &w->length) || start > length ||
        w->length > length - start)
        return fail(w, NATIVE, 0, 0, "invalid source byte range");
    shen_value config = shen_vector_ref(vm, input, 4);
    uint32_t limits[7];
    const uint32_t maxima[] = {268435456, 4194304,    1048576, 1048576,
                               536870912, 2147483647, 16777216};
    if (shen_vector_length(vm, config) != 7)
        return fail(w, NATIVE, 0, 0, "invalid limits");
    for (int i = 0; i < 7; i++)
        if (!integer(shen_vector_ref(vm, config, i), maxima[i], &limits[i]))
            return fail(w, NATIVE, 0, 0, "invalid limit value");
    if (!limits[1] || !limits[3])
        return fail(w, NATIVE, 0, 0, "node and match limits must be positive");
    if (w->length > limits[0])
        return fail(w, LIMIT, 0, 0, "source exceeds input byte limit");
    w->node_limit = limits[1];
    w->capture_limit = limits[2];
    w->match_limit = limits[3];
    w->remaining = limits[4];
    uint64_t now = now_ms();
    if (now == UINT64_MAX)
        return fail(w, NATIVE, 0, 0, "cannot read monotonic clock");
    w->end = now + limits[5];
    if (expired(w) || !charge(w, w->length))
        return false;
    w->source = malloc((size_t)w->length + 1);
    if (!w->source)
        return fail(w, NATIVE, 0, 0, "cannot copy source");
    memcpy(w->source, data + start, w->length);
    w->source[w->length] = 0;
    shen_value query = shen_vector_ref(vm, input, 3);
    if (query != SHEN_NIL) {
        size_t n;
        const char *text = shen_string_bytes(vm, query, &n);
        if (!text)
            return fail(w, NATIVE, 0, 0, "query must be a string");
        if (n > limits[6])
            return fail(w, LIMIT, 0, 0, "query exceeds query byte limit");
        w->query_text = malloc(n + 1);
        if (!w->query_text)
            return fail(w, NATIVE, 0, 0, "cannot copy query");
        memcpy(w->query_text, text, n);
        w->query_text[n] = 0;
        w->query_length = (uint32_t)n;
    }
    return true;
}

static bool language_ok(Work *w)
{
    if (!w->language)
        return fail(w, LANGUAGE, 0, 0, "grammar entry returned no language");
    uint32_t version = ts_language_abi_version(w->language);
    if (version < TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION ||
        version > TREE_SITTER_LANGUAGE_VERSION)
        return fail(w, LANGUAGE, version, 0, "grammar ABI is incompatible with this runtime");
    return true;
}

static bool name(Work *w, Names *names, uint32_t i, const char *text, size_t n)
{
    if (!charge(w, n))
        return false;
    names->text[i] = malloc(n + 1);
    if (!names->text[i])
        return fail(w, NATIVE, 0, 0, "cannot copy name table");
    memcpy(names->text[i], text, n);
    names->text[i][n] = 0;
    return true;
}

static bool names_new(Work *w, Names *names, uint32_t count)
{
    if (count > 65537)
        return fail(w, NATIVE, 0, 0, "grammar name table is too large");
    names->text = calloc(count ? count : 1, sizeof *names->text);
    names->count = count;
    return names->text || fail(w, NATIVE, 0, 0, "cannot allocate name table");
}

static bool copy_names(Work *w)
{
    if (!names_new(w, &w->kinds, ts_language_symbol_count(w->language) + 1) ||
        !names_new(w, &w->fields, ts_language_field_count(w->language) + 1) ||
        !names_new(w, &w->capture_names, w->query ? ts_query_capture_count(w->query) : 0))
        return false;
    for (uint32_t i = 0; i < w->kinds.count; i++) {
        const char *s =
            i + 1 == w->kinds.count ? "ERROR" : ts_language_symbol_name(w->language, (TSSymbol)i);
        if (!name(w, &w->kinds, i, s ? s : "", s ? strlen(s) : 0))
            return false;
    }
    for (uint32_t i = 0; i < w->fields.count; i++) {
        const char *s = i ? ts_language_field_name_for_id(w->language, (TSFieldId)i) : "";
        if (!name(w, &w->fields, i, s ? s : "", s ? strlen(s) : 0))
            return false;
    }
    for (uint32_t i = 0; i < w->capture_names.count; i++) {
        uint32_t n;
        const char *s = ts_query_capture_name_for_id(w->query, i, &n);
        if (!name(w, &w->capture_names, i, s, n))
            return false;
    }
    return true;
}

static bool compile_query(Work *w)
{
    if (!w->query_text)
        return true;
    uint32_t offset;
    TSQueryError error;
    w->query = ts_query_new(w->language, w->query_text, w->query_length, &offset, &error);
    if (!w->query)
        return fail(w, QUERY, error, offset, "invalid structural query");
    for (uint32_t i = 0; i < ts_query_pattern_count(w->query); i++) {
        uint32_t n;
        ts_query_predicates_for_pattern(w->query, i, &n);
        if (n)
            return fail(w, PREDICATE, 0, ts_query_start_byte_for_pattern(w->query, i),
                        "query predicates and directives are unsupported; filter captures in Shen");
    }
    return !expired(w);
}

static const char *read_source(void *payload, uint32_t index, TSPoint point, uint32_t *read)
{
    (void)point;
    Work *w = payload;
    *read = index < w->length ? w->length - index : 0;
    if (*read > 65536)
        *read = 65536;
    return w->source + (index < w->length ? index : w->length);
}

static bool parse_progress(TSParseState *state)
{
    return expired(state->payload);
}
static bool query_progress(TSQueryCursorState *state)
{
    return expired(state->payload);
}

static size_t hash(const void *key)
{
    uintptr_t x = (uintptr_t)key;
    x ^= x >> 17;
    x *= (uintptr_t)0xed5ad4bb;
    return (size_t)(x ^ (x >> 11));
}

static uint32_t node_id(Work *w, TSNode node, uint32_t insert)
{
    size_t i = hash(node.id) & (w->index_size - 1);
    while (w->index[i].key && w->index[i].key != node.id)
        i = (i + 1) & (w->index_size - 1);
    if (insert)
        w->index[i] = (Entry){node.id, insert};
    return w->index[i].value;
}

static bool flatten(Work *w)
{
    TSNode root = ts_tree_root_node(w->tree);
    w->nodes = ts_node_descendant_count(root);
    if (!w->nodes || w->nodes > w->node_limit)
        return fail(w, LIMIT, 0, 0, "tree exceeds node limit");
    size_t bytes = (size_t)w->nodes * NODE_WORDS * 4;
    if (!charge(w, bytes))
        return false;
    w->records = calloc(1, bytes);
    if (w->query) {
        w->index_size = 2;
        while (w->index_size < (size_t)w->nodes * 2)
            w->index_size *= 2;
        w->index = calloc(w->index_size, sizeof *w->index);
    }
    if (!w->records || (w->query && !w->index))
        return fail(w, NATIVE, 0, 0, "cannot allocate node snapshot");
    TSTreeCursor cursor = ts_tree_cursor_new(root);
    uint32_t parent = 0, previous = 0;
    bool ok = true;
    for (uint32_t id = 1; id <= w->nodes; id++) {
        if (expired(w)) {
            ok = false;
            break;
        }
        TSNode node = ts_tree_cursor_current_node(&cursor);
        TSPoint start = ts_node_start_point(node), end = ts_node_end_point(node);
        uint32_t *r = w->records + (size_t)(id - 1) * NODE_WORDS;
        r[0] = parent;
        r[3] = ts_node_is_error(node) ? w->kinds.count - 1 : ts_node_symbol(node);
        r[4] = ts_tree_cursor_current_field_id(&cursor);
        r[5] = (ts_node_is_named(node) ? 1u : 0u) | (ts_node_is_missing(node) ? 2u : 0u) |
               (ts_node_is_error(node) ? 4u : 0u) | (ts_node_has_error(node) ? 8u : 0u) |
               (ts_node_is_extra(node) ? 16u : 0u);
        r[6] = ts_node_start_byte(node);
        r[7] = ts_node_end_byte(node);
        r[8] = start.row;
        r[9] = start.column;
        r[10] = end.row;
        r[11] = end.column;
        if (previous)
            w->records[(size_t)(previous - 1) * NODE_WORDS + 2] = id;
        else if (parent)
            w->records[(size_t)(parent - 1) * NODE_WORDS + 1] = id;
        if (w->query)
            node_id(w, node, id);
        if (id == w->nodes)
            break;
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            parent = id;
            previous = 0;
        } else {
            uint32_t up = id;
            while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
                if (!ts_tree_cursor_goto_parent(&cursor)) {
                    ok = fail(w, NATIVE, 0, 0, "inconsistent tree traversal");
                    break;
                }
                up = parent;
                parent = w->records[(size_t)(up - 1) * NODE_WORDS];
            }
            if (!ok)
                break;
            previous = up;
        }
    }
    ts_tree_cursor_delete(&cursor);
    return ok;
}

static bool capture_space(Work *w, uint32_t count)
{
    if (count > w->capture_limit - w->captures)
        return fail(w, LIMIT, 0, 0, "query exceeds capture limit");
    if (!charge(w, (size_t)count * CAPTURE_WORDS * 4))
        return false;
    uint32_t need = w->captures + count;
    if (need <= w->capture_capacity)
        return true;
    uint32_t capacity = w->capture_capacity ? w->capture_capacity : 64;
    while (capacity < need)
        capacity *= 2;
    if (capacity > w->capture_limit)
        capacity = w->capture_limit;
    uint32_t *records = realloc(w->capture_records, (size_t)capacity * CAPTURE_WORDS * 4);
    if (!records)
        return fail(w, NATIVE, 0, 0, "cannot allocate capture snapshot");
    w->capture_records = records;
    w->capture_capacity = capacity;
    return true;
}

static bool run_query(Work *w)
{
    if (!w->query)
        return true;
    w->cursor = ts_query_cursor_new();
    if (!w->cursor)
        return fail(w, NATIVE, 0, 0, "cannot allocate query cursor");
    ts_query_cursor_set_match_limit(w->cursor, 65536);
    TSQueryCursorOptions options = {.payload = w, .progress_callback = query_progress};
    ts_query_cursor_exec_with_options(w->cursor, w->query, ts_tree_root_node(w->tree), &options);
    TSQueryMatch match;
    while (ts_query_cursor_next_match(w->cursor, &match)) {
        if (expired(w))
            return false;
        if (w->matches == w->match_limit)
            return fail(w, LIMIT, 0, 0, "query exceeds match limit");
        w->matches++;
        if (!capture_space(w, match.capture_count))
            return false;
        for (uint16_t i = 0; i < match.capture_count; i++) {
            TSQueryCapture capture = match.captures[i];
            uint32_t id = node_id(w, capture.node, 0);
            if (!id)
                return fail(w, NATIVE, 0, 0, "query capture has no snapshot node");
            uint32_t *r = w->capture_records + (size_t)w->captures++ * CAPTURE_WORDS;
            r[0] = w->matches;
            r[1] = match.pattern_index;
            r[2] = capture.index;
            r[3] = id;
        }
    }
    if (ts_query_cursor_did_exceed_match_limit(w->cursor))
        return fail(w, LIMIT, 0, 0, "query exceeded its active match-state limit");
    return !expired(w);
}

static void run(Work *w)
{
    if (!language_ok(w) || expired(w) || !compile_query(w) || !copy_names(w))
        return;
    w->parser = ts_parser_new();
    if (!w->parser || !ts_parser_set_language(w->parser, w->language)) {
        fail(w, NATIVE, 0, 0, "cannot configure parser");
        return;
    }
    TSInput input = {.payload = w, .read = read_source, .encoding = TSInputEncodingUTF8};
    TSParseOptions options = {.payload = w, .progress_callback = parse_progress};
    w->tree = ts_parser_parse_with_options(w->parser, NULL, input, options);
    if (!w->tree) {
        if (!expired(w))
            fail(w, NATIVE, 0, 0, "parser returned no tree");
        return;
    }
    if (flatten(w))
        run_query(w);
}

static void close_native(Work *w)
{
    if (w->cursor)
        ts_query_cursor_delete(w->cursor);
    if (w->query)
        ts_query_delete(w->query);
    if (w->tree)
        ts_tree_delete(w->tree);
    if (w->parser)
        ts_parser_delete(w->parser);
    w->cursor = NULL;
    w->query = NULL;
    w->tree = NULL;
    w->parser = NULL;
}

static void free_names(Names *names)
{
    if (names->text)
        for (uint32_t i = 0; i < names->count; i++)
            free(names->text[i]);
    free(names->text);
}

static void cleanup(Work *w)
{
    close_native(w);
    free(w->source);
    free(w->query_text);
    free(w->records);
    free(w->capture_records);
    free(w->index);
    free_names(&w->kinds);
    free_names(&w->fields);
    free_names(&w->capture_names);
}

/* The records have one explicit byte order on every platform. */
static shen_value words(shen_vm *vm, uint32_t *values, size_t n)
{
    unsigned char *bytes = (unsigned char *)values;
    for (size_t i = 0; i < n; i++) {
        uint32_t v = values[i];
        for (int j = 0; j < 4; j++)
            bytes[i * 4 + j] = (unsigned char)(v >> (j * 8));
    }
    return shen_make_bytes(vm, values, n * 4);
}

static shen_value export_names(shen_vm *vm, Names *names)
{
    shen_value out = shen_make_vector(vm, names->count, SHEN_NIL);
    if (out == SHEN_ERROR)
        return out;
    shen_root(vm, &out);
    for (uint32_t i = 0; i < names->count; i++) {
        shen_value text = shen_make_string(vm, names->text[i], strlen(names->text[i]));
        if (text == SHEN_ERROR) {
            shen_unroot(vm, 1);
            return text;
        }
        shen_vector_set(vm, out, i, text);
    }
    shen_unroot(vm, 1);
    return out;
}

static shen_value export_error(shen_vm *vm, Error error)
{
    shen_value out = shen_make_vector(vm, 4, SHEN_NIL);
    if (out == SHEN_ERROR)
        return out;
    shen_root(vm, &out);
    shen_vector_set(vm, out, 0, shen_make_fixnum(error.domain));
    shen_vector_set(vm, out, 1, shen_make_fixnum(error.code));
    shen_vector_set(vm, out, 2, shen_make_fixnum(error.offset));
    shen_value message = shen_make_string(vm, error.message, strlen(error.message));
    if (message != SHEN_ERROR)
        shen_vector_set(vm, out, 3, message);
    shen_unroot(vm, 1);
    return message == SHEN_ERROR ? message : out;
}

static shen_value export_snapshot(shen_vm *vm, Work *w)
{
    shen_value out = shen_make_vector(vm, 8, SHEN_NIL);
    if (out == SHEN_ERROR)
        return out;
    shen_root(vm, &out);
    for (int i = 0; i < 6; i++) {
        shen_value value;
        switch (i) {
        case 0:
            value = shen_make_bytes(vm, w->source, w->length);
            break;
        case 1:
            value = words(vm, w->records, (size_t)w->nodes * NODE_WORDS);
            break;
        case 2:
            value = export_names(vm, &w->kinds);
            break;
        case 3:
            value = export_names(vm, &w->fields);
            break;
        case 4:
            value = words(vm, w->capture_records, (size_t)w->captures * CAPTURE_WORDS);
            break;
        default:
            value = export_names(vm, &w->capture_names);
            break;
        }
        if (value == SHEN_ERROR) {
            shen_unroot(vm, 1);
            return value;
        }
        shen_vector_set(vm, out, i, value);
    }
    shen_vector_set(vm, out, 6, shen_make_fixnum(w->matches));
    shen_vector_set(vm, out, 7, shen_make_fixnum(ts_language_abi_version(w->language)));
    shen_unroot(vm, 1);
    return out;
}

EXPORT uint32_t shen_treesitter_abi(void)
{
    return 1;
}

EXPORT shen_value shen_treesitter_language(shen_vm *vm, shen_value *args)
{
    Work w = {.language = shen_pointer(vm, args[0], NULL)};
    if (!language_ok(&w))
        return export_error(vm, w.error);
    return shen_make_fixnum(ts_language_abi_version(w.language));
}

EXPORT shen_value shen_treesitter_parse(shen_vm *vm, shen_value *args)
{
    Work w = {.language = shen_pointer(vm, args[0], NULL)};
    if (copy_input(vm, args[1], &w)) {
        void *ticket = shen_release(vm);
        run(&w);
        close_native(&w);
        shen_acquire(vm, ticket);
    }
    shen_value out = w.error.domain ? export_error(vm, w.error) : export_snapshot(vm, &w);
    cleanup(&w);
    return out;
}

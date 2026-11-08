/* Independent public Tree-sitter client: no Shen header or adapter code. */
#include <tree_sitter/api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const TSLanguage *tree_sitter_c(void);
static TSNode *nodes;
static uint32_t count, capacity;

static uint32_t walk(TSNode node, uint32_t parent, const char *field)
{
    if (count == capacity) {
        capacity = capacity ? capacity * 2 : 128;
        nodes = realloc(nodes, (size_t)capacity * sizeof *nodes);
        if (!nodes)
            exit(2);
    }
    uint32_t id = ++count;
    nodes[id - 1] = node;
    TSPoint a = ts_node_start_point(node), b = ts_node_end_point(node);
    unsigned flags = ts_node_is_named(node) + 2 * ts_node_is_missing(node) +
                     4 * ts_node_is_error(node) + 8 * ts_node_has_error(node) +
                     16 * ts_node_is_extra(node);
    printf("N\t%u\t%u\t%s\t%s\t%u\t%u\t%u\t%u\t%u\t%u\t%u\n", id, parent, ts_node_type(node),
           field ? field : "", flags, ts_node_start_byte(node), ts_node_end_byte(node), a.row,
           a.column, b.row, b.column);
    for (uint32_t i = 0; i < ts_node_child_count(node); i++)
        walk(ts_node_child(node, i), id, ts_node_field_name_for_child(node, i));
    return id;
}

static char *read_file(const char *path, uint32_t *n)
{
    FILE *f = fopen(path, "rb");
    if (!f || fseek(f, 0, SEEK_END))
        exit(2);
    long length = ftell(f);
    if (length < 0 || length > 16777216 || fseek(f, 0, SEEK_SET))
        exit(2);
    char *out = malloc((size_t)length + 1);
    if (!out || fread(out, 1, (size_t)length, f) != (size_t)length)
        exit(2);
    fclose(f);
    *n = (uint32_t)length;
    return out;
}

int main(int argc, char **argv)
{
    if (argc != 3)
        return 2;
    uint32_t length, query_length;
    char *source = read_file(argv[1], &length), *text = read_file(argv[2], &query_length);
    TSParser *parser = ts_parser_new();
    if (!ts_parser_set_language(parser, tree_sitter_c()))
        return 2;
    TSTree *tree = ts_parser_parse_string(parser, NULL, source, length);
    walk(ts_tree_root_node(tree), 0, "");
    uint32_t offset;
    TSQueryError error;
    TSQuery *query = ts_query_new(tree_sitter_c(), text, query_length, &offset, &error);
    if (!query)
        return 2;
    TSQueryCursor *cursor = ts_query_cursor_new();
    ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree));
    TSQueryMatch match;
    uint32_t serial = 0;
    while (ts_query_cursor_next_match(cursor, &match)) {
        serial++;
        for (uint16_t i = 0; i < match.capture_count; i++) {
            TSQueryCapture capture = match.captures[i];
            uint32_t id = 0, name_length;
            for (uint32_t j = 0; j < count; j++)
                if (ts_node_eq(nodes[j], capture.node)) {
                    id = j + 1;
                    break;
                }
            if (!id)
                return 2;
            const char *name = ts_query_capture_name_for_id(query, capture.index, &name_length);
            printf("C\t%u\t%u\t%.*s\t%u\n", serial, match.pattern_index, (int)name_length, name,
                   id);
        }
    }
    ts_query_cursor_delete(cursor);
    ts_query_delete(query);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
    free(nodes);
    free(source);
    free(text);
    return 0;
}

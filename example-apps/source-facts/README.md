# C source facts

Walk a directory, parse `.c`/`.h` files with Tree-sitter, and write NDJSON file, function-definition
and direct-call facts. This combines [Tree-sitter](../../docs/tree-sitter.md), [filesystem traversal
and replacement](../../docs/fs.md), [our I/O](../../docs/io.md) and [JSON](../../docs/json.md).

From a source checkout/tarball root, with a shared-capable Shen/JIT and a C compiler:

```sh
make deps-tree-sitter fs
TREE_SITTER_SOURCE=.deps/tree-sitter make tree-sitter
cc -O2 -shared -fPIC -I.deps/tree-sitter-c/src .deps/tree-sitter-c/src/parser.c -o build/tree-sitter-c.so
build/shen-jit script example-apps/source-facts/main.shen ./build/tree-sitter-c.so src/runtime facts.ndjson
```

On Windows, build/use `.dll` names. In a binary package use `sh lib/build-fs.sh lib/shen-fs.so` and
`sh lib/build-tree-sitter.sh lib/shen-tree-sitter.so` with an installed runtime or `TREE_SITTER_SOURCE`;
the generated C grammar is a separate dependency. Its entry name is `tree_sitter_c`.
`sh tools/tree-sitter-deps.sh .deps` fetches the pinned runtime/grammar in a binary installation too.

Each source file produces a `file` record with `byte_count` and `syntax_error`. Captured definitions
and calls add `name`, enclosing function `container`, half-open `start_byte`/`end_byte`, and zero-based
byte `row`/`column`. `path` is absolute. Pointer-returning function declarators are followed to their
identifier. Syntax errors remain visible; a malformed file can still yield useful facts.

The extractor processes one file at a time, with an 8 MiB file cap and the binding's node/capture/
deadline limits. Walking visits at most 10000 entries, depth 64 and 16 MiB of names. It skips links,
`.git`, `.deps` and `build` directories. Output has a 4 KiB writer, 64 KiB per record, 100000 records
and 64 MiB total. Source/name text must be valid UTF-8 for JSON encoding. Failure preserves an existing
destination and removes the temporary output; replacement is not a crash-durability guarantee.

Facts describe syntax, without evaluating the preprocessor or resolving symbols. Function-pointer
calls, field calls and declarations without bodies are outside this example's query. Use the binding's
query/traversal API to extend the fact schema. [Source facts in Datalog](../../example-apps/source-deps/README.md)
consumes this export, reports matched/unresolved/ambiguous calls and answers reachability/impact
queries while keeping file/name/definition identity explicit.

`make test-tree-sitter` exercises this application with independent JSON/byte-range checks, failed
input preserving the destination, Unicode paths, malformed source and repeated files under a heap cap.

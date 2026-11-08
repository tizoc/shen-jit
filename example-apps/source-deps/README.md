# Source facts in Datalog

Read the NDJSON produced by [the C source-fact extractor](../../example-apps/source-facts/README.md), match calls
with definitions, and ask which functions a function reaches or which functions depend on it.
The rules use [Datalog](../../docs/datalog.md); input, output and replacement use
[our I/O](../../docs/io.md) and [filesystem library](../../docs/fs.md), independently of kernel streams.

From the repository/source-tarball root, after building the extractor's dependencies:

```sh
make fs
build/shen-jit script example-apps/source-facts/main.shen ./build/tree-sitter-c.so src/runtime facts.ndjson
build/shen-jit script example-apps/source-deps/main.shen facts.ndjson report.ndjson
```

The analyser needs the filesystem adapter, but needs neither Tree-sitter nor a grammar at analysis
time. From a binary installation use `./shen-jit` and build the adapter with
`sh lib/build-fs.sh lib/shen-fs.so` (`.dll` on Windows). Input facts can come from another machine.

Build one standalone executable, without loading Shen source files on each invocation:

```sh
build/shen-jit eval -q -l example-apps/source-deps/load.shen \
  -e '(shen-jit.save-executable "source-deps" source-deps.entry)'
./source-deps facts.ndjson report.ndjson
```

The saved executable still needs the filesystem adapter at its configured paths. Set absolute
`fs.*adapter-files*` entries before loading if it must launch from other directories.

## Questions and matching

```text
source-deps FACTS OUTPUT
source-deps FACTS OUTPUT --reach FILE NAME
source-deps FACTS OUTPUT --impact FILE NAME
```

`FILE` is the exact `path` string in the facts: the analyser does not reopen source files or
canonicalize those labels. The extractor normally emits absolute paths. `NAME` is the function name.
A selector must identify exactly one usable definition; otherwise the command fails and preserves
the old output. Reports keep `(file, name, definition byte)` as function identity, so equal names
in different files or at different definition offsets remain separate.

Matching is a **syntactic policy**, recorded in each report:

1. A call's enclosing name must identify exactly one definition in its file. Missing, unscoped or
   ambiguous owners become `unowned_call` records.
2. Prefer a unique target definition in the caller's file. Multiple definitions there are ambiguous.
3. With no same-file target, use a unique definition with that name across the usable input.
   Multiple candidates are `ambiguous_call`; no candidate is `unresolved_call`.

Files marked `syntax_error: true` are excluded as a whole and listed as `excluded_file`. Their
definitions do not become candidates. This avoids treating a partial parse as complete input.
An unresolved name might be external, excluded, indirect or missing from the export; it is not
automatically classified as an external C symbol.

The policy does not implement C linkage, preprocessing, local variable shadowing, indirect calls
or nested-function scope. In particular, "global" in a diagnostic means the whole fact input,
not C external linkage. Inspect ambiguous/unresolved/excluded records when interpreting a result.

`--reach` follows outgoing matched calls; `--impact` follows them backwards to callers. Both mean
one or more edges: the selected function appears in its own answers only if a cycle reaches it.
Only one selected root/direction is evaluated. A default report never computes an all-pairs
transitive closure.

## Reports and input validation

Output is NDJSON, with a `summary`, then deterministically sorted `excluded_file`, `function`,
`edge`, `file_edge`, `resolved_call`, `unresolved_call`, `ambiguous_call` and `unowned_call` records.
A query adds a `query` record and sorted `reach` or `impact` answers. Edges are sets: repeated calls
at different sites produce separate call records but one graph edge. Function objects have `file`,
`name` and `definition_byte`; site objects retain byte ranges and zero-based byte row/column positions.

The reader validates the extractor's exact record fields, integer ranges, text, source ranges,
definition/container agreement and per-file syntax flags. Each file record must precede its sites.
Duplicate file records and conflicting records at one site are rejected, preventing accidental
merging of two snapshots of a file. Identical repeated site records deduplicate. Blank lines,
CRLF and a final record without LF are accepted. A malformed JSON value, invalid UTF-8 or an I/O
failure aborts the whole operation; partial input is never published as a successful analysis.

The default input limits match the extractor: 64 MiB, 100000 records, 10000 files and 64 KiB per
line before LF. Fields used by Datalog must fit nonnegative signed 32-bit integers. A 16 KiB reader
and bounded line builder avoid retaining the encoded input file. Identical path/name strings are shared;
the retained facts and database grow with the graph. This is not a constant-memory graph engine.

Reports use a 4 KiB writer, at most 1 MiB per encoded record, 300000 records and 64 MiB total.
Input closes before analysis/output. Output is replaced only after encoding, writing and closing
succeed; failures leave an existing destination intact. Replacement does not promise crash durability.
Diagnostics return exit status 2. There is no solver timeout or incremental update protocol in this app.

## Implementation and checks

`model.shen` declares input relations, candidate counts, call classification and edges. `read.shen`
validates and streams records, `report.shen` encodes output, and `command.shen` supplies the CLI.
`load.shen` loads macros before those files are read. All application code is Shen; there are no
new runtime primitives or C adapters.

```sh
sh example-apps/source-deps/test.sh build/shen-jit
make test-datalog
make test-tree-sitter
```

The first two check the model against the naive evaluator, independent Python name matching/BFS,
chunk splits, limits, ambiguous names, cycles, failed replacement, Unicode paths, saved executables
and images/GC. Static builds run the managed reader/model checks and explicitly skip file operations.
The Tree-sitter suite also extracts real C files and checks the resulting Datalog graph and queries.

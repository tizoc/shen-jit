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
source-deps FACTS OUTPUT --reach FILE NAME [BYTE]
source-deps FACTS OUTPUT --impact FILE NAME [BYTE]
```

`FILE` is the exact `path` string in the facts: the analyser does not reopen source files or
canonicalize those labels. The extractor normally emits absolute paths. `NAME` is the function name.
A selector must identify exactly one usable definition; otherwise the command fails and preserves
the old output. Supply the optional decimal `BYTE` to select one of several definitions with the same
file/name. Reports keep `(file, name, definition byte)` as function identity, so equal names
in different files or at different definition offsets remain separate.

Matching is a **syntactic policy**, recorded in each report:

1. A version 2 call identifies its enclosing definition by file, name and `container_byte`, even when
   that name occurs twice. Unscoped calls become `unowned_call` records. A named caller referring to
   a missing or differently named definition is malformed input and aborts the analysis.
2. Prefer a unique target definition in the caller's file, with `internal` or `external` linkage.
   Multiple definitions there are ambiguous; a unique `unknown` target remains unresolved.
3. With no same-file target, consider only `external` definitions with that name across usable input.
   Multiple candidates are `ambiguous_call`; no candidate is `unresolved_call`. Private or unknown
   definitions never become cross-file candidates.

Old, unversioned exports are accepted as version 1. Their callers use a unique same-file enclosing
name; missing or ambiguous owners become `unowned_call`. Their definitions carry `legacy` linkage
and remain eligible for local and cross-file matching because visibility was not exported.
The summary counts `legacy_files` so this weaker policy stays visible. Different files may use
different schema versions.

Configured version 3 exports represent preprocessed translation units and carry file-scope function
declarations. Their matching policy is `caller-id-local-then-declared-external`: a cross-unit match
also requires an external declaration of that name preceding the call in the caller's preprocessed
input. A late, internal or missing declaration blocks the global guess. Same-unit candidates still
take precedence. These are name/declaration checks, without C type compatibility or block scope.
See [configured extraction](../../example-apps/source-facts/README.md#configured-translation-units)
for database requirements and toolchain limits.

The reader rejects mixed raw/configured exports and different configuration labels in one input.
Version 3 paths identify translation units; coordinates include expanded headers and refer to
preprocessed text. `context` records expose each unit's configuration and coordinate system.
Included header definitions remain separate in each unit; raw scans retain physical-file identities.

Files marked `syntax_error: true` are excluded as a whole and listed as `excluded_file`. Their
definitions do not become candidates. This avoids treating a partial parse as complete input.
An unresolved name might be external, excluded, indirect or missing from the export; it is not
automatically classified as an external C symbol.

The exporter supplies conservative linkage hints, including inherited static prototypes. The policy
does not implement full C linkage, preprocessing, local variable shadowing, indirect calls or
nested-function scope. In particular, "global" in a diagnostic means eligible names across the fact
input. Inspect linkage and ambiguous/unresolved/excluded records when interpreting a result.

`--reach` follows outgoing matched calls; `--impact` follows them backwards to callers. Both mean
one or more edges: the selected function appears in its own answers only if a cycle reaches it.
Each ordinary query evaluates one selected root/direction. A default report never computes an all-pairs
transitive closure.

## Batch queries

Match calls once with the existing Datalog rules, export the matched graph to
forward/reverse integer adjacency indexes, then run independent queries:

```sh
./source-deps facts.ndjson report.ndjson --batch queries.ndjson
./source-deps facts.ndjson report.ndjson --batch queries.ndjson \
  --workers 4 --worker-image ./source-deps
```

The saved executable built above contains the named worker entry too. Its
main function is not invoked in children. For `script` use, build a compatible
worker image explicitly with that command and supply its path. No image is
needed for sequential batch execution, the default (`--workers 0`). Native
worker counts are integers from 1 to 64. Parallel execution is explicit; no automatic
threshold or general parallel Datalog evaluator is provided.
The CLI opens one scope per invocation; the library can reuse one for several batches.

The query file is NDJSON, in the desired answer order:

```json
{"mode":"reach","file":"a.c","name":"main"}
{"mode":"impact","file":"b.c","name":"helper","definition_byte":123}
```

Selectors use the same validation and full function identity as ordinary
queries. All selectors must resolve before output replacement starts. A batch
report contains the ordinary graph records, then a `query` record and sorted
answers per selector; query and answer records add zero-based `query_index`.
Repeated queries are preserved. Empty query lists and empty worker shards are
valid. Reach/impact still mean one or more edges, including the root only when
a cycle reaches it.

The parent owns matching, names and result assembly. Children borrow one
immutable graph snapshot, run the same BFS as the sequential batch path with
private visited sets/queues, and return copied answer IDs. All threads join
before the graph snapshot is freed. Replies are converted back to full
function identities and retained until reporting. See [the structured worker reference](../../docs/parallel.md)
for cancellation, type checking and native-code limits.

Query input is at most 1 MiB and 4096 selectors, with at most 64 KiB per
nonblank line. The graph snapshot and aggregate reply bytes are each at most
64 MiB. Each child gets an equal share of the reply limit; a large shard can
fail even if another child has unused capacity. Report limits still apply.
The worker heap caps divide 384 MiB minus the snapshot size between children,
with a minimum of 64 MiB per child for the saved application image and private
query state. At 64 workers the configured child heap caps sum to 4 GiB, plus
the parent and snapshot. These are heap caps, not RSS limits; code, stacks and
copying spaces also consume memory. Choose a worker count that fits the
machine. Normal CLI invocation keeps the runtime's configured parent heap
limit, and an image larger than a child's cap is refused during initialization.

`batch-graph.shen` holds the common BFS and byte protocol; `batch.shen` holds
export, validation, sharding and reports. These are an algorithm/representation
change from the recursive Datalog walk. Compare **sequential CSR with threaded
CSR** to isolate threading; compare the original Datalog path separately.

Batches pay off only when they are large and a scope serves several of them: for 4096 selectors over the
Shen/JIT runtime's own sources, 4 workers answered in 1.9 ms warm against 4.2 ms sequentially, but a whole scope
cost 7.2 ms per batch against 8.3, and writing the report outweighs both. Small batches are faster sequentially.

### Optional ordinary-value batches

`batch-values.shen` adds a library-only alternative over `parallel.map`. Load
`lib/parallel-map.shen` and that file after `source-deps/load.shen`, under
`(tc -)`. The compatible worker image must contain them too:

```sh
build/shen-jit eval -q -l example-apps/source-deps/load.shen \
  -l lib/parallel-map.shen -l example-apps/source-deps/batch-values.shen \
  -e '(shen-jit.save-executable "source-deps-value-workers" [])'
```

Given an existing graph `Export` from `source-deps.export` and the resolved
`[direction root-ID]` query list from `source-deps.resolve-queries`, use:

```shen
(source-deps.with-value-workers Export "source-deps-value-workers" 4
  (/. Scope (source-deps.values-batch Export Scope Selected)))
```

Worker counts are integers from 1 to 64. The callback can run several batches.
`source-deps.batch-execute-values
Export Selected Workers Image` opens one scope for one batch. Both return the
same ordered `[reach-or-impact root-function answer-functions]` lists as
`source-deps.batch-execute`. Children read the same immutable graph and run the
same BFS, returning ordinary `[direction root-ID sorted-answer-IDs]` values.
The host validates those IDs and restores complete function identities.
Value-codec node/depth and per-shard byte bounds apply in addition to the
application limits. Arguments/results are copied; globals and scratch space
remain private. The normal CLI continues to use its existing byte protocol.

For the same graph queries this adapter costs more than packed bytes, as encoding the answers outweighs the
work saved; it suits coarser jobs.

## Reports and input validation

Output is NDJSON, with a `summary`, then deterministically sorted `excluded_file`, `function`,
`edge`, `file_edge`, `resolved_call`, `unresolved_call`, `ambiguous_call` and `unowned_call` records.
A query adds a `query` record and sorted `reach` or `impact` answers. Edges are sets: repeated calls
at different sites produce separate call records but one graph edge. Function objects have `file`,
`name` and `definition_byte`. Function records also expose `linkage` (`internal`, `external`, `unknown`
or `legacy`); site objects retain byte ranges and zero-based byte row/column positions. The summary's
`matching` value is `caller-id-local-then-visible-name` for raw input. `configured_units` and
`input_declarations` count build context. Unresolved calls include `reason`: `missing-target`,
`unknown-scope` or `missing-external-declaration`.

New exports also produce `parse` and `parse_diagnostic` records before graph records. They identify
the parser profile, normalization/ignored-capture counts and total parse errors, with at most eight
error/missing-token samples per file. Each sample has a site, node kind and bounded ASCII-escaped
excerpt in the export's coordinate system. Join these with `excluded_file` records to see why a unit
was excluded. The summary counts `parse_metadata_files` and distinct `diagnostic_samples`; older
exports without this optional metadata still work. Unowned calls distinguish `outside-function`
from `missing-or-ambiguous-owner` rather than presenting header expressions as graph edges.

The reader validates the extractor's exact record fields, integer ranges, text, source ranges,
definition/container agreement, versioned linkage/caller fields and per-file syntax flags. Each file
record must precede its sites. Named version 2/3 caller references are validated against all raw
definitions, including syntax-error files, before output begins. Unsupported schema versions fail.
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
chunk splits, limits, ambiguous names, private/unknown linkage, exact caller identities, cycles,
mixed/legacy exports, failed replacement, Unicode paths, saved executables and images/GC. Static builds
run the managed reader/model checks and explicitly skip file operations. The Tree-sitter suite also
checks real C linkage hints, inherited static prototypes, declarators, compiler configurations,
preprocessed coordinates, declaration guards and graph queries.

# Tree-sitter bindings

`lib/tree-sitter.shen` parses source code using existing Tree-sitter grammars. It returns owned,
immutable snapshots with tree traversal, byte/point ranges, syntax-error information and structural
query captures. Native parsers, trees, cursors and queries are closed before returning to Shen.

This complements [grammars written in Shen](grammar.md): Tree-sitter supplies existing source-language
grammars, while the Shen library handles application formats and binary protocols.

## Build and load

Install Tree-sitter's development package, version 0.25 or later, then build the optional adapter:

```sh
make tree-sitter
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/tree-sitter.shen -l program.shen
```

`pkg-config` finds an installed runtime. Alternatively, set `TREE_SITTER_CFLAGS` and `TREE_SITTER_LIBS`,
or `TREE_SITTER_SOURCE` to an unpacked runtime source root. A source build embeds that runtime in the
optional adapter; Shen/JIT itself has no Tree-sitter dependency. `CC` and `CFLAGS` are supported.

From a source checkout/tarball, fetch pinned test/example dependencies, including the generated C grammar:

```sh
make deps-tree-sitter
TREE_SITTER_SOURCE=.deps/tree-sitter make tree-sitter
cc -O2 -shared -fPIC -I.deps/tree-sitter-c/src .deps/tree-sitter-c/src/parser.c -o build/tree-sitter-c.so
make test-tree-sitter
```

The fetch script verifies SHA-256 and retains upstream licenses with the sources in `.deps/`.
It pins runtime 0.26.13 and C grammar 0.24.2. Ordinary builds never fetch or build them. Static Linux
tests run pure validation and skip native work before dependency checks, compilers or Python start.

Binary archives include the adapter source and build script. From the installation root:

```sh
sh lib/build-tree-sitter.sh lib/shen-tree-sitter.so
# MSYS2 UCRT64: sh lib/build-tree-sitter.sh lib/shen-tree-sitter.dll
```

`sh tools/tree-sitter-deps.sh .deps` fetches the same pinned dependencies in a binary installation;
set `TREE_SITTER_SOURCE=.deps/tree-sitter` when building against that runtime.

Use `.dll` for the grammar on Windows too. Grammars may require their own external scanner sources
or C++ compiler; follow that grammar's build instructions. Distribute the chosen runtime/grammars
and their licenses with applications. Grammars are native executable code.

Loading the facade never invokes a compiler. It searches `./build/`, `./lib/` and the current
directory for `shen-tree-sitter.so` and `.dll`. Set `treesitter.*adapter-files*` before loading to
use another location. The adapter ABI is 1. Fully static executables cannot load native bindings.

## Languages and parsing

`(treesitter.load-language Name Files Entry)` returns `[ok Language]` or `[error Error]`. Name is a
display string, Files is a nonempty list of shared-library paths to try, and Entry is the grammar's
zero-argument C entry name. Missing libraries/symbols, null languages and incompatible grammar ABIs
are structured errors. Load a language once and reuse it across files.

```shen
(define example.language
  Files -> (treesitter.load-language "C" Files "tree_sitter_c"))

(define example.parse
  Language ->
    (treesitter.parse Language (buffer.from-string "int main(void) { return 0; }")
      [[input-limit 1048576] [node-limit 100000] [timeout 2000]]))
```

`treesitter.language-name` and `treesitter.language-version` give the name and accepted grammar ABI.
The language retains a reloadable FFI entry, with the grammar library kept loaded by the FFI. It
does not retain a native pointer in a saved image. A restored image needs compatible libraries at
its configured paths; every operation resolves its entry again and checks ABI compatibility.

`(treesitter.parse Language Input Options)` returns `[ok Snapshot]` or `[error Error]`. Input is a
[byte view](buffers.md), including subviews and views over sized foreign memory. Parsing is UTF-8;
NUL and malformed text are length-counted input, and can produce syntax-error nodes. No text decoding
or newline normalization happens before parsing. Syntax errors return trees, not parse failures.

The adapter copies the selected source range to stable native storage before releasing the VM lock,
then returns a managed source snapshot. Changing or closing the original input afterwards cannot
change it. Foreign input must stay open while its initial copy is made. Parsing never borrows a
moving managed address while another Shen thread can collect.

## Snapshot traversal

Node IDs are one-based within a snapshot. Root is 1; absent parent/child/sibling is 0. IDs enumerate
all visible nodes in preorder, including punctuation, comments, missing tokens and `ERROR` nodes.
Keep each ID with its snapshot; a numeric ID alone cannot identify its owner.

| Function | Result |
| --- | --- |
| `treesitter.root Snapshot` | Root ID |
| `treesitter.node-count Snapshot` | Total node count |
| `treesitter.parent Snapshot ID` | Parent, or 0 |
| `treesitter.first-child Snapshot ID` | First child, or 0 |
| `treesitter.next-sibling Snapshot ID` | Next sibling, or 0 |
| `treesitter.children Snapshot ID` | Child IDs in source order |
| `treesitter.child-by-field Snapshot ID Name` | First child with that field, or 0 |
| `treesitter.kind Snapshot ID` | Grammar node kind, such as `"identifier"` |
| `treesitter.field Snapshot ID` | Field linking this node to its parent; `""` when absent |
| `treesitter.named?`, `missing?`, `error?`, `has-error?`, `extra?` | Flags, each taking Snapshot and ID |
| `treesitter.start-byte`, `end-byte` | Half-open byte range |
| `treesitter.start-point`, `end-point` | `[Row Column]`, both zero-based; columns count bytes |
| `treesitter.text Snapshot ID` | Copied source string for the range |
| `treesitter.source Snapshot` | Fresh byte-view copy of the complete source |
| `treesitter.fold F Initial Snapshot` | Apply `F Accumulator ID` once per node in preorder |

Accessors reject IDs outside the snapshot. The source getter copies so it cannot mutate the retained
source. Snapshots contain only managed bytes, strings and vectors; they survive images and GC, have
no native close operation, and can be shared for reading. Their internal representation is private.

Each node uses 48 record bytes plus shared kind/field tables and its share of source storage. Captures
use 16 bytes each plus names. Shen accessors read those records without a foreign call per node.
Creating a snapshot still copies the whole tree; this is a batch API, without incremental editing.

## Structural queries

`(treesitter.query Language Input Query Options)` parses once, runs the structural query, and returns
the same snapshot with captures attached. It does not reparse an already exported snapshot. Each
capture refers to a node in that snapshot, so text and parent traversal use the matching source.

```shen
(define example.definitions
  Language Input ->
    (treesitter.query Language Input "(function_definition) @definition"
      [[capture-limit 1000] [match-limit 1000] [timeout 2000]]))

(define example.first-capture
  Snapshot ->
    (let Node (treesitter.capture-node Snapshot 1)
      [(treesitter.capture-name Snapshot 1) (treesitter.kind Snapshot Node)
       (treesitter.start-point Snapshot Node)]))
```

| Function | Result |
| --- | --- |
| `treesitter.capture-count Snapshot` | Number of captures |
| `treesitter.match-count Snapshot` | Number of matches, including matches without captures |
| `treesitter.capture-node Snapshot CaptureID` | Node ID |
| `treesitter.capture-name Snapshot CaptureID` | Capture name without `@` |
| `treesitter.capture-match Snapshot CaptureID` | One-based match sequence |
| `treesitter.capture-pattern Snapshot CaptureID` | Zero-based query pattern index |

Capture IDs are one-based and returned in match order, preserving multiple captures per match and
repeated captures of a node. They are not a globally sorted stream of byte positions.

The [C query engine](https://tree-sitter.github.io/tree-sitter/using-parsers/queries/3-predicates-and-directives.html)
does not evaluate predicates/directives. This binding rejects every predicate/directive, including
`#eq?`, `#match?` and `#set!`, rather than silently ignoring them. Filter capture text in Shen. Queries
with no captures are permitted. Query syntax errors retain their upstream category and byte offset.

## Bounds and errors

Options are `[name number]` pairs. Unknown, repeated, negative, fractional or out-of-range values raise
before native work. Source/query quota failures, native failures and timeouts return structured errors;
no partial tree or truncated capture set is returned as success.

| Option | Default | Maximum |
| --- | --- | --- |
| `input-limit` | 8388608 | 268435456 source bytes |
| `node-limit` | 262144 | 4194304 nodes; minimum 1 |
| `capture-limit` | 65536 | 1048576 captures; zero permitted |
| `match-limit` | 65536 | 1048576 matches; minimum 1 |
| `result-limit` | 67108864 | 536870912 payload bytes |
| `timeout` | 30000 | 2147483647 monotonic milliseconds; zero expires immediately |
| `query-limit` | 1048576 | 16777216 query bytes |

The result budget counts retained source, node/capture records and UTF-8 name bytes. It excludes
managed object overhead and the upstream parser's temporary allocations. The node limit is checked
after parsing, before exporting records. A query also has a fixed 65536 active-match-state limit;
exceeding it fails rather than losing matches silently. These are result/input bounds, not a hard
limit on all native parser memory. Upstream Tree-sitter's default allocator aborts on allocation
failure; the binding does not replace its process-global allocator.

One native operation owns each parser/cursor. Parse/query progress callbacks check the monotonic
deadline while the VM is released; flattening checks it too. Query compilation and native destruction
have no upstream progress callback, so the deadline cannot preempt those calls. There is no separate
cross-thread cancellation API yet. The budget covers native analysis; Shen input normalization and
managed result conversion/collection are outside its timed phase.

Error accessors are `treesitter.error-operation`, `error-domain`, `error-code`, `error-offset`,
`error-resource` and `error-message`. Domains are `foreign`, `native`, `language`, `query`, `predicate`,
`limit` and `timeout`. Query error codes are upstream `TSQueryError` categories; offsets are bytes in
the query, starting at zero. A language error's code records its rejected ABI when available.

## Source facts application

[The source-fact extractor](../example-apps/source-facts/README.md) walks C headers/sources through
the filesystem library, reads one bounded file at a time through our own I/O, and emits NDJSON for
files, function definitions and direct calls. Output uses bounded buffering and safe filesystem
replacement. This is a starting fact source for Datalog or repository tooling; it does not resolve
C names, preprocessing, indirect calls or dependencies semantically.
[Source facts in Datalog](../example-apps/source-deps/README.md) consumes that export and adds
explicit call matching, diagnostics, reachability and reverse impact queries.

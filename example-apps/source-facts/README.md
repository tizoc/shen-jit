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

Each source file produces a `file` record with `schema_version: 2`, `byte_count` and `syntax_error`.
Captured definitions and calls add `name`, enclosing function `container`, half-open
`start_byte`/`end_byte`, and zero-based byte `row`/`column`. `path` is absolute. Pointer-returning and
parenthesized function declarators are followed to their identifier. Syntax errors remain visible;
a malformed file can still yield useful facts.

`container_byte` identifies the enclosing definition by its name's start byte. A definition refers
to itself; a call outside a function has `container: ""` and `container_byte: null`. Names alone
cannot distinguish two definitions captured from different preprocessor branches.

Definitions also carry a conservative `linkage` hint:

| Value | Meaning |
| --- | --- |
| `internal` | An explicit `static` definition, or a name appearing in a file-scope `static` declaration. |
| `external` | An ordinary file-scope definition without those static hints. |
| `unknown` | A nested function, whose scope this application does not resolve. |

A static prototype can give a later unqualified or `extern` definition internal linkage. The
extractor scans declarations before writing sites, including multiple declarators, and conservatively
honors static hints across all preprocessor branches and declaration order. This can suppress a valid
cross-file match in mutually exclusive configurations; it does not implement preprocessing or the
full C linkage rules.

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

## Configured translation units

Use a [JSON compilation database](https://clang.llvm.org/docs/JSONCompilationDatabase.html) to
select active preprocessor branches, expand macros and include header declarations:

```sh
make process
build/shen-jit script example-apps/source-facts/main.shen ./build/tree-sitter-c.so \
  --compile-commands build/compile_commands.json debug configured-facts.ndjson
build/shen-jit script example-apps/source-deps/main.shen configured-facts.ndjson configured-report.ndjson
```

`debug` is a caller-chosen configuration label, not a fingerprint. Supply one already selected
configuration: duplicate source labels are rejected. Command objects require `directory`, `file`
and an `arguments` array; shell `command` strings are not interpreted. Relative directories resolve
against the database's parent, and source operands against the command's working directory. Paths
are lexical labels; symlink aliases and different spellings of a path are not canonicalized.

The application executes the compiler from each argument vector through [our subprocess library](../../docs/processes.md),
without a shell. It preserves preprocessing and target flags, their order, the working directory
and the source operand's spelling (including its effect on `__FILE__`). The compiler inherits the
application's environment; the label and recorded argv do not capture that environment or toolchain
versions. It removes compile actions,
object/dependency output options and dependency generation, then requests GCC/Clang `-E -P -x c`
output on stdout. Compiler launch, nonzero exit, output limits or timeouts abort and preserve the
old facts. Compilation database commands are executable inputs; use the database for the project
and toolchain you intend to run.

This mode supports C inputs with GCC/Clang driver arguments. Response files, compiler wrappers,
`-Xclang`, `-Xpreprocessor`, `-Wp,`, compiler plugins and saved intermediates are unsupported.
Common separate operands for include paths, macros, sysroots, targets and architecture are retained;
other unknown bare operands fail. Unsupported forms require an explicit simplified database,
rather than silent flag removal. MSVC command syntax is not supported.

Schema version 3 file records include `configuration`, `coordinates: "preprocessed"`, `directory`
and the effective compiler `arguments`. `path` identifies a translation unit. **Byte ranges and
row/column positions refer to the preprocessed input, including included headers, not the original
source file.** Each translation unit owns its included definitions, so a static inline header
function in two units has two distinct identities. No source map or preprocessed-text artifact is
published. Reproduce the recorded command to obtain the text for these coordinates.

Version 3 also emits file-scope function `declaration` records, with an empty container, null
container byte and internal/external linkage. Function-pointer objects and block-scope prototypes
are excluded. The consumer requires a preceding external declaration before matching a cross-unit
call. This adds declaration context without implementing C type checking, variable shadowing,
linker selection, inline-definition rules or a full scope resolver.

The database is capped at 8 MiB, 1000 units, 256 original arguments and 32 KiB of encoded effective
argv per unit; individual arguments are at most 4096 bytes. Preprocessing runs sequentially, with
8 MiB stdout, 64 KiB stderr, 30 seconds per compiler and a five-minute compiler-phase budget for
the batch (cleanup has the process library's additional budget). Expanded translation units use a
1048576-node and 128 MiB serialized-result cap; other parsing and fact-output limits remain as above.
System-header extensions may exceed the C grammar's coverage: files with
syntax errors remain flagged, and the consumer excludes their entire translation unit. A configured
export is therefore not a promise of compiler-level semantic coverage.

`make test-tree-sitter` exercises this application with independent JSON/byte-range checks, failed
input preserving the destination, Unicode paths, malformed source and repeated files under a heap cap.
Configured tests compare both build modes with independent compiler preprocessing, run compiled
programs, verify declaration guards and check that extraction leaves object/dependency files intact.

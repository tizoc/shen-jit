# Working on Shen/JIT

Notes for contributors and agents. [The guide](docs/guide.md) covers how to install, use and build Shen/JIT, and
[docs/design.md](docs/design.md) how it works. If `AGENTS.local.md` exists, read it too: it holds a
checkout's own workflow, and git ignores it.

## Names

- This project is Shen/JIT: `shen-jit` in code, commands and file names.
- Bare "JIT" means this project's compiler, `src/runtime/jit.c`.

## Layout

| Path | Contents |
| --- | --- |
| `src/runtime/` | The C runtime: values and objects, collector, image, primitives, reader, loader, JIT, profiler, and the executable (`main.c`) |
| `src/lowerer/` | The lowerer (`lower.shen`) and the stage 0 tools; see [src/lowerer/README.md](src/lowerer/README.md) |
| `src/port/shen-jit.kl` | Port code: overrides and the `shen-jit.*` functions |
| `docs/` | The guide's source, and how it works |
| `site/` | What renders the guide: pandoc's template and a filter |
| `include/` | `shen.h`, for C written for Shen |
| `lib/` | Libraries that are not in the default image, loaded on request: `native.shen`, native code written by hand and the rules bytecode is checked against, `ffi.shen`, calling C, and `memory.shen`, `mmap.shen`, `sqlite.shen` and `socket.shen` over it, `handle.shen`, which releases memory once nothing reaches it, `datalog.shen`, relations and recursive rules, over `native.shen`, `buffer.shen` and `cursor.shen`, views over bytes, `grammar.shen`, parsers over those, I/O over those (`io.shen`, `io-file.shen`, `io-socket.shen`, `frame.shen`, `deadline.shen` and `clock.shen`), HTTP/1.1 over that (`http-*.shen`), and `json.shen` |
| `tools/` | Scripts: `stlib.shen` writes the executable of `make stlib`, `ci-deps.sh` fetches the kernel, the earlier release that builds this one and Shen/Scheme, `package.sh` makes a release archive, `release-notes.sh` prints a version's section of the changelog, and `buffer-parsers.shen`, `frame-echo.shen`, `http-echo.shen` and `http-head-capture.shen` are small examples over the libraries |
| `example-apps/` | Runnable applications built over the public libraries, each with its own README and independent test: `sqlite-http` over HTTP and SQLite, and `depends` over Datalog |
| `assets/` | The logos and icons |
| `tests/` | Unit tests, `eval-kl` cases, CLI tests and benchmark drivers |
| `contract/` | The contract examples, and Shen/Scheme's results for them |
| `vendor/` | SLJIT and xxHash, each with its license and an `UPSTREAM.md` naming the imported revision |

`lib/curl.shen` is another optional library, with `lib/curl.c` as its callback adapter over the public
C API. `make curl` builds it; `lib/build-curl.sh` also builds it from a binary release's sources.
`lib/fs.shen` adds paths, metadata, bounded traversal, temporary files and replacement over the I/O
library. `make fs` builds its platform-layout adapter, `lib/fs.c`, with only the system C library.

`lib/process.shen` and `lib/process-io.shen` add child processes, bounded pipe I/O and pipelines.
`make process` builds their adapter; `make test-process` needs a C compiler and Python 3. Static Linux
runs the pure checks and skips native work before compiling adapters or starting child fixtures.

`lib/tree-sitter.shen` adds complete-input syntax snapshots and bounded structural query captures.
`make tree-sitter` builds its adapter against Tree-sitter >= 0.25. `make deps-tree-sitter` fetches
the pinned runtime/C grammar for tests; loading or testing never downloads them implicitly.

## Priorities

- Shen/JIT must perform well, but stay small and simple. A speed-up that needs a lot of new machinery for
  little gain is not worth it: say so, and record it in the development log instead.
- A speed-up of the code people actually run weighs far more than one that moves a synthetic benchmark. A gain
  seen only in a benchmark is rarely worth any code.
- Niklaus Wirth's rule applies: "Generate good code for the frequent case; don't optimize the exceptional case."
  A pathological case must work correctly, but it doesn't need to be fast, and it doesn't get complexity or size.
- Libraries outside the default image go in `lib/`, and scripts in `tools/`.
- The standard library (stlib) stays out of the default image: `make stlib` builds an executable with it,
  from the kernel's `klambda/stlib.kl`.

## Git

A commit message says what changed and what it measured.

## Building

- `make deps` fetches the kernel and the earlier release of Shen/JIT that builds this one into `.deps/`. A file `local.mk`, which git ignores, can
  set other paths: the guide lists the variables.
- Shen/Scheme can be the host too, with `BOOTSTRAP`, and must keep making the same generated files, which CI's `shen-scheme-host` job checks. The host need not move with each release: move it in `tools/ci-deps.sh` only when the lowerer needs what a newer one has.
- `make guide` needs pandoc, and so do `make dist` and `make test-linux`, as a source tarball carries the guide rendered.
- `make` misses an edit made in the same second as the last build, since their times tie: any source file, not only
  `src/lowerer/lower.shen`. After scripted edits, `sleep 1; touch FILE` before rebuilding.

## Testing

Run what the change can break, and nothing more: CI runs everything on every push.

| What changed | What to run |
| --- | --- |
| The runtime, the JIT, the lowerer, the port, `vendor/` or the generated files | `make test-core` (about 20 s) |
| The C API (`include/shen.h`, `src/runtime/ffi.c`), images or threads, which libraries and their adapters use too | `make test-core test-libs` |
| `lib/native.shen` | `make test-native test-datalog` |
| `lib/ffi.shen` | `make test-ffi test-libs` |
| A library others load: `buffer`, `io`, `io-file`, `grammar`, `json`, `memory`, `socket`, `deadline`, `clock` or `fs` | `make test-libs` (about 30 s) |
| `datalog`, `http-*`, `process*`, `tree-sitter`, `curl` | `make test-datalog`, `test-http`, `test-process`, `test-tree-sitter`, `test-curl` |
| `frame`; `cursor`; `mmap`, `handle`, `sqlite` | `make test-io`; `test-buffer`; `test-ffi`, and `test-http` for `sqlite` |
| An application in `example-apps/` | The suite that runs its `test.sh`: `test-http` for `sqlite-http`, `test-datalog` for `depends` |
| A test, `Makefile`, `tools/` or CI | What the edit touches |
| Documentation only | Nothing; `make guide` if a rendered page's layout changed, and the examples you changed |

`make test-core` is `test test-jit test-ops test-kl check-lowerer check-generated test-kernel test-stlib test-thorn
test-native test-ffi test-overrides`, and `make test-libs` is `test-buffer test-json test-io test-fs test-process
test-tree-sitter test-http test-datalog test-curl`.

Keep each suite fast. A check that needs a collection at every allocation, a long wait or a large input goes in a
stress target that CI runs, as `test-lib-stress` holds the libraries' saved images reloaded under GC stress: a test
script runs such a part only when `TEST_GC_STRESS=1`.

`make test-curl` builds the optional adapter with libcurl's development headers, then runs an independent
loopback HTTP/TLS fixture with Python 3 and the `openssl` command. Static builds run the pure checks and
explicitly skip the native part. `make curl` builds the adapter for applications; ordinary builds do not need it.
`make test-fs` needs a C compiler and Python 3. It exercises native filesystem operations, I/O cleanup,
typed clients, images/GC and a bounded copy application; static builds run only the pure path checks.
`make test-tree-sitter` needs a C compiler, Python 3 and `make deps-tree-sitter` once, or explicit
runtime/grammar source roots. Static builds run pure validation and skip before native dependencies.
`make test-datalog` also checks `example-apps/source-deps/`: managed NDJSON/model checks on every
build, and a saved executable, independent graph/BFS oracles, I/O and image/GC on shared-capable
builds (C compiler and Python 3). The Tree-sitter suite checks the complete extraction/analysis path.

`make test-overrides` (a second) runs each kernel function that the port replaces beside the kernel's own definition, taken from the KLambda, over generated values, as compiled and through C. They must agree exactly: 1 and 1.0 differ, and a value and an error, but not the text of two errors. What differs on purpose is listed in `o.known` in `tests/overrides.shen`, with its reason, as narrowly as it can be. A difference that no longer shows fails, and so does a new override that the test does not name, so a new one joins it there or `o.left-out`.

A change that alters the generated files (the lowerer, the port, or the lowered test programs
`tests/bench/programs.kl` and `tests/kl/ops.kl`) updates `generated.sha256` in the same commit, with `make
update-generated`; `check-generated` fails until it does. Any other difference in them is drift: a different kernel or host.

CI runs the heavier suites on every push, or the same thing natively, so leave them to it, before a release too. Run one here only to debug what it guards, one at a time:

- `make test-kernel-stress test-kl-stress` (GC stress, about 2 minutes): changes to allocation, the collector or the heap pointer.
  Under `test-kl-stress` every allocation collects, so keep allocation loops in eval cases short, and under `test-kernel-stress` every 1000 words. The old space is overwritten after each collection, so a stale pointer fails at once.
- `make test-lib-stress` (about 2 minutes): changes to how a library keeps native state across a saved image or a collection, such as handles, finalizers or adapters. It reloads each library's saved image with a collection at every allocation.
- `make test-san` (sanitizers): changes to C code that handles memory.
- `make test-x86` (x86-64 under Rosetta): new kinds of SLJIT instructions or calls in the JIT, and changes to how `src/runtime/ffi.c` calls C.
- `make fuzz-native` (mutated code objects, a few minutes): changes to what the JIT assumes about bytecode, which the checker in `lib/native.shen` must then enforce for code written by hand.
- `make test-datalog-swipl` (about 6 s, needs `swipl`, not in CI): changes to how `lib/datalog.shen` evaluates. `make test-datalog` compares with its own plain evaluator, and this with an engine that shares nothing with it. `make bench-datalog` times its workloads, and `make bench-datalog-souffle` checks and times them against Soufflé.
- `make test-differential` (about a minute): changes to a primitive, inline or in C, to what the JIT does around one, or to handlers. It runs each primitive over generated values, however it is compiled, and again with `SHEN_JIT_SLOW_PRIMS=1`, which sends every primitive to C, and checks properties of `=`, the comparisons, arithmetic, strings, stores and bit operations. A new primitive joins `d.prims` in `tests/differential.shen`. `make differential-scheme` lists what differs from Shen/Scheme, to read and not to pass: either may be wrong.
- `make test-linux` (every suite on Linux arm64 and x86-64, in Docker, built with gcc from a release tarball, without a host): changes that may differ by
  platform or compiler. gcc evaluates a call's arguments in another order than clang, which shows a value read before an allocation that moves it, and Linux's AddressSanitizer also reports leaks.

On macOS, Guard Malloc finds a write past a block or into a freed one at once:
`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib build/shen-jit ...`, under `lldb` to see the writer.

New behaviour gets cases in `tests/kl/eval-cases.kl` (KL) or `tests/cli.sh` (the executable). Note that the readers turn `8.0` into the integer 8, as Shen's reader does.

CI (`.github/workflows/ci.yml`) follows `tests/linux.sh`: one job makes the tarball, with pandoc and the kernel and host releases that `tools/ci-deps.sh` checks by hash, and each platform builds and
tests it with a C compiler alone. Moving the kernel, the host or Shen/Scheme updates the hashes there.

`make test-thorn` runs THORN, from the kernel, with its wall-clock limit taken away. `tests/thorn.expected` holds each problem's inference count and what went unproved, which Shen/Scheme also gives. Moving the kernel may change them: compare with Shen/Scheme, then run `tests/thorn.sh` with `UPDATE_THORN=1`.

## Releasing

Move what is under "Unreleased" in [CHANGELOG.md](CHANGELOG.md) to a heading with the version and the date, then push `main` and a tag `vM.N` that matches `VERSION`, together if you like. CI builds Linux x86-64 and arm64 (dynamic, in a container with an old glibc, and static, which cannot load libraries), macOS arm64 and Windows
x86-64, and runs the fast suites on them. GC stress, the sanitizers and the mutated code objects ran on `main`, so a tag leaves them out. It then makes a draft release of those archives (`tools/package.sh`), each with the rendered guide, the source tarball and `SHA256SUMS`, with the tag as the title and the version's section of the changelog as the notes, and refuses if that section is empty (`sh tools/release-notes.sh VERSION` shows them). A tag with a hyphen is a prerelease. Making a draft public is done by hand, on GitHub, and only by the project's owner, once `main`'s run on that commit has passed.

## Measuring performance

- Time the rows a change aims at directly: a small Shen file that loops over the case and reports `get-time unix`, run on the old and new binaries in alternation, several times.
- Run `make bench` when a change can affect code beyond its target, such as branch shapes on common paths.
- Check that a gain holds outside the benchmarks: `make bench-independent` times workloads never used for tuning, which mostly load, compile and typecheck code, and THORN, which mostly runs. A benchmark gain that does not
  show there, or a loss there, is fitting the benchmarks or a cost in compile time.
- For real arithmetic and raw registers, `make bench-numeric` runs five programs in C, in boxed Shen and with registers, and a path tracer in C and with registers. Each prints a check, which must agree to the last digit.
- Some rows move with where code and data lie, not with what they run: `vector create (big)` with the heap pointer's parity, and `list traversal`, `match vector`, `symbol? (true)`, `shen.sysfunc?` and
  `captured-unary-ordinary` with what else the process compiled. Before acting on a slower row, time it alone; if a change alters branch shapes, also time it with the code shifted by a few unrelated definitions compiled first.
- To profile on macOS, run with `SHEN_JIT_PERF_MAP=1`, sample the process with `sample PID SECONDS`, and resolve JIT addresses against `/tmp/perf-PID.map`. `SHEN_JIT_PROFILE` uses SIGPROF, whose samples land where system calls
  return, so it over-counts C and under-counts native code.
- Measure on a quiet machine.

## Documentation

Keep these current with each change:

- [docs/development-log.md](docs/development-log.md): every significant change or rejected experiment gets an entry in the same commit, under its topic: what was done or rejected, why, and the numbers,
  with the date, the machine and what it was compared against, so that none reads as a current claim. It must answer "did anyone try X?" quickly. Rejected ideas are the most valuable part.
- [docs/design.md](docs/design.md): how it works now.
- [docs/bytecode.md](docs/bytecode.md): the lowerer's rules and the instructions.
- [docs/semantics.md](docs/semantics.md): the behaviour, with the contract examples.
- [docs/overrides.md](docs/overrides.md): overrides in the port.
- [docs/ffi.md](docs/ffi.md) and `include/shen.h`: calling C.
- [docs/guide.md](docs/guide.md): what a user sees. `make guide` renders it with pandoc, `site/template.html` and `site/guide.lua`, with design, semantics, bytecode and ffi as pages of their own, whose links `site/guide.lua` points at those pages; `.github/workflows/pages.yml` publishes them when any of those change, and release archives carry them. Don't mention the development log or the overrides in a rendered document. Run the guide's examples when you change them.
- Library API references belong on their own pages in `docs/`, linked from a brief guide entry. Register rendered pages in
  `GUIDE_PAGES` in the Makefile, `site/guide.lua`, and the path filter in `.github/workflows/pages.yml`.
- The README stays minimal and points to the guide, so that they don't say the same things twice. What a user should know goes in the guide.
- [CHANGELOG.md](CHANGELOG.md), in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format: what a user would notice, under "Unreleased" until a release.

If something tells people what to do now or how things work now, it belongs in those, and not in the log.

Don't say which version of Shen this implements, since that keeps changing: `tools/ci-deps.sh` holds it, and only the log's dated entries and the changelog, when the kernel moves, name one.

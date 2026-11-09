# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The guide has a part for the libraries, grouped by what they do, which says once how to load them and build their
  adapters, and lists the example applications. "Close to the machine" keeps the runtime's own: bytes and bits,
  calling C, memory outside the heap, C written for Shen and native code by hand.
- Prolog makes each clause variable in one function instead of three: short queries take 3-11% less time.

## [0.6] - 2026-11-08

### Added

- `lib/grammar.shen`: `defgrammar`, Shen-YACC's notation for parsers over byte views. Each rule compiles to a
  function over a buffer, a position and an end, with parameters, repetition as loops, captures of the bytes matched
  as strings or views, binary fields, and `require`, which stops a parse with a message and a position. See the guide.
- Typed grammars: a signature after a rule's name, `{==> Value}` or `{T1 --> T2 ==> Value}`, as in `defcc`, and
  under `(tc +)` each alternative is checked: its value, its guards, its messages and the arguments it passes. Typed
  code parses with `grammar.parse`, `grammar.match?` and `grammar.read` of a typed rule, `json.read` and
  `http.read-request` are declared, and grammars can be loaded under `(tc +)`.
- `grammar.read` parses a value from an I/O reader as its bytes arrive, in the reader's buffer, without framing
  it first, and `json.read` reads JSON values that way, leaving what follows unread. `http.read-request` reads a
  request head that way, and the server uses it when the head limit fits its read buffer, as by default.
- `io.let-ok` in `lib/io.shen` binds the values of `[ok X]` results in order and returns the first other result, in
  place of a function per step that passes errors on.
- Optional `lib/fs.shen`: paths, metadata, sorted listings and traversal within bounds, exclusive temporary files and
  directories, renaming that never overwrites, replacing a file whole, and copying through the I/O library. `make fs`
  builds its adapter, and [the reference](docs/fs.md) has the API and `tools/fs-copy.shen`.
- Optional `lib/process.shen` and `lib/process-io.shen`: child processes started with explicit arguments, environment
  and working directory, which the program owns and cleans up with their process groups or jobs, bounded waits,
  cancellable pipes, input and output at once, output streamed into sinks or limited. `make process` builds their
  adapter, and [the reference](docs/processes.md) includes `tools/process-filter.shen`, which writes a command's
  output to a file only once the command has exited with 0.
- Optional `lib/tree-sitter.shen`: languages loaded from compiled grammars, syntax trees of whole inputs, byte and
  point ranges, error and missing nodes, traversal, and structural queries with bounded captures. `make tree-sitter`
  builds its adapter against Tree-sitter 0.25 or later. See [the reference](docs/tree-sitter.md).
- Optional `lib/curl.shen`, with a small C adapter over libcurl: bounded HTTP(S) requests, reusable clients,
  binary bodies, headers and trailers, timeouts, TLS verification and explicit redirect limits. Responses can
  stream into I/O sinks, with backpressure, bounded chunks and exact progress when a write is partial.
  `tools/curl-fetch.shen` streams successful bodies to files, and an error once writing has begun can leave a
  partial file. `make curl` builds the adapter. See [the reference](docs/curl.md).
- Datalog records and types of several constructors: `(type shape [circle point integer] [rect point point])`, values such as
  `[rect [pt 1 2] [pt 4 6]]`, taken apart in a rule's body and made in its head or by `=`, recursive types included.
- Datalog functions: integer `/` and `%`, `band`, `bor`, `bxor`, `bshl` and `bshr`, `cat`, `strlen`, `substr`, `to-number` and
  `to-string` on strings, and the `mean` aggregate.
- Datalog equivalences: `(relation same [symbol symbol] equivalence)` keeps the reflexive, symmetric and transitive closure of what
  it is given, by union-find, stored as classes and not as their pairs, so that a class of k values takes room for k, not k squared.
- Datalog lattices: `(relation reached [symbol integer] (lattice F))` keeps for each key the least upper bound, by a Shen
  function, of the values derived; `(lattice bor)` and `(lattice band)`, unions and intersections of bit sets, are native.
- Datalog relations that keep one tuple a key: `(relation dist [symbol integer] min)`, `max` and `choice`, by which shortest
  paths end without a bound.
- `datalog.query`: a Datalog query computed by demand, through magic sets, deriving only what bears on its constants, and
  `datalog.demand-db`, a database that answers queries so, keeping what earlier ones derived through adds and removals.
- `datalog.explain`: why a Datalog tuple holds, as a proof down to the facts given.
- `datalog.read-facts` and `datalog.write-facts`: Datalog relations from and to tab-separated or CSV files, each field read as
  its column's type says; `datalog.bytes->facts` and `datalog.relation->bytes` do the same with the files' bytes, for a
  program that writes its files itself, as with the I/O library.
- `shen-jit.write-bytes`: a range of a byte buffer written to a stream at once, where `write-byte` takes a call a byte.
- `example-apps/depends/`, a dependency analyser over Shen and KL source files, built over `lib/datalog.shen` as one
  executable: what calls what, cycles between files, dead code from roots, call depths, and why one function reaches another.
- `example-apps/source-facts/`, which parses a directory of C with Tree-sitter and writes NDJSON facts: its files,
  function definitions and direct calls, with the definition each call is in, each definition's linkage as far as
  `static` declarations show it, and each file's parse errors, with samples. Given a compilation database from GCC or
  Clang, it preprocesses each file as that build does, through the process library, and records declarations too.
- `example-apps/source-deps/`, which reads those facts into Datalog and matches calls with definitions, keeping
  functions of the same name in different files or places apart. It reports which functions one reaches or which
  depend on it, and the calls it could not match or found ambiguous, and the files it left out for syntax errors.

### Changed

- `lib/http-request.shen` parses the request line with a grammar, and `lib/json.shen` decodes with one, so
  `lib/grammar.shen` must be loaded before either. JSON decoding is 1.2 to 4 times as fast, most for strings without
  escapes. Some invalid inputs are reported with a different message or offset: what was expected where it failed.
- A read lends the backend a chunk that the endpoint keeps, where it allocated a fresh one as large as the reader's
  free space each time. Small reads into a large reader are 3 to 8 times as fast, an HTTP head takes 15 to 32% less time,
  and a JSON value read a byte at a time as it arrives 6.6 times. A custom backend's Read must not keep its chunk.
- `pr`, through which `output` and `print` write, writes a string at once, not a byte at a time.
- On arm64, a loop in code written by hand keeps the memory of eight parameters at hand, where it kept four, and gives its
  last registers to words before the bases and limits of that memory, and first to words it carries from one iteration to
  the next. Datalog's larger evaluations take 9 to 21% less time.
- `datalog.ask` and `datalog.match` find the tuples of a pattern with constants by an index on their columns, which the first
  such question makes and the database keeps, where they read the whole relation.
- Datalog derives each combination of tuples once in a rule with several atoms of its own recursion, such as
  `(path X Z) <-- (path X Y) (path Y Z)`, where it derived those that were new together once for each.
- `make test-core` runs the suites of the runtime, the compiler and the port, and `make test-libs` those of the libraries.
  The libraries' saved images reloaded with a collection at every allocation moved to `make test-lib-stress`, so their
  suites take seconds where `make test-http` took over a minute.

### Fixed

- On Windows, command-line arguments reach a program as UTF-8, in scripts and saved executables alike. They came in the
  system's code page, with a question mark for any character outside it, so a program could not open a file whose name
  it was given with such characters.

## [0.5] - 2026-11-07

### Added

- `lib/datalog.shen`: relations, facts, recursive rules, stratified negation, arithmetic on 32-bit integers and
  aggregates (`count`, `sum`, `min` and `max`), evaluated bottom up to a fixed point, with each rule compiled to
  native code with `lib/native.shen`, facts added to a database incrementally, and facts removed. See the guide.
- `lib/native.shen` writes loops and branches without labels: `if`, `when`, `unless`, `while`, `for`, `block`, `exit`
  and `next`, which become the same instructions. `shen-jit.expand-native` shows what they become.
- Libraries for bytes and I/O that do not use Shen's streams: `lib/buffer.shen` and `lib/cursor.shen`, checked
  views over heap bytes or foreign memory and positions in them; `lib/io.shen`, `lib/io-file.shen` and
  `lib/io-socket.shen`, bounded readers and writers over memory, files and TCP connections, which keep what a short
  transfer moved and flush on close; `lib/frame.shen`, bounded binary messages read across chunks; and
  `lib/deadline.shen` with `lib/clock.shen`, a monotonic time budget for a whole operation, across retries.
- HTTP/1.1, in `lib/http-head.shen`, `http-request.shen`, `http-response.shen`, `http-server.shen` and
  `http-listener.shen`: request bodies bounded by Content-Length or chunked, with trailers kept apart, responses
  whole or streamed with a length or chunked under a write budget, a deadline for each phase, persistent connections
  under request, idle and lifetime limits, and a listener with a connection limit and controlled shutdown. Ambiguous
  framing is rejected.
- `lib/json.shen`: JSON decoded from and encoded to byte views, with strict UTF-8, numbers kept as written until
  converted exactly, and bounded output.
- `example-apps/sqlite-http/`, a counter served over HTTP from SQLite, which takes JSON bodies and streams NDJSON
  exports. `tools/` has smaller examples: `buffer-parsers.shen`, `frame-echo.shen`, `http-echo.shen` and
  `http-head-capture.shen`.
- `make test-overrides` runs each kernel function that the port replaces beside the kernel's own definition, over
  generated values, as compiled and through C.

### Changed

- Release archives carry the example applications and the tests, beside the libraries and the guide.
- Prolog does less work: `(when (= X Y))` compares as it dereferences, without copying both terms first, a cut
  followed by `(when false)` no longer makes a closure, and a chain of Prolog variables is followed without a call to
  C. THORN's problems take a few percent fewer instructions.
  The first two were contributed by @pyrex41 in [#19](https://github.com/tizoc/shen-jit/pull/19) and
  [#20](https://github.com/tizoc/shen-jit/pull/20).
- The JIT reuses scratch buffers across liveness checks while compiling each code object.
  Reported by @pyrex41 in [#17](https://github.com/tizoc/shen-jit/pull/17).
- Converting strings to byte lists for `read-from-string` takes time linear in the string's length.
  Reported by @pyrex41 in [#16](https://github.com/tizoc/shen-jit/pull/16).
- Compiling code with many distinct constants no longer searches all of them for each new one: a list of 32000
  numbers takes about a thirtieth of what it did.
  Contributed by @pyrex41 in [#13](https://github.com/tizoc/shen-jit/pull/13).
- Lowering is faster: looking up a fixed name no longer scans them all, and a long definition with many inlined calls
  no longer takes time that grows with the square of its size.
  Contributed by @pyrex41 in [#15](https://github.com/tizoc/shen-jit/pull/15).
- Many threads waiting on sockets use far less CPU: giving up the runtime lock wakes the next thread, not every
  waiting one, so 1000 such threads no longer take over the machine.

### Fixed

- `handle.close` invalidates the handle even if its release function raises, so nothing can keep using the memory
  that function freed.
- Under `SHEN_JIT_MAX_HEAP`, a vector or string of 256 KB or more no longer raises `out of memory` with the heap nearly
  empty, as it did for good once the heap had grown past half the limit. The process can use more memory at the limit
  as a result, up to about three times it.
- Writing to a closed pipe raises an error that a program can catch, instead of ending the process. So
  `shen-jit script f | head` can now print `write-byte: Broken pipe` to stderr and exit with status 1.
- A `c#N;` escape past 255 in a string, such as `c#955;`, no longer fails to load: `n->string` gives a Unicode scalar
  value's UTF-8 bytes.
- File read errors raise instead of looking like end of file: whole-file reads no longer return empty or
  partial data on failure, and `read-byte` reports failed file reads.
- Loading code with more than 255 parameters or call arguments, or a capture index above 255, reports which limit
  was exceeded. Reported by @pyrex41 in [#18](https://github.com/tizoc/shen-jit/pull/18).
- The error for defining a function with a system function's name ends its line, as the kernel's does.

## [0.4] - 2026-11-06

### Added

- `make test-differential` runs each primitive over generated values, however it is compiled and through C, and
  `make differential-scheme` lists what differs from Shen/Scheme.

### Changed

- Moved to the Shen kernel 43.4, from 43.2.
- Moved to Shen/Scheme 0.54, from 0.53, as the other host that can build a checkout, and what `make bench` compares
  against.
- Compiled code keeps more values in registers between instructions, which speeds up small interpreters and other code
  that works on values it has just taken apart.
- Compiling a long literal list takes far less, and with constant elements the list uses one frame slot instead of one
  per element.
  Contributed by @pyrex41 in [#10](https://github.com/tizoc/shen-jit/pull/10) and
  [#11](https://github.com/tizoc/shen-jit/pull/11).

### Fixed

- `define` no longer fails on a `cond` with no true clause. The definition compiles, and raises an error when no
  clause applies.
- `absvector` too large for `SHEN_JIT_MAX_HEAP` gave a handler `[]`, on which `error-to-string` failed, instead of
  an "out of memory" error.
- `absvector` with a length of 2^56 or more crashed. It now raises an error from 2^48 up, as `shen-jit.bytes` does.
- `shen-jit.pvar` and `shen-jit.pvar-offset` raised past a `trap-error` in the same function whose handler ignores
  the error.
- `write-byte` and `close` raise an error when the write fails, as on a full disk, instead of losing the data silently.

## [0.3] - 2026-11-06

### Added

- Memory outside the heap: `shen-jit.pointer-sized` makes a C pointer readable and writable in place, with
  the same functions as a byte buffer, each access checked against the length stated. `lib/memory.shen`
  allocates and frees such memory.
- `shen-jit.s32`, `s64`, `f32` and `f64` and their stores, on byte buffers too, and `shen-jit.pointer!`.
- `lib/mmap.shen`: all of a file as memory, on each system, with `mmap.read`, `mmap.read-write`, `mmap.create`
  and `mmap.close`.
- `lib/handle.shen`: memory that releases itself once nothing reaches it, with `handle.wrap`, `handle.close` and
  `handle.sweep`, over `shen-jit.pointer-guard`, `shen-jit.pointer-owner` and `shen-jit.pointers-dead`.
- `shen-jit.collect` collects now.
- `shen-jit.pointer-read-only` makes a pointer that raises when stored to, which is what `mmap.read` gives.
- Real registers in native code written by hand: `real`, `f64!`, `jump-unless` and `return-real` keep doubles
  unboxed in loops that call nothing, and `loop` and `again` make those loops, which can nest.
- Word registers there too: `word`, `jump-unless-word`, `return-word`, `word-box`, and `u8!` to `u64!` keep 64-bit
  integers that wrap, for hashes and random numbers, and as indices with no tag to check.
- `make bench-numeric` runs numeric programs and a path tracer in C and in Shen.
- `make test-thorn` runs THORN, from the kernel, with no time limit, and checks its inference counts and what it leaves
  unproved, which Shen/Scheme also gives.
  Contributed by @pyrex41 in [#9](https://github.com/tizoc/shen-jit/pull/9).
- The rendered guide now has how Shen/JIT works, its semantics, its instructions and calling C as pages of
  their own.

### Changed

- Arithmetic and comparisons on reals, and division, compile inline.
- A loop that calls nothing works out the memory it reads and stores through once, on the way in.
- In native code, machine registers go to what the deepest loops use most, whatever the order of the names, and
  an access to memory reached at one width takes one comparison.
- New objects now always go in the same memory, so a program that allocates uses much less of it, and allocates
  faster where two semispaces taking turns outgrew the cache. A process that only starts takes about 2 MB more.
- On x86-64 outside Windows, a loop that calls nothing keeps up to four values in registers, where it was two.
- The heap grows with what is live, not by doubling, so a program holding a lot of data no longer slows down as it
  nears the next doubling. Such a program can use more memory than before, at most about 1.7 times.
- `get-time` takes about half as long, as it no longer looks up the symbols `run` and `unix` at each call. THORN asks
  for the time at every predicate call.
  Contributed by @pyrex41 in [#8](https://github.com/tizoc/shen-jit/pull/8).

### Fixed

- `=`, `<`, `>`, `<=` and `>=` now compare an integer with a real exactly. From 2^53 up the integer was rounded to a
  double first, so `=` was not transitive, unification could depend on the order of its arguments, and two keys that
  were `=` could have different hashes.
  Contributed by @pyrex41 in [#6](https://github.com/tizoc/shen-jit/pull/6).
- `=` no longer crashes on terms nested deeper than the C stack, in the head of a pair or in an absvector. A cyclic
  term still ends the process, now with a message.
  Contributed by @pyrex41 in [#7](https://github.com/tizoc/shen-jit/pull/7).
- An integer literal too big for a fixnum, and one with a large exponent such as `1e300`, now reads as the
  nearest real. They could land slightly off it, as `1e100` read as `1.0000000000000006e100`.
- A burst of new symbols, such as from `gensym` in a loop, no longer slows every later collection for as long as
  the process runs.

## [0.2] - 2026-11-05

### Added

- A checkout now builds on Linux arm64, from `make deps`.

### Changed

- A checkout now builds with the previous release of Shen/JIT, which `make deps` fetches. Shen/Scheme can
  still build it, with `make BOOTSTRAP=...`, and makes the same generated files.
- The guide is centered on wide screens.

## [0.1] - 2026-11-05

### Added

- Initial release

[Unreleased]: https://github.com/tizoc/shen-jit/compare/v0.6...HEAD
[0.6]: https://github.com/tizoc/shen-jit/compare/v0.5...v0.6
[0.5]: https://github.com/tizoc/shen-jit/compare/v0.4...v0.5
[0.4]: https://github.com/tizoc/shen-jit/compare/v0.3...v0.4
[0.3]: https://github.com/tizoc/shen-jit/compare/v0.2...v0.3
[0.2]: https://github.com/tizoc/shen-jit/compare/v0.1...v0.2
[0.1]: https://github.com/tizoc/shen-jit/releases/tag/v0.1

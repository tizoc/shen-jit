# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Isolates: `(shen-jit.spawn F X)` runs a function the program defined on an OS thread of its own, with its own
  heap, globals and property list, so isolates run on several cores at once. They talk through channels
  (`shen-jit.channel`, `shen-jit.sender`, `shen-jit.send`, `shen-jit.receive`, `shen-jit.receive-any`,
  `shen-jit.wait-any`, `shen-jit.close` and `shen-jit.end?`), which copy what is sent; `shen-jit.monitor` watches them,
  and `shen-jit.kill` stops one at its next channel operation or `shen-jit.check-kill`, which the I/O library's socket
  waits call. Only the first isolate, the builder, defines, and the program is fixed while other isolates run:
  defining raises until they have ended. Symbols are the same in every isolate.
- `(shen-jit.share X)` copies `X` once into storage outside every heap, which isolates read by pointer rather than
  as copies; nothing changes it, as stores into its vectors and byte buffers raise, and it is never freed.
- `(parallel.map N F Xs)` in `lib/parallel.shen`, over isolates: a function named `F` mapped over `Xs` with at most
  `N` isolates, the results in order. It replaces the library's worker scopes and `lib/parallel-map.shen`.
- Tree-sitter languages loaded in the builder parse in any isolate.
- Datalog programs run in isolates: `(datalog.share Name)` prepares a program and gives it as a shared value, which an
  isolate takes up with `(datalog.use Shared)`. An isolate joins in the orders the builder's runs chose, and otherwise in
  the order with no sizes to go by.
- `(datalog.run-parallel N Name Facts)` runs a program whose rules keep the key of their first column in at most `N`
  isolates, each for some of the keys, and gives a database of the parts, which counts, membership and queries read;
  `datalog.partition` says whether a program runs so. Others run as `datalog.run` does.
- The `source-deps` example's batch queries are back, with `--workers N` running them in isolates over the graph
  shared once; no worker image is needed.
- Grammars work in isolates: a load compiles a rule's loops after the form defining it, and prepares the streaming
  reads that code names. `shen-jit.after-form` registers a function to run after each form of a load.

### Changed

- The HTTP listener serves each connection in an isolate of its own, in parallel, supervised by the program that calls
  the new `http.run` until the server is stopped; `http.listen` binds and returns the server without serving, and
  `http.wait` gives the result once `http.run` has returned. A handler goes by name, as `f` or `[f Arg ...]`, which
  is called with the arguments and then the request, rather than as a closure, and stops its server with
  `(http.stop (http.current-server))`. Connections left once `shutdown-grace` has passed are killed. The
  `sqlite-http` example passes its database path as a handler argument, and keeps a write-ahead log, with a
  connection held open while it serves.
- A `blocking` foreign call passes byte buffers where they are, rather than copies, and the flag changes nothing now.
- A definition whose code holds a value with no syntax, such as a vector put into a form given to `eval`, or a
  native `(const E)` whose value is one, is refused when it is defined.
- A grammar's loops compile after the form defining the rule, in a load, and at once outside one, rather than at
  their first call; a guard that calls a function defined after the rule is tested in place, without a table.
- Installed definitions, with what their code reaches, and every symbol now live in a program space that
  collections neither copy nor scan, so collections no longer copy the program. A redefined function's old
  versions stay there. `SHEN_JIT_STATS` reports the program space.
- A global's value is kept in a slot of the runtime's own, which a symbol gets once code names it as a global or it
  is set; `SHEN_JIT_STATS` reports function cells and global slots.
- Arities are kept beside function cells, not in the property vector: `(get F arity)` finds none. `arity` and `fn`
  are unchanged. A primitive's function cell now holds a definition, so it is a procedure as any function is.
- Calling a definition's procedure, as `shen-jit.function` gives it, with all its arguments at once now works, where
  it applied them one at a time and failed.
- The byte primitives read strings as they read byte buffers, and refuse to store into one. `shen-jit.bytes?` is
  still false for a string, `buffer.wrap` still refuses one as storage, and the FFI's `bytes` arguments take byte
  buffers alone.

### Removed

- `thread`, and the threads under a global lock it started: isolates run in parallel instead.
- The worker scopes, `lib/parallel.shen`'s scopes and byte API, `lib/parallel-map.shen` with
  `tools/parallel-map.shen`, and `lib/datalog-parallel.shen`, with their primitives and the shared read-only view, and
  the `source-deps` example's batch queries over them, which run over isolates now, with a parallel map and runs of
  Datalog in parts. `--worker-image` is gone from `source-deps`.

## [0.7] - 2026-11-10

### Added

- `defstruct`, available at startup: fixed managed records with read-only fields by default, optional mutable
  fields and `->` setters, positional constructors, labelled construction and pattern matching with
  `(:entry key <- K ...)`, open unions of typed structs with `(struct.union shape circle rect)`, namespace
  support and stable image/reload metadata. Records print with their type and fields, or through a declaration's
  `(printer F)`. Fields may have types, `(x : number)`: the operations are then typed, under `(tc +)` and
  for typed clients of a struct declared under `(tc -)`.
- Experimental worker scopes, `lib/parallel.shen`, whose API is expected to change: a named function of a saved
  image runs on 1 to 64 OS threads at once, each with a runtime of its own, over copied byte messages and one
  read-only buffer they share. A scope always joins its workers. `thread` is unchanged.
- Experimental `lib/parallel-map.shen`: `parallel.map` over workers, for copied numbers, booleans, symbols,
  strings and proper lists, with results in order, checked accessors for typed code, and the example
  `tools/parallel-map.shen`.
- Experimental `lib/datalog-parallel.shen`: opt-in Datalog evaluation with an explicit worker budget, automatic
  detection of key-preserving programs and sequential fallback. Results are ordinary parent-owned databases
  supporting queries, explanations and subsequent sequential updates.
  `datalog.parallel.with-db` keeps a read-only database in a reusable scope for counts and queries,
  with explicit materialization when a normal local database is needed. `datalog.parallel.match-many`
  answers several queries in one worker dispatch; bound-key queries skip non-owning shards.
- The source-deps example answers batches of reach and impact queries, `--batch QUERIES`, sequentially or with
  1 to 64 workers over one shared graph, and offers the same through `parallel.map`.
- `(shen-jit.finally Body Cleanup)` and `(shen-jit.on-error Body Cleanup)`, which clean up after a frozen body,
  however it ends or only if it raised. The body's error is the one raised, with any error of the cleanup added
  to its message.
- `(sqlite.with-database Path F)`, which closes the database however F ends.
- `json.string` and `json.array`, which take a string or an array's values out of a JSON value in typed code.
- Types for the socket functions whose arguments and results have plain ones, such as `socket.connect`.

### Changed

- All optional Shen libraries use namespaces, with explicit dependency prefixes and exported operations, types and
  shared support functions. Their qualified API names and data formats stay the same. The kernel pin moves to
  43.6 for namespace interfaces and syntax annotation hooks, using the release's precompiled KLambda. With it,
  a list pattern inside a custom pattern of the pattern-matching extension compiles.
- The libraries' fixed records are structs: views, cursors, I/O endpoints, readers and writers, subprocess, HTTP,
  curl, filesystem and Tree-sitter records, and Datalog's classes and indexes. They print briefly, as
  `#<endpoint "stdin" open>`, and libraries read each other's through exported readers such as
  `io.endpoint.state`. Public APIs and errors stay the same.
- The guide has a part for the libraries, grouped by what they do, which says once how to load them and build their
  adapters, and lists the example applications. "Close to the machine" keeps the runtime's own: bytes and bits,
  calling C, memory outside the heap, C written for Shen and native code by hand.
- Prolog makes each clause variable inline, with one primitive, instead of three calls, and gives its number back
  inline when a clause fails: short queries take 14-28% less time, and the kernel's test suite, which mostly
  typechecks, 8-11% less.
- A query reuses the vector of bindings an earlier one gave back, instead of making and filling one of
  `(prolog-memory N)` words: short queries take a further 13-25% less time, and installing the standard library,
  which typechecks it, 14-16% less.

### Fixed

- Printing an I/O endpoint, reader or writer, a framer, an HTTP head or body reader or response, or a child
  process called the library function named by the record's tag, which the writer takes for a printer, and
  raised an error or printed something else.
- A program that interns many symbols could crash in a collection: when the symbol table grew while most of its
  symbols had died since the last collection, or at the first collection after it grew to 32768 slots with the heap
  full of live data. Interning a name that already exists no longer grows the table.
- Saving an image or executable at `SHEN_JIT_MAX_HEAP` failed with "cannot write" when a large object made since
  loading took more than about half of what was left, though the heap fitted.
- `shen_make_vector` and `shen_make_bytes` given a length of 2^56 or more wrote past the object they made. They
  raise "out of memory".
- At `SHEN_JIT_MAX_HEAP`, a real or a string that a primitive could not make, as in arithmetic on reals, `str` or
  `get-time`, gave the handler `[]` instead of the "out of memory" error, and the process ended. Small objects made
  after a large one could also take the heap past the limit until the next collection, and so could a long string
  from compiled `tlstr` after a caught "out of memory".
- Compiled code calling `shen-jit.newpv` on an absvector of one element wrote past it, over the next object. It
  raises, as the call through C did.
- On Windows, a `save-executable` that failed to write removed the previous executable too.
- `shen_intern`, `shen_make_pointer`, `shen_raise` and `shen_raise_value` given text in a byte buffer could read it
  after a collection moved the buffer. They copy it first, as `shen_make_string` does.
- C that raised an error and then gave up the lock with `shen_release` could return another thread's error, or none.
- A `blocking` foreign call given the same byte buffer twice lost what C wrote through the first, once a thread had
  started.
- Code in shapes the kernel does not produce could compute the wrong value: a lambda nested in one that binds the
  same name, called with both arguments at once; a condition that binds a name the then branch also uses; a
  comparison of two dereferenced Prolog terms whose second changes the bindings; a query whose lock, key or
  continuation names one of its own variables; a query that returns or keeps a `freeze` reading its bindings,
  which went back to the pool; and three cases of inlining a sealed function, through a parameter bound again, a
  literal list, or a parameter named `lambda`.
- `SHEN_JIT_MAX_HEAP` and `SHEN_JIT_SEMISPACE` took any text: `garbage` or a limit under a word meant no limit,
  `8MBogus` meant 8 MB, and a large value wrapped. Anything but digits with one K, M or G is now refused.
- A directory named `shen-jit` on `PATH` before the executable made it fail to start.
- A `shen-jit.install` that failed kept its constants alive for good.
- With threads, a thread's error could show another thread's backtrace, and `SHEN_JIT_STATS` and `SHEN_JIT_PROFILE`
  printed nothing at exit.
- A stack overflow in Shen called from C, under a handler that ignores its error, ended the process once C read the
  error.
- A variable or function named like one of the lowerer's own node tags, such as `apply` or `var`, could make it
  compile code that computed the wrong value or read a variable after it was overwritten.
- Native code written by hand: an `entry` beside a self tail call read arguments it never loaded; an `f64!` or `f64`
  index could overwrite a value still in use; a register named `Word.0` or `Real.0` clashed with a temporary and is
  refused; a word constant that was not an integer became 0; a constant `if`, `when`, `unless` or `while` was refused;
  extra operands of a raw instruction were dropped; and a misplaced `exception` was reported as the instruction before.
- `mmap.create` given a size such as `1.0` emptied the file and left a descriptor open before raising, and
  `mmap.close` returned `true` when the system could not unmap.
- I/O: a backend that raised during a flush let new writes through, and close then reported no progress; a
  framer stopped by an exception forgot what it had read of the current frame; and `io.window-fill` took a
  negative or real count, and a closed reader.
- HTTP: a request head that arrived in the same read as the one before it was not held to `HeadLimit`, as
  `grammar.read-within` did not count input already buffered; a head already buffered was parsed after its head
  deadline; an aborted body read forgot what it had read; and a deadline that expired during a response
  producer's callback dropped the producer's error.
- `process.run`, `process.run-to` and the pipelines started a child before calling the `cancel` option, so a
  value that was not a frozen boolean, or a cancellation already requested, still started one.
- `fs.walk` walked into a linked root named with a trailing slash, such as `tree/loop/`.
- Grammars: `grammar.read` returned a shorter match, such as `12` for `123`, when the reader failed, timed out or
  reached the limit where a repetition or an option would have gone on; a `(text <r>)` that nothing named until the
  end replaced a later match of `<r>`; the first match of `(+ <r>)` replaced a value of `<r>` named before it; a
  rule defined again after a streaming read kept its old definition there; and a `require` whose literal bytes ran
  past the end of the input reported where it began instead of the end.
- JSON: `json.read` waited for more input after a string's closing quote, and reported a surrogate error in a
  string at the string's offset in its copy instead of in the stream.
- SQLite: a transaction whose COMMIT failed, as a deferred foreign key makes it, stayed open; one that SQLite had
  rolled back itself, as `INSERT OR ROLLBACK` does, raised "cannot rollback" in place of its error; and TEXT
  holding a NUL byte came back cut at it, and could not be bound.
- `socket.readable?` took a negative wait, which could wait for ever, and a real one.
- A curl transfer whose response fields did not parse reported no body progress.
- `fn`, given through a variable a function named `shen-jit.lambda-form1` or the like, gave a function that applied
  its argument to itself.
- Types that let typed code go wrong: any JSON value passed for a string, a number or a list, and an HTTP server or
  listener option for a response or chunk option; a foreign function defined again kept its earlier type; and a
  typed grammar took a byte bound with a parameter's name for the parameter, left the arguments it gave a rule
  defined after it unchecked, and accepted a variable that only another alternative bound, which then failed at
  its first call. Typed code could not take the error out of `http.wait`'s result.

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

[Unreleased]: https://github.com/tizoc/shen-jit/compare/v0.7...HEAD
[0.7]: https://github.com/tizoc/shen-jit/compare/v0.6...v0.7
[0.6]: https://github.com/tizoc/shen-jit/compare/v0.5...v0.6
[0.5]: https://github.com/tizoc/shen-jit/compare/v0.4...v0.5
[0.4]: https://github.com/tizoc/shen-jit/compare/v0.3...v0.4
[0.3]: https://github.com/tizoc/shen-jit/compare/v0.2...v0.3
[0.2]: https://github.com/tizoc/shen-jit/compare/v0.1...v0.2
[0.1]: https://github.com/tizoc/shen-jit/releases/tag/v0.1

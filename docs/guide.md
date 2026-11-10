# Shen/JIT guide

A small implementation of [Shen](https://shenlanguage.org) that compiles every function to native code.

Shen is a functional language with pattern matching, optional static types, macros and an embedded Prolog,
built on a small core called KLambda. Shen/JIT lowers KLambda to a register bytecode, and a baseline JIT turns
each function into native code the first time it is called. Its lowerer is written in Shen, and compiles
itself. Programs start in a few milliseconds from a heap image carried inside the executable, which is a single
file of about 1 MB.

## Start

### Install

Each [release](https://github.com/tizoc/shen-jit/releases) has an archive for each platform, holding two
executables, the optional libraries, this guide, the example applications and the tests: `shen-jit`,
`shen-jit-stlib`, which has the [standard library](#the-standard-library) loaded, `lib/`, `include/`,
`guide/index.html`, `example-apps/` and `tests/`.

| Platform | Archive | Can load C libraries |
| --- | --- | --- |
| macOS, arm64 | `shen-jit-VERSION-macos-arm64.tar.gz` | Yes |
| Linux, x86-64 | `shen-jit-VERSION-linux-x86_64.tar.gz` | Yes |
| Linux, arm64 | `shen-jit-VERSION-linux-arm64.tar.gz` | Yes |
| Linux, x86-64, static | `shen-jit-VERSION-linux-x86_64-static.tar.gz` | No |
| Linux, arm64, static | `shen-jit-VERSION-linux-arm64-static.tar.gz` | No |
| Windows 10 or later, x86-64 | `shen-jit-VERSION-windows-x86_64.zip` | Yes |

On Linux, take a dynamic build unless your system is too old for it or has a different C library: those are
built against an old glibc so that they run on newer ones. A static build runs anywhere, but cannot
[call C](#calling-c). The executable is the whole installation, so copy it anywhere, such as a directory on your
`PATH`, unless you use the libraries in `lib/`, which you then name by their path in the archive or source tree.

```sh
tar xzf shen-jit-VERSION-linux-x86_64.tar.gz
cd shen-jit-VERSION-linux-x86_64
./shen-jit --version
```

If macOS refuses to run a downloaded executable, clear its quarantine: `xattr -dr com.apple.quarantine .` in the
directory you unpacked.

#### From source

A release's source tarball needs only a C11 compiler (clang or gcc), `make` and a POSIX system with the maths
library: on Debian or Ubuntu, `apt install gcc make`. It carries, in `generated/`, the files that take an earlier
Shen to make.

```sh
tar xzf shen-jit-VERSION.tar.gz
cd shen-jit-VERSION
make                              # build/shen-jit
make stlib                        # build/shen-jit-stlib
make install PREFIX=/usr/local    # copies build/shen-jit to PREFIX/bin
```

`make install` copies only `shen-jit`, under `DESTDIR` if that is set. It leaves out `shen-jit-stlib` and the libraries in `lib/`.

`make release` makes the same executable without the runtime's symbols and debug information, which take about 5% of
it on macOS, and over half on Linux, with gcc's. `make STATIC=1`
links statically, for an executable that runs anywhere and cannot load libraries.

The JIT maps memory that is writable and executable, so a system that forbids that will not run it.

A checkout also needs what makes the generated files, the Shen kernel and an earlier release of Shen/JIT.
[`make deps`](#building-and-testing) fetches both.

#### On Windows

Shen/JIT builds natively on 64-bit Windows 10 or later, with gcc in [MSYS2](https://www.msys2.org)'s UCRT64
environment:

```sh
pacman -S --needed make diffutils mingw-w64-ucrt-x86_64-gcc
make release stlib    # from a source tarball: build/shen-jit.exe, build/shen-jit-stlib.exe
```

The executable is statically linked and runs from PowerShell or cmd with nothing else installed.

- **Ctrl-C** works as elsewhere. To end the REPL from a console, use Ctrl-Z then Enter, or `(shen-jit.exit 0)`:
  Ctrl-D is not the end of input there.
- **Not available:** `SHEN_JIT_PROFILE`, and scripts that run directly through `#!`.
- **`(get-time run)`** is elapsed time, not processor time.
- **Non-ASCII text** at the console has not been tested.

### First steps

With no arguments, `shen-jit` starts the REPL.

```repl
(0-) (+ 1 2)
3

(1-) (define greet Name -> (cn "hello, " Name))
(fn greet)

(2-) (greet "world")
"hello, world"

(3-) (map (+ 1) [1 2 3])
[2 3 4]
```

Errors name the value they are about, and show where they happened:

```repl
(4-) (define test X Y -> (+ X Y))
(fn test)

(5-) (test 1 "A")
"A" is not a number
  in test
```

- **Ctrl-C** stops a running evaluation, or a program waiting for input, and returns to the prompt. At the prompt
  it drops what you have typed of an expression.
- **Ctrl-D** ends the REPL. On Windows, use Ctrl-Z then Enter, or `(shen-jit.exit 0)`.
- **Line editing:** the REPL has none of its own. For history and arrow keys, run it under
  [rlwrap](https://github.com/hanslub42/rlwrap): `rlwrap shen-jit`.

### Running programs

```sh
shen-jit                               # the REPL
shen-jit script prog.shen a b          # *argv* is ["prog.shen" "a" "b"]
shen-jit eval -l prog.shen -e '(main)' # load a file, evaluate an expression
```

On Windows, the wide command line is converted to UTF-8 before arguments enter Shen, including
programs made with `shen-jit.save-executable`.

The commands come from the kernel's launcher (`shen-jit --help`):

| Command | What it does |
| --- | --- |
| `repl` | The interactive REPL, and the default |
| `script FILE [ARGS]` | Runs FILE, with `*argv*` set to `[FILE \| ARGS]` |
| `eval ARGS` | Evaluates, from left to right: `-e EXPR`, `-l FILE`, `-s KEY VALUE`. `-q` silences output, and `-r` starts the REPL afterwards. `*argv*` has no value here |

An error that nothing catches, or an unknown argument, ends the process with status 1.

Options for Shen/JIT itself go before the command:

| Option | What it does |
| --- | --- |
| `--seal` | Seals user definitions too: see [Sealing](#sealing) |
| `--save IMAGE` | After `eval` or `script` returns, writes the heap to IMAGE, so what they defined loads with the kernel: see [Saving a program](#saving-a-program). `-q` and the script's `*argv*` are not saved |
| `--version` | Prints the version |

A script whose first line starts with `#!` can run directly, with Shen/JIT on your `PATH`, and `load` skips that
line. This does not work on Windows.

```shen
#!/usr/bin/env -S shen-jit script
(output "~A~%" (tl (value *argv*)))
```

### The language

Everything here is standard Shen, and the [Shen site](https://shenlanguage.org) teaches the language. A short
taste, starting with functions defined by pattern matching:

```shen
(define total
  [] -> 0
  [X | Xs] -> (+ X (total Xs)))

(total [1 2 3])    \\ 6
```

Static typing is optional, and `(tc +)` turns it on:

```repl
(0-) (tc +)
true

(1+) (define inc {number --> number} X -> (+ X 1))
(fn inc) : (number --> number)

(2+) (inc 1)
2 : number

(3+) (inc "a")
type error
```

Prolog and a compiler-compiler are built in:

```shen
(defprolog parent
  ann bob <--;
  bob cid <--;)

(defprolog grandparent
  X Z <-- (parent X Y) (parent Y Z);)

(prolog? (grandparent ann cid))    \\ true

(defcc <digits>
  0 <digits> := [0 | <digits>];
  1 <digits> := [1 | <digits>];
  <e> := [];)

(compile (fn <digits>) [1 0 1])    \\ [1 0 1]
```

## Programs

### The standard library

`shen-jit` leaves the kernel's standard library out. `shen-jit-stlib` has it already loaded: maths, rationals,
complex numbers, numerals, lists, strings, vector macros, pretty printing, files and tuples. It is about 2 MB, and
starts in about the same time.

```sh
shen-jit-stlib eval -e '(prime? 7)'    # true
```

The names it exports are system functions, so a program running on it cannot `define` its own `take` or `drop`.
That is why it is not in the default image.

It is the kernel's precompiled `klambda/stlib.kl`, which a source tarball carries as `generated/stlib/stlib.kl`. The kernel's build of that file
leaves out Encrypt, Regex, Calendar, Data and Tk, whose sources are in its `lib/`. Any binary can load that file and
save itself, which is all `make stlib` does. To add a library or a program of your own, see
[Saving a program](#saving-a-program).

```sh
shen-jit script tools/stlib.shen stlib.kl shen-jit-stlib
```

### Saving a program

A program can write its own binary, with nothing but the `shen-jit` it runs on. The result is about 1 MB; 2 on
Linux unless the one running comes from `make release`, as gcc's debug information comes along.

```shen
(define main -> (output "hello ~A~%" (hd (tl (value *argv*)))))
(shen-jit.save-executable "hello" main)
```

```sh
shen-jit eval -q -l hello.shen
./hello world    # hello world
```

- **It runs the entry point,** a function of no arguments, instead of the launcher. All its arguments are its own,
  in `*argv*` after its name, and its exit status is 0 unless it calls `shen-jit.exit` or an error reaches the top.
  With `[]` as the entry point, it keeps the launcher: `repl`, `script`, `eval`.
- **It does not return:** it writes the file and ends the process. The path is relative to `*home-directory*`, as
  `open`'s is.
- **All the heap lasts:** definitions, globals, property lists, macros, datatypes and type signatures, so code
  loaded later type checks against them. The stack and open files do not, and `*home-directory*` starts empty.
- **It runs only on the kind of system it was made on.** It holds bytecode, compiled to native code on first call
  as always.
- **On macOS** it keeps the linker's ad-hoc signature, which runs. `codesign --verify` rejects it, as it does
  `shen-jit`, for the image appended to the runtime, which matters only for notarized distribution.

To save the heap as an image instead, without an executable:

```sh
shen-jit --save app.img eval -q -l app.shen
SHEN_JIT_IMAGE=app.img shen-jit eval -e '(main)'
```

An image starts with your program already loaded, and loads only into the build that wrote it. After a build from
source, one appended to the runtime makes an executable of its own:

```sh
cat build/runtime app.img > app && chmod +x app
./app eval -e '(main)'
```

### Threads

`(thread Frozen)` runs a frozen expression in a new thread and returns `true`, as programs written for Shen/Scheme
expect. Threads are real, and one runs at a time, holding a global lock. So they give concurrency, for work that
waits or runs beside the main program, and no speed-up from more cores.

```shen
(set done false)
(define work 0 -> (set done true) N -> (work (- N 1)))
(thread (freeze (work 1000000)))

(define wait -> (if (value done) finished (wait)))
(wait)    \\ finished
```

- **Switching:** every 10 ms if another thread is waiting, at a function's entry or a loop's next turn, and whenever
  a thread waits for input on stdin or a socket. Between those points no other thread runs, though a program should
  not count on where they fall.
- **Errors:** one that nothing catches ends its thread and is printed to stderr. The other threads go on.
- **The end:** the process ends when the main thread does, or when any thread calls `(shen-jit.exit N)`. An image
  saved with `--save` holds what the main thread reaches, and `shen-jit.save-executable` refuses to run while other
  threads do.
- **Ctrl-C** at the REPL stops the main thread's work, and threads beside it go on.
- **Not provided,** as in Shen/Scheme: join, mutexes and channels. A thread signals another through a global, which
  the other can spin on, as above.
- **Waiting elsewhere:** reading a file that blocks, such as a FIFO, holds the lock, and Ctrl-C does not end that
  wait.
- **Cost:** nothing until the first thread starts. All code then compiles again on its next call, with a test at
  each loop's turn. The time is shared with the threads that are running.

### Sealing

Kernel and port functions are sealed: calls to them are direct, and redefining one raises an error:
`F is sealed and cannot be redefined`, or for the names the kernel exports, `F is a system function`. Your definitions are open: you can redefine them at any time, and their
callers see the new definition.

With `--seal`, `SHEN_JIT_SEAL=1` or `(shen-jit.seal +)`, new definitions are sealed too, so calls to them are
direct, and they cannot be redefined. `(shen-jit.seal -)` turns that off. This gains little, as open calls are
inlined too, and patched when a function is redefined.

## Managed structs

`defstruct` replaces numbered `absvector` slots with named fields and ordinary generated functions.
It is available at startup. In a source file:

```shen
(defstruct entry key (mutable value))
(define value-of (:entry value <- V ...) -> V)
(let E (:entry value <- 42 key <- "answer")
  (do (entry.value-> E 43) (value-of E)))    \\ 43
```

`(:entry f <- V ...)` constructs a record with labelled fields in any order, and as a pattern matches
one, with `...` leaving out the fields it does not name. One function can match records of several
structs, a clause each, and `(struct.union shape circle rect)` makes such a set a type for typed code.

Fields are read-only by default; mutable fields get `->` setters that return the record. Fields may have
types, `(x : number)`, which typed code then checks. A record prints
as `#<entry key: "answer" value: 43>`, or through a function of its own, `(printer F)`. Construction
allocates one managed vector and can trigger GC; field reads and writes allocate nothing on success.
The [struct reference](https://github.com/tizoc/shen-jit/blob/main/docs/structs.md) covers positional
constructors, construction and matching, namespace exports, reload rules and the current limitations.

## Libraries

The libraries in `lib/` are not in the image. A program loads those it uses by their paths in the archive or source
tree, each after the ones it builds on, and a [saved program](#saving-a-program) keeps them. Each library's page
begins with the line that loads it, such as:

```sh
shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen -l program.shen
```

The libraries use namespaces. Their existing qualified names work directly, and a namespace client can
use prefixes or import their exported names:

```shen
(shen.x.namespace example.bytes
  (use buffer => b)
  (use cursor => c)
  (export first-byte)

  (define first-byte Text -> (c.read (c.new (b.from-string Text)))))

(example.bytes.first-byte "A")    \\ 65
```

Exports include the public operations and types, and the support operations shared by libraries, such as
`buffer.check` and `io.record`. HTTP, I/O and subprocess libraries contribute to their respective namespaces
across several files. `lib/native.shen` and `lib/ffi.shen` extend the runtime's `shen-jit` namespace, which stays open.

Namespace qualification applies to symbols in data too. Preserve a DSL's keywords with `with-externals`
around its form, while its definition names and references still resolve normally:

```shen
(shen.x.namespace example.numeric
  (export sum-to)

  (with-externals [define-native word for return-word]
    (define-native sum-to (N)
      (word Acc 0)
      (for I 0 N (word Acc (+ Acc I)))
      (return-word Acc))))
```

Load `lib/native.shen` before reading that example. Result tags and options keep their original symbols,
such as `[ok Value]`, `io-error` and `chunk-size`. A namespace client must preserve such vocabulary with
`externals` or import it when the library exports it. `shadow` makes a system name local to a namespace;
the libraries use it where a local operation would otherwise resolve to a kernel or stlib function.

Most of them call C through [the FFI](#calling-c), which a static Linux build cannot do. There, buffers and cursors,
grammars, JSON, I/O over memory, framing and Datalog still work.

Four have a small C adapter of their own as well, which a C compiler builds once: filesystem operations, subprocesses,
Tree-sitter, which also needs Tree-sitter 0.25 or later and a grammar compiled for it, and curl, which needs libcurl.
`make fs`, `make process`, `make tree-sitter` and `make curl` build them in a checkout, and in a binary archive
`sh lib/build-NAME.sh lib/shen-NAME.so` does, with `.dll` in place of `.so` on Windows. Loading the library never
compiles its adapter: it looks for it in `build/`, `lib/` and the current directory, or where its `*adapter-files*`
says, if that is set before loading.

### Bytes and parsing

[Buffers and cursors](https://github.com/tizoc/shen-jit/blob/main/docs/buffers.md): `lib/buffer.shen` gives checked
views over a range of a byte buffer or of [memory outside the heap](#memory-outside-the-heap), which copy and compare,
and `lib/cursor.shen` positions in them that move as they read. The libraries below read and write through such views.

[Grammars over bytes](https://github.com/tizoc/shen-jit/blob/main/docs/grammar.md): `lib/grammar.shen` adds
`defgrammar`, Shen-YACC's notation for parsers over views, compiled to the loops a scanner written by hand would use.
A grammar can have types, as `defcc` does, and `grammar.read` parses from an I/O reader as the bytes arrive.

[JSON](https://github.com/tizoc/shen-jit/blob/main/docs/json.md): `lib/json.shen` decodes JSON from views and encodes
it into them, with strict UTF-8, numbers kept as written until converted exactly, and limits on what it reads and
writes. It needs `lib/grammar.shen` loaded first.

[Tree-sitter bindings](https://github.com/tizoc/shen-jit/blob/main/docs/tree-sitter.md): `lib/tree-sitter.shen` parses
source code in a language that has a Tree-sitter grammar into a syntax tree, and runs structural queries over it,
within limits on nodes, captures and time.

### Input and output

[Chunk I/O](https://github.com/tizoc/shen-jit/blob/main/docs/io.md): `lib/io.shen` gives readers and writers with
buffers of a size they are given, over memory, and `lib/io-file.shen` over files, apart from Shen's streams. Each
operation gives its result or its error as a value, a short transfer keeps what it moved, and a writer flushes as it
closes.

[Binary framing](https://github.com/tizoc/shen-jit/blob/main/docs/framing.md): `lib/frame.shen` reads binary messages
of a bounded size through those readers, across chunks.

[Operation deadlines](https://github.com/tizoc/shen-jit/blob/main/docs/deadlines.md): `lib/deadline.shen`, with
`lib/clock.shen`, gives a whole operation a time budget on the monotonic clock, which its retries share.

[Filesystem operations](https://github.com/tizoc/shen-jit/blob/main/docs/fs.md): `lib/fs.shen` adds paths, metadata,
sorted directory listings and traversal within limits, exclusive temporary files and directories, renaming that
never overwrites, replacing a file whole, and copying through the I/O library, which `tools/fs-copy.shen` does.

[Subprocesses and pipelines](https://github.com/tizoc/shen-jit/blob/main/docs/processes.md): `lib/process.shen` and
`lib/process-io.shen` start programs with explicit arguments, environment and working directory, talk to them over
pipes through the I/O library, within limits on waits and output, join them into pipelines, and clean up after them,
with their process groups or jobs. `tools/process-filter.shen` writes a command's output to a file only once the
command has exited with 0.

#### Sockets

`lib/socket.shen` is TCP, over IPv4 and IPv6, written over [the FFI](#calling-c) in Shen alone.

```shen
(let S (socket.connect "example.com" 80)
  (do (socket.send S "GET / HTTP/1.0c#13;c#10;c#13;c#10;")
      (output "~A~%" (socket.recv-string S 4096))
      (socket.close S)))
```

```sh
shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l program.shen
```

A server, in a thread, with a client beside it:

```shen
(set l (socket.listen "127.0.0.1" 0))

(thread (freeze (let S (socket.accept (value l))
                  (do (socket.send S (socket.recv S 100))
                      (socket.close S)))))

(let C (socket.connect "127.0.0.1" (socket.port (value l)))
  (do (socket.send C "hello")
      (output "~A~%" (socket.recv-string C 100))    \\ hello
      (socket.close C)))
```

| Function | What it does |
| --- | --- |
| `(socket.connect Host Port)` | Tries each address the name has |
| `(socket.listen Host Port)`, `(socket.port S)` | Port 0 means any free one, and `socket.port` says which |
| `(socket.accept Listener)` | Waits for a client, and gives its socket |
| `(socket.send S Data)` | Sends all of a string or byte buffer |
| `(socket.recv S N)` | Waits for data, and gives a buffer of at most N bytes. An empty one means the other end has finished |
| `(socket.recv-into S B)`, `(socket.recv-string S N)` | Fills what it can of a buffer and says how much, and the same as `socket.recv` as a string |
| `(socket.readable? S Ms)` | Whether there is something to read, waiting that long at most |
| `(socket.shutdown S)`, `(socket.no-delay S)`, `(socket.close S)` | Tells the other end nothing more will be sent, sends small writes at once, and closes |

A socket is an integer. Waiting lets other threads run, and Ctrl-C at the REPL ends it. A send to a closed connection
raises instead of ending the process. The comments at the top of the file list every function.

[Socket I/O endpoints](https://github.com/tizoc/shen-jit/blob/main/docs/io-sockets.md), `lib/io-socket.shen`, put a
connection behind the I/O library's readers and writers, with deadlines.

### HTTP

`lib/http-*.shen` are HTTP/1.1 over the I/O library and sockets.
[HTTP head framing](https://github.com/tizoc/shen-jit/blob/main/docs/http-head.md) reads a head within a size limit,
keeping the bytes of the body that came with it.
[HTTP requests and responses](https://github.com/tizoc/shen-jit/blob/main/docs/http.md) parses requests, reads bodies
by Content-Length or chunked, within limits, with trailers kept apart, and encodes responses.
[Streaming HTTP responses](https://github.com/tizoc/shen-jit/blob/main/docs/http-streaming.md) writes a response as it
is made, with a length or chunked.
[Bounded HTTP servers](https://github.com/tizoc/shen-jit/blob/main/docs/http-listener.md) accept connections up to a
limit, keep them for later requests within limits, and shut down when asked. Ambiguous framing is refused.

[HTTP clients with libcurl](https://github.com/tizoc/shen-jit/blob/main/docs/curl.md): `lib/curl.shen` makes HTTP and
HTTPS requests through libcurl, with reusable clients, binary bodies, headers and trailers, timeouts, TLS
verification and a limit on redirects, and can stream a response into an I/O writer. `tools/curl-fetch.shen`
downloads to a file with it.

### Data

[Datalog](https://github.com/tizoc/shen-jit/blob/main/docs/datalog.md): `lib/datalog.shen` evaluates relations, facts
and recursive rules bottom up, to a fixed point, over symbols, strings, integers and records, with each rule compiled
through the JIT and its join order chosen from the sizes of the relations as it runs, and answers a query by deriving
only what bears on it.

#### SQLite

`lib/sqlite.shen` is written over [the FFI](#calling-c), in Shen alone. It needs SQLite's library, which macOS and
Windows 10 have, and most Linux systems do.

```shen
(let Db (sqlite.open "people.db")
  (do (sqlite.exec Db "CREATE TABLE IF NOT EXISTS people (name TEXT, age INTEGER)")
      (sqlite.run Db "INSERT INTO people VALUES (?, ?)" ["Ann" 30])
      (output "~S~%" (sqlite.query Db "SELECT name, age FROM people WHERE age > ?" [20]))
      (sqlite.close Db)))    \\ [["Ann" 30]]
```

```sh
shen-jit eval -l lib/ffi.shen -l lib/sqlite.shen -l people.shen
```

| Function | What it does |
| --- | --- |
| `(sqlite.open Path)`, `(sqlite.close Db)` | `":memory:"` is a database in memory. Closing raises if a statement is still open |
| `(sqlite.exec Db Sql)` | Runs statements with no parameters or results |
| `(sqlite.run Db Sql Params)` | Runs one, and gives the rows it changed |
| `(sqlite.query Db Sql Params)` | Gives its rows, each a list |
| `(sqlite.each Db Sql Params F)` | Calls F on each row, keeping none |
| `(sqlite.transaction Db (freeze ...))` | Commits, or rolls back on an error |
| `(sqlite.last-insert-id Db)`, `(sqlite.version)` | The last row inserted, and the library's version |

To use a statement many times: `sqlite.prepare`, `sqlite.bind`, `sqlite.step`, which gives `row` or `done`,
`sqlite.row`, `sqlite.reset` and `sqlite.finalize`. The comments at the top of the file list every function.

Values go in and come out as Shen values: a number is an INTEGER or a REAL, a string is TEXT, a byte buffer is a
BLOB, and `[]` is NULL. `true` and `false` go in as 1 and 0. Errors raise, with SQLite's message. A connection belongs
to one thread: other threads run while a query does, and some builds of SQLite, Apple's among them, do not allow two
threads on one.

### Example applications

Each is in `example-apps/`, with a README and a test of its own, and in the release archives.

- [`sqlite-http`](https://github.com/tizoc/shen-jit/blob/main/example-apps/sqlite-http/README.md): a counter served
  over HTTP from SQLite, which takes JSON bodies and streams NDJSON exports.
- [`depends`](https://github.com/tizoc/shen-jit/blob/main/example-apps/depends/README.md): a dependency analyser over
  Shen and KL source files, built over Datalog as one executable: what calls what, cycles between files, dead code
  from roots, call depths, and why one function reaches another.
- [`source-facts`](https://github.com/tizoc/shen-jit/blob/main/example-apps/source-facts/README.md): walks a directory
  of C with Tree-sitter and writes NDJSON facts about its files, function definitions and calls. Given a compilation
  database, it preprocesses each file as the build does.
- [`source-deps`](https://github.com/tizoc/shen-jit/blob/main/example-apps/source-deps/README.md): reads those facts
  into Datalog, matches calls with definitions, and answers which functions one reaches and which depend on it.

Smaller examples are in `tools/`, each on the page of the libraries it uses.

## Close to the machine

### Bytes and bits

Primitives for raw bytes, with every access checked. The collector frees the buffers, and saved executables keep
them.

```shen
(define fnv1a
  _ I I H -> H
  B I N H -> (fnv1a B (+ I 1) N
               (shen-jit.bit-and (* (shen-jit.bit-xor H (shen-jit.u8 B I)) 16777619) 4294967295)))

(let B (shen-jit.string->bytes "a")
  (fnv1a B 0 (shen-jit.bytes-length B) 2166136261))    \\ 3826002220
```

| Function | What it does |
| --- | --- |
| `(shen-jit.bytes N)` | A new buffer of N zero bytes |
| `(shen-jit.bytes? X)`, `(shen-jit.bytes-length B)` | Whether X is a buffer, and B's length |
| `(shen-jit.u8 B I)`, `u16`, `u32` | The unsigned value at byte offset I, little-endian, at any alignment |
| `(shen-jit.s32 B I)`, `s64` | The signed value there. An `s64` that does not fit a fixnum raises |
| `(shen-jit.f32 B I)`, `f64` | The floating-point value there, as a new real |
| `(shen-jit.u8! B I X)`, `u16!`, `u32!`, `s32!`, `s64!` | Stores X at I and returns B. X must fit |
| `(shen-jit.f32! B I X)`, `f64!` | Stores a number at I, rounded to fit, and returns B |
| `(shen-jit.string->bytes S)` | A new buffer with S's bytes |
| `(shen-jit.bytes->string B I N)` | A new string of the N bytes from I |
| `(shen-jit.copy-bytes To I From J N)` | Copies N bytes from J in From to I in To, which may overlap, and returns To |
| `(shen-jit.write-bytes B I N S)` | Writes the N bytes from I to the output stream S at once, and returns N |

On a fixnum's 62 bits: `shen-jit.bit-and`, `bit-or`, `bit-xor`, `bit-not`, `shift-left`, `shift-right`, `rotate32`,
`bswap32`, `popcount`, `clz` and `ctz`.

[docs/bytecode.md](https://github.com/tizoc/shen-jit/blob/main/docs/bytecode.md), "Byte buffers and bit operations",
has the details.

### Calling C

`lib/ffi.shen` lets Shen call plain C functions, with nothing to compile. It is not in the image, and has to be
loaded before the code that uses it, as a macro applies only to files read after it is defined.

```shen
(shen-jit.library libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
(define-foreign c-cos libm "cos" (double) --> double)

(output "~A~%" (c-cos 0))    \\ 1.0
```

```sh
shen-jit eval -l lib/ffi.shen -l cos.shen
```

A library is a symbol and the file names to try, in order. `[]` means the executable and what it links, which on
Windows reaches nothing, as the executable is static. A static Linux build cannot load libraries, and says so.

| Type | As an argument | As a result |
| --- | --- | --- |
| `int64` | A fixnum | Raises if it does not fit 62 bits |
| `int32`, `uint32` | A fixnum in range | The low 32 bits, sign- or zero-extended |
| `double` | A real or a fixnum | A new real |
| `string` | Copied for the call, and a NUL inside raises | Copied into a new string, and NULL is `[]` |
| `pointer` | A pointer of any kind, or `[]` for NULL | A pointer of kind `pointer`, and NULL is `[]` |
| `bytes` | The address of a byte buffer, for the call | Not allowed |
| `bool` | `true` or `false` | The low byte alone |
| `void` | Not allowed | `[]` |

> C's `int` is `int32`. A function returning `int` leaves the upper half of the result register undefined, so
> declaring it `int64` reads garbage. There is deliberately no type called `int` or `long`, as `long` is 32 bits on
> Windows and 64 elsewhere.

A function takes at most 6 arguments that are not doubles and 8 that are, and no structs by value. After the result,
two flags:

- **`blocking`** gives up the lock during the call, so other threads run. Its byte buffers are copied and back, as
  another thread's collection may move them.
- **`(varargs N)`** marks a variadic function with N fixed arguments, from 1 to 3, all integers.

```shen
(define-foreign c-recv sockets "recv" (int32 bytes int64 int32) --> int32 blocking)
(define-foreign c-fcntl sockets "fcntl" (int32 int32 int32) --> int32 (varargs 2))
```

Functions are found at their first call, so a saved program finds them again. One that cannot be found raises
`foreign: cannot find cos in libm`. `(shen-jit.errno)` is what the last call on this thread left in `errno`, or on
Windows in `GetLastError`, where `(shen-jit.c-errno)` is the C library's.

[Calling C in full](https://github.com/tizoc/shen-jit/blob/main/docs/ffi.md) has the rest, and how it works.
[Sockets](#sockets) and [SQLite](#sqlite) are larger examples, written over it in Shen alone.

#### Pointers

A pointer has a kind, a symbol, for reading and for messages. `=` compares kind, address and whether it is read only,
and one prints as
`#<pointer sqlite3 0x...>`. One saved in an image is dead there, and raises when given to C.

| Function | What it does |
| --- | --- |
| `(shen-jit.pointer? X)` | Whether X is a pointer |
| `(shen-jit.pointer-kind P)`, `(shen-jit.pointer-address P)` | Its kind, and its address as a fixnum |
| `(shen-jit.bytes->pointer B I Kind)` | The pointer at offset I in a buffer, for out-parameters, and `[]` if NULL |
| `(shen-jit.pointer->string P)` | Copies the NUL-terminated string it points to |
| `(shen-jit.pointer->bytes P I N)` | Copies N bytes from offset I. It cannot check them |
| `(shen-jit.pointer-kill P)` | For a library, once C has freed what P points to: P then raises when given to C or read |
| `(shen-jit.pointer-sized P N)` | A new pointer to the same address, whose N bytes can be read and written, and which keeps P alive: see [Memory outside the heap](#memory-outside-the-heap) |
| `(shen-jit.pointer-read-only P)` | A new pointer to the same memory, which raises when stored to, as any copy of it does |
| `(shen-jit.pointer! B I P)` | Stores a pointer's address at offset I, or NULL for `[]`, and returns B |

In typed code, a declaration whose types are all plain Shen types, and whose result cannot be NULL, can be called at
once. Others are for the program to `declare`, under `(tc -)`.

### Memory outside the heap

A byte buffer lives in the Shen heap, where the collector may move it. Memory outside the heap stays where it is, so C
can keep its address, a `blocking` call needs no copy, and the collector never copies or scans it, however large.

It is a pointer with a length. A pointer from C has none, and cannot be read until you state how many bytes it reaches.
Then it works with what works on a byte buffer, in place, each access checked against that length:

```shen
\\ struct point { double x, y; int32_t id; };   /* 24 bytes */
(define-foreign make-points mine "make_points" (int32) --> pointer)
(define-foreign free-points mine "free_points" (pointer) --> void)

(let P (make-points 1000)
     M (shen-jit.pointer-sized P 24000)
  (do (shen-jit.f64! M 72 1.5)                                     \\ x of point 3
      (output "~A ~A~%" (shen-jit.f64 M 72) (shen-jit.s32 M 88))   \\ and its id
      (shen-jit.pointer-kill M)
      (free-points P)))
```

`lib/memory.shen` allocates it, in Shen alone. Give it to C as a `pointer`:

```shen
(define-foreign c-read libc "read" (int32 pointer int64) --> int64 blocking)

(let M (memory.alloc 1073741824)    \\ 1 GB, all zero
  (do (c-read Fd M 1073741824)
      (output "~A~%" (shen-jit.u32 M 0))
      (memory.free M)))
```

```sh
shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l program.shen
```

- **Nothing frees it for you,** unless you ask for that below. `memory.free` frees and kills it, and forgetting to leaks,
  as in C.
- **The length you state is trusted,** and it is the one thing not checked. A wrong one, or memory C has freed, can
  crash. Kill a pointer once its memory is gone, so that using it raises.
- **Each sized pointer stands alone.** Killing one kills no other, nor the pointer it came from.
- **A saved image holds it dead,** and the memory itself is not saved: a byte buffer is what lasts in an image.
- **The same code works on both.** `u8`, `u16`, `u32`, `s32` and `f64`, and the stores `u8!`, `u16!`, `u32!` and `f64!`,
  compile inline for a buffer and for a pointer. The others call C for both.

#### Files as memory

`lib/mmap.shen` gives all of a file as such a pointer, on each system, in Shen alone. Nothing is read until it is touched:

```shen
(let M (mmap.read "data.bin")
  (do (output "~A bytes, starting ~A~%" (shen-jit.bytes-length M) (shen-jit.u8 M 0))
      (mmap.close M)))
```

```sh
shen-jit eval -l lib/ffi.shen -l lib/mmap.shen -l program.shen
```

| Function | What it does |
| --- | --- |
| `(mmap.read Path)` | All of a file, read only |
| `(mmap.read-write Path)` | All of a file, where what is written reaches the file |
| `(mmap.create Path N)` | A new file of N zero bytes, replacing any there, as `mmap.read-write` |
| `(mmap.close M)` | Unmaps it and kills M |

An empty file cannot be mapped, and raises, and so does a store into what `mmap.read` gives. One thing no check can catch
ends the process: an access past the end of a file that something has since made shorter.

#### Memory that releases itself

`lib/handle.shen` wraps such memory in a handle, which reads and writes the same bytes, and releases it once nothing
reaches the handle:

```shen
(define buffer
  N -> (handle.wrap (memory.alloc N) (/. M (memory.free M))))

(define mapped
  Path -> (handle.wrap (mmap.read Path) (/. M (mmap.close M))))
```

```sh
shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l lib/mmap.shen -l lib/handle.shen -l program.shen
```

- **It is released some time later:** in the next `handle.wrap` or `(handle.sweep)` after a collection finds it dead, and
  not at all if the program ends first, which leaves it to the system. Handles count what they hold, so that memory
  outside the heap brings collections too.
- **`(handle.close H)` releases it now,** for what should not wait: on Windows, a mapped file cannot be deleted. H then
  raises when used, and closing it again does nothing.
- **A copy from `shen-jit.pointer-sized` keeps its handle alive,** until the handle is closed, after which it must not be
  used.
- **The function that releases it must not refer to the handle,** or the handle will never die.

### C written for Shen

C can also take and return Shen values and call Shen, with
[`include/shen.h`](https://github.com/tizoc/shen-jit/blob/main/include/shen.h). It links against nothing, as the
runtime hands it a table of functions.

```c
#include "shen.h"

shen_value sum_list(shen_vm *vm, shen_value *args)
{
    int64_t sum = 0;
    for (shen_value l = args[0]; shen_is_pair(vm, l); l = shen_tail(vm, l)) {
        shen_value x = shen_head(vm, l);
        if (!shen_is_fixnum(x))
            return shen_raise_value(vm, "sum_list: ~S is not an integer", x);
        sum += shen_fixnum(x);
    }
    return shen_make_fixnum(sum);
}
```

```sh
cc -shared -fPIC -I include -o libmine.so mine.c
```

```shen
(shen-jit.library mine ["./libmine.so" "./libmine.dylib" "mine.dll"])
(define-foreign-procedure sum-list mine "sum_list" 1)

(sum-list [1 2 3])    \\ 6
```

- **Values** are valid until the next call that may allocate, unless in a root: `shen_root(vm, &local)` for a call, or
  `shen_root_new` for longer. Reads do not allocate, so the loop above needs no root.
- **Errors** come back by value, as `SHEN_ERROR`. `shen_call` calls Shen, and no `longjmp` crosses C, so a C library
  calling back is safe.
- **Waiting:** `shen_release` and `shen_acquire` let other threads run while C waits.
- **Limits:** up to 8 arguments, and a thread the runtime did not start cannot call in.

> Test with `SHEN_JIT_GC_STRESS=1`, which collects at every allocation and finds most mistakes with values. `shen.h`
> opens with the rules. **This API is not stable until 1.0:** it may change before then, and `SHEN_API_VERSION` says
> when it has.

### Native code by hand

`lib/native.shen` lets a program write a procedure in Shen/JIT's own instructions, choosing its slots, branches and
calls, and the JIT compiles it like any other. It is not in the image, and has to be loaded before the code that uses
it, under `(tc -)`.

```shen
(define-native sum-list (Xs Acc)
  (prim T cons? Xs)
  (jump-if-false T done)
  (prim H hd Xs)
  (prim Acc + Acc H)
  (prim Xs tl Xs)
  (tail-call sum-list Xs Acc)
  (label done)
  (return Acc))

(sum-list [1 2 3] 0)    \\ 6
```

```sh
shen-jit eval -l lib/native.shen -l sum.shen
```

A variable is a slot, a symbol is itself, and `[1 2]` is a list. The code is checked first, by the rules the lowerer's
own output is held to, so wrong code is refused instead of crashing. A program generating code at run time passes
lists to `shen-jit.assemble` and `shen-jit.install-code`. Slots hold tagged values, as in all Shen code, and
[bytes and bits](#bytes-and-bits) and [memory outside the heap](#memory-outside-the-heap) are primitives here as anywhere.

For numeric work, `real` keeps doubles unboxed in registers, in code that calls nothing. It reads an expression. `word`
does the same for 64-bit integers, which wrap, for hashes and random numbers, and as an index, which then has no tag to
check. `(loop L)` marks the head of a loop and `(again L)` goes back to it, and loops can nest:

```shen
(define-native dot (A B End)
  (real Acc 0)
  (word I 0)
  (loop terms)
  (jump-unless-word (< I End) done)
  (real Acc (+ Acc (* (f64 A I) (f64 B I))))
  (word I (+ I 8))
  (again terms)
  (label done)
  (return-real Acc))
```

Every read and store is still checked against its memory's length, and nothing in these loops allocates until
`return-real` boxes the result. Machine registers go to what the deepest loops use most, whatever the order of the names.
Nothing is moved out of a loop for you, nor is a repeated expression noticed, so a literal or a conversion that a loop
uses each time round is worth a name before it, and a value a statement uses twice is worth a name too. An FNV-1a hash, say, is a loop of wrapping multiplications:

```shen
(define-native fnv (Bytes End)
  (word Prime 1099511628211)
  (word Hash (+ (* 3421674724 4294967296) 2216829733))
  (word I 0)
  (loop bytes)
  (jump-unless-word (< I End) done)
  (word Hash (* (bit-xor Hash (u8 Bytes I)) Prime))
  (word I (+ I 1))
  (again bytes)
  (label done)
  (return-word (shift-right Hash 8)))
```

`if`, `when`, `unless`, `while`, `for`, `block`, `exit` and `next` write the same loops without labels: they become
them, so the code that runs is the same. The hash again:

```shen
(define-native fnv (Bytes End)
  (word Prime 1099511628211)
  (word Hash (+ (* 3421674724 4294967296) 2216829733))
  (for I 0 End
    (word Hash (* (bit-xor Hash (u8 Bytes I)) Prime)))
  (return-word (shift-right Hash 8)))
```

[docs/bytecode.md](https://github.com/tizoc/shen-jit/blob/main/docs/bytecode.md), "Native code written by hand", has
the instructions and these forms.

## Reference

### Debugging

An error that nothing catches prints a backtrace, even through inlined functions:

```text
shen-jit: uncaught error: hd: 1 is not a pair
  in inner
  in outer
```

| Function | What it does |
| --- | --- |
| `(shen-jit.backtrace)` | The names of the active functions, innermost first |
| `(shen-jit.code F)` | The bytecode of F, a function defined after startup |
| `(shen-jit.collect)` | Collects now |
| `(shen-jit.exit N)` | Ends the process with exit status N |

```repl
(0-) (define twice X -> (+ X X))
(fn twice)

(1-) (shen-jit.code twice)
[defun twice [code twice 1 4 [] [[prim 3 + 2 2] [return 3]] [] [[V8] [+ V8 V8]]]]
```

The kernel's `track`, `spy` and `step` work as in other ports. For where the time goes, `SHEN_JIT_PROFILE=1` prints a
flat profile at exit, and `SHEN_JIT_STATS=1` prints the collector's work and the live heap by type.

### Environment variables

| Variable | What it does |
| --- | --- |
| `SHEN_JIT_IMAGE` | An image to load instead of the executable's own |
| `SHEN_JIT_SEAL=1` | The same as `--seal` |
| `SHEN_JIT_SEMISPACE=SIZE` | Starts the heap at SIZE bytes (with K, M or G; anything that is not a size is refused) instead of 32 MB, or at what the image needs if that is more: what a collection keeps and the room for new objects add up to this. It still grows with live data, up to 64 GiB, or stays at SIZE if that is more. Less collects more often and uses less memory |
| `SHEN_JIT_MAX_HEAP=SIZE` | Limits the heap to SIZE bytes (with K, M or G; at least the initial semispace; anything that is not a size is refused). What the heap holds stays below SIZE, and an allocation past that raises `out of memory`. The collector copies, so the process can use two to three times SIZE: vectors and strings of 256 KB or more stay apart, uncopied, and count once |
| `SHEN_JIT_PROFILE=1` | Samples the program and prints a flat profile to stderr at exit, naming both Shen and C functions. Not on Windows |
| `SHEN_JIT_STATS=1` | Prints collection statistics, the live heap and its roots, and the native code compiled and freed, at exit |
| `SHEN_JIT_PERF_MAP=1` | Writes `/tmp/perf-PID.map`, so external profilers can name compiled code |
| `SHEN_JIT_GC_STRESS=N` | Collects after every N words allocated and overwrites the old space, for testing |
| `SHEN_JIT_SLOW_PRIMS=1` | Sends every primitive to C, for testing |

`SHEN_JIT_PROFILE`, `SHEN_JIT_STATS`, `SHEN_JIT_PERF_MAP` and `SHEN_JIT_SLOW_PRIMS` are on when set to anything, even 0.

### Differences from Shen/Scheme

- **No stlib in the default image.** Only the kernel and its extensions for features, programmable pattern matching, namespaces and the launcher are in use: see
  [The standard library](#the-standard-library).
- **Fixnums only.** Integers are 62-bit, and a result outside that range raises `integer overflow`.
- **Sealing.** Internal kernel functions cannot be redefined, where Shen/Scheme accepts such definitions.
- **Numbers hash by value.** A real and an integer that are `=` have the same `hash`, where Shen/Scheme's tells them apart.
- **Threads run one at a time,** where Shen/Scheme's run in parallel.
- **On Windows,** a few things differ: see [On Windows](#on-windows).

[docs/semantics.md](https://github.com/tizoc/shen-jit/blob/main/docs/semantics.md) defines the behaviour in full, and
marks each difference with *Deviation*.

### Building and testing

From a checkout, `make deps` fetches the pinned Shen kernel release and an earlier release of Shen/JIT into `.deps/`,
checked by hash. The kernel archive includes precompiled KLambda, sources and tests. CI downloads the same release
for each platform.

The earlier Shen/JIT release runs only to generate the files a source tarball already carries. It has executables for the platforms in
[Install](#install), and on Windows `make deps` also needs `unzip`. Elsewhere, use a source tarball, or set `BOOTSTRAP`
to a Shen of your own.

```sh
git clone https://github.com/tizoc/shen-jit
cd shen-jit
make deps
make
```

This writes `build/shen-jit`, a single file that carries its own image.
[docs/design.md](https://github.com/tizoc/shen-jit/blob/main/docs/design.md#build-stages-and-startup) explains the
stages.

[Shen/Scheme](https://github.com/tizoc/shen-scheme) can take that release's place, for a way in that does not start
from Shen/JIT. It makes the same generated files, byte for byte, which `check-generated` shows:

```sh
sh tools/ci-deps.sh shen-scheme .deps/shen-scheme
make BOOTSTRAP=.deps/shen-scheme/bin/shen-scheme check-generated all
```

These can be set on the command line, or in a file `local.mk`, which git ignores:

| Variable | Default | What it is |
| --- | --- | --- |
| `BOOTSTRAP` | `.deps/shen-jit/shen-jit` | The Shen that makes the generated files |
| `SHEN_SCHEME` | `.deps/shen-scheme/bin/shen-scheme` | Shen/Scheme, for `make bench` and `make bench-independent` |
| `KERNEL_KL` | `.deps/kernel/klambda` | The kernel's KLambda files |
| `KERNEL_DIR` | `.deps/kernel` | The kernel, for `make test-kernel`, `make test-thorn`, `make test-overrides` and `make bench-independent` |
| `BENCH_DIR` | `.deps/shen-scheme-src` | Shen/Scheme's sources, for `make bench` |
| `STLIB_DIR` | none | The standard library's sources, for `make bench-independent`, which leaves that workload out without them |

`make bench` also needs Shen/Scheme, as above, and `sh tools/ci-deps.sh shen-scheme-src .deps/shen-scheme-src` fetches
its sources.

`make test-core` checks the runtime, the compiler and the port, in about 20 s, and `make test-libs` the libraries,
in about 30 s:

```sh
make test-core test-libs
```

Run `make deps-tree-sitter` once for the optional binding's pinned native test dependencies, or set
`TREE_SITTER_SOURCE` and `TREE_SITTER_C_SOURCE` to existing source roots. Tests do not download them.

| Target | What it does |
| --- | --- |
| `make test-core` | `test`, `test-jit`, `test-ops`, `test-kl`, `check-lowerer`, `check-generated`, `test-kernel`, `test-stlib`, `test-thorn`, `test-native`, `test-ffi`, `test-overrides` and `test-structs` |
| `make test-libs` | `test-buffer`, `test-json`, `test-io`, `test-fs`, `test-process`, `test-tree-sitter`, `test-http`, `test-datalog`, `test-curl` and `test-namespaces` |
| `make test` | The runtime's unit tests |
| `make test-jit`, `make test-ops` | The JIT and the instructions, on small programs |
| `make test-kl` | The `eval-kl` cases, and the lowerer running inside Shen/JIT against its stage 0 output |
| `make test-kernel` | The kernel's test suite, the extension tests, the contract examples and `tests/cli.sh` |
| `make test-stlib` | The executable with the standard library |
| `make test-thorn` | THORN, from the kernel, with no time limit: its inference counts and what goes unproved, as on Shen/Scheme |
| `make test-native` | Native code written by hand: what runs, and what must be refused |
| `make test-structs` | Managed records, mutation, labelled evaluation order, namespace aliases, declaration validation and saved images in both executables |
| `make test-namespaces` | Library exports, aliases, imports, types and scoped DSL vocabulary in the base and stlib executables, and in their saved images |
| `make test-json` | JSON syntax/encoding, Unicode, exact numbers, builders, typing and images/GC |
| `make test-buffer` | Buffer/cursor bounds, copying, foreign lifetime, typed clients, format examples, grammars, typed grammars and images/GC |
| `make test-io` | Bounded chunk I/O, binary files and framing, socket endpoints/echo, native lifetimes, typed results and images/GC |
| `make test-http` | Request/response framing, streaming, persistent connections, shutdown, SQLite example, typing and images/GC |
| `make test-datalog` | Datalog answers/errors/generated programs against its plain evaluator; Shen/KL dependency analysis and source-fact matching/reach/impact with independent graph oracles |
| `make test-datalog-swipl` | The same generated programs against SWI-Prolog's tabling, if `swipl` is there |
| `make test-ffi` | C functions called from Shen and C written for Shen, against `tests/ffi_lib.c`, memory outside the heap, and the SQLite and socket libraries |
| `make test-curl` | Optional libcurl adapter, independent loopback HTTP/TLS fixtures, downloader, typing, threads and images/GC; needs libcurl development headers, Python 3 and `openssl` |
| `make test-fs` | Filesystem metadata, paths, bounded traversal, replacement, cleanup, typing, images/GC and the copy application; needs a C compiler and Python 3 |
| `make test-process` | Child lifecycle, argv/environment/cwd, bounded communication, pipelines, inheritance, typing, images/GC and streaming memory; needs a C compiler and Python 3 |
| `make test-tree-sitter` | Tree/query snapshots, independent C/coordinate oracles, types, images/GC and bounded source facts; needs a C compiler, Python 3 and `make deps-tree-sitter` on shared-capable builds |
| `make test-overrides` | Each kernel function that Shen/JIT replaces beside the kernel's own definition, over generated values, as compiled and through C |
| `make check-lowerer` | Checks the stage 0 output against the lowerer's invariants |
| `make check-generated` | Compares the generated files with `generated.sha256`. `make update-generated` rewrites it after a change to the lowerer, the port or the lowered test programs |
| `make test-kl-stress`, `make test-kernel-stress` | The same with frequent collections |
| `make test-lib-stress` | The libraries' saved images reloaded with a collection at every allocation, which their own suites leave out |
| `make test-san` | `test`, `test-jit`, `test-ops`, `test-kl`, FFI, libcurl, filesystem, subprocess and Tree-sitter adapters under AddressSanitizer and UBSan |
| `make test-x86` | The same five, built as x86-64 code (under Rosetta on Apple silicon) |
| `make test-differential` | Each primitive over generated values, however it is compiled and through C, and properties they must keep. `make differential-scheme` lists what differs from Shen/Scheme, to read and not to pass |
| `make fuzz-native` | Mutated code objects, run if the checker accepts them |
| `make test-ctrlc-windows` | A real Ctrl-C to the REPL on Windows, through a console |
| `make test-linux` | Every suite on Linux arm64 and x86-64, in Docker, from a source tarball. Needs pandoc, as `make dist` does |
| `make deps` | Fetches the kernel and the earlier release of Shen/JIT that makes the generated files |
| `make bench` | The kernel's benchmarks and Shen/Scheme's realistic ones, under Shen/JIT and Shen/Scheme, compared. `make bench SEAL=1` runs Shen/JIT sealed |
| `make bench-numeric` | Numeric programs and a path tracer, in C and in Shen with raw registers, and those programs with boxed reals too |
| `make bench-independent` | Workloads never used for tuning (the kernel's test suite, installing the standard library, a prover), to check that gains are not fitted to the benchmarks |
| `make clean` | Removes what `make` builds in `build/`, but for the generated files and `shen-jit-stlib` |
| `make guide` | Renders this guide and its documents' pages to `build/guide/`, with [pandoc](https://pandoc.org) |
| `make dist` | Writes a source tarball, `build/shen-jit-VERSION.tar.gz`, with this guide rendered, once the generated files match |

To run the test suites from a source tarball, point `KERNEL_DIR` at a directory with the kernel's `tests` and
`extensions`, and its `klambda` for `make test-overrides`:

```sh
make stlib
make deps-tree-sitter
make KERNEL_DIR=/path/to/kernel test-core test-libs
```

Windows CI runs these suites and GC stress. `tests/cli.sh` leaves out the tests that
send a signal, which `make test-ctrlc-windows` covers, or use the profiler. The sanitizers stay on Linux and macOS.

[AGENTS.md](https://github.com/tizoc/shen-jit/blob/main/AGENTS.md) has more on working on it.

### More

- [How Shen/JIT works](https://github.com/tizoc/shen-jit/blob/main/docs/design.md): the build, frames and calls, values
  and the collector.
- [Shen/JIT semantics](https://github.com/tizoc/shen-jit/blob/main/docs/semantics.md): the behaviour it implements, and
  where that differs from Shen/Scheme.
- [Shen/JIT instructions and frames](https://github.com/tizoc/shen-jit/blob/main/docs/bytecode.md): the instruction set
  and the lowering rules.
- [Calling C in full](https://github.com/tizoc/shen-jit/blob/main/docs/ffi.md): plain C, C written for Shen, and how it
  works.

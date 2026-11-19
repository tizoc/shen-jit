# Writing fast programs

Most Shen code needs nothing from this page: the compiler inlines small functions, keeps fixnums unboxed and
turns tail calls into jumps without being asked. What follows is for the code that runs most, once a
measurement has found it: how to see where time and memory go, what allocates, how a loop can run without
allocating, and how typed programs keep numbers in machine registers.

## Measuring

Time a call with the kernel's `time`, which prints how long it took, or with `(get-time unix)`, in seconds, on
either side of it. Here `read-many` is the example under [Running without allocating](#running-without-allocating):

```repl
(0-) (time (read-many 100))
run time: 0.026811 secs
300000
```

Run it several times: the first call of a function compiles it to native code. For where the time goes,
`SHEN_JIT_PROFILE=1` prints a flat profile at exit, naming both Shen and C functions, and `SHEN_JIT_PERF_MAP=1`
lets an external profiler, such as `perf` on Linux, name compiled code. `SHEN_JIT_STATS=1` prints at exit what
the collector did, with its longest pause, and the live heap by type. `(shen-jit.code F)` shows the bytecode of
F ([Shen/JIT instructions and frames](bytecode.md)).

### Counting allocations

`SHEN_JIT_GC_STRESS=1` collects at every allocation, so under it the number of collections that
`SHEN_JIT_STATS=1` reports is the number of allocations. Run the same code for N and for 2N iterations: the
difference is what N iterations allocate, without what setup and first calls allocate once. Load the program
into an image first, so that loading it does not run under the stress too:

```sh
shen-jit --save records.img eval -q -m buffer -l records.shen
SHEN_JIT_IMAGE=records.img SHEN_JIT_GC_STRESS=1 SHEN_JIT_STATS=1 shen-jit eval -e '(read-many 1)'
SHEN_JIT_IMAGE=records.img SHEN_JIT_GC_STRESS=1 SHEN_JIT_STATS=1 shen-jit eval -e '(read-many 2)'
```

Each run prints its result, then, at exit, the collector's work, starting `shen-jit: 426 collections`. Both runs
give the same count, so reading 3000 more records allocated nothing. Give both runs expressions of the same length,
as reading a longer one allocates more, and check that each printed its result: a run that stops at an error counts
low.

## What the collector costs

Allocating moves a pointer. A collection copies everything still live, and the heap grows to stay at least five
times what is live, so a collection copies at most a word for every four allocated. Allocation's total cost is
then proportional to what is allocated, whatever the heap holds; what grows with the live data is each pause.

- A program with little live data can allocate freely.
- One that holds a lot, or must answer within a bound, as a server must, gains most from running without
  allocating: each collection it avoids is a pause in proportion to all it holds.
- Vectors, strings and buffers of 256 KB or more are never copied: a collection marks them and scans them in
  place. Keep a large table in one vector or buffer rather than in many small objects.
- `SHEN_JIT_SEMISPACE` starts the heap larger, which collects less often until the heap would have grown that far
  anyway ([Environment variables](guide.md#environment-variables)).
- A collection copies a list's pairs one after another, so a list it has copied is contiguous in memory, and
  walking it reads memory in order.

## What allocates

Measured as above, in untyped code:

| Allocates each time it is evaluated | Allocates nothing |
| --- | --- |
| `cons`, `@p`, `vector`, a struct's constructor | Fixnum arithmetic and comparisons, `=` on fixnums |
| `cn`, `@s`, `str`: a new string | Reading and writing a struct's fields, `value` |
| A float result, even of two constants | `buffer.u8`, `buffer.u16-be`, `buffer.u32-be`, `buffer.u8->`, `buffer.length` |
| `buffer.slice` and any other new view | `buffer.copy-into!` |
| `(result.ok V)` and `(result.err E)` | `trap-error` |
| `floats.get`: a new float | `thaw` of a `freeze` made earlier |
| A lambda or `freeze` that captures a variable | A lambda, `freeze` or `(fn F)` that captures nothing |
| A partial application, `(add 1)` | A lambda bound by `let` and only called |
| | A lambda passed to a small sealed function that only applies it |

The last row needs the function to be sealed. A definition is open unless it was sealed: calls to it are inlined
and patched when it is redefined, so for first-order code sealing gains little ([Sealing](guide.md#sealing)).
What it adds is that a small function that takes a function and applies it, `apply1` below, is inlined with the
lambda in place, so no closure is made:

```shen
(define apply1
  F X -> (F X))

(define bump
  N -> (apply1 (/. X (+ X N)) 1))
```

Open, each `bump` allocates a closure; sealed, it allocates nothing. `shen-jit build` seals a program unless
given `--open`, and `--seal`, `SHEN_JIT_SEAL=1` or `(shen-jit.seal +)` seal what is defined after them.

## Running without allocating

A loop that runs for the life of a program, such as a server's, can run without allocating once it has
started. The ways to get there:

- **Make everything at setup.** Buffers, structs and vectors of fixnums are made once and reused. State that
  changes, such as a queue's head and tail, is fixnums in a struct's mutable fields.
- **Fill what the caller gives.** An operation that produces bytes copies them into a buffer the caller owns, and
  one that produces several values sets the fields of a struct the caller owns, rather than returning a new view,
  tuple or list.
- **Say how it went with a fixnum or a symbol.** A result struct allocates; in the inner loop, give `-1` or
  `would-block`, and leave [results](result.md) to the boundary of an API.
- **Name things with fixnums.** A handle to one of a fixed set of slots can be its index plus the number of slots
  times how often the slot has been reused: a handle kept past its slot's reuse no longer matches, and nothing is
  allocated to tell.
- **Read fields where they are.** Read a field at its offset with `buffer.u8` or `buffer.u16-be`, and copy bytes
  with `buffer.copy-into!`, rather than taking a slice.
- **Bound the work of a call.** A poll that handles at most a given number of items keeps each call short.

This reads records of a kind byte, a big-endian 16-bit length and that many bytes, into a header and a buffer
that the caller made once (`-m buffer`):

```shen
(defstruct header
  (mutable kind)
  (mutable length))

\\ Reads the record at offset I of In: a kind byte, a big-endian 16-bit length and that
\\ many bytes, which go to the start of Out. Fills H and gives the offset after the record,
\\ -1 if In ends first, or -2 if Out is too small.
(define read-record
  In I _ _ -> -1 where (> (+ I 3) (buffer.length In))
  In I H Out -> (read-payload In (+ I 3) (buffer.u16-be In (+ I 1)) (buffer.u8 In I) H Out))

(define read-payload
  In Start N _ _ _ -> -1 where (> (+ Start N) (buffer.length In))
  _ _ N _ _ Out -> -2 where (> N (buffer.length Out))
  In Start N Kind H Out -> (do (buffer.copy-into! Out 0 In Start N)
                               (header.kind-> H Kind)
                               (header.length-> H N)
                               (+ Start N)))

\\ Reads every record of In and gives how many it read.
(define read-all
  In H Out -> (read-from In 0 H Out 0))

(define read-from
  In I H Out Count -> (let Next (read-record In I H Out)
                        (if (< Next 0)
                            Count
                            (read-from In Next H Out (+ Count 1)))))

\\ Three records: kinds 1, 2 and 3, of 3, 2 and 0 bytes.
(define sample
  -> (fill (buffer.new 14) 0 [1 0 3 120 121 122 2 0 2 112 113 3 0 0]))

(define fill
  B _ [] -> B
  B I [X | Xs] -> (fill (buffer.u8-> B I X) (+ I 1) Xs))

(define read-many
  M -> (let In (sample)
            H (header.make 0 0)
            Out (buffer.new 16)
         (repeat (* M 1000) In H Out 0)))

(define repeat
  0 _ _ _ Count -> Count
  K In H Out Count -> (repeat (- K 1) In H Out (+ Count (read-all In H Out))))
```

`(read-many 1)` reads 3000 records and allocates only as it starts: the counts above are of this program.

## Data

- **Records as structs.** A struct's fields are read and written in place, and a sealed function that reads
  several of one struct's fields tests it once ([Managed structs](structs.md)).
- **Bytes in buffers.** A string is copied whole by `cn` and `@s`; bytes kept in a [buffer](buffers.md) are read
  and written where they are, and a builder appends to storage that doubles as it fills.
- **Numbers in arrays.** In untyped code each float is a 16-byte object. [`floats`](floats.md) keeps doubles
  unboxed, 8 bytes each, and [`words`](words.md) 64-bit words, though untyped code that reads one gets a new
  float or word.

## Numbers and typed programs

In untyped code a fixnum is unboxed, and its arithmetic is inline, overflow checked. A float is an object, so
each float result allocates. A typed program, or a typed module, keeps its floats, fixnums and 64-bit words in
machine registers: the module [`numbers`](numbers.md) gives the types `fixnum` and `float` and their operators,
and a descriptor's `(typed)` compiles the module with them ([Typed programs](modules.md#typed-programs)):

```shen
(shen.module (version 1) (name orbit) (requires numbers) (typed)
  (sources tc+ "orbit.shen"))
```

```shen
\\ orbit.shen
(define orbit
  {float --> float --> float --> float --> fixnum --> fixnum --> fixnum}
  _ _ _ _ Limit Limit -> Limit
  X Y CX CY N Limit -> (let XX (fl* X X)
                            YY (fl* Y Y)
                         (if (fl> (fl+ XX YY) (float 4))
                             N
                             (orbit (fl+ (fl- XX YY) CX)
                                    (fl+ (fl* (float 2) (fl* X Y)) CY)
                                    CX CY (fx+ N 1) Limit))))
```

A call of `orbit` runs its iterations as a loop in registers and allocates nothing. To check that a definition
got registers, look at its code: `float*`, `float+` and the other `float` instructions are arithmetic in
registers, and `float-box` is where a float leaves them. The same arithmetic as `prim` instructions is boxed.
These keep a definition's floats boxed:

- **A call to a function that is not inlined,** other than those that make an error's message. A typed helper
  that keeps its own values in registers is inlined unless it is very large, loops included, so this is a call to
  anything else, such as `output`.
- **`trap-error`** anywhere in the definition.
- **A module it relies on that was loaded open.** A typed module loads what it requires sealed, unless it was
  already loaded open. `(optimise +)` at the REPL or in `load` keeps floats in registers only where `numbers` was
  loaded sealed, so after `-m numbers` it gives boxed code.
- **Arithmetic on `number`,** after `fl->number`, which runs as in untyped code.

### What to expect

Five numeric programs and a path tracer, each written in C, in untyped Shen and as a typed program, all printing
the same check to the last digit, in `tests/bench/`: C compiled with `-O2 -ffp-contract=off`, times
in milliseconds, medians, measured as typed programs were added in November 2026. `make bench-numeric` runs them.

Apple M3 Max, macOS, Apple clang, 10 rounds:

| Program | C | Untyped | Typed |
| --- | ---: | ---: | ---: |
| matmul | 37.1 | 320 | 43.2 |
| mandelbrot | 14.0 | 79.4 | 17.0 |
| spectral | 7.34 | 120 | 11.4 |
| n-body | 1.18 | 35.2 | 1.68 |
| heat | 22.5 | 521 | 44.7 |
| path tracer | 226 | - | 413 |

Ryzen 5 5600X, in a 4-CPU Linux VM, gcc 9.4, 7 rounds, 2026-11-16:

| Program | C | Untyped | Typed |
| --- | ---: | ---: | ---: |
| matmul | 41.2 | 405 | 45.9 |
| mandelbrot | 13.3 | 99.9 | 13.9 |
| spectral | 15.2 | 153 | 20.7 |
| n-body | 1.85 | 55.9 | 2.77 |
| heat | 32.7 | 677 | 60.1 |
| path tracer | 367 | - | 699 |

On these programs typed Shen took 1.0 to 2.0 times as long as C, and untyped Shen 6 to 30 times.

## Loading

Many programs spend more time loading than running: reading, typechecking and compiling their sources.
`shen-jit build` does that once and writes an executable that starts with the program loaded ([Building a
program](modules.md#building-a-program)), and so does saving an image ([Saving a program](guide.md#saving-a-program)).
A source whose types need no checking can load with `tc-`, and a module typechecks against its own rules and those
of the modules it requires, not every rule loaded ([Rules](modules.md#rules)).

## Parallel work

[Isolates](guide.md#isolates) run on several cores, each with its own heap, so what one allocates and holds does
not lengthen the others' collections. A channel copies what is sent, a large byte buffer or string once, so send
work in pieces large enough to be worth the copy. [`parallel.map`](parallel.md) maps a function over a list with
them.

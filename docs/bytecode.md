# Shen/JIT instructions and frames

The lowerer ([src/lowerer/](../src/lowerer/README.md)), written in Shen, turns
KLambda into the symbolic instructions
below. They are plain Shen lists, so the same form serves as the stage 0 file
(printed as text) and as the value `eval-kl` passes to the `shen-jit.install` primitive
at runtime. C encodes them; the lowerer never deals with numeric opcodes, so no
encoder needs to be generated for it.

C encodes each instruction as 32-bit words: the opcode, then its operands
(`ops.h`). A code object keeps them packed (`bytecode_pack`): each word
rotated left by one bit, so that the constant-operand flag (bit 31) becomes
bit 0, then written as a variable-length integer, seven bits per byte. Nearly
every word takes one byte. The JIT unpacks a function's words when it
compiles it, which is the only time they are read.

## Frames

A frame is a run of slots on the guest stack, numbered from 0 at the frame
pointer:

| Slot | Contents |
| --- | --- |
| 0 | Return address (raw, 4-byte aligned). |
| 1 | The running procedure, which is also its closure environment. |
| 2 .. arity+1 | Parameters. |
| above | Let-bound variables and temporaries, allocated by the lowerer. |

A **call window** at offset `A` occupies slots `A` (return address), `A+1`
(callee) and `A+2 .. A+1+N` (arguments). The lowerer places every window above
every slot that is live across the call, and evaluates arguments directly into
the window. Evaluating argument `i` may itself use windows, which then start
above `A+2+i`. A code object's frame size is the highest slot it uses plus one,
including all of its windows, so a function writes only inside its own frame.

A named tail call uses window 0: its arguments go straight to slots
`2 .. N+1`, where the callee expects them, so nothing is copied. Argument `i`
is computed into slot `2+i` unless a later argument reads that slot. In that
case it is computed into a temporary above every parameter slot, and moved
into `2+i` after the last argument. An argument that is already in its slot,
such as an unchanged parameter, costs nothing.

## Code objects

```text
(code Name Arity FrameSize Constants Instructions Codes Inline)
```

- `Name`: the defined symbol, or `lambda` / `freeze` for nested code.
- `Arity`: number of parameters (a `lambda` has 1, a `freeze` has 0). A
  code object whose first instruction is `(entry N L)` keeps N in the high
  32 bits of its arity word.
- `FrameSize`: as above.
- `Constants`: a list of literal values (numbers, strings, symbols, `[]`,
  `true`, `false`, and proper lists of these). Instructions refer to them by
  index.
- `Instructions`: a list of the forms below.
- `Codes`: nested code objects for the `lambda` and `freeze` forms in this
  body, referred to by index.
- `Inline`: for a `defun`, `(Params Body)` when the definition can be inlined
  where it is called sealed (see the lowering rules), and `()` otherwise.
  Other code objects leave it out.

A stage 0 file is a sequence of `(defun Name Code)` forms, one per line, in
ASCII. Lists use parentheses; strings escape `"` and `\` with a backslash and
every byte outside 32–126 as `\xHH`; floats always contain `.` or `e`; and no
symbol is printed in a form that reads as a number. A non-`defun` expression
lowered for `eval-kl` is a code object of arity 0 named `eval-kl`.

## Instructions

`D`, `S` and `A` are slot numbers; `K`, `C` and `I` are indices; `L` is a label
number, local to its code object; `F` is a symbol; `N` is an argument count.
`O` is an operand: a slot number, or `(const K)` for constant K, which the
lowerer uses for every literal operand instead of copying it into a slot
first. Native code takes a constant that is not a pointer (a fixnum, `[]`, a
Boolean) as an immediate, and reads any other from its constant cell.

| Form | Meaning |
| --- | --- |
| `(move D S)` | Slot D := slot S. |
| `(const D K)` | D := constant K. |
| `(capture D I)` | D := capture I of the running closure (slot 1). I is zero-based and at most 4095. |
| `(closure D C S1 ... Sn)` | D := a new closure of code C capturing up to 4096 slots S1..Sn, in that order. With no slots, D := the one closure of C, which the loader made as it built the code, so that it allocates nothing and gives the same closure each time. |
| `(prim D Op O1 ... On)` | D := primitive Op (a KLambda primitive name) applied to O1..On. N must equal Op's arity. |
| `(label L)` | Marks L. |
| `(jump L)` | Continue at L. |
| `(jump-if-false O L)` | If O is `false`, continue at L; if `true`, fall through; otherwise raise "X is not a boolean". |
| `(call D A F N)` | Open named call: the callee is F's function binding, the arguments are in A+2..A+1+N, the result goes to D. |
| `(call-sealed D A F N)` | As `call`, but F is a stage 0 definition and the target is fixed when the code is installed. |
| `(call-value D A N)` | Dynamic call: the callee is already in A+1. N is 0 or 1, or more after `jump-unless-entry`. |
| `(tail-call A F N)` | Open named tail call; the arguments are in A+2..A+1+N and move to slots 2..N+1, or are already there when A is 0. |
| `(tail-call-sealed A F N)` | Sealed named tail call. |
| `(tail-call-value A N)` | Dynamic tail call; the callee is in A+1. |
| `(return O)` | Return O. |
| `(push-handler L)` | Install a handler: if anything raises before the matching `pop-handler`, continue at L. When L is not followed by `exception`, the handler is quiet: it never reads the exception, so none is built for it. |
| `(pop-handler)` | Remove the innermost handler. |
| `(exception D)` | D := the exception being handled; the first instruction at a handler label. |
| `(entry N L)` | First, in a `lambda` that returns lambdas: a call with N arguments, more than the arity, continues at L with them in slots 2..N+1. |
| `(jump-unless-entry S N L)` | Continue at L unless slot S holds a procedure that takes N arguments at once: a closure whose code has `(entry N _)` or takes exactly N, which only a definition's does, or a foreign function of N. Applied one argument at a time, the last two would fail. |
| `(inline F N)` | The next N instructions are a body of F inlined here: no code, but backtraces name F for errors raised in them. Not in stage 0 code. |

Primitive names are the 39 KLambda primitives, except `eval-kl` (see below),
plus:

- `raise-cond`: arity 0, raises the "no clause applies" error for `cond`;
- `shen-jit.field`: arity 2, `(prim D shen-jit.field O (const K))`, element K of the vector in O, read
  with no check, for a typechecked call of a struct's reader (see the lowering rules). Only the
  lowerer makes it, and it is no function; the checker of code written by hand refuses it. With an
  index that is not a small constant, it reads as `<-address`;
- `shen-jit.struct-ref`: arity 3, `(shen-jit.struct-ref R K N)`, element K of R, a struct of N elements, its
  tag among them, which a struct's reader is: read as `<-address` reads it, but testing that R is a vector of
  at least N elements, so that one shorter raises `struct: R is shorter than its struct` though K is in it. The
  JIT then knows the slot holds every field, as it knows a pair after `cons?`, and the struct's next reads of
  it, with constant K and N, are one load each;
- `shen-jit.install`: arity 1, the port primitive behind `eval-kl`. It takes
  `(defun F Code)`, publishes F and returns it, or a code object, and returns a
  closure of it. Nothing is published unless the whole definition was built.
- `shen-jit.symbol?`: arity 1, true exactly for symbol objects. The lowerer
  uses it instead of the kernel's `symbol?`, which also checks the characters
  of the name (it rejects `:=`) and which ports override differently.
  Under another Shen, `src/lowerer/host.shen` defines it.
- `shen-jit.hash`: arity 2, the C function behind the port's `hash`
  override. It is consistent with `=`, so 8 and 8.0 hash alike, and returns
  1 to Bound - 1, as the kernel's portable `hash` does.
- `shen-jit.symbol-kind`: arity 1, 0 for a value the kernel's `symbol?`
  rejects, 1 for a symbol and 2 for a variable, by the kernel's own rules for
  names. The port's `symbol?` and `variable?` overrides use it.
- `shen-jit.filled-vector`: arity 2, an absvector of the given length with
  every element the given value. The port's `shen.dict` uses it.
- `shen-jit.dict-find` (arity 2), `shen-jit.dict-put` (3),
  `shen-jit.dict-remove` (2) and `shen-jit.dict-entries` (1): the native
  dictionaries behind the port's dict overrides (`src/runtime/dict.c`).
  `dict-find` returns the `(Key . Value)` entry or `[]`, and `dict-entries`
  returns a new list of new entries.
- `shen-jit.tagged?`: arity 2, true for an absvector with at least one
  element whose element 0 is the given value, compared by identity, so it
  serves symbol tags. The port's `tuple?` uses it.
- `shen-jit.pvar` (arity 1), `shen-jit.pvar?` (1) and `shen-jit.pvar-offset`
  (1): a Prolog variable as an immediate value, a special whose low byte marks
  it, with the offset of its binding above that. It takes no memory, and `=`
  compares it by identity. All three are inline, and `shen-jit.pvar?` fuses with
  a branch like the other type tests. An offset is a fixnum from 0 to 2^56 - 1.
  A variable is not an absvector. `shen-jit.deref` (arity 3) gives what a value is
  bound to in a vector of bindings, given what marks no binding, along a chain of variables, inline. The port's `shen.lazyderef` uses
  it. `shen-jit.newpv` (arity 2) makes a new variable in a vector of bindings, whose element 1 is the next offset:
  that offset's binding becomes the second argument, which marks no binding, and element 1 moves on, inline, with
  one test that the vector has room. The port's `shen.newpv` uses it. `shen-jit.gc` (arity 2) returns its second
  argument, and if that is false, moves the next offset of the bindings back by one, inline; the port's `shen.gc`
  uses it. `shen-jit.same?` (arity 2) tells whether two values are one and the same. The port's `shen.make-prolog-variable`, `shen.pvar?`,
  `shen.lazyderef`, `shen.deref`, `shen.bindv` and `shen.unwind` use them.
- `shen-jit.foreign`: arity 2, `(shen-jit.foreign Name Desc)` makes Name a C function, as `lib/ffi.shen`
  describes it (`src/runtime/ffi.c`, and [ffi.md](ffi.md)), and returns Name. Calls go through a stub shared by all of them, so
  no instruction is new. `shen-jit.pointer?`, `shen-jit.pointer-kind`, `shen-jit.pointer-address`,
  `shen-jit.pointer->string`, `shen-jit.pointer-kill` (arity 1), `shen-jit.bytes->pointer`, `shen-jit.pointer->bytes` (arity 3)
  handle the pointers such functions pass around, and `shen-jit.errno`, `shen-jit.c-errno` (arity 0) what
  the last one left. `shen-jit.pointer-sized` (arity 2) states a length, `shen-jit.pointer!` (arity 3) stores an address, and `shen-jit.pointer-read-only` (arity 1) marks one against stores. `shen-jit.pointer-guard` (arity 2), `shen-jit.pointer-owner` (arity 1) and `shen-jit.pointers-dead` (arity 0)
  tell Shen when a pointer has died, and `shen-jit.collect` (arity 0) collects. [ffi.md](ffi.md) has their use.
  `shen-jit.pointer?` is inline, a test of the object's type, and fuses with a branch like the other type tests.
- `shen-jit.fixnum?`: arity 1, true exactly for immediate integers, excluding boxed floats even when
  integral. The value codec uses this representation test; the JIT emits a tag check.
- `shen-jit.integer?`: arity 1, the kernel's `integer?` as a primitive: true of a fixnum and of a
  float with no fraction.
- `shen-jit.vector?`: arity 1, the kernel's `vector?` without its
  `trap-error`: true for an absvector with at least one element whose element
  0 is a number at least 0. The port's `vector?` and `shen.+vector?` use it.
- `shen-jit.absvector3`: arity 3, a new absvector of the three values. The
  port's `@p` uses it.
- `shen-jit.quiet?`: arity 0, whether the innermost handler is quiet, so
  that an error raised now will not be read. The port's `get` and
  `shen.<-dict` then raise without building their message.
- `shen-jit.mark-toplevel` (arity 0), `shen-jit.trace-text` (1) and
  `shen-jit.backtrace` (0): backtraces. The
  port's REPL marks its frame with the first; the second gives the last
  captured backtrace as lines to print after an error's message; the third
  returns the names of the frames on the stack now, innermost first.
- `shen-jit.sealed?` (arity 1), `shen-jit.sealing` (1) and
  `shen-jit.inline-body` (1): whether calls to a name may be sealed, turning
  sealing of new definitions on or off, and a sealed definition's `Inline`
  body. The lowerer uses the first and last; the port's `shen-jit.seal`
  uses `shen-jit.sealing`.
- `shen-jit.exit`: arity 1, ends the process with the given status, from 0
  to 255, after flushing every open stream. The REPL uses it at end of input.
- `shen-jit.save-executable`: arity 2, the path and an entry point or `[]`. It
  writes the running executable's runtime and an image of the heap, and ends the
  process. Its arguments are checked first, and a path it cannot write raises.

- `shen-jit.bytes` (arity 1), `shen-jit.bytes?` (1), `shen-jit.bytes-length` (1),
  `shen-jit.u8`, `shen-jit.u16`, `shen-jit.u32` (2), `shen-jit.u8!`, `shen-jit.u16!`,
  `shen-jit.u32!` (3), `shen-jit.s32`, `shen-jit.s64`, `shen-jit.f32`, `shen-jit.f64` (2),
  `shen-jit.s32!`, `shen-jit.s64!`, `shen-jit.f32!`, `shen-jit.f64!` (3),
  `shen-jit.string->bytes` (1), `shen-jit.bytes->string` (3),
  `shen-jit.copy-bytes` (5), `shen-jit.write-bytes` (4) and `shen-jit.xxh64` (5): byte buffers, below.
- `shen-jit.read-file`: arity 2, a path and whether to give a list of bytes, else a string.
  The port's file reading uses it.
- `shen-jit.append`: arity 2, the port's `append` for a non-empty first list.
- `shen-jit.arity?` and `shen-jit.inlined?`: arity 2, the tests in the rules below.
- `shen-jit.arity` (arity 1) and `shen-jit.set-arity` (2): a name's arity, or -1, and
  recording it, which only the builder may do. Arities are kept beside function cells,
  outside the heap; the port's `arity` reads them.
- `shen-jit.function` (arity 1): the procedure a name has now, read inline, or an error
  for a name with none. A primitive's is a definition made from a code object at
  startup. `fn`'s templates make their last call with it.
- `shen-jit.apply` (arity 2): calls a name's procedure, or a procedure, with the elements
  of a list at once, through a nested call: `fn`'s templates past four arguments.
- `shen-jit.isolate` (arity 3): an operation's number and two operands, for the port's
  `isolate.spawn`, channels, monitors and `kill` (docs/design.md, "The builder and
  isolates").
- `shen-jit.bit-and`, `shen-jit.bit-or`, `shen-jit.bit-xor`, `shen-jit.shift-left`,
  `shen-jit.shift-right`, `shen-jit.rotate32` (2), `shen-jit.bit-not`,
  `shen-jit.bswap32`, `shen-jit.popcount`, `shen-jit.clz` and `shen-jit.ctz` (1): bit
  operations, below.
- `shen-jit.float`: arity 1, a number as a float: an integer converted, a float as it is, and anything
  else raising "X is not a number". Compiled code passes a float on at once, and of a number literal
  the lowerer makes the float a constant. The module `numbers`
  defines `float`, `fx->fl` and its float operators with it, which unboxed code reads into a float
  register (see the lowering rules).
- `shen-jit.truncate`: arity 1, a number truncated towards zero, as a fixnum: a fixnum is itself, and a float
  outside the fixnums, a NaN or an infinity among them, raises "integer overflow". The module `numbers`
  defines `fl->fx` as it; unboxed code computes it with `fix-from-float` (see the lowering rules).
- `shen-jit.quotient` and `shen-jit.remainder`: arity 2, of two fixnums, truncating towards zero, the
  remainder having the dividend's sign; zero as divisor raises "division by zero", and the least fixnum
  by -1 "integer overflow". The module `numbers` defines `fxquotient` and `fxremainder` as them.
- `shen-jit.sqrt`: arity 1, a number's square root, a float, raising as `shen-jit.float` does. The
  module `numbers` defines `flsqrt` as it; unboxed code computes it with `float-sqrt`.
- `shen-jit.word-op`: arity 3, a symbol naming an operation on 64-bit words, which wraps, and its two
  operands, the second ignored by those of one. A word is a byte buffer of 8 bytes, little-endian, and the
  result a new one: `wof` of a fixnum, `wfixnum` and `wfloat` of a word, the fixnum, raising "integer
  overflow" for a word that is no fixnum, and the float, `wget` of bytes and a byte index, `w+`, `w-`, `w*`,
  `wand`, `wor` and `wxor` of two words, `wshl`, `wshr`, `wsar`, `wrotl` and `wrotr` of a word and a count
  taken modulo 64, and `w<`, `w<=`, `wu<` and `wu<=`, a Boolean. An operand of another kind raises "X is
  not a word" or "X is not an integer", or, for `wget`, as the byte primitives do, and another symbol
  "shen-jit.word-op: X is not an operation". The module `word` defines its functions with it; unboxed code computes it
  in word registers (see the lowering rules).
- `shen-jit.decimal`: arity 2, a string holding a decimal number, which may have an
  exponent, and a power of ten to scale it by. It gives the nearest float, for the reader's
  literals past the fixnum range.

`input+` is not a primitive; the port defines it.

## Byte buffers and bit operations

A byte buffer is a `T_BYTES` object: a length and that many bytes, which the collector
does not scan. It lives in the heap like a string, so:

- the collector frees it, and there is no `free`;
- one of 256 KB or more gets a block of its own and is not copied;
- `shen-jit.save-executable` saves it with its contents;
- every access checks the type, the index and, for a store, the value, and raises if
  any is wrong.

A pointer with a length is memory outside the heap ([ffi.md](ffi.md)), and all of these except
`bytes?` and `string->bytes` take one in place of a buffer, with the same checks against its
length. `u8`, `u16`, `u32`, `s32`, `f64`, `bytes-length` and the stores `u8!`, `u16!`, `u32!` and `f64!` compile
inline for both; the others call C for both. `f64` allocates where it reads, and its float holds the word as it
is in memory, so it takes no floating point. `f64!` takes a float inline, and leaves an integer to C. A read-only
pointer differs in its header, which a store tests whole, so no other access pays for it. So does a shared buffer
or vector (`isolate.share`), by a bit of its header's type field: a store tests the whole byte and sends one to C,
which refuses it, and a read masks the bit out, as it masks a string's type, with no more instructions. Only
`absvector?`, which tests one byte it loads, and `=` on two objects, which tests their headers before calling C, take
one more.

A string is memory too, which they only read: it is laid out as a byte buffer, so a read takes
either inline, the type tested through a mask with no more instructions, and a store into a
string raises that it is read only. A string never changes, so a definition holding one as a
constant, such as a grammar loop's byte table, can go into the program space. `bytes?` stays
false for a string, and the FFI's `bytes` arguments take byte buffers alone, so C is never given
a string to write into.

Code that loops, calls nothing and has no handlers, and reads or stores through a parameter it never changes, works out that memory's base and lengths once, on the way in, for any code,
written by hand or not, however many loops it has, for eight parameters at most where integer registers are many, as on arm64, and four
where they are few, as on x86-64. They hold until C runs, as only C can collect or kill a pointer, and they are worked out again each time it has. What is not memory gets length 0, so that its first access raises as it would have, and a read-only pointer or a string gets 0 for stores. Memory reached only at word indices, all of bytes or all of elements of one size, keeps limits in place of lengths, the first index without room for the narrowest width it is reached at, so that an access at that width is one comparison, a wider one a second, of its last byte, and what is in registers is used where it is.

| Form | Result |
| --- | --- |
| `(shen-jit.bytes N)` | A new buffer of N zero bytes. |
| `(shen-jit.bytes? X)`, `(shen-jit.bytes-length B)` | Whether X is a buffer; B's length. |
| `(shen-jit.u8 B I)`, `u16`, `u32` | The unsigned value at byte offset I, little-endian, at any alignment. |
| `(shen-jit.s32 B I)`, `s64` | The signed value there. An `s64` that does not fit a fixnum raises. |
| `(shen-jit.f32 B I)`, `f64` | The floating-point value there, as a new float. |
| `(shen-jit.u8! B I X)`, `u16!`, `u32!` | Stores X at I and returns B. X must fit: 0 to 255 for `u8!`. |
| `(shen-jit.s32! B I X)`, `s64!` | The same, signed. |
| `(shen-jit.f32! B I X)`, `f64!` | The same for a number, rounded to fit. |
| `(shen-jit.string->bytes S)` | A new buffer with S's bytes. |
| `(shen-jit.bytes->string B I N)` | A new string of the N bytes from I. |
| `(shen-jit.copy-bytes To I From J N)` | Copies N bytes from J in From to I in To, which may overlap, and returns To. |
| `(shen-jit.write-bytes B I N S)` | Writes the N bytes from I to the output stream S, as `write-byte` would one at a time, and returns N. |
| `(shen-jit.xxh64 To From J N K)` | Stores the XXH64 hashes, seed 0, of K keys of N bytes, one after another from J in From, 8 bytes each from the start of To, as `word.set` would, and returns To. One call with K keys costs about what K calls of one would cost apart from the call. |

`=` compares buffers by contents, as it does strings, and `shen-jit.hash` agrees.

Bit operations work on a fixnum's 62 bits in two's complement. A float raises, even
one with no fraction.

| Form | Result |
| --- | --- |
| `(shen-jit.bit-and X Y)`, `bit-or`, `bit-xor`, `(shen-jit.bit-not X)` | As named. |
| `(shen-jit.shift-left X K)` | X shifted left by K, from 0 to 63. What leaves the 62 bits is gone: unlike `*`, it does not raise. |
| `(shen-jit.shift-right X K)` | X shifted right by K, from 0 to 63, keeping the sign. |
| `(shen-jit.rotate32 X K)` | X, from 0 to 2^32 - 1, rotated left by K, from 0 to 63, modulo 32. |
| `(shen-jit.bswap32 X)` | X, from 0 to 2^32 - 1, with its four bytes reversed. |
| `(shen-jit.popcount X)`, `clz`, `ctz` | The bits set, and the leading and trailing zeros, of the 62 bits; `clz` and `ctz` of 0 are 62. |

The JIT inlines the accesses named above, and `bit-and`, `bit-or`, `bit-xor`, `bit-not`, the
shifts, `bswap32`, `clz` and `ctz`. The others are calls to C.

## Lowering rules

- Lexical binding is checked before fixed names: in `(let if F (if a b c))`,
  the `if` call is dynamic.
- A symbol that is not lexically bound evaluates to itself (a constant).
- `(do A B)` evaluates A for effect, then B; B is in tail position when the
  `do` is.
- `(let X Y Body)`, where Y is a local variable held in a slot, binds X to
  Y's slot without a move. No slot is written while a variable bound to it is
  in scope, and KLambda variables are immutable.
- `(thaw X)` is a dynamic call of X with no arguments, except as follows.
- `(let G (freeze E) Body)` in tail position, where Body uses G only as
  `(thaw G)` in tail position (never inside a `lambda`, `freeze` or
  `trap-error`, and never binding G again), makes no closure. These are the
  `GoTo` bindings the factoriser emits for shared failure branches. E is
  lowered in tail position at a label after Body, and each `(thaw G)` jumps to
  it. E's variables still hold their values there, because Body writes only
  slots above them.
- Otherwise, `(let G (freeze E) Body)` where Body uses G exactly once, as
  `(thaw G)`, and binds no variable of E: the thaw is replaced by E and the
  `let` dropped. E then runs exactly when the thaw would have, with the same
  values, since KLambda variables are immutable.
- Otherwise, `(let G (freeze E) Body)` whose value goes to a slot or a
  register, where Body uses G only as `(thaw G)` in positions whose value is
  Body's, makes no closure either: Body and E, at a label after it, give their
  values there as an inlined loop's exits do, and go on after both. Calls of
  the functions of loops around it are calls there, as in a loop that is not in
  tail position. Typed code takes the value's kind, float or fixnum, from
  Body's and E's.
- `(is X Y B L K (freeze E))` and `is!`, with L and K variables, numbers or `[]`: unification,
  which returns the variables it bound or false, then E, and undoing them if E gives
  false. No closure is made. E is then never a tail call.
- `(shen.bind! X Y B (freeze E))`: the binding, E where the kernel's thaws the closure,
  and undoing the binding if E gives false. No closure is made. The Prolog compiler
  emits these for a variable met by a pattern.
- `(shen.cut B L K (freeze (when false B L K C)))`, with every argument a variable: `!` then
  `(when false)`, which THORN emits for every predicate. The continuation fails, so it is
  `(if (shen.unlocked? L) (shen.lock K L) false)`, with no closure and no call to `shen.cut`.
- A query as the kernel compiles `prolog?`,
  `((((lambda B (lambda L (lambda K (lambda C Body)))) (shen.prolog-vector)) Lock) Key) Cont)`, where every `lambda`
  in Body is a goal as the Prolog compiler passes one to `findall` or `call`, and every `freeze` a continuation, the
  last argument of a call after B, L and K: its vector of bindings is given back
  when Body returns (`shen-jit.prolog-done`), for the next query's `shen.prolog-vector` to take. A query that makes
  any other `lambda` or `freeze` keeps its vector, which that closure may read later, and so does one whose Lock, Key or Cont
  names B, L or K, as they are evaluated inside those bindings.
- `(= (shen.deref X B) (shen.deref Y B))`, with B and Y each a variable, a number or `[]`, which the Prolog compiler makes of
  `(when (= X Y))`: `(shen-jit.deref= X Y B)`, which dereferences as it compares and copies neither term.
- `(let G (freeze E) Body)`, where Body uses G only in `(thaw G)` and as the last argument
  of `shen.bind!`: each use takes a copy of E, within a limit of 100 nodes for the copies.
  The Prolog compiler emits these for atom patterns, a closure made before the test. When E
  is too large to copy and Body is `(if C1 U1 (if C2 U2 false))` with simple tests, the
  tests run first and the closure is made only if one passes.
- A call inlined with an argument `(freeze E)` whose parameter the body only thaws, once,
  as in `(when T B L K (freeze E))`: E runs there, and no closure is made.
- `(let X (lambda P1 ... (lambda Pn E)) Body)`, where Body uses X only
  applied to n arguments, `((X A1) ... An)`, binds no free variable of the
  lambda again and never uses P1 ... Pn, makes no closure: each application
  becomes `(let P1 A1 ... (let Pn An E))` and the `let` is dropped. These
  are the bindings the Prolog compiler emits for head patterns. The
  arguments are evaluated in the same order as before, then E, with the same
  values. Every use but one copies the lambda, so the copies may add 1,500
  nodes of normalised code at most; normalisation works from the inside out,
  so an outer lambda is measured with its inner ones already copied.
- A call to a sealed function inlined with an argument `(lambda P1 ... (lambda Pn E))` whose parameter the
  body only applies to n arguments, as `(define then X F -> (F X))` does, is the same: each application
  becomes `(let P1 A1 ... (let Pn An E))`, under the same conditions, and no parameter of the function may name
  a free variable of the lambda. Making a closure has no effects, so the lambda moves past the arguments
  after it. A call to an open function binds each argument first, for the call it makes if the function was
  redefined, so a lambda passed to one is still a closure.
- `(type X T)` is X; T is not evaluated. They are taken out before anything else, unless `type` names a
  variable there, so a definition the kernel's type annotator went through, as typed code is under
  `(optimise +)`, lowers to the code it would without them, inline form included, but for floats below. The
  port marks such a definition's body `(shen-jit.annotated Body)`; only there do the types count, and
  elsewhere a type form is only taken out.
- A definition with type annotations whose parameters include one annotated `(type P float)`, or that
  has a float literal, `shen-jit.f64`, `shen-jit.float` or `shen-jit.sqrt`, or a parameter annotated
  `(type P fixnum)` or `(type P word.t)`, or that has `float`, `fixnum` or `word.t` anywhere among its
  annotations, keeps floats in float registers and fixnums and 64-bit words in word registers, unboxed:
  - Each `float` parameter is read from its slot into a register on entry with `float-number`, checked
    and converted as arithmetic would, so an integer becomes a float and anything else raises. Each
    `fixnum` parameter is read with `word-number`, which raises for anything but a fixnum, and each
    `word.t` parameter, a word of `lib/word.shen`, with `word-load64` from its 8 bytes.
  - An expression gives a fixnum in a word register when it is a fixnum literal, a fixnum variable, or
    `+`, `-`, `*`, `shen-jit.bit-and`, `shen-jit.bit-or` or
    `shen-jit.bit-xor` over two of them, `shen-jit.shift-left` or `shen-jit.shift-right` of one by
    another, `shen-jit.clz`, `shen-jit.ctz` or `shen-jit.popcount` of one, a read of `shen-jit.u8`, `u16`, `u32` or `s32`, which is
    `word-load8` and the others at a fixnum index, `shen-jit.truncate` of a float, which is
    `fix-from-float`, or a `let`, `do` or `if` whose value does. Arithmetic is `fix+`, `fix-` and `fix*`, which raise "integer
    overflow" as `+` does, and comparisons of two are `word-unless` jumps. `shen-jit.quotient` and
    `shen-jit.remainder` are boxed, as any other primitive there. A shift right by a constant count up to 63 is
    `word-sar`; a shift left by one up to 61 is `word-shl` by the count and 2 more, then `word-sar` by 2, which drops what
    leaves the 62 bits, as the primitive does. A shift by any other count is `fix-sar` or `fix-shl`, which test it, and
    the counts of bits are `fix-clz`, `fix-ctz` and `fix-popcount`. Two sums of a fixnum variable `P`, as a loop's
    steps, are `word+`, with no check: in the branch of an `if` where its test says that `P` is less
    than another fixnum, `(< P E)` or `(> E P)` true, or `(>= P E)` or `(<= E P)` false, `P` plus a
    constant that is not negative; and in the arguments of a loop's own call that read or write bytes
    at `P` itself wherever they run, not under an `if`, `and`, `or` or closure, `P` plus another fixnum, as
    the access succeeds only for `P` from 0 to the length. `E`, and the fixnum added to such a `P`, must
    be exact, not possibly such a sum: a constant, a call's result, a checked primitive's, which is a
    fixnum whatever it reads, a variable in a slot, or one in a register that no such sum, nor a bit
    operation or shift of one, may have reached; a loop's parameter may be reached by what its own calls
    pass it, or for an inlined loop what it starts with, unless they pass it on as it is. Either sum is exact in 64 bits, and cannot be
    stepped so again without the test or the access finding it a fixnum; past the greatest fixnum it
    raises where it is boxed, as `word-box` checks, or at the access, and comparisons see its value. The last sum or difference of
    an index into bytes is `word+` or `word-`: of two fixnums it cannot leave 64 bits, and one that is no
    fixnum is past the end of any bytes, so the access raises for it, where `+` would have raised
    "integer overflow". A float computed from a fixnum takes it with `float-from-word`, and a read or a
    store of a float at a fixnum index is `float-load-at` or `float-store-at`; at a fixnum X times 8, as `(fx* X 8)`
    and `floats.get` give it, through the lets that inlining leaves, it is `float-load-index` or
    `float-store-index` at X, which the access scales, so no product is computed or checked, and an X past the
    doubles raises as an index past the end.
  - An expression gives a 64-bit word in a word register when it is a `word.t` variable, a `let`, `do` or
    `if` whose value does, or `(shen-jit.word-op Op X Y)`, with Op a constant, of words in registers
    where the operation takes words, and of a fixnum in one where it takes a fixnum: `wof` of a fixnum,
    which is its register, `wget` of bytes and a fixnum index, which is `word-load64`, or
    `word-load-index` at X where the index is X times 8, as `words.get` gives it, `w+`, `w-` and
    `w*`, which are `word+`, `word-` and `word*`, and `wand`, `wor`, `wxor`, `wshl`, `wshr`, `wsar`,
    `wrotl` and `wrotr`, which are `word-and` and the others, a count taken modulo 64. `wfixnum` of a
    word is a fixnum, `fix+` of it and 0, which raises "integer overflow" for a word that is no fixnum,
    and `wfloat` a float, `float-from-word`. `w<`, `w<=`, `wu<` and `wu<=` of two words are `word-unless`
    jumps, `-u` for the unsigned two, also as values, and `(shen-jit.copy-bytes B I W 0 8)`, W a word, is
    `word-store64`, or `word-store-index` at X times 8. A word goes into a slot as 8 new bytes, `shen-jit.bytes` and then `word-store64`, as
    the library boxes one.
  - An expression gives a float when it is a float literal, a float variable, `+`, `-`, `*` or `/` of two
    floats, `shen-jit.f64`, `shen-jit.float`, `shen-jit.sqrt`, or a `let`, `do` or `if` whose value
    does. It is computed with the instructions on registers: arithmetic, `float-sqrt`, `float-load` for
    `shen-jit.f64`. Division is `float-divide`, whose divisor of zero raises as `/` does. A `let` of one
    binds a register. Arithmetic mixing a float with an integer is boxed, as `+` does it, so an integer
    operand that is itself a sum of fixnums keeps its exact value and its overflow check; where a float is
    needed, its result is then read with `float-number`.
  - `<`, `>`, `<=`, `>=` and `=` of two floats are `float-unless` jumps, also as
    values. Mixed comparisons stay boxed, preserving exact ordering when a fixnum cannot be represented
    as a double. `(shen-jit.f64! M I V)`, V a float, is `float-store`;
    `(shen-jit.u8! M I V)` and the other stores of a fixnum V at a fixnum I are `fix-store8` and the others, and
    `shen-jit.s64!` is `word-store64`, or `word-store-index` at X times 8. A store for its value, the bytes, is the store, then them, so a store of a
    store stays in registers too.
  - A value is boxed, with `float-box` or `word-box`, only where it goes into a slot: returned, passed,
    captured, or an operand of anything else. Registers are counted as a stack: those an expression
    took for its own temporaries go back once it is done, and those a statement took, once it is. A
    value that is a `let`, as an inlined body is, is computed into the first register free, and what its
    variables took goes back once it is. An `if` computed into a register gives each branch's value to
    it, with none of its own, and what its test and each branch took goes back after each; and in `(let X V (if C Then Else))`
    computed so, where Else does not read X and X has the last register taken, Else takes that register
    back, knowing nothing of what it held, so that a chain of alternatives, each tried when the one
    before gave nothing, holds one register and not two for each. Any other `if` gives back what its test
    and its then branch took before its else, and what its else took after it; and the body of a
    `(let G (freeze E) Body)` lowered as a label gives back what it took before E: in tail position
    neither falls through, so alternatives that each fail to the next hold none of the registers of
    those before.
  - A sealed call of a C function of one to three doubles giving a double, which `lib/ffi.shen` marks with
    the property `shen-jit.foreign-floats` paired with that installed procedure, gives a float:
    `(float-call1 R F A)`, `float-call2` or `float-call3`,
    a call of the C function itself with the argument registers, which the JIT finds at the first call
    as the stub does. C keeps nothing of the registers, which the JIT saves around it, and such a call
    is no call of a function in the sense below.
  - A tail call of the definition itself, sealed, goes back to a `loop` after the entry reads, with
    `again`. A definition made while sealing is on counts as sealed here, as it is once installed, even
    where it replaces one made unsealed, as a grammar's rule replaces its stub. An argument for a register is computed straight into its parameter's register when no
    later argument reads that register, through the parameter or a variable bound to it, as a loop's
    counters and sums are; otherwise into a new one, moved to its parameter's last. The others go to
    their slots as for any named tail call. An argument that cannot raise or write, a variable, a
    constant, a sum, difference or product of floats, or a sum of fixnums left unchecked, waits until
    no other argument reads its register: a dot product's indices step in place after the sum that
    reads them. The others keep their order, left to right.
  - A loop inlined (below) is a `loop` of its own inside the caller's code. A parameter that its calls of
    itself pass on as it is, given `true` or `false` there, is that constant in its body, so that a test of it
    goes, in loops inlined into it too; `(if true X Y)` is X. Its parameters go to
    registers of their kinds, or slots, of their own where its calls of itself change them; then come
    the head and the body, whose tail calls of the loop's function go back to that head with `again`, as
    above. Its other tail positions are the caller's tail positions when the loop is in one, and
    otherwise exits: the value goes into a register, a slot, or nowhere, for its effect, and the code
    jumps past the loop. An exit that calls `shen.f-error`, which raises, stays a tail call. What the loop
    gives, a float, a fixnum or neither, is what its exits give.
  - Registers keep nothing across a call of a function or into a handler, so if some way on from a
    `call`, `call-sealed` or `call-value` reads or writes a register or goes back to a loop before it
    leaves the definition, by a return, a tail call or `simple-error`, as the calls that make an error's
    message do not, or the code has a `push-handler`, or computes nothing in a register, which would only
    box what it read again, the definition is lowered as usual instead, its body normalised again with
    no typed body or loop inlined, as those would only box their values. So is one needing more than 64
    float or 16 word registers.
- `(and A B)` and `(or A B)` short-circuit and must produce a Boolean. In value
  position they lower as `(if (and A B) true false)` and
  `(if (or A B) true false)`, whose tests become jumps; this also checks that B
  is a Boolean. In a test, `(let X V T)` and `(do V T)` evaluate V and then
  test T with the same jumps, so the factoriser's `let`-bound selectors make
  no Booleans. Nor does an inlined call's guard: `(if C T1 T2)` in a test
  tests C, then T1 or T2, unless a branch is a constant, as in `not`, whose
  Boolean the JIT follows to the one jump it takes.
- `(cond (C1 E1) ... (Cn En))` is a chain of tests. A clause whose test is the
  literal `true` ends the chain, and later clauses are dropped. If no clause
  holds, the chain executes `raise-cond`.
- `(trap-error X H)`: push a handler, evaluate X (never in tail position), pop
  the handler and continue. At the handler label, `exception` loads the error,
  H is evaluated and applied to it. When H is a literal `(lambda E Body)`, the
  lowerer binds E to the exception and lowers Body inline instead of creating a
  closure. The handler application is in tail position when the `trap-error`
  is. When Body does not use E, the handler label has no `exception`: such a
  handler is *quiet*, and an error raised while it is the innermost one
  builds no exception object.
- `((lambda X Body) A)` is `(let X A Body)`, so no closure is made; further
  arguments apply to the result. The kernel's compiler writes calls to other
  packages' functions this way.
- A call whose head is a lexically bound variable, or any non-symbol
  expression, is dynamic. With more than one argument it is applied one
  argument at a time: `(F A B)` evaluates F and A, applies, and only then
  evaluates B. With no arguments it is a thunk call.
- When every argument of such a call is a variable or a constant,
  evaluating them early changes nothing. F is evaluated first, then
  `jump-unless-entry` tests it: a closure that takes all N arguments at
  once gets one `call-value` (or `tail-call-value`) with N arguments, and
  anything else is applied one argument at a time, reading the same slots
  again.
- `(lambda X1 ... (lambda Xn Body))`, n >= 2, with X1..Xn distinct, lowered at runtime (not at
  stage 0) with Body at most 400 nodes, starts with `(entry n L)`: its usual
  one-argument code follows, and at L a second copy of Body, with X1..Xn in
  slots 2..n+1 and the outer lambda's captures. The inner lambdas take one
  argument each, as before. Stage 0 code has no entries: the kernel does not
  apply its own chains to several arguments, and its lambda forms would
  grow the image by 5%.
- A call whose head is a fixed name lowers to `prim`, or for special forms, to
  the rules above. Fixed names are the primitives, the special forms (`if`,
  `and`, `or`, `cond`, `let`, `lambda`, `defun`, `freeze`, `type`,
  `trap-error`) and `do`, `thaw` and `protect`. A fixed name used with the wrong number of
  arguments, or a malformed `cond` clause, is a lowering error.
- Any other symbol head is a named call: `call-sealed` when the name is
  sealed, `call` otherwise.
  - At stage 0, every name defined in the stage 0 input is sealed.
  - In Shen/JIT, so are the kernel, port and lowerer definitions, and,
    while sealing is on (`shen-jit.seal`), every definition installed then.
    Redefining a sealed name raises "F is sealed and cannot be redefined".
  - Sealing also allows a name not defined yet: its call's constant slot
    holds the symbol until the first call binds it.
- A sealed call with as many arguments as the callee's parameters is inlined
  when the callee's code carries an `Inline` body. A body qualifies when it
  is at most 15 nodes, or 48 when it calls only primitives and such bodies, which it may then be at any
  depth, has no handlers and no `eval-kl`, does not call its own name and, at stage 0, has no float
  literals, as the host may print one with other last bits. A closure it makes becomes one of the caller's own
  lambdas, capturing the parameter's variable. A number argument replaces its parameter
  in the body, unless a parameter is named `let` or `lambda`, so that `(vector 1)` lowers to `(absvector 2)` and a constant
  length, and a float stays a constant of the code computing with it. A body that is then a constant,
  with no parameter left, is that constant, which its caller takes as an operand. A small body whose
  code calls nothing, not even in tail position, but where an error's message is made carries
  `(Params Body contained)`: where the callee is sealed it inlines at any depth and is no level, as its
  own code inlined all it calls and it cannot be redefined, so that a loop over helpers that read a
  buffer keeps its values in registers. An error's message, the argument of `simple-error`, inlines
  only bodies of primitives: it is code no correct run reaches, and a contained body could otherwise
  reach itself through messages that call each other. Stage 0 knows bodies from their source, not from
  their code, so lowering for it, as the self-hosting check does too, takes a contained body as any
  small one. A definition with
  type annotations whose code keeps values in registers carries `(Params Body typed)` instead when it
  is not small, up to 800 nodes, or `(Params Body calling)` when that code calls on its way out,
  inlined only into a definition that keeps values in registers: a typed body at any depth where the
  callee is sealed, as its own code inlined all it calls and it cannot be redefined, and two levels
  deep otherwise, and a calling body two levels deep, as its calls could reach it again. One whose code is a loop, its own tail calls,
  carries `(Params Body loop Kinds)`, Kinds saying where each parameter goes, and such a definition
  inlines it where the callee is sealed, two levels deep at most, as a loop of its own (above): its arguments stay arguments, and
  its calls of itself stay calls, which the loop makes jumps. The other arguments are bound to fresh variables, then the
  parameters to those, and the body follows, normalised in its own scope. A
  fresh variable bound to a variable, and each parameter, share a slot with
  what they are bound to, so inlining adds no moves. Inlining nests two
  levels at most, but for the bodies above that inline at any depth. Stage 0 inlines too, so the kernel's calls to its own
  small functions are inlined. Outside stage 0 the body's code is marked
  `(inline F N)`, so that backtraces still show F.
- A call to an open F with such a body is inlined too, behind `(if
  (shen-jit.inlined? F Inline) Body (F X1 ... Xn))`, the arguments bound to
  fresh variables first. `shen-jit.inlined?` tests that F's definition is
  still the code whose `Inline` is that very list: compiled code on arm64 and x86-64
  makes it a nop that a redefinition of F patches into a branch to the call,
  and elsewhere tests it each time.
- `((fn F) X1 ... Xn)`, for a sealed F of arity n >= 1, is the named call
  `(F X1 ... Xn)`. F's lambda form would apply F to the same arguments, and F
  cannot be redefined.
- A fixed name gets neither this rule nor the next: `(fn F)` is called and its result applied.
- For an open F, which is how the kernel calls a function it did not know
  when compiling (one in another package, or defined later at the top
  level), the arguments go to fresh variables, then `(shen-jit.arity? F
  n)` chooses between the named call and applying `(fn F)`, which curries
  and raises "fn: F is undefined". The arguments are evaluated before `fn`,
  which only shows when F is undefined.
- Malformed forms (a non-symbol parameter, a `lambda` without exactly one
  parameter, duplicate `defun` parameters, a `let` binding a non-symbol, a
  `defun` that is not at top level) raise an error. So does a `defun` of a
  fixed name, except that stage 0 lowers the kernel's own definitions of `do`,
  `thaw` and `protect`.
- In a definition with type annotations, and in what is inlined there from definitions that had them,
  a call of a sealed struct reader is `(prim D shen-jit.field O (const K))`, K being the field's place,
  which `defstruct` records after installing the reader, paired with that procedure in `shen-jit.struct.field`:
  the typechecker has shown that the value is that struct, and the lowerer checks that it is still that reader.
  A write keeps its check, which also refuses a vector shared between
  isolates, and so does a read in an untyped body inlined into typed code.
- `(eval-kl X)` is a sealed call to the port's `shen-jit.eval-kl`
  (`src/port/shen-jit.kl`), which lowers X in guest code, installs it with
  `shen-jit.install` and, for an expression, runs it. It cannot be a C
  primitive, because C never calls guest code.
- `(protect X)` is X. The kernel defines `protect` as the identity, and
  backends treat it as one, as the kernel's own CL backend does.
- `(cons A B)` where A and B are constants and B is a proper list, of fewer
  than 64 nodes in all, is a constant list made by the lowerer, so a list
  literal such as `[a b c]` allocates nothing when it runs. Pairs are
  immutable and `=` compares structure, so a shared list and a fresh one
  cannot be told apart.
- `(cons (const A) (cons ...))` computed into a slot that is not a parameter's
  computes its tail into that same slot, so a long chain with constant heads
  takes one slot.
- `(+ A B)`, `(- A B)` and `(* A B)` of two integer constants below 10^9 in magnitude
  are their result, as a constant.
- A definition whose body (or a branch of it in tail position) is `(if C X
  Y)`, with C a chain of `and`s and `let`s, as factorised pattern matching
  produces, becomes nested `if`s inside C's lets, each failing to a frozen Y,
  so a label: X then uses a let's variable wherever it would take the same
  part of the argument again with `hd` and `tl`. Only when X has such a
  part. A test whose else is a jump to a label jumps there itself.
- Constants are shared within a code object only when they are identical
  literal strings, symbols or Booleans, or numbers that are `=` and print
  identically, so 8 and 8.0, and 0.0 and -0.0, stay distinct, and a NaN is
  never shared; lists when their elements are shared by the same rule.
- A value with no literal syntax inside code passed to `eval-kl` at runtime (a
  closure, absvector or stream) is a constant, as in Shen/Scheme, and is never
  shared with another.

## Guarantees of lowered code

The lowerer's output also satisfies the following, which `src/lowerer/check.shen`
verifies and the JIT may rely on:

- Jumps only go forward; lowered code has no loops other than calls, but for a definition with
  unboxed floats, whose own tail calls go back to its `loop` with `again`, as do those of the loops it
  inlines, each a `loop` of its own, which stage 0 never makes.
- There is no unreachable code, and code never falls off the end.
- Slots 0 and 1 are never written. A parameter slot is written only by a
  named tail call's arguments, and is not read afterwards except by that tail
  call.
- Each nested code object is created by exactly one `closure` instruction.
- Every slot is written on all paths before it is read, counting a call as
  overwriting every slot from its window up.
- Handler pushes and pops are balanced on every path; no handler is active at
  a `return` or tail call.

The JIT relies on the jumps, the slots and the handlers among these, and on two
things more, also checked: handlers nest in the order of the code, since it tracks
them that way, and a handler reads no slot written since its push, since it may not
store a result that the code after it never reads. The lowerer's other habits, such
as leaving parameters alone, are its own: code written by hand need not share them.

Slot assignment is scope-based, so windows sit above every variable in scope
and every pending temporary. A chain of `cons` with constant heads takes one slot
(see the lowering rules), and most frames are 16 slots or fewer. The lowerer also
keeps a call's result slot below its window, which is not checked.

## Native code written by hand

`lib/native.shen` lets a Shen program write these instructions itself. It stays
out of the image: load it under `(tc -)`, before the file that uses it, since a macro
applies only to files read after it is defined.

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
```

An operand follows Shen's conventions: a variable is a slot, a symbol is itself, and
anything else is a constant, so `[1 2]` is a list. `(const E)` is the value of the
expression E when the definition is evaluated, or a variable of the function around it
when `define-native` is used inside one. As in any definition, a constant holds only what
code can: symbols, numbers, strings, booleans and lists of them; a definition with another
value, such as a vector, is refused when it is installed.

| Form | Meaning |
| --- | --- |
| `(move D O)` | D := O. |
| `(prim D Op O1 ... On)` | D := primitive Op applied to O1..On. |
| `(label L)`, `(jump L)`, `(jump-if-false O L)` | As above, with L a symbol. Jumps only go forward; `again`, below, goes back. |
| `(call D F O1 ... On)` | D := F applied to O1..On, sealed if F is. If F is a variable, a call of its value, with no or one argument. |
| `(tail-call F O1 ... On)` | The same in tail position. |
| `(return O)` | Return O. |
| `(closure D (P) (C1 ... Cn) I1 ... Im)` | D := a closure of the instructions I, taking P or nothing, and seeing C1..Cn under the same names. |
| `(push-handler L)`, `(pop-handler)`, `(exception D)` | As above. |

The builder numbers the slots: the parameters from 2, then the other variables as
they first appear, with call windows above them all, and it works out the frame.
These decide what a loop costs:

- A parameter may be overwritten, and read afterwards.
- A tail call's arguments go straight to slots 2.., and one already there costs
  nothing. So a loop is a tail call of the function's own name with its arguments in
  place, as above, which the JIT compiles to a jump.
- Call-free loops keep their slots in registers when all of them fit (HOMES in `jit.c`:
  6 on arm64 and 4 on x86-64, or 2 outside Windows in code that also keeps raw integers
  in registers). One slot too many and none is kept there, so a loop should use few.

### Structured control

These forms become the labels, loops and jumps above, with labels of their own, before anything else is done, so
what they make is checked like any other code and runs the same:

| Form | Meaning |
| --- | --- |
| `(if Test Then)`, `(if Test Then Else)` | One statement or the other. `(do S1 ... Sn)` is several as one. |
| `(when Test S1 ... Sn)`, `(unless Test S1 ... Sn)` | The statements if Test holds, or if it does not. |
| `(while Test S1 ... Sn)` | The statements for as long as Test holds, tested first. |
| `(for I From To S1 ... Sn)` | Word register I from From up to and not including To, by 1, To read each time round. |
| `(block Name S1 ... Sn)` | The statements, which `(exit Name)` leaves. |
| `(exit)`, `(next)` | Leave the innermost loop, or go round it again. |
| `(exit Name)`, `(next Name)` | The same for the loop or block named. A loop is named by a symbol after `while` or `for`. |

A test is a comparison of two operands, `(< A B)`, with `>`, `<=`, `>=`, `=`, `!=`, and unsigned `u<`, `u>`, `u<=`
and `u>=` for words; `(and T1 ... Tn)`, `(or T1 ... Tn)` and `(not T)`; `true` and `false`; or a slot holding a boolean.
A comparison is of floats if either side is a float register or something only floats give, as `f64`, `sqrt`, `/` or a number
with a fraction, and of words otherwise. NaN makes a comparison of floats false.

```shen
(define-native count-byte (Data Start End Byte)
  (word Count 0)
  (for I Start End
    (when (= (u8 Data I) Byte)
      (word Count (+ Count 1))))
  (return-word Count))
```

A join that nothing reaches is left out: an `if` whose arms both return has nothing after it, and a loop whose body
always leaves it does not go round, as the checker refuses code it cannot reach. Code after a form still has to be
reachable, or the function has to return, as anywhere. `(shen-jit.expand-native Statements)` gives the instructions
these become, for reading or for a program to build on.

Code a program generates is data, not forms:

- `(shen-jit.assemble Name Params Body)` gives the code object of instructions in the
  same shape, as lists. There `[const X]` is a constant, and `(protect X)` writes a
  variable.
- `(shen-jit.install-code Form)` checks and installs a code object, from `assemble` or
  written by hand with slot numbers and any instruction of the table above. `(defun F
  Code)` publishes F and returns it; a code object returns a closure of it, with no
  name, so generating many procedures uses up no symbols.
- `shen-jit.install`, which `eval-kl` uses, checks only operand shapes and ranges, windows, labels and how the code ends. Wrong code
  given to it can crash.

The checker holds the rules the lowerer's output is checked against, in
`native.shen`: see "Guarantees of lowered code". Hand-written code differs in that
it may overwrite parameters, a sealed call needs only a sealed target, and constants
may be any value. `make test-native` has code to run and code to refuse, and `make
fuzz-native` mutates code objects and runs what the checker accepts: a crash means it
accepted something the JIT cannot compile.

What is in a slot stays tagged, also with byte buffers and bit operations.

### Float and word registers

Doubles can live unboxed in 64 float registers, and 64-bit integers, which wrap, in 16 word registers, each a namespace of
its own. The JIT gives machine registers to what is used most, each loop counting 8 times what is around it, so the numbers and
the order of the names make no difference: 27 float registers on arm64 and 12 on x86-64, and the integer registers a target has to spare,
11 on arm64, 2 on x86-64 and none on Windows, which the base and limits of kept memory compete for too, where registers are many at half
a word's weight: they never change in a loop, so a load of one from the native frame waits on nothing, while a word the loop writes puts
a store and a load in the way of the next iteration. For the same reason a word that a loop carries from one iteration to the next,
reading it before it writes it, counts there as used once more in a loop inside it. Code with loops that has more than
fits also takes the saved registers its slots would have had, 6, 2 and 4, and its slots stay in the frame. The rest are places in the
native frame. The collector does not look at any of them, and the JIT saves what C does not keep to the native frame around any call to
C that returns: a collection, a primitive, an interrupt check. Nothing saves them across a call of a function, so **code using them calls nothing and
has no handlers**, though it may tail call. That is what makes raw values safe here, where a raw frame slot could not
be: the collector reads every slot as a value.

| Form | Meaning |
| --- | --- |
| `(float X E)` | Register X := the value of E. X is then a register wherever it is named. |
| `(f64! M I E)` | Store E at byte offset I of M, checked as `shen-jit.f64!` is. |
| `(jump-unless (Op E1 E2) L)` | Jump to L unless E1 Op E2, with Op one of `<`, `>`, `<=`, `>=` and `=`. NaN compares false. |
| `(float-box D E)` | Slot D := a new float holding E. |
| `(return-float E)` | Return a new float holding E. |
| `(word X W)` | Word register X := the value of W. |
| `(u8! M I W)`, `u16!`, `u32!`, `u64!` | Store the low bits of W at byte offset I of M. |
| `(jump-unless-word (Op W1 W2) L)` | Jump to L unless W1 Op W2, with Op one of `<`, `>`, `<=`, `>=`, `=`, and unsigned `u<`, `u>`, `u<=`, `u>=`. |
| `(word-box D W)`, `(return-word W)` | Slot D := W as an integer, or return that. What does not fit a fixnum raises. |
| `(loop L)` | The head of a loop named L. Code only falls into it, and comes back to it with `again`. Loops nest, and a function may have many. |
| `(again L)` | Jump back to the head of loop L, which must come before this. |

A float expression E is a float register; a word register, converted; a number, a slot or `(const K)`, whose number is read with a check, an integer
converted, and anything else raising; `(+ E1 E2)`, `(- E1 E2)`, `(* E1 E2)`, `(/ E1 E2)`; `(neg E)`, `(abs E)`, `(sqrt E)`;
`(f64 M I)`, read and checked as `shen-jit.f64` is; or any word expression below that only words can be, converted. `(+ A B C)` is `(+ A (+ B C))`, as Shen's macro makes it.

A word expression W is a word register; an integer, or `(const K)` holding one; a slot, which must hold an integer; `(+ W1 W2)`, `(- W1 W2)`, `(* W1 W2)`, `(neg W)`;
`(bit-and W1 W2)`, `(bit-or W1 W2)`, `(bit-xor W1 W2)`, `(bit-not W)`; `(shift-left W N)`, `(shift-right W N)`, which fills with zeroes, `(shift-right-signed W N)`, `(rotate-left W N)`,
`(rotate-right W N)`, whose counts are taken modulo 64; `(u8 M I)`, `(u16 M I)`, `(u32 M I)`, `(s32 M I)`, `(u64 M I)`; `(ctz W)` and `(clz W)`, the
trailing and leading zeros of its 64 bits, 64 for zero; `(vmask V)`, below; or `(truncate E)`, toward zero, of a float expression, which is the machine's own beyond 64 bits.
Arithmetic wraps and raises nothing. A literal has to fit a fixnum, so a wider constant is built, once, before the loop.

The index of `u8` to `u64` and their stores is a word expression. So is that of `f64` and `f64!` when it is an integer or mentions a word register, with no tag to check and only the bound; any other is integer arithmetic through `prim`, as `(+ I 8)` on slots. A word index is checked as an unsigned number, so a negative one fails the bound. Intermediate values take registers too, named `Float.0`, `Word.0` and on, so a register written by hand may not take
such a name, and more than the registers there are is refused. A test that is `true` or `false` keeps only the branch
that runs.

### Vector registers

16 vector registers each hold 16 bytes, under the same rules as float and word registers: code using them calls
nothing and has no handlers, the JIT saves them around calls to C, and the collector never sees them. They are the
machine's float registers, which code using vectors shares between the two: the vectors used most take up to half of
them, 13 on arm64 and 6 on x86-64, and the rest live in 16 bytes each of the native frame. Each operation means the
same on both targets: SLJIT emits some of them, and byte equality, maximum, minimum, sum, difference, and-not and
the shift are encoded for each; x86-64 shifts
16-bit lanes and masks, and before its table lookup adds 112 with saturation to each index, which sets the bit that
makes it give 0 exactly from 16 up, as arm64's does.

| Form | Meaning |
| --- | --- |
| `(vector X V)` | Vector register X := the value of V. X is then a vector register wherever it is named. |
| `(v128! M I V)` | Store V's 16 bytes from byte offset I of M, checked as one access of 16 bytes, at any alignment. |

A vector expression V is a vector register; `(v128 M I)`, the 16 bytes from offset I of M, checked the same way;
`(splat W)`, 16 copies of W's low byte; `(v= V1 V2)`, 255 in each byte where the two are equal and 0 elsewhere;
`(vand V1 V2)`, `(vor V1 V2)`, `(vxor V1 V2)`, `(vandnot V1 V2)`, V1 and not V2; `(vmax V1 V2)`, `(vmin V1 V2)`, each
byte's unsigned maximum and minimum; `(v+ V1 V2)`, `(v- V1 V2)`, each byte's sum and difference, which wrap;
`(vshr V K)`, each byte shifted right by K, a constant from 0 to 7, with
zeros; or `(vlookup T I)`, whose byte K is byte `I[K]` of T, or 0 where `I[K]` is 16 or more. With the two, a byte's
high and low four bits pick bits out of tables of 16, which is how `bytes.span` tests 16 bytes against a class at once. `(vmask V)` is the word whose bit K is the top bit of V's byte K, so
that `(ctz (vmask (v= V (splat B))))` is where B first is in V, and 64 when it is not. Intermediate vectors are named
`Vector.0` and on.

| Instruction | Meaning |
| --- | --- |
| `(vec-load X M I)`, `(vec-store M I X)` | 16 bytes at word index I of M, checked |
| `(vec-splat X W)`, `(vec-move X Y)` | 16 copies of W's low byte; a copy of Y |
| `(vec= X A B)`, `(vec-and X A B)`, `(vec-or X A B)`, `(vec-xor X A B)`, `(vec-andnot X A B)` | Bytewise |
| `(vec-max X A B)`, `(vec-min X A B)`, `(vec+ X A B)`, `(vec- X A B)` | Each byte's unsigned maximum or minimum, wrapping sum or difference |
| `(vec-shr X A K)` | Each byte of A shifted right by the constant K, from 0 to 7 |
| `(vec-lookup X T I)` | Byte K := byte `I[K]` of T, or 0 from index 16 up |
| `(vec-mask W X)` | Word register W := the top bit of each of X's bytes |
| `(word-ctz W A)`, `(word-clz W A)` | Trailing and leading zeros of 64 bits |

- **Division is IEEE's:** dividing by zero gives an infinity or a NaN, where `/` raises.
- **A register or slot keeps its value round a loop,** and what comes before a loop's head runs once. To leave a loop, jump
  forward. A loop is checked in one pass: going back must bring everything that was set at the head, and what the head's code reads has
  to be set before the loop, the first time round.
- **A loop checks for an interrupt each time it goes back,** at the REPL, as a self tail call does.
- **Every access is checked,** and those checks are what is left between these loops and C.

The builder turns these into instructions that `shen-jit.install-code` takes too, with registers numbered from 0: `(float-number F O)`, `(float-box D F)`, `(float-move D F)`, `(float-neg D F)`, `(float-abs D F)`,
`(float-sqrt D F)`, `(float+ D A B)`, `(float- D A B)`, `(float* D A B)`, `(float/ D A B)`, `(float-unless< A B L)`, with `>`, `<=`, `>=` and `=`, `(float-load F M I)`, `(float-store M I F)`, `(float-load-at F M W)`, `(float-store-at M W F)`, `(float-from-word F W)`, `(word-from-float W F)`,
`(word-number W O)`, `(word-box D W)`, `(word-move W V)`, `(word+ D A B)`, with `-`, `*`, `word-and`, `word-or`, `word-xor`, `word-shl`, `word-shr`, `word-sar`, `word-rotl` and `word-rotr`, `(word-unless< A B L)`, with `>`, `<=`, `>=`, `=`, `-u<`, `-u>`, `-u<=` and `-u>=`, `(word-load8 D M W)`, with `16`, `32`, `-s32` and `64`, `(word-store8 M W V)`, with `16`, `32` and `64`, `(loop L)` and `(again L)`. An operand of a word instruction that it only reads may be `(const K)`.
The lowerer also uses `(fix+ D A B)`, `(fix- D A B)` and `(fix* D A B)`, as `word+` and the others but raising
"integer overflow" for a result that is no fixnum, for typed code's fixnums, `(fix-store8 M W V)`, with `16`, `32`
and `-s32`, as `word-store8` and the others but raising "bytes: V does not fit" for a value the width does not hold,
after the buffer and the index are checked, as `shen-jit.u8!` and the others do, `(fix-shl D X K)` and
`(fix-sar D X K)`, as `shen-jit.shift-left` and `shen-jit.shift-right` of fixnums, raising their error out of line for a
count outside 0 to 63, `(fix-clz D X)`, `(fix-ctz D X)` and `(fix-popcount D X)`, as `shen-jit.clz` and the others
count a fixnum's bits, `(fix-from-float W F)`, as
`word-from-float` but raising "integer overflow" out of line for a float outside the fixnums, a NaN or an infinity
among them, as `shen-jit.truncate` does, `(float-divide D A B)`, as `float/` but
raising "division by zero" for a divisor of zero, out of line, `(float-load-index F M W)` and
`(float-store-index M W F)`, as `float-load-at` and `float-store-at` but at W times 8, W an index of doubles checked
against the length in doubles, `(word-load-index D M W)` and `(word-store-index M W V)`, the same for 64-bit words, as
`word-load64` and `word-store64` but at W times 8, and `(float-call1 R F A)`, `float-call2` and
`float-call3`, a direct call of the C function of doubles defined as F (see the lowering rules); the checker of code
written by hand has no form for them.

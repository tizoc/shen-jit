# Shen/JIT semantics

The behaviour Shen/JIT implements. The executable [contract examples](../contract/examples.shen) check the main rules below, and their output under Shen/Scheme is recorded in [contract/shen-scheme-0.54.txt](../contract/shen-scheme-0.54.txt).

Where Shen/JIT deliberately differs from Shen/Scheme, the rule says so, and where there is an example, it is marked as a deviation. Shen/Scheme's behaviour was observed by
running KLambda through `eval-kl`, not inferred from its source.

## 1. Inputs

| Input | Version |
| --- | --- |
| Kernel | The release that `tools/ci-deps.sh` names: its `klambda/`, and its tests |
| Stage 0 host | The release of Shen/JIT that `tools/ci-deps.sh` names, or the release of Shen/Scheme it names, which make the same files |
| SLJIT | Upstream commit `a0020dd49a21`: see `vendor/sljit/UPSTREAM.md` |

`tools/ci-deps.sh` fetches the kernel, the earlier release of Shen/JIT and Shen/Scheme by hash, and `generated.sha256` holds the hashes of what they make.

## 2. Values

All values are 64-bit words. The low bits are tags, with the spare pattern used for object headers:

| Low bits | Meaning |
| --- | --- |
| `..00` | Fixnum, 62-bit signed: -2^61 to 2^61-1. |
| `011` | Pair pointer. Pairs are two words with no header. |
| `001` | Pointer to an object with a header. |
| `101` | Pointer to a procedure (an object with a header). |
| `110` | Pointer to a symbol (an object with a header). |
| `010` | Special value; the payload is in the upper bits. |
| `111` | Object header. No value has this pattern. |

A word at the start of a heap object is therefore either a header (`111`) or
the head of a pair. The collector's scan and the image's relocation pass rely on
this. Objects are 8-byte aligned and at least two words long.

Special values: the empty list, `true`, `false`, Prolog variables, the cleared
stack value (also used for unbound cells) and the forwarding marker used during
collection. The cleared value and the forwarding marker are never visible to Shen
code. `(fail)` is the symbol `shen.fail!`, as defined by the kernel, not a special
value.

A Prolog variable holds the offset of its binding in the Prolog vector, from 0 to
2^56-1. As an optimisation it is this immediate value and not the kernel's absvector, so
it allocates nothing and `absvector?` is false of it. `shen.pvar?` is true of it and of
nothing else, two are `=` when their offsets are, and it prints as the kernel's
`shen.pvar` prints one: `Var` and the offset.

Object families, each identified by a type field in its header, which also
states which fields hold values:

| Family | Contents |
| --- | --- |
| String | Byte length and bytes; immutable. |
| Byte buffer | Byte length and bytes, which can be stored to, and which the collector does not scan. |
| Symbol | Name string, name hash; its function cell's index and its global's number, with flags. |
| Real | IEEE double. |
| Absvector | Length and that many values. |
| Closure | Code object and captured values; a `defun` is a closure with no captures. Raw native entry. |
| Foreign function | A C function, its description and arity. Raw native entry and address. |
| Code object | Bytecode, constant slot base, frame size, arity, name. Raw native code pointer. |
| Exception | Message string, and a value that goes before it, or none. An error raised from C keeps the offending value apart; `error-to-string` builds the full message the first time it is asked. |
| Stream | Kind, direction, open flag; raw OS handle. |
| Pointer | Kind and what keeps it alive; raw address and length. Its header says whether it is read only. |
| Shared view | A worker scope's read-only input: raw address and length, cleared when the scope ends and in an image. Equal only to itself; prints as `#<shared-bytes>`. |

There is no partial-application object: KLambda named calls are saturated (see
section 9), so only closures and foreign functions are ever applied.

Symbols live in the program space ([design.md](design.md), "Collection"), in
slots that never move. The hash is computed from the name bytes when the symbol is
created. A symbol that code installed there refers to is published, and stays.
The others are held weakly: a collection drops a symbol that nothing else reaches,
that has no value or function, and that no compiled code calls by name, and its
slot and cell are reused. Interning the name again makes a new symbol, which
nothing can tell from the old one. `(intern "true")` and `(intern "false")`
return the Boolean specials.

Function cells (one per symbol) and constant slots live in root arrays outside
the heap. The arrays grow by adding fixed-size chunks, so no cell moves. The heap
refers to cells only by index; emitted code embeds cell addresses. A code object
owns its range of constant slots: the collector copies them with it, and reuses
them once it is dead (heap.c).

A global's value is in a slot of the VM's own, by a number that a symbol gets
once code names it as a global or it is `set`: a symbol never set and never named
so takes none, and reads as unbound. The slots follow the VM in one block of
address space, committed as numbers grow, so emitted code reads one at a fixed
offset from the VM's register. A dropped symbol's number is reused.

## 3. Numbers

- **Integers** are fixnums only. Any integer result outside the fixnum range
  raises a catchable "integer overflow" error. *Deviation:* Shen/Scheme has
  bignums.
- **Reals** are IEEE doubles. Mixed integer/real arithmetic produces a real.
- **Division:** `(/ A B)` of two integers is an integer when B divides A
  exactly and a real otherwise; any real operand gives a real. A zero divisor,
  integer or real, raises an error. *Deviation:* Shen/Scheme raises only for an integer zero, and a real zero
  gives an infinity or NaN. Other real operations follow IEEE, so infinities and NaN can arise from overflow.
- **Comparison:** `<`, `>`, `<=` and `>=` compare mathematical values across
  integers and reals, exactly, with no rounding of the integer; a non-number
  operand raises an error.
- **Equality:** `=` compares numbers by mathematical value, so `(= 8 8.0)` and
  `(= 0.0 -0.0)` are true, and NaN equals no other value, itself included unless
  both sides are the same object. *Deviation:* Shen/Scheme's `hash` gives 8 and
  8.0 different values.
- **Literals** are computed by the kernel reader with integer arithmetic
  (`shen.compute-integer`, and `shen.expt` for exponents), so a literal beyond
  the fixnum range, such as `1e300`, would overflow. Small overrides of
  `shen.compute-integer` and `shen.compute-E` make such literals the nearest real,
  or next to it if the digits before an exponent were already rounded, in a fraction
  or as more digits than a real holds. "8.0" still reads as the integer 8, as in Shen/Scheme.
  *Deviation:* Shen/Scheme reads such a literal as a bignum. So too the smallest
  fixnum: a minus sign applies after its digits are read, and those alone are past
  the range, so `-2305843009213693952` reads as a real, equal to that integer by
  value. `(- -2305843009213693951 1)` gives the integer itself.
- **Printing:** `str` prints integers in decimal and reals with the shortest
  digits that read back exactly, always with a decimal point or exponent
  (`(str (+ 0.5 0.5))` is "1.0"). The choice between positional and exponent
  notation is not a compatibility requirement.

## 4. Strings, symbols and characters

Strings are immutable byte sequences, and every string primitive works in
bytes; source text and files pass through as UTF-8 bytes without decoding.

- `(pos S N)`: the byte at fixnum index N as a one-byte string; an index outside
  0 to length-1 raises an error.
- `(tlstr S)`: S without its first byte; the empty string raises an error.
- `(cn A B)`: concatenation; a non-string raises an error.
- `(string->n S)`: the first byte; the empty string raises an error.
- `(n->string N)`: a one-byte string for N from 0 to 255, as the reader passes source
  bytes through it, and the UTF-8 bytes of any other Unicode scalar value, as from a
  `c#955;` escape in a string; anything else raises an error. `c#233;` is therefore
  one byte, and `(string->n (n->string 955))` is its first byte. *Deviation:* Shen/Scheme
  also accepts other numbers, and makes a one-unit string of a scalar value.
- `(str X)`: for strings, the text in double quotes; symbols, their name;
  Booleans, "true" or "false"; numbers, as above; the empty list, "()". Other
  values give a description such as `#<procedure>`; `str` never raises.
- `(intern S)`: any string, including "" and "1"; a non-string raises an error.

## 5. Pairs and absvectors

- `cons` accepts any two values; `hd` and `tl` of a non-pair raise an error.
- `(absvector N)`: N must be a fixnum from 0 to below 2^48. Every element starts as the
  symbol `shen.fail!`, as in Shen/Scheme, so the `vector` override need not
  fill elements again.
- `(<-address V N)` and `(address-> V N X)`: N must be within 0 to length-1;
  `address->` returns V. Out-of-range indices and non-vectors raise errors.

The kernel catches `pos` past the end in `shen.string->byte` and `value` of an
unbound symbol in `bound?`, and programs catch such errors too, so they must be
cheap to raise and catch.

## 6. Equality and hashing

`(= A B)` is true when A and B are numbers with the same mathematical value,
strings or byte buffers with the same bytes, pairs whose heads and tails are `=`,
absvectors of the same length whose elements are `=`, pointers of the same kind and
address that are both read only or both not, or the same symbol, special, procedure,
stream or exception. Closures compare by identity.

`=` follows a term as deep as it goes, without overflowing the C stack, and it
cannot raise. On two absvectors that contain themselves, which have no end, it
ends the process with the message `shen-jit: =: the term is cyclic or too large`.
So does a term that, below its first 256 levels of nesting, needs about 1 GB of
comparisons waiting or 2^31 steps.

`(hash X N)`, for a positive N, returns an integer within the bound of 0 to N that the
kernel's port performance guide states, in fact from 1 to N-1, or 1 when N is 1, and
looks at a structure's first 256 values. It is consistent with `=`: numbers
hash by mathematical value (8, 8.0 and -0.0/0.0 agree), strings by bytes,
symbols by their stored name hash, pairs and absvectors by their elements, byte
buffers as strings of the same bytes, and pointers by kind and address.
Procedures, streams and exceptions hash by family, since a moving collector
gives them no stable address. *Deviation:* Shen/Scheme's hash distinguishes 8
from 8.0.

## 7. Globals

KLambda keeps separate value and function bindings. `(set S X)` requires a
symbol and returns X. `(value S)` of a symbol with no value raises a catchable
error; a non-symbol raises an error.

## 8. Errors and handlers

- `(simple-error S)` raises an exception with message S; a non-string raises an
  error instead.
- `(error-to-string E)` returns the message of an exception. *Deviation:* a
  non-exception raises an error; Shen/Scheme returns a description.
- `(trap-error X H)` evaluates X; if X raises, it applies H to the exception.
  If H is not a procedure, applying it raises a new error that propagates
  outward. X is never in tail position.
- Every primitive error is an ordinary catchable exception. Message wording is
  informative but not a compatibility requirement; the examples check only that
  an error occurred, except for `simple-error` messages and the kernel's messages from `get`.
- Messages name the offending value in Shen notation, cut after 60 bytes, as
  in `hd: 5 is not a pair`; arity errors name the function and both
  argument counts.

## 9. Control forms and application

- `if`, `cond`, `and` and `or` require Boolean conditions and raise an error
  otherwise. `and` and `or` short-circuit, and the second operand must also be
  a Boolean, as in Shen/Scheme.
- `cond` with no true clause raises an error.
- `let` binds one variable; `lambda` takes exactly one parameter; `freeze`
  creates a thunk; `type` returns its first argument and does not evaluate the
  second.
- A symbol in value position that is not lexically bound evaluates to itself.
- **Named calls** `(f A1 ... An)`, with `f` not lexically bound, call `f`'s
  function binding. If its arity differs from n, the call raises an error; if f
  has no function binding, the call raises an error. This matches Shen/Scheme.
  The Shen compiler already turns Shen-level partial applications into lambdas,
  and the kernel, stlib and extension KLambda contain no named call with
  the wrong argument count.
- **Other applications** `(E A1 ... An)` evaluate E, which must be a procedure.
  A unary closure applied to more arguments applies the result to the rest, left
  to right, and a thunk takes no arguments, so applying one to any raises an error.
  Applying a closure to too few arguments, or applying anything that is not a
  procedure, raises an error.
  *Deviation:* `((fn F) A1 ... An)`, where F is not sealed and takes fewer than n
  arguments, evaluates A1 ... An before applying F to A1, where Shen/Scheme applies
  it before evaluating A2: the arguments are evaluated once, before a test of F's
  arity chooses between a named call and the lambda form. It shows only when those
  applications and the later arguments affect each other, which code compiled from
  Shen was not seen to do.
- **Order and tail calls:** arguments are evaluated left to right, after the
  operator of an application. A call in tail position, and the last form of `do`,
  uses no stack, including between different functions.
- **Symbols are not procedures.** Applying a symbol raises an error, as in
  Shen/Scheme, where `(map f L)` with a bare function name fails; Shen code uses
  `(fn f)` or `(function f)`.

## 10. Definitions, redefinition and sealing

- `(defun F Params Body)` returns F. The lowerer validates the form; malformed
  definitions raise an error and leave any previous binding in place.
  *Deviation:* Shen/Scheme accepts some malformed bodies, such as a bare
  `(lambda)`, and fails only when they run.
- A definition is published only after it is fully prepared. Replacing a
  binding never invalidates existing closures or active frames; open calls see
  the new binding on their next call, and the arity may change.
- **Fixed names** are lowered directly and cannot be redefined: `defun` of one
  raises an error. They are the 39 KLambda primitives (`input+` is not one; the port
  defines it), the special forms `if`, `and`, `or`, `cond`, `let`, `lambda`,
  `defun`, `freeze`, `type` and `trap-error`, the kernel functions `do`, `thaw` and
  `protect`, and the port's `shen-jit.*` primitives. A primitive or special form
  with the wrong number of arguments is malformed: it raises when lowered, so a
  `trap-error` in the same form does not catch it. *Deviation:* Shen/Scheme accepts such a `defun` but its compiled
  calls ignore it.
- **Sealing:**
  the kernel, port code and the lowerer are sealed. Calls to them, from the
  kernel and from user code alike, are bound once, and a `defun` of one of
  their names raises "F is sealed and cannot be redefined". The extensions
  stay open, since their tests reload their sources, but for `shen.x.launcher.main`,
  which the port replaces. `(shen-jit.seal +)`, `--seal` or `SHEN_JIT_SEAL=1` also
  seal user definitions. *Deviation:* Shen/Scheme accepts such a `defun`. Its calls
  within the kernel keep the original: after an `eval-kl` `defun` of `shen.misc?`,
  `shen.alpha?` still uses it. Calls from its user code are bound when compiled, so
  code compiled before the `defun` keeps the original. A Shen-level `define` of a
  system function is rejected by the kernel in both.
- **`defun`** is valid only as the whole form given to `eval-kl`. Nested, it raises
  an error.
- **`define` is factorised.** What it produces is evaluated through the kernel's
  `shen.factor`, which tests a condition that consecutive clauses share once, and
  reads a part of the argument that several clauses use once, before them. Guards
  should therefore have no effects, including on the value being matched.
  *Deviation:* the kernel, and Shen/Scheme, evaluate a definition as written,
  unless `(factorise +)` is set. So a guard that two consecutive clauses share runs
  once, not once a clause: with `X -> a where (and (tick) (= X 1))` and
  `X -> b where (and (tick) (= X 2))`, `tick` runs once. A guard that changes the
  vector being matched leaves later clauses the element read before it. And a vector
  pattern can read its first element before a clause that does not need it: with
  `(@v _ (@v 0 <>)) -> ok` before `(@v 1 _) -> one`, a vector whose first element
  was never set raises `hdv needs a non-empty vector as an argument`, where the
  kernel gives `ok`. The kernel's factoriser does the same with `(factorise +)`.

## 11. `eval-kl`

`(eval-kl X)` lowers X in guest code and installs the result. A `defun` returns
its name; any other form returns its value. Malformed forms raise an error.
`eval-kl` never enters C recursively. X that is not a list is its own value,
returned without lowering.

A definition's lambda form, which `fn` returns, is made the first time `fn`
asks for it, not when the definition is read; `shen.*gensym*` still moves as
if it had been made then. *Deviation:* until then, reading the
`shen.lambda-form` property directly gives a placeholder, an absvector tagged
`shen-jit.lazy-form`, where other ports give the closure.

## 12. Streams, files and time

- `(open Path Direction)`: Path is a string, Direction is `in` or `out`. The file
  opened is `(cn (value *home-directory*) Path)`, resolved by the operating
  system. `out` creates or truncates. Failures raise errors.
  Linux runtime files are opened with close-on-exec, including files used for
  loading code and saving images, so they do not leak into spawned children.
- `*home-directory*` starts as "", so relative paths resolve against the process's
  working directory, as in Shen/Scheme. Startup does not change it, and
  `shen-jit.save-executable` saves it as "".
- `(read-file-as-bytelist Path)` and `(read-file-as-string Path)` read the
  whole file in C, as Shen/Scheme's overrides do, with the path resolved as for
  `open`. An open failure raises; a read failure raises with the system's message
  instead of returning partial data. The kernel's read one byte at a time.
- `(read-byte S)`: a byte from 0 to 255, or -1 at end of file. A file read error
  raises with the system's message. On systems that open a directory as an input
  stream, reading it raises rather than treating it as empty.
- `(write-byte B S)`: B from 0 to 255; returns B. Output is buffered, so a failed write raises
  an error here only once the buffer fills, or else from `close`. Writing to a pipe that nobody
  reads is such a failure, and does not end the process, so that `shen-jit script f | head` can
  end with `write-byte: Broken pipe` and status 1 if nothing catches it. Output still buffered
  when the process ends is dropped silently. A child process finds `SIGPIPE` at its default.
  `(shen-jit.write-bytes B I N S)` writes N bytes of a buffer from I the same way, at once, and returns N.
- Reading from an output stream, writing to an input stream, or using a closed
  stream raises an error. `(close S)` returns the empty list, and raises an error if what was
  left to write could not be written; the stream is closed either way. Closing a closed stream
  does nothing. A collection closes a file stream that nothing reaches, which writes what was
  left but cannot report a failure.
- The standard streams are `*stinput*`, `*stoutput*` and `*sterror*`. Output to
  `*stoutput*` is flushed before any read from `*stinput*` and at exit.
- `(char-stream? S)` is false for every stream. `read-unit-string` and
  `write-string` raise "character streams are not supported", as in
  Shen/Scheme; the kernel only calls them for character streams.
- `(get-time run)` returns CPU seconds and `(get-time unix)` wall-clock seconds
  since the epoch, both as reals. Other arguments raise an error. *Deviation:*
  Shen/Scheme also accepts `real`.

## 13. Stage 1 order and extensions

Stage 1 runs, in order: install the stage 0 definitions; set `*os*`,
`*language*`, `*implementation*`, `*release*`, `*port*` and `*porters*`; call
`shen.initialise`; call `shen.x.features.initialise` with the feature list
`[shen/shen-jit]`, then `shen.x.programmable-pattern-matching.initialise` and
`shen.x.namespaces.initialise`, and `shen-jit.initialise`, which registers the port's
functions and defines `thread`; write the image, in which file streams are closed.
`make stlib` loads the standard library later, into a running image, and calls
`stlib.initialise` there.

This follows Shen/Scheme's build. The factorise-defun, expand-dynamic and
type-annotations extensions are not initialized. As built, what `define`
produces is evaluated factorised by the kernel's `shen.factor`, as with
`(factorise +)` (section 10); `ps`
shows the definition as `define` produced it, and `shen.*factorise?*` stays
false, as in Shen/Scheme. The command line is the
kernel's launcher extension: `main` passes the process arguments to
`shen.x.launcher.main`, which provides the `repl`, `script` and `eval` commands
Shen/Scheme also uses, so Shen/JIT needs none in C beyond `--seal` and `--save`, which
come before those arguments.

## 14. Memory, stack and compilation failures

- **Heap.** When a collection does not free enough space, the heap grows.
  If growth fails, or `SHEN_JIT_MAX_HEAP` is reached, the allocation raises a
  catchable "out of memory" error, from room kept back for it; the heap stays
  consistent because its regions are always the same size. The process aborts only if the collector itself
  cannot complete.
- **The heap's size,** what a collection keeps and the room for new objects
  together, starts at 32 MiB and grows after a collection to five times what
  is live, if that is more. It never shrinks.
- **Large objects:** vectors, strings and byte buffers of 32K words or more are allocated
  apart and copied only into an image; collections mark them, scan them in place and
  free the dead ones. They count as live data for that rule, and once
  toward `SHEN_JIT_MAX_HEAP`, which is on what the heap holds, small and large
  objects together, and not on the room it has grown to. An image holds them inside its heap.
- **Guest stack.** It starts at 64K slots, filled with the cleared value, and
  doubles on overflow up to a maximum of 1 GiB. Exceeding
  the maximum raises a catchable "stack overflow" error. The stack never shrinks
  while guest code runs.
- **Compilation.** If SLJIT cannot allocate executable memory or compilation
  fails, the process terminates with a diagnostic; there is no fallback. The
  loader raises an error on code of the wrong shape.

## 15. Image format

An image is a header followed by sections and a trailer, all little-endian:

- **Header:** magic `SJHI`, format version, the executable's build identifier
  (an image loads only into the build that wrote it), word size, the sizes of the
  program space's symbol slots and objects, of the heap and of the root sections,
  the program space's first free symbol slot, and the primitive table's size and a
  checksum of its names, so an image cannot load against a different primitive table.
- **Program space:** its symbol slots, then its objects, as they lie there.
- **Heap:** the live heap after a final collection.

  Every pointer in these is stored relative to the start of the program space,
  with bit 62 set, or of the heap, and every raw native field is stored as 0.
- **Roots:** the global-cell and constant-slot arrays, with relative pointers.
- **Trailer:** the image's length in bytes and the magic `SJHI-END`. A loader
  reads it from the end of the file, so an image can be appended to another
  file: the executable carries its image this way.

Loading reads the program space into a new one and the heap into a region at
least five times its size, adds the bases to every pointer in one linear pass
over each, does the same for the root arrays, rebuilds the symbol tables from
the slots, and then applies the reconstruction rules in
[design.md](design.md): native entries from each procedure's kind, the standard streams
rebound in place, and file streams left closed.

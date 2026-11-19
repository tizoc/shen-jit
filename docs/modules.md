# Modules

A module is a part of a program described by a file of its own, `NAME.shenmod`: the modules it needs loaded
first, and its sources. `shen-jit eval -m NAME` loads one, after those it requires, each once:

```sh
SHEN_JIT_PATH=app shen-jit eval -m report -e '(report.main)'
```

## Descriptors

A descriptor holds one form:

```shen
(shen.module
  (version 1)
  (name report)
  (requires json report/format)
  (requires-features shen-jit/ffi)
  (sources tc+ "types.shen" "report.shen"
           tc- "native.shen"))
```

| Field | Meaning |
| --- | --- |
| `(version 1)` | Required, once |
| `(name NAME)` | Required, once: the name the module is asked for by. A descriptor loaded by its path may have any |
| `(requires NAME ...)` | Modules loaded first, in this order, each after what it requires |
| `(main FUNCTION)` | At most once: the function of no arguments an executable that `build` writes runs (see [Building a program](#building-a-program)) |
| `(typed)` | At most once: wherever the module loads, what it requires loads sealed, and its sources sealed and with their types; `build` of a program with it compiles every module it loads with their types (see [Typed programs](#typed-programs)) |
| `(requires-features FEATURE ...)` | Features the build must have, as `(shen.x.features.current)` lists them: `shen/shen-jit` always, and `shen-jit/ffi` where C libraries load, which a static Linux build cannot |
| `(sources tc+ FILE ... tc- FILE ...)` | Required, once: the files loaded, in order, relative to the descriptor's directory, each with type checking on after `tc+` and off after `tc-` |
| `(extension ID ...)` | Host-specific options. Other hosts' extensions are ignored |

Each source starts with a fresh inference count. To give every source in a module its own
limit, add `(extension shen-jit (maxinferences 1500000))` to its descriptor. The value is
a nonnegative integer. A module without this option uses the limit in effect before the outer
module load. Dependencies and modules loaded from source code use their own settings.
Loading restores the caller's limit and count, including when a source raises.
The kernel checks the limit at specific points in proof search. Some proof paths
can finish above the configured count.

Anything else is refused, naming the descriptor: another field, a field given twice, a version other than 1, a
source that is not a relative path (one that starts with `/` or a drive such as `C:`, or holds a backslash), or a
file holding anything but one `shen.module` form.

List each source after those whose functions it calls. A file is read, and its calls compiled, before the sources
after it are, so a call to a function that a later source defines does not know that function's arity yet: it
works, but each time it runs it checks the arity, or, sealed, finds the function through `fn` and calls it
indirectly, and it is never inlined.

### Common types in typed clients

A typed list has one element type. If two values can each belong to several unions, repeating
them in separate tuple literals can make the checker try a different type for each position.
Build the common list first and use `map` to construct each row. Here a link monitor initializes
three history slots per link from its current state.

```shen
(datatype link.states
  ____________
  online : up;

  _______________
  offline : down;

  X : up;
  __________
  X : state;

  X : down;
  __________
  X : state;)

(define link.histories
  {up --> down --> (list (state * (state * state)))}
  U D -> (map (/. X (@p X X X)) [U D]))
```

The same two widening rules type `[U D]` once regardless of the number of history slots.
For rows with different types in different positions, a consumer signature can give the
expected type of each position explicitly.

A function returning a union can likewise declare that union as its result type.
The `result` module supplies two such functions. A caller can match several nominal
structs, then return the union directly.

```shen
(define monitor.total
  {(list (result.t (string * number))) --> (result.t (string * number))}
  [(:result.ok A) (:result.ok B) | _] -> (result.ok (+ A B))
  _ -> (result.err "two readings required"))
```

## Names and the path

A name is a symbol, and a slash in it is a directory: `report/format` is `report/format.shenmod`, and its sources
are relative to `report/`. It is looked for in each directory of the path in turn, and the first that holds it is
used. The path is:

1. the directories in `SHEN_JIT_PATH`, separated by `:`, or `;` on Windows;
2. the installation's `lib/`: beside the executable in an archive, or `../lib` from `build/` in a source tree.

`(module.path)` gives it, and `(module.set-path Directories)` replaces it. A relative directory is taken from the
process's own. The loader looks up descriptors and reads source files with `*home-directory*` empty. A source
can change that setting with `cd` for its own I/O and for the evaluation of later sources.

## Loading

- **On the command line,** `eval` takes `-m NAME`, or `-m FILE.shenmod` for a descriptor by its path, among its
  `-l` and `-e`, in order, and `script FILE.shenmod ARGS` loads a module as a script, with `*argv*` set to
  `[FILE.shenmod | ARGS]`.
- **`(module.use Names)`** loads each named module, and gives those it loaded, in order.
- **`(module.load File)`** loads the module a descriptor's path names, whatever its name, with its directory put first
  in the path, where it stays, for what it requires and what loads after. `-m FILE.shenmod` does the same, and only
  `build` puts the path back as it was.
- **`(module.loaded)`** gives every module loaded, in order.

Module sources evaluate a form at a time. A `tc+` source also typechecks as a checked `load` does.
Module loading shows output from the source and diagnostics. Direct `load` outside a module also
shows the inferred types and, under typechecking, the inference count.

A module loads once in a process, and a saved image keeps what it loaded. Those it requires load first, left to
right, and a module that requires itself, through others or not, is refused, naming the chain. A source that raises
leaves its module unloaded, so the next use loads it again from its first source; modules loaded before it stay
loaded. A typed module, and what it requires, load sealed, so what a failed load defined is unsealed again for the
next try; callers compiled meanwhile keep what they found. Type checking, `*hush*`, `optimise`, sealing and
`*home-directory*` come back as they were, however it ends. Loading a module evaluates its sources, defining what
they define, so only the builder can, as only it can define.

`module` is a namespace whose functions are system functions, so a namespace with `(use module => m)` can call
`(m.use [json])`. A namespace qualifies the symbols in its data too, so there a module's name must be among its
`externals`, as with `(externals [json])`, or `[json]` asks for `NAMESPACE.json`. Typed code sees
`module.use : ((list symbol) --> (list symbol))`, `module.load : (string --> (list symbol))`,
`module.path : (--> (list string))`, `module.set-path : ((list string) --> (list string))` and
`module.loaded : (--> (list symbol))`.

## Rules

A module's sources see the image's rules, the public rules of its direct and transitive
dependencies, and the active rules its own sources have defined so far. Each source starts
with the dependency rules again. Including another datatype lets the current source use it
without making it part of the module's interface.

For implementation-only rules, define a separate datatype and use `(preclude [t-internal])`
after the definitions that need it. It stays inactive in later sources unless they explicitly
`include` it. The module publishes only its own datatypes still active after its last source
succeeds. The caller then sees those public rules alongside its previous rules.

The loader filters the kernel's datatype registry to the source's scope and keeps the registry order.
Preloading a dependency can therefore change which of two overlapping rules is tried first.

List modules whose rules a source uses in `requires`. A `module.use` call inside a source adds the public
rules of modules it just loaded to that source's scope. A dependency in `requires` supplies its rules
at the start of every source, including when it was already loaded. Keeping the scope small also reduces
the rules the typechecker has to try.

## The libraries and tools

Each library in `lib/` is a module, its descriptor beside its sources (the guide's [Libraries](guide.md#libraries)
lists them): a library of several parts is a directory, such as `http/server`, and a module can have several
sources, as `buffer` has `buffer-view.shen`, `buffer-typed.shen` and `buffer.shen`. Each tool in `tools/` that
uses them has a descriptor of its own, so that it runs as `shen-jit script tools/fs-copy.shenmod SOURCE DESTINATION`.

## Building a program

A program is a module too: a descriptor beside its sources names the libraries it requires, and its entry point,
a function of no arguments:

```shen
(shen.module
  (version 1)
  (name app)
  (requires json)
  (main app.main)
  (sources tc+ "app.shen"))
```

`shen-jit build app/app.shenmod -o hello` loads it, and what it requires, then writes an executable, `hello`, as
[`shen-jit.save-executable`](guide.md#saving-a-program) does, which runs `app.main` with its arguments in `*argv*`.

- **The file** is the last part of the module's name in the current directory, `app`, or `app.exe` on Windows;
  `-o OUTPUT` names another, as it must when the descriptor is in a directory of that name, as `app/app.shenmod`
  is.
- **Its definitions are sealed,** the program's and the libraries' alike: calls between them are direct, and
  none can be redefined, so a program that redefines its own functions as it runs needs `--open`.
- **Its modules must not already be loaded** in the image used to build it, including one selected with
  `SHEN_JIT_IMAGE`: the build refuses a cached module in its dependency graph, since loading it again cannot
  change how its definitions were compiled. Start from an image without those modules. Dependencies first
  loaded during the build can still be shared.
- **Loading is quiet,** and `*hush*` and sealing are as they were when it saves, so the program starts as the
  command that built it did.
- **What it carries** is the whole image, compiler included: about 2 MB, and more with the libraries it loads,
  about 4 MB with `json`. A library's C adapter, for `fs`, `process`, `tree-sitter` or `curl`, is still looked for
  at run time, as for any program.

### Checking library boundaries

A module can load definitions with inline signatures from a `tc+` source. Give data
owners and their helpers types first so those signatures check the implementation. A
standalone `declare` supplies a trusted signature for a primitive, a native representation
boundary, or a Shen implementation that still needs to be migrated. Record the
representation invariant at the boundary that relies on it. For example, the Tree-sitter
adapter owns the native table layout, while Shen checks the functions that interpret
its node and capture indices.

Use `preclude` for datatype rules used only inside their module. A private struct's generated
match rule may be removed from client scope while its checked accessors remain callable.
Export a pattern rule when clients need to construct or destructure the type.

Use producers with a declared return type for values bound before their consumer supplies
a type. Examples include `option.none`, `option.some`, `result.ok`, and `json.from-string`.
The ordinary checker can keep looking for other types for a bare literal. Keep bounds on
library regressions at the default inference limit. Arbitrary user typing rules can still
require additional search.

The FFI and mmap APIs, SQLite values, dynamic handles, and Parallel's runtime worker
dispatch continue to have dynamic boundaries. Native's bytecode checker and Datalog's
relation checker validate their own languages. A checked Shen facade can sit over those
interfaces where it can express a stronger contract.

## Typed programs

A descriptor with `(typed)` describes a typed program, which `build` loads under `(optimise +)`; without it,
`build` loads under `(optimise -)`, and only typed modules (below) are compiled with their types. In a typed program, each
definition that typechecks, the program's and the libraries' alike, is compiled with the types the typechecker found: the kernel's type annotator puts
`(type X T)` around each use of a parameter or a literal whose type it knows, which the compiler can rely on, as the
program passed the typechecker. Definitions loaded unchecked, from `tc-` sources and from what datatypes and macros
generate, are compiled as before. The module [`numbers`](numbers.md) gives such a program `fixnum` and `float`.

What the compiler does with the types:

- **Floats in registers.** A definition that takes a `float`, or makes floats of its own, keeps them unboxed in the
  machine's floating-point registers, and boxes one only where it leaves: returned, passed, stored in a structure.
  Its own tail calls become a loop that carries its floats in registers. This holds for a definition that calls no
  other function once small ones are inlined, but on its way out, as the calls that make an error's message do,
  and has no `trap-error`, as numeric loops are; the rest compile as before. A float is read from memory with `shen-jit.f64` and stored with `shen-jit.f64!` in registers too, and
  `flsqrt` is computed there. Arithmetic on `number` that mixes a float with an integer, after `fl->number` and
  `fx->number`, runs as in untyped code.

```shen
(define orbit {float --> float --> float --> float --> fixnum --> fixnum --> fixnum}
  _ _ _ _ Limit Limit -> Limit
  X Y CX CY N Limit -> (let XX (fl* X X)
                            YY (fl* Y Y)
                         (if (fl> (fl+ XX YY) (float 4))
                             N
                             (orbit (fl+ (fl- XX YY) CX) (fl+ (fl* (float 2) (fl* X Y)) CY) CX CY (fx+ N 1) Limit))))
```

- **Fixnums in registers.** A `fixnum` parameter, and fixnum arithmetic, comparisons and shifts by a constant
  over such values, go to the machine's integer registers in the same definitions, overflow still raising,
  except for a loop's steps (below). Indices
  into bytes are computed there, and a read or store of a float at one takes no conversion.
- **Words in registers.** A `word.t`, a 64-bit word of the module [`word`](word.md), goes to an integer register in
  the same definitions, each operation on it an instruction, and is boxed, as 8 new bytes, only where it leaves.
- **Small functions inlined into loops.** A typed function that keeps its values in registers, of up to 800 nodes,
  is inlined where a definition that keeps its own values in registers calls it, so that a loop over it, as over
  the force between two bodies, keeps its own values in registers round it. Where it is sealed, as in a typed
  program, it is inlined at any depth, so a helper that a helper calls, in a loop inside a loop, is too.
- **Loops inlined into loops.** Such a function that is itself a loop, as the dot product of a row and a column
  is, becomes a loop inside its caller, as a row of a matrix product calls it, so the values of both stay in
  registers and no call is made for each row. Loops nest two levels this way.
- **C functions of doubles called in registers.** A function of doubles from [the FFI](ffi.md), `cos` say, is
  called with its arguments and result in floating-point registers, in the same definitions.
- **Struct fields read with no check.** Where a definition calls a struct's reader, `point.x` say, the
  typechecker has shown that the value is a `point`, so the field is read without testing that it is a vector long
  enough. A field of the type `fixnum` or `float` goes to a register, checked as it is read, so a definition that
  reads such fields, as a check of a view's offsets does, keeps its values in registers. A write keeps its test,
  which also refuses a struct shared between isolates.
- **Errors leave the registers alone.** An `if` one of whose branches raises gives what its other branch gives,
  in a register, and an error's message, which calls make, reads what it formats from slots it was boxed into.

A typed program is always sealed, as its compiled code relies on which definition each call reaches, so `--open`
is refused. `(optimise +)` does the same at the REPL or in `load`, for definitions that typecheck there, and keeps
floats in registers where the functions they call, `float` among them, are sealed.

A library can be typed on its own: with `(typed)` in its descriptor, wherever it loads, by `module.use`, as
what another module requires, or in a build, what it requires loads sealed, then its sources load sealed and under
`(optimise +)`, so that what typechecks there compiles as in a typed program, and the caller's modes come back
after. A module it requires that was already loaded unsealed stays so, and calls into it are not inlined: a typed
module over `numbers` keeps its floats in registers only where `numbers` was loaded sealed, or first by it.

A typed program or module is trusted to be what its types say. Datatype rules and declarations are its own claims, and are not
checked further. Untyped code can still call a typed definition with what its types do not allow:

- A `float` parameter is read as a float when the definition starts: an integer becomes the float equal to it, and
  anything else raises, as arithmetic on it would. A `fixnum` parameter that is not one raises there too.
- A value that is not the struct a typed definition reads a field of is read anyway, as memory it is not: the
  program then misbehaves or crashes, where untyped code would raise. So does one a datatype rule or a declaration
  passed off as a struct.

Only the second can crash. Anything else typed code does with a value its types did not allow raises, or gives a
wrong answer, as untyped code would. So where untyped code is to call typed code with values from outside it, an
untyped wrapper of the program's or the module's own checks, before it calls, only what is a struct or holds one:
each argument of a struct's type, with the predicate `defstruct` makes, and each element of a list of structs, or
the field of a parametric struct that holds one. Nothing a wrapper can do checks a function untyped code passes in:
the structs it returns later are read as they are. A module that untyped code uses exports both, the typed
definitions for typed clients and the wrappers for the rest:

```shen
(shen.module (version 1) (name shapes) (requires numbers) (typed)
  (sources tc+ "typed.shen" tc- "checked.shen"))
```

```shen
\\ typed.shen
(shen.x.namespace shapes
  (import struct defstruct)
  (export point point.make point? area-of total-of area total)

(defstruct point (x : number) (y : number))

(define area-of {point --> number}
  P -> (* (point.x P) (point.y P)))

(define total-of {(list point) --> number}
  [] -> 0
  [P | Ps] -> (+ (area-of P) (total-of Ps))))
```

```shen
\\ checked.shen
(shen.x.namespace shapes

(define area
  P -> (if (point? P) (area-of P) (error "shapes.area: ~S is not a point" P)))

(define total
  Ps -> (if (points? Ps) (total-of Ps) (error "shapes.total: ~S is not a list of points" Ps)))

(define points?
  [] -> true
  [P | Ps] -> (and (point? P) (points? Ps))
  _ -> false))
```

`(shapes.area 5)` raises `shapes.area: 5 is not a point`, where `area-of` would read memory that is not a point.
Typed clients call `area-of` and `total-of`, and pay for no check.

Within its types, four things differ from untyped code:

- An index into bytes that overflows raises as an index past their end, rather than as `integer overflow`.
- A loop's step is not checked where a test has just found the counter below a fixnum that is not itself
  such a step and the step is a constant that is not negative, or where the loop's own call reads bytes at
  the counter. A counter so stepped past the greatest fixnum raises where it is boxed, as "the word ... does
  not fit in an integer", or at the read, and otherwise what is computed from it in registers, by arithmetic,
  `fx->fl` or shifts, or stored by `shen-jit.s64!`, sees its true value, where untyped code would have raised
  `integer overflow` at the step.
- A C function of doubles called in registers does not save `errno` ([C FFI](ffi.md)).
- A float kept in a register is no object, so a NaN there never equals itself, where untyped code finds a NaN equal
  to itself when both sides are the same object ([Semantics](semantics.md)).

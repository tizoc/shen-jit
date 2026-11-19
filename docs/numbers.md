# Numbers by kind

[lib/numbers.shen](../lib/numbers.shen) gives typed code two kinds of number, `fixnum` and `float`, with operators
for each and conversions between them and `number`. Its module is `numbers`.

```sh
shen-jit eval -m numbers -l program.shen
```

```repl
(0-) (tc +)
true

(1+) (define mean {float --> float --> float} X Y -> (fl/ (fl+ X Y) (float 2)))
(fn mean) : (float --> (float --> float))

(2+) (mean 1.5 3.5)
2.5 : float

(3+) (define steps {fixnum --> fixnum} 0 -> 0 N -> (fx+ N (steps (fx- N 1))))
(fn steps) : (fixnum --> fixnum)

(4+) (define half {float --> float} X -> (/ X 2))
type error in rule 1 of half
```

## The types

| Type | Its values |
| --- | --- |
| `fixnum` | Integers, 62-bit; a result outside that range raises `integer overflow` |
| `float` | Floats, IEEE doubles |

Neither is a `number`, and a `number` is neither: each kind has its own operators, and a conversion goes from one
type to another where the program says so. An arithmetic expression then has one type, which the typechecker finds
without searching, and code that uses only `number` never tries the rules of this module.

An integer literal can supply an expected `fixnum` and a float literal an expected `float`.
Without an expected kind, a literal infers as `number`. For example, `(fx+ 1 2)` checks
both literals as fixnums. Use `(let N (fixnum 1) (fx+ N 2))` to bind a fixnum before
its use: of an integer literal, `fixnum` is read as `(type 1 fixnum)` and costs nothing,
where of anything else it checks at run time. Use `(float 1.5)` to bind a float. The reader gives the integer 2 for `2.0`,
so write `(float 2)` for a float with no fraction.

Polymorphic calls check arguments from left to right. If `N` is a fixnum,
`(= N 0)` gives the literal its expected type. In `(= 0 N)`, the literal
infers as `number` before the checker sees `N`. Use `(fx= 0 N)` or
`(fx= N 0)` for fixnum equality in either order.

When a generic call encounters the literal before its type is known, use
`(element? (fixnum 0) Xs)` or `(let L (cons (fixnum 0) Acc) ...)` for a
list of fixnums.

## Operators

| Operators | Type |
| --- | --- |
| `fl+`, `fl-`, `fl*`, `fl/` | `float --> float --> float` |
| `fl<`, `fl>`, `fl<=`, `fl>=` | `float --> float --> boolean` |
| `flsqrt` | `float --> float` |
| `fx+`, `fx-`, `fx*` | `fixnum --> fixnum --> fixnum` |
| `fx=`, `fx<`, `fx>`, `fx<=`, `fx>=` | `fixnum --> fixnum --> boolean` |
| `fxquotient`, `fxremainder` | `fixnum --> fixnum --> fixnum` |

`=` compares either, as it compares anything. The bit operations, `shen-jit.bit-and` and the rest
([bytecode.md](bytecode.md)), take and give fixnums; the module `word` gives 64-bit words, whose arithmetic wraps
([64-bit words](word.md)). `fl/` by zero raises, as `/` does, and a fixnum operation whose
result does not fit raises, as `+` does. `fxquotient` truncates towards zero and `fxremainder` has the dividend's
sign, as in C, so `(fxquotient -7 2)` is -3 and `(fxremainder -7 2)` is -1; dividing by zero raises, and the least
fixnum divided by -1 overflows.

Called from untyped code, the float operators convert an integer operand and raise for anything else, so their
arithmetic always gives a float. The fixnum operators are `+`, `-`, `*` and the comparisons there, and `fxquotient` and `fxremainder` raise
for an operand that is not a fixnum.

## Vectors and bytes

| Function | Type |
| --- | --- |
| `fx<-vector`, `fxvector->` | `(vector A) --> fixnum --> A`, `(vector A) --> fixnum --> A --> (vector A)` |
| `fxlimit` | `(vector A) --> fixnum` |
| `shen-jit.u8`, `u16`, `u32`, `s32`, `s64` | `buffer.storage --> fixnum --> fixnum` |
| `shen-jit.f32`, `f64` | `buffer.storage --> fixnum --> float` |
| `shen-jit.u8!` and the other stores | `buffer.storage --> fixnum --> fixnum --> buffer.storage`, `float` for `f32!` and `f64!` |
| `shen-jit.bytes`, `shen-jit.bytes-length` | `fixnum --> buffer.storage`, `buffer.storage --> fixnum` |

The vector functions are `<-vector`, `vector->` and `limit` with fixnum indices. `buffer.storage` is the type
`lib/buffer.shen` gives a byte buffer or a pointer to memory, and the module `memory` types `memory.alloc` as
`fixnum --> buffer.storage`, so a typed program reads and writes memory with no declarations of its own. The
libraries over bytes type what counts bytes as `fixnum` too ([Libraries](guide.md#libraries)). A typed
program keeps an offset in a register, and reads or writes an integer or a float there too. The module `floats` gives arrays
of doubles indexed by element ([Arrays of doubles](floats.md)).

## Conversions

| Conversion | Type | At run time |
| --- | --- | --- |
| `float` | `number --> float` | an integer as the float equal to it, `(= (float 2) 2)` being true; a float as it is; anything else raises |
| `fx->fl` | `fixnum --> float` | the same conversion |
| `fl->fx` | `float --> fixnum` | the float truncated towards zero, `(fl->fx -2.7)` being -2; one outside the fixnums, a NaN or an infinity among them, raises `integer overflow` |
| `fixnum` | `number --> fixnum` | the fixnum as it is; anything else, a float included, raises |
| `fl->number` | `float --> number` | nothing |
| `fx->number` | `fixnum --> number` | nothing |

`float` and `fx->fl` are the primitive `shen-jit.float`, `fl->fx` is `shen-jit.truncate`, and `flsqrt` is
`shen-jit.sqrt`, which a typed program keeps in registers ([Typed programs](modules.md#typed-programs)). Every operator and conversion here inlines where it is
sealed, so a conversion that changes nothing costs nothing. Once the module is loaded, these names are system
functions, which a program cannot redefine.

## Where the rules apply

A module that requires `numbers`, directly or through another, sees its rules, and others do not
([Modules](modules.md)); code outside modules sees them once the module is loaded. The datatype is `numbers.t`, which
`preclude` and `include` take.

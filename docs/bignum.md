# Bignums

[lib/bignum.shen](../lib/bignum.shen) gives bignums, integers of any size, over [GMP](https://gmplib.org), in Shen
alone. Its module is `bignum`, and its names are its namespace's: `bignum.+`, `bignum.expt`, `bignum.t` and the rest. It
needs GMP's library, which most Linux systems have, and Homebrew and MSYS2 package, and no C compiler. It requires
`ffi`, `numbers` and `memory`.

```sh
shen-jit eval -m bignum -l program.shen
```

```repl
(0-) (tc +)
true

(1+) (bignum.expt 2 200)
1606938044258990275541962092341162602522202993782792835301376 : bignum.t

(2+) (define fact {bignum.t --> bignum.t} 0 -> 1 N -> (bignum.* N (fact (bignum.- N 1))))
(fn fact) : (bignum.t --> bignum.t)

(3+) (fact 30)
265252859812191058636308480000000 : bignum.t

(4+) (bignum.+ 2305843009213693951 1)
2305843009213693952 : bignum.t

(5+) (bignum.quotient-remainder (bignum.of-string "1000000000000000000000000000000") 7)
(@p 142857142857142857142857142857 1) : (bignum.t * bignum.t)

(6+) (+ 2305843009213693951 1)
integer overflow
```

The kernel's arithmetic is as it was: its integers are 62-bit, and raise `integer overflow` past that. A literal past 62
bits reads as a float, so a large bignum comes from an operation or from `bignum.of-string`.

A namespace can bring in shorter names, with `import`, or a prefix of its own with `use`:

```shen
(shen.x.namespace rsa
  (import bignum t => bignum expt-mod)
  (export encrypt)

  (define encrypt
    {bignum --> bignum --> bignum}
    M N -> (expt-mod M 65537 N)))
```

## What one is

A bignum is an integer of any size. One that fits 62 bits is a fixnum, and only one that does not is something else.
So a fixnum from anywhere is a bignum, and:

- **Equal bignums are `=`,** and hash alike, so one can be a dictionary's key, or looked for in a list.
- **One prints as its digits,** with `~A` as with `~S`.
- **One is plain data:** it goes into a saved image, and to another isolate in a message, and the collector frees it.

In typed code an integer literal can be a `bignum.t`, as the 0 and 1 of `fact` are, and a variable of type `fixnum`
becomes one with `bignum.of`, which costs nothing. A `bignum.t` is not a `number`, and a `number` is not a `bignum.t`.
Untyped code can pass any fixnum, and anything that is no integer raises `bignum: X is not an integer`, a float among
them, even one with no fraction.

## Functions

`t` is `bignum.t` in the types below.

| Function | Type | |
| --- | --- | --- |
| `bignum.+`, `bignum.-`, `bignum.*` | `t --> t --> t` | |
| `bignum.quotient`, `bignum.remainder` | `t --> t --> t` | Division truncated towards zero; the remainder has the dividend's sign |
| `bignum.quotient-remainder` | `t --> t --> (t * t)` | Both at once |
| `bignum.floor-quotient`, `bignum.modulo` | `t --> t --> t` | Division rounded down; the modulus has the divisor's sign |
| `bignum.negate`, `bignum.abs` | `t --> t` | |
| `bignum.sign` | `t --> fixnum` | -1, 0 or 1 |
| `bignum.<`, `bignum.<=`, `bignum.>`, `bignum.>=` | `t --> t --> boolean` | |
| `bignum.compare` | `t --> t --> fixnum` | -1, 0 or 1 |
| `bignum.even?`, `bignum.odd?` | `t --> boolean` | |
| `bignum.integer?` | `A --> boolean` | Whether a value is an integer, for untyped code |

| Powers and number theory | Type | |
| --- | --- | --- |
| `bignum.expt` | `t --> fixnum --> t` | `(bignum.expt 0 0)` is 1 |
| `bignum.expt-mod` | `t --> t --> t --> t` | `(bignum.expt-mod B E M)` is B^E modulo M, from 0 up to M's magnitude. A negative E is a power of B's inverse |
| `bignum.invert` | `t --> t --> t` | The inverse of A modulo M, raising if there is none |
| `bignum.gcd`, `bignum.lcm` | `t --> t --> t` | Never negative |
| `bignum.gcd-extended` | `t --> t --> (t * (t * t))` | `(@p G (@p S T))`, where G is A S + B T |
| `bignum.sqrt` | `t --> t` | The square root rounded down |
| `bignum.square?` | `t --> boolean` | Whether it is a square |
| `bignum.prime?` | `t --> boolean` | Whether it is prime. The test is GMP's, with 25 repetitions: false is certain, and true all but certain |
| `bignum.next-prime` | `t --> t` | The next one above it for which `bignum.prime?` is likely true, as GMP finds it |
| `bignum.factorial`, `bignum.fibonacci` | `fixnum --> t` | |
| `bignum.binomial` | `t --> fixnum --> t` | `(bignum.binomial N K)`, for any N |

| Bits, of a negative bignum as in two's complement | Type | |
| --- | --- | --- |
| `bignum.bit-and`, `bignum.bit-or`, `bignum.bit-xor` | `t --> t --> t` | |
| `bignum.bit-not` | `t --> t` | |
| `bignum.bit-set?` | `t --> fixnum --> boolean` | Whether a bit is 1, bit 0 being the lowest |
| `bignum.bit-length` | `t --> fixnum` | How many bits the magnitude has, 0 for 0 |
| `bignum.bit-count` | `t --> fixnum` | How many bits are 1; a negative bignum raises |
| `bignum.shift-left`, `bignum.shift-right` | `t --> fixnum --> t` | By a count from 0; to the right, rounded down |

| Conversions | Type | |
| --- | --- | --- |
| `bignum.of` | `fixnum --> t` | The same integer |
| `bignum.to-fixnum` | `t --> fixnum` | Raises for one that does not fit |
| `bignum.of-float` | `float --> t` | Truncated towards zero; an infinity or a NaN raises |
| `bignum.to-float` | `t --> float` | The nearest float, the even one of two as near; one too large raises |
| `bignum.of-string`, `bignum.to-string` | `string --> t`, `t --> string` | In base 10 |
| `bignum.of-string-base`, `bignum.to-string-base` | `string --> fixnum --> t`, `t --> fixnum --> string` | In a base from 2 to 36, with lower-case letters, which either case reads as |

A string is an optional minus sign and digits, and nothing else, not even white space: any other raises. Where a type
says `fixnum`, for a power, a shift or a factorial, a negative one raises.

**Errors.** Division by zero raises `bignum: division by zero`, and so does a modulus of 0. A result of more than 2^31
bits, some 646 million digits, raises before it is computed: GMP ends the process when it runs out of memory, and
nothing can catch that. An operation on bignums near that size can need several times their memory.

## Where GMP is

The library is opened at the first operation that needs it, by the first of these names that opens: `libgmp.so.10`,
`libgmp.so`, `libgmp.dylib`, that file in `/opt/homebrew/lib`, `/usr/local/lib` and `/opt/local/lib`, and
`libgmp-10.dll`. Where it is elsewhere, set `bignum.*library-files*` to a list of names before loading the module. A
built program finds one shipped beside it, or in its `lib/` ([Calling C](ffi.md)). Without it, arithmetic on fixnums
whose result is one still works, and what needs GMP raises, as with `foreign: cannot find __gmpn_add in bignum.gmp`. A
static Linux build cannot load it.

A [closed program](modules.md#closed-builds) can use the module, with nothing to declare.

## What it costs

On fixnums whose result is one, the arithmetic, the comparisons, the divisions, the shifts and the bit operations are
the kernel's and the runtime's, with a test of the operands, and no call into C is made. `bignum.expt`, `bignum.gcd`,
`bignum.sqrt` and the others always call GMP.

Sums, differences, products, comparisons, and divisions by a fixnum, are GMP's functions on limbs, which work on the
operands' byte buffers where they are and write the result's. For bignums of a few limbs that is a call into C and a
new buffer.

The others work on registers of this module's, in memory outside the heap: the operands' limbs are copied into them, and
the result's out, into a new buffer. That stops showing as bignums grow, or where the operation is a long one. Registers
grow to the largest operand, and those that held more than 1 MB are freed after the operation. Each isolate has its own,
freed as it ends.

A call into GMP cannot be interrupted: Ctrl-C and a kill take effect when it returns.

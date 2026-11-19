# Arrays of doubles

[lib/floats.shen](../lib/floats.shen) gives arrays of doubles, unboxed and indexed by element, for typed code and
untyped code alike. Its module is `floats`, and its names are its namespace's: `floats.get`, `floats.t` and the
rest. It requires `numbers`.

```sh
shen-jit eval -m floats -l program.shen
```

```repl
(0-) (tc +)
true

(1+) (define total {floats.t --> fixnum --> float --> float}
       V I Acc -> Acc where (fx>= I (floats.length V))
       V I Acc -> (total V (fx+ I 1) (fl+ Acc (floats.get V I))))
(fn total) : (floats.t --> (fixnum --> (float --> float)))

(2+) (total (floats.of-list [1.5 2.5 4.25]) 0 (float 0))
8.25 : float
```

A namespace can bring in shorter names, with `import` or a prefix of its own with `use`:

```shen
(shen.x.namespace stats
  (import floats t => floats get length)

  (define total {floats --> fixnum --> float --> float}
    V I Acc -> Acc where (fx>= I (length V))
    V I Acc -> (total V (fx+ I 1) (fl+ Acc (get V I)))))
```

Inside `stats`, `get` and `length` are the ones of `floats`; elsewhere they are still the kernel's.

## Functions

| Function | Type | |
| --- | --- | --- |
| `floats.new` | `fixnum --> floats.t` | N doubles, each 0.0 |
| `floats.get` | `floats.t --> fixnum --> float` | The double at an index, from 0 |
| `floats.set` | `floats.t --> fixnum --> float --> floats.t` | The array, with a double at an index |
| `floats.length` | `floats.t --> fixnum` | How many doubles it holds |
| `floats.of-list`, `floats.to-list` | `(list float) --> floats.t`, `floats.t --> (list float)` | |
| `floats.bytes`, `floats.of-bytes` | `floats.t --> buffer.storage`, `buffer.storage --> floats.t` | The same object, as bytes or as doubles |

An index outside the array raises `bytes: N is not a valid index`, N the index of the double's first byte.

## What it is

A `floats.t` is a byte buffer of 8 bytes for each double, as `shen-jit.bytes` makes, so `memory`, `mmap` and the
FFI take one as it is, through `floats.bytes`, and a block of memory is an array of doubles through
`floats.of-bytes`, its length in doubles its length in bytes divided by 8.

In typed code, `floats.get` and `floats.set` keep the double in a register and read or write it at the element's
index, which the access scales, with one check of that index against the length in doubles: there is no product
to compute or check. In a loop over an array the loop does not change, that length is worked out once, on the way
in ([Shen/JIT instructions and frames](bytecode.md)). Untyped code gets the same results with each double boxed, as
`shen-jit.f64` gives it.

Typed code that reads `(shen-jit.f64 B (fx* I 8))` is compiled the same way, so code written over bytes gains it
too. An index whose product with 8 is past 64 bits raises there as an index past the end, where untyped code
raises `integer overflow` for the product.

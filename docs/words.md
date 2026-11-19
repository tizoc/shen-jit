# Arrays of words

[lib/words.shen](../lib/words.shen) gives arrays of 64-bit words, unboxed and indexed by element, for typed code
and untyped code alike, as [`floats`](floats.md) does for doubles. Its module is `words`, and its names are its
namespace's: `words.get`, `words.t` and the rest. It requires [`word`](word.md).

```sh
shen-jit eval -m words -l program.shen
```

```repl
(0-) (tc +)
true

(1+) (define xor-all {words.t --> fixnum --> word.t --> word.t}
       V I Acc -> Acc where (fx>= I (words.length V))
       V I Acc -> (xor-all V (fx+ I 1) (word.bit-xor Acc (words.get V I))))
(fn xor-all) : (words.t --> (fixnum --> (word.t --> word.t)))

(2+) (word.to-fixnum (xor-all (words.of-list [(word.of 5) (word.of 3) (word.of 12)]) 0 (word.of 0)))
10 : fixnum
```

A namespace that calls them by their full names uses the namespace, and one that wants them shorter imports them:

```shen
(shen.x.namespace table
  (use words)
  (externals [words.t])
  (import word t => word bit-xor => xor)

  (define fold {words.t --> fixnum --> word --> word}
    V I Acc -> Acc where (fx>= I (words.length V))
    V I Acc -> (fold V (fx+ I 1) (xor Acc (words.get V I)))))
```

## Functions

| Function | Type | |
| --- | --- | --- |
| `words.new` | `fixnum --> words.t` | N words, each 0 |
| `words.get` | `words.t --> fixnum --> word.t` | The word at an index, from 0 |
| `words.set` | `words.t --> fixnum --> word.t --> words.t` | The array, with a word at an index |
| `words.length` | `words.t --> fixnum` | How many words it holds |
| `words.of-list`, `words.to-list` | `(list word.t) --> words.t`, `words.t --> (list word.t)` | |
| `words.bytes`, `words.of-bytes` | `words.t --> buffer.storage`, `buffer.storage --> words.t` | The same object, as bytes or as words |

An index outside the array raises `bytes: N is not a valid index`, N the index of the word's first byte.

## What it is

A `words.t` is a byte buffer of 8 bytes for each word, little-endian, as `shen-jit.bytes` makes, so `memory`, `mmap`
and the FFI take one as it is, through `words.bytes`, and a block of memory is an array of words through
`words.of-bytes`, its length in words its length in bytes divided by 8. Each element is what `word.get` reads at 8
times its index.

In typed code, `words.get` and `words.set` keep the word in a register and read or write it at the element's index,
which the access scales, with one check of that index against the length in words: there is no product to
compute or check, and a loop over the array allocates nothing. Untyped code gets the same results with each word
boxed, as `word.get` gives it. `(word.get B (fx* I 8))` written out is read at the product, which typed code
computes and checks first, as `word.get`'s index is bound before the access: `words.get` is the way to read by
element.

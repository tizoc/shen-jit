# 64-bit words

[lib/word.shen](../lib/word.shen) gives 64-bit words, whose arithmetic wraps, for what hashes, random numbers and
checksums compute. Typed code keeps them in registers, where each operation is one instruction. Its module is
`word`, and its names are its namespace's: `word.+`, `word.shr`, `word.t` and the rest. It requires `numbers`.

```sh
shen-jit eval -m word -l program.shen
```

```repl
(0-) (tc +)
true

(1+) (define fnv {buffer.storage --> fixnum --> fixnum --> word.t --> word.t}
       B I N H -> H where (fx>= I N)
       B I N H -> (fnv B (fx+ I 1) N (word.* (word.bit-xor H (word.of (shen-jit.u8 B I)))
                                              (word.+ (word.shl (word.of 256) 32) (word.of 435)))))
(fn fnv) : (buffer.storage --> (fixnum --> (fixnum --> (word.t --> word.t))))

(2+) (tc -)
false : boolean

(3-) (let H (fnv (shen-jit.string->bytes "hello") 0 5 (word.+ (word.shl (word.of 3421674724) 32) (word.of 2216829733)))
       [(word.to-fixnum (word.shr H 32)) (word.to-fixnum (word.bit-and H (word.of 4294967295)))])
[2754664518 2158673163]
```

That is FNV-1a of "hello", `a430d846 80aabd0b` in hexadecimal, its high half then its low half.

A namespace can bring in shorter names, with `import`, or a prefix of its own with `use`:

```shen
(shen.x.namespace rng
  (externals [buffer.storage])
  (import word t => word of to-fixnum + * bit-xor => xor shl shr get set)

  \\ xorshift64*: the state in S's first 8 bytes, stepped, and a float in 0 to 1 from it.
  (define next {word --> word}
    X -> (let A (xor X (shr X 12))
              B (xor A (shl A 25))
           (xor B (shr B 27))))

  (define mult {--> word} -> (+ (shl (of 625341585) 32) (of 1332534557)))

  (define uniform {buffer.storage --> float}
    S -> (let X (next (get S 0))
           (do (set S 0 X)
               (fl* (fx->fl (to-fixnum (shr (* X (mult)) 11))) 1.1102230246251565e-16)))))
```

Inside `rng`, `+`, `*`, `get` and `set` are those of `word`; elsewhere they are still the kernel's. A type named in
a signature is the namespace's own unless it is imported or external, so `buffer.storage` is listed in
`externals`.

## Functions

| Function | Type | |
| --- | --- | --- |
| `word.of` | `fixnum --> word.t` | A fixnum as a word, a negative one in two's complement |
| `word.to-fixnum` | `word.t --> fixnum` | The word, read as signed, as a fixnum; one that is no fixnum raises `integer overflow` |
| `word.to-float` | `word.t --> float` | The float nearest the word, read as signed |
| `word.+`, `word.-`, `word.*` | `word.t --> word.t --> word.t` | Modulo 2^64 |
| `word.bit-and`, `word.bit-or`, `word.bit-xor` | `word.t --> word.t --> word.t` | |
| `word.bit-not` | `word.t --> word.t` | |
| `word.shl`, `word.shr`, `word.sar` | `word.t --> fixnum --> word.t` | Shifts by N modulo 64: `shr` brings in zeros, `sar` the sign |
| `word.rotl`, `word.rotr` | `word.t --> fixnum --> word.t` | Rotations by N modulo 64 |
| `word.<`, `word.<=`, `word.>`, `word.>=` | `word.t --> word.t --> boolean` | Comparisons of words read as signed |
| `word.u<`, `word.u<=`, `word.u>`, `word.u>=` | `word.t --> word.t --> boolean` | The same, read as unsigned |
| `word.get` | `buffer.storage --> fixnum --> word.t` | The word in 8 bytes at a byte index, little-endian |
| `word.set` | `buffer.storage --> fixnum --> word.t --> buffer.storage` | The bytes, with a word there |

A value that is not a word raises `X is not a word`, and an index of `word.get` or `word.set` whose 8 bytes are not
all inside the buffer raises `bytes: N is not a valid index`.

## What it is

A `word.t` is a byte buffer of 8 bytes, little-endian, as `shen-jit.bytes` makes. `=` compares two by their bytes,
and a word prints as bytes do, `#<bytes>`: `word.to-fixnum`, of the whole or of each half, shows its value. Words
are not numbers, and the kernel's arithmetic refuses them.

In typed code a word is in a word register, and each operation is one instruction: a comparison is a jump, and
`word.get` and `word.set` load and store the 8 bytes from the register. A word is boxed, as 8 new bytes, only
where it leaves the registers: returned, passed to a function that is not inlined, or kept in a structure. A loop
over words, as the hash above is, allocates nothing until it returns, and a state kept in bytes, as `uniform`'s,
is one load and one store each time. A `word.t` parameter is read from its bytes as the definition starts.

Untyped code gets the same results, each operation making a new word. Words are meant for typed code, then, and a
result that leaves it goes into bytes with `word.set` or becomes a fixnum with `word.to-fixnum`. Arrays of words
indexed by element are the module `words` ([Arrays of words](words.md)).

Each operation is the primitive `shen-jit.word-op`, whose first argument names it, and `word.set` is
`(shen-jit.copy-bytes B I W 0 8)` ([Shen/JIT instructions and frames](bytecode.md)).

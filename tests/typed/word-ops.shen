\\ Typed code over 64-bit words (lib/word.shen), their names imported: words in word registers, each
\\ operation an instruction, boxed only where a word leaves a definition.
(shen.x.namespace word-ops
  (use shen-jit)
  (use words)
  (externals [buffer.storage words.t])
  (import word t => word of to-fixnum + * bit-xor => xor shl shr rotl u< get set)

  \\ xorshift64*, as next_word in tests/bench/trace.c.
  (define next {word --> word}
    X -> (let A (xor X (shr X 12))
              B (xor A (shl A 25))
           (xor B (shr B 27))))

  (define steps {word --> fixnum --> word}
    S 0 -> S
    S N -> (steps (next S) (fx- N 1)))

  (define mult {--> word} -> (+ (shl (of 625341585) 32) (of 1332534557)))

  (define fraction {word --> float}
    S -> (fl* (fx->fl (to-fixnum (shr (* S (mult)) 11))) 1.1102230246251565e-16))

  \\ FNV-1a over bytes.
  (define fnv {buffer.storage --> fixnum --> fixnum --> word --> word}
    B I N H -> H where (fx>= I N)
    B I N H -> (fnv B (fx+ I 1) N (* (xor H (of (shen-jit.u8 B I))) (+ (shl (of 256) 32) (of 435)))))

  (define basis {--> word} -> (+ (shl (of 3421674724) 32) (of 2216829733)))

  (define stored {buffer.storage --> word --> buffer.storage}
    B W -> (set B 8 (rotl W 7)))

  (define larger {word --> word --> word}
    A B -> (if (u< A B) B A))

  \\ The top 24 bits of the next word of S's state: a helper of a helper (next), called by a loop
  \\ (below) inlined into a loop (total), three levels down, where typed bodies still inline.
  (define draw {buffer.storage --> fixnum}
    S -> (let X (next (get S 0))
           (do (set S 0 X) (to-fixnum (shr X 40)))))

  (define below {buffer.storage --> fixnum --> fixnum}
    S Limit -> (let X (draw S) (if (fx< X Limit) X (below S Limit))))

  (define total {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
    _ _ 0 Acc -> Acc
    S Limit N Acc -> (total S Limit (fx- N 1) (fx+ Acc (below S Limit))))

  \\ Arrays of words read and written by element (lib/words.shen): word-load-index and
  \\ word-store-index, with no product of the index.
  (define xor-all {words.t --> fixnum --> word --> word}
    V I Acc -> Acc where (fx>= I (words.length V))
    V I Acc -> (xor-all V (fx+ I 1) (xor Acc (words.get V I))))

  (define at {words.t --> fixnum --> word}
    V I -> (words.get V I))

  (define step-all {words.t --> fixnum --> words.t}
    V I -> V where (fx>= I (words.length V))
    V I -> (step-all (words.set V I (next (words.get V I))) (fx+ I 1))))

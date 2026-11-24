\\ Typed definitions that refine (lib/refine.shen) must accept: loaded under (tc +) by tests/refine.sh,
\\ whose last check is of refine-typed.main.

(refine.type natural N where (fx<= 0 N))
(refine.type octet N where (and (fx<= 0 N) (fx<= N 255)))

(define-checked byte-at
  {B : buffer.storage --> I : fixnum --> octet}
  {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
  B I -> (shen-jit.u8 B I))

\\ A loop, whose second clause knows that the first did not match, and whose own call must prove its condition.
(define-checked total-from
  {B : buffer.storage --> I : fixnum --> N : fixnum --> natural --> natural}
  {requires (fx<= 0 I) (fx<= N (shen-jit.bytes-length B))}
  _ I N Acc -> Acc where (fx>= I N)
  B I N Acc -> (total-from B (fx+ I 1) N (fx+ Acc (byte-at B I))))

\\ A plain definition can call one that has a condition, where its guards or nothing prove it.
(define total
  {buffer.storage --> natural}
  B -> (total-from B 0 (shen-jit.bytes-length B) 0))

(define-checked big-endian
  {buffer.storage --> fixnum --> R : fixnum}
  {ensures (fx<= -1 R) (fx<= R 65535)}
  B I -> (if (and (fx>= I 0) (fx<= (fx+ I 2) (shen-jit.bytes-length B)))
             (fx+ (fx* 256 (byte-at B I)) (byte-at B (fx+ I 1)))
             -1))

\\ Each short-circuit part knows those before it.
(define-checked starts-with?
  {buffer.storage --> fixnum --> boolean}
  B X -> (and (fx< 0 (shen-jit.bytes-length B)) (= X (byte-at B 0))))
(define-checked lacks?
  {buffer.storage --> fixnum --> boolean}
  B X -> (or (fx= 0 (shen-jit.bytes-length B)) (not (fx= X (byte-at B 0)))))

\\ A let says what its variable is, its own name in its value included.
(define-checked last-byte
  {buffer.storage --> fixnum}
  B -> (let N (shen-jit.bytes-length B)
            N (fx- N 1)
         (if (fx< N 0) -1 (byte-at B N))))
(define-checked capped
  {buffer.storage --> fixnum --> fixnum}
  B I -> (let Length (shen-jit.bytes-length B)
              At (if (fx< I Length) I (fx- Length 1))
           (if (fx>= At 0) (byte-at B At) 0)))

\\ Arithmetic the solver knows of: products by constants, quotients, remainders and masks.
(define-checked slot
  {B : buffer.storage --> fixnum --> fixnum}
  {requires (fx= (shen-jit.bytes-length B) 64)}
  B H -> (byte-at B (shen-jit.bit-and H 63)))
(define-checked middle
  {B : buffer.storage --> fixnum}
  {requires (fx< 0 (shen-jit.bytes-length B))}
  B -> (byte-at B (fxquotient (shen-jit.bytes-length B) 2)))
(define-checked rotate-to
  {buffer.storage --> fixnum --> fixnum}
  B I -> (byte-at B (fxremainder I (fixnum 8))) where (and (fx>= I 0) (fx>= (shen-jit.bytes-length B) 8))
  _ _ -> 0)
(define-checked even-byte
  {B : buffer.storage --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx< (fx* 2 I) (shen-jit.bytes-length B))}
  B I -> (byte-at B (fx* 2 I)))

\\ Integer patterns, results that are promised, and recursion on them.
(define-checked distance
  {A : fixnum --> B : fixnum --> R : fixnum}
  {ensures (fx>= R 0) (or (fx= R (fx- A B)) (fx= R (fx- B A)))}
  A B -> (if (fx< A B) (fx- B A) (fx- A B)))
(define-checked down
  {N : fixnum --> R : fixnum}
  {requires (fx>= N 0)}
  {ensures (fx= R 0)}
  0 -> 0
  N -> (down (fx- N 1)))
(define-checked clamp
  {Low : fixnum --> High : fixnum --> fixnum --> R : fixnum}
  {requires (fx<= Low High)}
  {ensures (fx<= Low R) (fx<= R High)}
  Low _ X -> Low where (fx< X Low)
  _ High X -> High where (fx> X High)
  _ _ X -> X)
(define-checked positive
  {fixnum --> R : fixnum}
  {ensures (fx> R 0)}
  N -> N where (fx> N 0)
  N -> (error "~A is not positive" N))
(define-checked backtracking
  {fixnum --> R : fixnum}
  {ensures (fx>= R 0)}
  N <- (fail-if (/. X (fx< X 0)) N) where (fx>= N 0)
  _ -> 0)

\\ Refined types of arguments, results and fields.
(define longest
  {(list fixnum) --> natural}
  [] -> 0
  [N | Ns] -> (let M (longest Ns) (if (fx> N M) N M)))
(define octet-of {fixnum --> octet} N -> N where (and (fx<= 0 N) (fx<= N 255)) _ -> 255)
(define widened {(list fixnum) --> natural} [] -> 0 [N | Ns] -> (fx+ (octet-of N) (widened Ns)))
(define doubled {natural --> natural} N -> (fx* 2 N))
(define after-first {(list fixnum) --> natural} Ns -> (let N (octet-of (head Ns)) (fx+ N 1)))
(defstruct span (start : natural) (size : natural))
(define span-end {span --> natural} S -> (fx+ (span.start S) (span.size S)))
(define-checked span-of
  {fixnum --> fixnum --> span}
  A B -> (span.make A (fx- B A)) where (and (fx<= 0 A) (fx<= A B))
  _ _ -> (span.make 0 0))

\\ Conditions with a Boolean that refine cannot read say what the rest of them does.
(define odd-one? {fixnum --> boolean} N -> (fx= 1 (shen-jit.bit-and N 1)))
(define-checked half-known
  {buffer.storage --> fixnum --> fixnum}
  B I -> (if (and (odd-one? I) (and (fx> I 0) (fx< I (shen-jit.bytes-length B)))) (byte-at B I) 0))

\\ Nested calls, each condition met by what the one inside promises.
(define-checked more
  {N : fixnum --> R : fixnum}
  {requires (fx> N 0)}
  {ensures (fx> R N)}
  N -> (fx+ N 1))
(define many-more
  {fixnum --> fixnum}
  N -> (more (more (more (more (more N))))) where (fx> N 3)
  _ -> 0)

\\ A call that is not direct is tested as it is made.
(define apply-at
  {(buffer.storage --> fixnum --> fixnum) --> buffer.storage --> fixnum --> fixnum}
  F B I -> (F B I))
(define indirect
  {buffer.storage --> fixnum --> fixnum}
  B I -> (apply-at (fn byte-at) B I))

\\ A rule of one's own, with the hypotheses.
(datatype ordered-pair
  ctxt Hyps
  if (refine.proves? Hyps [fx<= A B])
  A : fixnum; B : fixnum;
  ________________________________
  (pair-up A B) : (fixnum * fixnum);)
(define-checked in-order
  {fixnum --> fixnum --> (fixnum * fixnum)}
  A B -> (pair-up A B) where (fx<= A B)
  A B -> (pair-up B A) where (fx<= B A)
  A _ -> (pair-up A A))

(define-checked refine-typed.main
  {buffer.storage --> string}
  B -> (@s (make-string "~A ~A ~A ~A " (total B) (big-endian B 1) (big-endian B 7) (last-byte B))
           (make-string "~A ~A ~A ~A " (starts-with? B 97) (lacks? B 97) (capped B 99) (capped B 2))
           (make-string "~A ~A ~A ~A " (middle B) (rotate-to B 11) (even-byte B 3) (distance 3 9))
           (make-string "~A ~A ~A ~A " (down 100000) (clamp 1 5 9) (clamp 1 5 -9) (clamp 1 5 3))
           (make-string "~A ~A ~A ~A " (positive 3) (backtracking 4) (backtracking -4) (longest [3 9 2]))
           (make-string "~A ~A ~A ~A " (widened [0 7 255]) (doubled 4) (half-known B 3) (many-more 4))
           (make-string "~A ~A ~A " (indirect B 2) (trap-error (indirect B 8) (/. E 0)) (in-order 7 2))
           (make-string "~A ~A ~A" (after-first [4]) (span-end (span-of 3 10)) (span-end (span-of 10 3))))
    where (fx>= (shen-jit.bytes-length B) 8)
  _ -> "short")

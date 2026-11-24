\\ Typed definitions that call functions with contracts from elsewhere (lib/buffer/contracts.shen, and some
\\ here), which must be accepted: loaded with buffer/contracts under (tc +) by tests/smt.sh, whose check is
\\ of refine-contracts.main.

(define-checked byte-or
  {buffer.view --> fixnum --> fixnum}
  V I -> (if (and (fx<= 0 I) (fx< I (buffer.length V))) (buffer.u8 V I) -1))

\\ In a define, by its guard, and through fn, where nothing is asked.
(define byte-guarded
  {buffer.view --> fixnum --> fixnum}
  V I -> (buffer.u8 V I) where (and (fx<= 0 I) (fx< I (buffer.length V)))
  _ _ -> -1)
(define byte-at-of {buffer.view --> (fixnum --> fixnum)} V -> (buffer.u8 V))
(define byte-through {buffer.view --> fixnum --> fixnum} V I -> ((byte-at-of V) I))

\\ What a call needs may be what another gives, or promises.
(define-checked nested
  {V : buffer.view --> fixnum}
  {requires (fx>= (buffer.length V) 8)}
  V -> (buffer.u8 (buffer.slice (buffer.slice V 0 8) 4 4) 3))
(define-checked sixteen
  {buffer.view --> fixnum --> fixnum}
  V N -> (let H (buffer.new 16)
           (do (buffer.u32-be-> H 0 (shen-jit.bit-and N 4294967295))
               (buffer.u16-be-> H 4 (shen-jit.bit-and N 65535))
               (buffer.u8-> H 15 7)
               (buffer.copy-into! H 6 V 0 (if (fx< (buffer.length V) 9) (buffer.length V) 9))
               (fx+ (buffer.u16-be H 4) (fx+ (buffer.u32-be H 12) (buffer.offset-at H 8 8))))))
(define-checked pad
  {V : buffer.view --> I : fixnum --> End : fixnum --> buffer.view}
  {requires (fx<= 0 I) (fx<= I End) (fx<= End (buffer.length V))}
  V I End -> (if (= I End) V (pad (buffer.u8-> V I 0) (fx+ I 1) End)))
(define-checked equal-from?
  {A : buffer.view --> I : fixnum --> B : buffer.view --> J : fixnum --> N : fixnum --> boolean}
  {requires (fx<= 0 I) (fx<= 0 J) (fx<= 0 N) (fx<= (fx+ I N) (buffer.length A)) (fx<= (fx+ J N) (buffer.length B))}
  _ _ _ _ 0 -> true
  A I B J N -> (and (= (buffer.u8 A I) (buffer.u8 B J)) (equal-from? A (fx+ I 1) B (fx+ J 1) (fx- N 1))))

\\ An expression that knows things of its own as the first argument.
(define-checked from-0 {I : fixnum --> R : fixnum} {requires (fx<= 0 I)} {ensures (fx= R I)} I -> I)
(define plus {fixnum --> fixnum --> fixnum} A B -> (fx+ A B))
(refine.contract (plus A B) --> R requires (fx<= 0 A) (or (fx= B 1) (fx= B 2) (fx= B 3)) trusts (fx> R A))
(define-checked next
  {X : fixnum --> R : fixnum}
  {ensures (fx> R X)}
  X -> (if (fx< X 0) 0 (plus X 2)))
(define-checked next-from-0 {fixnum --> fixnum} X -> (from-0 (plus (if (fx< X 0) 0 (from-0 X)) 1)))

\\ Of any type, and of a function with a contract of trust alone.
(refine.contract (nth I Xs) requires (>= I 1) (<= I (length Xs)))
(define-checked second {(list A) --> A --> A} [X Y | Zs] _ -> (nth 2 [X Y | Zs]) _ D -> D)
(define five {--> fixnum} -> 5)
(refine.contract (five) --> R trusts (fx= R 5))
(define-checked more {fixnum --> fixnum} N -> (from-0 (fx- (five) 5)) where (fx> N 0) _ -> 1)

\\ and, or and sums of more than two, in what is promised, trusted, and of a type.
(define-checked stair {fixnum --> R : fixnum} {ensures (or (fx= R 1) (fx= R 2) (fx= R 4))} 0 -> 1 1 -> 2 _ -> 4)
(define stride {fixnum --> fixnum} 0 -> 1 _ -> 8)
(refine.contract (stride N) --> R trusts (and (fx> R 0) (fx< R 9) (or (fx= R 1) (fx= R 3) (fx= R 8))))
(define spread {fixnum --> fixnum} _ -> 6)
(refine.trust (spread N) --> R where (and (fx<= 0 R) (fx<= R 6) (fx<= (fx+ R R) 12)))
(refine.type digit N where (and (fx<= 0 N) (fx<= N 9) (fx< N 100)))
(define-checked small {N : fixnum --> R : fixnum} {requires (fx> N 0) (fx< N 5)} {ensures (fx= R N)} N -> N)
(define-checked by-steps {fixnum --> fixnum} N -> (small (stair N)))
(define-checked by-strides {N : fixnum --> fixnum} N -> (let S (stride N) (if (fx> S 3) (small (fx- S 7)) (small S))))
(define-checked by-spread {fixnum --> fixnum} N -> (let S (spread N) (small (fx+ 1 (fxquotient S 2)))))
(define-checked by-digit {digit --> fixnum} N -> (small (fx+ 1 (fxquotient N 3))))

(define-checked refine-contracts.main
  {--> string}
  -> (let V (buffer.from-string "abcdefghijkl")
       (@s (make-string "~A ~A ~A ~A " (byte-or V 1) (byte-or V 12) (byte-guarded V 2) (byte-through V 3))
           (make-string "~A ~A ~A ~A " (if (fx>= (buffer.length V) 8) (nested V) 0) (sixteen V 70000) (buffer.length (pad (buffer.new 4) 1 4)) (if (fx>= (buffer.length V) 4) (equal-from? V 0 V 0 4) false))
           (make-string "~A ~A ~A ~A ~A" (next 4) (next-from-0 -3) (second [1 2 3] 0) (second [1] 9) (more 3))
           (make-string " ~A ~A ~A ~A" (by-steps 7) (by-strides 1) (by-spread 0) (by-digit 9)))))

\\ The port's shen.lzy= and shen.lzy=! against the kernel's definitions, copied
\\ here, on random terms: the same answer, the same bindings, the continuation
\\ thawed as often, and everything undone when the continuation says false.
\\ Without the occurs check a term can hold itself, and walking two such terms need
\\ not end, in the kernel's either, so these cases make none.

(define pu.lzy=
  X X _ C -> (thaw C)
  X Y B C -> (shen.bind! X Y B C) where (shen.pvar? X)
  X Y B C -> (shen.bind! Y X B C) where (shen.pvar? Y)
  [X | Y] [W | Z] B C -> (pu.lzy= (shen.lazyderef X B) (shen.lazyderef W B) B
                                  (freeze (pu.lzy= (shen.lazyderef Y B) (shen.lazyderef Z B) B C)))
  _ _ _ _ -> false)

(define pu.lzy=!
  X X _ C -> (thaw C)
  X Y B C -> (shen.bind! X Y B C)
             where (and (shen.pvar? X) (not (shen.occurs-check? X (shen.deref Y B))))
  X Y B C -> (shen.bind! Y X B C)
             where (and (shen.pvar? Y) (not (shen.occurs-check? Y (shen.deref X B))))
  [X | Y] [W | Z] B C -> (pu.lzy=! (shen.lazyderef X B) (shen.lazyderef W B) B
                                   (freeze (pu.lzy=! (shen.lazyderef Y B) (shen.lazyderef Z B) B C)))
  _ _ _ _ -> false)

(set pu.seed 12345)

(define pu.random
  N -> (do (set pu.seed (shen-jit.bit-and (+ (* (value pu.seed) 1103515) 12345) 2147483647))
           (shen-jit.shift-right (* (shen-jit.shift-right (value pu.seed) 8) N) 23)))

(define pu.nth
  0 [X | _] -> X
  N [_ | Xs] -> (pu.nth (- N 1) Xs))

\\ Atoms that differ, and pairs that are = without being identical: the reader turns 1.0
\\ into the integer 1, so the float is computed.
(set pu.atoms [a b [] 1 (+ 0.5 0.5) 2 "s" "s" true c])

(define pu.term
  Vars Depth -> (let R (pu.random 10)
                  (cases (< R 4) (pu.nth (pu.random (length Vars)) Vars)
                         (and (< R 7) (> Depth 0)) [(pu.term Vars (- Depth 1)) | (pu.term Vars (- Depth 1))]
                         true (pu.nth (pu.random 10) (value pu.atoms)))))

(define pu.vars
  0 _ -> []
  N B -> (let V (shen.newpv B) [V | (pu.vars (- N 1) B)]))

\\ What each variable is bound to: the raw slots, so a cycle does no harm.
(define pu.slots
  [] _ -> []
  [V | Vs] B -> [(<-address B (shen-jit.pvar-offset V)) | (pu.slots Vs B)])

(define pu.bind-some
  [] _ _ _ -> done
  [V | Vs] [Bit | Bits] Term B -> (do (if Bit (shen.bindv V Term B) skip)
                                      (pu.bind-some Vs Bits Term B)))

\\ New bindings with four variables, the last three maybe bound to a term over the
\\ first, so that no variable is bound to a term holding itself.
(define pu.setup
  Pre Bits -> (let B (shen.prolog-vector)
                   Vars (pu.vars 4 B)
                   _ (pu.bind-some (tl Vars) Bits Pre B)
                [B | Vars]))

\\ A unifier's answer: what it returned, the bindings the continuation saw, how
\\ often it ran, and the bindings after.
(define pu.run
  F X Y [B | Vars] Answer
  -> (let Seen (absvector 2)
          _ (address-> Seen 0 0)
          _ (address-> Seen 1 none)
          R (F (shen.lazyderef X B) (shen.lazyderef Y B) B
               (freeze (do (address-> Seen 0 (+ 1 (<-address Seen 0)))
                           (address-> Seen 1 (pu.slots Vars B))
                           Answer)))
       [R (<-address Seen 0) (<-address Seen 1) (pu.slots Vars B)]))

(set pu.passed 0)
(set pu.failed 0)

(define pu.compare
  F G X Y S1 S2 Answer
  -> (let A1 (pu.run F X Y S1 Answer)
          A2 (pu.run G X Y S2 Answer)
       (if (= A1 A2)
           (set pu.passed (+ 1 (value pu.passed)))
           (do (output "differs: ~S ~S: ~S against ~S~%" X Y A1 A2)
               (set pu.failed (+ 1 (value pu.failed)))))))

(define pu.bits
  0 -> []
  N -> [(< (pu.random 10) 3) | (pu.bits (- N 1))])

\\ Any terms, for the unifier that checks for cycles.
(define pu.checked
  F G Answer -> (let Pre (pu.term [(shen-jit.pvar 2)] 1)
                     Bits (pu.bits 3)
                     S1 (pu.setup Pre Bits)
                     S2 (pu.setup Pre Bits)
                     X (pu.term (tl S1) 3)
                     Y (pu.term (tl S1) 3)
                  (pu.compare F G X Y S1 S2 Answer)))

\\ For the one that does not, terms that the other can unify, which make no cycle.
(define pu.unchecked
  F G Answer -> (let Pre (pu.term [(shen-jit.pvar 2)] 1)
                     Bits (pu.bits 3)
                     S0 (pu.setup Pre Bits)
                     S1 (pu.setup Pre Bits)
                     S2 (pu.setup Pre Bits)
                     X (pu.term (tl S1) 3)
                     Y (pu.term (tl S1) 3)
                     Safe (pu.run (/. A D B C (pu.lzy=! A D B C)) X Y S0 true)
                  (if (= (hd Safe) false)
                      skip
                      (pu.compare F G X Y S1 S2 Answer))))

\\ Terms with each variable once at most, which fail as often as not.
(define pu.linear
  Vars Depth -> (let R (pu.random 10)
                  (cases (and (< R 4) (cons? (value pu.pool)))
                         (let V (hd (value pu.pool))
                           (do (set pu.pool (tl (value pu.pool))) V))
                         (and (< R 7) (> Depth 0))
                         (let H (pu.linear Vars (- Depth 1))
                           [H | (pu.linear Vars (- Depth 1))])
                         true (pu.nth (pu.random 10) (value pu.atoms)))))

(define pu.clash
  F G Answer -> (let S1 (pu.setup 0 [false false false])
                     S2 (pu.setup 0 [false false false])
                     _ (set pu.pool (tl S1))
                     X (pu.linear [] 3)
                     Y (pu.linear [] 3)
                  (pu.compare F G X Y S1 S2 Answer)))

(define pu.cases
  0 -> done
  N -> (let Port= (/. X Y B C (shen.lzy= X Y B C))
            Kernel= (/. X Y B C (pu.lzy= X Y B C))
            Port=! (/. X Y B C (shen.lzy=! X Y B C))
            Kernel=! (/. X Y B C (pu.lzy=! X Y B C))
         (do (pu.checked Port=! Kernel=! true)
             (pu.checked Port=! Kernel=! false)
             (pu.unchecked Port= Kernel= true)
             (pu.unchecked Port= Kernel= false)
             (pu.clash Port= Kernel= true)
             (pu.clash Port= Kernel= false)
             (pu.cases (- N 1)))))

(prolog-memory 64)
(pu.cases 300)
(output "~A passed, ~A failed~%" (value pu.passed) (value pu.failed))

\\ Inlining. A defun's code
\\ carries (Params Body) when the body is small, has no handlers, calls
\\ nothing named F, and, at stage 0, has no float literals (stage 0 and shen-jit
\\ may read their last bits differently); otherwise []. A call to a sealed F
\\ with as many arguments as F's parameters becomes the body, two levels
\\ deep at most, or at any depth if it is primitives alone over parameters and
\\ constants, or if its code calls nothing but where an error's message is
\\ made (inline-at). A closure in the body becomes one of the caller's.

(shen.x.namespace shen-jit.lower
  (use shen-jit)
  (externals [apply const prim trap var calling contained loop typed])

(define inline-form
  F Params Body Stage0 -> [Params Body] where (and (inlinable? F Body Stage0)
                                                   (small? Body))
  _ _ _ _ -> [])

\\ A body of primitives alone calls nothing, so it may be larger.
(define small?
  Body -> (let Size (size Body)
            (or (<= Size 15) (and (<= Size 48) (leaf? Body)))))

(define inlinable?
  F [F | _] _ -> false
  _ [Head | _] _ -> false where (element? Head [trap-error defun eval-kl])
  F [X | Xs] Stage0 -> (and (inlinable? F X Stage0) (inlinable? F Xs Stage0))
  _ X Stage0 -> (not (and Stage0 (number? X) (not (integer? X)))))

(define size
  [X | Xs] -> (+ (size X) (size Xs))
  _ -> 1)

(define shen-jit.lower.call
  F Args -> (let Inline (inline-body F (length Args))
              (cond ((empty? Inline)
                     (open-call F (open-body F (length Args)) Args))
                    ((loop-form? Inline) (inline-loop F Inline Args))
                    (true (shen-jit.lower.inline F (hd Inline) (hd (tl Inline)) Args)))))

\\ A call to an open function with a small body inlines it too, behind a
\\ test that the name's definition is still the one with that very body
\\ (shen-jit.inlined?), which compiled code makes a nop until the name is
\\ redefined; the arguments go to fresh variables first, for either branch.
(define open-call
  F [] Args -> [call F Args]
  F Inline Args -> (let Vars (map (/. A (shen-jit.lower.fresh arg)) Args)
                        Refs (map (/. V [var V]) Vars)
                     (lets Vars Args
                                            [if [prim shen-jit.inlined? [[const F] [const Inline]]]
                                                (shen-jit.lower.inline F (hd Inline) (hd (tl Inline)) Refs)
                                                [call F Refs]])))

(define open-body
  F N -> (if (shen-jit.sealed? F) [] (inline-at F N)))

(define inline-body
  F N -> (if (shen-jit.sealed? F) (inline-at F N) []))

\\ A body of primitives over parameters and constants, such as a struct's
\\ reader or constructor, calls nothing, so it is inlined at any depth. So is
\\ a contained body where F is sealed: F's own code called nothing but where
\\ an error's message is made, and nothing that calls is inlined there, so the
\\ body inlines no more than that code held, and F, which cannot be redefined,
\\ was made after all it calls; nor is it a level (inlined-norm). So is a
\\ typed body, larger, which only code that keeps values in registers inlines,
\\ where F is sealed: F's own code called nothing but on its way out. One whose
\\ code calls, calling, is inlined into such code two levels deep, as those
\\ calls could reach it again. A loop is inlined two levels deep, only where F
\\ is sealed, and not inside itself: its own calls of F go back to its head.
(define inline-at
  F N -> (let Inline (shen-jit.inline-body F)
           (if (and (cons? Inline) (= (length (hd Inline)) N)
                    (if (trap-error (value *cold*) (/. E false))
                        (and (not (loop-form? Inline)) (leaf? (hd (tl Inline))))
                        (inline-here? F (if (stage0?) (uncontained Inline) Inline)
                                      (trap-error (value *inline-depth*) (/. E 0))
                                      (trap-error (value *registers*) (/. E false)))))
               Inline
               [])))

(define inline-here?
  _ [_ Body] Depth _ -> (or (< Depth 2) (leaf? Body))
  F [_ Body contained] Depth _ -> (or (< Depth 2) (shen-jit.sealed? F) (leaf? Body))
  F [_ _ typed] Depth Registers -> (and Registers (or (< Depth 2) (shen-jit.sealed? F)))
  _ [_ _ calling] Depth Registers -> (and Registers (< Depth 2))
  F [_ _ loop _] Depth Registers
  -> (and Registers (< Depth 2) (shen-jit.sealed? F)
          (not (element? F (trap-error (value *looping*) (/. E [])))))
  _ _ _ _ -> false)

\\ Stage 0 knows bodies from their source alone, not from code, so lowering for it, as the
\\ self-hosting check does too, takes a contained body as any small one.
(define stage0?
  -> (trap-error (value *stage0*) (/. E false)))

(define uncontained
  [Params Body contained] -> [Params Body]
  Inline -> Inline)

\\ Whether F is sealed and its small body contained (inline-of).
(define contained?
  F -> (and (shen-jit.sealed? F) (not (stage0?))
            (let Inline (shen-jit.inline-body F)
              (and (cons? Inline) (cons? (tl (tl Inline))) (= (hd (tl (tl Inline))) contained)))))

(define leaf?
  [Op | Args] -> (and (leaf-op? Op (length Args))
                      (leaves? Args))
  _ -> false)

\\ A primitive, or a sealed function whose own body is such a body, as the
\\ typed helpers of struct.shen are.
(define leaf-op?
  Op N -> true where (= N (prim-arity Op))
  Op N -> (let Inline (shen-jit.inline-body Op)
            (and (cons? Inline) (= (length (hd Inline)) N) (not (loop-form? Inline))
                 (leaf? (hd (tl Inline)))))
    where (and (shen-jit.symbol? Op) (shen-jit.sealed? Op))
  _ _ -> false)

(define leaves?
  [] -> true
  [X | Xs] -> (and (leaf? X) (leaves? Xs)) where (cons? X)
  [_ | Xs] -> (leaves? Xs))

\\ The arguments go to fresh variables first, so binding the parameters cannot
\\ capture a variable an argument uses; the body is normalized in its own
\\ scope, so it cannot capture the caller's variables either.
(define shen-jit.lower.inline
  F Params Body Args -> (inline-args F Params Body Args)
      where (or (element? let Params) (element? lambda Params)) \\ then calls, not binders, in Body
  F Params Body Args -> (inline-numbers F Params Body Args [] []))

\\ A number argument goes into the body itself, so that what the body computes
\\ from it can fold: (vector 1) allocates a constant length, and a float is a constant
\\ of the code that computes with it, not a variable read from a slot.
(define inline-numbers
  F [P | Ps] Body [[const N] | As] Qs Bs
  -> (inline-numbers F Ps (shen-jit.lower.subst P N Body) As Qs Bs)
      where (number? N)
  F [P | Ps] Body [A | As] Qs Bs -> (inline-numbers F Ps Body As [P | Qs] [A | Bs])
  F _ Body _ Qs Bs -> (inline-args F (reverse Qs) Body (reverse Bs)))

(define shen-jit.lower.subst
  X V X -> V
  X V [let X Y Body] -> [let X (shen-jit.lower.subst X V Y) Body]
  X V [lambda X Body] -> [lambda X Body]
  X V [Y | Ys] -> (map (/. Z (shen-jit.lower.subst X V Z)) [Y | Ys])
  _ _ Y -> Y)

(define inline-args
  F Params Body Args -> (inline-frozen F Params Args (inlined-norm F Params Body) [] []))

\\ F's Body normalised where it is inlined: a level deeper, unless F is contained, and typed only if
\\ F was annotated too.
(define inlined-norm
  F Params Body -> (let Depth (value *inline-depth*)
                        Deeper (set *inline-depth* (if (contained? F) Depth (+ Depth 1)))
                        Typed (value *typed*)
                        Inner (set *typed* (and Typed (annotated? F)))
                        Normal (norm Params Body)
                        Back (set *inline-depth* Depth)
                        Outer (set *typed* Typed)
                     Normal))

\\ An argument (freeze E) of a parameter the inlined body only thaws, once: E runs
\\ there and no closure is made, given that no name E uses is bound on the way.
\\ An argument (lambda P1 ... (lambda Pn Inner)) of a parameter the body only applies to n
\\ arguments: each application becomes Inner with P1 ... Pn bound to those, as let-lambda does for
\\ a let, and no closure is made, given the same conditions and that no parameter of F binds a
\\ name the lambda uses. Making a closure has no effects, so it may move.
(define inline-frozen
  F [P | Ps] [[freeze E] | As] Normal Qs Bs
  -> (inline-frozen F Ps As (thaw-in P E Normal) Qs Bs)
      where (and (= (thaw-count P Normal) 1)
                 (empty? (intersection (free E)
                                       (union [P | (append Ps Qs)] (binders Normal)))))
  F [P | Ps] [[lambda X E] | As] Normal Qs Bs
  -> (inline-frozen F Ps As (apply-in P (lambda-params [lambda X E]) (lambda-body [lambda X E]) Normal)
                    Qs Bs)
      where (lambda-in? P [lambda X E] Normal [P | (append Ps Qs)])
  F [P | Ps] [A | As] Normal Qs Bs -> (inline-frozen F Ps As Normal [P | Qs] [A | Bs])
  _ _ _ [const K] [] _ -> [const K]
  F _ _ Normal Qs Bs
  -> (let Params (reverse Qs)
          Args (reverse Bs)
          Fresh (map (/. P (shen-jit.lower.fresh arg)) Params)
       (lets Fresh Args
                              (lets Params (map (/. X [var X]) Fresh)
                                                     [let inlining [const F] Normal]))))

(define lambda-in?
  P V Normal Bound
  -> (let Params (lambda-params V)
          Uses (applies P (length Params) Normal)
       (and (> Uses 0)
            (<= (* (- Uses 1) (size V)) 1500)
            (empty? (intersection (free V) (union Bound (binders Normal))))
            (empty? (intersection Params (vars-of Normal))))))

\\ The walkers of normalised code below visit a node's parts one by one, each as a node, and
\\ never a node's tail, which may look like one: the tail of [lambda apply Body] is [apply Body],
\\ and that of [call var Args] is [var Args].
(define counts
  \\ the uses counted in each part: their sum, or the first that is negative
  [] -> 0
  [N | Ns] -> (if (< N 0) N (let M (counts Ns) (if (< M 0) M (+ N M)))))

(define union-all
  [] -> []
  [X | Xs] -> (union X (union-all Xs)))

(define lets
  [X | Xs] [V | Vs] Body -> [let X V (lets Xs Vs Body)]
  _ _ Body -> Body)

(define shen-jit.lower.fail
  Message X -> (simple-error (make-string "shen-jit lowerer: ~A: ~R" Message X))))

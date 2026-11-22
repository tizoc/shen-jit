\\ Emission. Env maps the variables of the current code object to slots;
\\ any other variable is captured. Top is the first free slot: every slot
\\ that may still be read lies below it, so windows and temporaries go at or
\\ above it. A Target is a slot below Top, or tail for a tail position.
\\ Nothing writes a slot while a variable bound to it is in scope, so a let
\\ of one local variable to another shares its slot (inlining makes many).

(shen.x.namespace shen-jit.lower
  (use shen-jit)
  (externals [apply call-sealed call-value capture closure const entry exit goto jump jump-if-false
    jump-unless-entry label move none pop-handler prim push-handler skip slot tail-call
    tail-call-sealed tail-call-value trap var])

(define shen-jit.lower.slot
  X Env -> (let Binding (assoc X Env)
             (if (and (cons? Binding) (number? (tl Binding))) (tl Binding) [])))

\\ Inside an inlined loop that is not in tail position, a tail position of its body is an exit,
\\ Target [exit Kind Dest End]: the value goes to Dest, a float or word register, a slot, or
\\ nowhere for effect, and the code jumps to End, after the loop. Neither falls through.
(define expr
  B Env [if C X Y] Target Top -> (shen-jit.lower.if B Env C X Y Target Top)
  B Env [let G [freeze E] Body] Target Top -> (shen-jit.lower.goto B Env G E Body Target Top)
      where (and (final? Target) (> (thaws G Body true) 0))
  B Env [let G [freeze E] Body] Target Top
  -> (expr B Env (thaw-in G E Body) Target Top)
      where (inline-thaw? G E Body)
  B Env [let G [freeze E] Body] D Top -> (frozen-value B Env G E Body slot D Top)
      where (and (number? D) (> (thaws G Body true) 0))
  B Env [apply [var G]] Target _ -> (emit B [jump (goto-label G Env)])
      where (and (final? Target) (in-kind? goto G Env))
  B Env [let inlining [const F] Body] Target Top
  -> (mark B F (freeze (expr B Env Body Target Top)))
  B Env [let shen-jit.lower.loop [const Info] Body] Target Top
  -> (released B (freeze (inlined-loop B Env Info Body Target Top)))
      where (final? Target)
  B Env [let shen-jit.lower.loop [const Info] Body] D Top
  -> (let End (new-label B)
       (do (released B (freeze (alone B (freeze (inlined-loop B Env Info Body [exit slot D End] Top)))))
           (emit B [label End])))
  B Env [let X V Body] Target Top -> (let Bound (let-bound B Env X V Top) (expr B (hd Bound) Body Target (tl Bound)))
  B Env [do X Y] Target Top
  -> (do (shen-jit.lower.effect B Env X Top)
         (expr B Env Y Target Top))
  B Env [call F Args] Target Top -> (shen-jit.lower.again B Env F Args Top)
      where (and (final? Target) (loops? B F Args))
  B Env X [exit Kind Dest End] Top -> (shen-jit.lower.exit B Env X Kind Dest End Top)
  B Env [call F Args] tail Top
  -> (let N (length Args)
       (do (loop-args B Env Args (slots-from 2 Args) [] (if (> Top (+ N 2)) Top (+ N 2)) [] [])
           (emit B (named-call B F tail 0 N))))
  B Env [call F Args] Target Top
  -> (do (window B Env Args (+ Top 2))
         (emit B (named-call B F Target Top (length Args))))
  B Env [apply F A] Target Top
  -> (apply-all B Env (chain [apply F A] []) Target Top)
      where (apply-all? [apply F A])
  B Env [apply F | Arg] Target Top
  -> (do (window B Env [F | Arg] (+ Top 1))
         (emit B (if (= Target tail)
                                      [tail-call-value Top (length Arg)]
                                      [call-value Target Top (length Arg)])))
  B Env [trap X E H] Target Top -> (shen-jit.lower.trap B Env X E H Target Top)
  B Env X tail Top -> (emit B [return (operand B Env X Top)])
  B Env X D Top -> (shen-jit.lower.value B Env X D Top))

\\ ((F A1) ... An), n >= 2, with every Ai a variable or a constant, so that
\\ evaluating them before applying F changes nothing: a closure that takes
\\ the n arguments at once (finish-entry) gets one call with all of them,
\\ and anything else is applied one argument at a time, as before, reading
\\ the same slots again.
(define apply-all?
  X -> (let Args (tl (chain X []))
         (and (>= (length Args) 2) (simple? Args))))

(define simple?
  [] -> true
  [[var _] | Xs] -> (simple? Xs)
  [[const _] | Xs] -> (simple? Xs)
  _ -> false)

(define apply-all
  B Env [Head | Args] Target Top
  -> (let H (shen-jit.lower.fresh shen-jit.lower.head)
          S (head-slot B Env Head Top)
          Env1 [[H | S] | Env]
          W (if (= S Top) (+ Top 1) Top)
          N (length Args)
          Fallback (new-label B)
       (do (window B Env1 [[var H] | Args] (+ W 1))
           (emit B [jump-unless-entry S N Fallback])
           (if (= Target tail)
               (do (emit B [tail-call-value W N])
                   (emit B [label Fallback])
                   (apply-each B Env1 [var H] Args tail W))
               (let Done (new-label B)
                 (do (emit B [call-value Target W N])
                     (emit B [jump Done])
                     (emit B [label Fallback])
                     (apply-each B Env1 [var H] Args Target W)
                     (emit B [label Done])))))))

\\ The slot of a variable head, or Top after evaluating any other.
(define head-slot
  B Env [var X] _ -> (shen-jit.lower.slot X Env) where (number? (shen-jit.lower.slot X Env))
  B Env Head Top -> (do (shen-jit.lower.value B Env Head Top (+ Top 1)) Top))

(define apply-each
  B Env F [A] Target Top -> (expr B Env [apply F A] Target Top)
  B Env F [A | As] Target Top
  -> (let R (shen-jit.lower.fresh partial)
       (do (shen-jit.lower.value B Env [apply F A] Top (+ Top 1))
           (apply-each B [[R | Top] | Env] [var R] As Target (+ Top 1)))))

\\ (let G (freeze E) Body) in tail position, or at an exit of an inlined loop,
\\ where Body uses G only as (thaw G) in such a position, as the factoriser's
\\ GoTo bindings do: E becomes code at a label after Body and each (thaw G) a
\\ jump to it, so no closure is made. E's variables keep their slots, since
\\ Body only writes at or above Top and ends in a return, a tail call or a
\\ jump out of the loop on every other path. For the same reason the registers Body took go
\\ back before E, which sees only those bound before.
(define shen-jit.lower.goto
  B Env G E Body Target Top
  -> (let L (new-label B)
       (do (released B (freeze (expr B [[G goto L] | Env] Body Target Top)))
           (emit B [label L])
           (expr B Env E Target Top))))

\\ The same where the let's value goes to a slot or a register Dest of Kind: Body and E give it there
\\ as at an exit of an inlined loop, and go on past both.
(define frozen-value
  B Env G E Body Kind Dest Top
  -> (let End (new-label B)
       (do (released B (freeze (alone B (freeze (shen-jit.lower.goto B Env G E Body [exit Kind Dest End] Top)))))
           (emit B [label End]))))

\\ A target that never falls through: a tail position, or an exit of an inlined loop.
\\ A store into bytes from registers, for its value, which is the bytes: the store, then them.
(define store-value
  B Env Op M I V D Top -> (let OM (operand B Env M Top)
                               Store (released B (freeze (stored B Env Op OM I V Top)))
                            (if (= OM D) skip (emit B [move D OM]))))

(define final?
  tail -> true
  [exit | _] -> true
  _ -> false)

(define goto-label
  G Env -> (hd (tl (tl (assoc G Env)))))

\\ The number of (thaw G) in tail position in X, or -1 if X uses G in any
\\ other way or binds G again. Tail says whether X is in tail position.
(define thaws
  G [apply [var G]] true -> 1
  G [var G] _ -> -1
  G [if C X Y] Tail -> (thaws-all G [[C false] [X Tail] [Y Tail]])
  G [let G _ _] _ -> -1
  \\ A frozen E that is itself a label is code in tail position.
  G [let _ [freeze E] Body] true -> (thaws G Body true)
      where (not (shen-jit.lower.occurs? G E))
  G [let H [freeze E] Body] true -> (thaws-all G [[E true] [Body true]])
      where (> (thaws H Body true) 0)
  G [let _ V Body] Tail -> (thaws-all G [[V false] [Body Tail]])
  G [do X Y] Tail -> (thaws-all G [[X false] [Y Tail]])
  G [and X Y] _ -> (thaws-all G [[X false] [Y false]])
  G [or X Y] _ -> (thaws-all G [[X false] [Y false]])
  G [lambda G _] _ -> -1
  G [lambda _ Body] _ -> (thaws G Body false)
  G [freeze Body] _ -> (thaws G Body false)
  G [prim _ Args] _ -> (thaws-all G (non-tail Args))
  G [call _ Args] _ -> (thaws-all G (non-tail Args))
  G [apply F | Arg] _ -> (thaws-all G (non-tail [F | Arg]))
  G [trap _ G _] _ -> -1
  G [trap X _ H] _ -> (thaws-all G [[X false] [H false]])
  _ _ _ -> 0)

\\ (let G (freeze E) Body), where Body uses G once, as (thaw G): that thaw
\\ becomes E itself and the let goes, so no closure is made. E then runs
\\ exactly when the thaw would have, with the same values, provided Body
\\ binds no variable of E.
(define inline-thaw?
  G E Body -> (and (= 1 (thaw-count G Body))
                   (empty? (intersection (vars-of E)
                                         (binders Body)))))

\\ The number of (thaw G) anywhere in X, or -1 if X uses G in any other way
\\ or binds it again.
(define thaw-count
  G [apply [var G]] -> 1
  G [var G] -> -1
  _ [const _] -> 0
  G [let G _ _] -> -1
  G [lambda G _] -> -1
  G [trap _ G _] -> -1
  G [X | Xs] -> (counts (map (/. Y (thaw-count G Y)) [X | Xs]))
  _ _ -> 0)

(define thaw-in
  G E [apply [var G]] -> E
  _ _ [const C] -> [const C]
  G E [X | Xs] -> (map (/. Y (thaw-in G E Y)) [X | Xs])
  _ _ X -> X)

(define vars-of
  [var X] -> [X]
  [const _] -> []
  [X | Xs] -> (union-all (map (/. Y (vars-of Y)) [X | Xs]))
  _ -> [])

(define binders
  [let X V Body] -> [X | (union (binders V) (binders Body))]
  [lambda X Body] -> [X | (binders Body)]
  [trap X E H] -> [E | (union (binders X) (binders H))]
  [X | Xs] -> (union-all (map (/. Y (binders Y)) [X | Xs]))
  _ -> [])

(define thaws-all
  _ [] -> 0
  G [[X Tail] | Xs] -> (let N (thaws G X Tail)
                         (if (< N 0)
                             N
                             (let M (thaws-all G Xs)
                               (if (< M 0) M (+ N M))))))

(define non-tail
  [] -> []
  [X | Xs] -> [[X false] | (non-tail Xs)])

\\ Compute X into slot D, which is below Top.
(define shen-jit.lower.value
  B Env X D Top -> (do (reserve B D) (value-h B Env X D Top)))

(define value-h
  B _ [const X] D _ -> (emit B [const D (constant B X)])
  \\ A read that register code takes into a register, here into its slot as it is.
  B Env [prim Op Args] D Top -> (emit B [prim D (emitted-prim Op) | (operands B Env Args Top)])
      where (read-into-register? Op)
  \\ A raise in code with registers: what its message reads from them boxed first, and the message,
  \\ which calls make, made as boxed code, so that nothing it computes is in a register across them.
  B Env [prim simple-error [Message]] D Top
  -> (let Spilled (spill B Env (vars-of Message) Top)
          Floats (<-address B 12)
          Off (address-> B 12 boxed)
          O (operand B (hd Spilled) Message (hd (tl Spilled)))
          On (address-> B 12 Floats)
       (emit B [prim D simple-error O]))
      where (registers? B)
  B Env X D Top -> (box B Env X D Top)
      where (unboxed? B Env X)
  B Env [prim Op Args] D Top
  -> (shen-jit.lower.if B Env [prim Op Args] [const true] [const false] D Top)
      where (unboxed-test? B Env Op Args)
  B Env [var X] D _ -> (load-var B Env X D)
  \\ A chain of conses with constant heads stays in one slot: only the innermost
  \\ reads other slots. A parameter's slot is left out, as nothing but a tail
  \\ call may read it once written; the tail then goes to a slot above.
  B Env [prim cons [[const A] [prim cons Args]]] D Top
  -> (let K (constant B A)
       (do (value-h B Env [prim cons Args] D Top)
           (emit B [prim D cons [const K] D])))
      where (>= D (+ 2 (<-address B 1)))
  B Env [prim Op [M I V]] D Top -> (store-value B Env Op M I V D Top)
      where (register-store? B Env Op I V)
  B Env [prim shen-jit.copy-bytes [M I W [const 0] [const 8]]] D Top -> (store-value B Env shen-jit.s64! M I W D Top)
      where (word-stored? B Env I W)
  B Env [prim Op Args] D Top
  -> (emit B [prim D Op | (operands B Env Args Top)])
  B Env [lambda X Body] D Top -> (shen-jit.lower.closure B Env lambda [X] Body D Top)
  B Env [freeze Body] D Top -> (shen-jit.lower.closure B Env freeze [] Body D Top)
  B Env [and X Y] D Top
  -> (shen-jit.lower.if B Env [and X Y] [const true] [const false] D Top)
  B Env [or X Y] D Top
  -> (shen-jit.lower.if B Env [or X Y] [const true] [const false] D Top)
  B Env X D Top -> (expr B Env X D Top))

(define load-var
  B Env X D -> (let Binding (assoc X Env)
                 (cond ((empty? Binding)
                        (emit B [capture D (capture-index B X)]))
                       ((= (tl Binding) D) skip)
                       (true (emit B [move D (tl Binding)])))))

\\ An operand for X: a local variable's own slot, (const K) for a constant,
\\ or Top, after computing X there.
(define operand
  _ Env [var X] _ -> (shen-jit.lower.slot X Env) where (number? (shen-jit.lower.slot X Env))
  B _ [const X] _ -> [const (constant B X)]
  B Env X Top -> (do (shen-jit.lower.value B Env X Top (+ Top 1)) Top))

(define operands
  _ _ [] _ -> []
  B Env [X | Xs] Top
  -> (let S (operand B Env X Top)
       [S | (operands B Env Xs (if (= S Top) (+ Top 1) Top))]))

\\ Evaluate Xs into consecutive slots from S, each above the previous ones.
(define window
  _ _ [] _ -> skip
  B Env [X | Xs] S -> (do (shen-jit.lower.value B Env X S (+ S 1))
                          (window B Env Xs (+ S 1))))

\\ The parameter slots of Xs, from S up, where a named tail call (window 0) computes its
\\ arguments, as loop-args does a loop's.
(define slots-from
  _ [] -> []
  S [_ | Xs] -> [S | (slots-from (+ S 1) Xs)])

\\ Whether X has some [var V] with V in slot S, among the variables vars-of finds,
\\ bound ones included, stopping at the first.
(define reads?
  Env [var V] S -> (= (shen-jit.lower.slot V Env) S)
  _ [const _] _ -> false
  Env [X | Xs] S -> (element? true (map (/. Y (reads? Env Y S)) [X | Xs]))
  _ _ _ -> false)

(define named-call
  B F Target A N
  -> (let Sealed (or (= F shen-jit.eval-kl) (element? F (<-address B 2)) (shen-jit.sealed? F))
       (do (reserve B (+ A (+ N 1)))
           (cond ((and (= Target tail) Sealed) [tail-call-sealed A F N])
                 ((= Target tail) [tail-call A F N])
                 (Sealed [call-sealed Target A F N])
                 (true [call Target A F N])))))

\\ What the test and each branch took in registers goes back after it: the else and what follows
\\ see only what was bound before. Each branch first checks a register that the test finds below a
\\ fixnum only in the other, if it may be past the greatest one (past-checked).
(define shen-jit.lower.if
  \\ An else that jumps to a label: the test jumps there itself.
  B Env C X [apply [var G]] Target Top
  -> (do (test B Env C (goto-label G Env) Top)
         (if-branch B Env C true X Target Top))
      where (and (final? Target) (in-kind? goto G Env) (= none (past-unbounded B Env C false)))
  B Env C X Y Target Top
  -> (let Else (new-label B)
          End (end-label B Target)
       (do (released B (freeze (do (test B Env C Else Top)
                                   (if-branch B Env C true X Target Top))))
           (jump-to-end B End)
           (emit B [label Else])
           (released B (freeze (if-branch B Env C false Y Target Top)))
           (place-end B End))))

(define if-branch
  B Env C Truth X Target Top -> (do (past-checked B Env C Truth)
                                    (expr B (bounded B Env C Truth) X Target Top)))

\\ Code in tail position, or at an exit, never falls through, so it needs no join label.
(define end-label
  B Target -> (if (final? Target) none (new-label B)))

(define jump-to-end
  _ none -> skip
  B L -> (emit B [jump L]))

(define place-end
  _ none -> skip
  B L -> (emit B [label L]))

\\ Fall through when X is true; continue at Else when it is false.
(define test
  B Env [and X Y] Else Top -> (do (test B Env X Else Top)
                                  (test B Env Y Else Top))
  B Env [or X Y] Else Top
  -> (let Next (new-label B)
          Then (new-label B)
       (do (test B Env X Next Top)
           (emit B [jump Then])
           (emit B [label Next])
           (test B Env Y Else Top)
           (emit B [label Then])))
  \\ An inlined call's guard is an if: its branches are tests too, rather than
  \\ a Boolean to test again. A constant branch, as in not, is left to the
  \\ JIT, which follows the constant to the one jump it takes.
  B Env [if C X Y] Else Top
  -> (let Other (new-label B)
          Then (new-label B)
       (do (test B Env C Other Top)
           (test B Env X Else Top)
           (emit B [jump Then])
           (emit B [label Other])
           (test B Env Y Else Top)
           (emit B [label Then])))
      where (not (or (constant? X) (constant? Y)))
  \\ The factoriser binds each selector with a let inside the and that
  \\ tests it: the body is a test too, rather than a Boolean to test again.
  B Env [let inlining [const F] Body] Else Top
  -> (mark B F (freeze (test B Env Body Else Top)))
  B Env [let shen-jit.lower.loop C Body] Else Top
  -> (emit B [jump-if-false (operand B Env [let shen-jit.lower.loop C Body] Top) Else])
  B Env [prim Op [X Y]] Else Top -> (unboxed-test B Env Op X Y Else Top)
      where (unboxed-test? B Env Op [X Y])
  B Env [prim shen-jit.word-op [[const Op] X Y]] Else Top -> (unboxed-test B Env Op X Y Else Top)
      where (unboxed-test? B Env shen-jit.word-op [[const Op] X Y])
  B Env [let X V Body] Else Top -> (let Bound (let-bound B Env X V Top) (test B (hd Bound) Body Else (tl Bound)))
  B Env [do X Y] Else Top -> (do (shen-jit.lower.effect B Env X Top)
                                 (test B Env Y Else Top))
  B Env X Else Top -> (emit B [jump-if-false (operand B Env X Top)
                                                              Else]))

(define constant?
  [const _] -> true
  _ -> false)

\\ The protected expression is never in tail position; the handler is when
\\ the trap-error is. E is bound to the exception in slot Top.
(define shen-jit.lower.trap
  B Env X E H Target Top
  -> (let Handler (new-label B)
          End (end-label B Target)
          S (if (= Target tail) Top Target)
       (do (emit B [push-handler Handler])
           (shen-jit.lower.value B Env X S (if (= Target tail) (+ Top 1) Top))
           (emit B [pop-handler])
           (if (= Target tail)
               (emit B [return S])
               (jump-to-end B End))
           (emit B [label Handler])
           (reserve B Top)
           (if (element? E (vars-of H))
               (emit B [exception Top])
               skip)
           (expr B [[E | Top] | Env] H Target (+ Top 1))
           (place-end B End))))

\\ Lower a lambda or freeze body as nested code, then capture the variables
\\ it uses from enclosing scopes, in the order the nested code numbered them.
(define shen-jit.lower.closure
  B Env Kind Params Body D Top
  -> (closure-with B Env (builder Kind (length Params) (<-address B 2))
                                    (if (= Kind lambda) (finish-lambda Params Body)
                                        (/. Nested (finish Nested Params Body)))
                                    D Top))

(define closure-with
  B Env Nested Finish D Top
  -> (let C (add-code B (Finish Nested))
          Slots (operands B Env (vars (<-address Nested 8)) Top)
       (emit B [closure D C | Slots])))

\\ A lambda that returns lambdas, as (/. A B C Body) and lambda forms are,
\\ also takes all their arguments at once: (entry N L) comes first, then
\\ the usual one-argument body, then at L the innermost body with the N
\\ parameters in slots 2 to N+1. Its free variables are the outer
\\ lambda's, so it reads them from the same closure. Only the outermost
\\ lambda of a chain has one, and only when the innermost body is at most
\\ 400 nodes, since it is a second copy. Code lowered at stage 0 (Sealed is
\\ not []) has none: the kernel does not apply its own chains to several
\\ arguments, and its 183 lambda forms would grow the image by 5%; those
\\ fn makes later have them.
(define finish-lambda
  Params [lambda X Body]
  -> (/. B (if (empty? (<-address B 2))
               (finish-entry B Params [lambda X Body])
               (finish-plain B Params [lambda X Body])))
      where (and (<= (size (lambda-body Body)) 400)
                 \\ The entry binds every name at once, so each must be bound once.
                 (distinct? (append Params (lambda-params [lambda X Body]))))
  Params Body -> (/. B (finish-plain B Params Body)))

(define distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (distinct? Xs)))

(define finish-entry
  B Params Inner
  -> (let All (append Params (lambda-params Inner))
          L (new-label B)
       (do (emit B [entry (length All) L])
           (plain-return B Params Inner)
           (emit B [label L])
           (reserve B (+ 1 (length All)))
           (expr B (shen-jit.lower.bind All 2) (lambda-body Inner)
                                  tail (+ 2 (length All)))
           (code-form B))))

\\ The one-argument bodies of a chain: its inner lambdas take one argument
\\ each, and have no entry.
(define finish-plain
  B Params [lambda X Body] -> (do (plain-return B Params [lambda X Body])
                                  (code-form B))
  B Params Body -> (finish B Params Body))

(define plain-return
  B Params [lambda X Body]
  -> (let Top (+ 2 (length Params))
       (do (reserve B Top)
           (closure-with B (shen-jit.lower.bind Params 2)
                                          (builder lambda 1 (<-address B 2))
                                          (/. Nested (finish-plain Nested [X] Body))
                                          Top (+ Top 1))
           (emit B [return Top]))))

(define vars
  [] -> []
  [X | Xs] -> [[var X] | (vars Xs)]))

\\ Fixed names

(shen.x.namespace shen-jit.lower
  (use shen-jit)
  (externals [apply const fixed prim raise-cond trap var])

\\ The primitives' arities, and the special forms, eval-kl and protect, which
\\ are fixed but no primitive. A named call looks its name up, so they go in a
\\ dictionary, made the first time it is needed.
(define fixed-names
  -> [[0 [shen-jit.quiet? shen-jit.mark-toplevel shen-jit.backtrace shen-jit.errno shen-jit.c-errno
       shen-jit.pointers-dead shen-jit.collect]]
   [1 [number? hd tl cons? tlstr str string? n->string string->n
       intern absvector absvector? value simple-error error-to-string
       get-time close read-byte char-stream? read-unit-string
       shen-jit.install shen-jit.fixnum? shen-jit.symbol? shen-jit.exit
       shen-jit.symbol-kind shen-jit.dict-entries
       shen-jit.sealed? shen-jit.sealing shen-jit.inline-body
       shen-jit.vector? shen-jit.trace-text shen-jit.integer?
       shen-jit.bytes shen-jit.bytes? shen-jit.bytes-length shen-jit.string->bytes
       shen-jit.bit-not shen-jit.bswap32 shen-jit.popcount shen-jit.clz shen-jit.ctz
       shen-jit.pvar shen-jit.pvar? shen-jit.pvar-offset
       shen-jit.pointer? shen-jit.pointer-kind shen-jit.pointer-address
       shen-jit.pointer->string shen-jit.pointer-kill shen-jit.pointer-owner
       shen-jit.pointer-read-only shen-jit.arity shen-jit.function shen-jit.float shen-jit.sqrt
       shen-jit.truncate]]
   [2 [+ - * / < > <= >= = cons cn pos <-address set open write-byte
       write-string shen-jit.hash shen-jit.filled-vector
       shen-jit.save-executable shen-jit.foreign
       shen-jit.dict-find shen-jit.dict-remove shen-jit.tagged? shen-jit.same? shen-jit.newpv shen-jit.gc
       shen-jit.read-file shen-jit.append shen-jit.arity?
       shen-jit.inlined? shen-jit.u8 shen-jit.u16 shen-jit.u32
       shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor
       shen-jit.shift-left shen-jit.shift-right shen-jit.rotate32
       shen-jit.decimal shen-jit.s32 shen-jit.s64 shen-jit.f32 shen-jit.f64
       shen-jit.pointer-sized shen-jit.pointer-guard shen-jit.set-arity shen-jit.apply
       shen-jit.quotient shen-jit.remainder]]
   [3 [address-> shen-jit.struct-ref shen-jit.dict-put shen-jit.absvector3 shen-jit.deref
       shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.bytes->string
       shen-jit.bytes->pointer shen-jit.pointer->bytes
       shen-jit.s32! shen-jit.s64! shen-jit.f32! shen-jit.f64! shen-jit.pointer! shen-jit.isolate
       shen-jit.word-op]]
   [4 [shen-jit.write-bytes]]
   [5 [shen-jit.copy-bytes shen-jit.xxh64]]
   [fixed [if and or cond let lambda defun freeze type trap-error do thaw eval-kl protect]]])

(define fixed-table
  -> (trap-error (value *fixed*)
                 (/. E (set *fixed*
                            (fill-table (fixed-names) (shen.dict 256))))))

(define fill-table
  [] Dict -> Dict
  [[_ []] | Groups] Dict -> (fill-table Groups Dict)
  [[A [F | Fs]] | Groups] Dict -> (do (shen.dict-> Dict F A)
                                      (fill-table [[A Fs] | Groups] Dict)))

\\ F's arity, fixed for a fixed name that is no primitive, or -1.
(define fixed-entry
  F -> (trap-error (shen.<-dict (fixed-table) F) (/. E -1)))

(define prim-arity
  F -> (let Entry (fixed-entry F)
         (if (number? Entry) Entry -1)))

(define fixed?
  F -> (not (= (fixed-entry F) -1)))

\\ The kernel itself defines do and thaw, so stage 0 (where they are sealed)
\\ lowers those definitions; any other defun of a fixed name is an error.
(define check-defun
  F Params Sealed
  -> (cond ((not (shen-jit.symbol? F)) (shen-jit.lower.fail "defun name is not a symbol" F))
           ((and (fixed? F)
                 (not (and (element? F [do thaw protect]) (element? F Sealed))))
            (shen-jit.lower.fail "defun of a fixed name" F))
           (true (check-params F Params))))

(define check-params
  _ [] -> true
  F [P | _] -> (shen-jit.lower.fail "non-symbol defun parameter" [F P]) where (not (shen-jit.symbol? P))
  F [P | Ps] -> (shen-jit.lower.fail "duplicate defun parameter" [F P]) where (element? P Ps)
  F [_ | Ps] -> (check-params F Ps)
  F Ps -> (shen-jit.lower.fail "defun parameters are not a list" [F Ps]))

\\ ---------------------------------------------------------------------------
\\ Normalization. Scope is the list of lexically bound symbols. The result
\\ uses these nodes:
\\
\\   [const V] [var X] [if C X Y] [and X Y] [or X Y] [let X V Body] [do X Y]
\\   [lambda X Body] [freeze Body] [prim Op Args] [call F Args]
\\   [apply F] [apply F X] [trap X E Handler]

(define norm
  \\ A query as the kernel compiles prolog?: its vector of bindings goes back when the
  \\ query ends, for the next one to take. Not when the query makes a lambda other than
  \\ a goal passed to findall or call, or a freeze other than a continuation, which may
  \\ outlive it and read the vector.
  Scope [[[[[lambda B [lambda L [lambda K [lambda C Body]]]] [shen.prolog-vector]] Lock] Key] Cont]
  -> (norm Scope [let B [shen.prolog-vector]
                                  [shen-jit.prolog-done B [let L Lock [let K Key [let C Cont Body]]]]])
      where (and (only-goals? Body [B L K]) (shen-jit.sealed? shen-jit.prolog-done)
                 (empty? (intersection [let lambda shen.prolog-vector shen-jit.prolog-done] Scope))
                 \\ Lock, Key and Cont end up inside B, L and K, so none may name them.
                 (not (or (shen-jit.lower.occurs? B [Lock Key Cont])
                          (shen-jit.lower.occurs? L [Key Cont]) (shen-jit.lower.occurs? K Cont))))
  \\ ((fn F) X1 ... Xn) for a sealed F of arity n >= 1 is (F X1 ... Xn): F's
  \\ lambda form applies F to its n arguments, and F cannot be redefined.
  Scope [[fn F] | Args] -> [call F (norm-list Scope Args)]
      where (and (shen-jit.symbol? F) (not (element? fn Scope)) (not (element? F Scope))
                 (cons? Args) (shen-jit.sealed? F) (= (arity F) (length Args)))
  \\ For an open F, it is how the kernel calls a function it did not know
  \\ when compiling: one defined later, or in another package. A named call
  \\ when F takes n arguments, tested each time; otherwise the lambda form,
  \\ which also curries and raises "fn: F is undefined". The arguments are
  \\ evaluated before fn, which shows when F is undefined, and before F is
  \\ applied to the first when it takes fewer (docs/semantics.md).
  Scope [[fn F] | Args] -> (norm Scope (fn-call F Args))
      where (and (shen-jit.symbol? F) (cons? Args) (not (shen-jit.sealed? F))
                 (not (fixed? F))
                 (empty? (intersection [fn F let if shen-jit.arity?] Scope)))
  \\ ((lambda X Body) A) is (let X A Body): A is evaluated, then Body with X
  \\ bound to it, and no closure is made. The kernel's compiler wraps calls
  \\ to other packages' functions this way. Further arguments apply to the
  \\ result, as for any dynamic call.
  Scope [[lambda X Body] A | More] -> (norm Scope [[let X A Body] | More])
      where (and (shen-jit.symbol? X) (not (element? lambda Scope)) (not (element? let Scope))
                 (cons? More))
  Scope [[lambda X Body] A] -> [let X (norm Scope A) (norm [X | Scope] Body)]
      where (and (shen-jit.symbol? X) (not (element? lambda Scope)))
  Scope [F | Args] -> (norm-apply (norm Scope F)
                                                   (norm-list Scope Args))
      where (or (element? F Scope) (not (shen-jit.symbol? F)))
  \\ (is X Y B L K (freeze E)) and is!: unify first, then E here, with no closure. L and
  \\ K are the Prolog compiler's variables, which is and is! do not use.
  Scope [Is X Y B L K [freeze E]]
  -> (unified-now (if (= Is is) shen-jit.unify= shen-jit.unify=!)
                                 (norm Scope X) (norm Scope Y)
                                 (norm Scope B) (norm Scope E))
      where (and (element? Is [is is!]) (not (element? Is Scope)) (not (element? freeze Scope))
                 (shen-jit.sealed? Is) (pure? L Scope) (pure? K Scope))
  \\ (shen.bind! X Y B (freeze E)) thaws its closure once and at once, so E runs here.
  Scope [shen.bind! X Y B [freeze E]]
  -> (bound-now (norm Scope X) (norm Scope Y)
                               (norm Scope B) (norm Scope E))
      where (and (not (element? shen.bind! Scope)) (not (element? freeze Scope))
                 (shen-jit.sealed? shen.bind!))
  \\ ! then (when false), THORN's cut-fail: shen.cut's continuation fails, so
  \\ it locks L if L is unlocked and returns false, with no closure.
  Scope [shen.cut B L K [freeze [when false B2 L2 K2 C]]]
  -> (norm Scope [if [shen.unlocked? L] [shen.lock K L] false])
      where (and (empty? (intersection [shen.cut when freeze if] Scope))
                 (shen-jit.sealed? shen.cut) (shen-jit.sealed? when)
                 (empty? (difference [B L K B2 L2 K2 C] Scope)))
  \\ (= (shen.deref X B) (shen.deref Y B)), the Prolog compiler's (when (= X Y)),
  \\ compares without copying either term. Both dereference after Y is evaluated,
  \\ so Y must not change the bindings.
  Scope [= [shen.deref X B] [shen.deref Y B]]
  -> (norm Scope [shen-jit.deref= X Y B])
      where (and (not (element? = Scope)) (not (element? shen.deref Scope))
                 (shen-jit.sealed? shen.deref) (pure? B Scope)
                 (pure? Y Scope))
  \\ A constant test, as inline-loop leaves one: its branch.
  Scope [if true X _] -> (norm Scope X)
  Scope [if false _ Y] -> (norm Scope Y)
  Scope [if C X Y] -> [if (norm Scope C) (norm Scope X)
                          (norm Scope Y)]
  Scope [and X Y] -> [and (norm Scope X) (norm Scope Y)]
  Scope [or X Y] -> [or (norm Scope X) (norm Scope Y)]
  Scope [cond | Clauses] -> (norm-cond Scope Clauses)
  Scope [let X V Body] -> (let-lambda X (norm Scope V)
                                                    (norm [X | Scope] Body))
      where (shen-jit.symbol? X)
  Scope [lambda X Body] -> [lambda X (norm [X | Scope] Body)]
      where (shen-jit.symbol? X)
  Scope [freeze X] -> [freeze (norm Scope X)]
  Scope [do X Y] -> [do (norm Scope X) (norm Scope Y)]
  Scope [thaw X] -> [apply (norm Scope X)]
  Scope [type X _] -> (norm Scope X)
  Scope [trap-error X [lambda E H]] -> [trap (norm Scope X) E
                                             (norm [E | Scope] H)]
      where (and (shen-jit.symbol? E) (not (element? lambda Scope)))
  Scope [trap-error X H] -> (let E (shen-jit.lower.fresh shen-jit.lower.exception)
                              [trap (norm Scope X) E
                                    [apply (norm Scope H) [var E]]])
  _ [defun | X] -> (shen-jit.lower.fail "defun not at top level" [defun | X])
  \\ protect is the identity (sys.kl); backends treat (protect X) as X, as
  \\ the kernel's own CL backend does.
  Scope [protect X] -> (norm Scope X)
  \\ eval-kl runs the lowerer, which is guest code, so it is a sealed call to
  \\ the port's shen-jit.eval-kl rather than a C primitive.
  Scope [eval-kl X] -> [call shen-jit.eval-kl [(norm Scope X)]]
  \\ A raise's message is made only when the definition fails: only bodies of primitives
  \\ inline there (inline-at), so that code no correct run reaches stays small.
  Scope [simple-error X] -> (shen-jit.lower.prim simple-error [(cold Scope X)])
      where (not (element? simple-error Scope))
  Scope [F | Args] -> (norm-named Scope F Args)
  Scope X -> [var X] where (element? X Scope)
  \\ Values with no literal syntax (absvectors, closures, streams) can reach
  \\ eval-kl at runtime; like Shen/Scheme, treat them as constants.
  _ X -> [const X])

(define cold
  Scope X -> (let Was (value *cold*)
                  Cold (set *cold* true)
                  Normal (norm Scope X)
                  Back (set *cold* Was)
               Normal))

(define pure?
  X Scope -> (or (element? X Scope) (or (number? X) (= X []))))

\\ is and is! with their continuation in place.
(define unified-now
  Unify X Y B E -> (let Left (shen-jit.lower.fresh arg)
                        Right (shen-jit.lower.fresh arg)
                        Bindings (shen-jit.lower.fresh arg)
                        Trail (shen-jit.lower.fresh arg)
                        Result (shen-jit.lower.fresh arg)
                        Scope [Left Right Bindings Trail Result]
                     [let Left X
                       [let Right Y
                         [let Bindings B
                           [let Trail (norm Scope [Unify [shen.lazyderef Left Bindings]
                                                                        [shen.lazyderef Right Bindings]
                                                                        Bindings []])
                             [if (norm Scope [= Trail false])
                                 [const false]
                                 [let Result E
                                   [if (norm Scope [= Result false])
                                       (norm Scope [shen-jit.undo Trail Bindings])
                                       [var Result]]]]]]]]))

\\ shen.bind! with its continuation in place: E, normalised, where the kernel's
\\ thaws the closure.
(define bound-now
  X Y B E -> (let Var (shen-jit.lower.fresh arg)
                  Value (shen-jit.lower.fresh arg)
                  Bindings (shen-jit.lower.fresh arg)
                  Result (shen-jit.lower.fresh arg)
                  Scope [Var Value Bindings Result]
               [let Var X
                 [let Value Y
                   [let Bindings B
                     [do (norm Scope [shen.bindv Var Value Bindings])
                         [let Result E
                           [if (norm Scope [= Result false])
                               (norm Scope [shen.unwind Var Bindings Result])
                               [var Result]]]]]]]))

\\ (let G (freeze E) Body), where Body uses G only in (thaw G) and as the last
\\ argument of shen.bind!, as the Prolog compiler's atom patterns do: a closure
\\ made before the test, whichever way it goes. Each use takes a copy of E, in
\\ normalised code and so from the inside out, or nested patterns would double the
\\ code at every level. The limit is low: at 1500 nodes, as for lambdas, compiling
\\ cost more than it gained.
(define let-frozen
  X E Body -> (let Uses (frozen-uses X Body)
                (if (and (> Uses 0)
                         (frozen-binds? X Body)
                         (<= (* (- Uses 1) (size E)) 100)
                         (empty? (intersection (free E) (binders Body))))
                    (frozen-in X E Body)
                    (frozen-late X E Body))))

\\ Too large to copy, but the closure can still wait for the tests that use it:
\\ a clause whose atom differs makes none.
(define frozen-late
  X E [if C1 Y1 [if C2 Y2 [const false]]]
  -> [if [or C1 C2] [let X [freeze E] [if C1 Y1 Y2]] [const false]]
      where (and (simple-test? C1) (simple-test? C2)
                 (not (shen-jit.lower.occurs? X C1)) (not (shen-jit.lower.occurs? X C2)))
  X E Body -> [let X [freeze E] Body])

\\ A test that can be made twice: no calls, and no primitive but these.
(define simple-test?
  [const _] -> true
  [var _] -> true
  [prim P Args] -> (and (element? P [= shen-jit.pvar? cons?]) (simple-tests? Args))
  [let _ V X] -> (and (simple-test? V) (simple-test? X))
  _ -> false)

(define simple-tests?
  [] -> true
  [X | Xs] -> (and (simple-test? X) (simple-tests? Xs)))

(define frozen-binds?
  X [call shen.bind! [_ _ _ [var X]]] -> true
  _ [const _] -> false
  X [Y | Ys] -> (element? true (map (/. Z (frozen-binds? X Z)) [Y | Ys]))
  _ _ -> false)

(define frozen-uses
  X [apply [var X]] -> 1
  X [call shen.bind! [A B C [var X]]] -> (let N (frozen-uses X [A B C])
                                           (if (< N 0) N (+ N 1)))
  X [var X] -> -1000000
  _ [const _] -> 0
  X Y -> -1000000 where (binds? X Y)
  X [Y | Ys] -> (counts (map (/. Z (frozen-uses X Z)) [Y | Ys]))
  _ _ -> 0)

(define frozen-in
  X E [apply [var X]] -> E
  X E [call shen.bind! [A B C [var X]]] -> (bound-now A B C E)
  _ _ [const C] -> [const C]
  X E [Y | Ys] -> (map (/. Z (frozen-in X E Z)) [Y | Ys])
  _ _ Y -> Y)

\\ (let X (lambda P1 ... (lambda Pn Inner)) Body), where Body uses X only
\\ applied to n arguments, as the Prolog compiler's head patterns do: each
\\ use becomes (let P1 A1 ... (let Pn An Inner)) and the let goes, so no
\\ closure is made and no call is dynamic. The arguments are evaluated in
\\ the same order, and then Inner with the same values, provided Body binds
\\ no free variable of the lambda and does not use its parameters. Every use
\\ but one copies the lambda, and the copies may add 1500 nodes of
\\ normalised code at most, inlined calls included; normalisation works
\\ from the inside out, so an outer lambda is measured with its inner ones
\\ already copied. Nested head patterns would otherwise double the code at
\\ every level.
(define let-lambda
  X [freeze E] Body -> (let-frozen X E Body)
  X V Body -> (if (and (cons? (lambda-params V)) (lambda-in? X V Body []))
                  (apply-in X (lambda-params V) (lambda-body V) Body)
                  [let X V Body]))

(define free
  [var X] -> [X]
  [const _] -> []
  [let X V Body] -> (union (free V) (remove X (free Body)))
  [lambda X Body] -> (remove X (free Body))
  [trap X E H] -> (union (free X) (remove E (free H)))
  [X | Xs] -> (union-all (map (/. Y (free Y)) [X | Xs]))
  _ -> [])

(define lambda-params
  [lambda P Body] -> [P | (lambda-params Body)]
  _ -> [])

(define lambda-body
  [lambda _ Body] -> (lambda-body Body)
  X -> X)

\\ A dynamic application as [F A1 ... An]: ((F A1) ... An), or Y itself.
(define chain
  [apply F A] Args -> (chain F [A | Args])
  Y Args -> [Y | Args])

\\ The number of applications of X to N arguments in Y, or -1 if Y uses X in
\\ any other way or binds it again.
(define applies
  X N Y -> (let Chain (chain Y [])
             (cond ((and (= (hd Chain) [var X]) (= (length (tl Chain)) N))
                    (applies-all X N (tl Chain) 1))
                   ((= Y [var X]) -1)
                   ((binds? X Y) -1)
                   ((and (cons? Y) (not (= (hd Y) const))) (applies-all X N Y 0))
                   (true 0))))

(define applies-all
  _ _ [] Count -> Count
  X N [Y | Ys] Count -> (let M (applies X N Y)
                          (if (< M 0) -1 (applies-all X N Ys (+ Count M))))
  _ _ _ Count -> Count)

(define binds?
  X [let X _ _] -> true
  X [lambda X _] -> true
  X [trap _ X _] -> true
  _ _ -> false)

(define apply-in
  X Params Inner Y
  -> (let Chain (chain Y [])
       (if (and (= (hd Chain) [var X]) (= (length (tl Chain)) (length Params)))
           (lets Params
                                  (map (/. A (apply-in X Params Inner A)) (tl Chain))
                                  Inner)
           (apply-in-all X Params Inner Y))))

(define apply-in-all
  _ _ _ [const C] -> [const C]
  X Params Inner [Y | Ys] -> (map (/. Z (apply-in X Params Inner Z)) [Y | Ys])
  _ _ _ Y -> Y)

(define literal?
  X -> (or (shen-jit.symbol? X) (number? X) (string? X) (boolean? X) (empty? X)))

(define fn-call
  F Args -> (let Vars (map (/. A (shen-jit.lower.fresh arg)) Args)
                 G (shen-jit.lower.fresh arg)
              (lets Vars Args
                                     [if [shen-jit.arity? F (length Args)]
                                         [F | Vars]
                                         [let G [fn F] [G | Vars]]])))

(define norm-list
  _ [] -> []
  Scope [X | Xs] -> [(norm Scope X) | (norm-list Scope Xs)]
  _ X -> (shen-jit.lower.fail "improper argument list" X))

\\ Dynamic calls apply one argument at a time: (F A B) is ((F A) B).
(define norm-apply
  F [] -> [apply F]
  F [X] -> [apply F X]
  F [X | Xs] -> (norm-apply [apply F X] Xs))

(define norm-named
  Scope F Args
  -> (cond ((= (length Args) (prim-arity F))
            (shen-jit.lower.prim F (norm-list Scope Args)))
           ((fixed? F)
            (shen-jit.lower.fail (malformed F) [F | Args]))
           ((field? F Args)
            [prim (field-read F) [(norm Scope (hd Args))
                                  [const (definition-property F shen-jit.struct.field [])]]])
           (true (shen-jit.lower.call F (norm-list Scope Args)))))

\\ A call of a struct's reader in typechecked code, where the value is that struct: its field is read
\\ with no check (docs/bytecode.md). Code is typechecked in a definition the annotator went through,
\\ and in the inlined bodies there of definitions it went through. The reader must be sealed, so that
\\ it is still that reader.
(define field?
  F [_] -> (and (value *typed*) (shen-jit.sealed? F)
                (number? (definition-property F shen-jit.struct.field [])))
  _ _ -> false)

\\ The read of F's field: shen-jit.field, or, where the struct gives the field the type fixnum or float,
\\ shen-jit.field-word or shen-jit.field-float, which register code takes into a register of that kind,
\\ checked as any read from a slot is, and which is shen-jit.field everywhere else.
(define field-read
  F -> (let Kind (definition-property F shen-jit.struct.field-kind 0)
         (cond ((= Kind 1) shen-jit.field-word)
               ((= Kind 2) shen-jit.field-float)
               (true shen-jit.field))))

(define annotated?
  F -> (definition-property F shen-jit.annotated false))

\\ Optimization properties are [InstalledProcedure | Claim]. Sealing a replacement says nothing
\\ about the old definition; procedure identity also handles replacements installed through KL.
(define definition-property
  F Key Default -> (trap-error (let Entry (get F Key)
                                (if (and (cons? Entry) (shen-jit.same? (hd Entry) (shen-jit.function F)))
                                    (tl Entry)
                                    Default))
                              (/. E Default)))

\\ A cons of two constants whose tail is a proper list is itself a constant,
\\ made here once: a list literal such as [a b c] then costs nothing to
\\ evaluate. Pairs are immutable and = compares structure, so a fresh list
\\ and a shared one cannot be told apart.
(define shen-jit.lower.prim
  cons [[const A] [const B]] -> [const (cons A B)]
      where (and (proper? B) (< (size [A | B]) 64))
  shen-jit.float [[const A]] -> [const (shen-jit.float A)] where (number? A)
  + [[const A] [const B]] -> [const (+ A B)] where (small-integers? A B)
  - [[const A] [const B]] -> [const (- A B)] where (small-integers? A B)
  * [[const A] [const B]] -> [const (* A B)] where (small-integers? A B)
  F Args -> [prim F Args])

\\ Integers whose sum, difference or product is an integer in every implementation.
(define small-integers?
  A B -> (and (integer? A) (integer? B)
              (< (shen-jit.lower.abs A) 1000000000) (< (shen-jit.lower.abs B) 1000000000)))

(define shen-jit.lower.abs
  X -> (if (< X 0) (- 0 X) X))

(define proper?
  [] -> true
  [_ | Xs] -> (proper? Xs)
  _ -> false)

(define malformed
  lambda -> "lambda needs one symbol parameter and a body"
  let -> "let needs a symbol, a value and a body"
  F -> (cn "wrong number of arguments to primitive " (str F))
      where (>= (prim-arity F) 0)
  F -> (cn "malformed " (str F)))

\\ A clause whose test is the literal true ends the chain.
(define norm-cond
  _ [] -> [prim raise-cond []]
  Scope [[true X] | _] -> (norm Scope X)
  Scope [[C X] | Clauses] -> [if (norm Scope C) (norm Scope X)
                                 (norm-cond Scope Clauses)]
  _ [Clause | _] -> (shen-jit.lower.fail "malformed cond clause" Clause)
  _ X -> (shen-jit.lower.fail "malformed cond" X))

\\ Whether every closure in X is one the Prolog compiler makes, which the query
\\ does not outlive: a lambda only as a goal for findall or call, four
\\ parameters applied as the last arguments of a call; a freeze only as a
\\ continuation, the last argument of a call after the query's own B, L and K,
\\ in Vars.
(define only-goals?
  [lambda B [lambda L [lambda K [lambda C [F | Args]]]]] _
  -> (and (shen-jit.symbol? F) (not (shen-jit.lower.occurs? lambda Args))
          (ends-with? [B L K C] Args))
  [lambda | _] _ -> false
  [freeze _] _ -> false
  [F | Args] Vars -> (goal-args? (reverse Args) Vars) where (shen-jit.symbol? F)
  [X | Xs] Vars -> (all-goals? [X | Xs] Vars)
  _ _ -> true)

\\ A call's arguments, the last first.
(define goal-args?
  [[freeze E] K L B | Xs] [B L K] -> (and (only-goals? E [B L K])
                                          (all-goals? Xs [B L K]))
  Xs Vars -> (all-goals? Xs Vars))

(define all-goals?
  [X | Xs] Vars -> (and (only-goals? X Vars) (all-goals? Xs Vars))
  _ _ -> true)

(define ends-with?
  Ys Xs -> (= Ys Xs) where (= (length Ys) (length Xs))
  Ys [_ | Xs] -> (ends-with? Ys Xs)
  _ _ -> false))

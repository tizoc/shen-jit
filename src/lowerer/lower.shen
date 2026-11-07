\\ shen-jit KLambda lowerer.
\\
\\ Turns KLambda into the symbolic code objects defined in docs/bytecode.md:
\\
\\   (code Name Arity FrameSize Constants Instructions Codes [Inline])
\\
\\ Two passes. Normalization validates the form, resolves each symbol to a
\\ lexical variable or a constant, and removes sugar (cond, type, thaw, the
\\ trap-error handler shapes, curried dynamic calls). Emission tracks tail
\\ positions, converts closures, assigns slots and call windows, and emits
\\ instructions.
\\
\\ Entry points; Sealed is the list of names defined in the stage 0 input:
\\
\\   (shen-jit.lower.defun [defun F Params Body] Sealed) -> [defun F Code]
\\   (shen-jit.lower.expression X Sealed) -> Code, of arity 0
\\   (shen-jit.lower.toplevel X Sealed) -> whichever of the two X needs
\\
\\ Errors in the input raise "shen-jit lowerer: ..." with the culprit.

(define shen-jit.lower.toplevel
  [defun | Rest] Sealed -> (shen-jit.lower.defun [defun | Rest] Sealed)
  X Sealed -> (shen-jit.lower.expression X Sealed))

(define shen-jit.lower.defun
  [defun F Params Body] Sealed
  -> (do (shen-jit.lower.check-defun F Params Sealed)
         (set shen-jit.lower.*inline-depth* 0)
         (set shen-jit.lower.*fresh* 0)
         [defun F (append (shen-jit.lower.code F Params
                                                 (shen-jit.lower.norm Params (shen-jit.lower.share Body))
                                                 Sealed)
                          [(shen-jit.lower.inline-form F Params Body)])])
  X _ -> (shen-jit.lower.fail "malformed defun" X))

\\ A body that tests a chain of conditions binding parts of the argument as
\\ it goes, as factorised pattern matching does: the chain becomes nested ifs
\\ whose failures jump to the else branch (a frozen else in tail position is
\\ a label), so that the then branch, inside those bindings, uses them where
\\ it would take the same parts again with hd and tl.
(define shen-jit.lower.share
  [if C X Y] -> (let Spine (shen-jit.lower.spine C [])
                     Then (if (empty? Spine) X (shen-jit.lower.reuse X Spine []))
                  (if (= Then X)
                      [if C (shen-jit.lower.share X) (shen-jit.lower.share Y)]
                      (let G (shen-jit.lower.fresh shen-jit.lower.else)
                        [let G [freeze (shen-jit.lower.share Y)]
                             (shen-jit.lower.unchain C (shen-jit.lower.share Then) G)])))
  [let X V Body] -> [let X V (shen-jit.lower.share Body)]
  [do X Y] -> [do X (shen-jit.lower.share Y)]
  X -> X)

\\ The variables bound along the chain, each with what it holds in terms of
\\ the variables outside it; none if a name is bound twice.
(define shen-jit.lower.spine
  [and _ S] Bs -> (shen-jit.lower.spine S Bs)
  [let X E S] Bs -> (if (or (not (symbol? X)) (shen-jit.lower.occurs? X Bs))
                        []
                        (shen-jit.lower.spine S [[X | (shen-jit.lower.canon E Bs)] | Bs]))
  _ Bs -> Bs)

(define shen-jit.lower.canon
  [Op A] Bs -> [Op (shen-jit.lower.canon A Bs)] where (element? Op [hd tl])
  X Bs -> (let B (assoc X Bs) (if (cons? B) (tl B) X)) where (symbol? X)
  X _ -> X)

(define shen-jit.lower.occurs?
  X X -> true
  X [Y | Ys] -> (or (shen-jit.lower.occurs? X Y) (shen-jit.lower.occurs? X Ys))
  _ _ -> false)

\\ X with each hd or tl that the chain bound replaced by its variable. Ls are
\\ X's own lets on the way; one that binds a name the chain uses ends it.
(define shen-jit.lower.reuse
  [Op A] Bs Ls -> (let V (shen-jit.lower.bound (shen-jit.lower.canon [Op A] (append Ls Bs)) Bs)
                    (if (symbol? V) V [Op (shen-jit.lower.reuse A Bs Ls)]))
      where (element? Op [hd tl])
  [let X E Body] Bs Ls
  -> (let E2 (shen-jit.lower.reuse E Bs Ls)
       (if (or (shen-jit.lower.occurs? X Bs) (shen-jit.lower.occurs? X Ls))
           [let X E2 Body]
           [let X E2 (shen-jit.lower.reuse Body Bs [[X | (shen-jit.lower.canon E2 (append Ls Bs))] | Ls])]))
  [lambda X Body] Bs Ls -> [lambda X Body] where (or (shen-jit.lower.occurs? X Bs) (shen-jit.lower.occurs? X Ls))
  [X | Xs] Bs Ls -> (map (/. Y (shen-jit.lower.reuse Y Bs Ls)) [X | Xs])
  X _ _ -> X)

(define shen-jit.lower.bound
  C [[X | C] | _] -> X
  C [_ | Bs] -> (shen-jit.lower.bound C Bs)
  _ _ -> [])

(define shen-jit.lower.unchain
  [and T S] Then G -> [if T (shen-jit.lower.unchain S Then G) [thaw G]]
  [let X E S] Then G -> [let X E (shen-jit.lower.unchain S Then G)]
  T Then G -> [if T Then [thaw G]])

(define shen-jit.lower.expression
  X Sealed -> (do (set shen-jit.lower.*inline-depth* 0)
                  (set shen-jit.lower.*fresh* 0)
                  (shen-jit.lower.code eval-kl [] (shen-jit.lower.norm [] X) Sealed)))

\\ A variable of the lowerer's own, fresh within the definition being lowered.
\\ The count restarts with each definition, so the same few names come back:
\\ gensym would intern a new symbol every time.
(define shen-jit.lower.fresh
  Prefix -> (let N (+ (value shen-jit.lower.*fresh*) 1)
                 Count (set shen-jit.lower.*fresh* N)
              (concat Prefix N)))

\\ ---------------------------------------------------------------------------
\\ Inlining. A defun's code
\\ carries (Params Body) when the body is small, has no handlers, calls
\\ nothing named F, and has no real literals (stage 0 and shen-jit may
\\ read their last bits differently); otherwise []. A call to a sealed F
\\ with as many arguments as F's parameters becomes the body, two levels
\\ deep at most. A closure in the body becomes one of the caller's.

(define shen-jit.lower.inline-form
  F Params Body -> [Params Body] where (and (shen-jit.lower.inlinable? F Body)
                                            (<= (shen-jit.lower.size Body) 15))
  _ _ _ -> [])

(define shen-jit.lower.inlinable?
  F [F | _] -> false
  _ [Head | _] -> false where (element? Head [trap-error defun eval-kl])
  F [X | Xs] -> (and (shen-jit.lower.inlinable? F X) (shen-jit.lower.inlinable? F Xs))
  _ X -> (not (and (number? X) (not (integer? X)))))

(define shen-jit.lower.size
  [X | Xs] -> (+ (shen-jit.lower.size X) (shen-jit.lower.size Xs))
  _ -> 1)

(define shen-jit.lower.call
  F Args -> (let Inline (shen-jit.lower.inline-body F (length Args))
              (if (empty? Inline)
                  (shen-jit.lower.open-call F (shen-jit.lower.open-body F (length Args)) Args)
                  (shen-jit.lower.inline F (hd Inline) (hd (tl Inline)) Args))))

\\ A call to an open function with a small body inlines it too, behind a
\\ test that the name's definition is still the one with that very body
\\ (shen-jit.inlined?), which compiled code makes a nop until the name is
\\ redefined; the arguments go to fresh variables first, for either branch.
(define shen-jit.lower.open-call
  F [] Args -> [call F Args]
  F Inline Args -> (let Vars (map (/. A (shen-jit.lower.fresh shen-jit.lower.arg)) Args)
                        Refs (map (/. V [var V]) Vars)
                     (shen-jit.lower.lets Vars Args
                                            [if [prim shen-jit.inlined? [[const F] [const Inline]]]
                                                (shen-jit.lower.inline F (hd Inline) (hd (tl Inline)) Refs)
                                                [call F Refs]])))

(define shen-jit.lower.open-body
  F N -> (let Depth (trap-error (value shen-jit.lower.*inline-depth*) (/. E 0))
              Inline (if (and (< Depth 2) (not (shen-jit.sealed? F))) (shen-jit.inline-body F) [])
           (if (and (cons? Inline) (= (length (hd Inline)) N)) Inline [])))

(define shen-jit.lower.inline-body
  F N -> (let Depth (trap-error (value shen-jit.lower.*inline-depth*) (/. E 0))
              Inline (if (and (< Depth 2) (shen-jit.sealed? F)) (shen-jit.inline-body F) [])
           (if (and (cons? Inline) (= (length (hd Inline)) N)) Inline [])))

\\ The arguments go to fresh variables first, so binding the parameters cannot
\\ capture a variable an argument uses; the body is normalized in its own
\\ scope, so it cannot capture the caller's variables either.
(define shen-jit.lower.inline
  F Params Body Args -> (shen-jit.lower.inline-numbers F Params Body Args [] []))

\\ An integer argument goes into the body itself, so that what the body
\\ computes from it can fold: (vector 1) allocates a constant length.
(define shen-jit.lower.inline-numbers
  F [P | Ps] Body [[const N] | As] Qs Bs
  -> (shen-jit.lower.inline-numbers F Ps (shen-jit.lower.subst P N Body) As Qs Bs)
      where (integer? N)
  F [P | Ps] Body [A | As] Qs Bs -> (shen-jit.lower.inline-numbers F Ps Body As [P | Qs] [A | Bs])
  F _ Body _ Qs Bs -> (shen-jit.lower.inline-args F (reverse Qs) Body (reverse Bs)))

(define shen-jit.lower.subst
  X V X -> V
  X V [let X Y Body] -> [let X (shen-jit.lower.subst X V Y) Body]
  X V [lambda X Body] -> [lambda X Body]
  X V [Y | Ys] -> (map (/. Z (shen-jit.lower.subst X V Z)) [Y | Ys])
  _ _ Y -> Y)

(define shen-jit.lower.inline-args
  F Params Body Args
  -> (let Depth (value shen-jit.lower.*inline-depth*)
          Deeper (set shen-jit.lower.*inline-depth* (+ Depth 1))
          Normal (shen-jit.lower.norm Params Body)
          Back (set shen-jit.lower.*inline-depth* Depth)
       (shen-jit.lower.inline-frozen F Params Args Normal [] [])))

\\ An argument (freeze E) of a parameter the inlined body only thaws, once: E runs
\\ there and no closure is made, given that no name E uses is bound on the way.
(define shen-jit.lower.inline-frozen
  F [P | Ps] [[freeze E] | As] Normal Qs Bs
  -> (shen-jit.lower.inline-frozen F Ps As (shen-jit.lower.thaw-with P E Normal) Qs Bs)
      where (and (= (shen-jit.lower.thaws-once P Normal) 1)
                 (empty? (intersection (shen-jit.lower.free E)
                                       (union [P | (append Ps Qs)] (shen-jit.lower.binders Normal)))))
  F [P | Ps] [A | As] Normal Qs Bs -> (shen-jit.lower.inline-frozen F Ps As Normal [P | Qs] [A | Bs])
  F _ _ Normal Qs Bs
  -> (let Params (reverse Qs)
          Args (reverse Bs)
          Fresh (map (/. P (shen-jit.lower.fresh shen-jit.lower.arg)) Params)
       (shen-jit.lower.lets Fresh Args
                              (shen-jit.lower.lets Params (map (/. X [var X]) Fresh)
                                                     [let shen-jit.lower.inlining [const F] Normal]))))

(define shen-jit.lower.thaws-once
  X [apply [var X]] -> 1
  X [var X] -> -1000000
  _ [const _] -> 0
  X [Y | Ys] -> (let M (shen-jit.lower.thaws-once X Y)
                     N (shen-jit.lower.thaws-once X Ys)
                  (if (or (< M 0) (< N 0)) -1000000 (+ M N)))
  _ _ -> 0)

(define shen-jit.lower.thaw-with
  X E [apply [var X]] -> E
  _ _ [const C] -> [const C]
  X E [Y | Ys] -> [(shen-jit.lower.thaw-with X E Y) | (shen-jit.lower.thaw-with X E Ys)]
  _ _ Y -> Y)

(define shen-jit.lower.lets
  [X | Xs] [V | Vs] Body -> [let X V (shen-jit.lower.lets Xs Vs Body)]
  _ _ Body -> Body)

(define shen-jit.lower.fail
  Message X -> (simple-error (make-string "shen-jit lowerer: ~A: ~R" Message X)))

\\ ---------------------------------------------------------------------------
\\ Fixed names

(define shen-jit.lower.prim-arity
  F -> 0 where (element? F [shen-jit.quiet? shen-jit.mark-toplevel shen-jit.backtrace shen-jit.errno shen-jit.c-errno
                            shen-jit.pointers-dead shen-jit.collect])
  F -> 1 where (element? F [number? hd tl cons? tlstr str string? n->string string->n
                            intern absvector absvector? value simple-error error-to-string
                            get-time close read-byte char-stream? read-unit-string
                            shen-jit.install shen-jit.symbol? shen-jit.exit
                            shen-jit.symbol-kind shen-jit.dict-entries
                            shen-jit.sealed? shen-jit.sealing shen-jit.inline-body
                            shen-jit.vector? shen-jit.trace-text shen-jit.integer?
                            shen-jit.bytes shen-jit.bytes? shen-jit.bytes-length shen-jit.string->bytes
                            shen-jit.bit-not shen-jit.bswap32 shen-jit.popcount shen-jit.clz shen-jit.ctz
                            shen-jit.pvar shen-jit.pvar? shen-jit.pvar-offset shen-jit.thread
                            shen-jit.pointer? shen-jit.pointer-kind shen-jit.pointer-address
                            shen-jit.pointer->string shen-jit.pointer-kill shen-jit.pointer-owner
                            shen-jit.pointer-read-only])
  F -> 2 where (element? F [+ - * / < > <= >= = cons cn pos <-address set open write-byte
                            write-string shen-jit.hash shen-jit.filled-vector
                            shen-jit.save-executable shen-jit.foreign
                            shen-jit.dict-find shen-jit.dict-remove shen-jit.tagged? shen-jit.same?
                            shen-jit.read-file shen-jit.append shen-jit.arity?
                            shen-jit.inlined? shen-jit.u8 shen-jit.u16 shen-jit.u32
                            shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor
                            shen-jit.shift-left shen-jit.shift-right shen-jit.rotate32
                            shen-jit.decimal shen-jit.s32 shen-jit.s64 shen-jit.f32 shen-jit.f64
                            shen-jit.pointer-sized shen-jit.pointer-guard])
  F -> 3 where (element? F [address-> shen-jit.dict-put shen-jit.absvector3 shen-jit.deref
                            shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.bytes->string
                            shen-jit.bytes->pointer shen-jit.pointer->bytes
                            shen-jit.s32! shen-jit.s64! shen-jit.f32! shen-jit.f64! shen-jit.pointer!])
  shen-jit.copy-bytes -> 5
  _ -> -1)

(define shen-jit.lower.special?
  F -> (element? F [if and or cond let lambda defun freeze type trap-error do thaw]))

(define shen-jit.lower.fixed?
  F -> (or (shen-jit.lower.special? F) (>= (shen-jit.lower.prim-arity F) 0)
           (element? F [eval-kl protect])))

\\ The kernel itself defines do and thaw, so stage 0 (where they are sealed)
\\ lowers those definitions; any other defun of a fixed name is an error.
(define shen-jit.lower.check-defun
  F Params Sealed
  -> (cond ((not (shen-jit.symbol? F)) (shen-jit.lower.fail "defun name is not a symbol" F))
           ((and (shen-jit.lower.fixed? F)
                 (not (and (element? F [do thaw protect]) (element? F Sealed))))
            (shen-jit.lower.fail "defun of a fixed name" F))
           (true (shen-jit.lower.check-params F Params))))

(define shen-jit.lower.check-params
  _ [] -> true
  F [P | _] -> (shen-jit.lower.fail "non-symbol defun parameter" [F P]) where (not (shen-jit.symbol? P))
  F [P | Ps] -> (shen-jit.lower.fail "duplicate defun parameter" [F P]) where (element? P Ps)
  F [_ | Ps] -> (shen-jit.lower.check-params F Ps)
  F Ps -> (shen-jit.lower.fail "defun parameters are not a list" [F Ps]))

\\ ---------------------------------------------------------------------------
\\ Normalization. Scope is the list of lexically bound symbols. The result
\\ uses these nodes:
\\
\\   [const V] [var X] [if C X Y] [and X Y] [or X Y] [let X V Body] [do X Y]
\\   [lambda X Body] [freeze Body] [prim Op Args] [call F Args]
\\   [apply F] [apply F X] [trap X E Handler]

(define shen-jit.lower.norm
  \\ ((fn F) X1 ... Xn) for a sealed F of arity n >= 1 is (F X1 ... Xn): F's
  \\ lambda form applies F to its n arguments, and F cannot be redefined.
  Scope [[fn F] | Args] -> [call F (shen-jit.lower.norm-list Scope Args)]
      where (and (shen-jit.symbol? F) (not (element? fn Scope)) (not (element? F Scope))
                 (cons? Args) (shen-jit.sealed? F) (= (arity F) (length Args)))
  \\ For an open F, it is how the kernel calls a function it did not know
  \\ when compiling: one defined later, or in another package. A named call
  \\ when F takes n arguments, tested each time; otherwise the lambda form,
  \\ which also curries and raises "fn: F is undefined". The arguments are
  \\ evaluated before fn, which only shows when F is undefined.
  Scope [[fn F] | Args] -> (shen-jit.lower.norm Scope (shen-jit.lower.fn-call F Args))
      where (and (shen-jit.symbol? F) (cons? Args) (not (shen-jit.sealed? F))
                 (not (shen-jit.lower.fixed? F))
                 (empty? (intersection [fn F let if shen-jit.arity?] Scope)))
  \\ ((lambda X Body) A) is (let X A Body): A is evaluated, then Body with X
  \\ bound to it, and no closure is made. The kernel's compiler wraps calls
  \\ to other packages' functions this way. Further arguments apply to the
  \\ result, as for any dynamic call.
  Scope [[lambda X Body] A | More] -> (shen-jit.lower.norm Scope [[let X A Body] | More])
      where (and (shen-jit.symbol? X) (not (element? lambda Scope)) (not (element? let Scope))
                 (cons? More))
  Scope [[lambda X Body] A] -> [let X (shen-jit.lower.norm Scope A) (shen-jit.lower.norm [X | Scope] Body)]
      where (and (shen-jit.symbol? X) (not (element? lambda Scope)))
  Scope [F | Args] -> (shen-jit.lower.norm-apply (shen-jit.lower.norm Scope F)
                                                   (shen-jit.lower.norm-list Scope Args))
      where (or (element? F Scope) (not (shen-jit.symbol? F)))
  \\ (is X Y B L K (freeze E)) and is!: unify first, then E here, with no closure. L and
  \\ K are the Prolog compiler's variables, which is and is! do not use.
  Scope [Is X Y B L K [freeze E]]
  -> (shen-jit.lower.unified-now (if (= Is is) shen-jit.unify= shen-jit.unify=!)
                                 (shen-jit.lower.norm Scope X) (shen-jit.lower.norm Scope Y)
                                 (shen-jit.lower.norm Scope B) (shen-jit.lower.norm Scope E))
      where (and (element? Is [is is!]) (not (element? Is Scope)) (not (element? freeze Scope))
                 (shen-jit.sealed? Is) (shen-jit.lower.pure? L Scope) (shen-jit.lower.pure? K Scope))
  \\ (shen.bind! X Y B (freeze E)) thaws its closure once and at once, so E runs here.
  Scope [shen.bind! X Y B [freeze E]]
  -> (shen-jit.lower.bound-now (shen-jit.lower.norm Scope X) (shen-jit.lower.norm Scope Y)
                               (shen-jit.lower.norm Scope B) (shen-jit.lower.norm Scope E))
      where (and (not (element? shen.bind! Scope)) (not (element? freeze Scope))
                 (shen-jit.sealed? shen.bind!))
  Scope [if C X Y] -> [if (shen-jit.lower.norm Scope C) (shen-jit.lower.norm Scope X)
                          (shen-jit.lower.norm Scope Y)]
  Scope [and X Y] -> [and (shen-jit.lower.norm Scope X) (shen-jit.lower.norm Scope Y)]
  Scope [or X Y] -> [or (shen-jit.lower.norm Scope X) (shen-jit.lower.norm Scope Y)]
  Scope [cond | Clauses] -> (shen-jit.lower.norm-cond Scope Clauses)
  Scope [let X V Body] -> (shen-jit.lower.let-lambda X (shen-jit.lower.norm Scope V)
                                                    (shen-jit.lower.norm [X | Scope] Body))
      where (shen-jit.symbol? X)
  Scope [lambda X Body] -> [lambda X (shen-jit.lower.norm [X | Scope] Body)]
      where (shen-jit.symbol? X)
  Scope [freeze X] -> [freeze (shen-jit.lower.norm Scope X)]
  Scope [do X Y] -> [do (shen-jit.lower.norm Scope X) (shen-jit.lower.norm Scope Y)]
  Scope [thaw X] -> [apply (shen-jit.lower.norm Scope X)]
  Scope [type X _] -> (shen-jit.lower.norm Scope X)
  Scope [trap-error X [lambda E H]] -> [trap (shen-jit.lower.norm Scope X) E
                                             (shen-jit.lower.norm [E | Scope] H)]
      where (and (shen-jit.symbol? E) (not (element? lambda Scope)))
  Scope [trap-error X H] -> (let E (shen-jit.lower.fresh shen-jit.lower.exception)
                              [trap (shen-jit.lower.norm Scope X) E
                                    [apply (shen-jit.lower.norm Scope H) [var E]]])
  _ [defun | X] -> (shen-jit.lower.fail "defun not at top level" [defun | X])
  \\ protect is the identity (sys.kl); backends treat (protect X) as X, as
  \\ the kernel's own CL backend does.
  Scope [protect X] -> (shen-jit.lower.norm Scope X)
  \\ eval-kl runs the lowerer, which is guest code, so it is a sealed call to
  \\ the port's shen-jit.eval-kl rather than a C primitive.
  Scope [eval-kl X] -> [call shen-jit.eval-kl [(shen-jit.lower.norm Scope X)]]
  Scope [F | Args] -> (shen-jit.lower.norm-named Scope F Args)
  Scope X -> [var X] where (element? X Scope)
  \\ Values with no literal syntax (absvectors, closures, streams) can reach
  \\ eval-kl at runtime; like Shen/Scheme, treat them as constants.
  _ X -> [const X])

(define shen-jit.lower.pure?
  X Scope -> (or (element? X Scope) (or (number? X) (= X []))))

\\ is and is! with their continuation in place.
(define shen-jit.lower.unified-now
  Unify X Y B E -> (let Left (shen-jit.lower.fresh shen-jit.lower.arg)
                        Right (shen-jit.lower.fresh shen-jit.lower.arg)
                        Bindings (shen-jit.lower.fresh shen-jit.lower.arg)
                        Trail (shen-jit.lower.fresh shen-jit.lower.arg)
                        Result (shen-jit.lower.fresh shen-jit.lower.arg)
                        Scope [Left Right Bindings Trail Result]
                     [let Left X
                       [let Right Y
                         [let Bindings B
                           [let Trail (shen-jit.lower.norm Scope [Unify [shen.lazyderef Left Bindings]
                                                                        [shen.lazyderef Right Bindings]
                                                                        Bindings []])
                             [if (shen-jit.lower.norm Scope [= Trail false])
                                 [const false]
                                 [let Result E
                                   [if (shen-jit.lower.norm Scope [= Result false])
                                       (shen-jit.lower.norm Scope [shen-jit.undo Trail Bindings])
                                       [var Result]]]]]]]]))

\\ shen.bind! with its continuation in place: E, normalised, where the kernel's
\\ thaws the closure.
(define shen-jit.lower.bound-now
  X Y B E -> (let Var (shen-jit.lower.fresh shen-jit.lower.arg)
                  Value (shen-jit.lower.fresh shen-jit.lower.arg)
                  Bindings (shen-jit.lower.fresh shen-jit.lower.arg)
                  Result (shen-jit.lower.fresh shen-jit.lower.arg)
                  Scope [Var Value Bindings Result]
               [let Var X
                 [let Value Y
                   [let Bindings B
                     [do (shen-jit.lower.norm Scope [shen.bindv Var Value Bindings])
                         [let Result E
                           [if (shen-jit.lower.norm Scope [= Result false])
                               (shen-jit.lower.norm Scope [shen.unwind Var Bindings Result])
                               [var Result]]]]]]]))

\\ (let G (freeze E) Body), where Body uses G only in (thaw G) and as the last
\\ argument of shen.bind!, as the Prolog compiler's atom patterns do: a closure
\\ made before the test, whichever way it goes. Each use takes a copy of E, in
\\ normalised code and so from the inside out, or nested patterns would double the
\\ code at every level. The limit is low: at 1500 nodes, as for lambdas, compiling
\\ cost more than it gained.
(define shen-jit.lower.let-frozen
  X E Body -> (let Uses (shen-jit.lower.frozen-uses X Body)
                (if (and (> Uses 0)
                         (shen-jit.lower.frozen-binds? X Body)
                         (<= (* (- Uses 1) (shen-jit.lower.size E)) 100)
                         (empty? (intersection (shen-jit.lower.free E) (shen-jit.lower.binders Body))))
                    (shen-jit.lower.frozen-in X E Body)
                    (shen-jit.lower.frozen-late X E Body))))

\\ Too large to copy, but the closure can still wait for the tests that use it:
\\ a clause whose atom differs makes none.
(define shen-jit.lower.frozen-late
  X E [if C1 Y1 [if C2 Y2 [const false]]]
  -> [if [or C1 C2] [let X [freeze E] [if C1 Y1 Y2]] [const false]]
      where (and (shen-jit.lower.simple-test? C1) (shen-jit.lower.simple-test? C2)
                 (not (shen-jit.lower.occurs? X C1)) (not (shen-jit.lower.occurs? X C2)))
  X E Body -> [let X [freeze E] Body])

\\ A test that can be made twice: no calls, and no primitive but these.
(define shen-jit.lower.simple-test?
  [const _] -> true
  [var _] -> true
  [prim P Args] -> (and (element? P [= shen-jit.pvar? cons?]) (shen-jit.lower.simple-tests? Args))
  [let _ V X] -> (and (shen-jit.lower.simple-test? V) (shen-jit.lower.simple-test? X))
  _ -> false)

(define shen-jit.lower.simple-tests?
  [] -> true
  [X | Xs] -> (and (shen-jit.lower.simple-test? X) (shen-jit.lower.simple-tests? Xs)))

(define shen-jit.lower.frozen-binds?
  X [call shen.bind! [_ _ _ [var X]]] -> true
  _ [const _] -> false
  X [Y | Ys] -> (or (shen-jit.lower.frozen-binds? X Y) (shen-jit.lower.frozen-binds? X Ys))
  _ _ -> false)

(define shen-jit.lower.frozen-uses
  X [apply [var X]] -> 1
  X [call shen.bind! [A B C [var X]]] -> (let N (shen-jit.lower.frozen-uses X [A B C])
                                           (if (< N 0) N (+ N 1)))
  X [var X] -> -1000000
  _ [const _] -> 0
  X Y -> -1000000 where (shen-jit.lower.binds? X Y)
  X [Y | Ys] -> (let M (shen-jit.lower.frozen-uses X Y)
                     N (shen-jit.lower.frozen-uses X Ys)
                  (if (or (< M 0) (< N 0)) -1000000 (+ M N)))
  _ _ -> 0)

(define shen-jit.lower.frozen-in
  X E [apply [var X]] -> E
  X E [call shen.bind! [A B C [var X]]] -> (shen-jit.lower.bound-now A B C E)
  _ _ [const C] -> [const C]
  X E [Y | Ys] -> [(shen-jit.lower.frozen-in X E Y) | (shen-jit.lower.frozen-in X E Ys)]
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
(define shen-jit.lower.let-lambda
  X [freeze E] Body -> (shen-jit.lower.let-frozen X E Body)
  X V Body -> (let Params (shen-jit.lower.lambda-params V)
                   Uses (if (empty? Params) 0 (shen-jit.lower.applies X (length Params) Body))
                (if (and (> Uses 0)
                         (<= (* (- Uses 1) (shen-jit.lower.size V)) 1500)
                         (empty? (intersection (shen-jit.lower.free V)
                                               (shen-jit.lower.binders Body)))
                         (empty? (intersection Params (shen-jit.lower.vars-of Body))))
                    (shen-jit.lower.apply-in X Params (shen-jit.lower.lambda-body V) Body)
                    [let X V Body])))

(define shen-jit.lower.free
  [var X] -> [X]
  [const _] -> []
  [let X V Body] -> (union (shen-jit.lower.free V) (remove X (shen-jit.lower.free Body)))
  [lambda X Body] -> (remove X (shen-jit.lower.free Body))
  [trap X E H] -> (union (shen-jit.lower.free X) (remove E (shen-jit.lower.free H)))
  [X | Xs] -> (union (shen-jit.lower.free X) (shen-jit.lower.free Xs))
  _ -> [])

(define shen-jit.lower.lambda-params
  [lambda P Body] -> [P | (shen-jit.lower.lambda-params Body)]
  _ -> [])

(define shen-jit.lower.lambda-body
  [lambda _ Body] -> (shen-jit.lower.lambda-body Body)
  X -> X)

\\ A dynamic application as [F A1 ... An]: ((F A1) ... An), or Y itself.
(define shen-jit.lower.chain
  [apply F A] Args -> (shen-jit.lower.chain F [A | Args])
  Y Args -> [Y | Args])

\\ The number of applications of X to N arguments in Y, or -1 if Y uses X in
\\ any other way or binds it again.
(define shen-jit.lower.applies
  X N Y -> (let Chain (shen-jit.lower.chain Y [])
             (cond ((and (= (hd Chain) [var X]) (= (length (tl Chain)) N))
                    (shen-jit.lower.applies-all X N (tl Chain) 1))
                   ((= Y [var X]) -1)
                   ((shen-jit.lower.binds? X Y) -1)
                   ((and (cons? Y) (not (= (hd Y) const))) (shen-jit.lower.applies-all X N Y 0))
                   (true 0))))

(define shen-jit.lower.applies-all
  _ _ [] Count -> Count
  X N [Y | Ys] Count -> (let M (shen-jit.lower.applies X N Y)
                          (if (< M 0) -1 (shen-jit.lower.applies-all X N Ys (+ Count M))))
  _ _ _ Count -> Count)

(define shen-jit.lower.binds?
  X [let X _ _] -> true
  X [lambda X _] -> true
  X [trap _ X _] -> true
  _ _ -> false)

(define shen-jit.lower.apply-in
  X Params Inner Y
  -> (let Chain (shen-jit.lower.chain Y [])
       (if (and (= (hd Chain) [var X]) (= (length (tl Chain)) (length Params)))
           (shen-jit.lower.lets Params
                                  (map (/. A (shen-jit.lower.apply-in X Params Inner A)) (tl Chain))
                                  Inner)
           (shen-jit.lower.apply-in-all X Params Inner Y))))

(define shen-jit.lower.apply-in-all
  _ _ _ [const C] -> [const C]
  X Params Inner [Y | Ys] -> [(shen-jit.lower.apply-in X Params Inner Y)
                              | (shen-jit.lower.apply-in-all X Params Inner Ys)]
  _ _ _ Y -> Y)

(define shen-jit.lower.literal?
  X -> (or (shen-jit.symbol? X) (number? X) (string? X) (boolean? X) (empty? X)))

(define shen-jit.lower.fn-call
  F Args -> (let Vars (map (/. A (shen-jit.lower.fresh shen-jit.lower.arg)) Args)
                 G (shen-jit.lower.fresh shen-jit.lower.arg)
              (shen-jit.lower.lets Vars Args
                                     [if [shen-jit.arity? F (length Args)]
                                         [F | Vars]
                                         [let G [fn F] [G | Vars]]])))

(define shen-jit.lower.norm-list
  _ [] -> []
  Scope [X | Xs] -> [(shen-jit.lower.norm Scope X) | (shen-jit.lower.norm-list Scope Xs)]
  _ X -> (shen-jit.lower.fail "improper argument list" X))

\\ Dynamic calls apply one argument at a time: (F A B) is ((F A) B).
(define shen-jit.lower.norm-apply
  F [] -> [apply F]
  F [X] -> [apply F X]
  F [X | Xs] -> (shen-jit.lower.norm-apply [apply F X] Xs))

(define shen-jit.lower.norm-named
  Scope F Args
  -> (cond ((= (length Args) (shen-jit.lower.prim-arity F))
            (shen-jit.lower.prim F (shen-jit.lower.norm-list Scope Args)))
           ((shen-jit.lower.fixed? F)
            (shen-jit.lower.fail (shen-jit.lower.malformed F) [F | Args]))
           (true (shen-jit.lower.call F (shen-jit.lower.norm-list Scope Args)))))

\\ A cons of two constants whose tail is a proper list is itself a constant,
\\ made here once: a list literal such as [a b c] then costs nothing to
\\ evaluate. Pairs are immutable and = compares structure, so a fresh list
\\ and a shared one cannot be told apart.
(define shen-jit.lower.prim
  cons [[const A] [const B]] -> [const (cons A B)]
      where (and (shen-jit.lower.proper? B) (< (shen-jit.lower.size [A | B]) 64))
  + [[const A] [const B]] -> [const (+ A B)] where (shen-jit.lower.small-integers? A B)
  - [[const A] [const B]] -> [const (- A B)] where (shen-jit.lower.small-integers? A B)
  F Args -> [prim F Args])

\\ Integers whose sum or difference is an integer in every implementation.
(define shen-jit.lower.small-integers?
  A B -> (and (integer? A) (integer? B)
              (< (shen-jit.lower.abs A) 1000000000) (< (shen-jit.lower.abs B) 1000000000)))

(define shen-jit.lower.abs
  X -> (if (< X 0) (- 0 X) X))

(define shen-jit.lower.proper?
  [] -> true
  [_ | Xs] -> (shen-jit.lower.proper? Xs)
  _ -> false)

(define shen-jit.lower.malformed
  lambda -> "lambda needs one symbol parameter and a body"
  let -> "let needs a symbol, a value and a body"
  F -> (cn "wrong number of arguments to primitive " (str F))
      where (>= (shen-jit.lower.prim-arity F) 0)
  F -> (cn "malformed " (str F)))

\\ A clause whose test is the literal true ends the chain.
(define shen-jit.lower.norm-cond
  _ [] -> [prim raise-cond []]
  Scope [[true X] | _] -> (shen-jit.lower.norm Scope X)
  Scope [[C X] | Clauses] -> [if (shen-jit.lower.norm Scope C) (shen-jit.lower.norm Scope X)
                                 (shen-jit.lower.norm-cond Scope Clauses)]
  _ [Clause | _] -> (shen-jit.lower.fail "malformed cond clause" Clause)
  _ X -> (shen-jit.lower.fail "malformed cond" X))

\\ ---------------------------------------------------------------------------
\\ Builders. A builder accumulates one code object in an absvector:
\\ 0 name, 1 arity, 2 sealed names, 3 instructions (reversed), 4 constants
\\ (reversed), 5 nested codes, 6 labels used, 7 frame size, 8 captured variables,
\\ 9 how many constants.

(define shen-jit.lower.builder
  Name Arity Sealed
  -> (let B (absvector 10)
       (do (address-> B 0 Name) (address-> B 1 Arity) (address-> B 2 Sealed)
           (address-> B 3 []) (address-> B 4 []) (address-> B 5 [])
           (address-> B 6 0) (address-> B 7 (+ Arity 2)) (address-> B 8 []) (address-> B 9 0))))

\\ Lower Body with Params in slots 2.. and return the finished code object.
(define shen-jit.lower.code
  Name Params Body Sealed
  -> (shen-jit.lower.finish (shen-jit.lower.builder Name (length Params) Sealed) Params Body))

(define shen-jit.lower.finish
  B Params Body
  -> (do (shen-jit.lower.expr B (shen-jit.lower.bind Params 2) Body tail
                                (+ 2 (length Params)))
         (shen-jit.lower.code-form B)))

(define shen-jit.lower.code-form
  B -> [code (<-address B 0) (<-address B 1) (<-address B 7) (reverse (<-address B 4))
             (reverse (<-address B 3)) (<-address B 5)])

(define shen-jit.lower.bind
  [] _ -> []
  [X | Xs] S -> [[X | S] | (shen-jit.lower.bind Xs (+ S 1))])

(define shen-jit.lower.emit
  B Instruction -> (address-> B 3 [Instruction | (<-address B 3)]))

\\ The code an inlined body of F lowers to, marked as F's for backtraces:
\\ (inline F N) before its N instructions, which compiled code keeps as a
\\ table of names by return address, at no cost when it runs. Not at stage 0,
\\ whose backtraces stay as they were.
(define shen-jit.lower.mark
  B F Lower -> (if (cons? (<-address B 2))
                   (thaw Lower)
                   (let Before (length (<-address B 3))
                        Done (thaw Lower)
                        N (- (length (<-address B 3)) Before)
                     (if (> N 0)
                         (do (address-> B 3 (shen-jit.lower.insert N [inline F N] (<-address B 3))) Done)
                         Done))))

\\ X put after the first N of the instructions, which are newest first.
(define shen-jit.lower.insert
  0 X Is -> [X | Is]
  N X [I | Is] -> [I | (shen-jit.lower.insert (- N 1) X Is)])

(define shen-jit.lower.new-label
  B -> (let L (<-address B 6) (do (address-> B 6 (+ L 1)) L)))

(define shen-jit.lower.reserve
  B S -> (if (> (+ S 1) (<-address B 7)) (address-> B 7 (+ S 1)) B))

\\ Constants are shared only when identical: numbers must also print the
\\ same, because Shen's = equates 8 and 8.0. str comes last, as most numbers
\\ compared here differ. Two values with no literal syntax never reach =.
(define shen-jit.lower.constant
  B X -> (let Constants (<-address B 4)
              Count (<-address B 9)
              I (shen-jit.lower.constant-index X Constants (- Count 1))
           (if (= I -1)
               (do (address-> B 4 [X | Constants]) (address-> B 9 (+ Count 1)) Count)
               I)))

(define shen-jit.lower.constant-index
  _ [] I -> I
  X [Y | _] I -> I where (shen-jit.lower.same-constant? X Y)
  X [_ | Ys] I -> (shen-jit.lower.constant-index X Ys (- I 1)))

(define shen-jit.lower.same-constant?
  X Y -> (and (number? Y) (= X Y) (= (str X) (str Y))) where (number? X)
  [X | Xs] [Y | Ys] -> (and (shen-jit.lower.same-constant? X Y) (shen-jit.lower.same-constant? Xs Ys))
  X Y -> (and (not (number? Y)) (shen-jit.lower.literal? X) (= X Y)))

(define shen-jit.lower.add-code
  B Code -> (let Codes (<-address B 5)
              (do (address-> B 5 (append Codes [Code])) (length Codes))))

(define shen-jit.lower.capture-index
  B X -> (let Captures (<-address B 8)
              I (shen-jit.lower.index X Captures 0)
           (do (if (= I (length Captures)) (address-> B 8 (append Captures [X])) B)
               I)))

(define shen-jit.lower.index
  _ [] I -> I
  X [X | _] I -> I
  X [_ | Ys] I -> (shen-jit.lower.index X Ys (+ I 1)))

\\ ---------------------------------------------------------------------------
\\ Emission. Env maps the variables of the current code object to slots;
\\ any other variable is captured. Top is the first free slot: every slot
\\ that may still be read lies below it, so windows and temporaries go at or
\\ above it. A Target is a slot below Top, or tail for a tail position.
\\ Nothing writes a slot while a variable bound to it is in scope, so a let
\\ of one local variable to another shares its slot (inlining makes many).

(define shen-jit.lower.slot
  X Env -> (let Binding (assoc X Env)
             (if (and (cons? Binding) (number? (tl Binding))) (tl Binding) [])))

(define shen-jit.lower.expr
  B Env [if C X Y] Target Top -> (shen-jit.lower.if B Env C X Y Target Top)
  B Env [let G [freeze E] Body] tail Top -> (shen-jit.lower.goto B Env G E Body Top)
      where (> (shen-jit.lower.thaws G Body true) 0)
  B Env [let G [freeze E] Body] Target Top
  -> (shen-jit.lower.expr B Env (shen-jit.lower.thaw-in G E Body) Target Top)
      where (shen-jit.lower.inline-thaw? G E Body)
  B Env [apply [var G]] tail _ -> (shen-jit.lower.emit B [jump (shen-jit.lower.goto-label G Env)])
      where (shen-jit.lower.goto? G Env)
  B Env [let shen-jit.lower.inlining [const F] Body] Target Top
  -> (shen-jit.lower.mark B F (freeze (shen-jit.lower.expr B Env Body Target Top)))
  B Env [let X [var Y] Body] Target Top
  -> (shen-jit.lower.expr B [[X | (shen-jit.lower.slot Y Env)] | Env] Body Target Top)
      where (number? (shen-jit.lower.slot Y Env))
  B Env [let X V Body] Target Top
  -> (do (shen-jit.lower.value B Env V Top (+ Top 1))
         (shen-jit.lower.expr B [[X | Top] | Env] Body Target (+ Top 1)))
  B Env [do X Y] Target Top
  -> (do (shen-jit.lower.value B Env X Top (+ Top 1))
         (shen-jit.lower.expr B Env Y Target Top))
  B Env [call F Args] tail Top
  -> (let N (length Args)
       (do (shen-jit.lower.in-place B Env Args 2 (if (> Top (+ N 2)) Top (+ N 2)) [])
           (shen-jit.lower.emit B (shen-jit.lower.named-call B F tail 0 N))))
  B Env [call F Args] Target Top
  -> (do (shen-jit.lower.window B Env Args (+ Top 2))
         (shen-jit.lower.emit B (shen-jit.lower.named-call B F Target Top (length Args))))
  B Env [apply F A] Target Top
  -> (shen-jit.lower.apply-all B Env (shen-jit.lower.chain [apply F A] []) Target Top)
      where (shen-jit.lower.apply-all? [apply F A])
  B Env [apply F | Arg] Target Top
  -> (do (shen-jit.lower.window B Env [F | Arg] (+ Top 1))
         (shen-jit.lower.emit B (if (= Target tail)
                                      [tail-call-value Top (length Arg)]
                                      [call-value Target Top (length Arg)])))
  B Env [trap X E H] Target Top -> (shen-jit.lower.trap B Env X E H Target Top)
  B Env X tail Top -> (shen-jit.lower.emit B [return (shen-jit.lower.operand B Env X Top)])
  B Env X D Top -> (shen-jit.lower.value B Env X D Top))

\\ ((F A1) ... An), n >= 2, with every Ai a variable or a constant, so that
\\ evaluating them before applying F changes nothing: a closure that takes
\\ the n arguments at once (finish-entry) gets one call with all of them,
\\ and anything else is applied one argument at a time, as before, reading
\\ the same slots again.
(define shen-jit.lower.apply-all?
  X -> (let Args (tl (shen-jit.lower.chain X []))
         (and (>= (length Args) 2) (shen-jit.lower.simple? Args))))

(define shen-jit.lower.simple?
  [] -> true
  [[var _] | Xs] -> (shen-jit.lower.simple? Xs)
  [[const _] | Xs] -> (shen-jit.lower.simple? Xs)
  _ -> false)

(define shen-jit.lower.apply-all
  B Env [Head | Args] Target Top
  -> (let H (shen-jit.lower.fresh shen-jit.lower.head)
          S (shen-jit.lower.head-slot B Env Head Top)
          Env1 [[H | S] | Env]
          W (if (= S Top) (+ Top 1) Top)
          N (length Args)
          Fallback (shen-jit.lower.new-label B)
       (do (shen-jit.lower.window B Env1 [[var H] | Args] (+ W 1))
           (shen-jit.lower.emit B [jump-unless-entry S N Fallback])
           (if (= Target tail)
               (do (shen-jit.lower.emit B [tail-call-value W N])
                   (shen-jit.lower.emit B [label Fallback])
                   (shen-jit.lower.apply-each B Env1 [var H] Args tail W))
               (let Done (shen-jit.lower.new-label B)
                 (do (shen-jit.lower.emit B [call-value Target W N])
                     (shen-jit.lower.emit B [jump Done])
                     (shen-jit.lower.emit B [label Fallback])
                     (shen-jit.lower.apply-each B Env1 [var H] Args Target W)
                     (shen-jit.lower.emit B [label Done])))))))

\\ The slot of a variable head, or Top after evaluating any other.
(define shen-jit.lower.head-slot
  B Env [var X] _ -> (shen-jit.lower.slot X Env) where (number? (shen-jit.lower.slot X Env))
  B Env Head Top -> (do (shen-jit.lower.value B Env Head Top (+ Top 1)) Top))

(define shen-jit.lower.apply-each
  B Env F [A] Target Top -> (shen-jit.lower.expr B Env [apply F A] Target Top)
  B Env F [A | As] Target Top
  -> (let R (shen-jit.lower.fresh shen-jit.lower.partial)
       (do (shen-jit.lower.value B Env [apply F A] Top (+ Top 1))
           (shen-jit.lower.apply-each B [[R | Top] | Env] [var R] As Target (+ Top 1)))))

\\ (let G (freeze E) Body) in tail position, where Body uses G only as
\\ (thaw G) in tail position, as the factoriser's GoTo bindings do: E becomes
\\ code at a label after Body and each (thaw G) a jump to it, so no closure is
\\ made. E's variables keep their slots, since Body only writes at or above
\\ Top and ends in a return or tail call on every other path.
(define shen-jit.lower.goto
  B Env G E Body Top
  -> (let L (shen-jit.lower.new-label B)
       (do (shen-jit.lower.expr B [[G goto L] | Env] Body tail Top)
           (shen-jit.lower.emit B [label L])
           (shen-jit.lower.expr B Env E tail Top))))

(define shen-jit.lower.goto?
  G Env -> (let Binding (assoc G Env) (and (cons? Binding) (cons? (tl Binding)))))

(define shen-jit.lower.goto-label
  G Env -> (hd (tl (tl (assoc G Env)))))

\\ The number of (thaw G) in tail position in X, or -1 if X uses G in any
\\ other way or binds G again. Tail says whether X is in tail position.
(define shen-jit.lower.thaws
  G [apply [var G]] true -> 1
  G [var G] _ -> -1
  G [if C X Y] Tail -> (shen-jit.lower.thaws-all G [[C false] [X Tail] [Y Tail]])
  G [let G _ _] _ -> -1
  \\ A frozen E that is itself a label is code in tail position.
  G [let H [freeze E] Body] true -> (shen-jit.lower.thaws-all G [[E true] [Body true]])
      where (> (shen-jit.lower.thaws H Body true) 0)
  G [let _ V Body] Tail -> (shen-jit.lower.thaws-all G [[V false] [Body Tail]])
  G [do X Y] Tail -> (shen-jit.lower.thaws-all G [[X false] [Y Tail]])
  G [and X Y] _ -> (shen-jit.lower.thaws-all G [[X false] [Y false]])
  G [or X Y] _ -> (shen-jit.lower.thaws-all G [[X false] [Y false]])
  G [lambda G _] _ -> -1
  G [lambda _ Body] _ -> (shen-jit.lower.thaws G Body false)
  G [freeze Body] _ -> (shen-jit.lower.thaws G Body false)
  G [prim _ Args] _ -> (shen-jit.lower.thaws-all G (shen-jit.lower.non-tail Args))
  G [call _ Args] _ -> (shen-jit.lower.thaws-all G (shen-jit.lower.non-tail Args))
  G [apply F | Arg] _ -> (shen-jit.lower.thaws-all G (shen-jit.lower.non-tail [F | Arg]))
  G [trap _ G _] _ -> -1
  G [trap X _ H] _ -> (shen-jit.lower.thaws-all G [[X false] [H false]])
  _ _ _ -> 0)

\\ (let G (freeze E) Body), where Body uses G once, as (thaw G): that thaw
\\ becomes E itself and the let goes, so no closure is made. E then runs
\\ exactly when the thaw would have, with the same values, provided Body
\\ binds no variable of E.
(define shen-jit.lower.inline-thaw?
  G E Body -> (and (= 1 (shen-jit.lower.thaw-count G Body))
                   (empty? (intersection (shen-jit.lower.vars-of E)
                                         (shen-jit.lower.binders Body)))))

\\ The number of (thaw G) anywhere in X, or -1 if X uses G in any other way
\\ or binds it again.
(define shen-jit.lower.thaw-count
  G [apply [var G]] -> 1
  G [var G] -> -1
  G [let G _ _] -> -1
  G [lambda G _] -> -1
  G [trap _ G _] -> -1
  G [X | Xs] -> (let N (shen-jit.lower.thaw-count G X)
                     M (shen-jit.lower.thaw-count G Xs)
                  (if (or (< N 0) (< M 0)) -1 (+ N M)))
  _ _ -> 0)

(define shen-jit.lower.thaw-in
  G E [apply [var G]] -> E
  G E [X | Xs] -> [(shen-jit.lower.thaw-in G E X) | (shen-jit.lower.thaw-in G E Xs)]
  _ _ X -> X)

(define shen-jit.lower.vars-of
  [var X] -> [X]
  [X | Xs] -> (union (shen-jit.lower.vars-of X) (shen-jit.lower.vars-of Xs))
  _ -> [])

(define shen-jit.lower.binders
  [let X V Body] -> [X | (union (shen-jit.lower.binders V) (shen-jit.lower.binders Body))]
  [lambda X Body] -> [X | (shen-jit.lower.binders Body)]
  [trap X E H] -> [E | (union (shen-jit.lower.binders X) (shen-jit.lower.binders H))]
  [X | Xs] -> (union (shen-jit.lower.binders X) (shen-jit.lower.binders Xs))
  _ -> [])

(define shen-jit.lower.thaws-all
  _ [] -> 0
  G [[X Tail] | Xs] -> (let N (shen-jit.lower.thaws G X Tail)
                         (if (< N 0)
                             N
                             (let M (shen-jit.lower.thaws-all G Xs)
                               (if (< M 0) M (+ N M))))))

(define shen-jit.lower.non-tail
  [] -> []
  [X | Xs] -> [[X false] | (shen-jit.lower.non-tail Xs)])

\\ Compute X into slot D, which is below Top.
(define shen-jit.lower.value
  B Env X D Top -> (do (shen-jit.lower.reserve B D) (shen-jit.lower.value-h B Env X D Top)))

(define shen-jit.lower.value-h
  B _ [const X] D _ -> (shen-jit.lower.emit B [const D (shen-jit.lower.constant B X)])
  B Env [var X] D _ -> (shen-jit.lower.load-var B Env X D)
  \\ A chain of conses with constant heads stays in one slot: only the innermost
  \\ reads other slots. A parameter's slot is left out, as nothing but a tail
  \\ call may read it once written; the tail then goes to a slot above.
  B Env [prim cons [[const A] [prim cons Args]]] D Top
  -> (let K (shen-jit.lower.constant B A)
       (do (shen-jit.lower.value-h B Env [prim cons Args] D Top)
           (shen-jit.lower.emit B [prim D cons [const K] D])))
      where (>= D (+ 2 (<-address B 1)))
  \\ So does one whose heads are local variables. A head in D itself would be
  \\ overwritten before it is read; no lowering puts one there now.
  B Env [prim cons [[var X] [prim cons Args]]] D Top
  -> (do (shen-jit.lower.value-h B Env [prim cons Args] D Top)
         (shen-jit.lower.emit B [prim D cons (shen-jit.lower.slot X Env) D]))
      where (and (>= D (+ 2 (<-address B 1))) (number? (shen-jit.lower.slot X Env))
                 (not (= (shen-jit.lower.slot X Env) D)))
  B Env [prim Op Args] D Top
  -> (shen-jit.lower.emit B [prim D Op | (shen-jit.lower.operands B Env Args Top)])
  B Env [lambda X Body] D Top -> (shen-jit.lower.closure B Env lambda [X] Body D Top)
  B Env [freeze Body] D Top -> (shen-jit.lower.closure B Env freeze [] Body D Top)
  B Env [and X Y] D Top
  -> (shen-jit.lower.if B Env [and X Y] [const true] [const false] D Top)
  B Env [or X Y] D Top
  -> (shen-jit.lower.if B Env [or X Y] [const true] [const false] D Top)
  B Env X D Top -> (shen-jit.lower.expr B Env X D Top))

(define shen-jit.lower.load-var
  B Env X D -> (let Binding (assoc X Env)
                 (cond ((empty? Binding)
                        (shen-jit.lower.emit B [capture D (shen-jit.lower.capture-index B X)]))
                       ((= (tl Binding) D) skip)
                       (true (shen-jit.lower.emit B [move D (tl Binding)])))))

\\ An operand for X: a local variable's own slot, (const K) for a constant,
\\ or Top, after computing X there.
(define shen-jit.lower.operand
  _ Env [var X] _ -> (tl (assoc X Env)) where (cons? (assoc X Env))
  B _ [const X] _ -> [const (shen-jit.lower.constant B X)]
  B Env X Top -> (do (shen-jit.lower.value B Env X Top (+ Top 1)) Top))

(define shen-jit.lower.operands
  _ _ [] _ -> []
  B Env [X | Xs] Top
  -> (let S (shen-jit.lower.operand B Env X Top)
       [S | (shen-jit.lower.operands B Env Xs (if (= S Top) (+ Top 1) Top))]))

\\ Evaluate Xs into consecutive slots from S, each above the previous ones.
(define shen-jit.lower.window
  _ _ [] _ -> skip
  B Env [X | Xs] S -> (do (shen-jit.lower.value B Env X S (+ S 1))
                          (shen-jit.lower.window B Env Xs (+ S 1))))

\\ A named tail call (window 0) computes each argument straight into its
\\ parameter slot S, from 2 up, so an argument already there costs nothing,
\\ even when a later one reads it, since nothing else writes that slot. Any
\\ other argument whose slot a later one still reads goes to a temporary at
\\ Top instead, and Moves puts it in place after the last argument. Top
\\ starts above every parameter slot.
(define shen-jit.lower.in-place
  B _ [] _ _ Moves -> (map (/. M (shen-jit.lower.emit B [move | M])) Moves)
  B Env [[var X] | Xs] S Top Moves -> (shen-jit.lower.in-place B Env Xs (+ S 1) Top Moves)
      where (= (shen-jit.lower.slot X Env) S)
  B Env [X | Xs] S Top Moves
  -> (do (shen-jit.lower.value B Env X Top (+ Top 1))
         (shen-jit.lower.in-place B Env Xs (+ S 1) (+ Top 1) [[S Top] | Moves]))
      where (shen-jit.lower.reads? Env (shen-jit.lower.vars-of Xs) S)
  B Env [X | Xs] S Top Moves
  -> (do (shen-jit.lower.value B Env X S Top)
         (shen-jit.lower.in-place B Env Xs (+ S 1) Top Moves)))

(define shen-jit.lower.reads?
  Env Vs S -> (element? S (map (/. V (shen-jit.lower.slot V Env)) Vs)))

(define shen-jit.lower.named-call
  B F Target A N
  -> (let Sealed (or (= F shen-jit.eval-kl) (element? F (<-address B 2)) (shen-jit.sealed? F))
       (do (shen-jit.lower.reserve B (+ A (+ N 1)))
           (cond ((and (= Target tail) Sealed) [tail-call-sealed A F N])
                 ((= Target tail) [tail-call A F N])
                 (Sealed [call-sealed Target A F N])
                 (true [call Target A F N])))))

(define shen-jit.lower.if
  \\ An else that jumps to a label: the test jumps there itself.
  B Env C X [apply [var G]] tail Top -> (do (shen-jit.lower.test B Env C (shen-jit.lower.goto-label G Env) Top)
                                            (shen-jit.lower.expr B Env X tail Top))
      where (shen-jit.lower.goto? G Env)
  B Env C X Y Target Top
  -> (let Else (shen-jit.lower.new-label B)
          End (shen-jit.lower.end-label B Target)
       (do (shen-jit.lower.test B Env C Else Top)
           (shen-jit.lower.expr B Env X Target Top)
           (shen-jit.lower.jump-to-end B End)
           (shen-jit.lower.emit B [label Else])
           (shen-jit.lower.expr B Env Y Target Top)
           (shen-jit.lower.place-end B End))))

\\ Code in tail position never falls through, so it needs no join label.
(define shen-jit.lower.end-label
  _ tail -> none
  B _ -> (shen-jit.lower.new-label B))

(define shen-jit.lower.jump-to-end
  _ none -> skip
  B L -> (shen-jit.lower.emit B [jump L]))

(define shen-jit.lower.place-end
  _ none -> skip
  B L -> (shen-jit.lower.emit B [label L]))

\\ Fall through when X is true; continue at Else when it is false.
(define shen-jit.lower.test
  B Env [and X Y] Else Top -> (do (shen-jit.lower.test B Env X Else Top)
                                  (shen-jit.lower.test B Env Y Else Top))
  B Env [or X Y] Else Top
  -> (let Next (shen-jit.lower.new-label B)
          Then (shen-jit.lower.new-label B)
       (do (shen-jit.lower.test B Env X Next Top)
           (shen-jit.lower.emit B [jump Then])
           (shen-jit.lower.emit B [label Next])
           (shen-jit.lower.test B Env Y Else Top)
           (shen-jit.lower.emit B [label Then])))
  \\ The factoriser binds each selector with a let inside the and that
  \\ tests it: the body is a test too, rather than a Boolean to test again.
  B Env [let shen-jit.lower.inlining [const F] Body] Else Top
  -> (shen-jit.lower.mark B F (freeze (shen-jit.lower.test B Env Body Else Top)))
  B Env [let X [var Y] Body] Else Top
  -> (shen-jit.lower.test B [[X | (shen-jit.lower.slot Y Env)] | Env] Body Else Top)
      where (number? (shen-jit.lower.slot Y Env))
  B Env [let X V Body] Else Top
  -> (do (shen-jit.lower.value B Env V Top (+ Top 1))
         (shen-jit.lower.test B [[X | Top] | Env] Body Else (+ Top 1)))
  B Env [do X Y] Else Top -> (do (shen-jit.lower.value B Env X Top (+ Top 1))
                                 (shen-jit.lower.test B Env Y Else Top))
  B Env X Else Top -> (shen-jit.lower.emit B [jump-if-false (shen-jit.lower.operand B Env X Top)
                                                              Else]))

\\ The protected expression is never in tail position; the handler is when
\\ the trap-error is. E is bound to the exception in slot Top.
(define shen-jit.lower.trap
  B Env X E H Target Top
  -> (let Handler (shen-jit.lower.new-label B)
          End (shen-jit.lower.end-label B Target)
          S (if (= Target tail) Top Target)
       (do (shen-jit.lower.emit B [push-handler Handler])
           (shen-jit.lower.value B Env X S (if (= Target tail) (+ Top 1) Top))
           (shen-jit.lower.emit B [pop-handler])
           (if (= Target tail)
               (shen-jit.lower.emit B [return S])
               (shen-jit.lower.jump-to-end B End))
           (shen-jit.lower.emit B [label Handler])
           (shen-jit.lower.reserve B Top)
           (if (element? E (shen-jit.lower.vars-of H))
               (shen-jit.lower.emit B [exception Top])
               skip)
           (shen-jit.lower.expr B [[E | Top] | Env] H Target (+ Top 1))
           (shen-jit.lower.place-end B End))))

\\ Lower a lambda or freeze body as nested code, then capture the variables
\\ it uses from enclosing scopes, in the order the nested code numbered them.
(define shen-jit.lower.closure
  B Env Kind Params Body D Top
  -> (shen-jit.lower.closure-with B Env (shen-jit.lower.builder Kind (length Params) (<-address B 2))
                                    (if (= Kind lambda) (shen-jit.lower.finish-lambda Params Body)
                                        (/. Nested (shen-jit.lower.finish Nested Params Body)))
                                    D Top))

(define shen-jit.lower.closure-with
  B Env Nested Finish D Top
  -> (let C (shen-jit.lower.add-code B (Finish Nested))
          Slots (shen-jit.lower.operands B Env (shen-jit.lower.vars (<-address Nested 8)) Top)
       (shen-jit.lower.emit B [closure D C | Slots])))

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
(define shen-jit.lower.finish-lambda
  Params [lambda X Body]
  -> (/. B (if (empty? (<-address B 2))
               (shen-jit.lower.finish-entry B Params [lambda X Body])
               (shen-jit.lower.finish-plain B Params [lambda X Body])))
      where (<= (shen-jit.lower.size (shen-jit.lower.lambda-body Body)) 400)
  Params Body -> (/. B (shen-jit.lower.finish-plain B Params Body)))

(define shen-jit.lower.finish-entry
  B Params Inner
  -> (let All (append Params (shen-jit.lower.lambda-params Inner))
          L (shen-jit.lower.new-label B)
       (do (shen-jit.lower.emit B [entry (length All) L])
           (shen-jit.lower.plain-return B Params Inner)
           (shen-jit.lower.emit B [label L])
           (shen-jit.lower.reserve B (+ 1 (length All)))
           (shen-jit.lower.expr B (shen-jit.lower.bind All 2) (shen-jit.lower.lambda-body Inner)
                                  tail (+ 2 (length All)))
           (shen-jit.lower.code-form B))))

\\ The one-argument bodies of a chain: its inner lambdas take one argument
\\ each, and have no entry.
(define shen-jit.lower.finish-plain
  B Params [lambda X Body] -> (do (shen-jit.lower.plain-return B Params [lambda X Body])
                                  (shen-jit.lower.code-form B))
  B Params Body -> (shen-jit.lower.finish B Params Body))

(define shen-jit.lower.plain-return
  B Params [lambda X Body]
  -> (let Top (+ 2 (length Params))
       (do (shen-jit.lower.reserve B Top)
           (shen-jit.lower.closure-with B (shen-jit.lower.bind Params 2)
                                          (shen-jit.lower.builder lambda 1 (<-address B 2))
                                          (/. Nested (shen-jit.lower.finish-plain Nested [X] Body))
                                          Top (+ Top 1))
           (shen-jit.lower.emit B [return Top]))))

(define shen-jit.lower.vars
  [] -> []
  [X | Xs] -> [[var X] | (shen-jit.lower.vars Xs)])

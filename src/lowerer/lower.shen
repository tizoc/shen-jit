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
\\ The lowerer is these files, which the Makefile lists as LOWERER and src/lowerer/tokl.shen
\\ compiles together:
\\
\\   lower.shen       entry points, and what comes before normalization
\\   inline.shen      inlining
\\   normalise.shen   the fixed names, and normalization
\\   builders.shen    builders, each accumulating a code object
\\   emit.shen        emission
\\   registers.shen   floats and fixnums in registers in typed code, and loops inlined into loops
\\
\\ Each is the namespace shen-jit.lower; src/lowerer/README.md says what that asks of its code.
\\
\\ Entry points; Sealed is the list of names defined in the stage 0 input:
\\
\\   (shen-jit.lower.defun [defun F Params Body] Sealed) -> [defun F Code]
\\   (shen-jit.lower.expression X Sealed) -> Code, of arity 0
\\   (shen-jit.lower.toplevel X Sealed) -> whichever of the two X needs
\\
\\ Errors in the input raise "shen-jit lowerer: ..." with the culprit.

(shen.x.namespace shen-jit.lower
  (use shen-jit)

(define toplevel
  [defun | Rest] Sealed -> (shen-jit.lower.defun [defun | Rest] Sealed)
  X Sealed -> (expression X Sealed))

\\ A definition the typechecker annotated comes with its body marked (shen-jit.annotated Body),
\\ by the port's shen-jit.compiled-kl: only there do its type forms say anything, and a
\\ (type X T) written in untyped code is only erased. Nothing at stage 0 is annotated.
(define shen-jit.lower.defun
  [defun F Params [shen-jit.annotated Typed]] Sealed -> (defun-of F Params Typed Sealed (empty? Sealed))
  [defun F Params Typed] Sealed -> (defun-of F Params Typed Sealed false)
  X _ -> (shen-jit.lower.fail "malformed defun" X))

(define defun-of
  F Params Typed Sealed Annotated
  -> (do (check-defun F Params Sealed)
         (set *inline-depth* 0)
         (set *fresh* 0)
         (set *looping* [F])
         (let Trusted (set *typed* Annotated)
              Kinds (param-kinds Params Typed Annotated)
              Registers (set *registers* (registers-for? Annotated Typed))
              Body (untyped Params Typed)
              Code (defun-code F Params (freeze (norm Params (share Body)))
                                              Sealed Kinds)
           [defun F (append Code [(inline-of F Params Body Sealed Code Kinds)])])))

\\ X without its (type E T) forms, which typed code has wherever the kernel's annotator
\\ (shen.x.type-annotations) put them: each is E, so the rest of the lowerer sees the code it
\\ would see without them, and makes the same. Not where type names a variable. Code with
\\ none is not copied.
(define untyped
  Scope X -> (if (shen-jit.lower.occurs? type X) (untyped-h Scope X) X))

(define untyped-h
  Scope [type X _] -> (untyped-h Scope X) where (not (element? type Scope))
  Scope [let X V Body] -> [let X (untyped-h Scope V) (untyped-h [X | Scope] Body)]
  Scope [lambda X Body] -> [lambda X (untyped-h [X | Scope] Body)]
  Scope [X | Xs] -> [(untyped-h Scope X) | (untyped-each Scope Xs)]
  _ X -> X)

\\ The elements of a form, each of them code.
(define untyped-each
  Scope [X | Xs] -> [(untyped-h Scope X) | (untyped-each Scope Xs)]
  _ X -> X)

\\ A body that tests a chain of conditions binding parts of the argument as
\\ it goes, as factorised pattern matching does: the chain becomes nested ifs
\\ whose failures jump to the else branch (a frozen else in tail position is
\\ a label), so that the then branch, inside those bindings, uses them where
\\ it would take the same parts again with hd and tl.
(define share
  [if C X Y] -> (let Spine (spine C [])
                     Then (if (or (empty? Spine) (captures? Spine X))
                              X
                              (reuse X Spine []))
                  (if (= Then X)
                      [if C (share X) (share Y)]
                      (let G (shen-jit.lower.fresh else)
                        [let G [freeze (share Y)]
                             (unchain C (share Then) G)])))
  [let X V Body] -> [let X V (share Body)]
  [do X Y] -> [do X (share Y)]
  X -> X)

\\ The variables bound along the chain, each with what it holds in terms of
\\ the variables outside it; none if a name is bound twice.
(define spine
  [and _ S] Bs -> (spine S Bs)
  [let X E S] Bs -> (if (or (not (symbol? X)) (shen-jit.lower.occurs? X Bs))
                        []
                        (spine S [[X | (canon E Bs)] | Bs]))
  _ Bs -> Bs)

\\ Whether X names a variable the chain binds, which X, once inside those
\\ bindings, would then mean instead of what it meant outside.
(define captures?
  [[V | _] | Bs] X -> (or (shen-jit.lower.occurs? V X) (captures? Bs X))
  _ _ -> false)

(define canon
  [Op A] Bs -> [Op (canon A Bs)] where (element? Op [hd tl])
  X Bs -> (let B (assoc X Bs) (if (cons? B) (tl B) X)) where (symbol? X)
  X _ -> X)

(define shen-jit.lower.occurs?
  X X -> true
  X [Y | Ys] -> (or (shen-jit.lower.occurs? X Y) (shen-jit.lower.occurs? X Ys))
  _ _ -> false)

\\ X with each hd or tl that the chain bound replaced by its variable. Ls are
\\ X's own lets on the way; one that binds a name the chain uses ends it.
(define reuse
  [Op A] Bs Ls -> (let V (bound (canon [Op A] (append Ls Bs)) Bs)
                    (if (symbol? V) V [Op (reuse A Bs Ls)]))
      where (element? Op [hd tl])
  [let X E Body] Bs Ls
  -> (let E2 (reuse E Bs Ls)
       (if (or (shen-jit.lower.occurs? X Bs) (shen-jit.lower.occurs? X Ls))
           [let X E2 Body]
           [let X E2 (reuse Body Bs [[X | (canon E2 (append Ls Bs))] | Ls])]))
  [lambda X Body] Bs Ls -> [lambda X Body] where (or (shen-jit.lower.occurs? X Bs) (shen-jit.lower.occurs? X Ls))
  [X | Xs] Bs Ls -> (map (/. Y (reuse Y Bs Ls)) [X | Xs])
  X _ _ -> X)

(define bound
  C [[X | C] | _] -> X
  C [_ | Bs] -> (bound C Bs)
  _ _ -> [])

(define unchain
  [and T S] Then G -> [if T (unchain S Then G) [thaw G]]
  [let X E S] Then G -> [let X E (unchain S Then G)]
  T Then G -> [if T Then [thaw G]])

(define expression
  X Sealed -> (do (set *inline-depth* 0)
                  (set *fresh* 0)
                  (set *typed* false)
                  (set *registers* false)
                  (set *looping* [])
                  (shen-jit.lower.code eval-kl [] (norm [] (untyped [] X)) Sealed)))

\\ A variable of the lowerer's own, fresh within the definition being lowered.
\\ The count restarts with each definition, so the same few names come back:
\\ gensym would intern a new symbol every time.
(define shen-jit.lower.fresh
  Prefix -> (let N (+ (value *fresh*) 1)
                 Count (set *fresh* N)
              (concat Prefix N))))

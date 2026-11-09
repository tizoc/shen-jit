\\ Checks for the shen-jit lowerer (test code).
\\
\\ Run from the shen-jit directory, after src/lowerer/stage0.shen, under the
\\ same host, once make has written build/tools/lower.shen and native.shen:
\\
\\   HOST script src/lowerer/check.shen [KLAMBDA-DIR [SBC-DIR]]
\\
\\ 1. Reads every build/stage0/*.sbc file back with a small reader for the
\\    stage 0 syntax and compares it with a fresh in-memory lowering.
\\ 2. Checks the structure of every code object: slot, window, constant,
\\    code and capture bounds, labels, primitive arities, call kinds against
\\    the sealed definitions and their arities, nested code shapes.
\\ 3. Runs a forward dataflow over each instruction list: every slot read is
\\    written on all paths (so a call's window, which clobbers every slot
\\    from A up, never holds a live value), handlers are balanced at every
\\    return and tail call, exception only starts a handler, jumps go
\\    forward, and no code falls off the end.
\\ 4. Unit cases with expected instruction lists, malformed inputs that the
\\    lowerer must reject, and broken code objects that this checker must
\\    reject.
\\ 5. Checks that normalization's output, for every definition and unit case,
\\    is the language the emitter takes: only its nodes, of their shapes,
\\    each variable bound where it is used, and each primitive given its
\\    arity. Most bad shapes would make the emitter loop, and an unbound
\\    variable would fail check 2 as a capture, but a dynamic call with two
\\    arguments, or a binder left out of scope, which makes its uses
\\    constants, would make code that checks 2 and 3 accept.

(set *hush* true)
(load "src/lowerer/host.shen")
(load "build/tools/lower.shen")
(load "build/tools/namespaces.shen")
(stage0.namespaces.initialise)
(load "build/tools/native.shen")
(set *hush* false)
(set *maximum-print-sequence-size* 100000)

(set shen-jit.check.*failures* 0)
(set shen-jit.check.*quiet* false)

(define shen-jit.check.fail
  Where Message X
  -> (do (set shen-jit.check.*failures* (+ 1 (value shen-jit.check.*failures*)))
         (if (and (not (value shen-jit.check.*quiet*)) (<= (value shen-jit.check.*failures*) 40))
             (output "FAIL ~A: ~A ~R~%" Where Message X)
             skip)
         false))

(define shen-jit.check.files
  -> ["toplevel" "core" "sys" "dict" "sequent" "yacc" "reader" "prolog" "track" "load"
      "writer" "macros" "declarations" "types" "t-star" "init"
      "extension-features" "extension-launcher" "extension-programmable-pattern-matching"
      "extension-namespaces" "extension-expand-dynamic" "extension-type-annotations"])

(define shen-jit.check.defuns
  Forms -> (mapcan (/. X (if (and (cons? X) (= (hd X) defun)) [X] [])) Forms))

\\ ---------------------------------------------------------------------------
\\ A reader for the stage 0 syntax (see stage0.shen), on bytes. Reals stay as
\\ [shen-jit.check.real Text] and are compared by their printed form.

(define shen-jit.check.read-sbc
  Path -> (shen-jit.check.read-all (read-file-as-bytelist Path)))

(define shen-jit.check.read-all
  [] -> []
  [B | Bs] -> (shen-jit.check.read-all Bs) where (element? B [10 32])
  Bs -> (let R (shen-jit.check.read-form Bs)
          [(hd R) | (shen-jit.check.read-all (tl R))]))

(define shen-jit.check.read-form
  [40 | Bs] -> (shen-jit.check.read-list Bs [])
  [34 | Bs] -> (shen-jit.check.read-string Bs [])
  Bs -> (shen-jit.check.read-token Bs []))

(define shen-jit.check.read-list
  [41 | Bs] Acc -> [(reverse Acc) | Bs]
  [B | Bs] Acc -> (shen-jit.check.read-list Bs Acc) where (element? B [10 32])
  [] _ -> (simple-error "sbc: unterminated list")
  Bs Acc -> (let R (shen-jit.check.read-form Bs)
              (shen-jit.check.read-list (tl R) [(hd R) | Acc])))

(define shen-jit.check.read-string
  [34 | Bs] Acc -> [(shen-jit.check.bytes->string (reverse Acc) "") | Bs]
  [92 120 H L | Bs] Acc -> (shen-jit.check.read-string
                             Bs [(+ (* 16 (shen-jit.check.hex H)) (shen-jit.check.hex L)) | Acc])
  [92 C | Bs] Acc -> (shen-jit.check.read-string Bs [C | Acc]) where (element? C [34 92])
  [C | Bs] Acc -> (shen-jit.check.read-string Bs [C | Acc]) where (and (>= C 32) (<= C 126))
  _ _ -> (simple-error "sbc: bad string"))

(define shen-jit.check.hex
  C -> (- C 48) where (and (>= C 48) (<= C 57))
  C -> (- C 87) where (and (>= C 97) (<= C 102))
  _ -> (simple-error "sbc: bad hex digit"))

(define shen-jit.check.bytes->string
  [] S -> S
  [B | Bs] S -> (shen-jit.check.bytes->string Bs (cn S (n->string B))))

(define shen-jit.check.read-token
  [B | Bs] Acc -> (shen-jit.check.read-token Bs [B | Acc]) where (not (element? B [10 32 40 41]))
  Bs Acc -> [(shen-jit.check.token (reverse Acc)) | Bs])

(define shen-jit.check.token
  [] -> (simple-error "sbc: empty token")
  Bytes -> (let Text (shen-jit.check.bytes->string Bytes "")
             (cond ((= Text "true") true)
                   ((= Text "false") false)
                   ((not (shen-jit.check.numeric? Bytes)) (intern Text))
                   ((shen-jit.check.integer-text? Bytes) (shen-jit.check.integer Bytes))
                   (true [shen-jit.check.real Text]))))

(define shen-jit.check.digit?
  B -> (and (>= B 48) (<= B 57)))

(define shen-jit.check.numeric?
  [B | _] -> true where (shen-jit.check.digit? B)
  [B C | _] -> (shen-jit.check.digit? C) where (element? B [43 45 46])
  _ -> false)

(define shen-jit.check.integer-text?
  [45 | Bs] -> (shen-jit.check.integer-text? Bs)
  Bs -> (and (cons? Bs) (shen-jit.check.all-digits? Bs)))

(define shen-jit.check.all-digits?
  [] -> true
  [B | Bs] -> (and (shen-jit.check.digit? B) (shen-jit.check.all-digits? Bs)))

(define shen-jit.check.integer
  [45 | Bs] -> (- 0 (shen-jit.check.integer Bs))
  Bs -> (shen-jit.check.digits Bs 0))

(define shen-jit.check.digits
  [] N -> N
  [B | Bs] N -> (shen-jit.check.digits Bs (+ (* 10 N) (- B 48))))

(define shen-jit.check.same?
  [shen-jit.check.real T] X -> (and (number? X) (= (str X) T))
  X [shen-jit.check.real T] -> (and (number? X) (= (str X) T))
  [X | Xs] [Y | Ys] -> (and (shen-jit.check.same? X Y) (shen-jit.check.same? Xs Ys))
  X Y -> (and (number? Y) (= (str X) (str Y))) where (number? X)
  X Y -> (= X Y))

\\ Where the lowerer's code is held to more than hand-written code: its
\\ constants are literals, a sealed call matches the sealed definition's arity,
\\ and a parameter it has overwritten is read only as a tail call's argument.

(define shen-jit.check.literal?
  [shen-jit.check.real _] -> true
  [X | Xs] -> (and (shen-jit.check.literal? X) (shen-jit.check.literal? Xs))
  X -> (stage0.lower.literal? X))

(define shen-jit.check.arity
  F -> (trap-error (get F shen-jit.check.arity) (/. E -1)))

(define shen-jit.check.sealed?
  F N -> (= (shen-jit.check.arity F) N))

(define shen-jit.check.open?
  F -> (and (symbol? F) (= (shen-jit.check.arity F) -1) (not (stage0.lower.fixed? F))))

\\ On entry with N arguments: slot 1 and the parameters are set.
(define shen-jit.check.entry-state
  N -> (let Params (shen-jit.check.range 2 (+ N 1))
         [(append [1 | Params] (map (/. P [param P]) Params)) | []]))

\\ ---------------------------------------------------------------------------
\\ Normalized code (see shen-jit.lower.norm). At most one failure for each
\\ definition: the checks stop at the first.

(define shen-jit.check.normalized
  [defun F Params Body] -> (do (set stage0.lower.*inline-depth* 0)
                               (set stage0.lower.*fresh* 0)
                               (shen-jit.check.norm F Params
                                                    (stage0.lower.norm Params (stage0.lower.share Body))))
  X -> (do (set stage0.lower.*inline-depth* 0)
           (set stage0.lower.*fresh* 0)
           (shen-jit.check.norm eval-kl [] (stage0.lower.norm [] X))))

(define shen-jit.check.norm
  W S [const X] -> (shen-jit.check.assert (not (element? X S)) W "bound variable as a constant" X)
  W S [var X] -> (shen-jit.check.assert (element? X S) W "unbound variable" X)
  W S [if C X Y] -> (shen-jit.check.norms W S [C X Y])
  W S [and X Y] -> (shen-jit.check.norms W S [X Y])
  W S [or X Y] -> (shen-jit.check.norms W S [X Y])
  W S [do X Y] -> (shen-jit.check.norms W S [X Y])
  W S [let X V Body] -> (and (shen-jit.check.binder W X) (shen-jit.check.norm W S V)
                             (shen-jit.check.norm W [X | S] Body))
  W S [lambda X Body] -> (and (shen-jit.check.binder W X) (shen-jit.check.norm W [X | S] Body))
  W S [freeze X] -> (shen-jit.check.norm W S X)
  W S [prim Op Args] -> (and (shen-jit.check.norms W S Args)
                             (shen-jit.check.assert (= (length Args) (shen-jit.check.prim-arity Op))
                                                    W "primitive arity" [Op | Args]))
  W S [call F Args] -> (and (shen-jit.check.binder W F) (shen-jit.check.norms W S Args))
  W S [apply F] -> (shen-jit.check.norm W S F)
  W S [apply F X] -> (shen-jit.check.norms W S [F X])
  W S [trap X E H] -> (and (shen-jit.check.norm W S X) (shen-jit.check.binder W E)
                           (shen-jit.check.norm W [E | S] H))
  W _ X -> (shen-jit.check.fail W "not normalized" X))

(define shen-jit.check.norms
  _ _ [] -> true
  W S [X | Xs] -> (and (shen-jit.check.norm W S X) (shen-jit.check.norms W S Xs))
  W _ X -> (shen-jit.check.fail W "improper list" X))

(define shen-jit.check.binder
  W X -> (shen-jit.check.assert (shen-jit.symbol? X) W "not a symbol" X))

\\ ---------------------------------------------------------------------------
\\ Unit cases: [Form Sealed Expected], where Sealed pairs names with arities
\\ and Expected is the code object (of the defun, when Form is one). Strings
\\ are read with the stage 0 reader above: the Shen reader would curry
\\ applications of known functions such as code and return.

(define shen-jit.check.units
  -> [
      \\ let: the value goes to the next free slot, which the body then uses.
      ["(defun f (X Y) (let Z (+ X 1) (foo Z (cons Y ()))))" [[foo | 2]]
       "(code f 2 5 (1 ())
          ((prim 4 + 2 (const 0)) (move 2 4) (prim 3 cons 3 (const 1))
           (tail-call-sealed 0 foo 2)) ())"]
      \\ A tail call computes its arguments in place, except one whose
      \\ parameter a later argument still reads, as when they swap.
      ["(defun f (X Y) (foo Y X))" [[foo | 2]]
       "(code f 2 5 () ((move 4 3) (move 3 2) (move 2 4) (tail-call-sealed 0 foo 2)) ())"]
      \\ Nested lambdas: the inner one captures X through the middle one. The
      \\ middle one also takes both arguments at once, at label 0.
      ["(defun f (X) (lambda Y (lambda Z (cons X (cons Y Z)))))" []
       "(code f 1 4 () ((closure 3 0 2) (return 3))
          ((code lambda 1 7 () ((entry 2 0) (capture 4 0) (closure 3 0 4 2) (return 3) (label 0)
                                (capture 5 0) (prim 6 cons 2 3) (prim 4 cons 5 6) (return 4))
            ((code lambda 1 7 () ((capture 4 0) (capture 6 1) (prim 5 cons 6 2)
                                  (prim 3 cons 4 5) (return 3)) ())))))"]
      \\ trap-error with a literal handler, in tail position.
      ["(defun f (X) (trap-error (hd X) (lambda E (error-to-string E))))" []
       "(code f 1 5 ()
          ((push-handler 0) (prim 3 hd 2) (pop-handler) (return 3) (label 0)
           (exception 3) (prim 4 error-to-string 3) (return 4)) ())"]
      \\ A lambda applied where it is written is a let: no closure is made.
      ["(defun f (X) ((lambda Y (cons Y Y)) X))" []
       "(code f 1 4 () ((prim 3 cons 2 2) (return 3)) ())"]
      \\ A handler that ignores the exception does not load it, which makes it
      \\ quiet.
      ["(defun f (X) (trap-error (hd X) (lambda E 0)))" []
       "(code f 1 4 (0)
          ((push-handler 0) (prim 3 hd 2) (pop-handler) (return 3) (label 0)
           (return (const 0))) ())"]
      \\ trap-error with a handler value, as an operand.
      ["(defun f (X H) (cons (trap-error (hd X) H) 1))" []
       "(code f 2 10 (1)
          ((push-handler 0) (prim 5 hd 2) (pop-handler) (jump 1) (label 0) (exception 6)
           (move 8 3) (move 9 6) (call-value 5 7 1) (label 1)
           (prim 4 cons 5 (const 0)) (return 4)) ())"]
      \\ cond: the true clause ends the chain.
      ["(defun f (X) (cond ((= X 1) a) (true b)))" []
       "(code f 1 4 (1 a b)
          ((prim 3 = 2 (const 0)) (jump-if-false 3 0) (return (const 1))
           (label 0) (return (const 2))) ())"]
      \\ cond with fallthrough to raise-cond.
      ["(defun f (X) (cond ((= X 1) a) ((and (cons? X) (= (hd X) 2)) b)))" []
       "(code f 1 5 (1 a 2 b)
          ((prim 3 = 2 (const 0)) (jump-if-false 3 0) (return (const 1))
           (label 0) (prim 3 cons? 2) (jump-if-false 3 1) (prim 4 hd 2)
           (prim 3 = 4 (const 2)) (jump-if-false 3 1) (return (const 3)) (label 1)
           (prim 3 raise-cond) (return 3)) ())"]
      \\ and/or as a test (jumps), and as values (if A (if B true false) false).
      ["(defun f (X Y) (if (or (= X 1) (and Y X)) (or X Y) (and X Y)))" []
       "(code f 2 5 (1 true false)
          ((prim 4 = 2 (const 0)) (jump-if-false 4 1) (jump 2) (label 1)
           (jump-if-false 3 0) (jump-if-false 2 0) (label 2)
           (jump-if-false 2 5) (jump 6) (label 5) (jump-if-false 3 3) (label 6)
           (const 4 1) (jump 4) (label 3) (const 4 2) (label 4) (return 4)
           (label 0) (jump-if-false 2 7) (jump-if-false 3 7) (const 4 1) (jump 8)
           (label 7) (const 4 2) (label 8) (return 4)) ())"]
      \\ Named calls, sealed and open, in and out of tail position; do.
      ["(defun f (X) (do (foo X) (bar (foo X))))" [[foo | 1]]
       "(code f 1 7 ()
          ((move 6 2) (call-sealed 3 4 foo 1) (move 5 2) (call-sealed 2 3 foo 1)
           (tail-call 0 bar 1)) ())"]
      \\ thaw of a freeze.
      ["(defun f (X) (thaw (freeze (foo X))))" []
       "(code f 1 5 () ((closure 4 0 2) (tail-call-value 3 0))
          ((code freeze 0 3 () ((capture 2 0) (tail-call 0 foo 1)) ())))"]
      \\ A dynamic call with two arguments is ((X Y) 3): one call when X takes
      \\ both at once, else one argument at a time.
      ["(defun f (X Y) (X Y 3))" []
       "(code f 2 8 (3)
          ((move 5 2) (move 6 3) (const 7 0) (jump-unless-entry 2 2 0) (tail-call-value 4 2)
           (label 0) (move 6 2) (move 7 3) (call-value 4 5 1) (move 6 4) (const 7 0)
           (tail-call-value 5 1)) ())"]
      \\ A lexically bound head is a dynamic call, even when it names a primitive.
      ["(defun f (hd) (hd 1))" []
       "(code f 1 6 (1) ((move 4 2) (const 5 0) (tail-call-value 3 1)) ())"]
      \\ 8 and 8.0 are distinct constants; equal strings are shared.
      [[defun f [] [cons 8 [cons (+ 7.5 0.5) [cons 8 [cons "s" "s"]]]]] []
       [code f 0 3 [8 (+ 7.5 0.5) "s"]
        [[prim 2 cons [const 2] [const 2]] [prim 2 cons [const 0] 2]
         [prim 2 cons [const 1] 2] [prim 2 cons [const 0] 2] [return 2]] []]]
      \\ A chain with constant heads takes one slot, but not a parameter's.
      ["(defun f (X) (let Y (cons a (cons b X)) (foo (cons c (cons d Y)))))" [[foo | 1]]
       "(code f 1 5 (a b c d)
          ((prim 3 cons (const 1) 2) (prim 3 cons (const 0) 3) (prim 4 cons (const 3) 3)
           (prim 2 cons (const 2) 4) (tail-call-sealed 0 foo 1)) ())"]
      \\ An expression for eval-kl; type is erased.
      ["(type (+ 1 2) number)" []
       "(code eval-kl 0 2 (3) ((return (const 0))) ())"]
      ])

\\ Malformed inputs that must raise (lower-case variables: the Shen reader
\\ rejects some of these shapes).
(define shen-jit.check.malformed
  -> [[defun f [x 1] x]
      [defun f [x x] x]
      [defun f x x]
      [defun hd [x] x]
      [defun do [x y] y]
      [defun f [x] [lambda x y x]]
      [defun f [x] [lambda [x] x]]
      [defun f [x] [let [x] 1 x]]
      [defun f [x] [let x 1]]
      [defun f [x] [defun g [] 1]]
      [defun f [x] [hd x x]]
      [defun f [x] [if x 1]]
      [defun f [x] [cond [x]]]
      [eval-kl 1 2]])

\\ Broken code objects the checker itself must reject.
(define shen-jit.check.broken
  -> ["(code f 0 4 () ((return 3)) ())"
      "(code f 0 6 (1) ((const 2 0) (call 3 2 foo 0) (return 2)) ())"
      "(code f 0 4 (1) ((push-handler 0) (const 2 0) (return 2) (label 0) (exception 2) (return 2)) ())"
      "(code f 0 5 (1) ((push-handler 0) (const 2 0) (const 3 0) (pop-handler) (return 2) (label 0) (exception 4) (return 3)) ())"
      "(code f 0 4 (1) ((const 2 0) (exception 3) (return 2)) ())"
      "(code f 0 4 (1) ((label 0) (const 2 0) (jump 0)) ())"
      "(code f 0 4 (1) ((const 2 0)) ())"
      "(code f 0 4 (1) ((const 2 0) (jump-if-false 2 0) (label 0) (label 0) (return 2)) ())"
      "(code f 0 4 (1) ((const 2 0) (prim 3 cons 2) (return 3)) ())"
      "(code f 0 4 () ((capture 2 0) (return 2)) ())"
      "(code f 0 4 () ((call 2 2 foo 1) (return 2)) ())"
      "(code f 1 4 () ((move 2 2) (return 2)) ())"
      "(code f 1 4 (1) ((const 2 0) (move 3 2) (return 3)) ())"
      "(code f 1 4 () ((tail-call 0 foo 2)) ())"
      "(code f 0 4 () ((tail-call-value 0 0)) ())"
      "(code f 0 4 () ((call-sealed 2 2 hd 1) (return 2)) ())"])

(define shen-jit.check.must-reject
  Code -> (let Before (value shen-jit.check.*failures*)
               Quiet (set shen-jit.check.*quiet* true)
               Checked (shen-jit.check.code broken (shen-jit.check.form Code) 0 top)
               Loud (set shen-jit.check.*quiet* false)
               Rejected (> (value shen-jit.check.*failures*) Before)
            (do (set shen-jit.check.*failures* Before)
                (shen-jit.check.assert Rejected "checker" "accepted broken code" Code))))

(define shen-jit.check.form
  S -> (hd (shen-jit.check.read-all (shen.str->bytes S))) where (string? S)
  X -> X)

(define shen-jit.check.run-units
  -> (do (map (/. U (shen-jit.check.unit U)) (shen-jit.check.units))
         (shen-jit.check.inline-units)
         (map (/. M (shen-jit.check.must-fail M)) (shen-jit.check.malformed))
         (map (/. C (shen-jit.check.must-reject C)) (shen-jit.check.broken))
         (output "unit cases: ~A, malformed cases: ~A, broken codes: ~A~%"
                 (length (shen-jit.check.units)) (length (shen-jit.check.malformed))
                 (length (shen-jit.check.broken)))))

(define shen-jit.check.unit
  [Form Sealed Expected]
  -> (let Arities (map (/. P (put (hd P) shen-jit.check.arity (tl P))) Sealed)
          Got (stage0.lower.toplevel (shen-jit.check.form Form) (map (function hd) Sealed))
          Code (if (= (hd Got) defun) (shen-jit.check.without-inline (hd (tl (tl Got)))) Got)
       (do (shen-jit.check.assert (shen-jit.check.same? Code (shen-jit.check.form Expected))
                                    "unit" "unexpected lowering" [Form Got])
           (shen-jit.check.lowered Got)
           (shen-jit.check.normalized (shen-jit.check.form Form))
           (map (/. P (put (hd P) shen-jit.check.arity -1)) Sealed))))

\\ Inlining: a call to a sealed g with an inline body becomes the body. The
\\ argument goes to a fresh variable, then to g's parameter, both sharing its
\\ slot, as any let of one variable to another does. Recursive bodies,
\\ closures and real literals are never inlined.
(define shen-jit.check.inline-units
  -> (do (set shen-jit.host.sealed [g])
         (set shen-jit.host.inline [[g [y] [cons y y]]])
         (shen-jit.check.unit ["(defun f (X) (g (hd X)))" [[g | 1]]
                                 "(code f 1 5 () ((prim 3 hd 2) (prim 4 cons 3 3) (return 4)) ())"])
         (shen-jit.check.unit ["(defun f (X) (let Y X (let Z Y (cons Z Y))))" []
                                 "(code f 1 4 () ((prim 3 cons 2 2) (return 3)) ())"])
         (shen-jit.host.set-tables [])
         (shen-jit.check.assert (= [[] [[y] [lambda z y]] [] [[y] [cons y 2]]]
                                     [(stage0.lower.inline-form g [y] [g y])
                                      (stage0.lower.inline-form g [y] [lambda z y])
                                      (stage0.lower.inline-form g [y] [cons y 1.5])
                                      (stage0.lower.inline-form g [y] [cons y 2])])
                                  "unit" "inline bodies" g)))

\\ A defun's code ends with its inline body; the units compare the rest.
(define shen-jit.check.without-inline
  [code N A F K I Codes | _] -> [code N A F K I Codes])

(define shen-jit.check.must-fail
  Form -> (trap-error (do (stage0.lower.toplevel (shen-jit.check.form Form) [])
                          (shen-jit.check.fail "malformed" "no error for" Form))
                      (/. E (output "  rejected: ~A~%" (error-to-string E)))))

(define shen-jit.check.lowered
  [defun F Code] -> (shen-jit.check.code F Code 0 top)
  Code -> (shen-jit.check.code toplevel Code 0 top))

\\ ---------------------------------------------------------------------------
\\ Main

(define shen-jit.check.main
  [_ In Out | _] -> (shen-jit.check.all In Out)
  _ -> (shen-jit.check.all ".deps/kernel/klambda/" "build/stage0/"))

(define shen-jit.check.all
  In Out
  -> (let Read (map (/. F [(hd F) | (shen-jit.check.defuns (read-from-string-unprocessed
                                                                  (read-file-as-string (hd (tl F)))))])
                      (append (map (/. F [F (cn In (cn F ".kl"))]) (shen-jit.check.files))
                              [["shen-jit" "build/port/shen-jit.kl"]
                               ["lower" "build/port/lower.kl"]]))
          Inputs (shen-jit.check.select-overrides Read)
          Defuns (mapcan (/. I (tl I)) Inputs)
          Sealed (map (/. D (hd (tl D))) Defuns)
          Arities (map (/. D (put (hd (tl D)) shen-jit.check.arity (length (hd (tl (tl D))))))
                       Defuns)
          Tables (shen-jit.host.set-tables Defuns)
          Compared (map (/. I (shen-jit.check.compare-file I Out Sealed)) Inputs)
          Units (shen-jit.host.set-tables [])
       (do (shen-jit.check.run-units)
           (output "~A failures~%" (value shen-jit.check.*failures*)))))

\\ As stage 0: a port defun replaces the kernel defun of the same name.
(define shen-jit.check.select-overrides
  Inputs -> (let Port (mapcan (/. I (if (= (hd I) "shen-jit") (tl I) [])) Inputs)
                 Names (map (/. D (hd (tl D))) Port)
              (map (/. I (if (= (hd I) "shen-jit")
                             I
                             [(hd I) | (stage0.filter (/. D (not (element? (hd (tl D)) Names))) (tl I))]))
                   Inputs)))

(define shen-jit.check.compare-file
  [File | Defuns] Out Sealed
  -> (let Expected (map (/. D (stage0.lower.defun D Sealed)) Defuns)
          Read (shen-jit.check.read-sbc (cn Out (cn File ".sbc")))
       (do (shen-jit.check.assert (shen-jit.check.same? Read Expected) File
                                    "sbc file differs from the lowering" File)
           (map (/. D (shen-jit.check.lowered D)) Read)
           (map (/. D (shen-jit.check.normalized D)) Defuns)
           (output "~A: ~A defuns checked~%" File (length Read)))))

(shen-jit.check.main (value *argv*))

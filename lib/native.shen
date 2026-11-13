\\ Native code written by hand: a Shen program builds a procedure from the
\\ instructions of docs/bytecode.md, checked before the JIT sees them. It stays out of
\\ the image until asked for; load this file under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/native.shen -l program.shen
\\
\\ (define-native sum-list (Xs Acc)
\\   (prim T cons? Xs)
\\   (jump-if-false T done)
\\   (prim H hd Xs)
\\   (prim Acc + Acc H)
\\   (prim Xs tl Xs)
\\   (tail-call sum-list Xs Acc)
\\   (label done)
\\   (return Acc))
\\
\\ Names follow Shen: a variable is a slot, a symbol is itself, and anything else
\\ is a constant, so [1 2] is a list. (const E) is the value of E, at definition, which
\\ code can hold only if it is a symbol, number, string, boolean or list of them.
\\ See docs/bytecode.md, "Native code written by hand".
\\
\\ Real registers hold doubles, unboxed, and word registers 64-bit integers that wrap, in code
\\ that calls nothing and catches nothing:
\\
\\ (define-native dot (A B End)
\\   (real Acc 0)
\\   (word I 0)
\\   (loop terms)
\\   (jump-unless-word (< I End) done)
\\   (real Acc (+ Acc (* (f64 A I) (f64 B I))))
\\   (word I (+ I 8))
\\   (again terms)
\\   (label done)
\\   (return-real Acc))
\\
\\ if, when, unless, do, while, for, block, exit and next write loops and branches without labels,
\\ and become them: see "Structured control" below and docs/bytecode.md.
\\
\\ Code a program generates is data, lists and not forms: (shen-jit.assemble Name
\\ Params Body) gives the code object for instructions in the same shape, and
\\ (shen-jit.install-code Form) checks and installs one. shen-jit.install, which
\\ eval-kl uses, checks only operand shapes: wrong code given to it can crash.
\\
\\ src/lowerer/check.shen loads this file for the rules, to hold the lowerer's
\\ output to them too, and defines its own versions of the next five functions.

(shen.x.namespace shen-jit
  \\ This extends the runtime namespace, which stays open for its primitives and other libraries.
  (use shen-jit.lower)
  (externals [!= abs again back bit-and bit-not bit-or bit-xor block call-sealed call-value
    capture closure code const dead define-native done entry exit f64 f64! for jump jump-if-false
    jump-unless jump-unless-entry jump-unless-test jump-unless-word label loop move neg nested
    new next none param pop-handler prim push-handler raise-cond real real! real* real+ real-
    real-abs real-box real-from-word real-load real-load-at real-move real-neg real-number
    real-sqrt real-store real-store-at real-unless< real-unless<= real-unless= real-unless>
    real-unless>= real/ return-real return-word rotate-left rotate-right s32 shift-left
    shift-right shift-right-signed skip slot! sqrt tagged tail-call tail-call-sealed
    tail-call-value top truncate u16 u16! u32 u32! u64 u64! u8 u8! u< u<= u> u>= unless while
    word word! word* word+ word- word-and word-box word-from-real word-load-s32 word-load16
    word-load32 word-load64 word-load8 word-move word-number word-or word-rotl word-rotr word-sar
    word-shl word-shr word-store16 word-store32 word-store64 word-store8 word-unless-u<
    word-unless-u<= word-unless-u> word-unless-u>= word-unless< word-unless<= word-unless=
    word-unless> word-unless>= word-xor])

(define check.fail
  Where Message X -> (simple-error (make-string "native code, ~A: ~A: ~R" Where Message X)))

\\ A constant may be any value: the collector sees the constants.
(define check.literal?
  _ -> true)

(define check.sealed?
  F _ -> (sealed? F))

(define check.open?
  F -> (and (shen-jit.symbol? F) (not (shen-jit.lower.fixed? F))))

\\ On entry with N arguments: slot 1 and the parameters are set.
(define check.entry-state
  N -> (let Params (check.range 2 (+ N 1))
         [[1 | Params] | []]))

(define check.assert
  true _ _ _ -> true
  false Where Message X -> (check.fail Where Message X))

\\ ---------------------------------------------------------------------------
\\ Structural checks. Ctx is [Where Arity Frame NConstants NCodes NCaptures].

(define check.code
  Where [code Name Arity Frame Constants Instructions Codes | _] NCaptures Kind
  -> (let Ctx [Where Arity Frame (length Constants) (length Codes) NCaptures Constants]
          Labels (check.labels Instructions)
          Handlers (mapcan (/. I (check.handler-target I)) Instructions)
       (do (check.header Where Name Arity Frame Kind)
           (map (/. K (check.assert (check.literal? K) Where
                                               "constant is not a literal" K))
                Constants)
           (check.assert (check.distinct? Labels) Where
                                    "label defined twice" Labels)
           (map (/. I (check.instruction Ctx Labels I)) Instructions)
           (check.handlers Where none Instructions Handlers)
           (check.reals Where Instructions)
           (check.flow Where Arity Instructions (+ 1 (check.max Labels -1)))
           (check.nested Where Instructions Codes)))
  Where X _ _ -> (check.fail Where "malformed code object" X))

(define check.header
  Where Name Arity Frame Kind
  -> (check.assert
       (and (integer? Arity) (>= Arity 0) (integer? Frame) (>= Frame (+ Arity 2))
            (cond ((= Kind top) (and (symbol? Name) (not (element? Name [lambda freeze]))))
                  ((= Name lambda) (= Arity 1))
                  ((= Name freeze) (= Arity 0))
                  (true false)))
       Where "bad code header" [Name Arity Frame Kind]))

(define check.labels
  Instructions -> (mapcan (/. I (if (element? (hd I) [label loop]) (tl I) [])) Instructions))

(define check.handler-target
  [push-handler L] -> [L]
  _ -> [])

(define check.distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (check.distinct? Xs)))

(define check.max
  [] M -> M
  [X | Xs] M -> (check.max Xs (if (> X M) X M)))

(define check.prim-arity
  raise-cond -> 0
  F -> (shen-jit.lower.prim-arity F))

(define check.instruction
  Ctx Labels I -> (check.assert (check.valid? Ctx Labels I)
                                           (hd Ctx) "bad instruction" I))

(define check.valid?
  Ctx _ [move D S] -> (and (check.write? Ctx D) (check.read? Ctx S))
  Ctx _ [const D K] -> (and (check.write? Ctx D) (check.below? K (nth 4 Ctx)))
  Ctx _ [capture D I] -> (and (check.write? Ctx D) (check.below? I (nth 6 Ctx)))
  Ctx _ [closure D C | Ss] -> (and (check.write? Ctx D) (check.below? C (nth 5 Ctx))
                                   (check.reads? Ctx Ss))
  Ctx _ [prim D Op | Ss] -> (and (check.write? Ctx D) (check.operands? Ctx Ss)
                                 (= (length Ss) (check.prim-arity Op)))
  _ _ [label L] -> (integer? L)
  _ Labels [jump L] -> (element? L Labels)
  Ctx Labels [jump-if-false S L] -> (and (check.operand? Ctx S) (element? L Labels))
  Ctx _ [call D A F N] -> (and (check.write? Ctx D) (check.window? Ctx A N)
                               (check.open? F))
  Ctx _ [call-sealed D A F N] -> (and (check.write? Ctx D) (check.window? Ctx A N)
                                      (check.sealed? F N))
  Ctx _ [call-value D A N] -> (and (check.write? Ctx D) (check.window? Ctx A N))
  Ctx _ [tail-call A F N] -> (and (check.tail-window? Ctx A N) (check.open? F))
  Ctx _ [tail-call-sealed A F N] -> (and (check.tail-window? Ctx A N) (check.sealed? F N))
  Ctx _ [tail-call-value A N] -> (check.window? Ctx A N)
  [_ Arity Frame | _] Labels [entry N L] -> (and (integer? N) (> N Arity) (< (+ N 1) Frame)
                                                 (element? L Labels))
  Ctx Labels [jump-unless-entry S N L] -> (and (check.read? Ctx S) (integer? N) (>= N 2)
                                               (element? L Labels))
  Ctx _ [return S] -> (check.operand? Ctx S)
  _ Labels [push-handler L] -> (element? L Labels)
  _ _ [pop-handler] -> true
  _ _ [inline F N] -> (and (symbol? F) (integer? N) (> N 0))
  Ctx _ [exception D] -> (check.write? Ctx D)
  Ctx Labels [Op | Args] -> (check.raw-valid? Ctx Labels (check.shape Op) Args)
  _ _ _ -> false)

\\ The instructions on real and word registers, by what each operand is: a tagged operand read, a
\\ slot written, a real register read or written, a word register or constant read, a word
\\ register written, a label, a loop's head, or the loop to go back to. As raw_kinds in ops.h.
(define check.shape
  loop -> [head]
  again -> [back]
  real-number -> [real! tagged]
  real-box -> [slot! real]
  real-load -> [real! tagged tagged]
  real-store -> [tagged tagged real]
  real-load-at -> [real! tagged word]
  real-store-at -> [tagged word real]
  real-from-word -> [real! word]
  word-from-real -> [word! real]
  word-number -> [word! tagged]
  word-box -> [slot! word]
  word-move -> [word! word]
  Op -> [real! real] where (element? Op [real-move real-neg real-abs real-sqrt])
  Op -> [real! real real] where (element? Op [real+ real- real* real/])
  Op -> [real real label] where (element? Op [real-unless< real-unless> real-unless<= real-unless>= real-unless=])
  Op -> [word! word word] where (element? Op [word+ word- word* word-and word-or word-xor
                                              word-shl word-shr word-sar word-rotl word-rotr])
  Op -> [word word label] where (element? Op [word-unless< word-unless> word-unless<= word-unless>= word-unless=
                                              word-unless-u< word-unless-u> word-unless-u<= word-unless-u>=])
  Op -> [word! tagged word] where (element? Op [word-load8 word-load16 word-load32 word-load-s32 word-load64])
  Op -> [tagged word word] where (element? Op [word-store8 word-store16 word-store32 word-store64])
  _ -> none)

(define check.raw-valid?
  _ _ none _ -> false
  _ _ [] [] -> true
  Ctx Labels [K | Ks] [A | As] -> (and (check.raw-operand? Ctx Labels K A)
                                       (check.raw-valid? Ctx Labels Ks As))
  _ _ _ _ -> false)

\\ As REAL_REGISTERS and WORD_REGISTERS in ops.h.
(define check.raw-operand?
  Ctx _ tagged A -> (check.operand? Ctx A)
  Ctx _ slot! A -> (check.write? Ctx A)
  _ _ real A -> (check.below? A 48)
  _ _ real! A -> (check.below? A 48)
  _ _ word! A -> (check.below? A 16)
  Ctx _ word [const K] -> (and (check.below? K (nth 4 Ctx)) (integer? (nth (+ K 1) (nth 7 Ctx))))
  _ _ word A -> (check.below? A 16)
  _ Labels label A -> (element? A Labels)
  _ _ head A -> (integer? A)
  _ Labels back A -> (element? A Labels))

(define check.raw-op?
  [Op | _] -> (not (= (check.shape Op) none)))

\\ Raw registers and loops are only for code that calls nothing and catches nothing: nothing
\\ saves a register across a call, and a handler would find them as a raise left them.
(define check.reals
  Where Is -> (if (check.any-raw? Is)
                  (map (/. I (check.assert
                               (not (element? (hd I) [call call-sealed call-value push-handler pop-handler
                                                      exception entry jump-unless-entry]))
                               Where "raw registers or loops with a call or a handler" I))
                       Is)
                  skip))

(define check.any-raw?
  [] -> false
  [I | Is] -> (or (check.raw-op? I) (check.any-raw? Is)))

(define check.below?
  I N -> (and (integer? I) (>= I 0) (< I N)))

\\ Writes never touch the return address, the procedure or the parameters.
(define check.write?
  [_ _ Frame | _] D -> (and (integer? D) (>= D 2) (< D Frame)))

(define check.read?
  [_ _ Frame | _] S -> (and (integer? S) (>= S 2) (< S Frame)))

\\ An operand is a slot to read, or (const K) for a constant of the code.
(define check.operand?
  Ctx [const K] -> (check.below? K (nth 4 Ctx))
  Ctx S -> (check.read? Ctx S))

(define check.operands?
  Ctx Ss -> (or (empty? Ss) (and (check.operand? Ctx (hd Ss))
                                 (check.operands? Ctx (tl Ss)))))

(define check.reads?
  Ctx Ss -> (or (empty? Ss) (and (check.read? Ctx (hd Ss))
                                 (check.reads? Ctx (tl Ss)))))

\\ Windows lie above the parameters and inside the frame: A+1+N < FrameSize.
(define check.window?
  [_ Arity Frame | _] A N -> (and (integer? A) (integer? N) (>= N 0) (>= A (+ Arity 2))
                                  (< (+ A (+ 1 N)) Frame)))

\\ A named tail call may also use window 0: its arguments are then already in
\\ slots 2 to N+1.
(define check.tail-window?
  [_ _ Frame | _] 0 N -> (and (integer? N) (>= N 0) (< (+ 1 N) Frame))
  Ctx A N -> (check.window? Ctx A N))

\\ exception follows only a handler label. A handler label without it is a
\\ quiet handler, which never reads the exception (docs/bytecode.md).
(define check.handlers
  _ _ [] _ -> true
  Where Prev [[exception D] | Is] Handlers
  -> (do (check.assert (check.handler-label? Prev Handlers) Where
                                  "exception not at a handler label" [exception D])
         (check.handlers Where [exception D] Is Handlers))
  Where _ [I | Is] Handlers -> (check.handlers Where I Is Handlers))

(define check.handler-label?
  [label L] Handlers -> (element? L Handlers)
  _ _ -> false)

\\ Every nested code is created by exactly one closure instruction and checked
\\ with that closure's capture count.
(define check.nested
  Where Instructions Codes
  -> (let Closures (mapcan (/. I (if (= (hd I) closure) [I] [])) Instructions)
          Used (map (/. I (hd (tl (tl I)))) Closures)
       (do (check.assert (and (= (length Used) (length Codes)) (check.distinct? Used))
                                    Where "nested codes not used exactly once" Used)
           (map (/. I (check.code (cn (str Where) "/") (nth (+ 1 (hd (tl (tl I)))) Codes)
                                             (length (tl (tl (tl I)))) nested))
                Closures))))

\\ ---------------------------------------------------------------------------
\\ Dataflow. A state is [Defined | Handlers] or dead; Pending holds, per
\\ label, the merged state of the jumps (and raises) to it, or done once the
\\ label is passed, so a backward jump is caught, or for a loop's head, the state
\\ there, as [head | State]. Only again goes back, and has to bring all of that
\\ state back with it, so that a single pass is enough. Defined also holds
\\ [param P] for each parameter slot, and [new P] once P is written: only a
\\ tail call with window 0 may then read P, as its argument.

(define check.flow
  Where Arity Instructions NLabels
  -> (let Pending (check.fill (absvector NLabels) 0 NLabels none)
          Final (check.flow-h Where Instructions (check.entry-state Arity) Pending [])
       (check.assert (= Final dead) Where "code falls off the end" Final)))

(define check.fill
  V I N X -> V where (= I N)
  V I N X -> (check.fill (address-> V I X) (+ I 1) N X))

(define check.range
  I J -> [] where (> I J)
  I J -> [I | (check.range (+ I 1) J)])

\\ Order is the handlers active by the order of the code, which is how the JIT
\\ tracks them: it must agree with the handlers active on every path here.
(define check.flow-h
  _ [] State _ _ -> State
  Where [[label L] | Is] State Pending Order
  -> (let Merged (check.merge Where State (<-address Pending L))
       (do (address-> Pending L done)
           (check.flow-h Where Is Merged Pending Order)))
  Where [I | Is] dead Pending Order
  -> (do (check.fail Where "unreachable instruction" I)
         (check.flow-h Where Is dead Pending (check.in-order I Order)))
  Where [I | Is] [Defined | Handlers] Pending Order
  -> (do (check.assert (check.readable? I (check.used I) Defined)
                                  Where "reads an unset or clobbered slot" I)
         (check.assert (= Handlers Order) Where "handlers do not nest in code order" I)
         (check.raise Where I [Defined | Handlers] Pending)
         (check.flow-h Where Is (check.step Where I [Defined | Handlers] Pending)
                                  Pending (check.in-order I Order))))

(define check.in-order
  [push-handler L] Order -> [L | Order]
  [pop-handler] [_ | Order] -> Order
  _ Order -> Order)

(define check.merge
  Where _ done -> (do (check.fail Where "label reached twice" done) dead)
  _ dead none -> dead
  _ State none -> State
  _ dead State -> State
  Where [D1 | H1] [D2 | H2]
  -> (do (check.assert (= H1 H2) Where "handler stacks differ at a join" [H1 H2])
         [(append (check.intersection D1 D2)
                  (check.new-on-one D1 D2) (check.new-on-one D2 D1))
          | H1]))

\\ A parameter written on one path and unchanged on the other.
(define check.new-on-one
  D1 D2 -> (mapcan (/. X (if (and (cons? X) (= (hd X) new) (element? (hd (tl X)) D2)) [X] [])) D1))

(define check.readable?
  [Op 0 | _] Used Defined -> (check.arguments? Used Defined)
      where (element? Op [tail-call tail-call-sealed])
  _ Used Defined -> (check.subset? Used Defined))

(define check.arguments?
  [] _ -> true
  [S | Ss] Defined -> (and (or (element? S Defined) (element? [new S] Defined))
                           (check.arguments? Ss Defined)))

\\ Writing a parameter slot makes it [new P].
(define check.set
  D Defined -> (adjoin [new D] (remove D Defined)) where (element? [param D] Defined)
  D Defined -> (adjoin D Defined))

(define check.propagate
  Where L State Pending
  -> (if (check.passed? (<-address Pending L))
         (check.fail Where "backward jump" L)
         (address-> Pending L (check.merge Where State (<-address Pending L)))))

(define check.passed?
  done -> true
  [head | _] -> true
  _ -> false)

(define check.loop-head
  Where L State Pending
  -> (do (check.assert (= (<-address Pending L) none) Where "a jump into a loop's head" L)
         (address-> Pending L [head | State])
         State))

(define check.back
  Where L [Defined | Handlers] Pending -> (check.back-to Where L (<-address Pending L) Defined Handlers))

(define check.back-to
  Where L [head Was | Handlers] Defined Handlers
  -> (do (check.assert (check.subset? Was Defined) Where
                                "going back without what the loop's head has" [L Was Defined])
         dead)
  Where L _ _ _ -> (do (check.fail Where "again without its loop before it" L) dead))

\\ Slots an instruction reads; constant operands read none.
(define check.used
  [move _ S] -> [S]
  [closure _ _ | Ss] -> Ss
  [prim _ _ | Ss] -> (check.slots Ss)
  [jump-if-false S _] -> (check.slots [S])
  [jump-unless-entry S _ _] -> [S]
  [call _ A _ N] -> (check.range (+ A 2) (+ A (+ 1 N)))
  [call-sealed _ A _ N] -> (check.range (+ A 2) (+ A (+ 1 N)))
  [call-value _ A N] -> (check.range (+ A 1) (+ A (+ 1 N)))
  [tail-call A _ N] -> (check.range (+ A 2) (+ A (+ 1 N)))
  [tail-call-sealed A _ N] -> (check.range (+ A 2) (+ A (+ 1 N)))
  [tail-call-value A N] -> (check.range (+ A 1) (+ A (+ 1 N)))
  [return S] -> (check.slots [S])
  [Op | Args] -> (check.raw-used (check.shape Op) Args))

(define check.raw-used
  none _ -> []
  [] _ -> []
  [tagged | Ks] [A | As] -> (append (check.slots [A]) (check.raw-used Ks As))
  [real | Ks] [A | As] -> [[real A] | (check.raw-used Ks As)]
  [word | Ks] [[const _] | As] -> (check.raw-used Ks As)
  [word | Ks] [A | As] -> [[word A] | (check.raw-used Ks As)]
  [_ | Ks] [_ | As] -> (check.raw-used Ks As)
  _ _ -> [])

(define check.slots
  Ss -> (mapcan (/. S (if (integer? S) [S] [])) Ss))

\\ A call clobbers every slot from its window up.
(define check.window-base
  [call _ A | _] -> A
  [call-sealed _ A | _] -> A
  [call-value _ A _] -> A
  _ -> -1)

\\ Anything but a jump or handler bookkeeping may raise: the innermost handler
\\ then starts with the slots set so far, minus those a call clobbers.
(define check.raise
  _ [Op | _] _ _ -> skip where (element? Op [jump push-handler pop-handler exception entry
                                              jump-unless-entry inline])
  _ _ [_ | []] _ -> skip
  Where I [Defined L | Handlers] Pending
  -> (check.propagate Where L [(check.clobber Defined (check.window-base I))
                                          | Handlers] Pending))

(define check.clobber
  Defined -1 -> Defined
  Defined A -> (mapcan (/. S (if (or (cons? S) (< S A)) [S] [])) Defined))

(define check.step
  Where [jump L] State Pending -> (do (check.propagate Where L State Pending) dead)
  Where [jump-if-false _ L] State Pending -> (do (check.propagate Where L State Pending) State)
  Where [jump-unless-entry _ _ L] State Pending
  -> (do (check.propagate Where L State Pending) State)
  Where [entry N L] State Pending
  -> (do (check.propagate Where L (check.entry-state N) Pending) State)
  Where [loop L] State Pending -> (check.loop-head Where L State Pending)
  Where [again L] State Pending -> (check.back Where L State Pending)
  Where [Op | Args] State Pending -> (check.raw-step Where (check.shape Op) Args State Pending)
      where (not (= (check.shape Op) none))
  Where [return S] [_ | Handlers] _ -> (check.leave Where [return S] Handlers)
  Where [Op | X] [_ | Handlers] _ -> (check.leave Where [Op | X] Handlers)
      where (element? Op [tail-call tail-call-sealed tail-call-value])
  _ [push-handler L] [Defined | Handlers] _ -> [Defined L | Handlers]
  _ [inline _ _] State _ -> State
  Where [pop-handler] [Defined | Handlers] _
  -> (if (empty? Handlers)
         (do (check.fail Where "pop-handler without handler" Defined) dead)
         [Defined | (tl Handlers)])
  _ [Op D | X] [Defined | Handlers] Pending
  -> (do (check.forget D Handlers Pending)
         [(check.set D (check.clobber Defined (check.window-base [Op D | X])))
          | Handlers])
      where (element? Op [move const capture closure prim call call-sealed call-value exception])
  Where I State _ -> (do (check.fail Where "unknown instruction" I) State))

(define check.raw-step
  _ [] [] State _ -> State
  Where [real! | Ks] [A | As] [Defined | Handlers] Pending
  -> (check.raw-step Where Ks As [(adjoin [real A] Defined) | Handlers] Pending)
  Where [word! | Ks] [A | As] [Defined | Handlers] Pending
  -> (check.raw-step Where Ks As [(adjoin [word A] Defined) | Handlers] Pending)
  Where [slot! | Ks] [A | As] [Defined | Handlers] Pending
  -> (do (check.forget A Handlers Pending)
         (check.raw-step Where Ks As [(check.set A Defined) | Handlers] Pending))
  Where [label | Ks] [A | As] State Pending
  -> (do (check.propagate Where A State Pending)
         (check.raw-step Where Ks As State Pending))
  Where [_ | Ks] [_ | As] State Pending -> (check.raw-step Where Ks As State Pending))


\\ A handler reads no slot written since its push: the JIT does not store a test's
\\ result that the code after the test never reads.
(define check.forget
  _ [] _ -> skip
  D [L | Ls] Pending -> (let S (<-address Pending L)
                          (do (if (cons? S) (address-> Pending L [(remove D (hd S)) | (tl S)]) skip)
                              (check.forget D Ls Pending))))

(define check.leave
  Where I Handlers -> (do (check.assert (empty? Handlers) Where "leaves with a handler" I)
                          dead))

(define check.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (check.subset? Xs Ys)))

(define check.intersection
  Xs Ys -> (mapcan (/. X (if (element? X Ys) [X] [])) Xs))

\\ ---------------------------------------------------------------------------
\\ The builder. Slots are numbered from 2: the parameters, then the other variables
\\ as they first appear, and call windows above them all.

\\ A later call in the same file compiles directly if the name's arity is known when
\\ it is read, as for define.
(defmacro native-macro
  [define-native Name Params | Body]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name (length Params))
             skip)
         [native.define Name (native.list Params) (native.list Body)]))

\\ Forms that evaluate to the instructions as data. (const E) stays an expression, and
\\ so does what the reader made of a list in brackets, as a constant.
(define native.data
  [const E] -> [cons const [cons E []]]
  [cons X Y] -> [cons const [cons [cons X Y] []]]
  [X | Y] -> (native.list [X | Y])
  X -> [protect X] where (variable? X)
  X -> X)

(define native.list
  [] -> []
  [X | Y] -> [cons (native.data X) (native.list Y)])

\\ As assemble and install-code, with the slots named in any error.
(define native.define
  Name Params Body
  -> (let Code (assemble Name Params Body)
       (trap-error
         (install-code [defun Name Code])
         (/. E (simple-error (make-string "~A~%slots: ~R" (error-to-string E)
                                          (shen-jit.lower.bind (native.slots Params [] (real.expand (expand-native Body))) 2)))))))

(define assemble
  Name Params Body -> (native.code Name Params [] Body))

(define native.code
  Name Params Captures Written
  -> (let Body (real.expand (expand-native Written))
          B (shen-jit.lower.builder Name (length Params) [])
          Named (native.slots Params Captures Body)
          Window (+ 2 (length Named))
          C [B (append (shen-jit.lower.bind Named 2) (real.registers Name Named Body))
               (native.labels Body) Window]
       (do (if (check.distinct? (append Params Captures))
               skip
               (simple-error (make-string "native code, ~A: a name given twice: ~R" Name [Params Captures])))
           (shen-jit.lower.reserve B (- Window 1))
           (native.captures C Captures 0)
           (map (/. I (native.insn C I)) Body)
           (shen-jit.lower.code-form B))))

(define native.slots
  Params Captures Body
  -> (native.add-names (mapcan (/. I (native.uses I)) Body)
                                (append Params Captures)))

(define native.add-names
  [] Named -> Named
  [X | Xs] Named -> (native.add-names Xs Named)
      where (or (not (variable? X)) (element? X Named))
  [X | Xs] Named -> (native.add-names Xs (append Named [X])))

(define native.uses
  [move D O] -> [D O]
  [prim D _ | Os] -> [D | Os]
  [jump-if-false O _] -> [O]
  [call D F | Os] -> [D F | Os]
  [tail-call F | Os] -> [F | Os]
  [return O] -> [O]
  [closure D _ Captures | _] -> [D | Captures]
  [exception D] -> [D]
  [Op | Args] -> (native.raw-uses (check.shape Op) Args))

(define native.raw-uses
  none _ -> []
  [] _ -> []
  [K | Ks] [A | As] -> [A | (native.raw-uses Ks As)] where (element? K [tagged slot!])
  [_ | Ks] [_ | As] -> (native.raw-uses Ks As)
  _ _ -> [])

(define native.labels
  Body -> (let Names (check.labels Body)
            (if (check.distinct? Names)
                (shen-jit.lower.bind Names 0)
                (simple-error (make-string "native code: a label given twice: ~R" Names)))))

(define native.find
  Kind Table X -> (let Entry (assoc X Table)
                    (if (cons? Entry)
                        (tl Entry)
                        (simple-error (make-string "native code: no such ~A: ~R" Kind X)))))

(define native.slot
  [_ Slots | _] X -> (native.find "slot" Slots X))

(define native.label
  [_ _ Labels _] X -> (native.find "label" Labels X))

(define native.emit
  [B | _] I -> (shen-jit.lower.emit B I))

(define native.operand
  [B | _] [const X] -> [const (shen-jit.lower.constant B X)]
  C X -> (native.slot C X) where (variable? X)
  _ [X | Y] -> (simple-error (make-string "native code: bad operand: ~R" [X | Y]))
  [B | _] X -> [const (shen-jit.lower.constant B X)])

(define native.operands
  C Os -> (map (/. O (native.operand C O)) Os))

(define native.store
  C D [const K] -> (native.emit C [const D K])
  C D S -> (native.emit C [move D S]))

(define native.captures
  _ [] _ -> skip
  C [X | Xs] I -> (do (native.emit C [capture (native.slot C X) I])
                      (native.captures C Xs (+ I 1))))

(define native.insn
  C [label L] -> (native.emit C [label (native.label C L)])
  C [jump L] -> (native.emit C [jump (native.label C L)])
  C [jump-if-false O L] -> (native.emit C [jump-if-false (native.operand C O)
                                                                  (native.label C L)])
  C [move D O] -> (native.store C (native.slot C D) (native.operand C O))
  C [prim D Op | Os] -> (native.emit C [prim (native.slot C D) Op
                                                      | (native.operands C Os)])
  C [return O] -> (native.emit C [return (native.operand C O)])
  C [call D F | Os] -> (native.value-call C [call-value (native.slot C D)] F Os)
      where (variable? F)
  C [call D F | Os] -> (native.named-call C (native.slot C D) F (native.operands C Os))
  C [tail-call F | Os] -> (native.value-call C [tail-call-value] F Os) where (variable? F)
  C [tail-call F | Os] -> (native.tail-call C F (native.operands C Os))
  C [closure D Params Captures | Body] -> (native.closure C (native.slot C D) Params Captures Body)
  C [push-handler L] -> (native.emit C [push-handler (native.label C L)])
  C [pop-handler] -> (native.emit C [pop-handler])
  C [exception D] -> (native.emit C [exception (native.slot C D)])
  C [Op | Args] -> (native.emit C [Op | (native.raw-args C (check.shape Op) Args)])
      where (not (= (check.shape Op) none))
  _ I -> (simple-error (make-string "native code: unknown instruction: ~R" I)))

(define native.raw-args
  _ [] As -> As
  _ _ [] -> []
  C [tagged | Ks] [A | As] -> [(native.operand C A) | (native.raw-args C Ks As)]
  C [word | Ks] [A | As] -> [(native.operand C A) | (native.raw-args C Ks As)]
  C [K | Ks] [A | As] -> [(native.label C A) | (native.raw-args C Ks As)]
      where (element? K [label head back])
  C [_ | Ks] [A | As] -> [(native.slot C A) | (native.raw-args C Ks As)]
  _ _ X -> (simple-error (make-string "native code: wrong operands: ~R" X)))

\\ Puts operands in the call window's argument slots, from T.
(define native.arguments
  _ [] _ -> skip
  C [X | Xs] T -> (do (native.store C T X)
                      (native.arguments C Xs (+ T 1))))

(define native.named-call
  [B S L Window] D F Os
  -> (do (shen-jit.lower.reserve B (+ Window (+ 1 (length Os))))
         (native.arguments [B S L Window] Os (+ Window 2))
         (native.emit [B S L Window]
                               [(if (sealed? F) call-sealed call) D Window F (length Os)])))

\\ What it takes all at once depends on the value, so one argument at a time.
(define native.value-call
  _ _ _ [_ _ | _] -> (simple-error "native code: a call of a variable takes no or one argument")
  [B S L Window] [Op | D] F Os
  -> (do (shen-jit.lower.reserve B (+ Window (+ 1 (length Os))))
         (native.arguments [B S L Window] (native.operands [B S L Window] Os) (+ Window 2))
         (native.store [B S L Window] (+ Window 1) (native.operand [B S L Window] F))
         (native.emit [B S L Window] (append [Op | D] [Window (length Os)]))))

\\ A tail call's arguments go straight to slots 2.., where the callee expects them,
\\ so a call of the same name loops without moves. One whose slot a later argument
\\ still reads waits above the others until they are done.
(define native.tail-call
  [B S L Window] F Os
  -> (let N (length Os)
       (do (shen-jit.lower.reserve B (+ N 1))
           (map (/. T (native.store [B S L Window] T (+ Window T)))
                (native.tail-arguments [B S L Window] Os 2 []))
           (native.emit [B S L Window]
                                 [(if (sealed? F) tail-call-sealed tail-call) 0 F N]))))

\\ Returns the slots whose arguments wait.
(define native.tail-arguments
  _ [] _ Later -> Later
  C [T | Os] T Later -> (native.tail-arguments C Os (+ T 1) Later)
  [B S L Window] [O | Os] T Later
  -> (do (shen-jit.lower.reserve B (+ Window T))
         (native.store [B S L Window] (+ Window T) O)
         (native.tail-arguments [B S L Window] Os (+ T 1) [T | Later]))
      where (element? T Os)
  C [O | Os] T Later
  -> (do (native.store C T O)
         (native.tail-arguments C Os (+ T 1) Later)))

(define native.closure
  [B S L Window] D Params Captures Body
  -> (let Name (if (empty? Params) freeze lambda)
          Code (native.code Name Params Captures Body)
          I (shen-jit.lower.add-code B Code)
       (native.emit [B S L Window]
                             [closure D I | (map (/. X (native.slot [B S L Window] X)) Captures)])))

\\ ---------------------------------------------------------------------------
\\ Structured control: if, when, unless, do, while, for, block, exit and next, made into the
\\ labels, loops and jumps above, with labels of their own, before anything else. A loop or a
\\ block may be named by a symbol after its keyword; exit leaves the innermost loop or the one
\\ named, and next goes round it again. A test is a comparison, and, or, not, true, false, or a
\\ slot holding a boolean. A comparison becomes jump-unless-test, which the next pass makes a test
\\ of reals if either side is a real register or expression, and of words if not. Nothing here
\\ is checked: what it makes is, like any other instructions.

(set structure.*count* 0)

(define structure.label
  Kind -> (let N (+ 1 (value structure.*count*))
               _ (set structure.*count* N)
            (intern (cn "structure." (cn Kind (cn "." (str N)))))))

(define structure.name?
  X -> (and (symbol? X) (not (variable? X))))

\\ The instructions these statements make. Loops is [[Name Exit Next] ...], innermost first,
\\ with Name [] for one not named and Next none for a block.
(define expand-native
  Body -> (structure.statements Body []))

(define structure.statements
  [] _ -> []
  [S | Ss] Loops -> (append (structure.statement S Loops)
                            (structure.statements Ss Loops)))

(define structure.statement
  \\ A constant test keeps only what runs: the checker refuses code that cannot be reached.
  [if true Then | _] Loops -> (structure.statement Then Loops)
  [if false _] _ -> []
  [if false _ Else] Loops -> (structure.statement Else Loops)
  [when true | Body] Loops -> (structure.statements Body Loops)
  [when false | _] _ -> []
  [unless false | Body] Loops -> (structure.statements Body Loops)
  [unless true | _] _ -> []
  [while false | _] _ -> []
  [while Name false | _] _ -> [] where (structure.name? Name)
  [if Test Then] Loops
  -> (let End (structure.label "end")
       (structure.close
         (append (structure.unless Test End) (structure.statement Then Loops)) End))
  [if Test Then Else] Loops
  -> (let Otherwise (structure.label "else")
          End (structure.label "end")
          First (structure.statement Then Loops)
          Joined (if (structure.ends? First) First (append First [[jump End]]))
       (structure.close
         (append (structure.unless Test Otherwise)
                 Joined
                 [[label Otherwise]]
                 (structure.statement Else Loops))
         End))
  [when Test | Body] Loops
  -> (let End (structure.label "end")
       (structure.close
         (append (structure.unless Test End) (structure.statements Body Loops)) End))
  [unless Test | Body] Loops
  -> (let End (structure.label "end")
       (structure.close
         (append (structure.if Test End) (structure.statements Body Loops)) End))
  [do | Body] Loops -> (structure.statements Body Loops)
  [while Name Test | Body] Loops -> (structure.while Name Test Body Loops) where (structure.name? Name)
  [while Test | Body] Loops -> (structure.while [] Test Body Loops)
  [for Name I From To | Body] Loops -> (structure.for Name I From To Body Loops)
      where (and (structure.name? Name) (variable? I))
  [for I From To | Body] Loops -> (structure.for [] I From To Body Loops) where (variable? I)
  [block Name | Body] Loops
  -> (let Exit (structure.label "exit")
       (structure.close (structure.statements Body [[Name Exit none] | Loops]) Exit))
      where (structure.name? Name)
  [exit] Loops -> [[jump (structure.exit-of (structure.innermost Loops))]]
  [exit Name] Loops -> [[jump (structure.exit-of (structure.named Name Loops))]]
  [next] Loops -> [[jump (structure.next-of (structure.innermost Loops))]]
  [next Name] Loops -> [[jump (structure.next-of (structure.named Name Loops))]]
  [Keyword | Form] _ -> (simple-error (make-string "native code: malformed ~A: ~R" Keyword [Keyword | Form]))
      where (element? Keyword [if when unless while for block exit next])
  S _ -> [S])

\\ Whether code cannot fall through its end, so that what would follow it is reached only by a jump.
(define structure.ends?
  [] -> false
  Code -> (element? (hd (hd (reverse Code))) [jump return return-word return-real tail-call again]))

(define structure.jumps-to?
  _ [] -> false
  L [I | Is] -> true where (and (cons? I) (element? (hd I) [jump jump-if-false jump-unless-test jump-unless jump-unless-word])
                                (= (hd (reverse I)) L))
  L [_ | Is] -> (structure.jumps-to? L Is))

\\ The label L after Code, if anything reaches it.
(define structure.close
  Code L -> (if (and (structure.ends? Code) (not (structure.jumps-to? L Code)))
                Code
                (append Code [[label L]])))

\\ A loop's way round: from where next jumps, what Step does, then back to the head. Not there if
\\ the body never gets that far.
(define structure.round
  Body Next Step Head -> (if (and (structure.ends? Body) (not (structure.jumps-to? Next Body)))
                             Body
                             (append Body [[label Next] | Step] [[again Head]])))

(define structure.while
  Name Test Body Loops
  -> (let Head (structure.label "while")
          Next (structure.label "next")
          Exit (structure.label "exit")
          Inside (structure.statements Body [[Name Exit Next] | Loops])
       (structure.close
         (append [[loop Head]]
                 (structure.round (append (structure.unless Test Exit) Inside) Next [] Head))
         Exit)))

\\ From From up to and not including To, a word at a time.
(define structure.for
  Name I From To Body Loops
  -> (let Head (structure.label "for")
          Next (structure.label "next")
          Exit (structure.label "exit")
          Inside (structure.statements Body [[Name Exit Next] | Loops])
       (structure.close
         (append [[word I From] [loop Head]]
                 (structure.round (append (structure.unless [< I To] Exit) Inside)
                                           Next [[word I [+ I 1]]] Head))
         Exit)))

(define structure.innermost
  [] -> (simple-error "native code: exit or next outside a loop")
  [[Name Exit none] | Loops] -> (structure.innermost Loops)
  [Loop | _] -> Loop)

(define structure.named
  Name [] -> (simple-error (make-string "native code: no loop or block named ~A around here" Name))
  Name [[Name | Rest] | _] -> [Name | Rest]
  Name [_ | Loops] -> (structure.named Name Loops))

(define structure.exit-of
  [_ Exit _] -> Exit)

(define structure.next-of
  [Name _ none] -> (simple-error (make-string "native code: next of ~A, which is a block and not a loop" Name))
  [_ _ Next] -> Next)

(define structure.comparison?
  Op -> (element? Op [< > <= >= = != u< u> u<= u>=]))

\\ Jump to L unless Test holds.
(define structure.unless
  [and | Tests] L -> (mapcan (/. T (structure.unless T L)) Tests)
  [or] L -> [[jump L]]
  [or Test] L -> (structure.unless Test L)
  [or Test | Tests] L -> (let Holds (structure.label "or")
                           (append (structure.if Test Holds)
                                   (structure.unless [or | Tests] L)
                                   [[label Holds]]))
  [not Test] L -> (structure.if Test L)
  [!= A B] L -> (structure.if [= A B] L)
  [Op A B] L -> [[jump-unless-test [Op A B] L]] where (structure.comparison? Op)
  true _ -> []
  false L -> [[jump L]]
  X L -> [[jump-if-false X L]] where (variable? X)
  Test _ -> (simple-error (make-string "native code: not a test: ~R" Test)))

\\ Jump to L if Test holds.
(define structure.if
  [not Test] L -> (structure.unless Test L)
  [or | Tests] L -> (mapcan (/. T (structure.if T L)) Tests)
  true L -> [[jump L]]
  false _ -> []
  Test L -> (let Fails (structure.label "fails")
              (append (structure.unless Test Fails) [[jump L] [label Fails]])))

\\ Whether an operand is a real: a real register, a number that is not an integer, or what only
\\ reals give.
(define structure.real?
  Regs E -> true where (real.real? Regs E)
  _ E -> (not (integer? E)) where (number? E)
  _ [const K] -> (and (number? K) (not (integer? K)))
  _ [Op | _] -> true where (element? Op [f64 sqrt abs /])
  Regs [Op | Args] -> (structure.any-real? Regs Args) where (element? Op [+ - * neg])
  _ _ -> false)

(define structure.any-real?
  _ [] -> false
  Regs [A | As] -> (or (structure.real? Regs A) (structure.any-real? Regs As)))

\\ ---------------------------------------------------------------------------
\\ Raw expressions, as flat instructions. A variable given a value by real or word is a
\\ register of that kind, in a namespace of its own; any other variable in an expression is a
\\ slot, whose number is read with a check. Intermediate values take registers of their own,
\\ named by depth. Regs is [Reals Words].

(define real.expand
  Body -> (let Regs [(real.names real Body) (real.names word Body)]
               _ (map (/. Name (real.own Name)) (append (hd Regs) (hd (tl Regs))))
            (mapcan (/. I (real.statement Regs I)) Body)))

\\ Real.N and Word.N are the temporaries' names, so no register written by hand may take one.
(define real.own
  Name -> (simple-error (make-string "native code: ~A is the name of a temporary" Name))
      where (or (real.numbered? "Real." (str Name)) (real.numbered? "Word." (str Name)))
  Name -> Name)

(define real.numbered?
  "" Digits -> (and (not (= Digits "")) (real.digits? Digits))
  (@s C Prefix) (@s C Rest) -> (real.numbered? Prefix Rest)
  _ _ -> false)

(define real.digits?
  "" -> true
  (@s C Rest) -> (and (element? C ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"]) (real.digits? Rest)))

(define real.names
  Head Body -> (native.add-names
                 (mapcan (/. I (if (and (cons? I) (= (hd I) Head) (cons? (tl I))) [(hd (tl I))] [])) Body)
                 []))

(define real.real?
  [Reals _] E -> (element? E Reals))

(define real.word?
  [_ Words] E -> (element? E Words))

(define real.statement
  Regs [real X E] -> (real.into Regs 0 X E)
  Regs [word X E] -> (word.into Regs 0 X E)
  Regs [f64! M I E] -> (let Value (real.operand Regs 0 E)
                             After (real.after Regs 0 E)
                         (if (word.index? Regs I)
                             (let Index (word.operand Regs After I)
                               (append (tl Value) (tl Index) [[real-store-at M (hd Index) (hd Value)]]))
                             (let Index (real.index After I)
                               (append (tl Value) (tl Index) [[real-store M (hd Index) (hd Value)]]))))
  Regs [real-box D E] -> (let Value (real.operand Regs 0 E)
                           (append (tl Value) [[real-box D (hd Value)]]))
  Regs [return-real E] -> (append (real.statement Regs [real-box (intern "Real.Result") E])
                                  [[return (intern "Real.Result")]])
  Regs [word-box D E] -> (let Value (word.operand Regs 0 E)
                           (append (tl Value) [[word-box D (hd Value)]]))
  Regs [return-word E] -> (append (real.statement Regs [word-box (intern "Real.Result") E])
                                  [[return (intern "Real.Result")]])
  Regs [jump-unless [Op A B] L]
  -> (let First (real.operand Regs 0 A)
          Second (real.operand Regs (real.after Regs 0 A) B)
       (append (tl First) (tl Second) [[(real.test Op) (hd First) (hd Second) L]]))
  Regs [jump-unless-test [Op A B] L]
  -> (real.statement Regs
       [(if (and (not (element? Op [u< u> u<= u>=])) (structure.any-real? Regs [A B]))
            jump-unless
            jump-unless-word)
        [Op A B] L])
  Regs [jump-unless-word [Op A B] L]
  -> (let First (word.operand Regs 0 A)
          Second (word.operand Regs (word.after Regs 0 A) B)
       (append (tl First) (tl Second) [[(word.test Op) (hd First) (hd Second) L]]))
  Regs [Op M I E] -> (let Value (word.operand Regs 0 E)
                          Index (word.operand Regs (word.after Regs 0 E) I)
                       (append (tl Value) (tl Index) [[(word.store Op) M (hd Index) (hd Value)]]))
      where (element? Op [u8! u16! u32! u64!])
  _ I -> [I])

(define real.test
  < -> real-unless<
  > -> real-unless>
  <= -> real-unless<=
  >= -> real-unless>=
  = -> real-unless=
  Op -> (simple-error (make-string "native code: not a comparison of reals: ~R" Op)))

(define word.test
  < -> word-unless<
  > -> word-unless>
  <= -> word-unless<=
  >= -> word-unless>=
  = -> word-unless=
  u< -> word-unless-u<
  u> -> word-unless-u>
  u<= -> word-unless-u<=
  u>= -> word-unless-u>=
  Op -> (simple-error (make-string "native code: not a comparison of words: ~R" Op)))

(define word.store
  u8! -> word-store8
  u16! -> word-store16
  u32! -> word-store32
  u64! -> word-store64)

\\ The temporary after the one operand E takes, if it takes one.
(define real.after
  Regs N E -> (if (real.real? Regs E) N (+ N 1)))

(define real.temporary
  N -> (intern (cn "Real." (str N))))

\\ [the register that holds E | the instructions that put it there]. E's own first operand
\\ can share its temporary, as that is written last.
(define real.operand
  Regs N E -> [E] where (real.real? Regs E)
  Regs N E -> (let T (real.temporary N)
                [T | (real.into Regs N T E)]))

\\ What puts E in real register D. D is written last, so E may read it.
(define real.into
  Regs _ D E -> [[real-move D E]] where (real.real? Regs E)
  Regs _ D E -> [[real-from-word D E]] where (real.word? Regs E)
  _ _ D [const K] -> [[real-number D [const K]]]
  Regs N D [f64 M I] -> (if (word.index? Regs I)
                            (let Index (word.operand Regs N I)
                              (append (tl Index) [[real-load-at D M (hd Index)]]))
                            (let Index (real.index N I)
                              (append (tl Index) [[real-load D M (hd Index)]])))
  Regs N D [neg A] -> (real.unary Regs N D real-neg A)
  Regs N D [abs A] -> (real.unary Regs N D real-abs A)
  Regs N D [sqrt A] -> (real.unary Regs N D real-sqrt A)
  Regs N D [+ A B] -> (real.binary Regs N D real+ A B)
  Regs N D [- A B] -> (real.binary Regs N D real- A B)
  Regs N D [* A B] -> (real.binary Regs N D real* A B)
  Regs N D [/ A B] -> (real.binary Regs N D real/ A B)
  Regs N D [Op A B C | More] -> (real.into Regs N D [Op A [Op B C | More]]) where (element? Op [+ *])
  Regs N D [Op | X] -> (let Value (word.operand Regs N [Op | X])
                         (append (tl Value) [[real-from-word D (hd Value)]]))
      where (element? Op (word.only))
  _ _ _ [Op | X] -> (simple-error (make-string "native code: not a real expression: ~R" [Op | X]))
  _ _ D O -> [[real-number D O]])

(define real.unary
  Regs N D Op A -> (let Value (real.operand Regs N A)
                     (append (tl Value) [[Op D (hd Value)]])))

(define real.binary
  Regs N D Op A B -> (let First (real.operand Regs N A)
                          Second (real.operand Regs (real.after Regs N A) B)
                       (append (tl First) (tl Second) [[Op D (hd First) (hd Second)]])))

\\ What is written only with words.
(define word.only
  -> [bit-and bit-or bit-xor bit-not shift-left shift-right shift-right-signed rotate-left rotate-right
      u8 u16 u32 s32 u64 truncate])

\\ What the operand of a word instruction can be as it is: a register, or a constant.
(define word.direct?
  Regs E -> (or (real.word? Regs E) (integer? E) (and (cons? E) (= (hd E) const))))

(define word.after
  Regs N E -> (if (word.direct? Regs E) N (+ N 1)))

(define word.temporary
  N -> (intern (cn "Word." (str N))))

\\ As shen-jit.real.operand.
(define word.operand
  Regs N E -> [E] where (word.direct? Regs E)
  Regs N E -> (let T (word.temporary N)
                [T | (word.into Regs N T E)]))

(define word.into
  Regs _ D E -> [[word-move D E]] where (word.direct? Regs E)
  Regs _ _ E -> (simple-error (make-string "native code: a real register as a word needs truncate: ~R" E))
      where (real.real? Regs E)
  Regs N D [+ A B] -> (word.binary Regs N D word+ A B)
  Regs N D [- A B] -> (word.binary Regs N D word- A B)
  Regs N D [* A B] -> (word.binary Regs N D word* A B)
  Regs N D [bit-and A B] -> (word.binary Regs N D word-and A B)
  Regs N D [bit-or A B] -> (word.binary Regs N D word-or A B)
  Regs N D [bit-xor A B] -> (word.binary Regs N D word-xor A B)
  Regs N D [bit-not A] -> (word.binary Regs N D word-xor A -1)
  Regs N D [neg A] -> (word.binary Regs N D word- 0 A)
  Regs N D [shift-left A B] -> (word.binary Regs N D word-shl A B)
  Regs N D [shift-right A B] -> (word.binary Regs N D word-shr A B)
  Regs N D [shift-right-signed A B] -> (word.binary Regs N D word-sar A B)
  Regs N D [rotate-left A B] -> (word.binary Regs N D word-rotl A B)
  Regs N D [rotate-right A B] -> (word.binary Regs N D word-rotr A B)
  Regs N D [Op A B C | More] -> (word.into Regs N D [Op A [Op B C | More]]) where (element? Op [+ *])
  Regs N D [u8 M I] -> (word.load Regs N D word-load8 M I)
  Regs N D [u16 M I] -> (word.load Regs N D word-load16 M I)
  Regs N D [u32 M I] -> (word.load Regs N D word-load32 M I)
  Regs N D [s32 M I] -> (word.load Regs N D word-load-s32 M I)
  Regs N D [u64 M I] -> (word.load Regs N D word-load64 M I)
  Regs N D [truncate E] -> (let Value (real.operand Regs N E)
                             (append (tl Value) [[word-from-real D (hd Value)]]))
  _ _ _ [Op | X] -> (simple-error (make-string "native code: not a word expression: ~R" [Op | X]))
  _ _ _ E -> (simple-error (make-string "native code: not an integer: ~R" E)) where (number? E)
  _ _ D O -> [[word-number D O]])

(define word.binary
  Regs N D Op A B -> (let First (word.operand Regs N A)
                          Second (word.operand Regs (word.after Regs N A) B)
                       (append (tl First) (tl Second) [[Op D (hd First) (hd Second)]])))

(define word.load
  Regs N D Op M I -> (let Index (word.operand Regs N I)
                       (append (tl Index) [[Op D M (hd Index)]])))

\\ Whether an index mentions a word register, and so is worked out in words.
(define word.index?
  _ I -> true where (integer? I)
  Regs I -> (word.mentioned? Regs I))

(define word.mentioned?
  Regs [const _] -> false
  Regs [_ | Args] -> (word.any-mentioned? Regs Args)
  Regs I -> (real.word? Regs I))

(define word.any-mentioned?
  _ [] -> false
  Regs [A | As] -> (or (word.mentioned? Regs A) (word.any-mentioned? Regs As)))

\\ An index in slots is integer arithmetic through prim: [what holds it | instructions]. Its slots
\\ are read at once, so that each statement can use them again.
(define real.index
  _ [const K] -> [[const K]]
  N [Op | Args] -> (let T (intern (cn "Real.Index." (str N)))
                        Values (real.indices (+ N 1) Args)
                     [T | (append (tl Values) [[prim T Op | (hd Values)]])])
  _ I -> [I])

(define real.indices
  _ [] -> [[]]
  N [A | As] -> (let Value (real.index N A)
                     Rest (real.indices (+ N 1) As)
                  [[(hd Value) | (hd Rest)] | (append (tl Value) (tl Rest))]))

\\ What flat instructions name as registers: the names and numbers, for the slots' table. They are
\\ not slots, nor both kinds, and they fit. The JIT chooses which get machine registers.
(define real.registers
  Name Slots Body
  -> (let Reals (mapcan (/. I (real.reads [real real!] I)) Body)
          Words (mapcan (/. I (real.reads [word word!] I)) Body)
          RealNames (native.add-names Reals [])
          WordNames (native.add-names Words [])
       (do (map (/. X (if (or (element? X Slots) (element? X WordNames))
                          (simple-error (make-string "native code, ~A: ~R is a register, and is used as something else" Name X))
                          skip))
                RealNames)
           (map (/. X (if (element? X Slots)
                          (simple-error (make-string "native code, ~A: ~R is a register, and is used as something else" Name X))
                          skip))
                WordNames)
           (if (or (> (length RealNames) 48) (> (length WordNames) 16))
               (simple-error (make-string "native code, ~A: more than 48 real registers or 16 word registers: ~R"
                                          Name [RealNames WordNames]))
               (append (shen-jit.lower.bind RealNames 0) (shen-jit.lower.bind WordNames 0))))))

(define real.reads
  Kinds [Op | Args] -> (real.reads-h Kinds (check.shape Op) Args))

(define real.reads-h
  _ none _ -> []
  _ [] _ -> []
  Kinds [K | Ks] [A | As] -> [A | (real.reads-h Kinds Ks As)] where (element? K Kinds)
  Kinds [_ | Ks] [_ | As] -> (real.reads-h Kinds Ks As)
  _ _ _ -> [])

\\ ---------------------------------------------------------------------------
\\ Checking and installing.

(define install-code
  [defun F [code Name Arity | Rest]]
  -> (do (native.check F [code Name Arity | Rest])
         (install [defun F [code Name Arity | Rest]])
         (shen.store-arity F Arity)
         F)
  Code -> (do (native.check code Code) (install Code)))

(define native.check
  Where [code Name Arity Frame Constants Instructions Codes]
  -> (check.code Where [code Name Arity Frame Constants Instructions Codes] 0 top)
  Where [code Name Arity Frame Constants Instructions Codes []]
  -> (check.code Where [code Name Arity Frame Constants Instructions Codes] 0 top)
  Where X -> (check.fail Where "malformed code object" X))

)

\\ Unboxed floats and fixnums. A definition with type annotations whose parameters
\\ include a float or a fixnum, as typed code declares them, or which makes floats of its
\\ own, keeps them, and what it computes from them, in float and word registers
\\ (docs/bytecode.md), and boxes a value only where it leaves them: returned, passed,
\\ stored or kept in a slot. Fixnum arithmetic there raises on overflow as + does (fix+
\\ and the rest). Its own tail calls go back to a loop after the parameters are read,
\\ carrying their values there. Reading a value from a slot checks it, as a primitive
\\ would, so a parameter that is not what its type says raises, or, for a float, is
\\ converted if it is an integer. Registers keep nothing across a call of a function or
\\ into a handler, so a definition whose code has either is made again as usual.
\\
\\ The builder counts registers as a stack: those of the parameters first, then those of
\\ the variables in scope, then temporaries, which go back once their expression is done.

(shen.x.namespace shen-jit.lower
  (use shen-jit)
  (externals [again apply below indexed past call-sealed call-value code const effect exit fix* fix+ fix-
    fixnum float frozen jump label loop move new none prim push-handler
    float float* float+ float- float-box float-call1 float-call2 float-call3 float-divide float-from-word
    float-load float-load-at float-load-index float-move float-number float-sqrt float-store float-store-at
    float-store-index fix-store8 fix-store16 fix-store32 fix-store-s32 fix-from-float word-load-index word-store-index word-store64 float-unless<
    float-unless<= float-unless= float-unless> float-unless>= skip slot typed calling var word word+ word- word-and
    word-box word-load-s32 word-load16 word-load32 word-load8 word-move word-number word-or word-sar
    word-shl word-unless< word-unless<= word-unless= word-unless> word-unless>= word-xor
    word.t word* word-shr word-rotl word-rotr word-load64 word-unless-u< word-unless-u<=
    wof wfixnum wfloat wget w+ w- w* wand wor wxor wshl wshr wsar wrotl wrotr w< w<= wu< wu<=])

\\ Whether an annotated definition tries registers: one with float, fixnum or word.t anywhere among
\\ its annotations, as on a parameter, which param-kinds reads, or that reads a typed struct's fixnum or
\\ float field, as a check over a struct's offsets does.
(define registers-for?
  Annotated Typed -> (and Annotated (or (shen-jit.lower.occurs? float Typed) (shen-jit.lower.occurs? fixnum Typed)
                                        (shen-jit.lower.occurs? word.t Typed)
                                        (register-field-read? Typed))))

(define register-field-read?
  [F | Args] -> (or (and (shen-jit.symbol? F) (not (= 0 (definition-property F shen-jit.struct.field-kind 0))))
                    (register-field-read? F)
                    (some-register-field-read? Args))
  _ -> false)

(define some-register-field-read?
  [X | Xs] -> (or (register-field-read? X) (some-register-field-read? Xs))
  _ -> false)

\\ Where each parameter goes: float for (type P float), word for (type P fixnum), bits for (type P
\\ word.t), a 64-bit word (lib/word.shen), as the annotator gives them, or slot; [] for code with no
\\ annotations, which is not tried.
(define param-kinds
  Params Typed Annotated -> (if (or (not Annotated) (element? type Params))
                                []
                                (map (/. P (param-kind P Typed)) Params)))

(define param-kind
  P Typed -> (cond ((typed-as? P float Typed) float)
                   ((typed-as? P fixnum Typed) word)
                   ((typed-as? P word.t Typed) bits)
                   (true slot)))

(define typed-as?
  P T [type P T] -> true
  P T [let X V Body] -> (or (typed-as? P T V)
                            (and (not (element? X [P type])) (typed-as? P T Body)))
  P T [lambda X Body] -> (and (not (element? X [P type])) (typed-as? P T Body))
  P T [X | Xs] -> (or (typed-as? P T X) (typed-as-each? P T Xs))
  _ _ _ -> false)

(define typed-as-each?
  P T [X | Xs] -> (or (typed-as? P T X) (typed-as-each? P T Xs))
  _ _ _ -> false)

\\ Norm, frozen, normalises the body. Code that keeps no values in registers normalises it again
\\ without the typed bodies and loops it inlined for registers, which would only box their values.
(define defun-code
  F Params Norm Sealed Kinds
  -> (let Body (thaw Norm)
          Unboxed (if (or (value *registers*) (and (cons? Kinds) (float-source? Body)))
                      (trap-error (unboxed F Params Body Sealed Kinds) (/. E (out-of-registers E)))
                      [])
       (cond ((cons? Unboxed) Unboxed)
             ((value *registers*)
              (do (set *registers* false)
                  (shen-jit.lower.code F Params (thaw Norm) Sealed)))
             (true (shen-jit.lower.code F Params Body Sealed)))))

\\ The code with values in registers, or [] if it calls a function or has a handler, or
\\ computes nothing in a register, which would only box what it read again.
(define unboxed
  F Params Body Sealed Kinds
  -> (let B (builder F (length Params) Sealed)
          Floats (address-> B 12 0)
          Layout (layout B Kinds 2)
          Env (append (stepped Params Layout (kept F Params Body) [] (self-calls F (length Params) Body)
                               (binders Body) 1)
                      (layout-env Params Layout))
          Loop (if (and (cons? (self-calls F (length Params) Body))
                        (or (element? F Sealed) (shen-jit.sealed? F)))
                   (let L (new-label B)
                     (do (emit B [loop L]) (address-> B 13 [[L Layout Params F]])))
                   skip)
          Done (expr B Env Body tail (+ 2 (length Params)))
       (if (and (keeps-nothing-across? (<-address B 3)) (computes? (<-address B 3)))
           (code-form B)
           [])))

\\ Where each parameter is: [float R], [word W] or [bits W], read from its slot, or the slot.
(define layout
  _ [] _ -> []
  B [float | Kinds] S -> (let R (float-from B S)
                          [[float R] | (layout B Kinds (+ S 1))])
  B [word | Kinds] S -> (let W (word-from B S)
                          [[word W] | (layout B Kinds (+ S 1))])
  B [bits | Kinds] S -> (let W (bits-from B S)
                          [[bits W] | (layout B Kinds (+ S 1))])
  B [_ | Kinds] S -> [S | (layout B Kinds (+ S 1))])

(define layout-env
  [] _ -> []
  [P | Ps] [L | Ls] -> [[P | L] | (layout-env Ps Ls)])

\\ Whether X makes a float of its own: a literal, a read from bytes, a conversion or a square root.
(define float-source?
  [const X] -> (and (number? X) (not (shen-jit.fixnum? X)))
  [prim Op _] -> true where (element? Op [shen-jit.f64 shen-jit.float shen-jit.sqrt])
  [call F Args] -> true where (foreign-float? F Args)
  [X | Xs] -> (or (float-source? X) (float-source-in? Xs))
  _ -> false)

(define float-source-in?
  [X | Xs] -> (or (float-source? X) (float-source-in? Xs))
  _ -> false)

(define calls-nothing?
  [] -> true
  [[Op | _] | _] -> false where (element? Op [call call-sealed call-value push-handler])
  [_ | Is] -> (calls-nothing? Is))

\\ Whether no call has registers to keep: after each, every way on leaves the definition, by a
\\ return, a tail call or a raise, before it reads or writes a register or goes back to a loop, as
\\ an error's message, made by calls, does. A handler keeps nothing of them, so none is allowed.
\\ The builder holds its instructions last first.
(define keeps-nothing-across?
  Backwards -> (let Is (reverse Backwards) (keeps-nothing-h? Is Is)))

(define keeps-nothing-h?
  [] _ -> true
  [[push-handler | _] | _] _ -> false
  [[Op | _] | Is] All -> (and (exits-first? Is All [] 0) (keeps-nothing-h? Is All))
      where (element? Op [call call-sealed call-value])
  [_ | Is] All -> (keeps-nothing-h? Is All))

\\ Whether every way on from Is leaves the definition first, looking at a bounded number of
\\ instructions: past that, it is taken not to, and the code is made boxed.
(define exits-first?
  _ _ _ 4000 -> false
  [] _ _ _ -> false
  [[Op | _] | _] _ _ _ -> true where (element? Op [return tail-call tail-call-sealed tail-call-value])
  [[prim _ simple-error | _] | _] _ _ _ -> true
  [[jump L] | _] All Seen N -> (exits-first-at? L All Seen (+ N 1))
  [[jump-if-false _ L] | Is] All Seen N -> (and (exits-first-at? L All Seen (+ N 1)) (exits-first? Is All Seen (+ N 1)))
  [[jump-unless-entry _ _ L] | Is] All Seen N -> (and (exits-first-at? L All Seen (+ N 1)) (exits-first? Is All Seen (+ N 1)))
  [[label L] | Is] All Seen N -> (or (element? L Seen) (exits-first? Is All [L | Seen] (+ N 1)))
  [[Op | _] | Is] All Seen N -> (exits-first? Is All Seen (+ N 1))
      where (element? Op [const move prim closure capture call call-sealed call-value inline])
  _ _ _ _ -> false)

(define exits-first-at?
  L All Seen N -> (or (element? L Seen) (exits-first? (after-label L All) All [L | Seen] N)))

(define after-label
  _ [] -> []
  L [[label L] | Is] -> Is
  L [_ | Is] -> (after-label L Is))

(define computes?
  [] -> false
  [[Op | _] | _] -> true where (element? Op [word* word-shr word-rotl word-rotr word-load64 word-unless-u<
                                             word-unless-u<= float+ float- float* float-divide float-sqrt float-load float-store
                                             float-load-at float-store-at float-load-index float-store-index
                                             fix-store8 fix-store16 fix-store32 fix-store-s32 word-store64
                                             fix-from-float word-load-index word-store-index float-call1 float-call2 float-call3
                                             float-unless< float-unless> float-unless<=
                                             float-unless>= float-unless= fix+ fix- fix* word+ word- word-and word-or word-xor
                                             word-shl word-sar
                                             word-load8 word-load16 word-load32 word-load-s32
                                             word-unless< word-unless> word-unless<= word-unless>= word-unless=])
  [_ | Is] -> (computes? Is))

\\ Registers. Field 12 of the builder is the next float register, field 14 the next word register.
(define register
  B Field Count -> (let R (<-address B Field)
                     (if (< R Count)
                         (do (address-> B Field (+ R 1)) R)
                         (no-register))))

\\ Code with registers that runs out of them, or has a value no register can take, is made again
\\ boxed: that is the one error that does it. Any other is the lowerer's own, and raises.
(define no-register
  -> (simple-error "shen-jit lowerer: no register left"))

(define out-of-registers
  E -> (if (= (error-to-string E) "shen-jit lowerer: no register left") [] (simple-error (error-to-string E))))

(define float-register
  B -> (register B 12 64))

(define word-register
  B -> (register B 14 16))

\\ A new register holding the number in O, an operand, checked and converted.
(define float-from
  B O -> (let R (float-register B)
           (do (emit B [float-number R O]) R)))

\\ Reads whose value register code takes into a register of its kind from the slot the read leaves
\\ it in, checked as any read from a slot is: a typed struct's fixnum or float field, which
\\ shen-jit.field reads, and the length of bytes.
(define read-into-register?
  Op -> (element? Op [shen-jit.field-word shen-jit.field-float shen-jit.bytes-length]))

(define emitted-prim
  shen-jit.field-word -> shen-jit.field
  shen-jit.field-float -> shen-jit.field
  Op -> Op)

\\ Such a read into slot Top, for a register to take it from.
(define read-slot
  B Env Op Args Top -> (do (shen-jit.lower.value B Env [prim Op Args] Top (+ Top 1)) Top))

\\ A new word register holding the fixnum in O, checked.
(define word-from
  B O -> (let W (word-register B)
           (do (emit B [word-number W O]) W)))

\\ A new word register holding the 64-bit word in O, a boxed one: its 8 bytes, read as bytes are.
(define bits-from
  B O -> (let W (word-register B)
           (do (emit B [word-load64 W O [const (constant B 0)]]) W)))

(define in-kind?
  Kind X Env -> (let Binding (assoc X Env)
                  (and (cons? Binding) (cons? (tl Binding)) (= Kind (hd (tl Binding))))))

\\ Whether B is making code with registers: its field 12, the next float register, is a number.
(define registers?
  B -> (number? (<-address B 12)))

(define float?
  B Env X -> (and (registers? B) (float-kind? Env X)))

\\ A value to keep in a register: a float or a fixnum, but not a constant, which an
\\ instruction takes as it is.
(define unboxed?
  B Env X -> (and (registers? B) (not (constant? X))
                  (not (= slot (kind Env X)))))

\\ Whether a double's index of bytes is a fixnum, read as a word with no tag to test: in a
\\ register, or a constant, as a field's offset in a record of floats is.
(define word-index?
  B Env I -> (and (registers? B) (word-kind? Env I)))

\\ What a variable bound to X is bound to: [float R] or [word W].
(define unbox
  B Env X Top -> [float (shen-jit.lower.float B Env X Top)] where (float-kind? Env X)
  B Env X Top -> [bits (shen-jit.lower.word B Env X Top)] where (= bits (kind Env X))
  B Env X Top -> [word (shen-jit.lower.word B Env X Top)])

(define box
  B Env X D Top -> (released B (freeze (box-h B Env X D Top))))

(define box-h
  B Env X D Top -> (emit B [float-box D (shen-jit.lower.float B Env X Top)])
      where (float-kind? Env X)
  B Env X D Top -> (box-bits B D (shen-jit.lower.word B Env X Top))
      where (= bits (kind Env X))
  B Env X D Top -> (emit B [word-box D (shen-jit.lower.word B Env X Top)]))

\\ A 64-bit word in W boxed into slot D: new bytes, its 8 there.
(define box-bits
  B D W -> (do (emit B [prim D shen-jit.bytes [const (constant B 8)]])
               (emit B [word-store64 D [const (constant B 0)] W])))

\\ Lower, then give back every register it took: what it computes leaves no value in one.
(define released
  B Lower -> (let RMark (<-address B 12)
                  WMark (<-address B 14)
                  Done (thaw Lower)
                  Back (address-> B 12 RMark)
                  Back2 (address-> B 14 WMark)
               Done))

\\ A let's value X, of Kind, computed into the first register free, M, whose own registers go back
\\ after: only M outlives X, so the lets of an inlined body, in a value, do not use up registers.
\\ X's first let may take M too, as into reads what it writes into M first.
(define down
  B Kind Env X Top -> (let Field (if (= Kind float) 12 14)
                           Count (if (= Kind float) 64 16)
                           M (<-address B Field)
                           Full (if (< M Count) skip (no-register))
                           Done (released B (freeze (into B Env Kind X M Top)))
                        (register B Field Count)))

\\ What a let binds in the kinds below: [float 0], [word 0], or a slot.
(define kind-of
  Env V -> (let K (kind Env V) (if (= K slot) 0 [K 0])))

(define float-kind?
  Env X -> (= float (kind Env X)))

(define word-kind?
  Env X -> (= word (kind Env X)))

\\ What X gives, float, word or slot, in one walk over X. A float: a float literal or variable,
\\ arithmetic of two floats, a float read from bytes, shen-jit.float, shen-jit.sqrt, a C function of
\\ doubles or a typed struct's float field. A word, a fixnum known to be one: a fixnum literal or
\\ variable, +, -, * and the bit operations over two of them, an integer read from bytes, a shift by a
\\ constant, a float truncated, a typed struct's fixnum field, or the length of bytes. Arithmetic
\\ mixing a float with an integer is a slot: it is done as + does it, boxed, so that an integer
\\ operand that is itself a sum keeps its exact value and its overflow check, and only the result
\\ becomes a float.
(define kind
  _ [const X] -> (cond ((and (integer? X) (shen-jit.fixnum? X)) word)
                       ((number? X) float)
                       (true slot))
  Env [var X] -> (cond ((in-kind? float X Env) float)
                       ((in-kind? word X Env) word)
                       ((in-kind? bits X Env) bits)
                       (true slot))
  Env [prim shen-jit.word-op [[const Op] X Y]] -> (word-op-kind Env Op X Y)
  Env [prim Op [X Y]] -> (let KX (kind Env X)
                           (cond ((and (= KX float) (= float (kind Env Y))) float)
                                 ((and (= KX word) (not (= Op /)) (= word (kind Env Y))) word)
                                 (true slot)))
      where (element? Op [+ - * /])
  Env [prim Op [X Y]] -> (if (and (= word (kind Env X)) (= word (kind Env Y))) word slot)
      where (element? Op [shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor])
  _ [prim Op [_ _]] -> word where (element? Op [shen-jit.u8 shen-jit.u16 shen-jit.u32 shen-jit.s32])
  _ [prim Op _] -> word where (element? Op [shen-jit.field-word shen-jit.bytes-length])
  _ [prim shen-jit.field-float _] -> float
  Env [prim Op [X [const K]]] -> (if (= word (kind Env X)) word slot) where (shift? Op K)
  _ [prim shen-jit.f64 _] -> float
  Env [prim shen-jit.truncate [X]] -> (if (= float (kind Env X)) word slot)
  _ [prim shen-jit.float _] -> float
  _ [prim shen-jit.sqrt _] -> float
  _ [call F Args] -> (if (foreign-float? F Args) float slot)
  Env [let inlining _ Body] -> (kind Env Body)
  _ [let shen-jit.lower.loop [const Info] _] -> (loop-result Info)
  Env [let X V Body] -> (kind [[X | (kind-of Env V)] | Env] Body)
  Env [do _ Y] -> (kind Env Y)
  Env [if _ X Y] -> (kind Env Y) where (raises? X)
  Env [if _ X Y] -> (kind Env X) where (raises? Y)
  Env [if _ X Y] -> (let KX (kind Env X)
                      (if (and (not (= KX slot)) (= KX (kind Env Y))) KX slot))
  _ _ -> slot)

\\ Whether X raises, on every way through it, as a check's error does: it gives no value, so an if
\\ with such a branch gives what its other branch does.
(define raises?
  [prim simple-error _] -> true
  [let _ _ Body] -> (raises? Body)
  [do _ Y] -> (raises? Y)
  [if _ X Y] -> (and (raises? X) (raises? Y))
  _ -> false)

\\ Whether a branch of an if in a register of Kind gives that kind, or raises.
(define branch-of?
  Env Kind X -> (or (raises? X) (= Kind (kind Env X))))

\\ A branch computed into R, or, one that raises, only run.
(define branch-into
  B Kind Env X R Top -> (shen-jit.lower.effect B Env X Top) where (raises? X)
  B Kind Env X R Top -> (emit B [(move-op Kind) R (register-of B Kind Env X Top)]))

\\ What a word operation (lib/word.shen) gives: a 64-bit word, bits, from words, a fixnum or bytes
\\ as each takes them; a fixnum or a float from a word; or, for a comparison or anything else, slot.
(define word-op-kind
  Env wof X _ -> (if (= word (kind Env X)) bits slot)
  Env wfixnum X _ -> (if (= bits (kind Env X)) word slot)
  Env wfloat X _ -> (if (= bits (kind Env X)) float slot)
  Env wget _ I -> (if (= word (kind Env I)) bits slot)
  Env Op X Y -> (if (and (= bits (kind Env X)) (= word (kind Env Y))) bits slot)
      where (element? Op [wshl wshr wsar wrotl wrotr])
  Env Op X Y -> (if (and (= bits (kind Env X)) (= bits (kind Env Y))) bits slot)
      where (element? Op [w+ w- w* wand wor wxor])
  _ _ _ _ -> slot)

\\ A comparison in registers needs both operands of the same kind. Converting a fixnum to a
\\ float can round it, so mixed comparisons keep the primitive's exact ordering.
(define unboxed-test?
  B Env Op [X Y] -> (and (registers? B)
                         (element? Op [< > <= >= =])
                         (let KX (kind Env X)
                           (and (not (= KX slot)) (= KX (kind Env Y)))))
  B Env shen-jit.word-op [[const Op] X Y] -> (and (registers? B) (element? Op [w< w<= wu< wu<=])
                                                  (= bits (kind Env X)) (= bits (kind Env Y)))
  _ _ _ _ -> false)

(define unboxed-test
  B Env Op X Y Else Top
  -> (let RMark (<-address B 12)
          WMark (<-address B 14)
          Float (or (float-kind? Env X) (float-kind? Env Y))
          OX (if Float (shen-jit.lower.float B Env X Top) (shen-jit.lower.word B Env X Top))
          OY (if Float (shen-jit.lower.float B Env Y Top) (shen-jit.lower.word B Env Y Top))
          Jump (emit B [(unless Float Op) OX OY Else])
          Back (address-> B 12 RMark)
       (address-> B 14 WMark)))

(define unless
  true < -> float-unless<
  true > -> float-unless>
  true <= -> float-unless<=
  true >= -> float-unless>=
  true = -> float-unless=
  false < -> word-unless<
  false > -> word-unless>
  false <= -> word-unless<=
  false >= -> word-unless>=
  false = -> word-unless=
  false w< -> word-unless<
  false w<= -> word-unless<=
  false wu< -> word-unless-u<
  false wu<= -> word-unless-u<=)

\\ The register that holds X, a float, computing it if need be.
(define shen-jit.lower.float
  B Env [prim Op [X Y]] Top -> (float-arithmetic-to B Env Op X Y Top new)
      where (and (element? Op [+ - * /]) (float-kind? Env [prim Op [X Y]]))
  B Env [prim shen-jit.float [X]] Top -> (shen-jit.lower.float B Env X Top)
  B Env [call F Args] Top
  -> (let Mark (<-address B 12)
          Rs (floats B Env Args Top)
          Back (address-> B 12 Mark)
          R (float-register B)
       (do (emit B [(float-call (length Args)) R F | Rs]) R))
      where (foreign-float? F Args)
  B Env [prim shen-jit.sqrt [X]] Top
  -> (let Mark (<-address B 12)
          RX (shen-jit.lower.float B Env X Top)
          Back (address-> B 12 Mark)
          R (float-register B)
       (do (emit B [float-sqrt R RX]) R))
  B Env [prim shen-jit.f64 [M I]] Top
  -> (let OM (operand B Env M Top)
          Top1 (if (= OM Top) (+ Top 1) Top)
          WMark (<-address B 14)
          Scaled (scaled-index? B Env I)
          OI (if Scaled (element-index B Env I Top1) (byte-index B Env I Top1))
          Back (address-> B 14 WMark)
          R (float-register B)
       (do (emit B [(if Scaled float-load-index float-load-at) R OM OI]) R))
      where (word-index? B Env I)
  B Env [prim shen-jit.f64 Args] Top
  -> (let Operands (operands B Env Args Top)
          R (float-register B)
       (do (emit B [float-load R | Operands]) R))
  B Env [prim shen-jit.word-op [[const wfloat] X _]] Top
  -> (shen-jit.lower.float-from-word B (shen-jit.lower.word B Env X Top))
      where (= bits (kind Env X))
  B Env [prim shen-jit.field-float Args] Top
  -> (float-from B (read-slot B Env shen-jit.field-float Args Top))
  B Env X Top -> (in-register B float Env X Top))

\\ A sealed C function of doubles giving a double, which lib/ffi.shen marks, called with as many:
\\ its arguments and result stay in registers, and the call is to C, which keeps nothing of them.
(define foreign-float?
  F Args -> (and (shen-jit.symbol? F) (shen-jit.sealed? F)
                 (= (length Args) (definition-property F shen-jit.foreign-floats 0))))

(define float-call
  1 -> float-call1
  2 -> float-call2
  3 -> float-call3)

\\ The registers of Xs, each a float, computed in order.
(define floats
  _ _ [] _ -> []
  B Env [X | Xs] Top -> (let R (shen-jit.lower.float B Env X Top)
                          [R | (floats B Env Xs Top)]))

(define shen-jit.lower.float-from-word
  B W -> (let R (float-register B)
           (do (emit B [float-from-word R W]) R)))

\\ Both operands are evaluated before either is checked, as the primitive does. A
\\ float divided by zero raises, as / does: float-divide tests the divisor, where float/ would give an
\\ infinity. The result goes into register To, or into a new one when To is new.
(define float-arithmetic-to
  B Env Op X Y Top To
  -> (let Mark (<-address B 12)
          OX (float-operand B Env X Top)
          Top1 (if (= OX Top) (+ Top 1) Top)
          OY (float-operand B Env Y Top1)
          RX (float-of B OX)
          RY (float-of B OY)
          Back (address-> B 12 Mark)
          R (if (= To new) (float-register B) To)
       (do (emit B [(float-op Op) R RX RY]) R)))

\\ A float operand is [float R], already in register R, as is a fixnum, converted; any other
\\ is a slot or a constant.
(define float-operand
  B Env X Top -> [float (shen-jit.lower.float B Env X Top)]
      where (or (float? B Env X) (unboxed? B Env X))
  B Env X Top -> (operand B Env X Top))

(define float-of
  _ [float R] -> R
  B O -> (float-from B O))

(define float-op
  + -> float+
  - -> float-
  * -> float*
  / -> float-divide)

\\ The word operand that holds X, a fixnum: a register, computing it if need be, or a constant.
(define shen-jit.lower.word
  B _ [const N] _ -> [const (constant B N)] where (and (integer? N) (shen-jit.fixnum? N))
  B Env [prim Op [X Y]] Top -> (word-arithmetic-to B Env Op X Y Top new)
      where (and (element? Op [+ - * shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor])
                 (word-kind? Env X) (word-kind? Env Y))
  B Env [prim Op [M I]] Top
  -> (let OM (operand B Env M Top)
          Top1 (if (= OM Top) (+ Top 1) Top)
          Mark (<-address B 14)
          OI (byte-index B Env I Top1)
          Back (address-> B 14 Mark)
          W (word-register B)
       (do (emit B [(word-load Op) W OM OI]) W))
      where (element? Op [shen-jit.u8 shen-jit.u16 shen-jit.u32 shen-jit.s32])
  \\ A shift right keeps the sign, as word-sar does. What a shift left moves past the 62 bits of a
  \\ fixnum is gone, so its result shifts 2 further, then back with the sign.
  B Env [prim Op [X [const K]]] Top
  -> (let Mark (<-address B 14)
          OX (shen-jit.lower.word B Env X Top)
          Back (address-> B 14 Mark)
          W (word-register B)
       (do (if (= Op shen-jit.shift-right)
               (emit B [word-sar W OX [const (constant B K)]])
               (do (emit B [word-shl W OX [const (constant B (+ K 2))]])
                   (emit B [word-sar W W [const (constant B 2)]])))
           W))
      where (and (shift? Op K) (word-kind? Env X))
  B Env [prim shen-jit.word-op [[const Op] X Y]] Top -> (word-op-to B Env Op X Y Top new)
      where (element? (word-op-kind Env Op X Y) [word bits])
  \\ A float truncated, raising out of line for one outside the fixnums.
  B Env [prim shen-jit.truncate [X]] Top
  -> (let Mark (<-address B 12)
          F (shen-jit.lower.float B Env X Top)
          Back (address-> B 12 Mark)
          W (word-register B)
       (do (emit B [fix-from-float W F]) W))
      where (= float (kind Env X))
  B Env [prim Op Args] Top -> (word-from B (read-slot B Env Op Args Top))
      where (element? Op [shen-jit.field-word shen-jit.bytes-length])
  B Env X Top -> (in-register B (if (= bits (kind Env X)) bits word) Env X Top))

\\ A word operation in word registers, its result into register To, or a new one when To is new:
\\ a fixnum as a word is the same 64 bits, and a word as a fixnum is checked as fix+ checks a sum.
(define word-op-to
  B Env wof X _ Top To -> (word-into B (shen-jit.lower.word B Env X Top) To)
  B Env wfixnum X _ Top To
  -> (let Mark (<-address B 14)
          OX (shen-jit.lower.word B Env X Top)
          Back (address-> B 14 Mark)
          W (word-to B To)
       (do (emit B [fix+ W OX [const (constant B 0)]]) W))
  B Env wget M I Top To
  -> (let OM (operand B Env M Top)
          Top1 (if (= OM Top) (+ Top 1) Top)
          Mark (<-address B 14)
          Scaled (scaled-index? B Env I)
          OI (if Scaled (element-index B Env I Top1) (byte-index B Env I Top1))
          Back (address-> B 14 Mark)
          W (word-to B To)
       (do (emit B [(if Scaled word-load-index word-load64) W OM OI]) W))
  B Env Op X Y Top To -> (word-instruction-to B Env (word-instruction Op) X Y Top To))

(define word-into
  _ O new -> O
  B O R -> (do (if (= O R) skip (emit B [word-move R O])) R))

(define word-instruction
  w+ -> word+
  w- -> word-
  w* -> word*
  wand -> word-and
  wor -> word-or
  wxor -> word-xor
  wshl -> word-shl
  wshr -> word-shr
  wsar -> word-sar
  wrotl -> word-rotl
  wrotr -> word-rotr)

\\ The register of Kind, float or word, that holds X, for what both compute alike: a variable's own,
\\ an inlined body's, a loop's inlined there, which gives this kind, the lets, do, and an if whose
\\ branches both give it. Anything else is converted (converted).
(define in-register
  _ Kind Env [var X] _ -> (hd (tl (tl (assoc X Env)))) where (in-kind? Kind X Env)
  B Kind Env [let inlining [const F] Body] Top -> (mark B F (freeze (register-of B Kind Env Body Top)))
  B Kind Env [let shen-jit.lower.loop [const Info] Body] Top
  -> (let R (new-register B Kind)
          End (new-label B)
          Done (released B (freeze (alone B (freeze (inlined-loop B Env Info Body [exit Kind R End] Top)))))
       (do (emit B [label End]) R))
      where (= (loop-result Info) Kind)
  B Kind Env [let shen-jit.lower.loop C Body] Top -> (converted B Kind Env [let shen-jit.lower.loop C Body] Top)
  B Kind Env [let X V Body] Top -> (down B Kind Env [let X V Body] Top)
      where (unboxed? B Env V)
  B Kind Env [let X V Body] Top
  -> (let Bound (let-bound B Env X V Top) (register-of B Kind (hd Bound) Body (tl Bound)))
  B Kind Env [do X Y] Top -> (do (shen-jit.lower.effect B Env X Top) (register-of B Kind Env Y Top))
  B Kind Env [if C X Y] Top
  -> (let R (new-register B Kind)
          Field (register-field Kind)
          Mark (<-address B Field)
          Else (new-label B)
          End (new-label B)
          Move (move-op Kind)
       (do (test B Env C Else Top)
           (branch-into B Kind Env X R Top)
           (address-> B Field Mark)
           (emit B [jump End])
           (emit B [label Else])
           (branch-into B Kind Env Y R Top)
           (address-> B Field Mark)
           (emit B [label End])
           R))
      where (and (branch-of? Env Kind X) (branch-of? Env Kind Y))
  B Kind Env X Top -> (converted B Kind Env X Top))

\\ X in a register of Kind: a float or a fixnum one gives, converted, or what it gives boxed, checked.
(define converted
  B float Env X Top -> (shen-jit.lower.float-from-word B (shen-jit.lower.word B Env X Top))
      where (unboxed? B Env X)
  B float Env X Top -> (float-from B (operand B Env X Top))
  B word Env X Top -> (word-from B (operand B Env X Top))
  B bits Env X Top -> (bits-from B (operand B Env X Top)))

(define register-of
  B float Env X Top -> (shen-jit.lower.float B Env X Top)
  B _ Env X Top -> (shen-jit.lower.word B Env X Top))

(define new-register
  B float -> (float-register B)
  B _ -> (word-register B))

(define register-field
  float -> 12
  _ -> 14)

(define move-op
  float -> float-move
  _ -> word-move)

\\ A fixnum index of an access to bytes. Its last sum or difference, of two fixnums, cannot
\\ leave 64 bits, and one that is no fixnum is past the end of any bytes, which the access's own
\\ check raises for, so it needs no test of its own.
(define byte-index
  B Env [prim Op [X Y]] Top -> (word-instruction-to B Env (if (= Op +) word+ word-) X Y Top new)
      where (and (element? Op [+ -]) (word-kind? Env X) (word-kind? Env Y))
  B Env [let inlining [const F] Body] Top
  -> (mark B F (freeze (byte-index B Env Body Top)))
  B Env [let X V Body] Top
  -> (byte-index B (bound-to B Env X V Top) Body Top)
      where (unboxed? B Env V)
  B Env [let X [var Y] Body] Top
  -> (byte-index B [[X | (shen-jit.lower.slot Y Env)] | Env] Body Top)
      where (number? (shen-jit.lower.slot Y Env))
  B Env I Top -> (shen-jit.lower.word B Env I Top))

\\ Whether the index of bytes I of a double or a word is a fixnum X times 8, as (fx* X 8),
\\ floats.get and words.get give it, through the lets that inlining leaves: the access then takes X
\\ as an index of elements (float-load-index, word-load-index and their stores), which it scales,
\\ with no product to check. An X past the elements raises as an index past the end, as an index
\\ of bytes that overflows does in typed code.
\\ Not a shift left, which keeps 62 bits where the access would not.
(define scaled-index?
  B Env [prim * [X [const 8]]] -> (word-kind? Env X)
  B Env [prim * [[const 8] X]] -> (word-kind? Env X)
  B Env [let inlining _ I] -> (scaled-index? B Env I)
  B Env [let X V I] -> (let Kind (kind-of Env V)
                         (scaled-index? B [[X | (if (cons? Kind) [(hd Kind) none] none)] | Env] I))
      where (unboxed? B Env V)
  B Env [let X [var Y] I] -> (scaled-index? B [[X | (shen-jit.lower.slot Y Env)] | Env] I)
      where (number? (shen-jit.lower.slot Y Env))
  _ _ _ -> false)

\\ The word operand of X, of an index that scaled-index? finds X times 8, its lets made as
\\ byte-index makes them.
(define element-index
  B Env [prim * [X [const 8]]] Top -> (shen-jit.lower.word B Env X Top)
  B Env [prim * [[const 8] X]] Top -> (shen-jit.lower.word B Env X Top)
  B Env [let inlining [const F] I] Top -> (mark B F (freeze (element-index B Env I Top)))
  B Env [let X V I] Top -> (element-index B (bound-to B Env X V Top) I Top)
      where (unboxed? B Env V)
  B Env [let X [var Y] I] Top -> (element-index B [[X | (shen-jit.lower.slot Y Env)] | Env] I Top)
      where (number? (shen-jit.lower.slot Y Env)))

(define word-arithmetic-to
  B Env Op X Y Top To -> (word-instruction-to B Env (word-op-of Env Op X Y) X Y Top To))

\\ Instruction Op of the words X and Y, into register To, or a new one when To is new, which may be
\\ one that computing them took and gave back.
(define word-instruction-to
  B Env Op X Y Top To
  -> (let Mark (<-address B 14)
          OX (shen-jit.lower.word B Env X Top)
          OY (shen-jit.lower.word B Env Y Top)
          Back (address-> B 14 Mark)
          W (word-to B To)
       (do (emit B [Op W OX OY]) W)))

(define word-to
  B new -> (word-register B)
  _ To -> To)

\\ One more than a fixnum below another is a fixnum, so that sum needs no check.
\\ A fixnum that a test has just found below another, plus a constant that is not negative, as a
\\ loop's step, is word+, unchecked: it is below the greatest fixnum, so the sum passes it by less
\\ than the step, exactly, in 64 bits, and cannot be stepped so again until a test finds it below a
\\ fixnum. Past the greatest fixnum, it raises where it leaves the registers, as word-box checks,
\\ and comparisons and byte indices see its exact value. The other fixnum, and what an indexed one
\\ is added to, must be exact (exact?), not such a sum, or sums of sums could pass 64 bits.
(define word-op-of
  Env + X [const K] -> word+ where (and (>= K 0) (known? below Env X))
  Env + [const K] Y -> word+ where (and (>= K 0) (known? below Env Y))
  Env + X Y -> word+ where (or (and (known? indexed Env X) (exact? Env Y))
                               (and (known? indexed Env Y) (exact? Env X)))
  _ Op _ _ -> (word-op Op))

\\ Whether X is a variable in a word register of which Env has the fact [Key W]: indexed, that the
\\ arguments of a loop's own call read or write bytes at it, as again finds, so that it is a fixnum
\\ from 0 to the length, and it plus a fixnum is exact in 64 bits, the read raising the next time
\\ round if that went past the greatest one; or below, that a test found it below a fixnum (bounded).
(define known?
  Key Env [var X] -> (let Ws (word-of Env X) (and (cons? Ws) (cons? (assoc [Key (hd Ws)] Env))))
  _ _ _ -> false)

\\ [W] for a variable X bound to word register W, else [].
(define word-of
  Env X -> (let Binding (assoc X Env)
             (if (and (cons? Binding) (cons? (tl Binding)) (= word (hd (tl Binding))))
                 [(second (tl Binding))]
                 [])))

\\ A shift of a fixnum by a constant count, left by at most 61, right by at most 63.
(define shift?
  shen-jit.shift-left K -> (and (integer? K) (>= K 0) (<= K 61))
  shen-jit.shift-right K -> (and (integer? K) (>= K 0) (<= K 63))
  _ _ -> false)

(define word-load
  shen-jit.u8 -> word-load8
  shen-jit.u16 -> word-load16
  shen-jit.u32 -> word-load32
  shen-jit.s32 -> word-load-s32)

(define word-op
  + -> fix+
  - -> fix-
  * -> fix*
  shen-jit.bit-and -> word-and
  shen-jit.bit-or -> word-or
  shen-jit.bit-xor -> word-xor)

\\ X for its effect: a float stored into bytes stays unboxed, as does a fixnum index, also
\\ inside the lets an inlined body binds its parameters with. In code with no registers, X's
\\ value goes to a slot, as for any value.
(define shen-jit.lower.effect
  B Env X Top -> (shen-jit.lower.value B Env X Top (+ Top 1)) where (not (registers? B))
  B Env X Top -> (released B (freeze (effect-h B Env X Top))))

(define effect-h
  B Env [let inlining [const F] Body] Top
  -> (mark B F (freeze (effect-h B Env Body Top)))
  B Env [let shen-jit.lower.loop [const Info] Body] Top
  -> (let End (new-label B)
       (do (alone B (freeze (inlined-loop B Env Info Body [exit effect none End] Top)))
           (emit B [label End])))
  B Env [let X V Body] Top -> (let Bound (let-bound B Env X V Top) (effect-h B (hd Bound) Body (tl Bound)))
  B Env [do X Y] Top -> (do (shen-jit.lower.effect B Env X Top) (effect-h B Env Y Top))
  B Env [prim Op [M I V]] Top -> (stored B Env Op (operand B Env M Top) I V Top)
      where (register-store? B Env Op I V)
  B Env [prim shen-jit.copy-bytes [M I W [const 0] [const 8]]] Top
  -> (stored B Env shen-jit.s64! (operand B Env M Top) I W Top)
      where (word-stored? B Env I W)
  B Env X Top -> (shen-jit.lower.value B Env X Top (+ Top 1)))

\\ Whether a store into bytes keeps its value in a register: a float, at any index, or a fixnum, at a
\\ fixnum index, either of them a constant or not.
(define register-store?
  B Env shen-jit.f64! _ V -> (and (registers? B) (float? B Env V))
  B Env Op I V -> (and (registers? B) (word-kind? Env I) (word-kind? Env V))
      where (element? Op [shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.s32! shen-jit.s64!])
  _ _ _ _ _ -> false)

\\ The store into the bytes in OM, M's operand: a float from its register, at an index of doubles
\\ where scaled-index? finds one; a fixnum from its word register, checked to fit as the primitive
\\ checks it (fix-store8 and the others), or as it is for shen-jit.s64!, which takes any fixnum.
(define stored
  B Env shen-jit.f64! OM I V Top
  -> (let Top1 (if (= OM Top) (+ Top 1) Top)
          Word (word-index? B Env I)
          Scaled (and Word (scaled-index? B Env I))
          OI (cases Scaled (element-index B Env I Top1)
                    Word (byte-index B Env I Top1)
                    true (operand B Env I Top1))
          Top2 (if (= OI Top1) (+ Top1 1) Top1)
          R (shen-jit.lower.float B Env V Top2)
       (emit B (cases Scaled [float-store-index OM OI R]
                      Word [float-store-at OM OI R]
                      true [float-store OM OI R])))
  B Env Op OM I V Top
  -> (let Top1 (if (= OM Top) (+ Top 1) Top)
          Scaled (and (= Op shen-jit.s64!) (scaled-index? B Env I))
          OI (if Scaled (element-index B Env I Top1) (byte-index B Env I Top1))
          Top2 (if (= OI Top1) (+ Top1 1) Top1)
          W (shen-jit.lower.word B Env V Top2)
       (emit B [(if Scaled word-store-index (fixnum-store Op)) OM OI W])))

\\ Whether a copy of 8 bytes from 0 is a 64-bit word's into bytes at a fixnum index, as word.set
\\ makes it: the word's register stored there, as word-store64.
(define word-stored?
  B Env I W -> (and (registers? B) (word-kind? Env I) (= bits (kind Env W))))

(define fixnum-store
  shen-jit.u8! -> fix-store8
  shen-jit.u16! -> fix-store16
  shen-jit.u32! -> fix-store32
  shen-jit.s32! -> fix-store-s32
  shen-jit.s64! -> word-store64)

\\ An inlined loop (inline-loop), its parameters bound in Env. Each goes where the loop keeps it,
\\ a register of its kind or a slot, of its own unless the loop passes it on as it is and it is
\\ already there; then comes the loop's head, and the body, whose calls of the loop's function
\\ in tail position go back to it (again), and whose other tail positions go to Target.
(define inlined-loop
  B Env [F Kinds _ Params Kept] Body Target Top
  -> (mark B F
       (freeze (let Placed (place B Env Params Kinds Kept Top [])
                    Layout (hd Placed)
                    L (new-label B)
                    Head (emit B [loop L])
                    Loops (<-address B 13)
                    In (address-> B 13 [[L Layout Params F] | Loops])
                    Starts (map (/. P (not (exact? Env [var P]))) Params)
                    Stepped (stepped Params Layout Kept Starts (self-calls F (length Params) Body)
                                     (binders Body) 1)
                    Done (expr B (append Stepped (layout-env Params Layout) Env) Body Target (hd (tl Placed)))
                 (address-> B 13 Loops)))))

\\ Lower, with no loop around to go back to: a loop that makes its own exit is in no tail position of
\\ the loops around it, so a call of their functions in its body is a call, not again.
(define alone
  B Lower -> (let Loops (<-address B 13)
                  Off (address-> B 13 [])
                  Done (thaw Lower)
                  On (address-> B 13 Loops)
               Done))

\\ Where an inlined loop keeps each parameter, moved there if need be, and the first slot above.
(define place
  _ _ [] _ _ Top Layout -> [(reverse Layout) Top]
  B Env [P | Ps] [K | Ks] [Kept | More] Top Layout
  -> (let Now (tl (assoc P Env))
          Kind (if (and (registers? B) (element? K [float word bits])) K slot)
       (cond ((and Kept (if (= Kind slot) (number? Now) (and (cons? Now) (= (hd Now) Kind))))
              (place B Env Ps Ks More Top [Now | Layout]))
             ((= Kind slot)
              (do (reserve B Top)
                  (if (and (cons? Now) (= (hd Now) bits))
                      (box-bits B Top (hd (tl Now)))
                      (emit B (to-slot Top Now)))
                  (place B Env Ps Ks More (+ Top 1) [Top | Layout])))
             (true (let R (if (= Kind float) (float-register B) (word-register B))
                     (do (if (and (= Kind bits) (number? Now))
                             (emit B [word-load64 R Now [const (constant B 0)]])
                             (emit B (to-register Kind R Now)))
                         (place B Env Ps Ks More Top [[Kind R] | Layout])))))))

\\ A raise's message is computed by calls, after which no register holds what it held: each register
\\ the message reads is boxed into a slot first, from Top up, and the message, made as boxed code,
\\ reads that. The new environment and the next free slot.
(define spill
  B Env [] Top -> [Env Top]
  B Env [V | Vs] Top
  -> (let Binding (assoc V Env)
       (if (and (cons? Binding) (cons? (tl Binding)) (element? (hd (tl Binding)) [float word bits]))
           (do (reserve B Top)
               (if (= bits (hd (tl Binding)))
                   (box-bits B Top (hd (tl (tl Binding))))
                   (emit B (to-slot Top (tl Binding))))
               (spill B [[V | Top] | Env] Vs (+ Top 1)))
           (spill B Env Vs Top))))

(define to-slot
  S [float R] -> [float-box S R]
  S [word W] -> [word-box S W]
  S From -> [move S From])

(define to-register
  float R [float From] -> [float-move R From]
  float R [word From] -> [float-from-word R From]
  float R From -> [float-number R From] where (number? From)
  word W [word From] -> [word-move W From]
  word W From -> [word-number W From] where (number? From)
  bits W [bits From] -> [word-move W From]
  _ _ _ -> (no-register))

\\ A tail call of a loop's own function, the definition's or an inlined one's, the innermost
\\ first: its arguments go to the parameters, the floats and fixnums among them to their
\\ registers, and the code goes back to the loop's head. Field 13 of the builder holds the
\\ loops, each [L Layout Params F], innermost first.
(define loops?
  B F Args -> (cons? (loop-of F (length Args) (<-address B 13))))

(define loop-of
  _ _ [] -> []
  F N [[L Layout Params F] | _] -> [L Layout Params F] where (= (length Params) N)
  F N [_ | Loops] -> (loop-of F N Loops))

(define shen-jit.lower.again
  B Env F Args Top
  -> (let Loop (loop-of F (length Args) (<-address B 13))
          Layout (hd (tl Loop))
          Indexed (append (map (/. W [[indexed W] | true]) (byte-indexed-each Env Args)) Env)
          Ordered (in-order Indexed (paired Args Layout))
       (do (loop-args B Indexed (map (/. A (hd A)) Ordered) (map (/. A (second A)) Ordered) Layout
                                     (if (> Top (+ (length Args) 2)) Top (+ (length Args) 2)) [] [])
           (emit B [again (hd Loop)]))))

(define paired
  [X | Xs] [Y | Ys] -> [[X Y] | (paired Xs Ys)]
  _ _ -> [])

\\ A loop's own arguments, each [X Place], in the order they are computed. One that cannot raise
\\ or write (effect-free?) can wait until no other argument reads its place, and is then computed
\\ into it, not into a new register moved there after: a step read by the sum after it, as a dot
\\ product's indices are. The others keep their order, left to right, which only they could show.
(define in-order
  _ [] -> []
  Env Args -> (let Next (next-arg Env Args (first-effect Env Args) Args)
                [Next | (in-order Env (remove Next Args))]))

\\ The first that may go now, one that is effect-free or the first that is not, whose place no
\\ other reads; else the first.
(define next-arg
  _ All _ [] -> (hd All)
  Env All First [A | As] -> A where (and (or (= A First) (effect-free? Env A))
                                         (not (place-read? Env (remove A All) (second A))))
  Env All First [_ | As] -> (next-arg Env All First As))

(define first-effect
  _ [] -> none
  Env [A | As] -> (if (effect-free? Env A) (first-effect Env As) A))

(define place-read?
  Env Args [Kind R] -> (reads-register? Env (map (/. A (hd A)) Args) [Kind R])
  Env Args S -> (reads? Env (map (/. A (hd A)) Args) S))

\\ Whether computing X into Place cannot raise or write: X is a variable already in that slot, or,
\\ for a register, a variable in a register of its kind, a constant, or a sum, difference or
\\ product of floats, or a sum of fixnums that is unchecked (word-op-of), over those, as inlining
\\ leaves them, in lets that rename.
(define effect-free?
  Env [[var V] S] -> true where (= (shen-jit.lower.slot V Env) S)
  Env [X [Kind _]] -> (computes-purely? Env Kind X)
  _ _ -> false)

(define computes-purely?
  Env Kind [var V] -> (in-kind? Kind V Env)
  _ _ [const _] -> true
  Env Kind [let inlining [const _] Body] -> (computes-purely? Env Kind Body)
  Env Kind [let X [var Y] Body] -> (computes-purely? [[X | (tl (assoc Y Env))] | Env] Kind Body)
      where (or (in-kind? float Y Env) (in-kind? word Y Env))
  Env float [prim Op [X Y]] -> (and (computes-purely? Env float X) (computes-purely? Env float Y))
      where (and (element? Op [+ - *]) (float-kind? Env [prim Op [X Y]]))
  Env word [prim + [X Y]] -> (and (computes-purely? Env word X) (computes-purely? Env word Y))
      where (and (word-kind? Env [prim + [X Y]]) (= (word-op-of Env + X Y) word+))
  _ _ _ -> false)

\\ Each argument computed into its parameter's place in Layout, a slot or a register, for a loop's
\\ own call or a named tail call (window 0). An argument already in its slot costs nothing, even
\\ when a later one reads it, since nothing else writes that slot; one whose slot a later argument
\\ still reads goes to a temporary at Top, and Moves puts it in place after the last argument. One
\\ for a register is computed into it at once when no later argument reads that register, as a
\\ loop's counters and sums are; otherwise into a new register, moved to its parameter's last,
\\ after every argument has read the parameters. A parameter's own register is then copied, as
\\ another parameter's move could overwrite it. What reads a register is any variable bound to it,
\\ as a let of a parameter is. Top starts above every parameter slot.
(define loop-args
  B _ [] _ _ _ Moves RMoves
  -> (do (map (/. M (emit B [move | M])) Moves)
         (map (/. M (emit B M)) RMoves))
  B Env [X | Xs] [[Kind R] | Ls] Layout Top Moves RMoves
  -> (do (into B Env Kind X R Top)
         (loop-args B Env Xs Ls Layout Top Moves RMoves))
      where (not (reads-register? Env Xs [Kind R]))
  B Env [X | Xs] [[Kind R] | Ls] Layout Top Moves RMoves
  -> (let T (if (= Kind float) (shen-jit.lower.float B Env X Top) (shen-jit.lower.word B Env X Top))
          Move (if (= Kind float) float-move word-move)
          Kept (if (and (element? [Kind T] Layout) (not (= T R)))
                   (let C (if (= Kind float) (float-register B) (word-register B))
                     (do (emit B [Move C T]) C))
                   T)
       (loop-args B Env Xs Ls Layout Top Moves
                                 (if (= Kept R) RMoves [[Move R Kept] | RMoves])))
  B Env [[var X] | Xs] [S | Ls] Layout Top Moves RMoves
  -> (loop-args B Env Xs Ls Layout Top Moves RMoves)
      where (= (shen-jit.lower.slot X Env) S)
  B Env [X | Xs] [S | Ls] Layout Top Moves RMoves
  -> (do (shen-jit.lower.value B Env X Top (+ Top 1))
         (loop-args B Env Xs Ls Layout (+ Top 1) [[S Top] | Moves] RMoves))
      where (reads? Env Xs S)
  B Env [X | Xs] [S | Ls] Layout Top Moves RMoves
  -> (do (shen-jit.lower.value B Env X S Top)
         (loop-args B Env Xs Ls Layout Top Moves RMoves)))

\\ The word registers of the variables that Xs read or write bytes at as the index itself, wherever
\\ they run whatever the tests decide: not in a branch of an if, and or or, nor in a closure.
(define byte-indexed-each
  Env Xs -> (mapcan (/. X (byte-indexed Env X)) Xs))

(define byte-indexed
  Env [prim Op [M [var P] | Rest]] -> (append (word-of Env P) (byte-indexed-each Env [M | Rest]))
      where (element? Op [shen-jit.u8 shen-jit.u16 shen-jit.u32 shen-jit.s32 shen-jit.s64 shen-jit.f64
                          shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.s32! shen-jit.s64! shen-jit.f64!])
  Env [prim _ Args] -> (byte-indexed-each Env Args)
  Env [call _ Args] -> (byte-indexed-each Env Args)
  Env [let X V Body] -> (append (byte-indexed Env V) (byte-indexed [[X | none] | Env] Body))
  Env [do X Y] -> (append (byte-indexed Env X) (byte-indexed Env Y))
  Env [if C _ _] -> (byte-indexed Env C)
  Env [and X _] -> (byte-indexed Env X)
  Env [or X _] -> (byte-indexed Env X)
  _ _ -> [])

\\ Whether X has some [var V] with V bound to register Kind R, among the variables vars-of
\\ finds, bound ones included.
(define reads-register?
  Env X KR -> (element? true (map (/. V (let Binding (assoc V Env)
                                          (and (cons? Binding) (= (tl Binding) KR))))
                                  (vars-of X))))

\\ X computed into register R: its last instruction writes R, when it is arithmetic, or it is
\\ moved there. Its operands are read before R is written.
(define into
  B Env float [prim Op [X Y]] R Top
  -> (released B (freeze (float-arithmetic-to B Env Op X Y Top R)))
      where (and (element? Op [+ - * /]) (float-kind? Env [prim Op [X Y]]))
  B Env word [prim Op [X Y]] R Top
  -> (released B (freeze (word-arithmetic-to B Env Op X Y Top R)))
      where (and (element? Op [+ - * shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor])
                 (word-kind? Env X) (word-kind? Env Y))
  B Env Kind [let inlining [const F] Body] R Top
  -> (mark B F (freeze (into B Env Kind Body R Top)))
  B Env Kind [let X V Body] R Top
  -> (released B (freeze (into B (bound-to B Env X V Top)
                                                             Kind Body R Top)))
      where (unboxed? B Env V)
  B Env Kind [let X [var Y] Body] R Top
  -> (into B [[X | (shen-jit.lower.slot Y Env)] | Env] Kind Body R Top)
      where (number? (shen-jit.lower.slot Y Env))
  B Env float X R Top
  -> (released B (freeze (let T (shen-jit.lower.float B Env X Top)
                                           (if (= T R) skip (emit B [float-move R T])))))
  B Env bits [prim shen-jit.word-op [[const Op] X Y]] R Top
  -> (released B (freeze (word-op-to B Env Op X Y Top R)))
      where (= bits (word-op-kind Env Op X Y))
  B Env Kind X R Top
  -> (released B (freeze (let T (shen-jit.lower.word B Env X Top)
                                           (if (= T R) skip (emit B [word-move R T])))))
      where (element? Kind [word bits]))

\\ ---------------------------------------------------------------------------
\\ Inline forms of code in registers. A typed function that keeps its values in registers is
\\ inlined into a caller that does too, though larger than inlining otherwise allows, and one that
\\ is a loop becomes a loop of the caller's: inline-form and call (inline.shen) come here for them.

\\ The inline form of F, whose Code is made; else, when Code keeps values in registers, which it
\\ does only when it calls nothing but on its way out, a body of up to 800 nodes, marked typed, or
\\ calling when it calls at all (inline-at), which only a
\\ definition that keeps values in registers too inlines: a loop over such a function, as over
\\ the force between two bodies, then keeps its own values in registers round it. A body that
\\ calls F, which such code does only in tail position, as its loop, is marked loop, with where
\\ each parameter goes (param-kinds), and such a definition inlines it as a loop of its own.
(define inline-of
  F Params Body Sealed Code Kinds
  -> (let Inline (inline-form F Params Body (cons? Sealed))
       (cond ((or (cons? Inline) (not (value *typed*)) (not (computes? (instructions Code)))
                  (> (size Body) 800))
              Inline)
             ((inlinable? F Body false) [Params Body (if (calls-nothing? (instructions Code)) typed calling)])
             \\ inlinable? with a name no body has, as Body calls F
             ((and (inlinable? shen-jit.lower.loop Body false)
                   (loops-in? (instructions Code))
                   (not (or (element? let Params) (element? lambda Params))))
              [Params Body loop Kinds])
             (true []))))

(define instructions
  [code _ _ _ _ Is | _] -> Is)

(define loops-in?
  [] -> false
  [[loop | _] | _] -> true
  [_ | Is] -> (loops-in? Is))

(define loop-form?
  [_ _ loop _] -> true
  _ -> false)

\\ A loop inlined: the arguments go to fresh variables and the parameters to those, as for any
\\ body, and the body, normalised in its own scope with its calls of F left as calls, goes under
\\ [let shen-jit.lower.loop [const Info] Body], which the emitter makes a loop of the caller's
\\ (inlined-loop). Info is [F Kinds Result Params Kept]: where each parameter goes, as in F's own
\\ code; what the loop gives, float, word or slot; and, for each parameter, whether F's calls of
\\ itself pass it on as it is. A number argument stays an argument, as the loop changes it. A
\\ parameter that the loop passes on as it is, given true or false here, is that constant in the
\\ body before it is normalised, so that a test of it goes, in this loop and in loops inlined into
\\ it, rather than reading it each round.
(define inline-loop
  F [Params Body loop Kinds] Args
  -> (let Looping (value *looping*)
          Within (set *looping* [F | Looping])
          N (length Params)
          Normal (inlined-norm F Params (fix-kl F N (fixed-flags F N Params Args 1 Body) Body))
          Out (set *looping* Looping)
          Fresh (map (/. P (shen-jit.lower.fresh arg)) Params)
          Result (result-kind (exits F (kinds-env Params Kinds) Normal))
          Info [F Kinds Result Params (kept F Params Normal)]
       (lets Fresh Args
                            (lets Params (map (/. X [var X]) Fresh)
                                                 [let shen-jit.lower.loop [const Info] Normal]))))

\\ Each parameter that every call of F with N arguments in Body passes on as it is, given true or
\\ false in Args, as [I P C]: its position, its name and the constant.
(define fixed-flags
  _ _ [] _ _ _ -> []
  F N [P | Ps] [[const C] | As] I Body -> [[I P C] | (fixed-flags F N Ps As (+ I 1) Body)]
      where (and (boolean? C) (kl-passed? F N I P Body))
  F N [_ | Ps] [_ | As] I Body -> (fixed-flags F N Ps As (+ I 1) Body)
  _ _ _ _ _ _ -> [])

\\ Whether nothing in the KLambda X binds P and every call of F with N arguments passes P as its
\\ I-th.
(define kl-passed?
  _ _ _ P [let P _ _] -> false
  _ _ _ P [lambda P _] -> false
  F N I P [F | Args] -> (and (= (nth I Args) P) (kl-passed-each? F N I P Args)) where (= (length Args) N)
  F N I P [X | Xs] -> (kl-passed-each? F N I P [X | Xs])
  _ _ _ _ _ -> true)

(define kl-passed-each?
  F N I P [X | Xs] -> (and (kl-passed? F N I P X) (kl-passed-each? F N I P Xs))
  _ _ _ _ _ -> true)

\\ The KLambda X with each parameter of Fixed its constant, but where F's calls of itself pass
\\ it on.
(define fix-kl
  _ _ [] X -> X
  F N Fixed [F | Args] -> [F | (fix-args F N Fixed Args 1)] where (= (length Args) N)
  _ _ Fixed P -> (hd (tl (tl (flag-entry P Fixed)))) where (and (symbol? P) (cons? (flag-entry P Fixed)))
  F N Fixed [X | Xs] -> (map (/. Y (fix-kl F N Fixed Y)) [X | Xs])
  _ _ _ X -> X)

(define fix-args
  _ _ _ [] _ -> []
  F N Fixed [A | As] I -> (let E (flag-entry A Fixed)
                            [(if (and (cons? E) (= (hd E) I)) A (fix-kl F N Fixed A))
                             | (fix-args F N Fixed As (+ I 1))]))

(define flag-entry
  _ [] -> []
  P [[I P C] | _] -> [I P C]
  P [_ | Fixed] -> (flag-entry P Fixed))

(define kinds-env
  [] _ -> []
  [P | Ps] [float | Ks] -> [[P float 0] | (kinds-env Ps Ks)]
  [P | Ps] [word | Ks] -> [[P word 0] | (kinds-env Ps Ks)]
  [P | Ps] [bits | Ks] -> [[P bits 0] | (kinds-env Ps Ks)]
  [P | Ps] [_ | Ks] -> [[P | 0] | (kinds-env Ps Ks)])

\\ The kinds X gives in tail position; a call of F, which goes back to the loop's head, gives none,
\\ and nor does shen.f-error, which raises.
(define exits
  F Env [if _ X Y] -> (union (exits F Env X) (exits F Env Y))
  F Env [let inlining _ X] -> (exits F Env X)
  _ _ [let shen-jit.lower.loop [const Info] _] -> [(loop-result Info)]
  F Env [let G [freeze E] X] -> (union (exits F Env E)
                                       (exits F [[G frozen] | Env] X))
  _ Env [apply [var G]] -> [] where (in-kind? frozen G Env)
  F Env [let X V Body] -> (exits F [[X | (kind-of Env V)] | Env] Body)
  F Env [do _ Y] -> (exits F Env Y)
  F _ [call F _] -> []
  _ _ [call shen.f-error _] -> []
  _ Env X -> [(let K (kind Env X) (if (element? K [float word bits]) K slot))])

(define result-kind
  [float] -> float
  [word] -> word
  [bits] -> bits
  _ -> slot)

(define loop-result
  [_ _ Result | _] -> Result)

\\ For each parameter, whether every call of F in X passes it on as it is: [var P] in its place,
\\ with P bound nowhere in X.
(define kept
  F Params X -> (kept-each Params 1 (self-calls F (length Params) X)
                                          (binders X)))

(define kept-each
  [] _ _ _ -> []
  [P | Ps] N Calls Bound -> [(and (not (element? P Bound)) (passed? [var P] N Calls))
                             | (kept-each Ps (+ N 1) Calls Bound)])

(define passed?
  _ _ [] -> true
  X N [Args | Calls] -> (and (= (nth N Args) X) (passed? X N Calls)))

\\ The arguments of each call of F with N of them in X.
(define self-calls
  F N [call F Args] -> [Args | (self-calls-each F N Args)] where (= (length Args) N)
  _ _ [const _] -> []
  F N [X | Xs] -> (self-calls-each F N [X | Xs])
  _ _ _ -> [])

(define self-calls-each
  F N [X | Xs] -> (append (self-calls F N X) (self-calls-each F N Xs))
  _ _ _ -> [])

\\ ---------------------------------------------------------------------------
\\ Exits of inlined loops, and what a test tells of a fixnum in a register, which emission's if
\\ (emit.shen) passes down each branch.

\\ X at an exit of an inlined loop: its value goes where the loop gives it, then on past the loop.
\\ shen.f-error, which the kernel calls where a partial function's clauses end, raises: it stays
\\ the tail call it is in the loop's own code, so that a loop with such an end keeps its registers.
(define shen-jit.lower.exit
  B Env [call shen.f-error Args] _ _ _ Top -> (expr B Env [call shen.f-error Args] tail Top)
  B Env X slot D End Top -> (do (shen-jit.lower.value B Env X D Top) (emit B [jump End]))
  B Env X effect _ End Top -> (do (if (simple? [X]) skip (shen-jit.lower.effect B Env X Top))
                                  (emit B [jump End]))
  B Env X Kind R End Top -> (do (into B Env Kind X R Top) (emit B [jump End])))

\\ Env with what C being Truth tells of a fixnum in a register W, [[below W] | true] when it is
\\ less than another fixnum, so that one more is a fixnum too: P in (< P E) and (> E P) when true,
\\ and in (>= P E) and (<= E P) when false. C is seen through the lets of inlined calls, whose
\\ variables share their registers when bound to variables. Only code with registers asks.
(define bounded
  B Env C Truth -> (let W (if (registers? B) (shen-jit.lower.below Env C Truth) none)
                     (if (number? W) [[[below W] | true] | Env] Env)))

(define shen-jit.lower.below
  Env [let inlining _ C] Truth -> (shen-jit.lower.below Env C Truth)
  Env [let X [var Y] C] Truth
  -> (let Binding (assoc Y Env)
       (shen-jit.lower.below [[X | (if (cons? Binding) (tl Binding) none)] | Env] C Truth))
  Env [let X V C] Truth -> (let Kind (kind-of Env V)
                             (shen-jit.lower.below [[X | (if (and (cons? Kind) (exact? Env V)) [(hd Kind) none] none)]
                                                    | Env] C Truth))
  Env [prim Op [P E]] Truth -> (below-of Env P E)
      where (or (and Truth (= Op <)) (and (not Truth) (= Op >=)))
  Env [prim Op [E P]] Truth -> (below-of Env P E)
      where (or (and Truth (= Op >)) (and (not Truth) (= Op <=)))
  _ _ _ -> none)

(define below-of
  Env [var P] E -> (let Ws (word-of Env P)
                     (if (and (cons? Ws) (word-kind? Env E) (exact? Env E)) (hd Ws) none))
  _ _ _ -> none)

(define second
  [_ X | _] -> X
  _ -> none)

\\ Facts that each parameter in a word register of its own may hold a sum past the greatest fixnum:
\\ one not kept, which starts with such a sum (Starts, for an inlined loop), which the body binds
\\ again (Bound), so that an own call's P may be another, or which some own call, given by its
\\ arguments, passes a value that may be one (step-exact?).
(define stepped
  [P | Ps] [Place | Layout] [Keep | Kept] Starts Calls Bound I
  -> (let Rest (stepped Ps Layout Kept (if (cons? Starts) (tl Starts) []) Calls Bound (+ I 1))
       (if (and (cons? Place) (= word (hd Place)) (not Keep)
                (or (and (cons? Starts) (hd Starts)) (element? P Bound) (not (steps-exact? P I Calls))))
           [[[past (hd (tl Place))] | true] | Rest]
           Rest))
  _ _ _ _ _ _ _ -> [])

(define steps-exact?
  _ _ [] -> true
  P I [Args | Calls] -> (and (step-exact? P (nth I Args)) (steps-exact? P I Calls)))

\\ Whether an own call's argument for P is no sum left unchecked: P as it is, a constant, a call's
\\ result or a checked primitive's (exact?), through the lets of inlined calls.
(define step-exact?
  P [var P] -> true
  _ [const _] -> true
  _ [call _ _] -> true
  _ [prim Op _] -> (not (element? Op [+ shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.shift-left
                                      shen-jit.shift-right]))
  _ [let shen-jit.lower.loop _ _] -> false
  P [let P _ Body] -> (step-exact? [] Body)
  P [let _ _ Body] -> (step-exact? P Body)
  P [do _ Y] -> (step-exact? P Y)
  P [if _ X Y] -> (and (step-exact? P X) (step-exact? P Y))
  _ _ -> false)

\\ A let's X bound to V, as [Env | Top] for its body: in a register (bound-to), in the slot of the
\\ variable V is, or in a new slot, Top, whose value V is.
(define let-bound
  B Env X V Top -> [(bound-to B Env X V Top) | Top] where (unboxed? B Env V)
  B Env X [var Y] Top -> [[[X | (shen-jit.lower.slot Y Env)] | Env] | Top]
      where (number? (shen-jit.lower.slot Y Env))
  B Env X V Top -> (do (shen-jit.lower.value B Env V Top (+ Top 1)) [[[X | Top] | Env] | (+ Top 1)]))

\\ Env with X bound to V's value in a register, and, for a fixnum that may be past the greatest,
\\ as an unchecked sum may be, that fact.
(define bound-to
  B Env X V Top -> (let Unboxed (unbox B Env V Top)
                     (if (or (not (= word (hd Unboxed))) (exact? Env V))
                         [[X | Unboxed] | Env]
                         [[[past (second Unboxed)] | true] [X | Unboxed] | Env])))

\\ Whether X's value is a fixnum when it is one, not a sum left unchecked: a constant, a call's
\\ result, a variable in a slot or in a word register with no fact that it may be past the
\\ greatest fixnum, or a primitive's. A checked one's value is a fixnum whatever it read, as such a
\\ sum is below 2^62, so that nothing computed from it passes 64 bits unseen; + is checked unless
\\ word-op-of finds it a step, and a bit operation or a shift passes on what it reads. Under an if
\\ within X, whose test may find a variable below another and make a + a step, no + is checked.
(define exact?
  Env X -> (exact-in? Env X false))

(define exact-in?
  _ [const _] _ -> true
  Env [var X] _ -> (exact-binding? Env (assoc X Env))
  _ [call _ _] _ -> true
  Env [prim + [X Y]] Branch -> (and (not Branch) (= fix+ (word-op-of Env + X Y)))
  Env [prim Op Args] Branch -> (exact-each? Env Args Branch)
      where (element? Op [shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.shift-left
                          shen-jit.shift-right])
  _ [prim _ _] _ -> true
  Env [do _ Y] Branch -> (exact-in? Env Y Branch)
  Env [if _ X Y] _ -> (and (exact-in? Env X true) (exact-in? Env Y true))
  _ [let shen-jit.lower.loop _ _] _ -> false
  Env [let X V Body] Branch -> (exact-in? [[X | (tl (assoc (alias-of V) Env))] | Env] Body Branch)
      where (cons? (assoc (alias-of V) Env))
  Env [let X V Body] Branch
  -> (exact-in? [[X | (if (exact-in? Env V Branch) [word none] none)] | Env] Body Branch)
  _ _ _ -> false)

\\ The variable a let's value is, through the lets inlining leaves, which the let's variable then
\\ shares, as let-bound binds it; else [].
(define alias-of
  [var Y] -> Y
  [let inlining _ E] -> (alias-of E)
  [do _ E] -> (alias-of E)
  _ -> [])

(define exact-binding?
  Env [_ word W] -> (not (cons? (assoc [past W] Env)))
  _ [_ | none] -> false
  _ [_ | _] -> true
  _ _ -> false)

(define exact-each?
  _ [] _ -> true
  Env [X | Xs] Branch -> (and (exact-in? Env X Branch) (exact-each? Env Xs Branch))))

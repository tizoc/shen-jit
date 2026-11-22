\\ Numbers by kind (lib/numbers.shen, docs/numbers.md), and typed definitions compiled with their types
\\ (docs/modules.md, Typed programs). Run from the repository's root:
\\   shen-jit eval -l tests/typed.shen

(set typed.passed 0)
(set typed.failed 0)

(define typed.check
  Name Expected Got -> (if (= Expected Got)
                           (set typed.passed (+ 1 (value typed.passed)))
                           (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                               (set typed.failed (+ 1 (value typed.failed))))))

\\ Empty-context datatype search must pass through bindings, retries and cuts.
(defprolog typed.first-choice [first] _ <--;)
(defprolog typed.next-choice [second] _ <--;)
(let Rules [[first | (fn typed.first-choice)] [second | (fn typed.next-choice)]]
  (typed.check "empty-context choices in order, with backtracking and with a cut"
    [first second false]
    [(prolog? (shen.search-user-datatypes [X] [] (receive Rules)) (return X))
     (prolog? (shen.search-user-datatypes [X] [] (receive Rules)) (is! X second) (return X))
     (prolog? (shen.search-user-datatypes [X] [] (receive Rules)) ! (is! X second))]))

\\ The first N characters of S.
(define typed.prefix
  0 _ -> ""
  _ "" -> ""
  N (@s C S) -> (@s C (typed.prefix (- N 1) S)))

\\ Whether F's code has an instruction Op.
(define typed.has?
  Op F -> (let Code (hd (tl (tl (shen-jit.code F))))
            (typed.has-in? Op (hd (tl (tl (tl (tl (tl Code)))))))))

(define typed.has-in?
  _ [] -> false
  Op [[Op | _] | _] -> true
  Op [_ | Is] -> (typed.has-in? Op Is))

\\ How many of instruction Op F's code has.
(define typed.count
  Op F -> (let Code (hd (tl (tl (shen-jit.code F))))
            (length (typed.ops Op (hd (tl (tl (tl (tl (tl Code))))))))))

(define typed.ops
  _ [] -> []
  Op [[Op | X] | Is] -> [[Op | X] | (typed.ops Op Is)]
  Op [_ | Is] -> (typed.ops Op Is))

\\ Whether X appears anywhere in a tree.
(define typed.mentions?
  X X -> true
  X [Y | Z] -> (or (typed.mentions? X Y) (typed.mentions? X Z))
  _ _ -> false)

\\ What the typechecker gives X for T, or false.
(define typed.as
  X T -> (shen.typecheck X T))

\\ The image has no number types: they are module numbers (lib/numbers.shen).
(typed.check "no fixnum in the image" false (typed.as 2 fixnum))
(typed.check "nor float" false (typed.as [fn float] [number --> float]))
(typed.check "module numbers" [numbers] (do (shen-jit.seal +) (let M (module.use [numbers]) (do (shen-jit.seal -) M))))

\\ Numbers: literals by kind, neither kind a number, operators within a kind, and conversions.
(typed.check "a float literal is a float" float (typed.as 1.5 float))
(typed.check "an integer literal is a fixnum" fixnum (typed.as 2 fixnum))
(typed.check "an integer literal is not a float" false (typed.as 2 float))
(typed.check "a literal is a number too" [number number] [(typed.as 2 number) (typed.as 1.5 number)])
(typed.check "a float is not a number" false (typed.as [lambda X X] [float --> number]))
(typed.check "nor a fixnum" false (typed.as [lambda X X] [fixnum --> number]))
(typed.check "nor a number a float" false (typed.as [lambda X X] [number --> float]))
(typed.check "float operators" [float float float float]
  (map (/. Op (typed.as [Op 1.5 2.5] float)) [fl+ fl- fl* fl/]))
(typed.check "float comparisons" [boolean boolean boolean boolean]
  (map (/. Op (typed.as [Op 1.5 2.5] boolean)) [fl< fl> fl<= fl>=]))
(typed.check "a square root" float (typed.as [flsqrt 2.25] float))
(typed.check "fixnum operators" [fixnum fixnum fixnum]
  (map (/. Op (typed.as [Op 3 4] fixnum)) [fx+ fx- fx*]))
(typed.check "fixnum comparisons" [boolean boolean boolean boolean]
  (map (/. Op (typed.as [Op 3 4] boolean)) [fx< fx> fx<= fx>=]))
(typed.check "the bit operations" fixnum (typed.as [shen-jit.bit-and 6 3] fixnum))
(typed.check "number operators on floats" false (typed.as [lambda X [+ X X]] [float --> float]))
(typed.check "float operators on numbers" false (typed.as [lambda X [fl+ X X]] [number --> float]))
(typed.check "kinds do not mix" false (typed.as [lambda X [fl+ X 1]] [float --> float]))
(typed.check "conversions" [float [fixnum --> float] [float --> number] [fixnum --> number] fixnum]
  [(typed.as [float 2] float) (typed.as [lambda X [fx->fl X]] [fixnum --> float])
   (typed.as [lambda X [fl->number X]] [float --> number]) (typed.as [lambda X [fx->number X]] [fixnum --> number])
   (typed.as [fixnum 2] fixnum)])
(typed.check "float's type" [number --> float] (typed.as [fn float] [number --> float]))

\\ The operators and conversions at run time, from untyped code.
(typed.check "operators" [4.0 -1.0 3.75 (/ 1.5 2.5) true false 1.5 7 -1 12 true]
  [(fl+ 1.5 2.5) (fl- 1.5 2.5) (fl* 1.5 2.5) (fl/ 1.5 2.5) (fl< 1.5 2.5) (fl>= 1.5 2.5) (flsqrt 2.25)
   (fx+ 3 4) (fx- 3 4) (fx* 3 4) (fx< 3 4)])
(typed.check "integers made floats" [3.0 false] [(fl+ 1 2) (shen-jit.fixnum? (fl+ 1 2))])
(typed.check "not a number" "c#34;ac#34; is not a number" (trap-error (fl+ "a" 1.5) (/. E (error-to-string E))))
(typed.check "conversions at run time" [2.0 2.0 1.5 3 3] [(float 2) (fx->fl 2) (fl->number 1.5) (fx->number 3) (fixnum 3)])
(typed.check "not a fixnum" "3.5 is not a fixnum" (trap-error (fixnum 3.5) (/. E (error-to-string E))))
(typed.check "a square root of an integer" 1.4142135623730951 (flsqrt 2))

\\ float at run time: an integer as a float, a float as it is.
(typed.check "float of an integer" "2.0" (str (float 2)))
(typed.check "is a float" false (shen-jit.fixnum? (float 2)))
(typed.check "equal to the integer" true (= (float 2) 2))
(typed.check "float of a float" 1.5 (float 1.5))
(typed.check "float of a string raises" "c#34;ac#34; is not a number"
  (trap-error (float "a") (/. E (error-to-string E))))

\\ Typed definitions over both kinds, in a module that requires numbers, checked when loaded and then
\\ run; a module that does not require it does not see its rules.
(typed.check "typed definitions load" [arith] (module.load "tests/typed/arith.shenmod"))
(typed.check "not without numbers" "type error"
  (trap-error (module.load "tests/typed/unrequired.shenmod") (/. E (typed.prefix 10 (error-to-string E)))))
(typed.check "a square" 2.25 (typed-sq 1.5))
(typed.check "a literal's fixnum, in a binding, at no cost" [5 3 false]
  [(typed-step true 4) (typed-step false 4) (typed.mentions? shen-jit.fixnum? (shen-jit.code typed-step))])
(typed.check "an orbit" 3 (typed-orbit 0.5 1.5 5))
(typed.check "a mean" 2.5 (typed-mean 1.5 3.5))
(typed.check "a sum of steps" 55 (typed-steps 10 0))
(typed.check "widened" 3.5 (typed-widen 2 1.5))
(typed.check "literal bindings by numeric kind" (@p 3 3 4) (typed-bound-literals))

(typed.check "fixnum equality in both orders" [true false]
  [(typed-fx-zero? 0) (typed-fx-zero? 1)])
(typed.check "early fixnum literal in polymorphic calls" [0 5] (typed-fx-zero-prefix [5]))

\\ Under (optimise +), a definition that typechecks is compiled annotated (src/port/shen-jit.kl,
\\ shen-jit.compiled-kl), and the lowerer makes the same code as without its annotations.
(typed.check "not annotated without optimise" false (tl (get typed-sq shen-jit.annotated)))
(optimise +)
(typed.check "shapes load" [shapes] (module.load "tests/typed/shapes.shenmod"))
(optimise -)

(set typed.shapes [shape-count shape-initial shape-either shape-scale shape-second shape-frozen])

\\ Whether F's annotations change its KLambda, so that comparing code says something.
(define typed.annotations?
  F -> (let Kl (shen.factor (ps F))
         (not (= Kl (shen.x.type-annotations.annotate-kl Kl)))))

\\ Whether F's code is the same with its annotations as without them.
(define typed.same-code?
  F -> (let Entry (get F shen-jit.annotated)
            Annotated (shen-jit.code F)
            Plain (do (put F shen-jit.annotated [(hd Entry) | false]) (shen-jit.code F))
         (do (put F shen-jit.annotated Entry) (= Annotated Plain))))

(typed.check "each annotated" (map (/. F true) (value typed.shapes))
  (map (/. F (tl (get F shen-jit.annotated))) (value typed.shapes)))
(typed.check "each with annotations" (map (/. F true) (value typed.shapes))
  (map (fn typed.annotations?) (value typed.shapes)))
(typed.check "each the same code" (map (/. F true) (value typed.shapes))
  (map (fn typed.same-code?) (value typed.shapes)))
(typed.check "and runs" [3 "a" b [2.0 4.0] 15 2 4]
  [(shape-count [a b c]) (shape-initial "abc")
   (shape-either false a b) (shape-scale 2 [1 2]) (shape-local 4) (shape-second (@p 1 2))
   (thaw (shape-frozen 3))])
(typed.check "but floats and fixnums in registers" [true 6.5 true 25.0 true 15]
  [(typed.has? float+ shape-sum) (shape-sum [1.5 5] 0) (typed.has? float* shape-norm) (shape-norm [pt 3 4])
   (typed.has? fix* shape-local) (shape-local 4)])
(typed.check "not what a datatype makes" false (tl (get (intern "shape-pair#type") shen-jit.annotated)))

\\ A typed definition that raises as it is evaluated leaves nothing marked as checked.
(define typed.load-typed
  File -> (do (tc +) (let R (trap-error (load File) (/. E failed)) (do (tc -) R))))
(shen-jit.seal +)
(typed.check "sealed once" loaded (typed.load-typed "tests/typed/sealed.shen"))
(shen-jit.seal -)
(typed.check "then refused" failed (typed.load-typed "tests/typed/sealed.shen"))
(typed.check "nothing marked" false (value shen-jit.*checked*))

\\ Floats in registers (src/lowerer/registers.shen): sealed, so that a definition's own tail
\\ calls loop, with the same results as the arithmetic boxed.
(shen-jit.seal +)
(optimise +)
(typed.check "float registers load" [float-registers] (module.load "tests/typed/float-registers.shenmod"))
(optimise -)
(shen-jit.seal -)

(typed.check "a loop in registers" [true true false]
  [(typed.has? again float-orbit) (typed.has? float* float-orbit) (typed.has? float-box float-orbit)])
(typed.check "an orbit" [100 15 0] [(float-orbit 0.0 0.0 -0.5 0.5 0 100) (float-orbit 0.0 0.0 0.3 0.6 0 100)
                                    (float-orbit 1.5 1.5 0.0 0.0 0 100)])
(typed.check "parameters swapped" (- (+ 1.5 0.5) (+ 2.5 0.5)) (float-swap 2 1.5 2.5))
(typed.check "and swapped back" (- (+ 2.5 0.5) (+ 1.5 1)) (float-swap 3 1.5 2.5))
(typed.check "a float by a test" [5.0 7.5] [(float-pick true 2.0 3.0) (float-pick false 2.0 3.0)])
(typed.check "comparisons as values" [[true false true false false] [false false true true true]]
  [(float-order 1.5 2.5) (float-order 2.5 2.5)])
(typed.check "comparisons of floats" true (typed.has? float-unless< float-order))

\\ Call the compiled definitions through apply: inlining them into this untyped caller would
\\ hide a wrong comparison in their register code. Test all four relations in both orders.
(define typed.mixed-order
  Name Expected R N
  -> (typed.check Name [Expected Expected]
       [(shen-jit.apply (shen-jit.function float-word-order) [R N])
        (shen-jit.apply (shen-jit.function float-number-order) [R N])]))
(typed.check "mixed comparisons beside register arithmetic" [true true]
  [(typed.has? float+ float-word-order) (typed.has? float+ float-number-order)])
(typed.mixed-order "positive fixnum past double precision"
  [true false true false false true false true] (float 9007199254740992) 9007199254740993)
(typed.mixed-order "negative fixnum past double precision"
  [false true false true true false true false] (float -9007199254740992) -9007199254740993)
(typed.mixed-order "largest fixnum below its rounded float"
  [false true false true true false true false] (float 2305843009213693951) 2305843009213693951)
(typed.mixed-order "fixnum above the least fixnum's float"
  [true false true false false true false true] (float -2305843009213693952) -2305843009213693951)
(typed.mixed-order "exactly equal across kinds"
  [false false true true false false true true] (float 9007199254740992) 9007199254740992)
(typed.check "an unknown number can be a float" [true false true false false true false true]
  (shen-jit.apply (shen-jit.function float-number-order) [1.5 2.5]))

(typed.check "mixed arithmetic keeps an integer sum exact"
  [(+ 0.5 (+ 9007199254740993 1)) "integer overflow"]
  [(shen-jit.apply (shen-jit.function float-mixed-sum) [0.5 9007199254740993 1])
   (trap-error (shen-jit.apply (shen-jit.function float-mixed-sum) [0.5 2305843009213693951 1])
               (/. E (error-to-string E)))])
(typed.check "a sealed call of no arguments, not inlined" 58 (float-after-later 30))
(typed.check "a quotient" (/ 1.5 2.5) (float-quotient 1.5 2.5))
(typed.check "a square root in a register" [true 5.0] [(typed.has? float-sqrt float-hypot) (float-hypot 3 4)])
(typed.check "by zero, as /" (trap-error (/ 1.5 (- 0.5 0.5)) (/. E (error-to-string E)))
  (trap-error (float-quotient 1.5 (- 0.5 0.5)) (/. E (error-to-string E))))
(typed.check "by a negative zero, and by a NaN, which divides, as /"
  ["division by zero" "division by zero" divided divided]
  (map (/. Q (trap-error (do (Q 1.5 (* -0.5 (- 0.5 0.5))) (Q 1.5 (shen-jit.sqrt -1)) divided)
                         (/. E (error-to-string E))))
       [(/. X Y (/ X Y)) (/. X Y (float-quotient X Y))
        (/. X Y (/ X (shen-jit.sqrt -1))) (/. X Y (float-quotient X (shen-jit.sqrt -1)))]))
(typed.check "the divisor tested out of line" [true false]
  [(typed.has? float-divide float-quotient) (typed.has? float-unless= float-quotient)])
(typed.check "integers and floats" 2.5 (float-mean [1 2 3 4] 0 (float 0)))
(typed.check "conversion in registers" false (typed.has? call float-mean))
(define typed.smoothed
  -> (let B (shen-jit.bytes 32)
          _ (shen-jit.f64! B 0 1.0)
          _ (shen-jit.f64! B 8 2.0)
          _ (shen-jit.f64! B 16 4.0)
          _ (shen-jit.f64! B 24 8.0)
          _ (float-smooth B 8 24)
       [(shen-jit.f64 B 8) (shen-jit.f64 B 16)]))
(typed.check "stored from registers" [2.5 5.25] (typed.smoothed))
(typed.check "with no float parameter" [true false] [(typed.has? float-store-at float-smooth) (typed.has? float-box float-smooth)])
(typed.check "a loop inlined" [true false 1.0]
  [(typed.has? float+ float-twice) (typed.has? call-sealed float-twice) (float-twice 1.0)])
\\ An untyped caller can pass what the types do not allow: an integer is read as a float, and anything
\\ else raises as arithmetic on it would.
(typed.check "an integer for a float" [5.0 12.5] [(float-pick true 2 3) (float-pick false 2.0 5)])
(typed.check "a string for a float" "c#34;ac#34; is not a number"
  (trap-error (float-pick true "a" 1.0) (/. E (error-to-string E))))

\\ Struct fields (src/lowerer/normalise.shen, field?): a typechecked call of a sealed reader reads the field
\\ with no check; untyped code, and untyped bodies inlined into typed code, keep theirs, and so do writes.
(shen-jit.seal +)
(optimise +)
(typed.check "fields load" [fields] (module.load "tests/typed/fields.shenmod"))
(optimise -)
(shen-jit.seal -)

\\ How many reads of a field F's code has with no check, and with one.
(define typed.reads
  F -> (let Code (hd (tl (tl (shen-jit.code F))))
            Is (hd (tl (tl (tl (tl (tl Code))))))
         [(typed.count-prim shen-jit.field Is) (typed.count-prim shen-jit.struct-ref Is)]))

(define typed.count-prim
  _ [] -> 0
  Op [[prim _ Op | _] | Is] -> (+ 1 (typed.count-prim Op Is))
  Op [_ | Is] -> (typed.count-prim Op Is))

(typed.check "typed reads" [2 0] (typed.reads spot-sum))
(typed.check "through a typed definition inlined" [4 0] (typed.reads spot-twice))
(typed.check "a write keeps its check" [1 1]
  (let Code (hd (tl (tl (shen-jit.code spot-bump))))
       Is (hd (tl (tl (tl (tl (tl Code))))))
    [(typed.count-prim shen-jit.field Is) (typed.count-prim address-> Is)]))
(typed.check "untyped reads" [[0 1] [0 2] [0 1]]
  [(typed.reads spot-x-untyped) (typed.reads spot-sum-untyped) (typed.reads spot-x-declared)])
(typed.check "an untyped body inlined" [0 1] (typed.reads spot-via))
(define typed.spot -> (spot.make 3 4))
(typed.check "and the values" [7 14 5 3 7 3]
  [(spot-sum (typed.spot)) (spot-twice (typed.spot)) (spot.y (spot-bump (typed.spot))) (spot-x-untyped (typed.spot))
   (spot-sum-untyped (typed.spot)) (spot-via (typed.spot))])
(typed.check "fixnum and float fields read into registers" [true true 14 25]
  [(typed.has? fix+ spot-sum) (typed.has? float* dot-norm2)
   (spot-sum (spot.make 6 8)) (shen-jit.truncate (dot-norm2 (dot.make 3.0 4.0)))])
(typed.check "an error formats values that were in registers" [true 4 "5 is not below 4"]
  [(typed.has? fix+ spot-next) (spot-next (spot.make 3 4))
   (trap-error (spot-next (spot.make 5 4)) (/. E (error-to-string E)))])
(typed.check "untyped code still raises" "<-address: 5 is not an absvector"
  (trap-error (spot-x-untyped 5) (/. E (error-to-string E))))

\\ Optimization claims belong to the installed procedure, not a name later reused and sealed.
(defstruct typed-replaced (x : fixnum) (y : fixnum))
(shen-jit.seal +)
(define typed-replaced.x P -> 42)
(eval-kl [defun typed-replaced.y [P] 43])
(load "tests/typed/redefine-before.shen")
(optimise +)
(typed.check "a typed replacement refused" failed (typed.load-typed "tests/typed/redefine-failed.shen"))
(typed.check "the old body stays untyped" false (tl (get typed-failed shen-jit.annotated)))
\\ The kernel unwinds the failed file's type declarations; restore the old function's signature.
(declare typed-failed [spot --> fixnum])
(typed.check "replacement callers load" loaded (typed.load-typed "tests/typed/redefined.shen"))
(optimise -)
(shen-jit.seal -)
(typed.check "replaced readers are ordinary functions" [[0 0] 85]
  [(typed.reads typed-replaced-read)
   (shen-jit.apply (shen-jit.function typed-replaced-read) [(typed-replaced.make 7 8)])])
(typed.check "a failed replacement cannot trust the old body" [[0 1] 3]
  [(typed.reads typed-failed-read) (shen-jit.apply (shen-jit.function typed-failed-read) [(typed.spot)])])

(typed.check "a loop of fixnums" [true true 385] [(typed.has? again word-sum) (typed.has? fix* word-sum) (word-sum 10 0)])
(typed.check "a frozen chain's value in a loop" [true false 96]
  [(typed.has? again word-chain) (typed.has? closure word-chain) (word-chain 10 0)])

\\ A definition made while sealing is on over one made unsealed, as a grammar's rule replaces its
\\ stub, is sealed as it is installed: its own tail calls loop, and a caller inlines it as a loop.
(define typed-replaced-loop N Acc -> Acc)
(shen-jit.seal +)
(optimise +)
(typed.check "an unsealed definition replaced" loaded (typed.load-typed "tests/typed/replaced-loop.shen"))
(optimise -)
(shen-jit.seal -)
(typed.check "replaced, a loop, inlined as one" [true true 56]
  [(typed.has? loop typed-replaced-loop) (typed.has? loop typed-replaced-caller) (typed-replaced-caller 10)])
(typed.check "bit operations" [true 5] [(typed.has? word-xor word-bits) (word-bits 6 3)])
(typed.check "fixnum comparisons" [true 5 5] [(typed.has? word-unless>= word-max) (word-max 5 3) (word-max 3 5)])
(typed.check "overflow raises" "integer overflow" (trap-error (word-double 1) (/. E (error-to-string E))))
(typed.check "a float for a fixnum" "2.5 is not an integer" (trap-error (word-sum 2.5 0) (/. E (error-to-string E))))
(typed.check "quotients and remainders" [301 -301 -299] [(word-div 7 2) (word-div -7 2) (word-div 7 -2)])
(typed.check "by zero" "division by zero" (trap-error (word-div 1 0) (/. E (error-to-string E))))
(define typed.step
  F X -> (trap-error (shen-jit.apply (shen-jit.function F) [X]) (/. E (error-to-string E))))
(define typed.step2
  F X Y -> (trap-error (shen-jit.apply (shen-jit.function F) [X Y]) (/. E (error-to-string E))))
(set typed.greatest 2305843009213693951)
(set typed.least (- (- 0 2305843009213693951) 1))
(typed.check "a constant step in registers" [true true true true]
  [(typed.has? fix+ word-up8) (typed.has? fix- word-down8) (typed.has? fix+ word-plus-minus8)
   (typed.has? fix- word-minus-minus8)])
(typed.check "a constant step up to the greatest fixnum, and past it"
  [(value typed.greatest) "integer overflow" (value typed.greatest) "integer overflow"]
  [(typed.step word-up8 (- (value typed.greatest) 8)) (typed.step word-up8 (- (value typed.greatest) 7))
   (typed.step word-minus-minus8 (- (value typed.greatest) 8)) (typed.step word-minus-minus8 (- (value typed.greatest) 7))])
(typed.check "a constant step down to the least fixnum, and past it"
  [(value typed.least) "integer overflow" (value typed.least) "integer overflow"]
  [(typed.step word-down8 (+ (value typed.least) 8)) (typed.step word-down8 (+ (value typed.least) 7))
   (typed.step word-plus-minus8 (+ (value typed.least) 8)) (typed.step word-plus-minus8 (+ (value typed.least) 7))])
(typed.check "loop steps in registers with no check, a counter's checked where its loop ends" [true 1 true]
  [(typed.has? word+ word-count-up) (typed.count fix+ word-count-up) (typed.has? word+ word-stride)])
(typed.check "a counter stepped past the greatest fixnum raises at the loop's next test"
  ["integer overflow" "integer overflow" 40 done true "integer overflow" 8]
  [(typed.step2 word-count-up 2305843009213693948 2305843009213693951)
   (typed.step2 word-count-to 2305843009213693948 2305843009213693951) (typed.step2 word-count-to 0 40)
   (typed.step2 word-count-up 2305843009213693935 2305843009213693944)
   (typed.has? loop word-count-outer) (typed.step2 word-count-outer 2305843009213693948 2305843009213693951)
   (typed.step2 word-count-outer 0 100)])
(typed.check "a large step that goes elsewhere is checked"
  [true "integer overflow" true "integer overflow" "integer overflow" "integer overflow" 0 0]
  [(typed.has? fix+ word-past-difference) (typed.step2 word-past-difference 1 2) (typed.has? fix+ word-past-float)
   (typed.step2 word-past-float 1 2)
   (trap-error (shen-jit.apply (shen-jit.function word-past-other) [1 0 2]) (/. E (error-to-string E)))
   (typed.step2 word-past-nested 1 3)
   (shen-jit.apply (shen-jit.function word-past-other) [-1 0 1]) (typed.step2 word-past-nested -3 0)])
(typed.check "a step below a bound the loop steps too is checked" [true "integer overflow"]
  [(typed.has? fix+ word-leapfrog) (typed.step2 word-leapfrog 0 1)])
(typed.check "an index stepped past the greatest fixnum raises at its read"
  "bytes: 2305843009213693952 is not a valid index"
  (trap-error (shen-jit.apply (shen-jit.function word-stride) [(shen-jit.bytes 4) 1 2305843009213693951 0])
              (/. E (error-to-string E))))
(typed.check "the one quotient that overflows" "integer overflow"
  (trap-error (word-div (- (- 0 2305843009213693951) 1) -1) (/. E (error-to-string E))))
(typed.check "untyped, the same" [3 -1 "division by zero"]
  [(fxquotient 7 2) (fxremainder -7 2) (trap-error (fxquotient 1 0) (/. E (error-to-string E)))])
(define typed.bytes
  -> (let B (shen-jit.bytes 4) _ (shen-jit.u8! B 0 1) _ (shen-jit.u8! B 1 2) _ (shen-jit.u8! B 2 250)
          _ (shen-jit.u8! B 3 4)
       (word-bytes B 0 4 0)))
(typed.check "bytes read in registers" [true 257] [(typed.has? word-load8 word-bytes) (typed.bytes)])
(typed.check "a byte index past the fixnums raises as one past the end"
  "bytes: 4611686018427387902 is not a valid index"
  (trap-error (shen-jit.apply (shen-jit.function word-byte-at)
                              [(shen-jit.bytes 4) 2305843009213693951 2305843009213693951])
              (/. E (error-to-string E))))
(typed.check "a NaN in a register never equals itself, where untyped code's same object does"
  [false true true]
  [(shen-jit.apply (shen-jit.function float-same) [(shen-jit.sqrt -1)])
   (shen-jit.apply (shen-jit.function float-same) [1.5])
   (let N (shen-jit.sqrt -1) (= N N))])
(typed.check "vectors at fixnum indices" 14 (word-vector (vector 3) 1 0))
(typed.check "vector types" [[[vector symbol] --> [fixnum --> symbol]] [[vector symbol] --> fixnum]]
  [(typed.as [fn fx<-vector] [[vector symbol] --> [fixnum --> symbol]])
   (typed.as [fn fxlimit] [[vector symbol] --> fixnum])])
(define typed.pair-untyped X -> (float-pair X 1.5))
(typed.check "a larger body inlined into a typed loop" [false true false]
  [(typed.has? call-sealed float-pairs) (typed.has? float-divide float-pairs) (typed.has? float-divide typed.pair-untyped)])
(typed.check "with what it gives called" (+ (float-pair 1.0 0.5) (+ (float-pair 2.0 0.5) 1.5)) (float-pairs 2 1.5))

\\ Loops inlined into typed loops (src/lowerer/registers.shen, inline-loop and inlined-loop).
(shen-jit.seal +)
(optimise +)
(typed.check "loops load" [loops] (module.load "tests/typed/loops.shenmod"))
(optimise -)
(shen-jit.seal -)


(define typed.doubles
  Xs -> (let B (shen-jit.bytes (* 8 (length Xs)))
             _ (typed.store B 0 Xs)
          B))

(define typed.store
  _ _ [] -> done
  B I [X | Xs] -> (do (shen-jit.f64! B I X) (typed.store B (+ I 8) Xs)))

(typed.check "loops in loops" [3 false 30.0 93.0]
  [(typed.count loop loop-sheets) (typed.has? call-sealed loop-sheets)
   (loop-rows (typed.doubles [1.0 2.0 3.0 4.0]) 0 2 16 (float 0))
   (loop-sheets (typed.doubles [1.0 2.0 3.0 4.0]) 0 16 (float 0))])
(typed.check "a parameter read before the loop changes it" [10 55 2]
  [(loop-triangle 4 0) (loop-triangle 10 0) (typed.count loop loop-triangle)])
(define typed.filled
  -> (let B (typed.doubles [9.5 9.5 9.5 9.5])
          _ (loop-fills B 0 2 16)
       [(shen-jit.f64 B 0) (shen-jit.f64 B 8) (shen-jit.f64 B 16) (shen-jit.f64 B 24)]))
(typed.check "an inner loop for its effect" [0.0 0.0 1.0 1.0] (typed.filled))
(typed.check "an inner loop in tail position" [7 0 true] [(loop-tail 3 10) (loop-tail 3 -1) (typed.has? loop loop-tail)])
(define typed.found
  -> (let B (shen-jit.bytes 4) _ (shen-jit.u8! B 0 1) _ (shen-jit.u8! B 1 3) _ (shen-jit.u8! B 2 5)
          _ (shen-jit.u8! B 3 3)
       (loop-found B 0 0)))
(typed.check "an inner loop tested" [3 2] [(typed.found) (typed.count loop loop-found)])
(typed.check "an inner loop over a list" [4.0 2] [(loop-means [1 2 3] 2 (float 0)) (typed.count loop loop-means)])
(typed.check "a caller that calls keeps the loop a call" [5 true false]
  [(loop-calls 5) (typed.has? call-sealed loop-calls) (typed.has? loop loop-calls)])
(typed.check "one more than a fixnum below another" [true true false true]
  [(typed.has? word+ loop-count) (typed.has? fix+ loop-count) (typed.has? word+ loop-up) (typed.has? fix+ loop-up)])
(typed.check "up to the largest fixnum" 2 (loop-count 2305843009213693949 2305843009213693951 0))
(typed.check "shifts in registers, as the primitives" [true true]
  [(typed.has? word-shl loop-shifts)
   (= (loop-shifts 5 -9) [(shen-jit.shift-left 5 3) (shen-jit.shift-right -9 2) (shen-jit.shift-left 5 61)
                          (shen-jit.shift-right -9 63) (shen-jit.bit-xor (shen-jit.shift-left 5 20) (shen-jit.shift-right -9 1))])])
(define typed.bits
  X K -> [(shen-jit.shift-left X K) (shen-jit.shift-right X K) (shen-jit.clz X) (shen-jit.ctz X) (shen-jit.popcount X)])
(typed.check "counted shifts and bit counts in registers, as the primitives" [true true true true true true true]
  [(typed.has? fix-shl loop-bits) (typed.has? fix-sar loop-bits) (typed.has? fix-popcount loop-bits)
   (= (loop-bits 5 61) (typed.bits 5 61)) (= (loop-bits -9 2) (typed.bits -9 2))
   (= (loop-bits 0 63) (typed.bits 0 63)) (= (loop-bits (shen-jit.shift-left -1 61) 1) (typed.bits (shen-jit.shift-left -1 61) 1))])
(typed.check "a shift's count tested in registers" ["bit operation: 64 is not a valid shift"
                                                    "bit operation: -1 is not a valid shift"]
  [(trap-error (loop-bits 1 64) (/. E (error-to-string E))) (trap-error (loop-bits 1 -1) (/. E (error-to-string E)))])
(typed.check "lets that give their registers back" [true 840] [(typed.has? again loop-mixes) (loop-mixes 3 0)])
(typed.check "repeated products" 3.0 (loop-row (typed.doubles [1.0 2.0 4.0 0.5 1.0 1.5]) 1))
(typed.check "a product in a branch and after it" [30 15] [(loop-branchy 5 true) (loop-branchy 5 false)])
(define typed.raised
  -> (let B (shen-jit.bytes 1)
          E (trap-error (loop-raise B 576460752303423488) (/. E (error-to-string E)))
       [E (shen-jit.u8 B 0)]))
(typed.check "an overflow raises after the effect before it" ["integer overflow" 7] (typed.raised))
(typed.check "and past it, which raises" [5 "integer overflow"]
  [(loop-up 2 5) (trap-error (loop-up 2305843009213693950 0) (/. E (error-to-string E)))])
(typed.check "steps read by the sum after them, in place" [0 14.0]
  [(typed.count word-move loop-strided)
   (loop-strided (typed.doubles [1.0 2.0 3.0]) 0 (typed.doubles [1.0 0.0 2.0 0.0 3.0 0.0]) 0 24 16 (float 0))])
(typed.check "an inlined loop's call of the definition around it is a call" [34102 1102 1103]
  [(loop-outer 0) (loop-outer 99) (loop-inner 99 100)])
(typed.check "a bound through inlining's lets, past the greatest fixnum, checked" "integer overflow"
  (trap-error (loop-aliased 2305843009213693950 10 9 4 2305843009213693951) (/. E (error-to-string E))))
(typed.check "an exit tested on floats, which a NaN does not take" [3 0]
  [(loop-nan 0.5 3) (loop-nan (shen-jit.sqrt -1) 3)])
(typed.check "arguments that read each other" [-9 9 55.0] [(loop-swap 3 10 1) (loop-swap 4 10 1) (loop-fib 10 (float 0) 1.0)])
(define typed.marked
  -> (let B (shen-jit.bytes 3)
          N (loop-marks B 0 3)
       [N (shen-jit.u8 B 0) (shen-jit.u8 B 1) (shen-jit.u8 B 2)]))
(typed.check "an effect before a step sees the counter as it was" [3 10 11 12] (typed.marked))
(define typed.error
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))
\\ F's own code on Args, rather than F inlined into this untyped caller.
(define typed.call
  F Args -> (shen-jit.apply (shen-jit.function F) Args))
(typed.check "floats truncated towards zero in a register, as shen-jit.truncate does"
  [[2 -2 0 255 127 -2305843009213693952] [2 -2 0 7 -2305843009213693952] true]
  [(append (map (/. X (typed.call float-truncated [X])) [2.7 -2.7 0.5])
           [(typed.call float-byte [1.0]) (typed.call float-byte [0.5])
            (typed.call float-truncated [(shen-jit.float -2305843009213693952)])])
   (map (/. X (shen-jit.truncate X)) [2.7 -2.7 0.5 7 (shen-jit.float -2305843009213693952)])
   (typed.has? fix-from-float float-truncated)])
(typed.check "an error's message made by calls leaves a loop in registers, and a helper raising so"
  [(shen-jit.float 45) "negative index -3" true true 19.30600052603572 "no root of -1.0" true true]
  [(typed.call float-checked [0 10 0.0]) (typed.error (freeze (typed.call float-checked [-3 10 0.0])))
   (typed.has? again float-checked) (typed.has? float+ float-checked)
   (typed.call float-roots [0 10 0.0]) (typed.error (freeze (typed.call float-root [-1.0])))
   (typed.has? float-sqrt float-roots) (typed.has? again float-roots)])
(typed.check "a float outside the fixnums raises, a NaN and an infinity among them"
  [overflow overflow overflow overflow "a is not a number"]
  (let Raise (/. F (if (= (typed.error F) "integer overflow") overflow (typed.error F)))
    [(Raise (freeze (typed.call float-truncated [1e300])))
     (Raise (freeze (typed.call float-truncated [2305843009213693952])))
     (Raise (freeze (typed.call float-truncated [(shen-jit.sqrt -1)])))
     (Raise (freeze (shen-jit.truncate -1e300)))
     (typed.error (freeze (shen-jit.truncate a)))]))
(typed.check "doubles at an index of doubles" [true true true 6.0 3.0 5.0]
  (let B (typed.doubles [1.0 2.0 3.0])
    [(typed.has? float-load-index loop-scaled-sum) (typed.has? float-load-index scaled-get)
     (typed.has? float-store-index scaled-set) (loop-scaled-sum B 0 3 (float 0)) (scaled-get B 2)
     (scaled-get (scaled-set B 1 5.0) 1)]))
(typed.check "past either end, as an index of bytes says it"
  (let B (typed.doubles [1.0 2.0 3.0])
    (map (/. F (typed.error F)) [(freeze (shen-jit.f64 B (* 3 8))) (freeze (shen-jit.f64 B (* -1 8)))
                                 (freeze (shen-jit.f64 B (* 3 8))) (freeze (shen-jit.f64! B (* 3 8) 1.0))]))
  (let B (typed.doubles [1.0 2.0 3.0])
    (map (/. F (typed.error F))
         [(freeze (typed.call scaled-get [B 3])) (freeze (typed.call scaled-get [B -1]))
          (freeze (typed.call loop-scaled-sum [B 0 4 (float 0)])) (freeze (typed.call scaled-set [B 3 1.0]))])))
(typed.check "an index of doubles past 64 bits as bytes"
  "bytes: element 1152921504606846976 is not a valid index"
  (typed.error (freeze (typed.call scaled-get [(typed.doubles [1.0]) 1152921504606846976]))))
(shen-jit.seal +)
(optimise +)
(typed.check "vectors load" [floats vectors] (module.load "tests/typed/vectors.shenmod"))
(optimise -)
(shen-jit.seal -)
(typed.check "floats in registers, at indices of doubles" [true true 14.0 [2.0 4.0 6.0]]
  (let A (floats.of-list [1.0 2.0 3.0])
    [(typed.has? float-load-index vectors.dot) (typed.has? float-store-index vectors.scale)
     (vectors.dot A A 0 3 (float 0)) (floats.to-list (vectors.scale A (float 2) 0))]))
(typed.check "floats' types" [[floats.t --> [fixnum --> float]] [fixnum --> floats.t]]
  [(typed.as [fn floats.get] [floats.t --> [fixnum --> float]]) (typed.as [fn floats.new] [fixnum --> floats.t])])
(define typed.stored
  B -> [(shen-jit.u8 B 0) (shen-jit.u16 B 2) (shen-jit.u32 B 4) (shen-jit.s32 B 8) (shen-jit.s64 B 16)])
(typed.check "fixnums stored from registers" [[200 200 70000 70000 70000] [7 9] true true true true false]
  [(typed.stored (store-each (shen-jit.bytes 24) 200 70000))
   (let B (store-nested (shen-jit.bytes 8) 7 9) [(shen-jit.u32 B 0) (shen-jit.u32 B 4)])
   (typed.has? fix-store8 store-each) (typed.has? fix-store-s32 store-each) (typed.has? word-store64 store-each)
   (typed.has? fix-store32 store-nested) (typed.has? prim store-nested)])
(typed.check "stores that do not fit, or past the end, as the primitives say"
  (let B (shen-jit.bytes 24)
    (map (/. F (typed.error F)) [(freeze (shen-jit.u8! B 0 256)) (freeze (shen-jit.u32! B 4 -5))
                                 (freeze (shen-jit.s32! B 8 2147483648)) (freeze (shen-jit.s32! (shen-jit.bytes 8) 8 1))]))
  (let B (shen-jit.bytes 24)
    (map (/. F (typed.error F))
         [(freeze (typed.call store-each [B 256 1])) (freeze (typed.call store-each [B 1 -5]))
          (freeze (typed.call store-each [B 1 2147483648])) (freeze (typed.call store-each [(shen-jit.bytes 8) 1 1]))])))
(typed.check "a negative 32-bit value and the greatest fixnum in 64 bits" [-5 2305843009213693951]
  (let B (typed.call store-wide [(shen-jit.bytes 24) -5 2305843009213693951])
    [(shen-jit.s32 B 8) (shen-jit.s64 B 16)]))
(shen-jit.seal +)
(optimise +)
(typed.check "word operations load" [word words word-ops] (module.load "tests/typed/word-ops.shenmod"))
(optimise -)
(shen-jit.seal -)
(define typed.instructions
  F -> (hd (tl (tl (tl (tl (tl (hd (tl (tl (shen-jit.code F)))))))))))
(define typed.seed
  -> (word.+ (word.shl (word.of 1234567) 32) (word.of 89101112)))
(typed.check "words in registers, as C computes them"
  [1114011315718371988 0.44672172732768156 0 true true]
  (let S (word-ops.steps (typed.seed) 10)
    [(word.to-fixnum (word.shr S 3)) (word-ops.fraction S) (typed.count-prim shen-jit.word-op (typed.instructions word-ops.steps))
     (typed.has? word-shr word-ops.steps) (typed.has? word* word-ops.fraction)]))
(typed.check "FNV-1a over bytes, a word stored, and an unsigned comparison"
  [true true true true true true]
  (let H (word-ops.fnv (shen-jit.string->bytes "hello") 0 5 (word-ops.basis))
       Want (word.+ (word.shl (word.of 2754664518) 32) (word.of 2158673163))
       S (typed.seed)
       B (word-ops.stored (shen-jit.bytes 16) S)
    [(= H Want) (= (word.get B 8) (word.rotl S 7)) (typed.has? word-store64 word-ops.stored)
     (= (word-ops.larger (word.of -1) (word.of 1)) (word.of -1)) (typed.has? word-unless-u< word-ops.larger)
     (= 0 (typed.count-prim shen-jit.word-op (typed.instructions word-ops.fnv)))]))
(typed.check "a typed helper of a helper, three levels into a loop, inlined"
  [80909964 2164574606262478231 false false true]
  (let S (word.set (shen-jit.bytes 8) 0 (typed.seed))
       N (word-ops.total S 8000000 20 0)
    [N (word.to-fixnum (word.get S 0)) (typed.has? call word-ops.total) (typed.has? call-sealed word-ops.total)
     (typed.has? word-store64 word-ops.total)]))
(typed.check "arrays of words, by element in registers, as untyped code reads them"
  [true true true true false true 0 0 ["bytes: 24 is not a valid index" "bytes: 24 is not a valid index"]]
  (let V (words.of-list [(word.of 1) (word.of 2) (typed.seed)])
       Stepped (word-ops.step-all (words.of-list [(word.of 1) (word.of 2) (typed.seed)]) 0)
    [(= (word-ops.xor-all V 0 (word.of 0)) (word.bit-xor (word.of 3) (typed.seed)))
     (= (words.to-list Stepped) (map (/. W (word-ops.next W)) (words.to-list V)))
     (typed.has? word-load-index word-ops.xor-all) (typed.has? word-store-index word-ops.step-all)
     (typed.has? fix* word-ops.xor-all) (typed.has? word-load-index word-ops.at)
     (typed.count-prim shen-jit.word-op (typed.instructions word-ops.xor-all))
     (typed.count-prim shen-jit.copy-bytes (typed.instructions word-ops.step-all))
     [(typed.error (freeze (typed.call word-ops.at [V 3]))) (typed.error (freeze (words.get V 3)))]]))
(typed.check "untyped words, the same"
  [8912090525746975904.0 true]
  [(word.to-float (word-ops.steps (typed.seed) 10))
   (= (word-ops.next (typed.seed)) (word.bit-xor (word.bit-xor (word.bit-xor (typed.seed) (word.shr (typed.seed) 12)) (word.shl (word.bit-xor (typed.seed) (word.shr (typed.seed) 12)) 25)) (word.shr (word.bit-xor (word.bit-xor (typed.seed) (word.shr (typed.seed) 12)) (word.shl (word.bit-xor (typed.seed) (word.shr (typed.seed) 12)) 25)) 27)))])
(typed.check "a constant flag of an inlined loop, tested once" [10 2 false]
  [(loop-flags 5) (typed.count loop loop-flags) (typed.has? jump-if-false loop-flags)])
(typed.check "a flag the loop changes" [4 3] [(loop-toggles 5) (loop-toggled 4 false 1)])

\\ C functions of doubles called in registers (lib/ffi.shen marks them), where a build loads C.
(define typed.foreign
  -> (do (shen-jit.seal +)
         (optimise +)
         (module.load "tests/typed/foreign.shenmod")
         (optimise -)
         (shen-jit.seal -)
         (typed.check "a C call in registers" [true false 1 2 -1]
           [(typed.has? float-call1 foreign-sum) (typed.has? call-sealed foreign-sum)
            (tl (get foreign-cos shen-jit.foreign-floats)) (tl (get foreign-pow shen-jit.foreign-floats))
            (tl (get foreign-labs shen-jit.foreign-floats))])
         (typed.check "as the stub gives" [(+ (foreign-cos 3) (+ (foreign-cos 2) (+ (foreign-cos 1) 0.5)))
                                           (* (foreign-pow 1.5 2) 2.5)]
           [(foreign-sum 3 0.5) (foreign-power 1.5 2.0)])
         (typed.check "two arguments" true (typed.has? float-call2 foreign-power))
         (typed.check "no arguments, an ordinary call" [-1 (+ 1 (foreign-rounding))]
           [(tl (get foreign-rounding shen-jit.foreign-floats)) (foreign-rounding-plus 1)])
         (typed.check "memory, typed" 2.5 (foreign-memory 4))
         (typed.check "integer arguments of a C call stay exact" [(+ 9007199254740993 1) "integer overflow"]
           [(shen-jit.apply (shen-jit.function foreign-sum-of) [9007199254740993 1])
            (trap-error (shen-jit.apply (shen-jit.function foreign-product-of) [2147483648 2147483648])
                        (/. E (error-to-string E)))])
         (load "tests/typed/foreign-replaced-c.shen")
         (shen-jit.seal +)
         (optimise +)
         (typed.check "foreign replacement loads" loaded (typed.load-typed "tests/typed/foreign-replaced.shen"))
         (optimise -)
         (shen-jit.seal -)
         (typed.check "a foreign name replaced by Shen" [false 11.5]
           [(typed.has? float-call1 foreign-replaced-call)
            (shen-jit.apply (shen-jit.function foreign-replaced-call) [1.5])])))
(if (element? shen-jit/ffi (shen.x.features.current)) (typed.foreign) skip)

\\ Only what the typechecker annotated is trusted (src/lowerer/lower.shen, defun): untyped code that
\\ names type, or writes a type form, compiles as untyped code. Called through apply, as a caller
\\ inlining them would check again.
(define typed.via
  F Args -> (trap-error (shen-jit.apply (shen-jit.function F) Args) (/. E (error-to-string E))))
(shen-jit.seal +)
(defstruct typed-plain (x : number) (y : number))
(define typed.names-type P -> (if (= P type) 0 (typed-plain.x P)))
(define typed.names-kind P -> (if (= P kind) 0 (typed-plain.x P)))
(shen-jit.seal -)
(define typed.writes-type X Y -> (+ (type X float) Y))
(typed.check "untyped code naming type keeps its field checks"
  [(typed.via typed.names-kind [7]) (typed.via typed.names-kind [[1 2 3]])]
  [(typed.via typed.names-type [7]) (typed.via typed.names-type [[1 2 3]])])
(typed.check "a type form in untyped code converts nothing" [3 false]
  [(typed.via typed.writes-type [1 2]) (typed.has? float-number typed.writes-type)])

\\ A type declared represented by fixnums keeps its values in registers, and stays a type of its own.
(shen-jit.seal +)
(optimise +)
(typed.check "a represented type loads" [represented] (module.load "tests/typed/represented.shenmod"))
(optimise -)
(shen-jit.seal -)
(typed.check "its values in registers, wrapping" [true 705032408 2000000000]
  [(typed.has? word-number rep.walk) (rep.walk 5000000 (rep.seq-of 4294967000)) (rep.walk 2000000 (rep.seq-of 0))])
(typed.check "a type of its own to the typechecker" [fixnum false]
  [(shen.typecheck [rep.seq-number [rep.seq-of 1]] (protect A))
   (shen.typecheck [fx< [rep.seq-of 1] [rep.seq-of 2]] (protect A))])

(output "~A passed, ~A failed (typed)~%" (value typed.passed) (value typed.failed))

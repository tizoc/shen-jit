\* Differential tests of the primitives, with values nobody chose by hand.

   Every primitive runs over every value, written each way the JIT compiles it differently: operands in
   variables, constants or captures, the call a function value, in a loop, under a handler, as a branch's
   test. All the ways must agree with the first, by value or by error message. Then properties that
   must hold whatever the values: = is an equivalence that hash respects, the comparisons agree, and so on.

   With an argument FILE it also writes each result to FILE. tests/differential.sh runs this twice, the second
   time with SHEN_JIT_SLOW_PRIMS=1, which sends every primitive to C, and compares the files. With --portable it
   runs on Shen/Scheme too, for tests/differential_scheme.py. *\

(set d.*portable* (or (= (language) "Scheme") (and (cons? (tl (value *argv*))) (= (hd (tl (value *argv*))) "--portable"))))

\\ The runtime's own primitives that are not yet values.
(map (/. P (if (= (language) "Scheme") skip (eval-kl [shen-jit.primitive (hd P) (hd (tl P))])))
     [[shen-jit.fixnum? 1] [shen-jit.integer? 1] [shen-jit.symbol? 1] [shen-jit.vector? 1] [shen-jit.pvar 1] [shen-jit.pvar? 1] [shen-jit.pvar-offset 1]
      [shen-jit.hash 2] [shen-jit.filled-vector 2] [shen-jit.tagged? 2] [shen-jit.same? 2] [shen-jit.newpv 2] [shen-jit.gc 2] [shen-jit.append 2]
      [shen-jit.decimal 2] [shen-jit.deref 3]
      [shen-jit.pointer-kill 1] [shen-jit.pointer-owner 1] [shen-jit.pointer-kind 1] [shen-jit.pointer-address 1]
      [shen-jit.pointer-sized 2] [shen-jit.pointer-read-only 1] [shen-jit.pointer! 3] [shen-jit.bytes->pointer 3]])

\\ Memory outside the heap, from lib/memory.shen beside this file, except where a static build cannot
\\ load libraries or the implementation has none.
(define d.dir
  S -> (d.dir-h S "" ""))

(define d.dir-h
  "" Dir _ -> Dir
  S Dir Part -> (d.dir-h (tlstr S) (cn Dir (cn Part "/")) "") where (= (pos S 0) "/")
  S Dir Part -> (d.dir-h (tlstr S) Dir (cn Part (pos S 0))))

(set *hush* true)
(if (= (language) "Scheme")
    skip
    (let Dir (d.dir (hd (value *argv*)))
      (do (load (cn Dir "../lib/ffi.shen"))
          (load (cn Dir "../lib/memory.shen")))))
(set *hush* false)

(set d.*failures* 0)
(set d.*checks* 0)
(set d.*log* [])

\\ At most this many failures are shown for each primitive and way.
(define d.fail
  Text -> (do (set d.*failures* (+ 1 (value d.*failures*)))
              (if (< (value d.*failures*) 200)
                  (output "FAIL ~A~%" Text)
                  skip)))

(define d.check
  -> (set d.*checks* (+ 1 (value d.*checks*))))

\\ ---------------------------------------------------------------------------
\\ Showing a result exactly: 1 and 1.0 differ, as do 0.0 and -0.0, and every NaN
\\ shows its bits. = is under test, so comparisons are of these strings.

(define d.real-bits
  R -> (let B (shen-jit.f64! (shen-jit.bytes 8) 0 R)
         (cn "r" (cn (str (shen-jit.u32 B 4)) (cn ":" (str (shen-jit.u32 B 0)))))))

\\ A fixnum is its own sum with 0, while a real is a new object.
(define d.fixnum?
  V -> (and (number? V) (shen-jit.same? V (+ V 0))))

(define d.show
  V -> (d.show-to V 6))

(define d.show-to
  V 0 -> "..."
  V _ -> (str V) where (and (number? V) (value d.*portable*))
  V _ -> (cn "i" (str V)) where (d.fixnum? V)
  V _ -> (d.real-bits V) where (number? V)
  V _ -> (cn "s" (make-string "~S" V)) where (string? V)
  V D -> (cn "(" (cn (d.show-to (hd V) (- D 1)) (cn " . " (cn (d.show-to (tl V) (- D 1)) ")")))) where (cons? V)
  V D -> (cn "#" (d.show-bytes V 0)) where (and (not (value d.*portable*)) (shen-jit.bytes? V))
  V D -> (d.show-pointer V) where (and (not (value d.*portable*)) (shen-jit.pointer? V))
  V D -> (cn "[" (d.show-vector V 0 D)) where (absvector? V)
  V _ -> (str V))

\\ Its kind and what it holds, not its address, which changes from run to run.
(define d.show-pointer
  P -> (trap-error (cn "@" (cn (str (shen-jit.pointer-kind P)) (cn " " (d.show-bytes P 0))))
                   (/. E (cn "@dead " (str (shen-jit.pointer-kind P))))))

(define d.show-bytes
  B I -> "" where (>= I (shen-jit.bytes-length B))
  B I -> "..." where (> I 16)
  B I -> (cn (str (shen-jit.u8 B I)) (cn " " (d.show-bytes B (+ I 1)))))

(define d.show-vector
  V 8 _ -> "...]"
  V I D -> (let E (trap-error [(<-address V I)] (/. Ignored []))
             (if (= E [])
                 "]"
                 (cn (d.show-to (hd E) (- D 1)) (cn " " (d.show-vector V (+ I 1) D))))))

\\ A call's outcome as a string.
(define d.outcome
  F Args -> (trap-error (cn "= " (d.show (d.apply F Args)))
                        (/. E (cn "! " (error-to-string E)))))

(define d.apply
  F [] -> (thaw F)
  F [A] -> (F A)
  F [A B] -> (F A B)
  F [A B C] -> (F A B C)
  F [A B C D] -> (F A B C D)
  F [A B C D E] -> (F A B C D E))

\\ ---------------------------------------------------------------------------
\\ Values: each is [Name Form], and Form is evaluated afresh for each call, so what a
\\ primitive stores into one does not reach the next. A literal's Form can also be a constant.

(define d.pow
  _ 0 -> 1
  B N -> (* B (d.pow B (- N 1))))

\\ 2^K as a real, however large.
(define d.real-pow
  0 -> (+ 0.5 0.5)
  K -> (* 2 (d.real-pow (- K 1))))

(define d.integers
  -> (let P53 (d.pow 2 53)
          Max (+ (d.pow 2 60) (- (d.pow 2 60) 1))
          Min (- (- 0 Max) 1)
       [0 1 -1 2 -2 3 7 8 15 16 63 64 -64 255 256 1023 65535 65536
        2147483647 2147483648 -2147483648 -2147483649 4294967295 4294967296 -4294967296
        (- P53 1) P53 (+ P53 1) (+ P53 2) (- 0 P53) (- -1 P53)
        (d.pow 2 60) (- 0 (d.pow 2 60)) Max (- Max 1) Min (+ Min 1)]))

\\ Reals past the reader's reach are computed; the readers turn 8.0 into the integer 8.
(define d.real-forms
  -> (let One [+ 0.5 0.5]
          Big [* One 1.0e200]
       [[half 0.5] [-half -0.5] [one-half 1.5] [tenth 0.1]
        [r0 [- 0.5 0.5]] [r-0 [* -1 [- 0.5 0.5]]] [r1 One] [r-1 [- -0.5 0.5]] [r2 [+ 0.5 1.5]] [r8 [* 8 One]]
        [r53 [* 18014398509481984 0.5]] [r-53 [* -18014398509481984 0.5]] [r54 [* 18014398509481984 One]]
        [r61 [* 2305843009213693951 One]] [r-61 [* -2305843009213693952 One]]
        [r62 [* 2 [* 2305843009213693951 One]]]
        [big [* One 1.0e300]] [small [* One 1.0e-300]] [tiny [* 0.5 [* One 1.0e-323]]]
        [inf [* Big Big]] [-inf [* -1 [* Big Big]]]
        [nan [- [* Big Big] [* Big Big]]]]))

\\ Two blocks, each filled again whenever a value needs it, so that a call sees what the one before it
\\ saw. A value's length is at most a block's.
(set d.*blocks* (trap-error [(memory.alloc 32) (memory.alloc 32)] (/. E [])))

(define d.fill-block
  M Base -> (do (d.for-each (/. K (shen-jit.u8! M K (+ Base K))) (d.range 0 32)) M))

(define d.block
  I Base N -> (shen-jit.pointer-sized (d.fill-block (if (= I 0) (hd (value d.*blocks*)) (hd (tl (value d.*blocks*)))) Base) N))

(define d.pointer-values
  -> [[p8 [d.block 0 1 8]] [p8b [d.block 1 101 8]] [p0 [d.block 0 1 0]] [p32 [d.block 0 1 32]]
      [ro8 [shen-jit.pointer-read-only [d.block 0 1 8]]] [dead [shen-jit.pointer-kill [d.block 0 1 8]]]])

(define d.pointer-names
  -> (map (/. V (hd V)) (d.pointer-values)))

(define d.values
  -> (append
       (if (or (= (value d.*blocks*) []) (value d.*portable*)) [] (d.pointer-values))
       (map (/. N [(intern (make-string "n~A" N)) N]) (d.integers))
       (d.real-forms)
       [[empty ""] [a "a"] [abc "abc"] [abc2 [cn "ab" "c"]] [acute "é"] [kanji "日本語"]
        [nul [n->string 0]] [nul-a [cn [n->string 0] "a"]] [s7 "abcdefg"] [s8 "abcdefgh"] [s9 "abcdefghi"] [s16 "abcdefghijklmnop"]
        [s17 "abcdefghijklmnopq"] [s17b [cn "abcdefghijklmnop" "q"]] [digit "7"]
        [nil []] [true true] [false false] [sym foo] [sym2 [intern "foo"]] [fail [fail]]
        [one-list [cons 1 []]] [one-list2 [cons 1 []]] [real-list [cons [+ 0.5 0.5] []]] [pair [cons 1 2]] [nested [cons [cons 1 []] []]]
        [str-list [cons "abc" [cons foo []]]] [vec-list [cons [absvector 1] []]]
        [v0 [absvector 0]] [v1 [absvector 1]] [v3 [absvector 3]] [v3b [absvector 3]] [nv0 [vector 0]] [nv2 [vector 2]]
        [nv2b [address-> [address-> [vector 2] 1 a] 2 b]] [tuple [@p 1 2]]
        [closure [lambda x x]] [frozen [freeze 1]] [fn [function +]] [err [trap-error [simple-error "e"] [lambda e e]]]
        [stream [stoutput]]
        [pvar0 [shen-jit.pvar 0]] [pvar1 [shen-jit.pvar 1]]
        [b0 [shen-jit.bytes 0]] [b1 [shen-jit.bytes 1]] [b8 [shen-jit.bytes 8]] [b8b [shen-jit.bytes 8]]
        [bs [shen-jit.string->bytes "abc"]] [bs8 [shen-jit.string->bytes "abcdefgh"]]]))

\\ The values for primitives of three arguments or more, where all of them would be too many.
(define d.few
  -> [n0 n1 n-1 n2 n3 n7 n8 n255 n256 n-2147483648 n4294967296 half r1 inf nan empty abc s9 nil sym pair one-list
      v0 v3 nv2b b1 b8 bs bs8 fn pvar0 p8 p8b ro8 dead])

(define d.literal?
  V -> (or (number? V) (string? V) (symbol? V) (= V [])))

(define d.literal-values
  Values -> (d.filter (/. V (d.literal? (hd (tl V)))) Values))

(define d.filter-names
  Names Values -> (d.filter (/. V (element? (hd V) Names)) Values))

\\ A value is a procedure that makes it.
(define d.thunks
  Values -> (map (/. V [(hd V) (eval-kl [freeze (hd (tl V))]) (hd (tl V))]) Values))

(define d.name
  V -> (hd V))

(define d.make
  V -> (thaw (hd (tl V))))

\\ ---------------------------------------------------------------------------
\\ The ways to write a call. Each gives the definitions to evaluate, of which the last defines
\\ the function to call, with the parameters that remain.

(set d.*counter* 0)

(define d.gensym
  -> (let N (set d.*counter* (+ 1 (value d.*counter*)))
       (intern (make-string "d.f~A" N))))

(define d.params
  0 -> []
  1 -> [a]
  2 -> [a b]
  3 -> [a b c]
  4 -> [a b c d]
  5 -> [a b c d e])

(define d.boolean-prims
  -> [< > <= >= = number? cons? string? absvector? shen-jit.symbol? shen-jit.fixnum? shen-jit.integer? shen-jit.vector?
      shen-jit.bytes? shen-jit.pvar? shen-jit.pointer? shen-jit.same? shen-jit.tagged?])

(define d.boolean?
  P -> (element? P (d.boolean-prims)))

\\ Those to run in a loop, or anywhere else they run more than once: not what fills memory.
(define d.ways
  P N -> (append [captured value-of let-bound nested rethrown quiet inlined]
                 \\ It runs the call twice, and an overlapping copy does not give the same again, nor a
                 \\ new variable, which moves the offset on.
                 (if (element? P [shen-jit.copy-bytes shen-jit.newpv]) [] [loop])
                 (if (> N 0) [after-cons? after-number? after-string? after-vector? after-symbol?] [])
                 (if (d.boolean? P) [if-test if-not and-test loop-test] [])))

(define d.defs
  captured P Ps F -> (if (= Ps [])
                         [[defun F [] [[lambda x [P]] 0]]]
                         [[defun F Ps [[lambda x [P | (subst x (hd Ps) Ps)]] (hd Ps)]]])
  value-of P Ps F -> [[defun F Ps [let g [function P] [g | Ps]]]]
  let-bound P Ps F -> [[defun F Ps [let r [P | Ps] r]]]
  nested P Ps F -> [[defun F Ps [let r [P | Ps] [let s [cons r []] [hd s]]]]]
  rethrown P Ps F -> [[defun F Ps [trap-error [P | Ps] [lambda e [simple-error [error-to-string e]]]]]]
  quiet P Ps F -> [[defun F Ps [trap-error [P | Ps] [lambda e d.caught]]]]
  inlined P Ps F -> (let H (concat F .h)
                      [[defun H Ps [P | Ps]]
                       [defun F Ps [H | Ps]]])
  loop P Ps F -> (let L (concat F .l)
                   [[defun L (append Ps [n r]) [if [= n 0] r [L | (append Ps [[- n 1] [P | Ps]])]]]
                    [defun F Ps [L | (append Ps [2 0])]]])
  after-cons? P Ps F -> (d.after cons? P Ps F)
  after-number? P Ps F -> (d.after number? P Ps F)
  after-string? P Ps F -> (d.after string? P Ps F)
  after-vector? P Ps F -> (d.after absvector? P Ps F)
  after-symbol? P Ps F -> (d.after shen-jit.symbol? P Ps F)
  if-test P Ps F -> [[defun F Ps [if [P | Ps] true false]]]
  if-not P Ps F -> [[defun F Ps [if [not [P | Ps]] false true]]]
  and-test P Ps F -> [[defun F Ps [if [and [P | Ps] true] true false]]]
  loop-test P Ps F -> (let L (concat F .l)
                        [[defun L (append Ps [n]) [if [P | Ps] [if [= n 0] true [L | (append Ps [[- n 1]])]] false]]
                         [defun F Ps [L | (append Ps [1])]]]))

\\ What the JIT learns from the test must not change the outcome of either branch.
(define d.after
  G P [A | Ps] F -> [[defun F [A | Ps] [if [G A] [P A | Ps] [P A | Ps]]]])

(define d.subst-nth
  0 K [_ | Ps] -> [K | Ps]
  I K [P | Ps] -> [P | (d.subst-nth (- I 1) K Ps)])

(define d.drop-nth
  0 [_ | Ps] -> Ps
  I [P | Ps] -> [P | (d.drop-nth (- I 1) Ps)])

(define d.compile
  Defs -> (do (map (/. D (eval-kl D)) Defs)
              (let Def (d.last Defs)
                   Name (hd (tl Def))
                   Ps (hd (tl (tl Def)))
                (eval-kl (if (= Ps []) [freeze [Name]] (d.wrap Ps [Name | Ps]))))))

\\ Eval-kl's definitions aren't known to function, so calls go through a closure.
(define d.wrap
  [] Body -> Body
  [P | Ps] Body -> [lambda P (d.wrap Ps Body)])

(define d.last
  [X] -> X
  [_ | Xs] -> (d.last Xs))

(define d.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (d.filter F Xs)] (d.filter F Xs)))

\\ ---------------------------------------------------------------------------
\\ Running them

\\ Every list of N values from Lists, in order, each made afresh, with the same object twice too.
(define d.each-args
  [] Names Work -> (Work (reverse Names))
  [Vs | Lists] Names Work -> (d.each-value Vs Lists Names Work))

(define d.each-value
  [] _ _ _ -> done
  [V | Vs] Lists Names Work -> (do (d.each-args Lists [V | Names] Work)
                                   (d.each-value Vs Lists Names Work)))

(define d.args
  Vs -> (map (/. V (d.make V)) Vs))

(define d.names
  Vs -> (d.join (map (/. V (str (d.name V))) Vs)))

(define d.join
  [] -> ""
  [X] -> X
  [X | Xs] -> (cn X (cn " " (d.join Xs))))

\\ What a way should give, from what the plain call gave: a handler that ignores the error gives its own.
(define d.expected
  quiet Base -> (if (= (pos Base 0) "!") "= d.caught" Base)
  _ Base -> Base)

(define d.log
  Line -> (if (= (value d.*out*) none)
              skip
              (pr (cn Line (n->string 10)) (value d.*out*))))

(set d.*out* none)

(define d.run-way
  P Way Base Vs -> (let F (d.compile (d.defs Way P (d.params (length Vs)) (d.gensym)))
                     (d.compare P Way F Base Vs)))

(define d.compare
  P Way F Base Vs -> (do (d.check)
                         (let Got (d.outcome F (d.args Vs))
                              Want (d.expected Way Base)
                           (if (= Got Want)
                               ok
                               (d.fail (make-string "(~A ~A) ~A: ~A, plain ~A" P (d.names Vs) Way Got Want))))))

\\ One primitive: the plain call over all the values, and at each the other ways, which take the
\\ same arguments, so each is compiled once. Then its constants, which are compiled per constant.
(define d.prim
  P N All Literals
  -> (let Plain (d.compile [[defun (d.gensym) (d.params N) [P | (d.params N)]]])
          Ways (map (/. W (@p W (d.compile (d.defs W P (d.params N) (d.gensym))))) (d.ways P N))
          Lists (d.lists P N All)
       (do (d.each-args Lists [] (/. Vs (d.one P Plain Ways Vs)))
           (d.same-object P N All Plain)
           (d.constants P N Lists Literals Plain))))

(define d.lists
  shen-jit.copy-bytes _ All -> (let Memory (d.filter-names [b0 b1 b8 b8b bs bs8 sym n0 abc nv2b p8 p8b p0 ro8 dead] All)
                                    Index (d.filter-names [n0 n1 n2 n3 n7 n8 n-1 half r1 sym n9007199254740992
                                                           n2305843009213693951 n-2305843009213693952] All)
                                 [Memory Index Memory Index Index])
  _ N All -> (d.n-copies N All) where (<= N 2)
  _ N All -> (d.n-copies N (d.filter-names (d.few) All)))

(define d.n-copies
  0 _ -> []
  N X -> [X | (d.n-copies (- N 1) X)])

(define d.one
  P Plain Ways Vs
  -> (let Base (d.outcome Plain (d.args Vs))
       (do (if (d.address-shows? P Vs) skip (d.log (make-string "(~A ~A) ~A" P (d.names Vs) Base)))
           (map (/. W (d.compare P (fst W) (snd W) Base Vs)) Ways)
           done)))

\\ Whether a result depends on an address, and so does not compare with another run's. Within a run the
\\ blocks stay where they are.
(define d.address-shows?
  shen-jit.pointer-address _ -> true
  shen-jit.pointer! _ -> true
  shen-jit.hash Vs -> (d.any-pointer? Vs)
  hash Vs -> (d.any-pointer? Vs)
  _ _ -> false)

(define d.any-pointer?
  [] -> false
  [V | Vs] -> (or (element? (hd V) (d.pointer-names)) (d.any-pointer? Vs)))

\\ The same object as both arguments: = and same? may take a shortcut. Not shen-jit.newpv, which moves
\\ its offset on, so the second call on one object gives the next variable.
(define d.same-object
  shen-jit.newpv _ _ _ -> done
  P 2 All Plain -> (d.each-args [All] [] (/. Vs (d.same-one P Plain (hd Vs))))
  _ _ _ _ -> done)

(define d.same-one
  P Plain V -> (let X (d.make V)
                    Base (d.outcome Plain [X X])
                    F (d.same-way P)
                 (do (if (d.address-shows? P [V]) skip (d.log (make-string "(~A ~A same) ~A" P (d.name V) Base)))
                     (d.check)
                     (let Got (d.outcome F [X])
                       (if (= Got Base)
                           ok
                           (d.fail (make-string "(~A ~A ~A) same object: ~A, plain ~A" P (d.name V) (d.name V) Got Base)))))))

(set d.*same-ways* [])

(define d.same-way
  P -> (let Known (assoc P (value d.*same-ways*))
         (if (= Known [])
             (let F (d.compile [[defun (d.gensym) [a] [P a a]]])
               (do (set d.*same-ways* [[P | F] | (value d.*same-ways*)]) F))
             (tl Known))))

\\ A constant in each position, and in all of them at once for two arguments. The call is plain, and
\\ again after a let, which may pass the constant on, and through an inlined function, which does.
(define d.constants
  P N _ _ _ -> done where (> N 2)
  P 0 _ _ _ -> done
  P 1 Lists Literals Plain -> (d.constant-at P 1 0 Lists Literals Plain)
  P 2 Lists Literals Plain -> (do (d.constant-at P 2 0 Lists Literals Plain)
                                  (d.constant-at P 2 1 Lists Literals Plain)
                                  (d.both-constant P Literals Plain)))

(define d.constant-at
  P N I Lists Literals Plain
  -> (let Ps (d.params N)
          Rest (d.drop-nth I Ps)
          H (d.gensym)
          Inlined (eval-kl [defun H Ps [P | Ps]])
       (d.for-each (/. K (let C (hd (tl K))
                            Const (d.compile [[defun (d.gensym) Rest [P | (d.subst-nth I C Ps)]]])
                            Let (d.compile [[defun (d.gensym) Rest [let k C [P | (d.subst-nth I k Ps)]]]])
                            Through (d.compile [[defun (d.gensym) Rest [H | (d.subst-nth I C Ps)]]])
                         (d.each-args (d.drop-nth I Lists) []
                           (/. Vs (d.constant-one P I K Vs Plain [(@p const Const) (@p let-const Let) (@p inlined-const Through)])))))
                 Literals)))

(define d.constant-one
  P I K Vs Plain Ways
  -> (let All (d.subst-in I K Vs)
          Base (d.outcome Plain (d.args All))
       (d.for-each (/. W (do (d.check)
                           (let Got (d.outcome (snd W) (d.args Vs))
                             (if (= Got Base)
                                 ok
                                 (d.fail (make-string "(~A ~A) ~A at ~A: ~A, plain ~A" P (d.names All) (fst W) I Got Base))))))
                 Ways)))

(define d.subst-in
  0 K Vs -> [K | Vs]
  I K [V | Vs] -> [V | (d.subst-in (- I 1) K Vs)])

(define d.both-constant
  P Literals Plain
  -> (d.for-each (/. A (d.for-each (/. B (d.both-one P A B Plain)) Literals)) Literals))

(define d.both-one
  P A B Plain
  -> (let Base (d.outcome Plain (d.args [A B]))
          Got (d.outcome (freeze (eval-kl [P (hd (tl A)) (hd (tl B))])) [])
       (do (d.check)
           (if (= Got Base)
               ok
               (d.fail (make-string "(~A ~A ~A) both constant: ~A, plain ~A" P (d.name A) (d.name B) Got Base))))))

(define d.for-each
  _ [] -> done
  F [X | Xs] -> (do (F X) (d.for-each F Xs)))

\\ ---------------------------------------------------------------------------
\\ Properties

(define d.must
  true _ -> ok
  false Text -> (d.fail Text)
  V Text -> (d.fail (make-string "~A: not a Boolean: ~S" Text V)))

(define d.prop
  Test Text -> (do (d.check) (d.must (trap-error (Test) (/. E false)) (Text))))

\\ Numbers near each power of two, of both kinds, and what d.integers has.
(define d.number-values
  -> (let Powers (d.powers 0)
          Reals (map (/. K (d.real-pow K)) [0 1 2 31 32 52 53 54 60 61 62 63 64])
       (append (d.integers)
               Powers
               (map (/. N (- 0 N)) Powers)
               Reals
               (map (/. R (* -1 R)) Reals)
               [0.5 -0.5 0.1 1.5 (- 0.5 0.5) (* -1 (- 0.5 0.5)) 1.0e300 -1.0e300 1.0e-300 (* 1.0e200 1.0e200) (* -1.0e200 1.0e200)
                (- (* 1.0e200 1.0e200) (* 1.0e200 1.0e200))])))

(define d.powers
  61 -> []
  K -> (let P (d.pow 2 K)
         (append [(- P 1) P (+ P 1)] (d.powers (+ K 1)))))

(define d.hash-values
  -> [0 1 "" "a" "abc" (cn "ab" "c") foo [] true [1] [1 2] [[1] "a"] (cons 1 2) (+ 0.5 0.5) (- 0.5 0.5) (* -1 (- 0.5 0.5))
      (d.real-pow 53) (d.pow 2 53) (d.real-pow 61)
      (shen-jit.bytes 2) (shen-jit.string->bytes "abc") (shen-jit.string->bytes "abc") (vector 1) (vector 1) (@p 1 2) (@p 1 2)])

\\ = is symmetric, transitive and reflexive but for NaN, and what it calls equal hashes the same.
(define d.equivalence
  Xs -> (d.for-each (/. X (d.equal-to X Xs Xs)) Xs))

(define d.equal-to
  X [] _ -> done
  X [Y | Ys] Xs
  -> (do (d.prop (freeze (= (= X Y) (= Y X))) (freeze (make-string "= is not symmetric: ~S ~S" X Y)))
         (if (= X Y)
             (do (d.prop (freeze (= (hash X 1000000) (hash Y 1000000)))
                         (freeze (make-string "hash differs for equal ~S and ~S" X Y)))
                 (d.prop (freeze (= (shen-jit.hash X 1000000) (shen-jit.hash Y 1000000)))
                         (freeze (make-string "shen-jit.hash differs for equal ~S and ~S" X Y)))
                 (d.for-each (/. Z (d.prop (freeze (= (= Y Z) (= X Z)))
                                         (freeze (make-string "= is not transitive: ~S ~S ~S" X Y Z))))
                           Xs))
             skip)
         (d.equal-to X Ys Xs)))

\\ The comparisons agree with each other.
(define d.ordered
  Xs -> (d.for-each (/. X (d.for-each (/. Y (d.ordered-pair X Y)) Xs)) Xs))

(define d.ordered-pair
  X Y -> (let Lt (< X Y)
              Gt (> X Y)
              Eq (= X Y)
              Text (freeze (make-string "comparisons disagree for ~S and ~S: ~S ~S ~S" X Y Lt Eq Gt))
           (do (d.prop (freeze (= Lt (> Y X))) Text)
               (d.prop (freeze (or (d.nan-either? X Y) (= (<= X Y) (or Lt Eq)))) Text)
               (d.prop (freeze (or (d.nan-either? X Y) (= (>= X Y) (or Gt Eq)))) Text)
               (d.prop (freeze (if Lt (not (or Gt Eq)) (if Gt (not Eq) true))) Text)
               (d.prop (freeze (or Lt (or Gt (or Eq (d.nan-either? X Y))))) Text))))

(define d.nan-either?
  X Y -> (or (not (>= X X)) (not (>= Y Y))))

\\ Arithmetic: what must be so, or raise the same way both ways round.
(define d.arithmetic
  Xs -> (d.for-each (/. X (do (d.arith-one X) (d.for-each (/. Y (d.arith-pair X Y)) Xs))) Xs))

(define d.same-outcome
  F G Text -> (d.prop (freeze (= (d.outcome F []) (d.outcome G []))) Text))

(define d.arith-pair
  X Y -> (do (d.same-outcome (freeze (+ X Y)) (freeze (+ Y X)) (freeze (make-string "+ is not commutative: ~S ~S" X Y)))
             (d.same-outcome (freeze (* X Y)) (freeze (* Y X)) (freeze (make-string "* is not commutative: ~S ~S" X Y)))
             (d.add-undoes X Y)))

\\ X + Y - Y is X for integers, when X + Y is one.
(define d.add-undoes
  X Y -> (if (and (d.fixnum? X) (d.fixnum? Y))
             (let S (trap-error (+ X Y) (/. Ignored none))
               (if (= S none)
                   skip
                   (d.prop (freeze (and (d.fixnum? S) (= (- S Y) X)))
                           (freeze (make-string "~S + ~S gave ~S" X Y S)))))
             skip))

(define d.arith-one
  X -> (let Text (freeze (make-string "identity fails for ~S" X))
         (if (>= X X)
             (do (d.prop (freeze (= (d.show (+ X 0)) (d.show-zero-sum X))) Text)
                 (d.prop (freeze (= (d.show (* X 1)) (d.show (* 1 X)))) Text)
                 (d.prop (freeze (= (- X 0) X)) Text)
                 (d.prop (freeze (= (/ X 1) X)) Text)
                 (if (d.fixnum? X)
                     (d.prop (freeze (d.fixnum? (/ X 1))) Text)
                     skip))
             skip)))

\\ -0.0 + 0 is 0.0 in IEEE arithmetic.
(define d.show-zero-sum
  X -> (d.show (+ 0 X)))

\\ Strings: put together what was taken apart.
(define d.strings
  -> (d.for-each (/. S (d.string-one S))
               ["" "a" "abc" "é" "日本語" "aé日𝄞z" "abcdefgh" "abcdefghi" "abcdefghijklmnopqrstuvwxyz" (n->string 0) (cn "a" (n->string 0))]))

(define d.string-one
  "" -> (d.prop (freeze (= (trap-error (pos "" 0) (/. Ignored none)) none)) (freeze "pos of an empty string"))
  S -> (do (d.prop (freeze (= (cn (pos S 0) (tlstr S)) S)) (freeze (make-string "pos and tlstr do not rebuild ~S" S)))
           (d.prop (freeze (= (string->n (n->string (string->n S))) (string->n S)))
                   (freeze (make-string "string->n and n->string do not agree on ~S" S)))
           (d.prop (freeze (= (intern (cn "d.s" S)) (intern (cn "d.s" S)))) (freeze (make-string "intern ~S" S)))))

\\ Vectors and buffers: what is stored comes back.
(define d.stores
  -> (do (d.for-each (/. N (d.for-each (/. I (d.vector-store N I)) (d.range 0 N))) [1 2 3 7 8 15 16 17 40])
         (d.for-each (/. I (d.bytes-store I)) (d.range 0 16))))

(define d.range
  A B -> [] where (>= A B)
  A B -> [A | (d.range (+ A 1) B)])

(define d.vector-store
  N I -> (let V (absvector N)
           (do (address-> V I x)
               (d.prop (freeze (= (<-address V I) x)) (freeze (make-string "vector ~A at ~A" N I)))
               (d.prop (freeze (= (trap-error (<-address V N) (/. Ignored none)) none)) (freeze (make-string "vector ~A read past the end" N)))
               (d.prop (freeze (= (trap-error (address-> V N 0) (/. Ignored none)) none)) (freeze (make-string "vector ~A stored past the end" N))))))

(define d.bytes-store
  I -> (let B (shen-jit.bytes 16)
            Text (freeze (make-string "buffer at ~A" I))
         (do (shen-jit.u8! B I 200)
             (d.prop (freeze (= (shen-jit.u8 B I) 200)) Text)
             (if (<= I 14)
                 (do (shen-jit.u16! B I 51234) (d.prop (freeze (= (shen-jit.u16 B I) 51234)) Text))
                 (d.prop (freeze (= (trap-error (shen-jit.u16 B I) (/. Ignored none)) none)) Text))
             (if (<= I 12)
                 (do (shen-jit.u32! B I 4000000000) (d.prop (freeze (= (shen-jit.u32 B I) 4000000000)) Text)
                     (shen-jit.s32! B I -5) (d.prop (freeze (= (shen-jit.s32 B I) -5)) Text)
                     (shen-jit.f32! B I 1.5) (d.prop (freeze (= (shen-jit.f32 B I) 1.5)) Text))
                 (d.prop (freeze (= (trap-error (shen-jit.u32 B I) (/. Ignored none)) none)) Text))
             (if (<= I 8)
                 (do (shen-jit.s64! B I -7) (d.prop (freeze (= (shen-jit.s64 B I) -7)) Text)
                     (shen-jit.f64! B I 2.5) (d.prop (freeze (= (shen-jit.f64 B I) 2.5)) Text))
                 (d.prop (freeze (= (trap-error (shen-jit.s64 B I) (/. Ignored none)) none)) Text)))))

\\ Copies within a buffer and between two, overlapping or not, against what each byte should become. One
\\ that does not fit raises and changes nothing.
(define d.copies
  -> (let Range (d.range -1 10)
       (d.for-each (/. I (d.for-each (/. J (d.for-each (/. N (do (d.copy-one true I J N) (d.copy-one false I J N))) Range)) Range)) Range)))

(define d.pattern
  Base -> (d.fill (shen-jit.bytes 8) (/. K (+ Base K))))

(define d.fill
  B F -> (do (d.for-each (/. K (shen-jit.u8! B K (F K))) (d.range 0 8)) B))

(define d.copy-fits?
  I J N -> (and (>= I 0) (and (>= J 0) (and (>= N 0) (and (<= (+ I N) 8) (<= (+ J N) 8))))))

(define d.copy-one
  Same I J N
  -> (let From (d.pattern 1)
          To (if Same From (d.pattern 101))
          ToBase (if Same 1 101)
          Fits (d.copy-fits? I J N)
          Want (d.show (if Fits
                           (d.fill (shen-jit.bytes 8) (/. K (if (and (>= K I) (< K (+ I N))) (+ 1 (- (+ J K) I)) (+ ToBase K))))
                           (d.pattern ToBase)))
          Raised (trap-error (do (shen-jit.copy-bytes To I From J N) false) (/. E true))
          Text (freeze (make-string "copy ~A ~A ~A, same buffer ~A: raised ~A, gave ~A" I J N Same Raised (d.show To)))
       (do (d.prop (freeze (= Raised (not Fits))) Text)
           (d.prop (freeze (= (d.show To) Want)) Text)
           (d.prop (freeze (or Same (= (d.show From) (d.show (d.pattern 1))))) Text))))

\\ Memory outside the heap: each width at each offset of each length, against a model of the whole block, so
\\ a write past the length or to the wrong place shows. Reading past the length raises, storing through a
\\ read-only or killed pointer raises and changes nothing, and each copy of a pointer sees the same memory.
(define d.widths
  -> [[1 shen-jit.u8 shen-jit.u8! 200 200]
      [2 shen-jit.u16 shen-jit.u16! 51234 51234]
      [4 shen-jit.u32 shen-jit.u32! 4000000000 4000000000]
      [4 shen-jit.s32 shen-jit.s32! -5 -5]
      [8 shen-jit.s64 shen-jit.s64! -7 -7]])

(define d.whole
  I Base -> (d.show-bytes (d.block I Base 16) 0))

(define d.pointers
  -> (do (d.for-each (/. L (d.for-each (/. I (d.for-each (/. W (d.pointer-access L I W)) (d.widths))) (d.range -1 18))) [0 1 2 3 4 7 8 12 16])
         (d.pointer-copies)
         (d.pointer-identity)))

(define d.pointer-access
  L I [W Read Store X Y]
  -> (let Fits (and (>= I 0) (<= (+ I W) L))
          Text (freeze (make-string "~A at ~A of ~A" Read I L))
          M (d.block 0 1 L)
          Before (d.show-bytes (shen-jit.pointer-sized M 16) 0)
          RO (shen-jit.pointer-read-only M)
          Dead (shen-jit.pointer-kill (shen-jit.pointer-sized M L))
       (do (d.prop (freeze (= (d.raises? (freeze ((function Read) M I))) (not Fits))) Text)
           (d.prop (freeze (d.raises? (freeze ((function Store) RO I X)))) Text)
           (d.prop (freeze (d.raises? (freeze ((function Store) Dead I X)))) Text)
           (d.prop (freeze (d.raises? (freeze ((function Read) Dead I)))) Text)
           (d.prop (freeze (= Before (d.show-bytes (shen-jit.pointer-sized M 16) 0))) Text)
           (d.prop (freeze (= (d.raises? (freeze ((function Store) M I X))) (not Fits))) Text)
           (if Fits
               (do (d.prop (freeze (= ((function Read) M I) Y)) Text)
                   (d.prop (freeze (= ((function Read) RO I) Y)) Text))
               (d.prop (freeze (= Before (d.show-bytes (shen-jit.pointer-sized M 16) 0))) Text))
           (d.prop (freeze (d.outside-unchanged? (shen-jit.pointer-sized M 32) I W Fits)) Text))))

\\ What a store did not reach still holds the block's filling.
(define d.outside-unchanged?
  M I W Fits -> (d.outside-h M 0 I W Fits))

(define d.outside-h
  _ 32 _ _ _ -> true
  M K I W Fits -> (d.outside-h M (+ K 1) I W Fits) where (and Fits (and (>= K I) (< K (+ I W))))
  M K I W Fits -> (and (= (shen-jit.u8 M K) (+ 1 K)) (d.outside-h M (+ K 1) I W Fits)))

(define d.raises?
  F -> (trap-error (do (thaw F) false) (/. E true)))

(define d.pointer-copies
  -> (let Range (d.range -1 10)
       (d.for-each (/. I (d.for-each (/. J (d.for-each (/. N (do (d.pointer-copy true I J N) (d.pointer-copy false I J N))) Range)) Range)) Range)))

\\ As d.copy-one, on two blocks or within one.
(define d.pointer-copy
  Same I J N
  -> (let To (d.block 0 1 8)
          From (if Same To (d.block 1 101 8))
          FromBase (if Same 1 101)
          Fits (d.copy-fits? I J N)
          Want (d.show-bytes (if Fits
                                 (d.fill (shen-jit.bytes 8) (/. K (if (and (>= K I) (< K (+ I N))) (+ FromBase (- (+ J K) I)) (+ 1 K))))
                                 (d.pattern 1)) 0)
          Raised (trap-error (do (shen-jit.copy-bytes To I From J N) false) (/. E true))
          Text (freeze (make-string "pointer copy ~A ~A ~A, same ~A: raised ~A" I J N Same Raised))
       (do (d.prop (freeze (= Raised (not Fits))) Text)
           (d.prop (freeze (= (d.show-bytes To 0) Want)) Text))))

\\ Copies of a pointer are = to it, hash the same, and name what they came from. Its address goes through memory
\\ and back, what is unchecked reads what is there, and killing one kills no other.
(define d.pointer-identity
  -> (let M (d.block 0 1 8)
          S (shen-jit.pointer-sized M 4)
          K (shen-jit.pointer-kind M)
          B (shen-jit.bytes 16)
          T (freeze "pointers")
       (do (d.prop (freeze (= M S)) T)
           (d.prop (freeze (= (shen-jit.hash M 1000000) (shen-jit.hash S 1000000))) T)
           (d.prop (freeze (not (= M (shen-jit.pointer-read-only M)))) T)
           (d.prop (freeze (= (shen-jit.pointer-owner S) M)) T)
           (d.prop (freeze (= (shen-jit.pointer-owner (shen-jit.pointer-guard M guarded)) guarded)) T)
           (shen-jit.pointer! B 4 M)
           (d.prop (freeze (= (shen-jit.bytes->pointer B 4 K) M)) T)
           (d.prop (freeze (= (shen-jit.pointer-address (shen-jit.bytes->pointer B 4 K)) (shen-jit.pointer-address M))) T)
           (shen-jit.pointer! B 4 [])
           (d.prop (freeze (= (shen-jit.bytes->pointer B 4 K) [])) T)
           (d.prop (freeze (= (d.show-bytes (shen-jit.pointer->bytes M 2 3) 0) "3 4 5 ")) T)
           (shen-jit.u8! M 3 0)
           (d.prop (freeze (= (string->n (shen-jit.pointer->string M)) 1)) T)
           (shen-jit.pointer-kill S)
           (d.prop (freeze (= (shen-jit.u8 M 0) 1)) T)
           (d.prop (freeze (d.raises? (freeze (shen-jit.pointer->string S)))) T)
           (d.prop (freeze (d.raises? (freeze (shen-jit.pointer-sized S 1)))) T))))

\\ Bit operations against each other and against arithmetic.
(define d.bits
  Xs -> (d.for-each (/. X (do (d.bits-one X) (d.for-each (/. Y (d.bits-pair X Y)) Xs))) Xs))

(define d.bits-pair
  X Y -> (let Text (freeze (make-string "bit operations disagree for ~S and ~S" X Y))
              A (shen-jit.bit-and X Y)
              O (shen-jit.bit-or X Y)
              N (shen-jit.bit-xor X Y)
           (do (d.prop (freeze (= N (shen-jit.bit-and O (shen-jit.bit-not A)))) Text)
               (d.prop (freeze (= A (shen-jit.bit-and Y X))) Text)
               (d.prop (freeze (= O (shen-jit.bit-not (shen-jit.bit-and (shen-jit.bit-not X) (shen-jit.bit-not Y))))) Text))))

(define d.bits-one
  X -> (let Text (freeze (make-string "shifts disagree for ~S" X))
         (do (d.prop (freeze (= X (shen-jit.bit-not (shen-jit.bit-not X)))) Text)
             (d.prop (freeze (= (shen-jit.shift-left X 0) X)) Text)
             (d.prop (freeze (= (shen-jit.shift-right X 0) X)) Text)
             (d.prop (freeze (= (+ (shen-jit.popcount X) (shen-jit.popcount (shen-jit.bit-not X))) 62)) Text)
             (d.prop (freeze (= (shen-jit.shift-right X 63) (if (< X 0) -1 0))) Text)
             (d.for-each (/. K (d.shift X K)) [1 2 3 7 8 31 32 61 62 63]))))

(define d.shift
  X K -> (let Text (freeze (make-string "(shift ~S ~S)" X K))
              Right (shen-jit.shift-right X K)
           (do (if (and (<= K 60) (<= (d.abs X) (d.pow 2 (- 60 K))))
                   (d.prop (freeze (= (shen-jit.shift-left X K) (* X (d.pow 2 K)))) Text)
                   skip)
               (if (<= K 60)
                   (d.prop (freeze (= (shen-jit.shift-left Right K) (shen-jit.bit-and X (shen-jit.bit-not (- (d.pow 2 K) 1))))) Text)
                   skip))))

(define d.abs
  X -> (if (< X 0) (if (= X (- -2305843009213693951 1)) 2305843009213693951 (- 0 X)) X))

\\ ---------------------------------------------------------------------------
\\ The primitives, by arguments. Those missing would stop the run, block, or change
\\ what the rest depends on.

(define d.prims
  -> [[1 number? cons? string? absvector? hd tl tlstr str n->string string->n intern absvector value error-to-string
         shen-jit.symbol? shen-jit.fixnum? shen-jit.integer? shen-jit.vector? shen-jit.bytes? shen-jit.bytes shen-jit.bytes-length
         shen-jit.string->bytes shen-jit.bit-not shen-jit.bswap32 shen-jit.popcount shen-jit.clz shen-jit.ctz
         shen-jit.pvar shen-jit.pvar? shen-jit.pvar-offset shen-jit.pointer? simple-error
         shen-jit.pointer-kind shen-jit.pointer-address shen-jit.pointer-kill shen-jit.pointer-owner shen-jit.pointer-read-only
         shen-jit.arity shen-jit.function]
      [2 + - * / < > <= >= = cons cn pos <-address shen-jit.hash shen-jit.filled-vector shen-jit.tagged? shen-jit.same? shen-jit.newpv shen-jit.gc
         shen-jit.append shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.shift-left shen-jit.shift-right
         shen-jit.rotate32 shen-jit.decimal shen-jit.u8 shen-jit.u16 shen-jit.u32 shen-jit.s32 shen-jit.s64 shen-jit.f32 shen-jit.f64
         shen-jit.pointer-sized shen-jit.apply]
      [3 address-> shen-jit.deref shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.s32! shen-jit.s64! shen-jit.f32!
         shen-jit.f64! shen-jit.bytes->string shen-jit.bytes->pointer shen-jit.pointer!]
      [5 shen-jit.copy-bytes]])

\\ Against another implementation: the primitives and values of the language alone, called plainly, with
\\ no error's message, and a length that this implementation refuses might not be refused there.
(define d.portable-values
  -> (d.filter (/. V (not (element? (hd V) [pvar0 pvar1 b0 b1 b8 b8b bs bs8]))) (d.values)))

(define d.portable
  P N -> (let All (d.thunks (d.portable-values))
              F (eval-kl (d.wrap (d.params N) [P | (d.params N)]))
              Few (d.filter-names [n0 n1 n-1 n2 n3 n7 n8 n255 half r1 inf nan empty abc s9 nil sym pair one-list v0 v3 nv2b fn] All)
              Lists (d.n-copies N (if (or (> N 2) (element? P [absvector n->string])) Few All))
           (d.each-args Lists []
             (/. Vs (d.log (make-string "(~A ~A) ~A" P (d.names Vs) (d.portable-outcome F (d.args Vs))))))))

(define d.arguments
  P [[N | Ps] | Groups] -> (if (element? P Ps) N (d.arguments P Groups)))

(define d.portable-outcome
  F Args -> (trap-error (cn "= " (d.show (d.apply F Args))) (/. E "!")))

(define d.portable-prims
  -> [[1 number? cons? string? absvector? hd tl tlstr str n->string string->n intern absvector value error-to-string]
      [2 + - * / < > <= >= = cons cn pos <-address hash]
      [3 address->]])

(define d.main
  Only
  -> (let All (d.thunks (d.values))
          Literals (d.literal-values All)
       (do (d.for-each (/. Group (d.for-each (/. P (d.run-prim Only P (hd Group) All Literals)) (tl Group))) (d.prims))
           (if (or (= Only []) (= (hd Only) "properties"))
               (let Numbers (d.number-values)
                    Few (d.integers)
                 (do (output "properties~%")
                     (d.equivalence (append Numbers (d.hash-values)))
                     (d.ordered Numbers)
                     (d.arithmetic Numbers)
                     (d.strings)
                     (d.stores)
                     (d.copies)
                     (if (= (value d.*blocks*) []) skip (d.pointers))
                     (d.bits Few)))
               skip)
           (output "~A checks, ~A failed~%" (value d.*checks*) (value d.*failures*)))))

(define d.run-prim
  Only P N All Literals
  -> (if (or (= Only []) (= (hd Only) (str P)))
         (do (output "~A~%" P) (d.prim P N All Literals))
         skip))

\\ The primitives, to choose from.
(define d.list
  [] -> done
  [Group | Groups] -> (do (d.for-each (/. P (output "~A~%" P)) (tl Group)) (d.list Groups)))

\\ The arguments: --list, or the file for results, or "-", then the primitive to run, or "properties", or all.
(let Args (tl (value *argv*))
  (if (and (cons? Args) (= (hd Args) "--list"))
      (d.list (d.prims))
   (if (value d.*portable*)
      (if (= Args ["--portable"])
          (d.list (d.portable-prims))
          \\ --portable PRIMITIVE FILE
          (let P (intern (hd (tl Args)))
            (do (set d.*out* (open (hd (tl (tl Args))) out))
                (d.portable P (d.arguments P (d.portable-prims)))
                (close (value d.*out*)))))
      (do (if (or (= Args []) (= (hd Args) "-"))
              skip
              (set d.*out* (open (hd Args) out)))
          (d.main (if (= Args []) [] (tl Args)))
          (if (= (value d.*out*) none) skip (close (value d.*out*)))))))

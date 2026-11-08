\* Tests of lib/datalog.shen. Fixtures whose answers are written by hand, errors, and the engine
   against the plain definition over generated programs, under fixed and adaptive plans.
   Usage: shen-jit eval -l lib/datalog.shen -l tests/datalog.shen *\

(set dt.*checks* 0)
(set dt.*failures* 0)

(define dt.fail
  Name Got Want -> (do (set dt.*failures* (+ 1 (value dt.*failures*)))
                       (output "FAIL ~A: got ~R, want ~R~%" Name Got Want)))

(define dt.check
  Name Got Want -> (do (set dt.*checks* (+ 1 (value dt.*checks*)))
                       (if (= Got Want) ok (dt.fail Name Got Want))))

\* The reference, both kinds of plan, KL joins and facts added in three parts give the same
   sorted tuples. *\
(define dt.runs
  Name Facts -> [(datalog.run-naive Name Facts) (datalog.run Name Facts) (dt.run-fixed Name Facts) (dt.run-kl Name Facts)
                 (dt.run-added Name Facts) (dt.run-readded Name Facts)])

\* The facts in three parts: a run of the first, then two adds. *\
(define dt.run-added
  Name Facts -> (let Third (dt.third (length Facts))
                     A (dt.take Third Facts)
                     B (dt.take Third (dt.drop Third Facts))
                     C (dt.drop (* 2 Third) Facts)
                  (datalog.add (datalog.add (datalog.run Name A) B) C)))

\* A run of every fact, the middle third removed, and added back. *\
(define dt.run-readded
  Name Facts -> (let Mid (dt.middle Facts)
                  (datalog.add (datalog.remove (datalog.run Name Facts) Mid) Mid)))

(define dt.middle
  Facts -> (let Third (dt.third (length Facts)) (dt.take Third (dt.drop Third Facts))))

\* The facts that are not among these, every copy. *\
(define dt.facts-without
  [] _ -> []
  [F | Fs] Gone -> (if (element? F Gone) (dt.facts-without Fs Gone) [F | (dt.facts-without Fs Gone)]))

(define dt.third
  N -> (if (< N 3) 0 (+ 1 (dt.third (- N 3)))))

(define dt.take
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (dt.take (- N 1) Xs)])

(define dt.drop
  0 Xs -> Xs
  _ [] -> []
  N [_ | Xs] -> (dt.drop (- N 1) Xs))

\* With joins as KL, not native kernels, compiled afresh. *\
(define dt.run-kl
  Name Facts -> (let _ (set datalog.*native* false)
                     _ (datalog.forget-code Name)
                     Db (datalog.run Name Facts)
                     _ (set datalog.*native* true)
                     _ (datalog.forget-code Name)
                  Db))

\* With plans that do not follow sizes. *\
(define dt.run-fixed
  Name Facts -> (let _ (set datalog.*adaptive* false)
                     Db (datalog.run Name Facts)
                     _ (set datalog.*adaptive* true)
                  Db))

(define dt.same
  Label Facts Name Rel Want
  -> (dt.same-h (dt.runs Name Facts) Label Rel Want))

(define dt.same-h
  [] _ _ _ -> ok
  [Db | Dbs] Label Rel Want
  -> (do (dt.check (make-string "~A ~A" Label Rel) (datalog.sorted Db Rel) Want)
         (dt.same-h Dbs Label Rel Want)))

(define dt.raises
  Name Part F -> (let Got (trap-error (do (thaw F) "no error") (/. E (error-to-string E)))
                   (do (set dt.*checks* (+ 1 (value dt.*checks*)))
                       (if (dt.contains? Got Part) ok (dt.fail Name Got Part)))))

(define dt.contains?
  S Part -> true where (dt.prefix? Part S)
  "" _ -> false
  S Part -> (dt.contains? (tlstr S) Part))

(define dt.prefix?
  "" _ -> true
  _ "" -> false
  A B -> (and (= (pos A 0) (pos B 0)) (dt.prefix? (tlstr A) (tlstr B))))

\* ---- By hand. *\

(defdatalog dt.dep
  (relation imports [symbol symbol])
  (relation depends [symbol symbol])
  (relation cyclic [symbol])
  (rule (depends X Y) <-- (imports X Y))
  (rule (depends X Z) <-- (imports X Y) (depends Y Z))
  (rule (cyclic X) <-- (depends X X)))

\* A chain with a branch, and a separate cycle. *\
(set dt.dep-facts [[imports a b] [imports b c] [imports b d] [imports x y] [imports y x] [imports a b]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep imports
  [[a b] [b c] [b d] [x y] [y x]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep depends
  [[a b] [a c] [a d] [b c] [b d] [x x] [x y] [y x] [y y]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep cyclic [[x] [y]])
(dt.same "empty" [] dt.dep depends [])

\* Two recursive atoms, where a new tuple can arrive in either and only in the second. *\
(defdatalog dt.nonlinear
  (relation edge [symbol symbol])
  (relation path [symbol symbol])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(dt.same "nonlinear" [[edge a b]] dt.nonlinear path [[a b]])
(dt.same "nonlinear chain" [[edge a b] [edge b c] [edge c d] [edge d e]] dt.nonlinear path
  [[a b] [a c] [a d] [a e] [b c] [b d] [b e] [c d] [c e] [d e]])

\* Each combination of tuples is derived once, by the variant of the first atom that reads a new
   one, as the atoms before it read only the old tuples: by a lookup and its chain, a scan, and a
   probe of the table. With joins as KL nothing is derived twice, though an insert that finds no
   room counts again once it has grown it, at most 16 times here; a native kernel that has to grow
   its head starts again where it stood, which repeats at most Slack. *\
(define dt.derived
  Db Rel -> (hd (tl (tl (assoc Rel (datalog.stats Db))))))

(define dt.derived-once
  Label Name Facts Rel Want Slack
  -> (let Kl (dt.derived (dt.run-kl Name Facts) Rel)
          Native (dt.derived (datalog.run Name Facts) Rel)
          Exact (Want (datalog.run Name Facts))
       (do (dt.check (cn Label ", KL") (dt.within? Kl Exact 16) true)
           (dt.check (cn Label ", native") (dt.within? Native Kl Slack) true))))

(define dt.within?
  X Low Slack -> (and (>= X Low) (<= X (+ Low Slack))))

(define dt.joined
  [] _ -> 0
  [[_ Y] | Ts] Paths -> (+ (length (dt.from Y Paths)) (dt.joined Ts Paths)))

(define dt.from
  _ [] -> []
  Y [[Y Z] | Ts] -> [[Y Z] | (dt.from Y Ts)]
  Y [_ | Ts] -> (dt.from Y Ts))

(define dt.formula-edges
  N N Acc -> Acc
  I N Acc -> (dt.formula-edges (+ I 1) N [[e I (shen.mod (+ (* I 7) 3) N)] [e I (shen.mod (+ (* I 5) 1) N)] | Acc]))

(defdatalog dt.closure2
  (relation e [integer integer])
  (relation p [integer integer])
  (rule (p X Y) <-- (e X Y))
  (rule (p X Z) <-- (p X Y) (p Y Z)))

(defdatalog dt.cross
  (relation e [integer integer])
  (relation p [integer integer])
  (rule (p X Y) <-- (e X Y))
  (rule (p X Z) <-- (p X _) (p _ Z)))

(defdatalog dt.sym
  (relation e [integer integer])
  (relation p [integer integer])
  (relation q [integer integer])
  (rule (p X Y) <-- (e X Y))
  (rule (p Y X) <-- (q X Y))
  (rule (q X Y) <-- (p X Y) (p Y X)))

(dt.derived-once "nonlinear derives once" dt.closure2 (dt.formula-edges 0 16 []) p
  (/. Db (+ (datalog.count Db e) (dt.joined (datalog.tuples Db p) (datalog.tuples Db p)))) 100)
(dt.derived-once "a cross product derives once" dt.cross (dt.formula-edges 0 10 []) p
  (/. Db (+ (datalog.count Db e) (* (datalog.count Db p) (datalog.count Db p)))) 100)
(dt.derived-once "a member derives once" dt.sym (dt.formula-edges 0 24 [[e 1 2] [e 2 1] [e 5 5]]) q
  (/. Db (datalog.count Db q)) 4)

\* Mutual recursion, with a head outside the cycle reading it. *\
(defdatalog dt.mutual
  (relation succ [integer integer])
  (relation even [integer])
  (relation odd [integer])
  (relation both [integer])
  (rule (even 0))
  (rule (odd Y) <-- (even X) (succ X Y))
  (rule (even Y) <-- (odd X) (succ X Y))
  (rule (both X) <-- (even X) (odd X)))

(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual even [[0] [2] [4]])
(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual odd [[1] [3]])
(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual both [])
(dt.same "mutual, a cycle" [[succ 0 1] [succ 1 2] [succ 2 0]] dt.mutual both [[0] [1] [2]])

\* Constants, repeated variables, _, comparisons, strings, a rule with no atoms and a relation with
   no rules that also receives derived tuples. *\
(defdatalog dt.mixed
  (relation size [symbol integer])
  (relation name [symbol string])
  (relation link [symbol symbol])
  (relation big [symbol])
  (relation self [symbol])
  (relation linked [symbol])
  (relation pair [symbol symbol])
  (relation named [string])
  (relation fixed [symbol integer])
  (relation seeded [symbol])
  (rule (big X) <-- (size X N) (> N 10))
  (rule (self X) <-- (link X X))
  (rule (linked X) <-- (link X _))
  (rule (pair X Y) <-- (size X A) (size Y B) (< A B) (!= X Y))
  (rule (named S) <-- (name a S))
  (rule (fixed z 7))
  (rule (fixed X 8) <-- (name X "bee") (= X b))
  (rule (seeded X) <-- (link X b))
  (rule (seeded c)))

(set dt.mixed-facts [[size a 1] [size b 20] [size c 11] [size d 20]
                     [name a "ay"] [name b "bee"] [name a "alpha"]
                     [link a a] [link a b] [link c d] [link d d]
                     [seeded q]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed big [[b] [c] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed self [[a] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed linked [[a] [c] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed pair [[a b] [a c] [a d] [c b] [c d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed named [["alpha"] ["ay"]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed fixed [[b 8] [z 7]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed seeded [[a] [c] [q]])

\* A rule's own constant that no fact has, and a relation wide enough to need vectors. *\
(defdatalog dt.wide
  (relation r [integer integer integer integer integer integer integer])
  (relation s [integer integer])
  (rule (s A G) <-- (r A _ _ 99 _ _ G)))
(dt.same "wide" [[r 1 2 3 99 5 6 7] [r 8 9 10 11 12 13 14] [r 1 2 3 99 5 6 7]] dt.wide s [[1 7]])
(dt.same "wide" [[r 1 2 3 99 5 6 7] [r 8 9 10 11 12 13 14]] dt.wide r
  [[1 2 3 99 5 6 7] [8 9 10 11 12 13 14]])

\* A relation of no columns. *\
(defdatalog dt.nullary
  (relation a [symbol])
  (relation some [])
  (relation none [])
  (rule (some) <-- (a _))
  (rule (none) <-- (a nothing)))
(dt.same "nullary" [[a x] [a y]] dt.nullary some [[]])
(dt.same "nullary" [[a x]] dt.nullary none [])

\* Queries. *\
(let Db (datalog.run dt.dep (value dt.dep-facts))
  (do (dt.check "ask" (datalog.sort (datalog.ask Db (depends a X))) [[a b] [a c] [a d]])
      (dt.check "ask, repeated" (datalog.sort (datalog.ask Db (depends X X))) [[x x] [y y]])
      (dt.check "ask, anything" (datalog.sort (datalog.ask Db (depends _ d))) [[a d] [b d]])
      (dt.check "ask, none" (datalog.ask Db (depends q X)) [])
      (dt.check "holds" (datalog.holds? Db [depends a c]) true)
      (dt.check "does not hold" (datalog.holds? Db [depends c a]) false)
      (dt.check "not a value" (datalog.holds? Db [depends a nowhere]) false)
      (dt.check "count" (datalog.count Db depends) 9)))

\* The program as data is the same program. *\
(datalog.define dt.data
  [[relation e [symbol symbol]]
   [relation t [symbol symbol]]
   [rule [t [var "A"] [var "B"]] [[e [var "A"] [var "B"]]]]
   [rule [t [var "A"] [var "C"]] [[t [var "A"] [var "B"]] [e [var "B"] [var "C"]]]]])
(dt.same "as data" [[e a b] [e b c]] dt.data t [[a b] [a c] [b c]])

\* A long chain, where a loop that is not a tail call would run out of stack. *\
(define dt.chain
  N N Acc -> Acc
  I N Acc -> (dt.chain (+ I 1) N [[edge I (+ I 1)] | Acc]))

(defdatalog dt.reach
  (relation edge [integer integer])
  (relation start [integer])
  (relation reach [integer])
  (rule (start 0))
  (rule (reach X) <-- (start X))
  (rule (reach Y) <-- (reach X) (edge X Y)))

(let Db (datalog.run dt.reach (dt.chain 0 20000 []))
  (dt.check "long chain" (datalog.count Db reach) 20001))

\* A rule with many variables, each loop taking those it passes on as parameters. *\
(defdatalog dt.many
  (relation r [integer integer integer integer integer integer integer integer])
  (relation h [integer integer])
  (rule (h A1 C8) <-- (r A1 A2 A3 A4 A5 A6 A7 A8)
                      (r A8 B2 B3 B4 B5 B6 B7 B8)
                      (r B8 C2 C3 C4 C5 C6 C7 C8)
                      (!= A1 A2) (!= A2 A3) (!= A3 A4) (!= A4 A5) (!= A5 A6) (!= A6 A7) (!= A7 B2)
                      (!= B2 B3) (!= B3 B4) (!= B4 B5) (!= B5 B6) (!= B6 B7) (!= B7 C2)
                      (!= C2 C3) (!= C3 C4) (!= C4 C5) (!= C5 C6) (!= C6 C7)))
(dt.same "many variables"
  [[r 1 2 3 4 5 6 7 8] [r 8 9 10 11 12 13 14 15] [r 15 16 17 18 19 20 21 22] [r 15 1 1 1 1 1 1 1]]
  dt.many h [[1 22]])

\* Tables and buffers grow well past where they start, and find what they hold. *\
(define dt.many-edges
  0 Acc -> Acc
  N Acc -> (dt.many-edges (- N 1) [[edge N (+ N 1)] | Acc]))
(let Db (datalog.run dt.reach (dt.many-edges 5000 [[edge 0 1]]))
  (do (dt.check "grown, right" (datalog.count Db reach) 5002)
      (dt.check "grown, found" (datalog.holds? Db [edge 2500 2501]) true)
      (dt.check "grown, not found" (datalog.holds? Db [edge 2501 2500]) false)))

\* Plans follow sizes as they grow, and what is generated can be read. *\
(let Db (datalog.run dt.reach (dt.chain 0 2000 []))
  (dt.check "plans again as sizes grow" (> (hd (tl (hd (tl (datalog.stats Db))))) 4) true))
(dt.check "plans are there to read" (cons? (datalog.plans dt.dep)) true)
(dt.check "code is there to read" (hd (hd (datalog.code dt.dep))) define-native)
(dt.check "with the KL around it" (element? defun (map (function hd) (datalog.code dt.dep))) true)

\* A rule whose order matters, written either way, gives one result. *\
(defdatalog dt.order-a
  (relation big [integer integer]) (relation tiny [integer integer]) (relation out [integer integer])
  (rule (out A C) <-- (big A B) (tiny B C)))
(defdatalog dt.order-b
  (relation big [integer integer]) (relation tiny [integer integer]) (relation out [integer integer])
  (rule (out A C) <-- (tiny B C) (big A B)))
(set dt.order-facts [[big 1 2] [big 3 2] [big 4 5] [tiny 2 9]])
(dt.same "order, one way" (value dt.order-facts) dt.order-a out [[1 9] [3 9]])
(dt.same "order, the other" (value dt.order-facts) dt.order-b out [[1 9] [3 9]])

\* The kernels themselves, with enough random tuples that hashes collide: values in a run are small
   and dense, and meet few collisions. With 300000 of them about ten pairs share a fingerprint. *\
(set dt.*bits* 88172645)

(define dt.u32
  -> (let X (value dt.*bits*)
          Y (shen-jit.bit-xor X (shen-jit.bit-and (shen-jit.shift-left X 13) 4294967295))
          Z (shen-jit.bit-xor Y (shen-jit.shift-right Y 17))
          W (shen-jit.bit-xor Z (shen-jit.bit-and (shen-jit.shift-left Z 5) 4294967295))
          _ (set dt.*bits* W)
       W))

\* Keys in a small range for the first column, so that chains are long; tuples go in a dictionary
   too, by what they should be. *\
(define dt.fill-relation
  _ 0 _ Seen -> Seen
  R N Add Seen
  -> (let A (shen-jit.bit-and (dt.u32) 524287)
          B (dt.u32)
          _ (Add R [A B])
          _ (shen.dict-> Seen [A B] true)
       (dt.fill-relation R (- N 1) Add Seen)))

(define dt.all-found
  _ _ [] Acc -> Acc
  R Find [T | Ts] Acc -> (dt.all-found R Find Ts (if (> (Find R T) 0) Acc (+ Acc 1))))

(define dt.chain-length
  P _ _ N _ _ -> N where (= P 0)
  P Next Tuples N Key Off
  -> (dt.chain-length (shen-jit.u32 Next (* 4 (- P 1))) Next Tuples
       (if (= (shen-jit.u32 Tuples (+ Off (* 8 (- P 1)))) Key) (+ N 1) -1000000000) Key Off))

\* Each key's chain holds exactly its tuples. *\
(define dt.chains
  _ _ _ _ [] _ Acc -> Acc
  Index Tuples Find Want [K | Ks] Off Acc
  -> (let P (Find (<-address Index 0) Tuples (<-address Index 2) K)
          N (dt.chain-length P (<-address Index 1) Tuples 0 K Off)
       (dt.chains Index Tuples Find Want Ks Off (if (= N (tl (assoc-or K Want))) Acc (+ Acc 1)))))

(define assoc-or
  K D -> (let E (shen.<-dict D K) [K | E]))

(define dt.key-counts
  [] _ D -> D
  [T | Ts] Column D -> (let A (dt.column T Column)
                            E (trap-error (shen.<-dict D A) (/. X 0))
                            _ (shen.dict-> D A (+ E 1))
                         (dt.key-counts Ts Column D)))

(define dt.column
  [A _] 1 -> A
  [_ B] 2 -> B)

\* Tuples not in the relation, of which some share a fingerprint with one that is. *\
(define dt.absent-found
  _ _ _ 0 Acc -> Acc
  R Find Seen N Acc
  -> (let T [(+ 524288 (shen-jit.bit-and (dt.u32) 524287)) (dt.u32)]
       (dt.absent-found R Find Seen (- N 1) (if (> (Find R T) 0) (+ Acc 1) Acc))))

\* An index by one column, with a kernel called as a closure. *\
(define dt.index-test
  Label R Tuples Column
  -> (let Index (datalog.new-index 2 [Column] (datalog.count-of R))
          _ (datalog.index-range R Index 0 (datalog.count-of R))
          Counts (dt.key-counts Tuples Column (shen.dict 8))
          K (datalog.find-kernel 2 [Column])
          Find (eval-kl [lambda a [lambda b [lambda c [lambda d [K a b c d]]]]])
          _ (dt.check (cn "kernels: an index counts its keys, " Label) (<-address Index 4) (shen.dict-count Counts))
       (dt.check (cn "kernels: each chain holds its tuples, " Label)
                 (dt.chains Index (<-address R 2) Find Counts (shen.dict-keys Counts) (* 4 (- Column 1)) 0) 0)))

(define dt.kernel-test
  -> (let R (datalog.new-relation 2 false)
          Add (datalog.adder 2)
          Seen (dt.fill-relation R 300000 Add (shen.dict 8))
          Tuples (shen.dict-keys Seen)
          _ (dt.check "kernels: distinct tuples counted" (datalog.count-of R) (shen.dict-count Seen))
          _ (dt.check "kernels: each tuple found" (dt.all-found R (datalog.finder 2) Tuples 0) 0)
          _ (dt.check "kernels: absent tuples not found" (dt.absent-found R (datalog.finder 2) Seen 300000 0) 0)
          _ (dt.index-test "long chains" R Tuples 1)
          _ (dt.index-test "wide keys" R Tuples 2)
       ok))

\* Too much allocation for GC stress, whose run sets this first, and the rest there has buffers moving. *\
(if (trap-error (value dt.*light*) (/. E false)) ok (dt.kernel-test))

\* A plan that begins with a lookup, whose head grows while an inner scan is part done: the kernel
   starts again from the beginning, not from where the inner scan stood. *\
(defdatalog dt.restart
  (relation k [symbol integer])
  (relation big [integer])
  (relation out [integer integer])
  (rule (out X Y) <-- (k a X) (big Y)))

(define dt.upto-facts
  _ 0 Acc -> Acc
  Rel N Acc -> (dt.upto-facts Rel (- N 1) [[Rel N] | Acc]))

(define dt.pairs-of
  [] _ -> []
  [X | Xs] Ys -> (append (map (/. Y [X Y]) Ys) (dt.pairs-of Xs Ys)))

(dt.same "restarting a kernel" (append [[k a 1] [k a 2] [k b 3] [k a 3]] (dt.upto-facts big 40 []))
  dt.restart out (dt.pairs-of [1 2 3] (map (/. F (hd (tl F))) (dt.upto-facts big 40 []))))

\* Negation: what is not reached, what has no edge out, and what is not reached by a path of its
   own, which negates a recursive relation from a later stratum. *\
(defdatalog dt.neg
  (relation node [symbol])
  (relation edge [symbol symbol])
  (relation start [symbol])
  (relation reach [symbol])
  (relation unreached [symbol])
  (relation sink [symbol])
  (relation path [symbol symbol])
  (relation acyclic [symbol])
  (relation lonely [symbol])
  (rule (reach X) <-- (start X))
  (rule (reach Y) <-- (reach X) (edge X Y))
  (rule (unreached X) <-- (node X) (not (reach X)))
  (rule (sink X) <-- (node X) (not (edge X _)))
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z))
  (rule (acyclic X) <-- (node X) (not (path X X)))
  (rule (lonely X) <-- (unreached X) (not (edge _ X)) (not (start a))))

(set dt.neg-facts [[node a] [node b] [node c] [node d] [node e] [start a]
                   [edge a b] [edge b c] [edge c b] [edge d e]])

(dt.same "negation" (value dt.neg-facts) dt.neg unreached [[d] [e]])
(dt.same "negation" (value dt.neg-facts) dt.neg sink [[e]])
(dt.same "negation" (value dt.neg-facts) dt.neg acyclic [[a] [d] [e]])
(dt.same "negation" (value dt.neg-facts) dt.neg lonely [])
(dt.same "negation, empty" (remove [start a] (value dt.neg-facts)) dt.neg lonely [[a] [d]])

\* A negated atom with no keys: whether its relation is empty. *\
(defdatalog dt.neg-empty
  (relation node [symbol])
  (relation edge [symbol symbol])
  (relation edgeless [symbol])
  (rule (edgeless X) <-- (node X) (not (edge _ _))))

(dt.same "negation, no keys" [[node a] [node b] [edge a b]] dt.neg-empty edgeless [])
(dt.same "negation, no keys" [[node a] [node b]] dt.neg-empty edgeless [[a] [b]])

(dt.raises "negation in a cycle" "depends on the negation or an aggregate of"
  (freeze (datalog.define dt.bad [[relation p [symbol]] [relation q [symbol]]
                                  [rule [p [var "X"]] [[q [var "X"]]]]
                                  [rule [q [var "X"]] [[q [var "X"]] [not [p [var "X"]]]]]])))
(dt.raises "negation of itself" "depends on its own negation or aggregate"
  (freeze (datalog.define dt.bad [[relation p [symbol]] [relation q [symbol]]
                                  [rule [p [var "X"]] [[q [var "X"]] [not [p [var "X"]]]]]])))

(dt.raises "negation, unstratified loop" "depends on"
  (freeze (datalog.define dt.neg-loop2 [[relation n [integer]] [relation even [integer]] [relation odd [integer]]
                                        [rule [odd [var "Y"]] [[n [var "Y"]] [not [even [var "Y"]]]]]
                                        [rule [even [var "Y"]] [[n [var "Y"]] [not [odd [var "Y"]]]]]])))
(dt.raises "an unbound negated variable" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation p [symbol]] [relation q [symbol symbol]]
                                  [rule [p [var "X"]] [[p [var "X"]] [not [q [var "X"] [var "Y"]]]]]])))
(dt.raises "negating a comparison" "is not an atom"
  (freeze (datalog.define dt.bad [[relation p [integer]] [rule [p [var "X"]] [[p [var "X"]] [not 1]]]])))
(dt.raises "not as a relation" "cannot name"
  (freeze (datalog.define dt.bad [[relation not [symbol]]])))

\* Arithmetic: distances along weighted edges, bounded so that they end; a lookup by a computed
   value; bindings that depend on each other, written in either order; an alias of a symbol; and
   expressions compared. *\
(defdatalog dt.arith
  (relation edge [symbol symbol integer])
  (relation start [symbol])
  (relation dist [symbol integer])
  (relation n [integer])
  (relation next [integer integer])
  (relation chain [integer integer integer])
  (relation same [symbol symbol])
  (relation small [integer integer])
  (relation sq [integer integer])
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W)) (<= D 10))
  (rule (next X Y) <-- (n X) (= Y (+ X 1)) (n Y))
  (rule (chain X Z Y) <-- (n X) (= Z (* Y 2)) (= Y (- X 1)))
  (rule (same X Y) <-- (start X) (= Y X))
  (rule (small X Y) <-- (n X) (n Y) (< (+ X Y) 2) (= (- X Y) 1))
  (rule (sq X Y) <-- (n X) (= Y (- (* X X) (* 2 X)))))

(set dt.arith-facts [[start a] [edge a b 3] [edge b c 4] [edge a c 9] [edge c a 1] [edge c d 5]
                     [n -1] [n 0] [n 1] [n 2] [n 4]])

(dt.same "arithmetic" (value dt.arith-facts) dt.arith dist [[a 0] [a 8] [a 10] [b 3] [c 7] [c 9]])
(dt.same "arithmetic" (value dt.arith-facts) dt.arith next [[-1 0] [0 1] [1 2]])
(dt.same "arithmetic" (value dt.arith-facts) dt.arith chain [[-1 -4 -2] [0 -2 -1] [1 0 0] [2 2 1] [4 6 3]])
(dt.same "arithmetic" (value dt.arith-facts) dt.arith same [[a a]])
(dt.same "arithmetic" (value dt.arith-facts) dt.arith small [[0 -1] [1 0]])
(dt.same "arithmetic" (value dt.arith-facts) dt.arith sq [[-1 3] [0 0] [1 -1] [2 0] [4 8]])

\* 32 bits, signed: the extremes are kept and ordered, and arithmetic past them raises, however
   it is evaluated. *\
(defdatalog dt.int32
  (relation v [integer])
  (relation lt [integer integer])
  (rule (lt X Y) <-- (v X) (v Y) (< X Y)))

(defdatalog dt.int32-up
  (relation v [integer])
  (relation up [integer integer])
  (rule (up X Y) <-- (v X) (= Y (+ X 1))))

(dt.same "32 bits" [[v -2147483648] [v 0] [v 2147483647]] dt.int32 lt
  [[-2147483648 0] [-2147483648 2147483647] [0 2147483647]])
(dt.raises "past 32 bits" "outside 32 bits" (freeze (datalog.run dt.int32-up [[v 2147483647]])))
(dt.raises "past 32 bits, KL" "outside 32 bits" (freeze (dt.run-kl dt.int32-up [[v 2147483647]])))
(set datalog.*native* true)
(datalog.forget-code dt.int32-up)
(dt.raises "past 32 bits, reference" "outside 32 bits" (freeze (datalog.run-naive dt.int32-up [[v 2147483647]])))
(dt.raises "a fact past 32 bits" "in a column of type integer" (freeze (datalog.run dt.int32 [[v 2147483648]])))
(dt.check "holds? with an integer" (datalog.holds? (datalog.run dt.int32-up [[v -5]]) [up -5 -4]) true)
(dt.check "holds? across types" (datalog.holds? (datalog.run dt.dep [[imports a b]]) [imports 0 1]) false)

(dt.raises "arithmetic on symbols" "works on integers"
  (freeze (datalog.define dt.bad [[relation p [symbol]] [rule [p [var "Y"]] [[p [var "X"]] [= [var "Y"] [+ [var "X"] 1]]]]])))
(dt.raises "an unbound binding" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation p [integer]] [rule [p [var "Y"]] [[p [var "X"]] [= [var "Y"] [+ [var "Z"] 1]]]]])))
(dt.raises "two unbound sides" "is not bound"
  (freeze (datalog.define dt.bad [[relation p [integer]] [rule [p [var "X"]] [[p [var "X"]] [= [var "Y"] [var "Z"]]]]])))

\* Aggregates: by a key, over a whole relation, over nothing, with a variable repeated in the atom,
   and comparing a result bound already. *\
(defdatalog dt.agg
  (relation node [symbol])
  (relation edge [symbol symbol])
  (relation w [symbol integer])
  (relation degree [symbol integer])
  (relation total [integer])
  (relation loops [integer])
  (relation weight [symbol integer])
  (relation heaviest [symbol integer])
  (relation lightest [symbol integer])
  (relation consistent [symbol])
  (relation weighs-degree [symbol integer])
  (relation linked [symbol symbol integer])
  (rule (degree X N) <-- (node X) (= N (count (edge X _))))
  (rule (total N) <-- (= N (count (edge _ _))))
  (rule (loops N) <-- (= N (count (edge Y Y))))
  (rule (weight X S) <-- (node X) (= S (sum W (w X W))))
  (rule (heaviest X M) <-- (node X) (= M (max W (w X W))))
  (rule (lightest X M) <-- (node X) (= (min W (w X W)) M))
  (rule (consistent X) <-- (degree X D) (= D (count (edge X _))))
  (rule (weighs-degree X N) <-- (node X) (w X N) (= N (count (edge X _))))
  (rule (linked X Y N) <-- (edge X Y) (= N (count (edge X Y)))))

(set dt.agg-facts [[node a] [node b] [node c] [node d] [edge a b] [edge a c] [edge b c] [edge c c]
                   [w a 5] [w a 3] [w b 7] [w b 1] [w c -2]])

(dt.same "aggregates" (value dt.agg-facts) dt.agg degree [[a 2] [b 1] [c 1] [d 0]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg total [[4]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg loops [[1]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg weight [[a 8] [b 8] [c -2] [d 0]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg heaviest [[a 5] [b 7] [c -2]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg lightest [[a 3] [b 1] [c -2]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg consistent [[a] [b] [c] [d]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg weighs-degree [[b 1]])
(dt.same "aggregates" (value dt.agg-facts) dt.agg linked [[a b 1] [a c 1] [b c 1] [c c 1]])
(dt.same "aggregates, nothing" [] dt.agg total [[0]])

(defdatalog dt.agg-sum
  (relation w [symbol integer])
  (relation weight [symbol integer])
  (rule (weight X S) <-- (w X _) (= S (sum W (w X W)))))

(dt.raises "a sum past 32 bits" "outside 32 bits" (freeze (datalog.run dt.agg-sum [[w a 2147483647] [w a 1]])))
(dt.raises "a sum past 32 bits, KL" "outside 32 bits" (freeze (dt.run-kl dt.agg-sum [[w a 2147483647] [w a 1]])))
(set datalog.*native* true)
(datalog.forget-code dt.agg-sum)
(dt.raises "a sum past 32 bits, reference" "outside 32 bits"
  (freeze (datalog.run-naive dt.agg-sum [[w a 2147483647] [w a 1]])))
\* Added a part at a time, this sum would pass 32 bits on the way, so only whole runs. *\
(set dt.back [[w a 2147483647] [w a 1] [w a -5]])
(dt.check "a sum back within 32 bits" (datalog.sorted (datalog.run dt.agg-sum (value dt.back)) weight) [[a 2147483643]])
(dt.check "a sum back within 32 bits, KL" (datalog.sorted (dt.run-kl dt.agg-sum (value dt.back)) weight) [[a 2147483643]])
(dt.check "a sum back within 32 bits, reference" (datalog.sorted (datalog.run-naive dt.agg-sum (value dt.back)) weight) [[a 2147483643]])

(dt.raises "an aggregate of itself" "its own negation or aggregate"
  (freeze (datalog.define dt.bad [[relation p [symbol integer]] [relation q [symbol]]
                                  [rule [p [var "X"] [var "N"]] [[q [var "X"]] [= [var "N"] [count [p [var "X"] [any]]]]]]])))
(dt.raises "what sum reads, not in its atom" "is not in its atom"
  (freeze (datalog.define dt.bad [[relation w [symbol integer]] [relation s [symbol integer]]
                                  [rule [s [var "X"] [var "S"]] [[w [var "X"] [any]] [= [var "S"] [sum [var "Y"] [w [var "X"] [var "W"]]]]]]])))
(dt.raises "what sum reads, as a key" "must appear only in its atom"
  (freeze (datalog.define dt.bad [[relation w [symbol integer]] [relation s [integer integer]]
                                  [rule [s [var "W"] [var "S"]] [[w [any] [var "W"]] [= [var "S"] [sum [var "W"] [w [any] [var "W"]]]]]]])))
(dt.raises "a sum of symbols" "sum reads integers"
  (freeze (datalog.define dt.bad [[relation e [symbol symbol]] [relation s [symbol integer]]
                                  [rule [s [var "X"] [var "S"]] [[e [var "X"] [any]] [= [var "S"] [sum [var "Y"] [e [var "X"] [var "Y"]]]]]]])))
(dt.raises "a result in what it reads" "is what the aggregate gives"
  (freeze (datalog.define dt.bad [[relation w [symbol integer]] [relation s [symbol integer]]
                                  [rule [s [var "X"] [var "N"]] [[w [var "X"] [any]] [= [var "N"] [count [w [var "X"] [var "N"]]]]]]])))
(dt.raises "a symbol result" "an aggregate gives an integer"
  (freeze (datalog.define dt.bad [[relation e [symbol symbol]] [relation s [symbol]]
                                  [rule [s [var "X"]] [[e [var "X"] [var "Y"]] [= [var "Y"] [count [e [var "X"] [any]]]]]]])))
(dt.raises "an aggregate in arithmetic" "is not a value"
  (freeze (datalog.define dt.bad [[relation e [symbol symbol]] [relation s [symbol integer]]
                                  [rule [s [var "X"] [var "N"]] [[e [var "X"] [any]] [= [var "N"] [+ [count [e [var "X"] [any]]] 1]]]]])))
(dt.raises "aggregate as a relation" "cannot name"
  (freeze (datalog.define dt.bad [[relation aggregate [symbol]]])))

\* Fingerprints collide only among many values spread over 32 bits, so that a probe that trusted
   one would pass every small test. Native joins against KL joins, whose probes are the table
   kernels', on lookups, members and negations of 150,000 random tuples, most keys absent. *\
(defdatalog dt.spread
  (relation a [integer integer])
  (relation b [integer])
  (relation c [integer integer])
  (relation t [integer integer integer])
  (relation by-key [integer integer])
  (relation by-two [integer integer integer])
  (relation member [integer integer])
  (relation missing [integer])
  (relation missing-two [integer integer])
  (rule (by-key X Y) <-- (b X) (a X Y))
  (rule (by-two X Y Z) <-- (c X Y) (t X Y Z))
  (rule (member X Y) <-- (c X Y) (a X Y))
  (rule (missing X) <-- (b X) (not (a X _)))
  (rule (missing-two X Y) <-- (c X Y) (not (t X Y _))))

(define dt.word32
  -> (- (shen-jit.bit-xor (shen-jit.shift-left (dtg.random 65536) 16) (dtg.random 65536)) 2147483648))

(define dt.spread-facts
  0 Acc -> Acc
  N Acc -> (let X (dt.word32) Y (dt.word32) Z (dt.word32)
             (dt.spread-facts (- N 1)
               (append [[a X Y] [t X Y Z]]
                       (if (= 0 (shen.mod N 2)) [[b Z] [c Z Y]] [])
                       (if (= 0 (shen.mod N 3)) [[b X] [c X Y]] [])
                       Acc))))

(let Facts (dt.spread-facts 150000 [])
     Native (datalog.run dt.spread Facts)
     Kl (dt.run-kl dt.spread Facts)
  (map (/. R (dt.check (make-string "spread ~A" R) (datalog.count Native R) (datalog.count Kl R)))
       [by-key by-two member missing missing-two]))

\* Native kernels run, and the plans that fall back to KL are few. *\
(dt.check "native kernels ran" (< (value datalog.*fallbacks*) 20) true)

\* Records and types of several constructors: taken apart in bodies, at any depth and with a
   variable bound in another column, made in heads, by =, as a lookup's key and in a negation,
   compared, counted, and as recursive values that only grow while a bound holds. *\
(defdatalog dt.shapes
  (type point [pt integer integer])
  (type shape [circle point integer] [rect point point] [blank])
  (relation drawn [symbol shape])
  (relation centre [symbol point])
  (relation wide [symbol integer])
  (relation corner [symbol integer integer])
  (relation at [point symbol])
  (relation near [symbol symbol])
  (relation unit [symbol shape])
  (relation lonely [symbol])
  (relation diagonal [symbol])
  (relation same-place [symbol symbol])
  (relation circles [integer])
  (relation blanks [symbol])
  (rule (centre S P) <-- (drawn S [circle P _]))
  (rule (wide S W) <-- (drawn S [rect [pt X1 _] [pt X2 _]]) (= W (- X2 X1)))
  (rule (corner S X Y) <-- (drawn S [rect [pt X Y] _]))
  (rule (corner S X Y) <-- (drawn S [circle [pt X Y] _]))
  (rule (diagonal S) <-- (drawn S [rect [pt X X] [pt Y Y]]))
  (rule (near S T) <-- (corner S X Y) (at [pt X Y] T))
  (rule (unit S [circle P 1]) <-- (centre S P))
  (rule (unit S Q) <-- (corner S X Y) (= Q [rect [pt X Y] [pt (+ X 1) (+ Y 1)]]))
  (rule (lonely S) <-- (corner S X Y) (not (at [pt X Y] _)))
  (rule (same-place S T) <-- (drawn S A) (drawn T B) (= A B) (!= S T))
  (rule (circles N) <-- (= N (count (drawn _ [circle _ _]))))
  (rule (blanks S) <-- (drawn S [blank])))

(set dt.shapes-facts
  [[drawn a [circle [pt 0 0] 5]] [drawn b [rect [pt 1 2] [pt 4 6]]] [drawn c [rect [pt 3 3] [pt 7 7]]]
   [drawn d [circle [pt 9 9] 1]] [drawn e [blank]] [drawn f [rect [pt 1 2] [pt 4 6]]]
   [at [pt 1 2] home] [at [pt 9 9] work]])
(dt.same "records" (value dt.shapes-facts) dt.shapes centre [[a [pt 0 0]] [d [pt 9 9]]])
(dt.same "records" (value dt.shapes-facts) dt.shapes wide [[b 3] [c 4] [f 3]])
(dt.same "records" (value dt.shapes-facts) dt.shapes diagonal [[c]])
(dt.same "records" (value dt.shapes-facts) dt.shapes near [[b home] [d work] [f home]])
(dt.same "records" (value dt.shapes-facts) dt.shapes unit
  [[a [circle [pt 0 0] 1]] [a [rect [pt 0 0] [pt 1 1]]] [b [rect [pt 1 2] [pt 2 3]]] [c [rect [pt 3 3] [pt 4 4]]]
   [d [circle [pt 9 9] 1]] [d [rect [pt 9 9] [pt 10 10]]] [f [rect [pt 1 2] [pt 2 3]]]])
(dt.same "records" (value dt.shapes-facts) dt.shapes lonely [[a] [c]])
(dt.same "records" (value dt.shapes-facts) dt.shapes same-place [[b f] [f b]])
(dt.same "records" (value dt.shapes-facts) dt.shapes circles [[2]])
(dt.same "records" (value dt.shapes-facts) dt.shapes blanks [[e]])

(let Db (datalog.run dt.shapes (value dt.shapes-facts))
  (do (dt.check "a record asked" (datalog.sort (datalog.ask Db (drawn X [rect [pt 1 Y] _]))) [[b [rect [pt 1 2] [pt 4 6]]] [f [rect [pt 1 2] [pt 4 6]]]])
      (dt.check "a record holds" (datalog.holds? Db [drawn d [circle [pt 9 9] 1]]) true)
      (dt.check "a record does not hold" (datalog.holds? Db [drawn d [circle [pt 9 9] 2]]) false)
      (dt.check "a record never made" (datalog.holds? Db [drawn d [circle [pt 8 8] 1]]) false)
      (dt.check "a record of the wrong type" (datalog.holds? Db [drawn d [pt 9 9]]) false)))

\* A list type, built up along paths and taken apart again, bounded by its length. *\
(defdatalog dt.lists
  (type path [nil] [cons symbol path])
  (relation edge [symbol symbol])
  (relation start [symbol])
  (relation route [symbol path integer])
  (relation second [symbol symbol])
  (rule (route X [cons X [nil]] 1) <-- (start X))
  (rule (route Y [cons Y P] N) <-- (route X P M) (edge X Y) (= N (+ M 1)) (<= N 4))
  (rule (second X Y) <-- (route X [cons X [cons Y _]] _)))

(dt.same "lists" [[start a] [edge a b] [edge b c] [edge b a] [edge c a]] dt.lists route
  [[a [cons a [cons b [cons a [nil]]]] 3] [a [cons a [cons c [cons b [cons a [nil]]]]] 4] [a [cons a [nil]] 1]
   [b [cons b [cons a [cons b [cons a [nil]]]]] 4] [b [cons b [cons a [nil]]] 2]
   [c [cons c [cons b [cons a [nil]]]] 3]])
(dt.same "lists" [[start a] [edge a b] [edge b c] [edge b a] [edge c a]] dt.lists second
  [[a b] [a c] [b a] [c b]])

\* Many records made inside kernels, so that their tables grow while a kernel runs. *\
(defdatalog dt.counting
  (type nat [z] [s nat])
  (relation up [integer nat])
  (relation back [integer integer])
  (rule (up 0 [z]))
  (rule (up N [s P]) <-- (up M P) (= N (+ M 1)) (<= N 3000))
  (rule (back N M) <-- (up N [s [s P]]) (up M P)))
(let Db (datalog.run dt.counting [])
  (do (dt.check "records made while running" (datalog.count Db up) 3001)
      (dt.check "records taken apart" (datalog.count Db back) 2999)
      (dt.check "a deep record" (datalog.holds? Db [back 2 0]) true)))
(let Db (dt.run-kl dt.counting [])
  (dt.check "records made while running, KL" (datalog.count Db back) 2999))

\* Division, remainder and bit operations, natively where a kernel can and in KL where not, and
   string functions and mean, in KL. *\
(defdatalog dt.functions
  (relation n [integer])
  (relation word [string])
  (relation divided [integer integer integer])
  (relation bits [integer integer integer integer integer integer])
  (relation joined [string string string])
  (relation sizes [string integer])
  (relation parts [string string])
  (relation numbers [string integer])
  (relation texts [integer string])
  (relation middle [integer])
  (relation even-big [integer])
  (rule (divided A B Q) <-- (n A) (n B) (!= B 0) (= Q (/ A B)))
  (rule (divided A B R) <-- (n A) (n B) (> B 0) (= R (+ 1000 (% A B))))
  (rule (bits A B C D E F) <-- (n A) (n B) (>= B 0) (<= B 5)
                               (= C (band A B)) (= D (bor A B)) (= E (bxor A (bshl B 2))) (= F (bshr A B)))
  (rule (joined X Y Z) <-- (word X) (word Y) (= Z (cat X (cat "-" Y))))
  (rule (sizes X N) <-- (word X) (= N (strlen X)))
  (rule (parts X P) <-- (word X) (= P (substr X 1 2)))
  (rule (numbers X N) <-- (word X) (= X (to-string N0)) (n N0) (= N (to-number X)))
  (rule (texts N T) <-- (n N) (= T (to-string (* N 2))))
  (rule (middle M) <-- (= M (mean A (n A))))
  (rule (even-big A) <-- (n A) (= 0 (% A 2)) (> (bshl A 1) 4)))

(set dt.functions-facts [[n -7] [n -2] [n 0] [n 3] [n 4] [n 9] [word "ab"] [word "c"] [word "hello"] [word "-2"] [word "9"]])
(dt.same "functions" (value dt.functions-facts) dt.functions divided
  [[-7 -7 1] [-7 -2 3] [-7 3 -2] [-7 3 999] [-7 4 -1] [-7 4 997] [-7 9 0] [-7 9 993] [-2 -7 0] [-2 -2 1]
   [-2 3 0] [-2 3 998] [-2 4 0] [-2 4 998] [-2 9 0] [-2 9 998] [0 -7 0] [0 -2 0] [0 3 0] [0 3 1000] [0 4 0]
   [0 4 1000] [0 9 0] [0 9 1000] [3 -7 0] [3 -2 -1] [3 3 1] [3 3 1000] [3 4 0] [3 4 1003] [3 9 0] [3 9 1003]
   [4 -7 0] [4 -2 -2] [4 3 1] [4 3 1001] [4 4 1] [4 4 1000] [4 9 0] [4 9 1004] [9 -7 -1] [9 -2 -4] [9 3 3]
   [9 3 1000] [9 4 2] [9 4 1001] [9 9 1] [9 9 1000]])
(dt.same "functions" (value dt.functions-facts) dt.functions bits
  [[-7 0 0 -7 -7 -7] [-7 3 1 -5 -11 -1] [-7 4 0 -3 -23 -1]
   [-2 0 0 -2 -2 -2] [-2 3 2 -1 -14 -1] [-2 4 4 -2 -18 -1]
   [0 0 0 0 0 0] [0 3 0 3 12 0] [0 4 0 4 16 0]
   [3 0 0 3 3 3] [3 3 3 3 15 0] [3 4 0 7 19 0]
   [4 0 0 4 4 4] [4 3 0 7 8 0] [4 4 4 4 20 0]
   [9 0 0 9 9 9] [9 3 1 11 5 1] [9 4 0 13 25 0]])
(dt.same "functions" (value dt.functions-facts) dt.functions sizes [["-2" 2] ["9" 1] ["ab" 2] ["c" 1] ["hello" 5]])
(dt.same "functions" (value dt.functions-facts) dt.functions parts [["-2" "2"] ["9" ""] ["ab" "b"] ["c" ""] ["hello" "el"]])
(dt.same "functions" (value dt.functions-facts) dt.functions numbers [["-2" -2] ["9" 9]])
(dt.same "functions" (value dt.functions-facts) dt.functions texts [[-7 "-14"] [-2 "-4"] [0 "0"] [3 "6"] [4 "8"] [9 "18"]])
(dt.same "functions" (value dt.functions-facts) dt.functions middle [[1]])
(dt.same "functions" (value dt.functions-facts) dt.functions even-big [[4]])
(let Db (datalog.run dt.functions (value dt.functions-facts))
  (do (dt.check "strings made while running" (datalog.holds? Db [joined "ab" "hello" "ab-hello"]) true)
      (dt.check "strings made, counted" (datalog.count Db joined) 25)))
(dt.same "a mean of nothing" [[word "x"]] dt.functions middle [])
(defdatalog dt.native-bits
  (relation n [integer])
  (relation masked [integer integer])
  (rule (masked A M) <-- (n A) (= M (bxor (band A 6) (bshl (bor A 1) 2))) (> (bshr M 1) -9)))
(dt.same "native bits" [[n -7] [n -2] [n 0] [n 3] [n 4] [n 9]] dt.native-bits masked [[-2 -6] [0 4] [3 14] [4 16] [9 36]])
(dt.check "bit operations run natively" (datalog.kl-only? (datalog.plan-rule (hd (datalog.nth 4 (datalog.program dt.native-bits))) [])) false)
(defdatalog dt.partial
  (relation n [integer])
  (relation w [string])
  (relation q [integer integer integer])
  (relation num [string integer])
  (relation shifted [integer integer integer integer])
  (rule (q A B C) <-- (n A) (n B) (= C (/ A B)) (!= B 0))
  (rule (q A B C) <-- (n A) (n B) (= C (+ 100 (% A B))) (> (/ 6 B) 0))
  (rule (num S N) <-- (w S) (= N (+ 1 (to-number S))))
  (rule (shifted A B C D) <-- (n A) (n B) (= C (bshl A B)) (= D (bshr A B)))
  (relation unguarded [integer integer integer])
  (rule (unguarded A B C) <-- (n A) (n B) (= C (% A B)))
  (relation g [symbol integer])
  (relation avg [symbol integer])
  (rule (avg K M) <-- (g K _) (= M (mean V (g K V)))))
(dt.same "no value" [[n 0] [n 2] [n -3] [w "12"] [w "1x"] [w ""] [w "-"]] dt.partial q
  [[-3 -3 1] [-3 2 -1] [-3 2 99] [0 -3 0] [0 2 0] [0 2 100] [2 -3 0] [2 2 1] [2 2 100]])
(dt.same "no value" [[n 0] [n 2] [n -3] [w "12"] [w "1x"] [w ""] [w "-"]] dt.partial num [["12" 13]])
(dt.same "no value" [[n 0] [n 2] [n -3] [w "12"] [w "1x"] [w ""] [w "-"]] dt.partial shifted
  [[-3 -3 -1 -24] [-3 0 -3 -3] [-3 2 -12 -1] [0 -3 0 0] [0 0 0 0] [0 2 0 0] [2 -3 0 16] [2 0 2 2] [2 2 8 0]])
(dt.same "no value" [[n 0] [n 2] [n -3]] dt.partial unguarded
  [[-3 -3 0] [-3 2 -1] [0 -3 0] [0 2 0] [2 -3 2] [2 2 0]])
(dt.same "a mean truncates" [[g a 1] [g a 2] [g b -7] [g b -2] [g c 5]] dt.partial avg [[a 1] [b -4] [c 5]])
(dt.raises "a shift too far" "outside 32 bits"
  (freeze (datalog.run (datalog.define dt.bad [[relation a [integer]] [rule [a [var "Y"]] [[a [var "X"]] [= [var "Y"] [bshl 1 [var "X"]]] [< [var "Y"] 0]]]]) [[a 40]])))
(dt.raises "a shift too far, natively" "outside 32 bits"
  (freeze (datalog.run (datalog.define dt.bad [[relation a [integer]] [relation b [integer]] [rule [b [var "Y"]] [[a [var "X"]] [= [var "Y"] [bshl [var "X"] 31]]]]]) [[a 4]])))
(dt.raises "a string function's types" "cat takes"
  (freeze (datalog.define dt.bad [[relation a [string]] [rule [a [var "S"]] [[a [var "T"]] [= [var "S"] [cat [var "T"] 1]]]]])))
(dt.raises "a string function's arity" "strlen takes 1 values, not 2"
  (freeze (datalog.define dt.bad [[relation a [integer]] [relation w [string]] [rule [a [var "N"]] [[w [var "T"]] [= [var "N"] [strlen [var "T"] [var "T"]]]]]])))
(dt.raises "a function as a constructor" "cannot name a constructor"
  (freeze (datalog.define dt.bad [[type t [cat integer]]])))

\* Explanations: each proof is a rule instance whose atoms' tuples are proved in turn, every
   tuple holding in the reference and every condition true, down to the facts given. *\
(define dt.valid?
  Name Facts Ref [T fact] -> (element? T Facts)
  Name Facts Ref [[Rel | Values] lattice] -> (and (cons? (assoc Rel (datalog.nth 9 (datalog.program Name))))
                                                  (element? Values (datalog.tuples Ref Rel)))
  Name Facts Ref [[Rel | Values] equivalence] -> (and (element? Rel (datalog.nth 8 (datalog.program Name)))
                                                      (element? Values (datalog.tuples Ref Rel)))
  Name Facts Ref [[Rel | Values] Form | Subs]
  -> (let Rules (mapcan (/. R (if (= (datalog.rule->form (hd R) (hd (tl R))) Form) [R] []))
                        (datalog.nth 4 (datalog.program Name)))
       (and (cons? Rules)
            (element? Values (datalog.tuples Ref Rel))
            (dt.valid-instance? (hd Rules) Values (map (function hd) Subs) Ref)
            (dt.all-valid? Name Facts Ref Subs))))

(define dt.all-valid?
  _ _ _ [] -> true
  Name Facts Ref [P | Ps] -> (and (dt.valid? Name Facts Ref P) (dt.all-valid? Name Facts Ref Ps)))

(define dt.valid-instance?
  [[Rel | Terms] Body] Values Tuples [naive N Tables]
  -> (let Env (dt.match-atoms (datalog.atoms Body) Tuples (datalog.naive-match Terms Values []))
          Conditions (datalog.conditions Body)
          Bound (if (= Env no) no (datalog.naive-bind Conditions Env Conditions false Tables))
       (and (not (= Bound no)) (datalog.naive-true? Conditions Bound Tables))))

(define dt.match-atoms
  _ _ no -> no
  [] [] Env -> Env
  [[Rel | Terms] | Atoms] [[Rel | Values] | Tuples] Env -> (dt.match-atoms Atoms Tuples (datalog.naive-match Terms Values Env))
  _ _ _ -> no)

\* Every tuple of every relation explained and its proof checked, and a tuple that does not hold
   explained by []. *\
(define dt.explain-all
  Label Name Facts
  -> (let Db (datalog.run Name Facts)
          Ref (datalog.run-naive Name Facts)
          Tuples (mapcan (/. R (map (/. V [(hd R) | V]) (datalog.tuples Db (hd R)))) (datalog.nth 3 (datalog.program Name)))
          Bad (mapcan (/. T (if (dt.valid? Name Facts Ref (datalog.explain Db T)) [] [T])) Tuples)
       (dt.check Label Bad [])))

(dt.explain-all "explained" dt.dep (value dt.dep-facts))
(dt.explain-all "explained" dt.nonlinear [[edge a b] [edge b c] [edge c d] [edge d a] [edge x y]])
(dt.explain-all "explained" dt.mutual [[succ 0 1] [succ 1 2] [succ 2 0]])
(dt.explain-all "explained" dt.mixed (value dt.mixed-facts))
(dt.explain-all "explained" dt.shapes (value dt.shapes-facts))
(dt.explain-all "explained" dt.functions (value dt.functions-facts))
\* A probe of a relation of the rule's own recursion reads only what earlier rounds merged, as scans
   do, so that each tuple comes after all it was derived from: here t's rule probes r, which an
   earlier rule of the same round adds to, in either order of declaration. *\
(defdatalog dt.round-a
  (relation start [symbol]) (relation u [symbol]) (relation t [symbol]) (relation r [symbol])
  (rule (u X) <-- (start X))
  (rule (u X) <-- (t X))
  (rule (r X) <-- (u X))
  (rule (t X) <-- (u X) (r X)))
(defdatalog dt.round-b
  (relation start [symbol]) (relation u [symbol]) (relation r [symbol]) (relation t [symbol])
  (rule (u X) <-- (start X))
  (rule (u X) <-- (t X))
  (rule (r X) <-- (u X))
  (rule (t X) <-- (u X) (r X)))
(dt.explain-all "explained, probing this round" dt.round-a [[start a] [start b]])
(dt.explain-all "explained, probing this round" dt.round-b [[start a] [start b]])
(set datalog.*native* false)
(datalog.forget-code dt.round-a)
(datalog.forget-code dt.round-b)
(dt.explain-all "explained, probing this round, KL" dt.round-a [[start a] [start b]])
(dt.explain-all "explained, probing this round, KL" dt.round-b [[start a] [start b]])
(set datalog.*native* true)
(datalog.forget-code dt.round-a)
(datalog.forget-code dt.round-b)
(let Db (datalog.run dt.dep (value dt.dep-facts))
  (do (dt.check "explained, not holding" (datalog.explain Db [depends d a]) [])
      (dt.check "explained, a fact" (datalog.explain Db [imports a b]) [[imports a b] fact])
      (let Forms (map (/. R (datalog.rule->form (hd R) (hd (tl R)))) (datalog.nth 4 (datalog.program dt.dep)))
        (dt.check "explained, as written" (datalog.explain Db [depends a c])
                  [[depends a c] (hd (tl Forms))
                   [[imports a b] fact]
                   [[depends b c] (hd Forms) [[imports b c] fact]]]))))
(let Db (datalog.add (datalog.run dt.dep [[imports a b]]) [[imports b c]])
  (dt.check "explained after an add" (dt.valid? dt.dep [[imports a b] [imports b c]] (datalog.run-naive dt.dep [[imports a b] [imports b c]])
                                       (datalog.explain Db [depends a c])) true))

\* Fact files: what is written is read back the same, of every type and in both formats, and what
   does not fit its columns is refused, naming the file and line. *\
(defdatalog dt.files
  (type point [pt integer integer] [no-point])
  (relation row [symbol string integer point])
  (relation copy [symbol string integer point])
  (rule (copy A B C D) <-- (row A B C D)))
(set dt.file-facts [[row a "plain" 1 [pt 1 2]] [row b "with, comma" -2147483648 [no-point]]
                    [row c "with c#34;quotesc#34; and c#9;tab" 2147483647 [pt -3 4]] [row d "" 0 [pt 0 0]]])
(let Db (datalog.run dt.files (value dt.file-facts))
  (do (dt.check "a file written" (datalog.write-facts Db copy "build/datalog-facts.csv") 4)
      (dt.check "a file read" (datalog.sort (datalog.read-facts dt.files copy "build/datalog-facts.csv"))
                (datalog.sort (map (/. F [copy | (tl F)]) (value dt.file-facts))))
      (dt.raises "a tab in a tab-separated file" "cannot hold" (freeze (datalog.write-facts Db copy "build/datalog-facts.tsv")))
      (let Plain [(hd (value dt.file-facts)) (hd (tl (value dt.file-facts))) (hd (reverse (value dt.file-facts)))]
        (do (datalog.write-facts (datalog.run dt.files Plain) copy "build/datalog-facts.tsv")
            (dt.check "a tab-separated file read" (datalog.sort (datalog.read-facts dt.files copy "build/datalog-facts.tsv"))
                      (datalog.sort (map (/. F [copy | (tl F)]) Plain)))))))
(define dt.write-file
  Path Text -> (let S (open Path out) (do (pr Text S) (close S) Path)))
(dt.check "lines with returns and gaps" (datalog.read-facts dt.files row (dt.write-file "build/datalog-facts.tsv" "e	x	5	[pt 1 1]c#13;c#10;c#10;f	y	6	[no-point]"))
          [[row e "x" 5 [pt 1 1]] [row f "y" 6 [no-point]]])
(dt.raises "a file's field count" "line 2, has 3 fields"
  (freeze (datalog.read-facts dt.files row (dt.write-file "build/datalog-facts.tsv" "e	x	5	[pt 1 1]c#10;f	y	6"))))
(dt.raises "a file's integer" "line 1: c#34;5xc#34; is not an integer"
  (freeze (datalog.read-facts dt.files row (dt.write-file "build/datalog-facts.tsv" "e	x	5x	[pt 1 1]"))))
(dt.raises "a file's record" "is not of type point"
  (freeze (datalog.read-facts dt.files row (dt.write-file "build/datalog-facts.tsv" "e	x	5	[pt 1]"))))
(dt.raises "a file's relation" "no relation nope" (freeze (datalog.read-facts dt.files nope "build/datalog-facts.tsv")))

\* Relations of one tuple a key: the least or greatest last column, or the first tuple derived, on
   graphs with cycles, where a shortest path needs no bound to end. *\
(defdatalog dt.paths
  (relation edge [integer integer integer])
  (relation start [integer])
  (relation dist [integer integer] min)
  (relation widest [integer integer] max)
  (relation via [integer integer] choice)
  (relation step [integer integer])
  (relation near [integer])
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W)))
  (rule (widest X 1000) <-- (start X))
  (rule (widest Y W) <-- (widest X B0) (edge X Y W) (< W B0))
  (rule (widest Y B0) <-- (widest X B0) (edge X Y W) (>= W B0))
  (rule (step X Y) <-- (edge X Y _))
  (rule (via Y X) <-- (step X Y))
  (rule (near X) <-- (dist X D) (<= D 3)))

(define dt.weighted
  0 _ Acc -> Acc
  M N Acc -> (dt.weighted (- M 1) N [[edge (dtg.random N) (dtg.random N) (dtg.random 10)] | Acc]))
(dt.same "least" [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1] [edge 4 1 1] [edge 3 4 10]] dt.paths dist
  [[1 0] [2 2] [3 1] [4 3]])
(dt.same "greatest" [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1] [edge 4 1 1] [edge 3 4 10]] dt.paths widest
  [[1 1000] [2 5] [3 1] [4 1]])
(dt.same "read by a later stratum" [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1] [edge 4 1 1] [edge 3 4 10]] dt.paths near
  [[1] [2] [3] [4]])

\* On random graphs, against the reference, which keeps the best of each key round by round. *\
(define dt.random-paths
  0 -> ok
  K -> (let Facts [[start (dtg.random 12)] | (dt.weighted 30 12 [])]
            Ref (datalog.run-naive dt.paths Facts)
            _ (map (/. Db (do (dt.check (make-string "random paths ~A dist" K) (datalog.sorted Db dist) (datalog.sorted Ref dist))
                              (dt.check (make-string "random paths ~A widest" K) (datalog.sorted Db widest) (datalog.sorted Ref widest))))
                   [(datalog.run dt.paths Facts) (dt.run-kl dt.paths Facts) (dt.run-added dt.paths Facts) (dt.run-readded dt.paths Facts)])
         (dt.random-paths (- K 1))))
(dt.random-paths 30)
(defdatalog dt.signs
  (relation v [symbol integer])
  (relation low [symbol integer] min)
  (relation high [symbol integer] max)
  (rule (low K X) <-- (v K X))
  (rule (high K X) <-- (v K X)))
(dt.same "least, signed" [[v a 5] [v a -3] [v a 2] [v b -2147483648] [v b 7] [v c 2147483647]] dt.signs low [[a -3] [b -2147483648] [c 2147483647]])
(dt.same "greatest, signed" [[v a 5] [v a -3] [v a 2] [v b -2147483648] [v b 7] [v c 2147483647]] dt.signs high [[a 5] [b 7] [c 2147483647]])

\* choice keeps one tuple of each key, which some rule derives. *\
(let Facts [[start 0] [edge 0 1 1] [edge 2 1 1] [edge 3 1 1] [edge 1 2 1] [edge 0 2 1]]
     Db (datalog.run dt.paths Facts)
     Via (datalog.sorted Db via)
  (do (dt.check "a choice a key" (map (function hd) Via) [1 2])
      (dt.check "a choice derived" (datalog.subset? (map (/. T [(hd (tl T)) (hd T)]) Via) (datalog.tuples Db step)) true)
      (dt.check "a choice explained" (dt.valid? dt.paths Facts (datalog.run-naive dt.paths Facts) (datalog.explain Db [via 1 (hd (tl (hd Via)))])) true)))
(dt.explain-all "explained, least" dt.paths [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1] [edge 4 1 1] [edge 3 4 10]])
\* Lattices: the union of bit sets, for which starts reach each node, and a flat lattice, a value
   or 2147483647 for many, for constant propagation. *\
(define dt.union A B -> (shen-jit.bit-or A B))
(define dt.flat A A -> A _ _ -> 2147483647)
(defdatalog dt.lattices
  (relation edge [integer integer])
  (relation start [integer integer])
  (relation reached-by [integer integer] (lattice dt.union))
  (relation assign [integer integer])
  (relation copy [integer integer])
  (relation const [integer integer] (lattice dt.flat))
  (relation known [integer])
  (rule (reached-by X M) <-- (start X I) (= M (bshl 1 I)))
  (rule (reached-by Y M) <-- (reached-by X M) (edge X Y))
  (rule (const X C) <-- (assign X C))
  (rule (const Y C) <-- (copy X Y) (const X C))
  (rule (known X) <-- (const X C) (!= C 2147483647)))
(set dt.lattice-facts [[start 1 0] [start 4 1] [edge 1 2] [edge 2 3] [edge 4 3] [edge 3 5] [edge 5 3]
                       [assign 10 7] [assign 11 7] [assign 12 8] [copy 10 13] [copy 11 13] [copy 12 14] [copy 13 15] [copy 12 15]])
(dt.same "lattice" (value dt.lattice-facts) dt.lattices reached-by [[1 1] [2 1] [3 3] [4 2] [5 3]])
(dt.same "lattice" (value dt.lattice-facts) dt.lattices const [[10 7] [11 7] [12 8] [13 7] [14 8] [15 2147483647]])
(dt.same "lattice" (value dt.lattice-facts) dt.lattices known [[10] [11] [12] [13] [14]])
(define dt.random-lattice
  0 -> ok
  K -> (let Facts (append [[start (dtg.random 10) 0] [start (dtg.random 10) 1] [start (dtg.random 10) 2]]
                          (map (/. E [edge (hd (tl E)) (hd (tl (tl E)))]) (dt.weighted 18 10 [])))
         (do (dt.same (make-string "random lattice ~A" K) Facts dt.lattices reached-by (datalog.sorted (datalog.run-naive dt.lattices Facts) reached-by))
             (dt.random-lattice (- K 1)))))
(dt.random-lattice 20)

\* The bit operations as lattices, which kernels join: bor for which starts reach a node, and band
   for the tags every way into a node carries. Each plan is a kernel. *\
(defdatalog dt.bits
  (relation edge [integer integer])
  (relation start [integer integer])
  (relation tag [integer integer])
  (relation reached [integer integer] (lattice bor))
  (relation common [integer integer] (lattice band))
  (rule (reached X M) <-- (start X M))
  (rule (reached Y M) <-- (reached X M) (edge X Y))
  (rule (common X M) <-- (tag X M))
  (rule (common Y M) <-- (common X M) (edge X Y)))
(dt.same "bit lattices" [[start 1 1] [start 4 2] [edge 1 2] [edge 2 3] [edge 4 3] [edge 3 5] [edge 5 3]] dt.bits reached
  [[1 1] [2 1] [3 3] [4 2] [5 3]])
(dt.same "bit lattices" [[tag 1 7] [tag 4 5] [tag 3 12] [edge 1 2] [edge 2 3] [edge 4 3] [edge 3 5] [edge 5 3]] dt.bits common
  [[1 7] [2 7] [3 4] [4 5] [5 4]])
(define dt.random-bits
  0 -> ok
  K -> (let Edges (map (/. E [edge (hd (tl E)) (hd (tl (tl E)))]) (dt.weighted 18 10 []))
            Facts (append [[start (dtg.random 10) 1] [start (dtg.random 10) 4] [tag (dtg.random 10) 13] [tag (dtg.random 10) 7] [tag (dtg.random 10) 2147483647]] Edges)
            Ref (datalog.run-naive dt.bits Facts)
         (do (dt.same (make-string "random bits ~A" K) Facts dt.bits reached (datalog.sorted Ref reached))
             (dt.same (make-string "random bits ~A" K) Facts dt.bits common (datalog.sorted Ref common))
             (dt.random-bits (- K 1)))))
(dt.random-bits 20)
(dt.check "bit lattices are kernels"
  (length (mapcan (/. F (if (= (hd F) define-native) [F] [])) (datalog.code dt.bits)))
  (length (datalog.all-steps (datalog.plans dt.bits))))
(dt.explain-all "explained, lattice" dt.lattices (value dt.lattice-facts))
(dt.raises "a lattice of symbols" "must be an integer"
  (freeze (datalog.define dt.bad [[relation a [integer symbol] [lattice dt.union]]])))
(dt.raises "a least of symbols" "must be an integer"
  (freeze (datalog.define dt.bad [[relation a [integer symbol] min]])))
(dt.raises "a key with no value" "two columns or more"
  (freeze (datalog.define dt.bad [[relation a [integer] choice]])))
(dt.raises "an unknown way to keep" "neither equivalence, min, max, choice nor (lattice F)"
  (freeze (datalog.define dt.bad [[relation a [integer integer] best]])))

\* Queries by demand give what a whole run would, and compute less. *\
(define dt.query
  Label Name Facts Pattern
  -> (dt.check (make-string "~A ~R" Label (datalog.atom->form Pattern))
       (datalog.sort (datalog.solve Name Facts Pattern))
       (datalog.sort (datalog.match (datalog.run-naive Name Facts) Pattern))))

(dt.query "demand" dt.dep (value dt.dep-facts) [depends a [var "X"]])
(dt.query "demand" dt.dep (value dt.dep-facts) [depends [var "X"] d])
(dt.query "demand" dt.dep (value dt.dep-facts) [depends x x])
(dt.query "demand" dt.dep (value dt.dep-facts) [depends [var "X"] [var "X"]])
(dt.query "demand" dt.dep (value dt.dep-facts) [cyclic [var "X"]])
(dt.query "demand" dt.dep (value dt.dep-facts) [imports b [any]])
(dt.query "demand" dt.dep (value dt.dep-facts) [depends nowhere [var "X"]])
(dt.query "demand" dt.nonlinear [[edge a b] [edge b c] [edge c d] [edge d a] [edge x y]] [path b [var "X"]])
(dt.query "demand" dt.mutual [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] [odd [var "X"]])
(dt.query "demand" dt.mutual [[succ 0 1] [succ 1 2] [succ 2 0]] [both 1])
(map (/. R (dt.query "demand" dt.mixed (value dt.mixed-facts) [R | (map (/. T [any]) (tl (assoc R (datalog.nth 3 (datalog.program dt.mixed)))))]))
     [big self linked pair named fixed seeded])
(dt.query "demand" dt.mixed (value dt.mixed-facts) [fixed b [var "N"]])
(dt.query "demand" dt.mixed (value dt.mixed-facts) [pair c [var "Y"]])
(dt.query "demand" dt.shapes (value dt.shapes-facts) [unit [var "S"] [rect [pt 1 2] [pt 2 3]]])
(dt.query "demand" dt.shapes (value dt.shapes-facts) [near b [var "T"]])
(dt.query "demand" dt.shapes (value dt.shapes-facts) [lonely [var "S"]])
(dt.query "demand" dt.lists [[start a] [edge a b] [edge b c] [edge b a] [edge c a]] [route c [var "P"] [var "N"]])
(let Db (datalog.run dt.dep (value dt.dep-facts))
  (dt.check "a query as written" (datalog.sort (datalog.query dt.dep (value dt.dep-facts) (depends a X)))
            (datalog.sort (datalog.ask Db (depends a X)))))

\* Equivalences: closed as they grow, from facts, from rules, and through a rule that reads one, as
   congruence closure does: if X and Y are the same, so are what f gives for each. *\
(defdatalog dt.equal
  (relation same [symbol symbol] equivalence)
  (relation link [symbol symbol])
  (relation f [symbol symbol])
  (relation big [symbol])
  (relation near-big [symbol])
  (relation classes [symbol integer])
  (rule (same X Y) <-- (link X Y))
  (rule (same A B) <-- (same X Y) (f X A) (f Y B))
  (rule (near-big X) <-- (same X Y) (big Y) (!= X Y))
  (rule (classes X N) <-- (same X _) (= N (count (same X _)))))
(set dt.equal-facts [[same a b] [link b c] [link x y] [f a p] [f c q] [f x r] [f s t] [same q u] [big c] [big r]])
(dt.same "equivalence" (value dt.equal-facts) dt.equal same
  [[a a] [a b] [a c] [b a] [b b] [b c] [c a] [c b] [c c]
   [p p] [p q] [p u] [q p] [q q] [q u] [r r] [u p] [u q] [u u] [x x] [x y] [y x] [y y]])
(dt.same "equivalence" (value dt.equal-facts) dt.equal near-big [[a] [b]])
(dt.same "equivalence" (value dt.equal-facts) dt.equal classes [[a 3] [b 3] [c 3] [p 3] [q 3] [r 1] [u 3] [x 2] [y 2]])
(dt.query "demand" dt.equal (value dt.equal-facts) [same a [var "X"]])
(dt.query "demand" dt.paths [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1]] [dist 4 [var "D"]])
(dt.query "demand" dt.paths [[start 1] [edge 1 2 5] [edge 1 3 1] [edge 3 2 1] [edge 2 4 1]] [near [var "X"]])
(dt.query "demand" dt.lattices (value dt.lattice-facts) [known [var "X"]])
(dt.query "demand" dt.equal (value dt.equal-facts) [near-big [var "X"]])
(dt.query "demand" dt.equal (value dt.equal-facts) [classes [var "X"] 2])
(let Db (datalog.run dt.equal [[same a b] [same c d]])
     _ (dt.check "equivalence, classes apart" (datalog.count Db same) 8)
     Added (datalog.add Db [[link b c]])
     _ (dt.check "equivalence, joined by an add" (datalog.count Added same) 16)
  (dt.check "equivalence, after a removal" (datalog.count (datalog.remove Added [[link b c]]) same) 8))
(let Db (datalog.run dt.equal (map (/. I [link a (intern (cn "n" (str I)))]) (datalog.upto 1 300)))
  (dt.check "a large class" (datalog.count Db same) 90601))
(dt.explain-all "explained" dt.equal (value dt.equal-facts))

\* An equivalence whose classes change early, one in the round after the other, in a component that
   goes on growing: h and k read its old pairs, by a scan and by a member check, beside l, which
   reaches 10 several rounds later. never has no tuples, and only keeps h and k in the component. *\
(defdatalog dt.late-eq
  (relation step [integer integer])
  (relation start [integer])
  (relation link [integer integer])
  (relation pairup [integer integer])
  (relation cand [integer integer])
  (relation never [integer])
  (relation same [integer integer] equivalence)
  (relation l [integer])
  (relation h [integer integer])
  (relation lp [integer integer])
  (relation k [integer integer])
  (rule (l X) <-- (start X))
  (rule (l Y) <-- (l X) (step X Y))
  (rule (same X Y) <-- (link X Y))
  (rule (same X Y) <-- (l X) (pairup X Y))
  (rule (h X Y) <-- (same X Y) (l X))
  (rule (lp X Y) <-- (l X) (l Y) (cand X Y))
  (rule (k X Y) <-- (same X Y) (lp X Y))
  (rule (l Y) <-- (h X Y) (never Y))
  (rule (l Y) <-- (k X Y) (never Y)))
(set dt.late-eq-facts (append (map (/. I [step I (+ I 1)]) (datalog.upto 0 11))
                              [[start 0] [link 10 20] [pairup 2 10] [link 30 40] [pairup 3 30]
                               [cand 10 2] [cand 2 10]]))
(dt.same "an equivalence read late" (value dt.late-eq-facts) dt.late-eq h
  [[2 2] [2 10] [2 20] [3 3] [3 30] [3 40] [10 2] [10 10] [10 20]])
(dt.same "an equivalence read late" (value dt.late-eq-facts) dt.late-eq k [[2 10] [10 2]])
(dt.raises "an equivalence of two types" "two of one type"
  (freeze (datalog.define dt.bad [[relation e [symbol integer] equivalence]])))
(dt.raises "an equivalence of three columns" "two of one type"
  (freeze (datalog.define dt.bad [[relation e [symbol symbol symbol] equivalence]])))

\* Negation and an aggregate read complete relations, beside the copies a query makes. *\
(defdatalog dt.graph
  (relation edge [integer integer])
  (relation node [integer])
  (relation reach [integer integer])
  (relation sink [integer])
  (relation far [integer integer])
  (relation degree [integer integer])
  (rule (reach X Y) <-- (edge X Y))
  (rule (reach X Z) <-- (reach X Y) (edge Y Z))
  (rule (sink X) <-- (node X) (not (edge X _)))
  (rule (far X Y) <-- (reach X Y) (sink Y) (not (reach Y X)))
  (rule (degree X N) <-- (reach X _) (= N (count (reach X _))))
  (relation out [integer])
  (relation lone [integer])
  (rule (out X) <-- (reach X _))
  (rule (lone X) <-- (node X) (not (out X))))
(define dt.chain-int
  N N Acc -> Acc
  I N Acc -> (dt.chain-int (+ I 1) N [[edge I (+ I 1)] [node I] | Acc]))
(set dt.graph-facts (append (dt.chain-int 0 25 []) [[edge 70 71] [edge 71 70] [edge 5 70] [node 25] [node 71] [node 3]]))
(dt.query "demand" dt.graph (value dt.graph-facts) [reach 20 [var "Y"]])
(dt.query "demand" dt.graph (value dt.graph-facts) [far 15 [var "Y"]])
(dt.query "demand" dt.graph (value dt.graph-facts) [far [var "X"] 25])
(dt.query "demand" dt.graph (value dt.graph-facts) [degree 23 [var "N"]])
(dt.query "demand" dt.graph (value dt.graph-facts) [degree [var "X"] 3])
(dt.query "demand" dt.graph (value dt.graph-facts) [lone [var "X"]])
(let D (datalog.demand dt.graph reach [b f])
     Db (datalog.run D [[magic@reach@bf 20] | (value dt.graph-facts)])
  (do (dt.check "demand computes less" (datalog.count Db reach@bf) 5)
      (dt.check "demand leaves the rest" (datalog.count Db reach) 0)))
(dt.check "a rewritten program is kept" (datalog.demand dt.graph reach [b f]) (datalog.demand dt.graph reach [b f]))
(dt.raises "a query of no relation" "no relation nope" (freeze (datalog.solve dt.dep [] [nope a])))
(dt.raises "a query's arity" "takes 2 values, not 1" (freeze (datalog.solve dt.dep [] [depends a])))

\* Errors, each when the program is defined. *\
(dt.raises "undeclared" "no relation nope"
  (freeze (datalog.define dt.bad [[rule [nope a] []]])))
(dt.raises "undeclared in a body" "no relation nope"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[nope [var "X"]]]]])))
(dt.raises "arity" "takes 1 values, not 2"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a b c] []]])))
(dt.raises "unbound head" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [relation b [symbol]] [rule [b [var "Y"]] [[a [var "X"]]]]])))
(dt.raises "unbound comparison" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation a [integer]] [rule [a [var "X"]] [[a [var "X"]] [< [var "X"] [var "Y"]]]]])))
(dt.raises "_ in a head" "cannot hold _"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [any]] [[a [var "X"]]]]])))
(dt.raises "_ compared" "cannot be compared"
  (freeze (datalog.define dt.bad [[relation a [integer]] [rule [a [var "X"]] [[a [var "X"]] [< [any] 1]]]])))
(dt.raises "a variable of two types" "X is both"
  (freeze (datalog.define dt.bad [[relation a [integer]] [relation b [symbol]] [rule [a [var "X"]] [[a [var "X"]] [b [var "X"]]]]])))
(dt.raises "a constant of the wrong type" "is not of type symbol"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a 1] []]])))
(dt.raises "ordering symbols" "orders integers"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[a [var "X"]] [< [var "X"] b]]]])))
(dt.raises "comparing two types" "are compared"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[a [var "X"]] [= [var "X"] 1]]]])))
(dt.raises "declared twice" "declared twice"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [relation a [symbol]]])))
(dt.raises "an unknown column type" "not a list of"
  (freeze (datalog.define dt.bad [[relation a [real]]])))
(dt.raises "an operator as a name" "cannot name"
  (freeze (datalog.define dt.bad [[relation < [symbol]]])))
(dt.raises "not an item" "neither"
  (freeze (datalog.define dt.bad [[other]])))
(dt.raises "a fact's relation" "has no relation"
  (freeze (datalog.run dt.dep [[nope a]])))
(dt.raises "a fact's arity" "should have 2 values"
  (freeze (datalog.run dt.dep [[imports a]])))
(dt.raises "a fact's type" "in a column of type symbol"
  (freeze (datalog.run dt.dep [[imports a 1]])))
(dt.raises "a fact's real" "in a column of type integer"
  (freeze (datalog.run dt.reach [[edge 1 (+ 0.5 0.5)]])))
(dt.raises "no such program" "no program"
  (freeze (datalog.run dt.nope [])))
(dt.raises "an unknown constructor" "is not a value"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [rule [a [j 1]] []]])))
(dt.raises "a constructor's arity" "takes 1 values, not 2"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [rule [a [k 1 2]] []]])))
(dt.raises "a record of another type" "is not of type"
  (freeze (datalog.define dt.bad [[type t [k integer]] [type u [j integer]] [relation a [t]] [rule [a [j 1]] []]])))
(dt.raises "a record in a column of integers" "is not of type"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [integer]] [rule [a [k 1]] []]])))
(dt.raises "a record's field" "is not of type"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [rule [a [k b]] []]])))
(dt.raises "_ in a head's record" "cannot hold _"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [rule [a [k [any]]] [[a [var "X"]]]]])))
(dt.raises "_ in a negated record" "cannot hold _"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [relation b [integer]]
                                  [rule [b [var "N"]] [[b [var "N"]] [not [a [k [any]]]]]]])))
(dt.raises "a constructor declared twice" "declared twice"
  (freeze (datalog.define dt.bad [[type t [k integer]] [type u [k symbol]]])))
(dt.raises "a type declared twice" "declared twice"
  (freeze (datalog.define dt.bad [[type t [k integer]] [type t [j symbol]]])))
(dt.raises "a reserved constructor" "cannot name a constructor"
  (freeze (datalog.define dt.bad [[type t [+ integer integer]]])))
(dt.raises "a base type redeclared" "cannot name a type"
  (freeze (datalog.define dt.bad [[type integer [k integer]]])))
(dt.raises "an unknown field type" "not a list of"
  (freeze (datalog.define dt.bad [[type t [k real]]])))
(dt.raises "ordering records" "orders integers"
  (freeze (datalog.define dt.bad [[type t [k integer]] [relation a [t]] [rule [a [var "X"]] [[a [var "X"]] [< [var "X"] [k 1]]]]])))
(dt.raises "a fact's record" "in a column of type t"
  (freeze (datalog.run (datalog.define dt.bad [[type t [k integer]] [relation a [t]]]) [[a [k b]]])))
(dt.raises "a fact's constructor" "in a column of type t"
  (freeze (datalog.run (datalog.define dt.bad [[type t [k integer]] [type u [j integer]] [relation a [t]]]) [[a [j 1]]])))

\* ---- Generated programs (tests/datalog-generate.shen) against the plain definition. *\

(define dt.compare-relation
  _ _ _ [] -> ok
  Seed Db Reference [[Rel | _] | Rs]
  -> (do (dt.check (make-string "generated ~A ~A" Seed Rel) (datalog.sorted Db Rel) (datalog.sorted Reference Rel))
         (dt.compare-relation Seed Db Reference Rs)))

(define dt.compare-all
  _ [] _ _ -> ok
  Seed [Db | Dbs] Reference Relations
  -> (do (dt.compare-relation Seed Db Reference Relations)
         (dt.compare-all Seed Dbs Reference Relations)))

\* A query's term: a constant, a variable, which may repeat, or _. A query of each generated program
   runs with KL joins, which compile faster than kernels: what it tests is the rewriting. *\
(define dt.query-term
  Type -> (let R (dtg.random 6)
            (cases (< R 3) (dtg.value Type)
                   (< R 5) [var (dtg.choose ["X" "Y"])]
                   true [any])))

(define dt.generated
  0 -> ok
  N -> (let Program (dtg.program)
            Relations (hd Program)
            Rules (hd (tl Program))
            Facts (hd (tl (tl Program)))
            Name (dtg.numbered "dt.g" N)
            _ (datalog.define Name (dtg.items Relations Rules))
            Reference (datalog.run-naive Name Facts)
            Db (datalog.run Name Facts)
            Fixed (dt.run-fixed Name Facts)
            Kl (dt.run-kl Name Facts)
            Added (dt.run-added Name Facts)
            Readded (dt.run-readded Name Facts)
            Removed (datalog.remove (datalog.run Name Facts) (dt.middle Facts))
            Left (datalog.run-naive Name (dt.facts-without Facts (dt.middle Facts)))
            _ (dt.compare-relation N Removed Left Relations)
            Name2 (dtg.numbered "dt.h" N)
            _ (datalog.define Name2 (append (dtg.items (dtg.shuffle Relations) [])
                                            (dtg.rule-items (dtg.shuffle (dtg.shuffle-bodies Rules)))))
            Shuffled (datalog.run Name2 (dtg.shuffle Facts))
            Rel (dtg.choose Relations)
            Pattern [(hd Rel) | (dtg.map (function dt.query-term) (tl Rel))]
            _ (set datalog.*native* false)
            _ (dt.check (make-string "generated ~A query ~R" N (datalog.atom->form Pattern))
                (datalog.sort (datalog.solve Name Facts Pattern)) (datalog.sort (datalog.match Reference Pattern)))
            _ (set datalog.*native* true)
            _ (dt.compare-all N [Fixed Db Kl Added Readded] Reference Relations)
            _ (dt.compare-relation N Shuffled Reference Relations)
            Unproved (mapcan (/. R (mapcan (/. V (if (dt.valid? Name Facts Reference (datalog.explain Db [(hd R) | V])) [] [[(hd R) | V]]))
                                           (dt.take 4 (datalog.tuples Db (hd R)))))
                             Relations)
            _ (dt.check (make-string "generated ~A explained" N) Unproved [])
         (dt.generated (- N 1))))

(dt.generated 300)

(output "~A checks, ~A failed~%" (value dt.*checks*) (value dt.*failures*))
(if (= 0 (value dt.*failures*)) true (shen-jit.exit 1))

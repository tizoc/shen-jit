\* The port's overrides against the kernel's own definitions.

   Each function that src/port/shen-jit.kl replaces is also loaded as the kernel defines it, from the
   kernel's KLambda, under the name k.F, and both run over the same generated values. They must agree
   exactly: 1 and 1.0 differ, and so do a value and an error, though not the text of two errors. The
   override also runs under a handler that ignores the error, which it may treat differently.

   A k.F calls the port's definitions of everything else, so a difference belongs to F. The exceptions
   are groups whose data the port represents in its own way, Prolog variables and dictionaries,
   which are loaded whole, so that each side runs on its own representation.

   What differs on purpose is listed in o.known, with its reason; a listed difference that no longer
   shows fails too, and so does an override that is neither tested here nor listed in o.left-out.
   Usage: overrides.shen KERNEL_DIR PORT_FILE WORK_DIR, with its standard input empty, as the kernel's
   shen.f-error asks a question. *\

(set o.*failures* 0)
(set o.*checks* 0)
(set o.*known* [])

(define o.fail
  Text -> (do (set o.*failures* (+ 1 (value o.*failures*)))
              (if (< (value o.*failures*) 200)
                  (output "FAIL ~A~%" Text)
                  skip)))

(define o.check
  -> (set o.*checks* (+ 1 (value o.*checks*))))

\\ ---------------------------------------------------------------------------
\\ The kernel's definitions

(define o.read-kl
  File -> (compile (/. X (shen.<s-exprs> X)) (read-file-as-bytelist File)))

(set o.*kernel* (shen.dict 4096))

(define o.defuns
  File -> (o.filter (/. Form (and (cons? Form) (= (hd Form) defun))) (o.read-kl File)))

(define o.read-kernel
  Dir -> (o.for-each
           (/. File (o.for-each
                      (/. Form (shen.dict-> (value o.*kernel*) (hd (tl Form)) Form))
                      (o.defuns (cn Dir (cn "/klambda/" (cn File ".kl"))))))
           ["core" "dict" "prolog" "macros" "reader" "sys" "writer" "yacc" "toplevel" "extension-launcher" "extension-namespaces"]))

(define o.for-each
  _ [] -> done
  F [X | Xs] -> (do (F X) (o.for-each F Xs)))

(define o.kname
  F -> (concat k. F))

(define o.rename
  Names [X | Y] -> [(o.rename Names X) | (o.rename Names Y)]
  Names X -> (if (element? X Names) (o.kname X) X))

\\ Names, as the kernel defines them, calling each other. Everything else they call is the port's. A
\\ file is read whole before any of it runs, when k.F is not yet defined, so Shen code calls one through
\\ (o.k F), and the port's beside it through (o.p F).
(set o.*closures* [])

(define o.load
  Names -> (o.for-each (/. F (o.load-one Names F (shen.<-dict (value o.*kernel*) F))) Names))

(define o.load-one
  Names F [defun Name Ps Body]
  -> (do (eval-kl (o.rename Names [defun Name Ps Body]))
         (set o.*closures* [[(o.kname F) | (eval-kl (o.wrap Ps [(o.kname F) | Ps]))]
                            [F | (eval-kl (o.wrap Ps [F | Ps]))]
                            | (value o.*closures*)])))

(define o.k
  F -> (tl (assoc (o.kname F) (value o.*closures*))))

(define o.p
  F -> (tl (assoc F (value o.*closures*))))

\\ ---------------------------------------------------------------------------
\\ Showing a result exactly. A Prolog variable shows the same whichever way it is represented, and so
\\ does a dictionary. Depth only guards against a mistake: no term here holds itself.

(define o.real-bits
  R -> (let B (shen-jit.f64! (shen-jit.bytes 8) 0 R)
         (cn "r" (cn (str (shen-jit.u32 B 4)) (cn ":" (str (shen-jit.u32 B 0)))))))

(define o.fixnum?
  V -> (and (number? V) (shen-jit.same? V (+ V 0))))

(define o.kernel-pvar?
  V -> (and (absvector? V) (= (trap-error (<-address V 0) (/. E none)) shen.pvar)))

(define o.show
  V -> (o.show-to V 2000))

(define o.show-to
  V 0 -> "..."
  V _ -> (cn "i" (str V)) where (o.fixnum? V)
  V _ -> (o.real-bits V) where (number? V)
  V _ -> (cn "s" (make-string "~S" V)) where (string? V)
  V D -> (cn "(" (cn (o.show-to (hd V) (- D 1)) (cn " . " (cn (o.show-to (tl V) (- D 1)) ")")))) where (cons? V)
  V _ -> (cn "?" (str (shen-jit.pvar-offset V))) where (shen-jit.pvar? V)
  V _ -> (cn "?" (str (<-address V 1))) where (o.kernel-pvar? V)
  V _ -> "#dict" where (shen.dict? V)
  V _ -> (cn "#" (o.show-bytes V 0)) where (shen-jit.bytes? V)
  V D -> (cn "[" (o.show-vector V 0 D)) where (absvector? V)
  V _ -> (str V))

(define o.show-bytes
  B I -> "" where (>= I (shen-jit.bytes-length B))
  B I -> (cn (str (shen-jit.u8 B I)) (cn " " (o.show-bytes B (+ I 1)))))

(define o.show-vector
  V 8 _ -> "...]"
  V I D -> (let E (trap-error [(<-address V I)] (/. Ignored []))
             (if (= E [])
                 "]"
                 (cn (o.show-to (hd E) (- D 1)) (cn " " (o.show-vector V (+ I 1) D))))))

(define o.apply
  F [] -> (thaw F)
  F [A] -> (F A)
  F [A B] -> (F A B)
  F [A B C] -> (F A B C)
  F [A B C D] -> (F A B C D))

\\ A call's outcome: "= " and the value, or "!" for an error.
(define o.outcome
  Post F Args -> (let _ (set o.*last* none)
                   (trap-error (cn "= " (o.show (Post (set o.*last* (o.apply F Args))))) (/. E (o.raised E)))))

\\ A handler that uses the error, as one that ignores it is the case that o.case runs apart.
(define o.raised
  E -> (do (error-to-string E) "!"))

\\ ---------------------------------------------------------------------------
\\ Differences on purpose. Each clause names a call and both outcomes, as narrowly as it can, and
\\ gives its reason. Anything else that differs fails.

(define o.known
  integer? [N] "!" "= true" -> "integer?: the kernel's doubles a fixnum up to the number, and overflows on 2^60 or more"
    where (element? N [n1152921504606846976 n2305843009213693951 n-2305843009213693952 r61 r62 big])
  integer? [N] "!" "= false" -> "integer?: the kernel's doubles a fixnum up to the number, and overflows on an infinity or NaN"
    where (element? N [inf -inf nan])
  symbol? [N] "= true" "= false" -> "symbol?: the kernel's expects str to fail on what is not an atom, but here it describes it"
    where (element? N [v0 v1 v3 tuple tag-only neg str-tag nan-tag closure frozen fn err stream b0 b8 bs absvar pvar0 pvar3])
  variable? [N] "= true" "= false" -> "variable?: a Prolog variable prints as Var and its offset, which reads as a name"
    where (element? N [pvar0 pvar3])
  shen.misc? [r35h] "= false" "= true" -> "shen.misc?: takes bytes; the port's ranges also hold what lies between two bytes"
  read-file [_] _ _ -> "read-file: the port's skips a first line that starts with #!, so that a script can run"
    where (o.shebang-file? (hd (value o.*case-values*)))
  hash [X Bound] _ "!" -> "hash: the port's takes a fixnum for a bound, as every caller gives; the kernel's works with reals too"
    where (element? Bound [half one-half r1 r8])
  hash [tag-only _] "!" "in range" -> "hash: the kernel's hashes what prints, and a tuple with no elements cannot print"
  shen.dict [N] "!" "= #dict" -> "shen.dict: the port's starts with 8 buckets, whatever size is asked for, where the kernel's makes them all"
    where (element? N [n2147483647 n2147483648 n4294967296 n9007199254740992 n9007199254740993 n1152921504606846976 n2305843009213693951
                       one-half r1 r2 r8 r33 r35h r48 r53 r61 r62 big inf nan])
  shen.compute-integer _ "!" _ -> "shen.compute-integer: past the fixnum range a literal becomes the nearest real, where the kernel's overflows"
    where (o.literal? (value o.*port-value*) (o.real-digits (hd (value o.*case-values*)) (- 0.5 0.5)))
  shen.compute-integer _ "!" "= r0:0" -> "shen.compute-integer: the reader gives only digits, and what the port's cannot add reads as the decimal 0"
    where (= none (o.real-digits (hd (value o.*case-values*)) 0))
  shen.compute-fraction-h _ _ _ -> "shen.compute-fraction-h: a zero digit adds an exact 0, so that 8.0 reads as the integer 8"
    where (o.exact-for-real?)
  shen.compute-E [_ _] "!" _ -> "shen.compute-E: past the fixnum range a literal becomes the nearest real, where the kernel's overflows"
    where (let Args (value o.*case-values*)
            (o.literal? (value o.*port-value*) (o.real-power (hd Args) (hd (tl Args)))))
  shen.compute-E _ "!" "= r0:0" -> "shen.compute-E: the reader gives only numbers, and what the port's cannot multiply reads as the decimal 0"
    where (not (number? (hd (value o.*case-values*))))
  shen.make-prolog-variable [N] _ "!" -> "shen.make-prolog-variable: the port's holds an offset, which is what the kernel always gives it, and the kernel's holds anything"
    where (not (o.offset? (hd (value o.*case-values*))))
  shen.bindv [tuple _] _ "!" -> "shen.bindv: the kernel's takes the offset from any absvector, and the port's only from a variable"
  shen.unwind [tuple _] _ "!" -> "shen.unwind: the kernel's takes the offset from any absvector, and the port's only from a variable"
  shen.record-kl [Before false] _ _ -> "shen.record-kl: the port's takes a name with no shen.source for a new one, and only removing that property by hand makes one that is listed"
    where (element? o.rec Before)
  _ _ _ _ -> false)

(define o.known-clauses
  -> 18)

(define o.offset?
  N -> (and (o.fixnum? N) (>= N 0) (< N 72057594037927936)))

\\ The same number, one exact and the other a real.
(define o.exact-for-real?
  -> (let K (value o.*kernel-value*)
          P (value o.*port-value*)
       (and (number? K) (number? P) (= K P) (o.fixnum? P) (not (o.fixnum? K)))))

\\ What a literal should read as, within rounding.
(define o.literal?
  P Want -> (and (number? P) (number? Want) (not (o.fixnum? P))
                 (or (= P Want) (< (o.abs (- P Want)) (* (o.abs Want) 0.000001)))))

(define o.abs
  X -> (if (< X 0) (- 0 X) X))

(define o.real-digits
  [] N -> N
  [D | Ds] N -> (o.real-digits Ds (+ (* N 10) D)) where (and (integer? D) (>= D 0) (<= D 9))
  _ _ -> none)

(define o.real-power
  M E -> none where (not (and (number? M) (integer? E)))
  0 _ -> 0
  M E -> (* M (o.real-expt E)))

(define o.real-expt
  0 -> (+ 0.5 0.5)
  E -> (* 10 (o.real-expt (- E 1))) where (> E 0)
  E -> (/ (o.real-expt (+ E 1)) 10))

(define o.note-known
  Reason -> (let Entry (assoc Reason (value o.*known*))
              (if (empty? Entry)
                  (set o.*known* [[Reason | 1] | (value o.*known*)])
                  (set o.*known* (map (/. E (if (= (hd E) Reason) [Reason | (+ 1 (tl E))] E)) (value o.*known*))))))

(define o.differs
  P Names K Got
  -> (let Reason (o.known P Names K Got)
       (if (= Reason false)
           (o.fail (make-string "(~A ~A): kernel ~A, port ~A" P (o.join Names) K Got))
           (o.note-known Reason))))

(define o.join
  [] -> ""
  [X] -> (make-string "~S" X)
  [X | Xs] -> (make-string "~S ~A" X (o.join Xs)))

\\ ---------------------------------------------------------------------------
\\ Running a function over cases. A case is a list of values, each [Name Frozen], made afresh for each
\\ call, so that what a call stores into one does not reach the next.

(define o.wrap
  [] Body -> [freeze Body]
  Ps Body -> (o.wrap-h Ps Body))

(define o.wrap-h
  [] Body -> Body
  [P | Ps] Body -> [lambda P (o.wrap-h Ps Body)])

(define o.params
  0 -> []
  1 -> [a]
  2 -> [a b]
  3 -> [a b c]
  4 -> [a b c d])

(define o.make
  V -> (thaw (hd (tl V))))

(define o.v
  X -> [(o.show X) (freeze X)])

(define o.run
  P N Cases -> (o.run-post P N (/. X X) Cases))

(define o.run-post
  P N Post Cases
  -> (let Ps (o.params N)
          Kernel (eval-kl (o.wrap Ps [(o.kname P) | Ps]))
          Plain (eval-kl (o.wrap Ps [P | Ps]))
          Quiet (eval-kl (o.wrap Ps [trap-error [P | Ps] [lambda e o.caught]]))
       (do (set o.*raised* 0)
           (o.for-each (/. Case (o.case P Post Kernel Plain Quiet Case)) Cases)
           (output "~A: ~A cases, ~A raise~%" P (length Cases) (value o.*raised*)))))

(define o.case
  P Post Kernel Plain Quiet Vs
  -> (let Names (map (/. V (hd V)) Vs)
          _ (set o.*case-values* (map (/. V (o.make V)) Vs))
          K (o.outcome Post Kernel (map (/. V (o.make V)) Vs))
          _ (set o.*kernel-value* (value o.*last*))
          Got (o.outcome Post Plain (map (/. V (o.make V)) Vs))
          _ (set o.*port-value* (value o.*last*))
          ByQuiet (o.outcome Post Quiet (map (/. V (o.make V)) Vs))
       (do (o.check)
           (if (= K "!") (set o.*raised* (+ 1 (value o.*raised*))) skip)
           (if (= K Got) skip (o.differs P Names K Got))
           (if (= ByQuiet (if (= Got "!") "= o.caught" Got))
               skip
               (o.fail (make-string "(~A ~A): under a handler ~A, by name ~A" P (o.join Names) ByQuiet Got))))))

\\ One function of two values, or of one, over all of them.
(define o.cases1
  Xs -> (map (/. X [X]) Xs))

(define o.cases2
  Xs Ys -> (o.flatmap (/. X (map (/. Y [X Y]) Ys)) Xs))

(define o.cases3
  Xs Ys Zs -> (o.flatmap (/. X (o.flatmap (/. Y (map (/. Z [X Y Z]) Zs)) Ys)) Xs))

(define o.flatmap
  _ [] -> []
  F [X | Xs] -> (append (F X) (o.flatmap F Xs)))

\\ ---------------------------------------------------------------------------
\\ Values, from tests/differential.shen. The readers turn 8.0 into the integer 8, so reals are computed.

(define o.pow
  _ 0 -> 1
  B N -> (* B (o.pow B (- N 1))))

(define o.integers
  -> (let P53 (o.pow 2 53)
          Max (+ (o.pow 2 60) (- (o.pow 2 60) 1))
          Min (- (- 0 Max) 1)
       [0 1 -1 2 -2 3 7 8 15 16 63 64 -64 255 256 65536
        2147483647 2147483648 -2147483649 4294967296
        P53 (+ P53 1) (- 0 P53) (o.pow 2 60) Max Min]))

(define o.real-forms
  -> (let One [+ 0.5 0.5]
          Big [* One 1.0e200]
       [[half 0.5] [-half -0.5] [one-half 1.5] [tenth 0.1]
        [r0 [- 0.5 0.5]] [r-0 [* -1 [- 0.5 0.5]]] [r1 One] [r-1 [- -0.5 0.5]] [r2 [+ 0.5 1.5]] [r8 [* 8 One]]
        [r33 [* 33 One]] [r35h [+ 35 0.5]] [r48 [* 48 One]] [r53 [* 18014398509481984 0.5]]
        [r61 [* 2305843009213693951 One]] [r62 [* 2 [* 2305843009213693951 One]]] [big [* One 1.0e300]]
        [small [* One 1.0e-300]] [inf [* Big Big]] [-inf [* -1 [* Big Big]]] [nan [- [* Big Big] [* Big Big]]]]))

(define o.value-forms
  -> (append
       (map (/. N [(intern (make-string "n~A" N)) N]) (o.integers))
       (o.real-forms)
       [[empty ""] [a "a"] [abc "abc"] [abc2 [cn "ab" "c"]] [acute "é"] [kanji "日本語"]
        [nul [n->string 0]] [nul-a [cn [n->string 0] "a"]] [s9 "abcdefghi"] [digit "7"]
        [nil []] [true true] [false false] [sym foo] [sym2 [intern "foo"]] [var [intern "Foo"]] [fail [fail]]
        [one-list [cons 1 []]] [real-list [cons [+ 0.5 0.5] []]] [pair [cons 1 2]] [pair3 [cons 1 [cons 2 3]]]
        [two-list [cons 1 [cons 2 []]]] [three-list [cons 1 [cons 2 [cons 3 []]]]]
        [nested [cons [cons 1 []] []]] [str-list [cons "abc" [cons foo []]]] [vec-list [cons [absvector 1] []]]
        [v0 [absvector 0]] [v1 [absvector 1]] [v3 [absvector 3]] [nv0 [vector 0]] [nv2 [vector 2]]
        [nv2b [address-> [address-> [vector 2] 1 a] 2 b]] [nv3p [address-> [vector 3] 2 x]]
        [tuple [@p 1 2]] [tag-only [address-> [absvector 1] 0 shen.tuple]]
        [zero-long [address-> [absvector 4] 0 0]] [neg [address-> [absvector 2] 0 -1]] [real-tag [address-> [absvector 2] 0 1.5]]
        [real-zero [address-> [absvector 2] 0 [- 0.5 0.5]]] [real-zero1 [address-> [absvector 1] 0 [- 0.5 0.5]]] [str-tag [address-> [absvector 2] 0 "x"]]
        [nan-tag [address-> [absvector 2] 0 [let b [* [+ 0.5 0.5] 1.0e200] [- [* b b] [* b b]]]]]
        [closure [lambda x x]] [frozen [freeze 1]] [fn [function +]] [err [trap-error [simple-error "e"] [lambda e e]]]
        [stream [stoutput]] [b0 [shen-jit.bytes 0]] [b8 [shen-jit.bytes 8]] [bs [shen-jit.string->bytes "abc"]]
        [absvar [address-> [address-> [absvector 2] 0 shen.pvar] 1 2]]
        [pvar0 [shen-jit.pvar 0]] [pvar3 [shen-jit.pvar 3]]]))

(define o.values
  -> (map (/. V [(hd V) (eval-kl [freeze (hd (tl V))])]) (o.value-forms)))

(define o.named
  Names All -> (o.filter (/. V (element? (hd V) Names)) All))

(define o.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (o.filter F Xs)] (o.filter F Xs)))

(define o.without
  Names All -> (o.filter (/. V (not (element? (hd V) Names))) All))

\\ Random numbers, always the same ones.
(set o.*seed* 12345)

(define o.random
  N -> (do (set o.*seed* (shen-jit.bit-and (+ (* (value o.*seed*) 1103515) 12345) 2147483647))
           (shen-jit.shift-right (* (shen-jit.shift-right (value o.*seed*) 8) N) 23)))

(define o.nth
  0 [X | _] -> X
  N [_ | Xs] -> (o.nth (- N 1) Xs))

(define o.pick
  Xs -> (o.nth (o.random (length Xs)) Xs))

(define o.range
  From To -> [] where (>= From To)
  From To -> [From | (o.range (+ From 1) To)])

\\ ---------------------------------------------------------------------------
\\ Functions of any values

(define o.single-names
  -> [shen.+string? shen.+vector? shen.misc? shen.str->bytes shen.<-out shen.hds=? <-vector @p append
      tuple? vector vector? symbol? variable? shen.compute-E shen.compute-fraction-h shen.compute-integer
      shen.<alphanums> shen.<atom> shen.<digits> shen.<shortnatters> shen.<whitespaces>
      read-file read-file-as-bytelist read-file-as-string pr get fn hash shen.update-lambdatable
      shen.record-kl shen.record-and-evaluate shen.shendef->kldef-h])

(define o.any-values
  All -> (do (o.run tuple? 1 (o.cases1 All))
             (o.run vector? 1 (o.cases1 All))
             (o.run vector 1 (o.cases1 All))
             (o.run shen.+vector? 1 (o.cases1 All))
             (o.run shen.+string? 1 (o.cases1 All))
             (o.run integer? 1 (o.cases1 All))
             (o.run symbol? 1 (o.cases1 All))
             (o.run variable? 1 (o.cases1 All))
             (o.run shen.misc? 1 (o.cases1 (append All (map (/. N (o.v N)) (o.range -2 260)))))
             (o.run shen.str->bytes 1 (o.cases1 (append All (map (/. S (o.v S)) (o.strings)))))
             (o.run shen.<-out 1 (o.cases1 All))
             (o.run shen.hds=? 2 (o.cases2 All All))
             (o.run @p 2 (o.cases2 All All))
             (o.run append 2 (o.cases2 All All))
             (o.run <-vector 2 (o.cases2 All All))))

(define o.strings
  -> (o.flatmap (/. B (let S (n->string B) [S (cn S "a") (cn "a" S) (cn S S)])) (o.range 0 256)))

\\ Long inputs, which outrun what o.show looks at, and which take the port's loops past a collection.
(define o.same-long
  P Args -> (let K (trap-error [(o.apply (o.k P) Args)] (/. E "!"))
                 Got (trap-error [(o.apply (o.p P) Args)] (/. E "!"))
              (do (o.check)
                  (if (= K Got)
                      skip
                      (o.fail (make-string "(~A ...) on a long input differs" P))))))

(define o.run-of
  0 _ Tail -> Tail
  N X Tail -> (o.run-of (- N 1) X [X | Tail]))

(define o.long-string
  0 -> ""
  N -> (let Half (o.long-string (shen-jit.shift-right N 1))
         (cn Half (cn Half (if (= (shen-jit.bit-and N 1) 1) "x" "")))))

(define o.long
  -> (do (output "long inputs~%")
         (o.same-long append [(o.run-of 300000 1 []) [2 3]])
         (o.same-long append [(o.run-of 300000 1 5) [2 3]])
         (o.same-long shen.str->bytes [(o.long-string 5000)])
         (o.same-long shen.<digits> [(o.run-of 20000 49 [97])])
         (o.same-long shen.<alphanums> [(o.run-of 20000 97 [32])])
         (o.same-long shen.<whitespaces> [(o.run-of 20000 32 [97])])
         (o.same-long shen.<shortnatters> [(o.run-of 20000 97 [10 97])])))

\\ ---------------------------------------------------------------------------
\\ Names, from every byte alone, first and later, and what the kernel treats apart.

(define o.name-values
  -> (let Bytes (map (/. B (n->string B)) (o.range 1 256))
          Names (append
                  ["" "a" "A" "Ab" "aB" "a1" "A1" "1" "1a" "-" "--" "a-b" "@p" "<-" "->" "<>" "=" "_" "_a" "A_" "." ".a" "a."
                   "{" "}" ":" ";" "," "|" "[" "]" "(" ")" "true" "false" "()" "é" "aé" "éa" "日本語" "#<procedure>" "<vector 3>"]
                  (o.flatmap (/. S [S (cn "a" S) (cn S "a") (cn "A" S) (cn S "1")]) Bytes))
       (map (/. S (let Sym (intern S) [(make-string "intern ~S" S) (freeze Sym)])) Names)))

\\ ---------------------------------------------------------------------------
\\ The reader's rules, over lists of bytes

(define o.bytes
  S -> (o.bytes-h S 0 (shen-jit.string->bytes S)))

(define o.bytes-h
  S I B -> [] where (>= I (shen-jit.bytes-length B))
  S I B -> [(shen-jit.u8 B I) | (o.bytes-h S (+ I 1) B)])

(define o.random-text
  0 _ -> []
  N Alphabet -> [(o.pick Alphabet) | (o.random-text (- N 1) Alphabet)])

(define o.alphabet
  -> (o.bytes "0123456789+-.eEabzAZ_<>c#34;; ,()#!=é\c*"))

(define o.texts
  0 -> []
  N -> [(o.random-text (o.random 12) (append (o.alphabet) [9 10 13 32])) | (o.texts (- N 1))])

(define o.byte-lists
  -> (let Fixed ["" "0" "7" "007" "123" "1.5" "1.0" "8.0" "-1" "+1" "--1" "-+1" "1e5" "1E5" "1e-5" "1e+5" "1.5e3" "1.5e-3" ".5" "-.5"
                 "1." "1..2" "e5" "-e5" "abc" "a1" "A" "<>" "<>a" "c#34;strc#34;" "c#34;c#34;" "c#34;open" (cn "c#" "65;") (cn "c#34;c#" "65;c#34;") "\\ x" "\* x *\" "#!"
                 "   a" "
 a" "a b" "123456789012345678" "1234567890123456789012345"]
          Bytes (map (/. B [B]) (o.range 0 256))
          Pairs (o.flatmap (/. A (map (/. B [A B]) [9 10 13 32 48 57 97 65 45 43 46 34 92 0 255])) [9 10 13 32 48 57 97 65 45 43 46 34 92 0 255])
       (append (map (/. S (o.bytes S)) Fixed) (append Bytes (append Pairs (o.texts 1500))))))

\\ Lists whose bytes are not bytes, which no reader gives but no rule refuses.
(define o.odd-lists
  -> [[1.5] [(+ 48 0.5)] [(* 48 (+ 0.5 0.5))] ["a"] [a] [[]] [[48]] [48 | 49] [32 | 32] [97 | 98] [48 a] [32 a] [97 a] [10 a] [-1] [256] [1000]])

(define o.rules
  All -> (let Texts (map (/. B (o.v B)) (append (o.byte-lists) (o.odd-lists)))
              Cases (o.cases1 (append Texts All))
           (o.for-each (/. Rule (o.run Rule 1 Cases))
                       [shen.<digits> shen.<whitespaces> shen.<shortnatters> shen.<alphanums> shen.<atom>])))

\\ ---------------------------------------------------------------------------
\\ The reader's numbers

(define o.digit-lists
  -> (append [[] [0] [0 0] [1] [7] [1 0] [0 1] [0 0 7] [1 2 3] [5 0 0] [0 5 0]
              [1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8] [2 3 0 5 8 4 3 0 0 9 2 1 3 6 9 3 9 5 1]
              [9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9]]
             (map (/. N (o.random-text N [0 0 1 2 3 4 5 6 7 8 9])) (o.range 0 30))))

(define o.odd-digits
  -> [[a] ["1"] [1 | 2] [1.5] [(+ 0.5 0.5)] [-1] [10] [10 10] [11 12 13]])

(define o.exponents
  -> [0 1 2 5 18 19 20 22 23 100 308 309 400 -1 -2 -5 -18 -22 -23 -100 -307 -323 -324 -400])

(define o.mantissas
  -> [0 1 -1 5 12 123 1000 (o.pow 2 53) (o.pow 2 60) (+ 0.5 0.5) 0.5 1.5 123.456 -2.5 (- 0.5 0.5)])

(define o.numbers
  All -> (let Digits (map (/. D (o.v D)) (append (o.digit-lists) (o.odd-digits)))
              Exponents (map (/. N (o.v N)) (o.exponents))
              Mantissas (map (/. N (o.v N)) (o.mantissas))
              Oddments (o.named [a abc nil sym nv2b] All)
           (do (o.run shen.compute-integer 1 (o.cases1 (append Digits All)))
               (o.run shen.compute-fraction-h 2 (o.cases2 (append Digits Oddments) (append (map (/. N (o.v N)) [-1 -2 -5 -20 0 1]) Oddments)))
               (o.run shen.compute-E 2 (o.cases2 (append Mantissas Oddments) (append Exponents Oddments))))))

\\ ---------------------------------------------------------------------------
\\ Files

(set o.*dir* "")

(define o.write-file
  Name Bytes -> (let Path (cn (value o.*dir*) (cn "/" Name))
                     Out (open Path out)
                     _ (o.for-each (/. B (write-byte B Out)) Bytes)
                     _ (close Out)
                  Path))

(define o.file-contents
  -> [[] [97] [10] [13 10] [0] [0 97 0] [195 169] [255 254 128] [97 98 10 99 100 13 10]
      (o.range 0 256)
      (o.bytes "(a b) [c d] c#34;ec#34; 1.5")
      (o.bytes "(define f X -> X)")
      (o.bytes "\\ comment
a")
      (o.bytes "(a") (o.bytes ")") (o.bytes "c#34;open")
      (o.bytes "#")
      (o.bytes "#a b")
      (o.bytes "#!")
      (o.bytes "#!/usr/bin/env shen")
      (o.bytes "#!/usr/bin/env shen
(a b)")
      (o.bytes " #!not first")])

(define o.files
  All -> (let Contents (o.file-contents)
              Paths (map (/. I (o.write-file (make-string "input~A" I) (o.nth I Contents))) (o.range 0 (length Contents)))
              Cases (o.cases1 (append (map (/. P (o.v P)) Paths)
                                      (append [(o.v (cn (value o.*dir*) "/no-such-file")) (o.v "") (o.v (value o.*dir*))]
                                              (o.named [nil n0 sym one-list v3] All))))
           (do (o.run read-file-as-bytelist 1 Cases)
               (o.run read-file-as-string 1 Cases)
               (o.run read-file 1 Cases))))

\\ pr: each call writes to a file of its own, opened as its arguments are made, and its outcome
\\ is its value and what the file holds. Others are a closed stream and values that are not
\\ streams, and each again with *hush*, which is set as the arguments are made, and unset after.

(set o.*out* [])
(set o.*outs* 0)

(define o.no-out
  -> (do (if (cons? (value o.*out*)) (close (hd (value o.*out*))) skip)
         (set o.*out* [])
         (set *hush* false)))

(define o.fresh-out
  -> (let _ (o.no-out)
          N (set o.*outs* (+ 1 (value o.*outs*)))
          Path (cn (value o.*dir*) (make-string "/pr~A" N))
          S (open Path out)
          _ (set o.*out* [S Path])
       S))

(define o.closed-out
  -> (let _ (o.no-out)
          S (open (cn (value o.*dir*) "/closed") out)
       (do (close S) S)))

(define o.written
  X -> (let Out (value o.*out*)
            _ (set *hush* false)
         (if (cons? Out)
             (do (close (hd Out))
                 (set o.*out* [])
                 [X (read-file-as-bytelist (hd (tl Out)))])
             X)))

(define o.hushed
  [Name F] -> [(make-string "hushed ~A" Name) (freeze (let V (thaw F) (do (set *hush* true) V)))])

(define o.pr
  All -> (let Texts (append (map (/. S (o.v S)) (append ["" "abc" "a
b" (n->string 0) (n->string 255)] (o.strings)))
                            (o.named [n0 sym nil one-list bs] All))
              Others (map (/. V (let F (hd (tl V)) [(hd V) (freeze (do (o.no-out) (thaw F)))])) (o.named [n0 sym nil] All))
              Streams (append [["out" (freeze (o.fresh-out))] ["closed" (freeze (o.closed-out))]] Others)
              _ (o.run-post pr 2 (function o.written) (o.cases2 Texts (append Streams (map (function o.hushed) Streams))))
       (o.no-out)))

\\ ---------------------------------------------------------------------------
\\ get and fn

(define o.sample-dict
  -> (let D (shen.dict 8)
       (do (shen.dict-> D a [[p | 1] [q | false]])
           (shen.dict-> D b [])
           (shen.dict-> D c 5)
           (shen.dict-> D d [[p | 1] | 5])
           (shen.dict-> D e [p q])
           (shen.dict-> D 8 [[8 | eight]])
           (shen.dict-> D "s" [["t" | u]])
           D)))

(define o.get
  All -> (let Keys (append [(o.v a) (o.v b) (o.v c) (o.v d) (o.v e) (o.v 8) (o.v "s") (o.v missing) (o.v hd)] (o.named [r8 half nil pair nan] All))
              Attributes (append [(o.v p) (o.v q) (o.v "t") (o.v 8) (o.v missing) (o.v arity)] (o.named [r8 nil] All))
              Dicts (append [[dict (freeze (o.sample-dict))] [empty-dict (freeze (shen.dict 1))] [properties (freeze (value *property-vector*))]]
                            (o.named [n0 abc nil sym one-list v0 v3 nv2b tuple closure] All))
           (o.run get 3 (o.cases3 Keys Attributes Dicts))))

\\ What fn gives, used: a function takes arguments until it is done.
(define o.saturate
  R -> (trap-error (o.saturate-h R 6) (/. E [raised])))

(define o.saturate-h
  R 0 -> R
  R N -> (o.saturate-h (R 3) (- N 1)) where (= (str R) "#<procedure>")
  R _ -> R)

(define o.zero
  -> zero)

(define o.one
  X -> [X])

(define o.three
  X Y Z -> [X Y Z])

\\ fn makes a form when first asked for it, where the kernel's reads what the definition stored: the port
\\ gives a form to both by asking first.
(define o.fn
  All -> (let Names [o.zero o.one o.three hd tl cons + address-> @p vector fn append shen.dict shen-jit.u8 missing-function]
              _ (map (/. F (trap-error (fn F) (/. E skip))) Names)
           (o.run-post fn 1 (/. R (o.saturate R))
                       (o.cases1 (append (map (/. N (o.v N)) Names) All)))))

\\ ---------------------------------------------------------------------------
\\ hash: the values differ, as the kernel's hashes a string of the value and the port's the value, so the
\\ checks are that both take the same arguments and stay in range. The kernel's never ends on a bound
\\ below 1, which the port's refuses, so those are left out.

(define o.hash-range?
  R Bound -> (and (o.fixnum? R) (>= R 1) (or (= R 1) (< R Bound))))

(define o.hash-outcome
  F X Bound -> (trap-error (let R (F X Bound) (if (o.hash-range? R Bound) "in range" (make-string "out of range ~A" R))) (/. E "!")))

(define o.hash
  All -> (let Bounds (append (map (/. N (o.v N)) [1 2 3 7 8 100 65536 2147483648]) (o.named [half one-half r1 r8 abc nil sym] All))
              Kernel (o.k hash)
              Port (o.p hash)
           (do (output "hash~%")
               (o.for-each
                 (/. Case (let Names (map (/. V (hd V)) Case)
                               X (o.make (hd Case))
                               B (o.make (hd (tl Case)))
                               K (o.hash-outcome Kernel X B)
                               Got (o.hash-outcome Port X B)
                            (do (o.check)
                                (if (= K Got) skip (o.differs hash Names K Got)))))
                 (o.cases2 All Bounds)))))

\\ ---------------------------------------------------------------------------
\\ Dictionaries: the same operations on the kernel's and on the port's, with the hash of the port for both.

(define o.dict-group
  -> [shen.dict shen.dict-count shen.<-dict shen.dict-> shen.dict-rm shen.dict-fold
      shen.dict-capacity shen.<-dict-bucket shen.dict-bucket-> shen.dict-update-count shen.dict-count->
      shen.dict-fold-h shen.bucket-fold])

(define o.same-entries?
  [] [] -> true
  [X | Xs] Ys -> (and (element? X Ys) (o.same-entries? Xs (remove X Ys)))
  _ _ -> false)

\\ A key's value is made once and used by both, as a closure or a NaN is equal only to itself.
(define o.dict-keys
  All -> (map (/. V (o.make V))
              (o.named [n0 n1 n8 r8 r1 half r0 r-0 nan inf a abc abc2 empty nil sym sym2 true false one-list real-list two-list pair nested
                        v0 v3 nv2 nv2b tuple closure fn b8 bs] All)))

\\ Not of size 1: the kernel's has one bucket, at index 0, and looks in bucket 1, as hash never gives 0.
(define o.dicts
  All -> (let Keys (o.dict-keys All)
           (do (output "shen.dict and its operations~%")
               (o.run shen.dict 1 (o.cases1 All))
               (o.for-each (/. Size (o.dict-run Keys Size 400)) [2 8 100 5000]))))

(define o.dict-run
  Keys Size Steps
  -> (let K (o.pcall k shen.dict [Size])
          P (o.pcall p shen.dict [Size])
        (o.dict-steps Keys K P Steps)))

(define o.dict-steps
  _ K P 0 -> (o.dict-final K P)
  Keys K P N -> (let Key (o.pick Keys)
                     Op (o.random 4)
                     Value (o.random 100)
                  (do (o.dict-compare Op Key Value K P)
                      (o.dict-steps Keys K P (- N 1)))))

(define o.dict-compare
  Op Key Value K P
  -> (let Kernel (o.dict-op k Op Key Value K)
          Port (o.dict-op p Op Key Value P)
       (do (o.check)
           (if (= Kernel Port)
               skip
               (o.fail (make-string "dict op ~A on ~A: kernel ~A, port ~A" Op (o.show Key) Kernel Port)))
           (o.dict-final K P))))

(define o.dict-op
  W 1 Key _ D -> (let Used (trap-error (o.show (o.pcall W shen.<-dict [D Key])) (/. E (o.raised E)))
                      Ignored (trap-error (o.show (o.pcall W shen.<-dict [D Key])) (/. E "!"))
                   (if (= Used Ignored) Used "differs under a handler"))
  W 2 Key _ D -> (trap-error (o.show (o.pcall W shen.dict-rm [D Key])) (/. E (o.raised E)))
  W _ Key Value D -> (trap-error (o.show (o.pcall W shen.dict-> [D Key Value])) (/. E (o.raised E))))

(define o.dict-final
  K P -> (let Entry (/. A B Acc [(cn (o.show A) (cn " -> " (o.show B))) | Acc])
              KEntries (o.pcall k shen.dict-fold [Entry K []])
              PEntries (o.pcall p shen.dict-fold [Entry P []])
              KCount (o.pcall k shen.dict-count [K])
              PCount (o.pcall p shen.dict-count [P])
           (do (if (= KCount PCount)
                   skip
                   (o.fail (make-string "dict count: kernel ~A, port ~A" KCount PCount)))
               (if (o.same-entries? KEntries PEntries)
                   skip
                   (o.fail (make-string "dict entries: kernel ~A, port ~A" KEntries PEntries))))))

\\ ---------------------------------------------------------------------------
\\ Prolog: each world has its own variables, so terms are described and then built in each, and what comes
\\ back shows the same way in both.

(define o.prolog-group
  -> [shen.make-prolog-variable shen.pvar? shen.lazyderef shen.deref shen.bindv shen.unwind shen.lzy= shen.lzy=!
      shen.bind! shen.occurs-check? shen.newpv shen.gc shen.prolog-vector])

(define o.pcall
  k F Args -> (o.apply (o.k F) Args)
  p F Args -> (o.apply (o.p F) Args))

(define o.bindings
  -> (address-> (address-> (absvector 32) 0 shen.print-prolog-vector) 1 2))

(define o.term
  Depth -> (let R (o.random 10)
             (cases (< R 4) [v (o.random 4)]
                    (and (< R 7) (> Depth 0)) [c (o.term (- Depth 1)) (o.term (- Depth 1))]
                    true [a (o.random 10)])))

\\ Each variable at most once, which fails as often as not and makes no cycle.
(define o.linear-term
  Depth -> (let R (o.random 10)
             (cases (and (< R 4) (cons? (value o.*pool*)))
                    (let V (hd (value o.*pool*))
                      (do (set o.*pool* (tl (value o.*pool*))) [v V]))
                    (and (< R 7) (> Depth 0))
                    (let H (o.linear-term (- Depth 1))
                      [c H (o.linear-term (- Depth 1))])
                    true [a (o.random 10)])))

(define o.atom
  0 -> a
  1 -> b
  2 -> []
  3 -> 1
  4 -> (+ 0.5 0.5)
  5 -> 2
  6 -> "s"
  7 -> (cn "" "s")
  8 -> true
  9 -> c)

(define o.build
  [v I] Vars -> (o.nth I Vars)
  [c H T] Vars -> [(o.build H Vars) | (o.build T Vars)]
  [a N] _ -> (o.atom N))

\\ A world's bindings and variables, of which the last three may be bound to a term over the first.
(define o.world
  W Pre Bits -> (let B (o.bindings)
                     Vars (o.newpvs W 4 B)
                     Term (o.build Pre Vars)
                     _ (o.bind-some W (tl Vars) Bits Term B)
                  [B | Vars]))

(define o.newpvs
  _ 0 _ -> []
  W N B -> (let V (o.pcall W shen.newpv [B]) [V | (o.newpvs W (- N 1) B)]))

(define o.bind-some
  _ [] _ _ _ -> done
  W [V | Vs] [Bit | Bits] Term B -> (do (if Bit (o.pcall W shen.bindv [V Term B]) skip)
                                        (o.bind-some W Vs Bits Term B)))

(define o.slots
  B -> (map (/. I (o.show (<-address B I))) (o.range 1 8)))

\\ What a unifier returned, what the continuation saw, how often it ran, and the bindings after.
(define o.unify
  W F DX DY Pre Bits Answer
  -> (let World (o.world W Pre Bits)
          B (hd World)
          Vars (tl World)
          X (o.build DX Vars)
          Y (o.build DY Vars)
          Runs (absvector 2)
          _ (address-> Runs 0 0)
          _ (address-> Runs 1 none)
          R (trap-error (o.show (o.pcall W F [(o.pcall W shen.lazyderef [X B]) (o.pcall W shen.lazyderef [Y B]) B
                                              (freeze (do (address-> Runs 0 (+ 1 (<-address Runs 0)))
                                                          (address-> Runs 1 (o.slots B))
                                                          Answer))]))
                        (/. E "!"))
       [R (<-address Runs 0) (<-address Runs 1) (o.slots B)]))

(define o.bits
  0 -> []
  N -> [(< (o.random 10) 3) | (o.bits (- N 1))])

(define o.compare-unify
  F DX DY Pre Bits Answer
  -> (let K (o.unify k F DX DY Pre Bits Answer)
          P (o.unify p F DX DY Pre Bits Answer)
       (do (o.check)
           (if (= (hd K) (o.show false)) skip (set o.*unified* (+ 1 (value o.*unified*))))
           (if (= K P)
               skip
               (o.fail (make-string "(~A ~S ~S) pre ~S ~S, answer ~A: kernel ~S, port ~S" F DX DY Pre Bits Answer K P))))))

\\ Without the occurs check a term can hold itself, and walking two such terms need not end in either,
\\ so shen.lzy= runs on terms that the checking unifier can unify, and on terms with no repeated variable.
(define o.unifiers
  0 -> done
  N -> (let Pre (o.term 1)
            Pre* (o.only-first Pre)
            Bits (o.bits 3)
            DX (o.term 3)
            DY (o.term 3)
            Answer (o.pick [true false ok])
            Checked (o.unify k shen.lzy=! DX DY Pre* Bits true)
            _ (o.compare-unify shen.lzy=! DX DY Pre* Bits Answer)
            _ (o.deref-both DX Pre* Bits)
            _ (if (= (hd Checked) (o.show false))
                  skip
                  (o.compare-unify shen.lzy= DX DY Pre* Bits Answer))
            _ (set o.*pool* [0 1 2 3])
            LX (o.linear-term 3)
            LY (o.linear-term 3)
         (do (o.compare-unify shen.lzy= LX LY [a 0] [false false false] Answer)
             (o.compare-unify shen.lzy=! LX LY [a 0] [false false false] Answer)
             (o.unifiers (- N 1)))))

\\ The term that binds the others mentions only the first variable.
(define o.only-first
  [v _] -> [v 0]
  [c H T] -> [c (o.only-first H) (o.only-first T)]
  X -> X)

(define o.deref-both
  DX Pre Bits -> (o.compare-worlds (/. W (let World (o.world W Pre Bits)
                                              X (o.build DX (tl World))
                                           [(o.show (o.pcall W shen.lazyderef [X (hd World)]))
                                            (o.show (o.pcall W shen.deref [X (hd World)]))]))
                                   (make-string "deref ~S pre ~S ~S" DX Pre Bits)))

(define o.compare-worlds
  F Text -> (let K (trap-error (F k) (/. E "!"))
                 P (trap-error (F p) (/. E "!"))
              (do (o.check)
                  (if (= K P)
                      skip
                      (o.fail (make-string "~A: kernel ~S, port ~S" Text K P))))))

\\ Calls with what they should not be given, by what each side would raise.
(define o.prolog-edges
  All -> (let Others (o.without [pvar0 pvar3 absvar] All)
              Bindings (append [[b (freeze (o.bindings))] [short (freeze (absvector 1))]] (o.named [n0 abc nil sym one-list v0 tuple] All))
           (do (output "shen.make-prolog-variable~%")
               (o.for-each (/. V (o.world-call shen.make-prolog-variable V (/. W X (o.pcall W shen.make-prolog-variable [X])))) Others)
               (output "shen.pvar?~%")
               (o.for-each (/. V (o.world-call shen.pvar? V (/. W X (o.pcall W shen.pvar? [X])))) Others)
               (o.compare-worlds (/. W (o.pcall W shen.pvar? [(o.pcall W shen.make-prolog-variable [2])])) "shen.pvar? of a variable")
               (output "shen.gc~%")
               (o.for-each (/. C (o.compare-worlds (/. W (let B (o.bindings)
                                                              _ (o.newpvs W 3 B)
                                                              R (o.pcall W shen.gc [B C])
                                                           [(o.show R) (<-address B 1)]))
                                                   (make-string "shen.gc after a result ~S" C)))
                           [false true 0 [] "s" [1 2] a])
               (o.for-each (/. B (o.for-each (/. C (o.compare-worlds (/. W (o.show (o.pcall W shen.gc [(o.make B) C])))
                                                                     (make-string "shen.gc of ~A and ~S" (hd B) C)))
                                             [false true]))
                           Bindings)
               (output "shen.prolog-vector~%")
               (o.for-each (/. Memory (o.compare-worlds (/. W (o.prolog-vector-shape W Memory))
                                                        (make-string "shen.prolog-vector at ~A words" Memory)))
                           [3 10 1000 10000])
               (prolog-memory 10000)
               (output "shen.lazyderef, shen.deref, shen.bindv, shen.unwind~%")
               (o.for-each (/. Case (o.deref-edge Case))
                           (o.cases2 (append [[var2 2] [var31 31] [var32 32] [var1000 1000]] (map (/. V [(hd V) (o.make V)]) Others)) Bindings)))))

\\ What a query sees of a new vector of bindings: its first two elements and its size. The port's may be
\\ one an earlier query gave back, here one that holds a binding and a later offset, made at another size.
\\ What a query's end does in compiled code (shen-jit.prolog-done).
(define o.give-back
  V -> (set shen-jit.*free-prolog-vectors* (cons V (trap-error (value shen-jit.*free-prolog-vectors*) (/. E [])))))

(define o.prolog-vector-shape
  W Memory -> (let Before (if (= W p)
                              (let _ (prolog-memory 7)
                                   V (o.pcall W shen.prolog-vector [])
                                   _ (address-> V 2 junk)
                                   _ (address-> V 1 5)
                                (o.give-back V))
                              skip)
                   _ (prolog-memory Memory)
                   Given (if (= W p) (o.give-back (o.pcall W shen.prolog-vector [])) skip)
                   V (o.pcall W shen.prolog-vector [])
                [(<-address V 0) (<-address V 1)
                 (trap-error (do (<-address V (- Memory 1)) in) (/. E out))
                 (trap-error (do (<-address V Memory) in) (/. E out))]))

(define o.world-call
  P V Call -> (let _ (set o.*case-values* [(o.make V)])
                   K (trap-error (o.show (Call k (o.make V))) (/. E "!"))
                   Got (trap-error (o.show (Call p (o.make V))) (/. E "!"))
                (do (o.check)
                    (if (= K Got) skip (o.differs P [(hd V)] K Got)))))

\\ A case is a variable's offset or another value, and something to use as bindings.
(define o.deref-edge
  [[Name X] B]
  -> (let Maker (/. W (if (element? Name [var2 var31 var32 var1000]) (o.pcall W shen.make-prolog-variable [X]) X))
       (o.for-each
         (/. Op (let K (trap-error (o.show (o.edge-op k Op (Maker k) (o.make B))) (/. E "!"))
                     Got (trap-error (o.show (o.edge-op p Op (Maker p) (o.make B))) (/. E "!"))
                  (do (o.check)
                      (if (= K Got) skip (o.differs Op [Name (hd B)] K Got)))))
         [shen.lazyderef shen.deref shen.bindv shen.unwind])))

(define o.edge-op
  W shen.lazyderef X B -> (o.pcall W shen.lazyderef [X B])
  W shen.deref X B -> (o.pcall W shen.deref [X B])
  W shen.bindv X B -> (o.pcall W shen.bindv [X 1 B])
  W shen.unwind X B -> (o.pcall W shen.unwind [X B ok]))

\\ ---------------------------------------------------------------------------
\\ Definitions

(define o.lambdatable
  -> (do (output "shen.update-lambdatable~%")
         (o.for-each (/. N (o.lambdatable-case N)) [1 2 3 4])))

(define o.lambdatable-side
  Update N
  -> (let F (concat o.lt N)
          _ (eval-kl [defun F (o.take N [a b c d]) [cons 7 (o.list-form (o.take N [a b c d]))]])
          _ (put F arity N (value *property-vector*))
          G (value shen.*gensym*)
          R (Update F N)
          Moved (- (value shen.*gensym*) G)
          Form (fn F)
          Result (o.saturate Form)
       (o.show [R Moved Result])))

(define o.take
  0 _ -> []
  N [X | Xs] -> [X | (o.take (- N 1) Xs)])

(define o.list-form
  [] -> []
  [X | Xs] -> [cons X (o.list-form Xs)])

(define o.lambdatable-case
  N -> (let K (o.lambdatable-side (o.k shen.update-lambdatable) N)
            P (o.lambdatable-side (o.p shen.update-lambdatable) N)
         (do (o.check)
             (if (= K P) skip (o.fail (make-string "shen.update-lambdatable ~A: kernel ~A, port ~A" N K P))))))

\\ What recording leaves: what it returned, the list of definitions, and the definition.
(define o.record-side
  Record F Kl Before Sourced
  -> (let _ (set shen.*userdefs* Before)
          _ (if Sourced
                (put F shen.source old (value *property-vector*))
                (o.unsource F))
          R (Record F Kl)
       (o.show [R (value shen.*userdefs*) (get F shen.source (value *property-vector*))])))

\\ As if it had never been recorded.
(define o.unsource
  F -> (let Plist (trap-error (shen.<-dict (value *property-vector*) F) (/. E []))
         (shen.dict-> (value *property-vector*) F (o.remove-attribute shen.source Plist))))

(define o.remove-attribute
  _ [] -> []
  A [[A | _] | Rest] -> Rest
  A [X | Rest] -> [X | (o.remove-attribute A Rest)])

(define o.record
  -> (let Saved (value shen.*userdefs*)
          _ (output "shen.record-kl~%")
          _ (o.for-each
              (/. Case (let Before (hd Case)
                            Sourced (hd (tl Case))
                            K (o.record-side (o.k shen.record-kl) o.rec new Before Sourced)
                            P (o.record-side (o.p shen.record-kl) o.rec new Before Sourced)
                         (do (o.check)
                             (if (= K P) skip (o.differs shen.record-kl [Before Sourced] K P)))))
              [[[] false] [[a b] false] [[a b] true] [[o.rec] true] [[a o.rec b] true] [[a o.rec b] false] [[o.rec] false]])
       (set shen.*userdefs* Saved)))

\\ Rules as define hands them to shen.shendef->kldef-h. Gensyms are put back between the two.
(define o.rule-sets
  -> ["1 X -> X"
      "X -> 1 where (= X 2) X -> X"
      "[X | Y] 0 -> X [] N -> N _ _ -> none"
      "X X -> same X Y -> different"
      "(@p X Y) -> X"
      "(@v X <>) -> X"
      "(@s c#34;ac#34; X) -> X c#34;c#34; -> empty"
      "a -> b c <- (fail) d -> e"
      "X -> (let Y (+ X 1) (* Y Y))"
      "X Y Z -> [X Y Z]"
      \\ What it refuses: arities that differ, and a free variable.
      "1 2 -> 3 4 -> 5"
      "X -> Y"])

(define o.rules-of
  Text -> (compile (/. X (shen.<rules> X)) (read-from-string Text)))

(define o.kldef-side
  Def Rules G -> (do (set shen.*gensym* G)
                     (trap-error (o.show (Def o.defined Rules)) (/. E "!"))))

(define o.kldefs
  -> (o.for-each
       (/. Set (let Rules (trap-error (o.rules-of Set) (/. E failed))
                    G (value shen.*gensym*)
                    K (o.kldef-side (o.k shen.shendef->kldef-h) Rules G)
                    P (o.kldef-side (o.p shen.shendef->kldef-h) Rules G)
                 (do (o.check)
                     (if (= K P) skip (o.differs shen.shendef->kldef-h [Set] K P)))))
       (o.rule-sets)))

(define o.evaluate-side
  Evaluate Form Name Inputs
  -> (let R (trap-error (o.show (Evaluate Form)) (/. E "!"))
          Results (if (= Name none) [] (map (/. In (trap-error (o.show (o.apply-symbol Name In)) (/. E "!"))) Inputs))
       [R Results]))

(define o.apply-symbol
  F In -> ((fn F) In))

(define o.evaluate
  -> (let Good (shen.shendef->kldef-h o.evaluated (o.rules-of "[X | Y] -> X [] -> none X -> [X]"))
          Cases [[Good o.evaluated] [[defun o.evaluated2 [x] [+ x 1]] o.evaluated2] [[defun hd [x] x] none]
                 [[defun] none] [[defun o.bad] none] [[defun o.bad []] none] [[defun o.bad [] 1 2] none]
                 [5 none] ["s" none] [[] none] [[if true 1 2] none] [defun none]]
          Inputs [[1 2] [] 3 "a"]
       (o.for-each
         (/. Case (let Form (hd Case)
                       Name (hd (tl Case))
                       K (o.evaluate-side (o.k shen.record-and-evaluate) Form Name Inputs)
                       _ (shen.shendef->kldef-h o.evaluated (o.rules-of "[X | Y] -> X [] -> none X -> [X]"))
                       P (o.evaluate-side (o.p shen.record-and-evaluate) Form Name Inputs)
                    (do (o.check)
                        (if (= K P) skip (o.differs shen.record-and-evaluate [Form] K P)))))
         Cases)))

\\ ---------------------------------------------------------------------------

(define o.shebang-file?
  Path -> (let Bytes (read-file-as-bytelist Path)
            (and (cons? Bytes) (cons? (tl Bytes)) (= (hd Bytes) 35) (= (hd (tl Bytes)) 33))))

\\ The sessions that these three wire together are for tests/cli.sh: they read the REPL's input, display
\\ what reaches the top and end the process.
(define o.left-out
  -> [shen.read-evaluate-print shen.toplevel-display-exception shen.x.launcher.main])

(define o.tested
  -> (append (o.single-names) (append (o.dict-group) (append (o.prolog-group) [integer?]))))

(define o.overrides-known
  Port -> (o.for-each
            (/. Form (let F (hd (tl Form))
                       (if (or (element? F (o.tested)) (element? F (o.left-out))
                               (not (cons? (trap-error [(shen.<-dict (value o.*kernel*) F)] (/. E [])))))
                           skip
                           (o.fail (make-string "~A overrides the kernel, and is neither tested nor left out" F)))))
            (o.defuns Port)))

\\ Every clause of o.known but the last must still be needed.
(define o.report-known
  -> (do (o.for-each (/. E (output "known, ~A times: ~A~%" (tl E) (hd E))) (value o.*known*))
         (if (= (length (value o.*known*)) (o.known-clauses))
             skip
             (o.fail (make-string "~A known differences showed, of ~A listed" (length (value o.*known*)) (o.known-clauses))))))

(define o.main
  Kernel Port Dir
  -> (let _ (set o.*dir* Dir)
          _ (o.read-kernel Kernel)
          _ (o.overrides-known Port)
          _ (o.for-each (/. F (o.load [F])) (o.single-names))
          _ (o.load [integer? shen.integer-test? shen.magless])
          _ (o.load (o.dict-group))
          _ (o.load (o.prolog-group))
          All (o.values)
          Plain (o.without [pvar0 pvar3] All)
       (do (o.any-values All)
           (o.long)
           (o.run symbol? 1 (o.cases1 (o.name-values)))
           (o.run variable? 1 (o.cases1 (o.name-values)))
           (o.rules All)
           (o.numbers All)
           (o.files All)
           (o.pr All)
           (o.get All)
           (o.fn All)
           (o.hash Plain)
           (o.dicts Plain)
           (set o.*unified* 0)
           (let Checks (value o.*checks*)
             (do (o.unifiers 1000)
                 (output "shen.lzy=, shen.lzy=!, shen.deref, shen.lazyderef: ~A cases, ~A unified~%" (- (value o.*checks*) Checks) (value o.*unified*))))
           (o.prolog-edges All)
           (o.lambdatable)
           (o.record)
           (output "shen.shendef->kldef-h~%")
           (o.kldefs)
           (output "shen.record-and-evaluate~%")
           (o.evaluate)
           (o.report-known)
           (output "~A checks, ~A failed~%" (value o.*checks*) (value o.*failures*))
           (shen-jit.exit (if (= (value o.*failures*) 0) 0 1)))))

(let Args (tl (value *argv*))
  (o.main (hd Args) (hd (tl Args)) (hd (tl (tl Args)))))

\\ What refine makes of terms, which is what the walk of refine-walk.shen makes of code: formulas for smt, about numbers,
\\ propositions and things that are equal or not.
\\
\\ A term is a constant, [literal S X] for a number X that is no fixnum and is written as S, a call [F Term ...],
\\ [if P A B], a Boolean of and, or and not, [partial F Term ...], a function with some of its arguments, or [valued N], a
\\ value of which only its type is known: an argument of the definition, or what a call that is not pure gave. It is read in
\\ one of four ways, and has a name in each that it is read in:
\\
\\   integer  its value, for fixnums and for numbers that are always integers
\\   order    its place among numbers, for the rest of them; not what their arithmetic gives, as it rounds
\\   same     which thing it is, for symbols and strings
\\   true     whether it is true

(shen.x.namespace refine
  (use smt)
  (use shen-jit)
  (use shen)
  (externals [verified fixnum])
  (export proves?)

\\ What is known where the walk is, and what is known of terms wherever it is, as formulas. What each value is, [N | Call],
\\ the name of each term, [[Kind | Term] Name], the numbers among those ordered, and the symbols and strings compared.
(set *facts* [])
(set *always* [])
(set *values* [])
(set *names* [])
(set *described* [])
(set *numbers* [])
(set *constants* [])
(set *replaced* 0)
(set *depth* 0)
(set *hypotheses* [])
(set *types* [])

(define known-of
  -> [*facts* *always* *names* *described* *numbers* *constants*])

(define reset
  -> (do (map (/. X (set X [])) [*values* *hypotheses* *types* | (known-of)])
         (set *depth* 0)))

\\ Whether a term is so short that it can be wherever it is meant. One that is not is named, as what doubles would
\\ have no end.
(define brief?
  X -> (> (left 100 X) 0))

(define left
  0 _ -> 0
  N [X | Y] -> (left (left (- N 1) X) Y)
  N _ -> (- N 1))

\\ ---------------------------------------------------------------------------
\\ Types, which are those of the kernel, as what is walked was typechecked.

(define function-type
  F -> (let T (shen.x.type-annotations.function-type F) (if (= T false) [] T)) where (symbol? F)
  _ -> [])

\\ The type of a term, which its value is of whatever else the kernel takes it for, or [] where it cannot be told.
(define type-of
  [valued N] -> (type-of-call (call-of N))
  [cons X []] -> [list (type-of X)]
  [cons X Xs] -> (either-type [list (type-of X)] (type-of Xs))
  [@p X Y] -> [(type-of X) * (type-of Y)]
  [literal _ _] -> number
  [partial F | Args] -> (type-of-call [fn F | Args])
  [F | Args] -> (type-of-call [F | Args])
  X -> (type-in X (value *hypotheses*)) where (shen.freshterm? X)
  X -> (cases (shen-jit.fixnum? X) fixnum (string? X) string (boolean? X) boolean (symbol? X) symbol true []))

(define type-of-call
  [argument _ T] -> T
  [again _ T] -> (plain-type T)
  [fn F | Args] -> (if (= (arity F) 0) [] (type-of-call [F | Args]))
  [applied T | Ts] -> (plain-type (result-of (if (symbol? T) (function-type T) (type-of T)) Ts []))
  [F | Args] -> (plain-type (result-of (known-type F (assoc F (value *types*))) Args [])))

\\ Each is asked for once.
(define known-type
  _ [_ | T] -> T
  F [] -> (let T (function-type F)
               _ (set *types* [[F | T] | (value *types*)])
            T))

\\ What a function of a type gives for some arguments, its variables being what those make them. One that is in the type of
\\ an argument whose own cannot be told may be anything.
(define result-of
  [--> B] [] S -> (instance S B)
  [A --> B] [X | Xs] S -> (result-of B Xs (fit-argument A (type-of X) S))
  B [] S -> (instance S B)
  _ _ _ -> [])

(define fit-argument
  A T S -> (if (shaped? A T) (fit A T S) (append (map (/. V [V]) (shen.extract-vars A)) S)))

(define shaped?
  A _ -> true where (variable? A)
  [A | As] [T | Ts] -> (and (shaped? A T) (shaped? As Ts))
  A T -> (= A T))

(define fit
  A T S -> (let Entry (assoc A S) [[A | (if (empty? Entry) T (either-type T (tl Entry)))] | S]) where (variable? A)
  [A | As] [T | Ts] S -> (fit As Ts (fit A T S))
  _ _ S -> S)

\\ A variable is what is of lists and pairs. The kernel may take it for more, which what is given to a function, or put in a
\\ vector, can be of.
(define instance
  S A -> (let Entry (assoc A S) (if (empty? Entry) [] (tl Entry))) where (variable? A)
  S [list A] -> [list (instance S A)]
  S [A * B] -> [(instance S A) * (instance S B)]
  _ T -> (if (empty? (shen.extract-vars T)) T []))

\\ The type of what may be of either.
(define either-type
  T T -> T
  T U -> number where (and (number-type? T) (number-type? U))
  [list T] [list U] -> [list (either-type T U)]
  _ _ -> [])

(define number-type?
  T -> (element? T [fixnum number float]))

\\ A refined type is its base.
(define plain-type
  T -> (let C (condition T) (if (not (cons? C)) T (plain-type (replace (parameters (hd (tl (tl (tl C))))) (parameters T) (hd (tl (tl C))))))))

(define type-in
  _ [] -> []
  X [[Y : T] | Hyps] -> (if (= X Y) T (type-in X Hyps))
  X [_ | Hyps] -> (type-in X Hyps))

(define has-base?
  X Ts -> (element? (type-name (type-of X)) Ts))

\\ Whether a type is of these, or of lists and pairs of them.
(define made-of?
  Ts [list T] -> (made-of? Ts T)
  Ts [A * B] -> (and (made-of? Ts A) (made-of? Ts B))
  Ts T -> (element? T Ts))

\\ Equal values of these are the same.
(define exact?
  X -> (made-of? [fixnum symbol string boolean] (type-of X)))

\\ Whether two terms are equal or not whenever it is asked.
(define stays-equal?
  A B -> (or (constant? A) (constant? B) (and (unchanging? A) (unchanging? B))))

(define unchanging?
  X -> (made-of? [fixnum symbol string boolean number float] (type-of X)))

\\ A number that is never a float.
(define integer-term?
  [Op A B] -> (and (integer-term? A) (integer-term? B)) where (element? Op [+ - *])
  [if _ A B] -> (and (integer-term? A) (integer-term? B))
  [valued N] -> true where (integer-call? (call-of N))
  [F | Args] -> true where (integer-call? [F | Args])
  X -> (has-base? X [fixnum]))

(define integer-call?
  [F | _] -> (and (symbol? F) (declared F integer false)))

(define number-term?
  X -> (or (and (number? X) (not (shen-jit.fixnum? X))) (has-base? X [number float])))

(define truth-term?
  X -> (has-base? X [boolean]))

\\ ---------------------------------------------------------------------------
\\ Terms. What is written in a condition is one, with terms for its names, and nothing that it calls is made.

(define resolve
  [valued N] -> [valued N]
  [partial F | Args] -> [partial F | Args]
  [literal S X] -> [literal S X]
  [type X _] -> (resolve X)
  [not P] -> [not (resolve P)]
  [Op P Q] -> [Op (resolve P) (resolve Q)] where (element? Op [and or])
  [if P A B] -> [if (resolve P) (resolve A) (resolve B)]
  [fn F] -> (partial-of F [])
  [F | Args] -> (resolved-call (compare-numbers (length Args) (arity F)) F (map (fn resolve) Args)) where (symbol? F)
  X -> (constant X) where (not (cons? X))
  E -> (new-value E))

\\ 25.0 is equal to 25, and is another number.
(define constant
  X -> (if (or (not (number? X)) (shen-jit.fixnum? X)) X [literal (str X) X]))

(define special?
  F -> (element? F [lambda freeze trap-error protect set where cond let do]))

\\ What a function is given, against what it takes.
(define compare-numbers
  N M -> (cases (= N M) same (> N M) more true less))

(define resolved-call
  more F Ts -> (new-value [[fn F] | Ts])
  less F Ts -> (partial-of F Ts)
  _ F Ts -> (call-value F Ts (definition F (contract F))))

\\ A function with some of its arguments is the same for the same if it is pure, but for = of what may change.
(define partial-of
  = Ts -> (new-value [fn = | Ts]) where (or (empty? Ts) (not (stays-equal? (hd Ts) (hd Ts))))
  F Ts -> (if (pure? F) [partial F | Ts] (new-value [fn F | Ts])))

\\ The function that lambdas of Xs, the last first, give the last of its arguments, with the others, or [].
(define eta
  Xs [lambda X E] -> (eta [X | Xs] E)
  Xs [F | Args] -> (let Others (but-last Xs (reverse Args))
                     (if (or (= Others none) (some-mentioned? Xs Others)) [] [F | (reverse Others)])) where (and (symbol? F) (pure? F))
  _ _ -> [])

(define but-last
  [] Args -> Args
  [X | Xs] [X | Args] -> (but-last Xs Args)
  _ _ -> none)

(define new-value
  Call -> (let N (+ 1 (length (value *values*)))
               _ (set *values* [[N | Call] | (value *values*)])
            [valued N]))

(define call-of
  N -> (tl (assoc N (value *values*))))

(define one-of
  _ [] -> false
  X [cons Y Ys] -> [or (call-value = [X Y] []) (one-of X Ys)])

(define call-value
  F Args [Formals T] -> (do (set *replaced* (+ 1 (value *replaced*))) (resolve (replace Formals Args T)))
    where (and (= (length Formals) (length Args)) (brief? Args) (< (value *replaced*) 100))
  element? [X Ys] _ -> (one-of X Ys) where (written? Ys)
  = [A B] _ -> (new-value [= A B]) where (not (stays-equal? A B))
  F Args _ -> (if (and (pure? F) (steady? (known-type F (assoc F (value *types*))) Args)) (simplify [F | Args]) (new-value [F | Args])))

\\ Whether what a function is given as functions are the same each time: pure ones, by name or with some of their
\\ arguments. A pure function that is given another may give something else.
(define steady?
  [A --> B] [X | Xs] -> (and (or (not (mentions? --> A)) (steady-function? X)) (steady? B Xs))
  _ _ -> true)

(define steady-function?
  [partial | _] -> true
  F -> (and (symbol? F) (pure? F)))

\\ A promise that a result is equal to something says what the call is, whether it is made or not: [Formals
\\ Term], or []. Not in a circle, as each time round would make the same call something else.
(define definition
  F C -> (let D (equation F C)
           (if (or (empty? D) (element? F (called (hd (tl D)) []))) [] D)))

(define equation
  F [Formals _ R [Op A B]] -> (cases (= A R) (equation-by Formals R B) (= B R) (equation-by Formals R A) true [])
    where (and (element? Op [= fx=]) (element? (last-type (function-type F)) [boolean fixnum symbol string]))
  _ _ -> [])

(define last-type
  [--> T] -> (plain-type T)
  [_ --> T] -> (last-type T)
  T -> (plain-type T))

(define equation-by
  Formals R T -> (if (mentions? R T) [] [Formals T]))

\\ Fs and what a term calls, and what the terms that those are equal to call.
(define called
  [F | Ts] Fs -> (called-in Ts (if (symbol? F) (called-by F Fs) (called F Fs)))
  _ Fs -> Fs)

(define called-in
  [T | Ts] Fs -> (called-in Ts (called T Fs))
  _ Fs -> Fs)

(define called-by
  F Fs -> Fs where (element? F Fs)
  F Fs -> (let D (equation F (contract F))
            (if (empty? D) [F | Fs] (called (hd (tl D)) [F | Fs]))))

\\ What a pure call on constructors is.
(define simplify
  [head [cons X _]] -> X
  [tail [cons _ X]] -> X
  [fst [@p X _]] -> X
  [snd [@p _ X]] -> X
  [empty? []] -> true
  [empty? [cons _ _]] -> false
  [cons? []] -> false
  [length [cons _ X]] -> [+ 1 (simplify [length X])]
  [tuple? X] -> true where (has-base? X [*])
  [fx->number X] -> X
  [fixnum X] -> X where (integer-term? X)
  [shen-jit.fixnum? X] -> true where (integer-term? X)
  [Op | Ns] -> (computed Op Ns) where (and (bits? Op) (fixnums? Ns))
  [F X] -> (simplify-struct (struct-operation F) X [F X])
  X -> X)

(define bits?
  Op -> (element? Op [shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.shift-left shen-jit.shift-right fxquotient fxremainder]))

(define fixnums?
  [] -> true
  [N | Ns] -> (and (shen-jit.fixnum? N) (fixnums? Ns)))

(define computed
  F [A B] -> (trap-error ((fn F) A B) (/. E [F A B])))

(define simplify-struct
  [read T I] [Make | Args] _ -> (nth I Args) where (made-by? Make T)
  [test T] X Y -> (if (has-base? X [T]) true Y)
  _ _ X -> X)

(define made-by?
  Make T -> (and (symbol? Make) (= (struct-operation Make) [make T])))

\\ ---------------------------------------------------------------------------
\\ Formulas.

(define formula
  [not P] -> [not (formula P)]
  [and P Q] -> [and (formula P) (formula Q)]
  [or P Q] -> [or (formula P) (formula Q)]
  [if P Q R] -> (let F (named-if-long (formula P)) [and [or [not F] (formula Q)] [or F (formula R)]])
  P -> (atom (resolve P)))

\\ A formula that is in others more than once.
(define named-if-long
  F -> F where (brief? F)
  F -> (let X (name true (new-value [part]))
            _ (set *always* [[or [not X] F] [or X [not F]] | (value *always*)])
         X))

(define atom
  P -> P where (boolean? P)
  [Op | Ps] -> (formula [Op | Ps]) where (element? Op [and or not if])
  [Op A B] -> (comparison Op (number-of A) (number-of B)) where (comparison? Op)
  [cons? X] -> [not (atom [empty? X])] where (has-base? X [list])
  P -> (name true P))

\\ What a comparison tells of a number is its place among them, however it is written.
(define number-of
  [literal _ X] -> X
  X -> X)

(define comparison
  = A B -> (equal A B)
  Op A B -> (compare (integer-comparison Op) A B) where (element? Op [fx= fx< fx> fx<= fx>=])
  Op A B -> (compare-order (float-comparison Op) A B) where (element? Op [fl< fl> fl<= fl>=])
  Op A B -> (if (and (integer-term? A) (integer-term? B)) (compare Op A B) (compare-order Op A B)))

(define integer-comparison
  fx= -> =  fx< -> <  fx> -> >  fx<= -> <=  fx>= -> >=)

(define float-comparison
  fl< -> <  fl> -> >  fl<= -> <=  fl>= -> >=)

(define compare
  Op A B -> [Op (integer A) (integer B)])

\\ A comparison with a float that is no number is false.
(define compare-order
  Op A B -> [and (a-number A) [and (a-number B) [Op (order A) (order B)]]])

(define a-number
  X -> true where (or (number? X) (integer-term? X))
  X -> [not (name no-number X)])

(define iff
  F G -> (iff-named (named-if-long F) (named-if-long G)))

(define iff-named
  F G -> [and [or [not F] G] [or F [not G]]])

(define equal
  A A -> true where (exact? A)
  [] B -> (atom (simplify [empty? B]))
  A [] -> (atom (simplify [empty? A]))
  [Op A B] [Op C D] -> [and (comparison = (number-of A) (number-of C)) (comparison = (number-of B) (number-of D))] where (element? Op [cons @p])
  A B -> (iff (atom A) (atom B)) where (and (truth-term? A) (truth-term? B))
  A B -> (compare = A B) where (and (integer-term? A) (integer-term? B))
  A B -> (equal-numbers (a-number A) (a-number B) [= (order A) (order B)]) where (or (number-term? A) (number-term? B))
  A B -> [= (same A) (same B)] where (or (constant? A) (constant? B) (has-base? A [symbol string]) (has-base? B [symbol string]))
  A B -> (name true [= A B]))

\\ Two floats that are no numbers are equal only if they are the same object, which nothing tells.
(define equal-numbers
  M N E -> [or [and M [and N E]] [and [not M] [and [not N] (name true (new-value [nan]))]]])

(define constant?
  X -> (or (empty? X) (string? X) (number? X) (boolean? X) (and (symbol? X) (not (variable? X)))))

\\ As terms of smt's. A product is linear if one side is constant.
(define integer
  N -> N where (shen-jit.fixnum? N)
  [Op A B] -> [+ (integer A) (integer B)] where (element? Op [+ fx+])
  [Op A B] -> [- (integer A) (integer B)] where (element? Op [- fx-])
  [Op A B] -> (product-of (integer A) (integer B) [Op A B]) where (element? Op [* fx*])
  X -> (name integer X))

(define product-of
  A B X -> [* A B] where (or (linear-constant? A) (linear-constant? B))
  _ _ X -> (name integer X))

(define linear-constant?
  N -> true where (shen-jit.fixnum? N)
  [Op | Ts] -> (and (element? Op [+ - *]) (linear-constants? Ts))
  _ -> false)

(define linear-constants?
  [] -> true
  [T | Ts] -> (and (linear-constant? T) (linear-constants? Ts)))

\\ A number that is written stands for its place among them, which places gives in the end.
(define order
  N -> (let Entry (assoc N (value *numbers*))
         (if (cons? Entry)
             (hd (tl Entry))
             (let Name (cn "n" (str (length (value *numbers*))))
                  _ (set *numbers* [[N Name] | (value *numbers*)])
               Name))) where (number? N)
  X -> (name order X))

(define same
  X -> (code X (value *constants*)) where (constant? X)
  X -> (name same X))

(define code
  X Cs -> (let _ (set *constants* [X | Cs]) (length Cs)) where (not (element? X Cs))
  X [X | Cs] -> (length Cs)
  X [_ | Cs] -> (code X Cs))

(define name
  Kind X -> (let Entry (assoc [Kind | X] (value *names*))
              (if (cons? Entry) (hd (tl Entry)) (new-name Kind X))))

(define letter
  integer -> "i"
  order -> "o"
  same -> "s"
  true -> "t"
  no-number -> "x")

\\ What is known of a term wherever it is, and of pure functions, that they give the same for the same.
(define new-name
  Kind X -> (let Name (make-string "~A~A" (letter Kind) (length (value *names*)))
                 Others (value *names*)
                 _ (set *names* [[[Kind | X] Name] | Others])
                 _ (set *always* (append (congruences Kind X Name Others) (value *always*)))
                 _ (describe X)
                 _ (describe-choice Kind X)
              Name))

(define congruences
  Kind [F | Args] Name Others -> (congruent-to Kind F Args Name Others)
    where (and (element? Kind [integer same true]) (symbol? F) (not (element? F [valued if])))
  _ _ _ _ -> [])

(define congruent-to
  _ _ _ _ [] -> []
  Kind F Args Name [[[Kind F | Others] Other] | Ns]
  -> (append (congruence (arguments-equal Args Others) (if (= Kind true) (iff Name Other) [= Name Other]))
             (congruent-to Kind F Args Name Ns)) where (= (length Args) (length Others))
  Kind F Args Name [_ | Ns] -> (congruent-to Kind F Args Name Ns))

(define congruence
  unclear _ -> []
  Es E -> [[or E | (map (/. F [not F]) Es)]])

\\ Formulas for each argument to equal the other's, but for those that are the same, or unclear.
(define arguments-equal
  [] [] -> []
  [X | Xs] [X | Ys] -> (arguments-equal Xs Ys)
  [X | Xs] [Y | Ys] -> (argument-equal (arguments-equal Xs Ys) X Y))

(define argument-equal
  unclear _ _ -> unclear
  Es X Y -> [(compare = X Y) | Es] where (and (integer-term? X) (integer-term? Y))
  Es X Y -> [[= (same X) (same Y)] | Es] where (and (has-base? X [symbol string]) (has-base? Y [symbol string]))
  Es X Y -> [(iff (atom X) (atom Y)) | Es] where (and (truth-term? X) (truth-term? Y))
  _ _ _ -> unclear)

\\ P is so of terms wherever they are, or where the walk is. What is said of a call may name others, of which something is
\\ said.
(define note
  P -> (said *always* P))

(define know
  P -> (said *facts* P))

(define said
  _ true -> skip
  _ _ -> skip where (or (> (value *depth*) 5) (> (length (value *names*)) 300))
  Where P -> (let Depth (value *depth*)
                  _ (set *depth* (+ 1 Depth))
                  F (formula P)
                  _ (set *depth* Depth)
               (set Where [F | (value Where)])))

(define describe
  X -> skip where (element? X (value *described*))
  X -> (do (set *described* [X | (value *described*)])
           (describe-parts X)
           (describe-trusted X)))

(define describe-parts
  [_ | Args] -> (describe-each Args)
  _ -> skip)

(define describe-each
  [] -> skip
  [X | Xs] -> (do (describe X) (describe-each Xs))
  _ -> skip)

(define field-says
  [read T _] F X -> (if-so [(member T "?") X] (promised (contract F) [X] [F X]))
  _ _ _ -> true)

(define if-so
  _ true -> true
  P Q -> [or [not P] Q])

(define describe-trusted
  [valued N] -> (trust-call (call-of N) [valued N])
  [F | Args] -> (trust-call [F | Args] [F | Args])
  _ -> skip)

(define trust-call
  [F | Args] X -> (do (trust-result (trusted F) Args X) (note (bits F Args X)))
  _ _ -> skip)

(define trust-result
  [Formals R Post] Args X -> (note (replace [R | Formals] [X | Args] Post)) where (= (length Formals) (length Args))
  _ _ _ -> skip)

\\ What a shift or a mask by a constant gives, as arithmetic, true for none. A mask is a remainder, whose
\\ quotient the shift gives. No number in them is so large that the solver's sums would leave the fixnums: a
\\ left shift is only of what fits in 24 bits.
(define bits
  shen-jit.shift-right [A K] R -> (let P (power-of-2 K) [and [fx<= [fx* P R] A] [fx< A [fx+ [fx* P R] P]]]) where (width? K)
  shen-jit.shift-left [A K] R -> [or [fx< A -16777216] [or [fx> A 16777216] [fx= R [fx* (power-of-2 K) A]]]] where (width? K)
  shen-jit.bit-and [A M] R -> (masked A M R) where (mask? M)
  shen-jit.bit-and [M A] R -> (masked A M R) where (mask? M)
  _ _ _ -> true)

(define masked
  A M R -> [fx= A [fx+ R [fx* (+ M 1) [shen-jit.shift-right A (shen-jit.popcount M)]]]])

(define width?
  K -> (and (shen-jit.fixnum? K) (>= K 0) (<= K 32)))

(define mask?
  M -> (and (shen-jit.fixnum? M) (> M 0) (<= M 4294967295) (= 0 (shen-jit.bit-and M (+ M 1)))))

(define power-of-2
  0 -> 1
  K -> (* 2 (power-of-2 (- K 1))))

\\ An if is one of two.
(define describe-choice
  integer [if P A B] -> (note [if P [fx= [if P A B] A] [fx= [if P A B] B]])
  same [if P A B] -> (note [if P [= [if P A B] A] [= [if P A B] B]])
  _ _ -> skip)

\\ ---------------------------------------------------------------------------
\\ What follows from the names together.

\\ Numbers that are written, in order and so far apart that every other fits between any two.
(define places
  -> (place (sort-numbers (value *numbers*)) 0 (+ 2 (count-names order (value *names*)))))

(define place
  [] _ _ -> []
  [[_ Name] | Ns] At Apart -> [[= Name At] | (place Ns (+ At Apart) Apart)])

(define sort-numbers
  [] -> []
  [N | Ns] -> (insert-number N (sort-numbers Ns)))

(define insert-number
  N [] -> [N]
  [N A] [[M B] | Ns] -> (if (< N M) [[N A] [M B] | Ns] [[M B] | (insert-number [N A] Ns)]))

(define count-names
  _ [] -> 0
  Kind [[[Kind | _] _] | Ns] -> (+ 1 (count-names Kind Ns))
  Kind [_ | Ns] -> (count-names Kind Ns))

\\ ---------------------------------------------------------------------------
\\ What is asked.

\\ Whether P follows from what is known, as smt's answer. Asked is P as it was read.
(set *asked* true)
(set *known* [])

(define ask
  P -> (let _ (set *known* (value *values*))
            _ (set *replaced* 0)
            Goal (formula P)
            _ (set *asked* Goal)
         (smt.check (append (value *facts*) (value *always*) (places) [[not Goal]]))))

\\ For the side condition of a datatype's rule, where (ctxt Hyps) gives the hypotheses.
(define proves?
  Hyps P -> (let _ (reset)
                 _ (set *hypotheses* Hyps)
                 _ (map (fn suppose) (reverse Hyps))
              (smt.unsat? (ask (uncurry P)))))

(define suppose
  [P : verified] -> (know (uncurry P))
  _ -> skip)

\\ A term as it was before it was curried.
(define uncurry
  [type X T] -> [type (uncurry X) T]
  [F | Args] -> (with-arguments (uncurry F) (map (fn uncurry) Args)) where (cons? F)
  [F | Args] -> [F | (map (fn uncurry) Args)]
  X -> X)

(define with-arguments
  [F | Args] More -> [F | (append Args More)] where (and (symbol? F) (<= (+ (length Args) (length More)) (arity F)))
  F More -> [F | More])
\\ ---------------------------------------------------------------------------
\\ What an error says.

\\ What is said of the first of the conditions that is not proved by itself, or of all if each is.
(define not-proved
  All [] -> (not-met All (ask All))
  All [P | Ps] -> (let R (ask P) (if (smt.unsat? R) (not-proved All Ps) (not-met P R))))

(define not-met
  P R -> (make-string "~R, which ~A" (shown P) (if (smt.sat? R)
                                                    (@s "may not be so" (example (smt.model R)) (another (values-in P (value *values*))))
                                                    (cn "is not proved: " (smt.reason R)))))

\\ The values of what was asked, in it and made as it was read.
(define values-in
  P Calls -> (valued-in P) where (= Calls (value *known*))
  P [[N | _] | Calls] -> [N | (values-in P Calls)])

(define valued-in
  [valued N] -> [N]
  [X | Y] -> (append (valued-in X) (valued-in Y))
  _ -> [])

\\ That a call in what was asked is not the one that something is known of, as it is not pure: nothing can be known
\\ of one that is true or false.
(define another
  [] -> ""
  [N | Ns] -> (let Call (call-of N)
                (if (another? N Call)
                    (make-string ". ~A, so ~R may be another each time"
                                 (why-another (hd Call) (tl Call)) (shown (if (= again (hd Call)) (hd (tl Call)) Call)))
                    (another Ns))))

(define another?
  _ [again | _] -> true
  N [F | Args] -> (and (symbol? F) (not (special? F)) (not (element? F [part nan argument applied]))
                       (or (> (occurrences [F | Args] (map (fn tl) (value *values*))) 1)
                           (element? [true valued N] (map (fn hd) (value *names*)))))
  _ _ -> false)

\\ Of a pure function, the first function that it is given and that is not.
(define given-function
  [] -> "A function that it is given may change"
  [[valued N] | _] -> (why-another fn (tl (call-of N))) where (= fn (hd (call-of N)))
  [_ | Args] -> (given-function Args))

(define why-another
  = _ -> "What it compares may change"
  again _ -> "What it is in may change"
  fn [F | _] -> (why-another F [])
  F Args -> (given-function Args) where (pure? F)
  F _ -> (make-string "~A is not declared pure" F))

\\ A model in the program's terms, of those in what was asked.
(define example
  Model -> (let Parts (mapcan (fn asked-parts) (value *names*))
             (example-h (mapcan (/. Entry (example-of Entry (value *names*) Parts (no-numbers (value *names*) Model))) Model) ", as if ")))

\\ What is no number in a model.
(define no-numbers
  [] _ -> []
  [[[no-number | X] Name] | Ns] Model -> [X | (no-numbers Ns Model)] where (element? [Name true] Model)
  [_ | Ns] Model -> (no-numbers Ns Model))

\\ An if is what its parts are, so it is those that the example gives.
(define asked-parts
  [[_ if | Parts] Name] -> Parts where (mentions? Name (value *asked*))
  _ -> [])

(define asked?
  _ [if | _] _ -> false
  Name X Parts -> (or (mentions? Name (value *asked*)) (mentions? X Parts)))

(define mentions?
  X X -> true
  X [Y | Z] -> (or (mentions? X Y) (mentions? X Z))
  _ _ -> false)

(define example-of
  _ [] _ _ -> []
  [Name V] [[[Kind | X] Name] | _] Parts Not -> (if (asked? Name X Parts) (example-in Kind X V Not) [])
  Entry [_ | Ns] Parts Not -> (example-of Entry Ns Parts Not))

(define example-in
  integer X V _ -> [[(shown X) V]]
  true [valued N] _ _ -> [] where (element? (call-of N) [[part] [nan]])
  true X V _ -> [[(shown X) V]]
  same X V _ -> (let C (constant-of V (value *constants*)) (if (empty? C) [] [[(shown X) (hd C)]]))
  order X V Not -> (let At (among V (places) (reverse (value *numbers*))) (if (= At "") [] [[(shown X) (intern At)]]))
    where (not (element? X Not))
  no-number X true _ -> [[(shown X) (intern "no number")]]
  _ _ _ _ -> [])

\\ Where a place is among the numbers that are written.
(define among
  V Places Numbers -> (between-text (nearest V Places Numbers below none) (nearest V Places Numbers above none)))

(define nearest
  _ [] _ _ Best -> (if (= Best none) none (hd (tl Best)))
  V [[= Name At] | Ps] Numbers Side Best
  -> (nearest V Ps Numbers Side
       (if (and (if (= Side below) (<= At V) (>= At V)) (closer? At Side Best))
           [At (number-named Name Numbers)]
           Best)))

(define closer?
  _ _ none -> true
  At Side [Other | _] -> (if (= Side below) (> At Other) (< At Other)))

(define number-named
  Name [[N Name] | _] -> N
  Name [_ | Ns] -> (number-named Name Ns))

(define between-text
  none none -> ""
  N N -> (str N)
  none N -> (cn "below " (str N))
  N none -> (cn "above " (str N))
  M N -> (@s "between " (str M) " and " (str N)))

\\ The symbol or string whose code is N, in a list.
(define constant-of
  _ [] -> []
  N [C | Cs] -> (if (= N (length Cs)) [C] (constant-of N Cs)))

(define example-h
  [] _ -> ""
  [[X V] | Es] Before -> (cn (make-string "~A~R is ~S" Before X V) (example-h Es " and ")))

\\ A term as the program has it: by a name that it is bound to, [Name | Term] each, if it has one.
(set *shown* [])

(define shown
  X -> (shown-by X (value *shown*)))

(define shown-by
  X [] -> (shown-parts X)
  X [[Name | X] | _] -> Name
  X [_ | Names] -> (shown-by X Names))

(define shown-parts
  [valued N] -> (shown-parts (call-of N))
  [argument X _] -> X
  [again X _] -> X
  [type X _] -> (shown X)
  [applied | Ts] -> (map (fn shown) Ts)
  [partial F] -> [fn F]
  [partial | X] -> (shown-parts X)
  [literal _ X] -> X
  [X | Y] -> [X | (map (fn shown) Y)] where (symbol? X)
  [X | Y] -> (map (fn shown) [X | Y])
  X -> X)

\\ Numbers that are never floats, though their type is number.
(map (/. F (put F integer true)) [length limit occurrences])

)

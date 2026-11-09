\\ Datalog: relations, facts and recursive rules, evaluated bottom up to a fixed point. It stays
\\ out of the image until asked for; load it after lib/native.shen, whose assembler makes its
\\ kernels, and before the code using it:
\\
\\   shen-jit eval -l lib/native.shen -l lib/datalog.shen -l program.shen
\\
\\ (defdatalog dependencies
\\   (relation imports [symbol symbol])
\\   (relation depends [symbol symbol])
\\   (relation cyclic [symbol])
\\   (rule (depends X Y) <-- (imports X Y))
\\   (rule (depends X Z) <-- (imports X Y) (depends Y Z))
\\   (rule (cyclic X) <-- (depends X X)))
\\
\\ (let Db (datalog.run dependencies [[imports a b] [imports b c] [imports c a]])
\\   (datalog.ask Db (depends a X)))     \\ the tuples of depends whose first column is a
\\
\\ defdatalog          relations and rules, checked when defined; a rule is a head, or a head,
\\                     <-- and a body of atoms and comparisons
\\ datalog.define      (datalog.define Name Items), the same with the program as data
\\ datalog.run         (datalog.run Name Facts), a database from facts such as [imports a b]
\\ datalog.add         (datalog.add Db Facts), the same database with more facts and what follows
\\ datalog.remove      (datalog.remove Db Facts), the same without these facts and what they gave
\\ datalog.run-naive   the same by the plain definition, which is slow and is what the rest is
\\                     tested against
\\ datalog.tuples      (datalog.tuples Db Relation), its tuples as lists, in no particular order
\\ datalog.sorted      the same, sorted
\\ datalog.count       how many tuples a relation has
\\ datalog.holds?      (datalog.holds? Db [depends a b])
\\ datalog.ask         (datalog.ask Db (depends a X)), the tuples that match; _ matches anything
\\ datalog.match       (datalog.match Db [depends a [var "X"]]), the same with the pattern as data
\\ datalog.plans       (datalog.plans Name), the order of each rule's joins and the indexes they use
\\ datalog.code        (datalog.code Name), the KL those give
\\ datalog.stats       (datalog.stats Db), rounds, and per relation tuples and derivations
\\
\\ A column is a symbol, a string or an integer of 32 bits, signed. A variable in a head, a
\\ comparison or a negated atom must appear in a positive atom of the body, or be bound by =.
\\ Comparisons are <, >, <= and >= on integers, and = and != on values of one type; either side
\\ can be arithmetic, (+ A B), (- A B) or (* A B), which raises when a result is not 32 bits.
\\ (= D (+ D0 W)) binds D if nothing else has. (= N (count (edge X _))), and (sum W Atom),
\\ (min W Atom) and (max W Atom), aggregate over the tuples an atom matches, with keys its
\\ variables that appear elsewhere in the body. (not (edge X _)) holds when no tuple matches; a relation
\\ cannot depend on the negation or an aggregate of one that depends on it, so what is negated or
\\ aggregated is complete before it is read. As data, a variable is [var "X"] and _ is [any].
\\
\\ Relations are sets, so duplicates count once, and the order of rules, atoms and facts does not
\\ change a result. datalog.add and datalog.remove change a database in place: an add goes on
\\ from what grew, and a removal evaluates again what it reaches.
\\
\\ Each rule becomes a native kernel, for an order of joins, kept with the program. The order comes
\\ from the sizes of the relations as it runs, and changes when they have. Symbols and strings are
\\ interned, integers are themselves, and tuples are kept flat in byte buffers: see "Storage" below.

(shen.x.namespace datalog
  (use shen-jit)
  (externals [!= % a absent again aggregate all any assign b band bit-and bit-or bit-xor block
    bor bshl bshr bxor c cat check choice compare count csv d db defdatalog define-native demand
    e emit eq equivalence exit f fact filter fold for grow i insert integer j k keyed l lattice
    lookup max mean min n naive new no none ok old p place plans probe program q r record
    relation replace restart return-word rounds rule s s32 same scan shift-left shift-right
    shift-right-signed skip start strlen substr t to-number to-string tsv u32 u32! u64 u64! u<
    unless unpack v var w while word x])
  (shadow atom? bound? log2 nth run some? sort subset?)
  (export add ask bytes->facts code datalog.count => count datalog.define => define demand-db
    explain holds? match datalog.plans => plans query read-facts relation->bytes
    datalog.remove => remove run run-naive solve sorted stats tuples write-facts defdatalog)

(set *adaptive* true)
(set *plans* 0)

\\ ---------------------------------------------------------------------------
\\ Checking a program.

(define comparison?
  X -> (element? X [< > <= >= = !=]))

(define ordering?
  X -> (element? X [< > <= >=]))

\\ An integer column holds 32 bits, signed, as itself; symbols and strings are interned.
(define int32?
  X -> (and (integer? X) (>= X -2147483648) (<= X 2147483647)
            (trap-error (do (shen-jit.bit-or X 0) true) (/. E false))))

(define value-type
  X -> symbol where (symbol? X)
  X -> string where (string? X)
  X -> integer where (int32? X)
  _ -> none)

\\ The 32 bits a column holds for an integer, and back.
(define int-word
  X -> (if (< X 0) (+ X 4294967296) X))

(define word-int
  W -> (if (> W 2147483647) (- W 4294967296) W))

(define term->form
  [var Name] -> (intern Name)
  [any] -> (intern "_")
  [F | Args] -> [F | (map (/. T (term->form T)) Args)]
  X -> X)

(define atom->form
  [Rel | Terms] -> [Rel | (map (/. T (term->form T)) Terms)]
  X -> X)

(define rule->form
  Head [] -> (atom->form Head)
  Head Body -> [(atom->form Head) <-- | (map (/. A (literal->form A)) Body)])

(define literal->form
  [not Atom] -> [not (atom->form Atom)]
  [aggregate V count _ Atom _] -> [= (intern V) [count (atom->form Atom)]]
  [aggregate V Op T Atom _] -> [= (intern V) [Op (intern T) (atom->form Atom)]]
  [= A B] -> [= (aggregate->form A) (aggregate->form B)]
  Literal -> (atom->form Literal))

(define aggregate->form
  [count Atom] -> [count (atom->form Atom)]
  [Op T Atom] -> [Op (term->form T) (atom->form Atom)] where (aggregate? Op)
  T -> (term->form T))

(define relations
  _ _ [] Acc -> (reverse Acc)
  Name Known [[relation Rel Types] | Items] Acc
  -> (cases (or (not (symbol? Rel)) (variable? Rel) (comparison? Rel) (element? Rel [not aggregate]))
            (error "datalog ~A: ~S cannot name a relation" Name Rel)
            (cons? (assoc Rel Acc))
            (error "datalog ~A: relation ~A is declared twice" Name Rel)
            (not (types? Types Known))
            (error "datalog ~A: relation ~A has columns ~S, which are not a list of symbol, string, integer or declared types" Name Rel Types)
            true (relations Name Known Items [[Rel | Types] | Acc]))
  Name Known [[relation Rel [A B] equivalence] | Items] Acc
  -> (if (= A B)
         (relations Name Known [[relation Rel [A B]] | Items] Acc)
         (error "datalog ~A: equivalence ~A has columns ~S, where two of one type are wanted" Name Rel [A B]))
  Name _ [[relation Rel Types equivalence] | _] _
  -> (error "datalog ~A: equivalence ~A has columns ~S, where two of one type are wanted" Name Rel Types)
  Name Known [[relation Rel Types Mode] | Items] Acc
  -> (cases (not (keep-mode? Mode))
            (error "datalog ~A: relation ~A is declared ~S, which is neither equivalence, min, max, choice nor (lattice F)" Name Rel Mode)
            (or (not (cons? Types)) (< (length Types) 2))
            (error "datalog ~A: ~A keeps one tuple for each value of the columns before its last, so it needs two columns or more" Name Rel)
            (and (not (= Mode choice)) (not (= (hd (reverse Types)) integer)))
            (error "datalog ~A: ~A keeps the ~A of its last column, which must be an integer" Name Rel Mode)
            true (relations Name Known [[relation Rel Types] | Items] Acc))
  Name Known [[rule | _] | Items] Acc -> (relations Name Known Items Acc)
  Name Known [[type | _] | Items] Acc -> (relations Name Known Items Acc)
  Name _ [Item | _] _ -> (error "datalog ~A: ~S is neither a relation, a type nor a rule" Name Item))

(define types?
  [] _ -> true
  [T | Ts] Known -> (and (element? T [symbol string integer | Known]) (types? Ts Known))
  _ _ -> false)

\\ The variables' types so far, as [["X" | symbol] ...]; each atom of the body adds to them.
(define check-atom
  Say Relations Env [Rel | Terms]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (check-terms Say Terms (tl Types) Env)))
  Say _ _ Atom -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define check-terms
  _ [] [] Env -> Env
  Say [[any] | Terms] [_ | Types] Env -> (check-terms Say Terms Types Env)
  Say [[var V] | Terms] [Type | Types] Env
  -> (let Known (assoc V Env)
       (cases (empty? Known) (check-terms Say Terms Types [[V | Type] | Env])
              (= (tl Known) Type) (check-terms Say Terms Types Env)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say [X | Terms] [Type | Types] Env
  -> (check-terms Say Terms Types
       (check-terms Say (tl X) (fields-of Say X Type) Env))
     where (cons? X)
  Say [X | Terms] [Type | Types] Env
  -> (if (= (value-type X) Type)
         (check-terms Say Terms Types Env)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define term-type
  Say Env [var V] -> (let Known (assoc V Env)
                       (if (empty? Known)
                           (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
                           (tl Known)))
  Say _ [any] -> (error "datalog ~A: _ cannot be compared" Say)
  Say Env [Op A B] -> (if (and (= (term-type Say Env A) integer) (= (term-type Say Env B) integer))
                          integer
                          (error "datalog ~A: ~A works on integers" Say Op))
                      where (arithmetic? Op)
  Say Env [F | Args] -> (let Sig (takes F)
                          (cases (not (= (length Args) (length (hd Sig))))
                                 (error "datalog ~A: ~A takes ~A values, not ~A" Say F (length (hd Sig)) (length Args))
                                 (= (map (/. A (term-type Say Env A)) Args) (hd Sig)) (hd (tl Sig))
                                 true (error "datalog ~A: ~A takes ~A" Say F (hd Sig))))
                      where (string-function? F)
  Say Env [C | Args] -> (let Con (constructor-of Say [C | Args])
                          (do (check-field-types Say Env Args (nth 4 Con))
                              (nth 2 Con)))
  Say _ X -> (let Type (value-type X)
               (if (= Type none)
                   (error "datalog ~A: ~S is not a value" Say X)
                   Type)))

(define check-comparison
  Say Env [Op A B]
  -> (let TA (term-type Say Env A)
          TB (term-type Say Env B)
       (cases (not (= TA TB)) (error "datalog ~A: ~A and ~A are compared" Say TA TB)
              (and (ordering? Op) (not (= TA integer)))
              (error "datalog ~A: ~A orders integers" Say Op)
              true Env))
  Say _ Form -> (error "datalog ~A: ~S is not a comparison" Say Form))

\\ A literal of a body is an atom, a comparison, a negated atom or an aggregate; all but the first
\\ are conditions.
(define atom?
  [Op | _] -> (not (or (comparison? Op) (element? Op [not aggregate])))
  _ -> true)

\\ (not Atom): no tuple of that relation matches, with every variable in it bound elsewhere.
(define check-condition
  Say Relations Env [not [Rel | Terms]]
  -> (do (check-head Say Env Relations [Rel | Terms] true) Env)
  Say _ _ [not Atom] -> (error "datalog ~A: ~S is not an atom" Say Atom)
  Say Relations Env [aggregate V Op Target Atom Keys]
  -> (check-aggregate Say Relations Env V Op Target Atom Keys)
  Say _ Env Comparison -> (check-comparison Say Env Comparison))

\\ ---------------------------------------------------------------------------
\\ Aggregates: (= N (count Atom)), and (sum W Atom), (min W Atom) and (max W Atom) over a variable
\\ of the atom. A variable of the atom that appears elsewhere in the body is a key, bound first;
\\ the others are its own, and W must be one of them. Over no tuples, count and sum give 0, and min
\\ and max nothing, so that the rule does not hold. The checker turns each into [aggregate V Op
\\ Target Atom Keys], Target none for count.

(define aggregate?
  X -> (element? X [count sum min max mean]))

(define aggregate-form?
  [count _] -> true
  [Op _ _] -> (aggregate? Op)
  _ -> false)

(define aggregate-condition?
  [= A B] -> (or (aggregate-form? A) (aggregate-form? B))
  _ -> false)

(define normalize
  Say Body -> (map (/. L (if (aggregate-condition? L)
                              (normalize-aggregate Say L (remove-one L Body))
                              L))
                   Body))

(define normalize-aggregate
  Say [= [var V] Agg] Others -> (aggregate-of Say V Agg Others) where (aggregate-form? Agg)
  Say [= Agg [var V]] Others -> (aggregate-of Say V Agg Others) where (aggregate-form? Agg)
  Say L _ -> (error "datalog ~A: an aggregate stands on one side of =, with a variable on the other, not as in ~R"
                    Say (literal->form L)))

(define aggregate-of
  Say V [count Atom] Others -> (aggregate-h Say V count none Atom Others)
  Say V [Op [var T] Atom] Others -> (aggregate-h Say V Op T Atom Others)
  Say _ Agg _ -> (error "datalog ~A: ~R is not an aggregate" Say (aggregate->form Agg)))

(define aggregate-h
  Say V Op Target [Rel | Terms] Others
  -> (let Own (term-vars Terms [])
          Keys (keep-in Own (body-vars Others))
       (cases (element? V Own)
              (error "datalog ~A: ~A is what the aggregate gives, and in what it reads" Say V)
              (and (not (= Target none)) (not (element? Target Own)))
              (error "datalog ~A: ~A, which ~A reads, is not in its atom" Say Target Op)
              (element? Target Keys)
              (error "datalog ~A: ~A, which ~A reads, must appear only in its atom" Say Target Op)
              true [aggregate V Op Target [Rel | Terms] Keys]))
  Say _ _ _ Atom _ -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define keep-in
  [] _ -> []
  [X | Xs] Ys -> (if (element? X Ys) [X | (keep-in Xs Ys)] (keep-in Xs Ys)))

\\ The variables a body's literals name, in any position.
(define body-vars
  [] -> []
  [L | Ls] -> (union (literal-vars L) (body-vars Ls)))

(define literal-vars
  [not [_ | Terms]] -> (term-vars Terms [])
  [aggregate V _ _ [_ | Terms] _] -> [V | (term-vars Terms [])]
  [= A B] -> (union (aggregate-vars A) (aggregate-vars B))
  [Op A B] -> (union (expr-vars A) (expr-vars B)) where (comparison? Op)
  [_ | Terms] -> (term-vars Terms []))

(define aggregate-vars
  [count [_ | Terms]] -> (term-vars Terms [])
  [Op T [_ | Terms]] -> (union (expr-vars T) (term-vars Terms [])) where (aggregate? Op)
  E -> (expr-vars E))

\\ Its keys must be bound, its own variables are typed by its atom, and what it reads is an integer.
(define check-aggregate
  Say Relations Env V Op Target [Rel | Terms] Keys
  -> (let Unbound (difference Keys (map (function hd) Env))
          _ (if (cons? Unbound) (error "datalog ~A: ~A is not bound by an atom of the body" Say (hd Unbound)) skip)
          Inner (check-atom Say Relations Env [Rel | Terms])
          _ (if (and (not (= Target none)) (not (= (tl (assoc Target Inner)) integer)))
                (error "datalog ~A: ~A reads integers" Say Op)
                skip)
          Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) integer) Env
              true (error "datalog ~A: ~A is ~A, and an aggregate gives an integer" Say V (tl Known)))))

(define atoms
  [] -> []
  [L | Ls] -> (if (atom? L) [L | (atoms Ls)] (atoms Ls)))

(define conditions
  [] -> []
  [L | Ls] -> (if (atom? L) (conditions Ls) [L | (conditions Ls)]))

(define check-all
  _ _ Env [] -> Env
  F Say Env [L | Ls] -> (check-all F Say (F Say Env L) Ls))

\\ An atom whose variables are all bound already: a head, or one that is negated, which alone can
\\ hold _.
(define check-head
  Say Env Relations [Rel | Terms] Negated
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (check-head-terms Say Env Terms (tl Types) Negated)))
  Say _ _ Atom _ -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define check-head-terms
  _ _ [] [] _ -> true
  Say Env [[any] | Terms] [_ | Types] true -> (check-head-terms Say Env Terms Types true)
  Say _ [[any] | _] _ false -> (error "datalog ~A: a head cannot hold _" Say)
  Say _ [[any] | _] _ record -> (error "datalog ~A: a record in a negated atom cannot hold _" Say)
  Say Env [[var V] | Terms] [Type | Types] Negated
  -> (let Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) Type) (check-head-terms Say Env Terms Types Negated)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say Env [X | Terms] [Type | Types] Negated
  -> (do (check-head-terms Say Env (tl X) (fields-of Say X Type) (if (= Negated false) false record))
         (check-head-terms Say Env Terms Types Negated))
     where (cons? X)
  Say Env [X | Terms] [Type | Types] Negated
  -> (if (= (value-type X) Type)
         (check-head-terms Say Env Terms Types Negated)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define check-rule
  Name Relations Head Written
  -> (let Say (make-string "~A, rule ~R" Name (rule->form Head Written))
          Body (normalize Say Written)
          Atoms (check-all (/. S E A (check-atom S Relations E A)) Say [] (atoms Body))
          Env (check-binders Say (conditions Body) Atoms)
          _ (check-all (/. S E C (check-condition S Relations E C)) Say Env (conditions Body))
          _ (check-head Say Env Relations Head false)
       [Head Body]))

\\ Functions in rules, nested as deep as wanted: on integers, + - * / % band bor bxor bshl bshr,
\\ and on strings, (cat S T), (strlen S), (substr S Start Length), (to-number S) and (to-string N).
\\ / and % truncate toward zero, and (bshl A B) is A times 2 to the B, floored. Division by zero
\\ and to-number of what is not a number give no value, which [] stands for, as it is never one,
\\ so that the rule does not hold there; a result outside 32 bits raises.
(define arithmetic?
  X -> (element? X [+ - * / % band bor bxor bshl bshr]))

(define string-function?
  X -> (element? X [cat strlen substr to-number to-string]))

(define function?
  X -> (or (arithmetic? X) (string-function? X)))

\\ What a string function takes and gives.
(define takes
  cat -> [[string string] string]
  strlen -> [[string] integer]
  substr -> [[string integer integer] string]
  to-number -> [[string] integer]
  to-string -> [[integer] string])

(define expr-vars
  [var V] -> [V]
  [_ | Args] -> (term-vars Args [])
  _ -> [])

(define bound?
  Vars Env -> (subset? Vars (map (function hd) Env)))

\\ (= V E), where V is not bound yet and everything in E is, binds V. What binds one variable can
\\ make another's ready, so this goes on until nothing more is bound.
(define binder
  [= [var V] B] Bound -> [V B] where (and (not (element? V Bound)) (subset? (expr-vars B) Bound))
  [= A [var V]] Bound -> [V A] where (and (not (element? V Bound)) (subset? (expr-vars A) Bound))
  [aggregate V Op Target Atom Keys] Bound
  -> [V [aggregate V Op Target Atom Keys]] where (and (not (element? V Bound)) (subset? Keys Bound))
  _ _ -> none)

(define binding-type
  Say Env [aggregate | _] -> integer
  Say Env E -> (term-type Say Env E))

(define check-binders
  Say Conditions Env -> (check-binders-h Say Conditions Env Conditions false))

(define check-binders-h
  _ [] Env _ false -> Env
  Say [] Env All true -> (check-binders-h Say All Env All false)
  Say [C | Cs] Env All Progress
  -> (let B (binder C (map (function hd) Env))
       (if (= B none)
           (check-binders-h Say Cs Env All Progress)
           (check-binders-h Say Cs [[(hd B) | (binding-type Say Env (hd (tl B)))] | Env] All true))))

\\ The relations a body reads, and of those, the ones that must be complete before it runs.
(define body-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (body-relations Ls))
  [[aggregate _ _ _ [Rel | _] _] | Ls] -> (adjoin Rel (body-relations Ls))
  [L | Ls] -> (if (atom? L) (adjoin (hd L) (body-relations Ls)) (body-relations Ls)))

(define complete-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (complete-relations Ls))
  [[aggregate _ _ _ [Rel | _] _] | Ls] -> (adjoin Rel (complete-relations Ls))
  [_ | Ls] -> (complete-relations Ls))

\\ A relation cannot depend on the negation or an aggregate of one that depends on it: there would
\\ be no single answer. What each relation reaches comes from the plans' datalog.reach.
(define check-strata
  Name Relations Rules
  -> (let Graph (map (/. R [(hd R) | (depends (hd R) Rules)]) Relations)
          Reach (reach Graph)
       (map (/. R (check-rule-strata Name R Reach)) Rules)))

(define check-rule-strata
  Name [[Head | Terms] Body] Reach
  -> (map (/. N (cases (= N Head)
                       (error "datalog ~A, rule ~R: ~A depends on its own negation or aggregate"
                              Name (rule->form [Head | Terms] Body) Head)
                       (element? Head (tl (assoc N Reach)))
                       (error "datalog ~A, rule ~R: ~A depends on the negation or an aggregate of ~A, which depends on ~A"
                              Name (rule->form [Head | Terms] Body) Head N Head)
                       true ok))
          (complete-relations Body)))

\\ Each relation's stratum, as [[Rel | N] ...]: at least that of each relation its rules read, and
\\ one more than that of each they need complete: what they negate or aggregate, and a relation of
\\ one tuple a key, Keyed, read from outside its own recursion, as a better tuple can replace one.
\\ The reference evaluates by these.
(define strata
  Relations Rules Keyed
  -> (let Reach (reach (map (/. R [(hd R) | (depends (hd R) Rules)]) Relations))
       (strata-h Rules (map (/. R [(hd R) | 0]) Relations) [Keyed Reach])))

(define strata-h
  Rules S Whole -> (let Next (strata-round Rules S Whole)
                     (if (= Next S) S (strata-h Rules Next Whole))))

(define strata-round
  [] S _ -> S
  [[[Head | _] Body] | Rules] S Whole
  -> (strata-round Rules (raise Head (body-stratum Body S Head Whole) S) Whole))

(define body-stratum
  [] _ _ _ -> 0
  [[not [Rel | _]] | Ls] S H W -> (datalog.max (+ 1 (tl (assoc Rel S))) (body-stratum Ls S H W))
  [[aggregate _ _ _ [Rel | _] _] | Ls] S H W -> (datalog.max (+ 1 (tl (assoc Rel S))) (body-stratum Ls S H W))
  [[Rel | _] | Ls] S H [Keyed Reach]
  -> (datalog.max (+ 1 (tl (assoc Rel S))) (body-stratum Ls S H [Keyed Reach]))
     where (and (element? Rel Keyed) (not (element? H (tl (assoc Rel Reach)))))
  [L | Ls] S H W -> (if (atom? L)
                        (datalog.max (tl (assoc (hd L) S)) (body-stratum Ls S H W))
                        (body-stratum Ls S H W)))

(define raise
  Rel N [[Rel | M] | S] -> [[Rel | (datalog.max N M)] | S]
  Rel N [X | S] -> [X | (raise Rel N S)])

(define datalog.max
  A B -> (if (> A B) A B))

(define rules
  _ _ [] -> []
  Name Relations [[relation | _] | Items] -> (rules Name Relations Items)
  Name Relations [[type | _] | Items] -> (rules Name Relations Items)
  Name Relations [[rule Head Body] | Items]
  -> [(check-rule Name Relations Head Body) | (rules Name Relations Items)]
  Name _ [Item | _] -> (error "datalog ~A: ~S is neither a relation nor a rule" Name Item))

\\ The constants to intern: integers are themselves.
(define term-constants
  [] Acc -> Acc
  [[var _] | Ts] Acc -> (term-constants Ts Acc)
  [[any] | Ts] Acc -> (term-constants Ts Acc)
  [[_ | Args] | Ts] Acc -> (term-constants (append Args Ts) Acc)
  [X | Ts] Acc -> (term-constants Ts Acc) where (integer? X)
  [X | Ts] Acc -> (term-constants Ts (adjoin X Acc)))

(define constants
  [] Acc -> (reverse Acc)
  [[[_ | Terms] Body] | Rules] Acc
  -> (constants Rules
       (body-constants Body (term-constants Terms Acc))))

(define body-constants
  [] Acc -> Acc
  [[not [_ | Terms]] | Ls] Acc -> (body-constants Ls (term-constants Terms Acc))
  [[aggregate _ _ _ [_ | Terms] _] | Ls] Acc -> (body-constants Ls (term-constants Terms Acc))
  [[_ | Terms] | Ls] Acc -> (body-constants Ls (term-constants Terms Acc)))

\\ The relations declared as equivalences.
(define equivalences
  [] -> []
  [[relation Rel _ equivalence] | Items] -> [Rel | (equivalences Items)]
  [_ | Items] -> (equivalences Items))

\\ The relations that keep one tuple for each key, the columns before the last: [[Rel | Mode] ...],
\\ Mode min or max for the least or greatest last column, choice for the first, or [lattice F].
(define datalog.keyed
  [] -> []
  [[relation Rel _ Mode] | Items] -> [[Rel | Mode] | (datalog.keyed Items)] where (keep-mode? Mode)
  [_ | Items] -> (datalog.keyed Items))

\\ (lattice F) keeps for each key the least upper bound of its values, by F, a function of two
\\ integers that gives one: bor or band, the bit operations, which kernels compute, or the name of
\\ a Shen function, which KL calls. min and max are such too, natively.
(define keep-mode?
  [lattice F] -> (symbol? F)
  Mode -> (element? Mode [min max choice]))

\\ [program Name Relations Rules Constants Strata Constructors Equivalences Keyed].
(define datalog.check
  Name Items -> (let Types (declared-types Name Items [])
                     Relations (relations Name (map (function hd) Types) Items [])
                     Constructors (constructor-table Name Types (length Relations))
                     _ (set *constructors* Constructors)
                     Rules (rules Name Relations Items)
                     _ (check-strata Name Relations Rules)
                  [program Name Relations Rules (constants Rules [])
                   (strata Relations Rules (map (function hd) (datalog.keyed Items))) Constructors
                   (equivalences Items) (datalog.keyed Items)]))

(define datalog.define
  Name Items -> (let Program (datalog.check Name Items)
                  (do (put Name datalog.program Program)
                      (put Name schedule (make-schedule Program))
                      (put Name demands [])
                      (forget-code Name)
                      Name)))

(define forget-code
  Name -> (do (put Name compiled (shen.dict 8))
              (put Name indexes [])
              (put Name counter 0)))

(define datalog.program
  Name -> (trap-error (get Name datalog.program)
                      (/. E (error "datalog: no program ~A" Name))))

(define check-fact
  Relations Constructors [Rel | Values]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog: fact ~S has no relation" [Rel | Values])
              (not (= (length Values) (length (tl Types))))
              (error "datalog: fact ~S should have ~A values" [Rel | Values] (length (tl Types)))
              true (check-values [Rel | Values] Values (tl Types) Constructors)))
  _ _ Fact -> (error "datalog: ~S is not a fact" Fact))

(define check-values
  _ [] [] _ -> true
  Fact [V | Vs] [T | Ts] Cs -> (if (value-of? V T Cs)
                                   (check-values Fact Vs Ts Cs)
                                   (error "datalog: fact ~S has ~S in a column of type ~A" Fact V T)))

(define value-of?
  V integer _ -> (int32? V)
  V symbol _ -> (symbol? V)
  V string _ -> (string? V)
  [C | Vs] T Cs -> (let Con (assoc C Cs)
                     (and (cons? Con) (= (nth 2 Con) T) (values-of? Vs (nth 4 Con) Cs)))
  _ _ _ -> false)

(define values-of?
  [] [] _ -> true
  [V | Vs] [T | Ts] Cs -> (and (value-of? V T Cs) (values-of? Vs Ts Cs))
  _ _ _ -> false)

\\ ---------------------------------------------------------------------------
\\ Types of records: (type shape [circle integer] [rect integer integer]) declares a type and its
\\ constructors, and a value of it is a list headed by one, as [rect 2 3]; a record is a type of
\\ one constructor, and a field's type may be the type itself. A column of such a type holds the
\\ record's position in a table of its own, where a tuple is its constructor's number and its
\\ fields, as many as the widest constructor has: a record is interned, so equal records are equal
\\ words. The constructors are [[C Type Tag FieldTypes Slot Width] ...], Slot where the table is in
\\ a run's state, after the relations. Checking and generating code read them from here.

(set *constructors* [])
(set *interned-slot* 0)

(define declared-types
  _ [] Acc -> (reverse Acc)
  Name [[type T | Constructors] | Items] Acc
  -> (cases (or (not (symbol? T)) (variable? T) (element? T [symbol string integer]))
            (error "datalog ~A: ~S cannot name a type" Name T)
            (cons? (assoc T Acc)) (error "datalog ~A: type ~A is declared twice" Name T)
            (empty? Constructors) (error "datalog ~A: type ~A has no constructors" Name T)
            true (declared-types Name Items [[T | Constructors] | Acc]))
  Name [_ | Items] Acc -> (declared-types Name Items Acc))

(define constructor-table
  Name Types N -> (constructor-table-h Name Types (map (function hd) Types) (+ N 1) []))

(define constructor-table-h
  _ [] _ _ Acc -> (reverse Acc)
  Name [[T | Cs] | Types] Known Slot Acc
  -> (let Width (+ 1 (widest Cs 0))
       (constructor-table-h Name Types Known (+ Slot 1)
         (constructors-of Name T Cs 0 Known Slot Width Acc))))

(define widest
  [] N -> N
  [[_ | Fields] | Cs] N -> (widest Cs (datalog.max N (length Fields)))
  [C | _] _ -> (error "datalog: ~S is not a constructor such as [point integer integer]" C))

(define constructors-of
  _ _ [] _ _ _ _ Acc -> Acc
  Name T [[C | Fields] | Cs] Tag Known Slot Width Acc
  -> (cases (or (not (symbol? C)) (variable? C) (element? C [var any]) (function? C) (aggregate? C))
            (error "datalog ~A: ~S cannot name a constructor" Name C)
            (cons? (assoc C Acc)) (error "datalog ~A: constructor ~A is declared twice" Name C)
            (not (types? Fields Known))
            (error "datalog ~A: constructor ~A has fields ~S, which are not a list of symbol, string, integer or declared types" Name C Fields)
            true (constructors-of Name T Cs (+ Tag 1) Known Slot Width [[C T Tag Fields Slot Width] | Acc])))

(define constructor
  C -> (assoc C (value *constructors*)))

\\ The constructor of a record term, checked against its arity.
(define constructor-of
  Say [C | Args] -> (let Con (constructor C)
                      (cases (empty? Con) (error "datalog ~A: ~S is not a value" Say [C | Args])
                             (not (= (length Args) (length (nth 4 Con))))
                             (error "datalog ~A: ~A takes ~A values, not ~A" Say C (length (nth 4 Con)) (length Args))
                             true Con)))

\\ The types of a record term's fields, where a value of type Type is wanted.
(define fields-of
  Say X Type -> (let Con (constructor-of Say X)
                  (if (= (nth 2 Con) Type)
                      (nth 4 Con)
                      (error "datalog ~A: ~R is not of type ~A" Say (term->form X) Type))))

(define check-field-types
  _ _ [] [] -> true
  Say Env [A | As] [T | Ts] -> (if (= (term-type Say Env A) T)
                                   (check-field-types Say Env As Ts)
                                   (error "datalog ~A: ~R is not of type ~A" Say (term->form A) T)))

\\ ---------------------------------------------------------------------------
\\ The reference: the plain definition, over lists. Every rule runs over every tuple until a round
\\ adds nothing. It shares only the checker with what follows, and the results must agree.

(define run-naive
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Rules (nth 4 Program)
          Strata (nth 6 Program)
          Check (map (/. F (check-fact Relations (nth 7 Program) F)) Facts)
          Tables (map (/. R [(hd R)]) Relations)
          Closure (mapcan (function equivalence-rules) (nth 8 Program))
          _ (set *naive-keyed* (nth 9 Program))
       [naive Name (naive-strata 0 (highest Strata 0) (append Rules Closure) Strata
                                        (naive-add-all Facts Tables))]))

\\ What an equivalence is, as rules: reflexive, symmetric and transitive.
(define equivalence-rules
  R -> [[[R [var "X"] [var "X"]] [[R [var "X"] [any]]]]
        [[R [var "Y"] [var "X"]] [[R [var "X"] [var "Y"]]]]
        [[R [var "X"] [var "Z"]] [[R [var "X"] [var "Y"]] [R [var "Y"] [var "Z"]]]]])

\\ Each stratum's rules to a fixed point, lowest first, so that what one negates is complete.
(define naive-strata
  K Top Rules Strata Tables
  -> (if (> K Top)
         Tables
         (naive-strata (+ K 1) Top Rules Strata
           (naive-loop (in-stratum K Rules Strata) Tables))))

(define in-stratum
  _ [] _ -> []
  K [[[Head | Terms] Body] | Rules] Strata
  -> (if (= K (tl (assoc Head Strata)))
         [[[Head | Terms] Body] | (in-stratum K Rules Strata)]
         (in-stratum K Rules Strata)))

(define highest
  [] N -> N
  [[_ | M] | S] N -> (highest S (datalog.max M N)))

(define nth
  N [X | Xs] -> (if (= N 1) X (nth (- N 1) Xs)))

(define naive-add
  [Rel | Values] [[Rel | Tuples] | Tables]
  -> (let Mode (assoc Rel (value *naive-keyed*))
       (cases (element? Values Tuples) [[Rel | Tuples] | Tables]
              (empty? Mode) [[Rel Values | Tuples] | Tables]
              true [[Rel | (keep-best (tl Mode) Values Tuples)] | Tables]))
  Fact [Table | Tables] -> [Table | (naive-add Fact Tables)])

\\ A relation of one tuple a key: the new tuple in place of its key's, if it is better, or beside
\\ the others if its key has none.
(set *naive-keyed* [])

(define keep-best
  Mode Values [] -> [Values]
  Mode Values [T | Ts] -> (if (= (key-of Values) (key-of T))
                              (if (better? Mode (hd (reverse Values)) (hd (reverse T)))
                                  [(kept Mode Values T) | Ts]
                                  [T | Ts])
                              [T | (keep-best Mode Values Ts)]))

\\ What a key keeps of a better value: a lattice the bound of both.
(define kept
  [lattice F] Values T -> (append (key-of T) [(lub F (hd (reverse T)) (hd (reverse Values)))])
  _ Values _ -> Values)

(define key-of
  Values -> (reverse (tl (reverse Values))))

(define better?
  [lattice F] A B -> (not (= (lub F B A) B))
  min A B -> (< A B)
  max A B -> (> A B)
  choice _ _ -> false)

(define naive-add-all
  [] Tables -> Tables
  [F | Fs] Tables -> (naive-add-all Fs (naive-add F Tables)))

(define naive-loop
  Rules Tables -> (let Next (naive-add-all (naive-round Rules Tables []) Tables)
                    (if (= Next Tables) Tables (naive-loop Rules Next))))

(define naive-round
  [] _ Acc -> Acc
  [[Head Body] | Rules] Tables Acc
  -> (naive-round Rules Tables
       (naive-body (atoms Body) (conditions Body) Head [] Tables Acc)))

(define naive-body
  [] Conditions [Rel | Terms] Env Tables Acc
  -> (let Bound (naive-bind Conditions Env Conditions false Tables)
       (if (and (not (= Bound no)) (naive-true? Conditions Bound Tables))
           [[Rel | (map (/. T (naive-value T Bound)) Terms)] | Acc]
           Acc))
  [[Rel | Terms] | Atoms] Comparisons Head Env Tables Acc
  -> (naive-tuples (tl (assoc Rel Tables)) Terms Atoms Comparisons Head Env Tables Acc))

(define naive-tuples
  [] _ _ _ _ _ _ Acc -> Acc
  [Tuple | Tuples] Terms Atoms Comparisons Head Env Tables Acc
  -> (let Bound (naive-match Terms Tuple Env)
          More (if (= Bound no)
                   Acc
                   (naive-body Atoms Comparisons Head Bound Tables Acc))
       (naive-tuples Tuples Terms Atoms Comparisons Head Env Tables More)))

(define naive-match
  [] [] Env -> Env
  [[any] | Ts] [_ | Vs] Env -> (naive-match Ts Vs Env)
  [[var X] | Ts] [V | Vs] Env
  -> (let Known (assoc X Env)
       (cases (empty? Known) (naive-match Ts Vs [[X | V] | Env])
              (= (tl Known) V) (naive-match Ts Vs Env)
              true no))
  [[C | Args] | Ts] [V | Vs] Env
  -> (let Inner (if (and (cons? V) (= C (hd V))) (naive-match Args (tl V) Env) no)
       (if (= Inner no) no (naive-match Ts Vs Inner)))
  [C | Ts] [V | Vs] Env -> (if (= C V) (naive-match Ts Vs Env) no))

(define naive-value
  [var X] Env -> (tl (assoc X Env))
  [Op A B] Env -> (arithmetic Op (naive-value A Env) (naive-value B Env))
                  where (arithmetic? Op)
  [F | Args] Env -> (string-op F (map (/. T (naive-value T Env)) Args))
                    where (string-function? F)
  [C | Args] Env -> (let Vs (map (/. T (naive-value T Env)) Args)
                      (if (element? [] Vs) [] [C | Vs]))
  C _ -> C)

\\ What each binding condition binds, until nothing more is; once bound, it holds as a comparison.
(define naive-bind
  [] Env _ false _ -> Env
  [] Env All true Tables -> (naive-bind All Env All false Tables)
  [C | Cs] Env All Progress Tables
  -> (let B (binder C (map (function hd) Env))
          Value (if (= B none) [] (naive-bound (hd (tl B)) Env Tables))
       (cases (= B none) (naive-bind Cs Env All Progress Tables)
              (empty? Value) no
              true (naive-bind Cs [[(hd B) | Value] | Env] All true Tables))))

(define naive-bound
  [aggregate V Op Target Atom Keys] Env Tables -> (naive-aggregate Op Target Atom Env Tables)
  E Env _ -> (naive-value E Env))

\\ An aggregate over the tuples its atom matches: [], which no value is, for min or max of none.
(define naive-aggregate
  Op Target [Rel | Terms] Env Tables
  -> (let Matches (naive-matches (tl (assoc Rel Tables)) Terms Env)
          Values (if (= Target none) [] (map (/. M (tl (assoc Target M))) Matches))
       (cases (= Op count) (length Matches)
              (= Op sum) (in-range (datalog.sum Values 0))
              (empty? Values) []
              (= Op mean) (quot (datalog.sum Values 0) (length Values))
              (= Op min) (fold-pick (function <) Values)
              true (fold-pick (function >) Values))))

(define naive-matches
  [] _ _ -> []
  [Tuple | Tuples] Terms Env -> (let M (naive-match Terms Tuple Env)
                                  (if (= M no)
                                      (naive-matches Tuples Terms Env)
                                      [M | (naive-matches Tuples Terms Env)])))

(define datalog.sum
  [] Acc -> Acc
  [X | Xs] Acc -> (datalog.sum Xs (+ X Acc)))

(define fold-pick
  F [X | Xs] -> (fold-pick-h F Xs X))

(define fold-pick-h
  _ [] Best -> Best
  F [X | Xs] Best -> (fold-pick-h F Xs (if (F X Best) X Best)))

\\ Each operation on 32-bit integers raises if its result is not one; [] has no value.
(define arithmetic
  _ [] _ -> []
  _ _ [] -> []
  + A B -> (in-range (+ A B))
  - A B -> (in-range (- A B))
  * A B -> (in-range (* A B))
  / _ 0 -> []
  % _ 0 -> []
  / A B -> (in-range (quot A B))
  % A B -> (- A (* B (quot A B)))
  band A B -> (shen-jit.bit-and A B)
  bor A B -> (shen-jit.bit-or A B)
  bxor A B -> (shen-jit.bit-xor A B)
  bshl A B -> (arithmetic bshr A (- 0 B)) where (< B 0)
  bshr A B -> (arithmetic bshl A (- 0 B)) where (< B 0)
  bshl 0 _ -> 0
  bshl A B -> (in-range (shen-jit.shift-left A (if (> B 32) 32 B)))
  bshr A B -> (shen-jit.shift-right A (if (> B 31) 31 B)))

\\ A / B truncated toward zero, B not 0, by long division.
(define quot
  A B -> (let Q (floor-quot (if (< A 0) (- 0 A) A) (if (< B 0) (- 0 B) B))
           (if (= (< A 0) (< B 0)) Q (- 0 Q))))

(define floor-quot
  N D -> (if (< N D)
             0
             (let Q (floor-quot N (* 2 D))
                  R (- N (* Q (* 2 D)))
               (+ (* 2 Q) (if (< R D) 0 1)))))

\\ The string functions, on Shen's strings, by the characters pos and tlstr count; substr keeps
\\ what of its range the string has.
(define string-op
  _ Args -> [] where (element? [] Args)
  cat [A B] -> (cn A B)
  strlen [S] -> (length (explode S))
  substr [S I N] -> (substring S (if (< I 0) 0 I) N)
  to-number [S] -> (let N (parse-integer S) (if (= N []) [] (in-range N)))
  to-string [N] -> (str N))

(define substring
  S I N -> (cases (<= N 0) ""
                  (= S "") ""
                  (> I 0) (substring (tlstr S) (- I 1) N)
                  true (cn (pos S 0) (substring (tlstr S) 0 (- N 1)))))

(define parse-integer
  S -> (let Cs (explode S)
         (cases (and (cons? Cs) (= (hd Cs) "-") (cons? (tl Cs))) (negate (digits (tl Cs) 0))
                (cons? Cs) (digits Cs 0)
                true [])))

(define negate
  [] -> []
  N -> (- 0 N))

(define digits
  [] N -> N
  [C | Cs] N -> (let D (- (string->n C) 48)
                  (if (and (>= D 0) (<= D 9)) (digits Cs (+ (* 10 N) D)) [])))

(define in-range
  X -> (if (int32? X) X (error "datalog: arithmetic gave ~A, outside 32 bits" X)))

(define naive-true?
  [] _ _ -> true
  [[not [Rel | Terms]] | Rest] Env Tables
  -> (and (not (naive-any? (tl (assoc Rel Tables)) Terms Env))
          (naive-true? Rest Env Tables))
  [[aggregate V Op Target Atom Keys] | Rest] Env Tables
  -> (and (= (naive-aggregate Op Target Atom Env Tables) (tl (assoc V Env)))
          (naive-true? Rest Env Tables))
  [[Op A B] | Rest] Env Tables
  -> (and (defined-compare Op (naive-value A Env) (naive-value B Env))
          (naive-true? Rest Env Tables)))

(define naive-any?
  [] _ _ -> false
  [Tuple | Tuples] Terms Env -> (or (not (= (naive-match Terms Tuple Env) no))
                                    (naive-any? Tuples Terms Env)))

\\ A comparison, false where either side has no value.
(define defined-compare
  _ [] _ -> false
  _ _ [] -> false
  Op A B -> (datalog.compare Op A B))

(define datalog.compare
  < A B -> (< A B)
  > A B -> (> A B)
  <= A B -> (<= A B)
  >= A B -> (>= A B)
  = A B -> (= A B)
  != A B -> (not (= A B)))

\\ ---------------------------------------------------------------------------
\\ Plans. Relations are evaluated by strongly connected components, in dependency order. In a
\\ recursive component a rule has one variant per atom of that component, reading the new tuples
\\ of that atom's relation: a new derivation must use a new tuple somewhere. So that a derivation
\\ from several new tuples is made once, by the variant of the first atom to read one, the atoms
\\ of the component before it read only the old tuples, from before this round's new ones, and
\\ those after it read all.

(define depends
  Rel Rules -> (depends-h Rel Rules []))

(define depends-h
  _ [] Acc -> Acc
  Rel [[[Rel | _] Body] | Rules] Acc
  -> (depends-h Rel Rules (union (body-relations Body) Acc))
  Rel [_ | Rules] Acc -> (depends-h Rel Rules Acc))

\\ What each relation reaches, as [[Rel Reached ...] ...], grown until it stops.
(define reach
  Graph -> (let Next (map (/. Node [(hd Node) | (reach-from (tl Node) Graph (tl Node))]) Graph)
             (if (= Next Graph) Graph (reach Next))))

(define reach-from
  [] _ Acc -> Acc
  [R | Rs] Graph Acc -> (reach-from Rs Graph (union (tl (assoc R Graph)) Acc)))

(define component
  Rel Reach -> (unique [Rel | (mutual Rel (tl (assoc Rel Reach)) Reach)] []))

(define unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (unique Xs (adjoin X Acc)))

(define mutual
  _ [] _ -> []
  Rel [Rel | Rs] Reach -> (mutual Rel Rs Reach)
  Rel [R | Rs] Reach -> (if (element? Rel (tl (assoc R Reach)))
                            [R | (mutual Rel Rs Reach)]
                            (mutual Rel Rs Reach)))

(define subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (subset? Xs Ys)))

(define same-set?
  A B -> (and (subset? A B) (subset? B A)))

(define seen?
  _ [] -> false
  C [D | Ds] -> (or (same-set? C D) (seen? C Ds)))

(define distinct-sets
  [] Acc -> (reverse Acc)
  [C | Cs] Acc -> (if (seen? C Acc)
                      (distinct-sets Cs Acc)
                      (distinct-sets Cs [C | Acc])))

\\ Components with nothing left waiting go first, in the order of the declarations.
(define order
  [] _ _ Acc -> (reverse Acc)
  Waiting Reach Done Acc -> (order-h Waiting Waiting Reach Done Acc))

(define order-h
  [C | Cs] Waiting Reach Done Acc
  -> (if (subset? (difference (reached-by C Reach) C) Done)
         (order (remove C Waiting) Reach (append C Done) [C | Acc])
         (order-h Cs Waiting Reach Done Acc)))

(define reached-by
  [] _ -> []
  [R | Rs] Reach -> (union (tl (assoc R Reach)) (reached-by Rs Reach)))

(define components
  Relations Rules
  -> (let Names (map (function hd) Relations)
          Graph (map (/. R [R | (depends R Rules)]) Names)
          Reach (reach Graph)
          Cs (distinct-sets (map (/. R (component R Reach)) Names) [])
       (order Cs Reach [] [])))

(define term-vars
  [] Acc -> Acc
  [[var V] | Ts] Acc -> (term-vars Ts (adjoin V Acc))
  [[_ | Args] | Ts] Acc -> (term-vars Ts (term-vars Args Acc))
  [_ | Ts] Acc -> (term-vars Ts Acc))

(define known?
  [var V] Bound -> (element? V Bound)
  [any] _ -> false
  [_ | Args] Bound -> (all-known? Args Bound)
  _ _ -> true)

(define all-known?
  [] _ -> true
  [T | Ts] Bound -> (and (known? T Bound) (all-known? Ts Bound)))

(define known-count
  [] _ -> 0
  [T | Ts] Bound -> (if (known? T Bound)
                        (+ 1 (known-count Ts Bound))
                        (known-count Ts Bound)))

\\ The next atom. With no sizes to go by, Est is [] and it is the one with the most columns already
\\ known, and the first written of those. With sizes, the one expected to give the fewest tuples.
(define best
  [A | As] Bound [] -> (best-h As Bound A (known-count (tl A) Bound))
  [A | As] Bound Est -> (cheapest As Bound Est A (Est A Bound)))

(define best-h
  [] _ Best _ -> Best
  [A | As] Bound Best N -> (let K (known-count (tl A) Bound)
                             (if (> K N)
                                 (best-h As Bound A K)
                                 (best-h As Bound Best N))))

(define cheapest
  [] _ _ Best _ -> Best
  [A | As] Bound Est Best N -> (let K (Est A Bound)
                                 (if (< K N)
                                     (cheapest As Bound Est A K)
                                     (cheapest As Bound Est Best N))))

\\ What to do with each column of an atom: [bind V i], [check T i], [unpack Record i Binds] for a
\\ record, Binds the variables it binds, or nothing.
(define columns
  [] _ _ -> []
  [[any] | Ts] I Bound -> (columns Ts (+ I 1) Bound)
  [[var V] | Ts] I Bound
  -> (if (element? V Bound)
         [[check [var V] I] | (columns Ts (+ I 1) Bound)]
         [[bind V I] | (columns Ts (+ I 1) [V | Bound])])
  [[F | Args] | Ts] I Bound
  -> (let Binds (reverse (difference (term-vars Args []) Bound))
       [[unpack [F | Args] I Binds] | (columns Ts (+ I 1) (append Binds Bound))])
  [C | Ts] I Bound -> [[check C I] | (columns Ts (+ I 1) Bound)])

(define key-columns
  [] _ _ -> []
  [T | Ts] I Bound -> (if (known? T Bound)
                          [I | (key-columns Ts (+ I 1) Bound)]
                          (key-columns Ts (+ I 1) Bound)))

(define key-terms
  [] _ -> []
  [T | Ts] Bound -> (if (known? T Bound)
                        [T | (key-terms Ts Bound)]
                        (key-terms Ts Bound)))

(define unkey
  [] _ _ -> []
  [T | Ts] I Bound -> (if (known? T Bound)
                          [[any] | (unkey Ts (+ I 1) Bound)]
                          [T | (unkey Ts (+ I 1) Bound)]))

(define bound-after
  [] Bound -> Bound
  [[bind V _] | Cs] Bound -> (bound-after Cs [V | Bound])
  [[unpack _ _ Binds] | Cs] Bound -> (bound-after Cs (append Binds Bound))
  [_ | Cs] Bound -> (bound-after Cs Bound))

\\ The conditions that can run now, as steps, those left, and what is bound after: [Steps Left
\\ Bound]. A negated atom is [absent Rel Keys Terms]: no tuple has these terms in these columns.
\\ (= V E) whose V is not bound is [assign V E], and may make others ready.
(define ready
  Conditions Bound -> (ready-h Conditions Bound [] [] false))

(define ready-h
  [] Bound Ready Left false -> [(reverse Ready) (reverse Left) Bound]
  [] Bound Ready Left true -> (let More (ready-h (reverse Left) Bound [] [] false)
                                [(append (reverse Ready) (hd More)) | (tl More)])
  [C | Cs] Bound Ready Left Progress
  -> (let B (binder C Bound)
       (cases (subset? (condition-vars C) Bound)
              (ready-h Cs Bound [(condition-step C Bound) | Ready] Left Progress)
              (= B none)
              (ready-h Cs Bound Ready [C | Left] Progress)
              true
              (ready-h Cs [(hd B) | Bound] [(binding-step (hd B) (hd (tl B)) Bound) | Ready] Left true))))

(define condition-vars
  [not [_ | Terms]] -> (term-vars Terms [])
  [aggregate V _ _ _ Keys] -> [V | Keys]
  [_ A B] -> (union (expr-vars A) (expr-vars B)))

(define condition-step
  [not [Rel | Terms]] Bound -> [absent Rel (key-columns Terms 1 Bound) (key-terms Terms Bound)]
  [aggregate | A] Bound -> (fold-step compare [aggregate | A] Bound)
  [Op A B] _ -> [filter Op A B])

(define binding-step
  V [aggregate | A] Bound -> (fold-step bind [aggregate | A] Bound)
  V E _ -> [assign V E])

\\ [fold Mode V Op Target Rel Keys KeyTerms Columns]: the aggregate over the tuples of Rel with
\\ these terms in the Keys columns, Columns saying what to do with the rest. Mode is bind, or
\\ compare when V is bound already.
(define fold-step
  Mode [aggregate V Op Target [Rel | Terms] _] Bound
  -> [fold Mode V Op Target Rel (key-columns Terms 1 Bound) (key-terms Terms Bound)
      (columns (unkey Terms 1 Bound) 1 Bound)])

\\ Steps for the atoms left, each a scan of its tuples or a lookup by its known columns. Those in
\\ Old read the old tuples only, and the rest all.
(define plan-steps
  [] _ Comparisons Head Bound _
  -> [[emit | Head]]
  Atoms Old Comparisons Head Bound Est
  -> (let Atom (best Atoms Bound Est)
          Source (if (element? Atom Old) old all)
       (plan-atom Atom Source (remove-one Atom Atoms)
         (if (= Source old) (remove-one Atom Old) Old) Comparisons Head Bound Est)))

(define remove-one
  X [X | Xs] -> Xs
  X [Y | Xs] -> [Y | (remove-one X Xs)])

(define plan-atom
  [Rel | Terms] Source Atoms Old Comparisons Head Bound Est
  -> (let Keys (key-columns Terms 1 Bound)
       (if (empty? Keys)
           (plan-scan Rel Source Terms Atoms Old Comparisons Head Bound Est)
           (let KeyTerms (key-terms Terms Bound)
                Rest (columns (unkey Terms 1 Bound) 1 Bound)
             (plan-next [lookup Rel Source Keys KeyTerms Rest] Rest Atoms Old Comparisons Head Bound Est)))))

(define plan-scan
  Rel Source Terms Atoms Old Comparisons Head Bound Est
  -> (let Columns (columns Terms 1 Bound)
       (plan-next [scan Rel Source Columns] Columns Atoms Old Comparisons Head Bound Est)))

(define plan-next
  Step Columns Atoms Old Comparisons Head Bound Est
  -> (let Split (ready Comparisons (bound-after Columns Bound))
       [Step | (append (hd Split) (plan-steps Atoms Old (hd (tl Split)) Head (hd (tl (tl Split))) Est))]))

(define plan-rule
  [Head Body] Est
  -> (let Split (ready (conditions Body) [])
       (append (hd Split) (plan-steps (atoms Body) [] (hd (tl Split)) Head (hd (tl (tl Split))) Est))))

\\ A variant: the atom at Position reads the new tuples, and goes first, and those at the positions
\\ in Old read the old ones.
(define plan-variant
  [Head Body] Position Old Est
  -> (let Atoms (atoms Body)
          Atom (nth Position Atoms)
          Others (without Position Atoms)
          Split (ready (conditions Body) [])
       (append (hd Split)
               (plan-scan (hd Atom) new (tl Atom) Others (map (/. P (nth P Atoms)) Old)
                 (hd (tl Split)) Head (hd (tl (tl Split))) Est))))

(define without
  1 [_ | Xs] -> Xs
  N [X | Xs] -> [X | (without (- N 1) Xs)])

(define positions-in
  [] _ _ -> []
  [[Rel | _] | As] I Component
  -> (if (element? Rel Component)
         [I | (positions-in As (+ I 1) Component)]
         (positions-in As (+ I 1) Component)))

(define head-in?
  [[Rel | _] _] Component -> (element? Rel Component))

(define rules-in
  [] _ -> []
  [R | Rs] C -> (if (head-in? R C)
                    [R | (rules-in Rs C)]
                    (rules-in Rs C)))

(define rule-positions
  [_ Body] C -> (positions-in (atoms Body) 1 C))

(define first-rules
  [] _ -> []
  [R | Rs] C -> (if (empty? (rule-positions R C))
                    [R | (first-rules Rs C)]
                    (first-rules Rs C)))

(define variants
  [] _ -> []
  [R | Rs] C -> (append (rule-variants R (rule-positions R C) [])
                        (variants Rs C)))

\\ [Rule Position Old] for each of these positions, Old those before it.
(define rule-variants
  _ [] _ -> []
  R [P | Ps] Before -> [[R P Before] | (rule-variants R Ps [P | Before])])

\\ For each component [Relations First Variants]: First the rules that read nothing of the
\\ component, run once, and Variants the rest as [Rule Position Old], run until nothing is new.
\\ What order each joins in is chosen when it runs.
(define make-schedule
  [program _ Relations Rules | _]
  -> (map (/. C (let In (rules-in Rules C)
                  [C (first-rules In C) (variants In C)]))
          (components Relations Rules)))

\\ The plan with no sizes to go by.
(define datalog.plans
  Name -> (map (/. C [(hd C)
                      (map (/. R (plan-rule R [])) (hd (tl C)))
                      (map (/. V (plan-variant (hd V) (hd (tl V)) (hd (tl (tl V))) [])) (hd (tl (tl C))))])
               (get Name schedule)))

\\ ---------------------------------------------------------------------------
\\ Storage. A relation's tuples are u32 columns, one after another in a byte buffer, which the
\\ collector does not scan, and its new tuples and those for the next round are ranges of that. A
\\ table of 64-bit entries, open addressed, finds a tuple or an index's key: the top half of each is
\\ the top half of its hash, which also says where it goes when the table grows, and the bottom half
\\ is the tuple's position plus one, 0 being empty. An index's chain of tuples with one key is
\\ a u32 for each tuple, the position plus one of the next.

(define stride
  0 -> 4
  N -> (* 4 N))

(set *kernels* (shen.dict 8))

(eval-kl [defun dict-find [d k] [shen-jit.dict-find d k]])
(shen.store-arity dict-find 2)

\\ A generated kernel, once, under its name. Kernels depend only on the shape of a tuple.
(define kernel
  Name Make -> (if (cons? (dict-find (value *kernels*) Name))
                   Name
                   (do (shen-jit.install-code [defun Name (thaw Make)])
                       (shen.dict-> (value *kernels*) Name true)
                       Name)))

(define kernel-name
  Prefix N Keys -> (intern (name-with Keys (cn Prefix (str N)))))

(define name-with
  [] Name -> Name
  [K | Ks] Name -> (name-with Ks (cn Name (cn "." (str K)))))

\\ The word registers and parameters of a kernel are named, as protect writes a variable.
(define column-parameter
  I -> (intern (cn "C" (str I))))

(define upto
  I N -> (if (> I N) [] [I | (upto (+ I 1) N)]))

\\ A multiplicative hash of word expressions, whose top half is what goes in the table.
(define hash-form
  [] -> (protect K)
  [C | Cs] -> (hash-more Cs [* C (protect K)]))

(define hash-more
  [] H -> H
  [C | Cs] H -> (hash-more Cs [* [bit-xor H C] (protect K)]))

(define hash-setup
  -> [[word (protect K) [bit-or [shift-left 2654435769 32] 2135587861]]])

(define offset-form
  Base 0 -> Base
  Base Off -> [+ Base Off])

\\ Add a tuple if it is not there: 1 if it was added, 0 if not, 2 if there is no room, for which
\\ datalog.grow makes room. Meta holds the count, the table's mask, how many tuples fit and how many
\\ derivations there have been, at 0, 8, 16 and 24.
(define insert-kernel
  N -> (kernel (kernel-name "datalog.k.insert." N [])
         (freeze (insert-code N))))

(define insert-code
  N -> (table-code (kernel-name "datalog.k.insert." N []) N 1 0 2))

\\ Add a tuple to a relation of one tuple a key, as datalog.insert-kernel adds one, if its key has
\\ no tuple, or if it is better than the one it has: then the key's entry in the table at KTab moves
\\ to it, and the other stays where it is, dead. Mode is min, max or choice.
(define keyed-insert-kernel
  N Mode -> (kernel (kernel-name (cn "datalog.k.keyed-" (cn (str Mode) ".")) N [])
              (freeze (keyed-insert-code N Mode))))

(define keyed-insert-code
  N Mode
  -> (let Cols (map (function column-parameter) (upto 1 N))
          Keys (reverse (tl (reverse Cols)))
          Last (* 4 (- N 1))
       (shen-jit.assemble (kernel-name (cn "datalog.k.keyed-" (cn (str Mode) ".")) N [])
         [(protect Table) (protect Tuples) (protect Meta) (protect KTab) | Cols]
         (append (hash-setup)
           [[word (protect Count) [u64 (protect Meta) 0]]
            [u64! (protect Meta) 24 [+ [u64 (protect Meta) 24] 1]]
            [word (protect Mask) [u64 (protect Meta) 8]]
            [word (protect Kfp) [shift-right (hash-form Keys) 32]]
            [word (protect Ki) [bit-and (protect Kfp) (protect Mask)]]
            [while probe true
              [word (protect E) [u64 (protect KTab) [shift-left (protect Ki) 3]]]
              [when [= (protect E) 0] [exit probe]]
              [when [= [shift-right (protect E) 32] (protect Kfp)]
                [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (stride N)]]
                [when [and | (same-columns Keys 0)]
                  | (keyed-check Mode (hd (reverse Cols)) [s32 (protect Tuples) [+ (protect P) Last]] [return-word 0] [exit probe])]]
              [word (protect Ki) [bit-and [+ (protect Ki) 1] (protect Mask)]]]
            [word (protect Fp) [shift-right (hash-form Cols) 32]]
            [word (protect I) [bit-and (protect Fp) (protect Mask)]]
            [while true
              [word (protect Off) [shift-left (protect I) 3]]
              [word (protect E) [u64 (protect Table) (protect Off)]]
              [when [= (protect E) 0]
                [unless [< (protect Count) [u64 (protect Meta) 16]] [return-word 2]]
                [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
                [word (protect P) [* (protect Count) (stride N)]]
                [do | (store-columns Cols 0)]
                [u64! (protect Meta) 0 [+ (protect Count) 1]]
                [u64! (protect KTab) [shift-left (protect Ki) 3] [bit-or [shift-left (protect Kfp) 32] [+ (protect Count) 1]]]
                [return-word 1]]
              [when [= [shift-right (protect E) 32] (protect Fp)]
                [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (stride N)]]
                [when [and | (same-columns Cols 0)] [return-word 0]]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

\\ Statements for a key that has a tuple: Refuse, which leaves it as it is, unless the new value is
\\ better, and then Go on to add it. Under choice no value is better.
(define keyed-check
  replace _ _ _ Go -> [Go]
  choice _ _ Refuse _ -> [Refuse]
  min New Old Refuse Go -> [[unless [< [shift-right-signed [shift-left New 32] 32] Old] Refuse] Go]
  max New Old Refuse Go -> [[unless [> [shift-right-signed [shift-left New 32] 32] Old] Refuse] Go])

\\ Find a record, or add it: its position plus one, or 0 if there is no room.
(define intern-kernel
  N -> (kernel (kernel-name "datalog.k.intern." N [])
         (freeze (table-code (kernel-name "datalog.k.intern." N []) N
                   [+ (protect Count) 1] [bit-and (protect E) 4294967295] 0))))

(define table-code
  Name N Added Present Full
  -> (let Cols (map (function column-parameter) (upto 1 N))
         (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Meta) | Cols]
           (append (hash-setup)
             [[word (protect Count) [u64 (protect Meta) 0]]
              [u64! (protect Meta) 24 [+ [u64 (protect Meta) 24] 1]]
              [word (protect Fp) [shift-right (hash-form Cols) 32]]
              [word (protect Mask) [u64 (protect Meta) 8]]
              [word (protect I) [bit-and (protect Fp) (protect Mask)]]
              [while true
                [word (protect Off) [shift-left (protect I) 3]]
                [word (protect E) [u64 (protect Table) (protect Off)]]
                [when [= (protect E) 0]
                  [unless [< (protect Count) [u64 (protect Meta) 16]] [return-word Full]]
                  [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
                  [word (protect P) [* (protect Count) (stride N)]]
                  [do | (store-columns Cols 0)]
                  [u64! (protect Meta) 0 [+ (protect Count) 1]]
                  [return-word Added]]
                [when [= [shift-right (protect E) 32] (protect Fp)]
                  [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (stride N)]]
                  [when [and | (same-columns Cols 0)] [return-word Present]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

(define store-columns
  [] _ -> []
  [C | Cs] Off -> [[u32! (protect Tuples) (offset-form (protect P) Off) C]
                   | (store-columns Cs (+ Off 4))])

\\ Tests that the tuple at P holds these values.
(define same-columns
  [] _ -> []
  [C | Cs] Off -> [[= [u32 (protect Tuples) (offset-form (protect P) Off)] C]
                   | (same-columns Cs (+ Off 4))])

\\ Where these key values are in a table: the position plus one of the tuple there, or 0.
(define find-kernel
  N Keys -> (kernel (kernel-name "datalog.k.find." N Keys)
              (freeze (find-code N Keys))))

(define key-offsets
  Keys -> (map (/. K (* 4 (- K 1))) Keys))

(define same-keys
  [] [] -> []
  [Off | Offs] [C | Cs]
  -> [[= [u32 (protect Tuples) (offset-form (protect P) Off)] C] | (same-keys Offs Cs)])

(define find-code
  N Keys
  -> (let Cols (map (function column-parameter) (upto 1 (length Keys)))
          Name (kernel-name "datalog.k.find." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Mask) | Cols]
         (append (hash-setup)
           [[word (protect Fp) [shift-right (hash-form Cols) 32]]
            [word (protect I) [bit-and (protect Fp) (protect Mask)]]
            [while true
              [word (protect E) [u64 (protect Table) [shift-left (protect I) 3]]]
              [when [= (protect E) 0] [return-word 0]]
              [when [= [shift-right (protect E) 32] (protect Fp)]
                [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (stride N)]]
                [when [and | (same-keys (key-offsets Keys) Cols)]
                  [return-word [bit-and (protect E) 4294967295]]]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

\\ Adds the tuples from From up to To to an index, whose table has room, and gives how many keys
\\ were new. A tuple goes at the head of its key's chain.
(define index-kernel
  N Keys -> (kernel (kernel-name "datalog.k.index." N Keys)
              (freeze (index-code N Keys))))

(define tuple-columns
  [] _ -> []
  [Off | Offs] Base -> [[u32 (protect Tuples) (offset-form Base Off)] | (tuple-columns Offs Base)])

\\ Tests that the tuples at Q and Base have the same keys.
(define same-tuples
  [] -> []
  [Off | Offs]
  -> [[= [u32 (protect Tuples) (offset-form (protect Q) Off)]
         [u32 (protect Tuples) (offset-form (protect Base) Off)]]
      | (same-tuples Offs)])

(define index-code
  N Keys
  -> (let Offs (key-offsets Keys)
          Name (kernel-name "datalog.k.index." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Next) (protect Tuples) (protect Mask) (protect From) (protect To)]
         (append (hash-setup)
           [[word (protect D) 0]
            [word (protect Mk) (protect Mask)]
            [for (protect Pos) (protect From) (protect To)
              [word (protect Base) [* (protect Pos) (stride N)]]
              [word (protect Fp) [shift-right (hash-form (tuple-columns Offs (protect Base))) 32]]
              [word (protect I) [bit-and (protect Fp) (protect Mk)]]
              [while probe true
                [word (protect Off) [shift-left (protect I) 3]]
                [word (protect E) [u64 (protect Table) (protect Off)]]
                [when [= (protect E) 0]
                  [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Pos) 1]]]
                  [u32! (protect Next) [shift-left (protect Pos) 2] 0]
                  [word (protect D) [+ (protect D) 1]]
                  [exit probe]]
                [when [= [shift-right (protect E) 32] (protect Fp)]
                  [word (protect Q) [* [- [bit-and (protect E) 4294967295] 1] (stride N)]]
                  [when [and | (same-tuples Offs)]
                    [u32! (protect Next) [shift-left (protect Pos) 2] [bit-and (protect E) 4294967295]]
                    [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Pos) 1]]]
                    [exit probe]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mk)]]]]
            [return-word (protect D)]]))))

\\ Moves a table's entries to a larger one.
(define rehash-code
  -> (shen-jit.assemble k.rehash [(protect New) (protect Old) (protect Mask) (protect Size)]
       [[word (protect Mk) (protect Mask)]
        [for (protect J) 0 (protect Size)
          [word (protect E) [u64 (protect Old) [shift-left (protect J) 3]]]
          [unless [= (protect E) 0]
            [word (protect I) [bit-and [shift-right (protect E) 32] (protect Mk)]]
            [while place true
              [word (protect Off) [shift-left (protect I) 3]]
              [when [= [u64 (protect New) (protect Off)] 0]
                [u64! (protect New) (protect Off) (protect E)]
                [exit place]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mk)]]]]]
        [return-word 0]]))

(kernel k.rehash (freeze (rehash-code)))

\\ A relation's record: 0 where its indexes end, 1 those in use, 2 its tuples, 3 its table, 4 its
\\ meta, 5 and 6 the tuples that are new, by position, those before 6 being all that a round reads,
\\ 7 the bytes of a tuple, 8 an equivalence's classes, a table by key for a relation of one tuple a
\\ key, its entries as the relation's own table's and as many, or 0, 9 the merges its tuples came in, and
\\ each index from 10, by a number kept with the program across runs. A run starts only those it
\\ looks up. An index is a vector of its table, chain, mask and keys.
\\ Kind is true for an equivalence, keyed for a relation of one tuple a key, or false.
(define new-relation
  Arity Kind
  -> (let Room (+ 10 (shen-jit.shift-left 1 (if (> Arity 6) 6 Arity)))
          R (absvector Room)
          Stride (stride Arity)
          Meta (shen-jit.bytes 32)
          _ (shen-jit.s64! Meta 8 15)
          _ (shen-jit.s64! Meta 16 8)
          _ (address-> R 0 Room)
          _ (address-> R 1 [])
          _ (address-> R 2 (shen-jit.bytes (* 8 Stride)))
          _ (address-> R 3 (shen-jit.bytes (* 16 8)))
          _ (address-> R 4 Meta)
          _ (address-> R 5 0)
          _ (address-> R 6 0)
          _ (address-> R 7 Stride)
          _ (address-> R 8 (cases (= Kind keyed) (shen-jit.bytes (* 16 8)) Kind (new-classes) true 0))
          _ (address-> R 9 [])
       R))

(define count-of
  Rec -> (shen-jit.s64 (<-address Rec 4) 0))

\\ A larger table, its entries moved.
(define larger-table
  Old OldSize NewSize
  -> (let New (shen-jit.bytes (* 8 NewSize))
          _ (k.rehash New Old (- NewSize 1) OldSize)
       New))

\\ Room for at least one more tuple, in the buffer and at half full in the table.
(define datalog.grow
  Rec
  -> (let Meta (<-address Rec 4)
          Count (shen-jit.s64 Meta 0)
          Stride (<-address Rec 7)
          Tuples (<-address Rec 2)
          Fits (/ (shen-jit.bytes-length Tuples) Stride)
          Size (+ 1 (shen-jit.s64 Meta 8))
          NewFits (if (>= Count Fits) (* 2 Fits) Fits)
          NewSize (if (>= (* 2 Count) Size) (* 2 Size) Size)
          _ (if (= NewFits Fits)
                skip
                (address-> Rec 2 (shen-jit.copy-bytes (shen-jit.bytes (* NewFits Stride)) 0 Tuples 0 (* Count Stride))))
          _ (if (= NewSize Size)
                skip
                (do (address-> Rec 3 (larger-table (<-address Rec 3) Size NewSize))
                    (if (shen-jit.bytes? (<-address Rec 8))
                        (address-> Rec 8 (larger-table (<-address Rec 8) Size NewSize))
                        skip)
                    (shen-jit.s64! Meta 8 (- NewSize 1))))
          _ (shen-jit.s64! Meta 16 (let Half (shen-jit.shift-right NewSize 1) (if (< Half NewFits) Half NewFits)))
       true))

\\ ---------------------------------------------------------------------------
\\ Generating KL. The relations' records and the values are in a vector S, read by position.

(define position
  X [X | _] N -> N
  X [_ | Ys] N -> (position X Ys (+ N 1)))

(define relation-slot
  Rel Relations -> (position Rel (map (function hd) Relations) 1))

(define index-slot
  Rel Keys Indexes -> (position Keys (tl (assoc Rel Indexes)) 10))

(define steps-indexes
  [] _ Acc -> Acc
  [Step | Steps] Relations Acc
  -> (let Index (step-index Step Relations)
       (steps-indexes Steps Relations
         (if (= Index none) Acc (add-index (hd Index) (hd (tl Index)) Acc)))))

\\ Keys that are every column need no index: the relation's own table finds them. A negated atom
\\ with no keys needs only to know whether the relation is empty.
(define whole-tuple?
  Rel Keys Relations -> (= (length Keys) (arity-in Rel Relations)))

\\ The index a step looks up, as [Rel Keys], or none.
(define step-index
  [lookup Rel _ Keys | _] Relations -> (index-of Rel Keys Relations)
  [absent Rel Keys | _] Relations -> (index-of Rel Keys Relations)
  [fold _ _ _ _ Rel Keys | _] Relations -> (index-of Rel Keys Relations)
  _ _ -> none)

(define index-of
  Rel Keys Relations -> (if (or (empty? Keys) (whole-tuple? Rel Keys Relations) (equivalence? Rel))
                            none
                            [Rel Keys]))

\\ The equivalences of the program whose code is being made or prepared: they are read from their
\\ classes, by the steps below, and have no index.
(set *equivalences* [])

(define equivalence?
  Rel -> (element? Rel (value *equivalences*)))

(define arity-in
  Rel Relations -> (- (length (assoc Rel Relations)) 1))

(define add-index
  Rel Keys [] -> [[Rel Keys]]
  Rel Keys [[Rel | Ks] | Rest] -> [[Rel | (if (element? Keys Ks) Ks (append Ks [Keys]))] | Rest]
  Rel Keys [Other | Rest] -> [Other | (add-index Rel Keys Rest)])

\\ A term's word: an integer's 32 bits, or an interned value's number.
(define value-form
  [var V] _ -> (var-symbol V)
  C _ -> (int-word C) where (integer? C)
  E Constants -> [intern-string s (value *interned-slot*) (string-form E Constants)]
                 where (string-expression? E)
  E Constants -> [word-of (number-form E Constants)] where (kl-only-term? E)
  E Constants -> [int-word (number-form E Constants)] where (expression? E)
  [F | Args] Constants
  -> (let Con (constructor F)
          Words (pad [(nth 3 Con) | (map (/. T (value-form T Constants)) Args)] (nth 6 Con))
       [record-id s (nth 5 Con) (list-form Words)])
  C Constants -> (position C Constants 0))

(define word-of
  [] -> []
  N -> (int-word N))

(define list-form
  [] -> []
  [X | Xs] -> [cons X (list-form Xs)])

\\ A record term, as data: not a variable, _ or arithmetic.
(define record-term?
  [F | _] -> (not (or (element? F [var any]) (function? F)))
  _ -> false)

\\ Whether a type has more than one constructor, so that its records' tags need checking.
(define tagged?
  T -> (> (length (mapcan (/. C (if (= (hd (tl C)) T) [C] [])) (value *constructors*))) 1))

(define var-symbol
  V -> (intern (cn "V" V)))

\\ An integer term's value, signed, from its word.
(define number-form
  [var V] _ -> (let W (var-symbol V) [if [> W 2147483647] [- W 4294967296] W])
  [Op A B] Constants -> [in-range [Op (number-form A Constants) (number-form B Constants)]]
                        where (and (element? Op [+ - *]) (not (kl-only-term? [Op A B])))
  [Op A B] Constants -> [arithmetic Op (number-form A Constants) (number-form B Constants)]
                        where (arithmetic? Op)
  [F | Args] Constants -> (string-call F Args Constants)
  C _ -> C)

\\ A string term's value, the string itself.
(define string-form
  [var V] _ -> [<-vector [<-address s 0] [+ (var-symbol V) 1]]
  [F | Args] Constants -> (string-call F Args Constants)
  C _ -> C)

(define string-call
  F Args Constants
  -> [string-op F (list-form (map (/. P (if (= (hd P) string)
                                                          (string-form (tl P) Constants)
                                                          (number-form (tl P) Constants)))
                                                 (pairs (hd (takes F)) Args)))])

(define pairs
  [] [] -> []
  [X | Xs] [Y | Ys] -> [[X | Y] | (pairs Xs Ys)])

(define expression?
  [Op | _] -> (function? Op)
  _ -> false)

\\ Whether an expression gives a string.
(define string-expression?
  [Op | _] -> (element? Op [cat substr to-string])
  _ -> false)

\\ Values of one type are equal when their words are; an expression is compared as a number.
(define filter-form
  Op A B Constants -> [defined-compare Op (side-form A B Constants) (side-form B A Constants)]
                      where (or (kl-only-term? A) (kl-only-term? B))
  = A B Constants -> [= (value-form A Constants) (value-form B Constants)]
                     where (or (string-expression? A) (string-expression? B))
  = A B Constants -> [= (number-form A Constants) (number-form B Constants)]
                     where (or (expression? A) (expression? B))
  != A B Constants -> [not (filter-form = A B Constants)]
  = A B Constants -> [= (value-form A Constants) (value-form B Constants)]
  Op A B Constants -> [Op (number-form A Constants) (number-form B Constants)])

\\ One side of a comparison: a number if either side is arithmetic, and otherwise a word.
(define side-form
  A B Constants -> (number-form A Constants)
                   where (and (or (expression? A) (expression? B))
                              (not (string-expression? A)) (not (string-expression? B)))
  A _ Constants -> (value-form A Constants))

\\ What [assign V E] binds V to: a word, as a column would hold.
(define assign-form
  E Constants -> (value-form E Constants))

(define step-uses
  [filter _ A B] -> (union (expr-vars A) (expr-vars B))
  [assign _ E] -> (expr-vars E)
  [fold bind _ _ _ _ _ Terms _] -> (term-vars Terms [])
  [fold compare V _ _ _ _ Terms _] -> (adjoin V (term-vars Terms []))
  [absent _ _ Terms] -> (term-vars Terms [])
  [emit _ | Terms] -> (term-vars Terms [])
  [scan _ _ Columns] -> (columns-use Columns)
  [lookup _ _ _ Terms Columns] -> (term-vars Terms (columns-use Columns)))

(define columns-use
  [] -> []
  [[check T _] | Cs] -> (term-vars [T] (columns-use Cs))
  [[unpack T _ Binds] | Cs] -> (union (difference (term-vars [T] []) Binds) (columns-use Cs))
  [_ | Cs] -> (columns-use Cs))

(define step-binds
  [scan _ _ Columns] -> (columns-bind Columns)
  [lookup _ _ _ _ Columns] -> (columns-bind Columns)
  [assign V _] -> [V]
  [fold bind V | _] -> [V]
  _ -> [])

(define columns-bind
  [] -> []
  [[bind V _] | Cs] -> [V | (columns-bind Cs)]
  [[unpack _ _ Binds] | Cs] -> (append Binds (columns-bind Cs))
  [_ | Cs] -> (columns-bind Cs))

\\ What the steps need from before them, for the parameters of a loop.
(define live
  [] -> []
  [Step | Steps] -> (union (step-uses Step)
                           (difference (live Steps) (step-binds Step))))

(define loop-name
  Prefix N -> (intern (cn Prefix (cn ".s" (str N)))))

(define loop-live
  Columns Steps
  -> (map (function var-symbol)
          (difference (union (columns-use Columns) (live Steps))
                      (columns-bind Columns))))

\\ Add a tuple to the relation in r, growing it if it must. Its first attempt found no room and
\\ changed nothing, so that a second is the whole of it.
(define insert-form
  N Forms [lattice F]
  -> (let Keys (reverse (tl (reverse Forms)))
          Find (find-kernel N (upto 1 (- N 1)))
          Replace (/. Value (insert-form N (append Keys [Value]) replace))
       [let k [Find [<-address r 8] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Keys]
         [if [= k 0]
             (Replace (hd (reverse Forms)))
             [let old [shen-jit.u32 [<-address r 2] [+ [* [- k 1] [<-address r 7]] (* 4 (- N 1))]]
               [let j [int-word (if (element? F [bor band])
                                            [arithmetic F [word-int old] [word-int (hd (reverse Forms))]]
                                            [in-range [F [word-int old] [word-int (hd (reverse Forms))]]])]
                 [if [= j old] 0 (Replace j)]]]]])
  N Forms Mode
  -> (let Call (if (= Mode none)
                   [(insert-kernel N) [<-address r 3] [<-address r 2] [<-address r 4] | Forms]
                   [(keyed-insert-kernel N Mode) [<-address r 3] [<-address r 2] [<-address r 4] [<-address r 8] | Forms])
       [let x Call [if [= x 2] [do [datalog.grow r] Call] x]]))

\\ How a relation keeps its tuples, by the program whose code is being made: min, max, choice or
\\ none.
(set *keyed* [])

(define keyed-mode
  Rel -> (let Entry (assoc Rel (value *keyed*)) (if (empty? Entry) none (tl Entry))))

\\ A lattice's least upper bound of two integers, checked to be 32 bits.
(define lub
  F A B -> (arithmetic F A B) where (element? F [bor band])
  F A B -> (in-range ((fn F) A B)))

\\ Lattices that kernels join: those of the bit operations.
(define native-lattice?
  [lattice F] -> (element? F [bor band])
  _ -> false)

\\ Adds a value to a lattice's key, as the KL of datalog.insert-form does inline: the key's tuple is
\\ replaced by one of the least upper bound of the two values, unless that is what it has. 1 if the
\\ relation changed, and 0 if not.
(define lattice-insert
  Rec F Words
  -> (let N (length Words)
          Keys (reverse (tl (reverse Words)))
          P ((key-finder N) Rec Keys)
          Replace (adder-for N replace)
       (if (= P 0)
           (Replace Rec Words)
           (let Old (shen-jit.u32 (<-address Rec 2) (+ (* (- P 1) (<-address Rec 7)) (* 4 (- N 1))))
                Join (int-word (lub F (word-int Old) (word-int (hd (reverse Words)))))
             (if (= Join Old) 0 (Replace Rec (append Keys [Join])))))))

\\ The expression for these steps. Each atom's loop is a function of its own, so that it is a
\\ self tail call and named in a backtrace; those go to datalog.*forms*. Ctx is Relations,
\\ Constants and Indexes. A loop keeps the buffer it started with: a round can only add to a
\\ relation it reads, what it reads is already in that buffer, and growing leaves it as it is.
(define gen
  [] _ _ _ -> true
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (relation-slot Rel Relations)]
       (gen-pairs [eq-pairs r Source [] []] Columns Steps [Relations Constants Indexes] Prefix N)]
     where (equivalence? Rel)
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (relation-slot Rel Relations)]
       (gen-pairs [eq-pairs r Source (list-form Keys) (list-form (map (/. T (value-form T Constants)) Terms))]
         Columns Steps [Relations Constants Indexes] Prefix N)]
     where (equivalence? Rel)
  [[absent Rel Keys Terms] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (relation-slot Rel Relations)]
       [if (if (empty? Keys)
               [> [<-address [<-address r 8] 8] 0]
               [cons? [eq-pairs r all (list-form Keys) (list-form (map (/. T (value-form T Constants)) Terms))]])
           true
           (gen Steps [Relations Constants Indexes] Prefix N)]]
     where (equivalence? Rel)
  [[filter Op A B] | Steps] Ctx Prefix N
  -> [if (filter-form Op A B (nth 2 Ctx)) (gen Steps Ctx Prefix N) true]
  [[assign V E] | Steps] Ctx Prefix N
  -> [let x (assign-form E (nth 2 Ctx))
       [if [= x []] true [let (var-symbol V) x (gen Steps Ctx Prefix N)]]]
     where (kl-only-term? E)
  [[assign V E] | Steps] Ctx Prefix N
  -> [let (var-symbol V) (assign-form E (nth 2 Ctx)) (gen Steps Ctx Prefix N)]
  [[fold Mode V Op Target Rel Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Ctx [Relations Constants Indexes]
          Rest (gen Steps Ctx Prefix (+ N 1))
       [let r [<-address s (relation-slot Rel Relations)]
         [let a (fold-form Op Target Rel Keys Terms Columns Ctx Prefix N)
           (cases (= Mode compare) [if [= (if (= Op sum) [in-range a] a) (number-form [var V] Constants)] Rest true]
                  (element? Op [min max mean]) [if [= a none] true [let (var-symbol V) [int-word a] Rest]]
                  true [let (var-symbol V) [int-word [in-range a]] Rest])]])
  [[absent Rel Keys Terms] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (relation-slot Rel Relations)]
       [if (found-form Rel Keys Terms [Relations Constants Indexes])
           true
           (gen Steps [Relations Constants Indexes] Prefix N)]]
  [[emit Rel | Terms] | _] [Relations Constants Indexes] _ _
  -> [let r [<-address s (relation-slot Rel Relations)]
       (insert-form (arity-in Rel Relations)
         (map (/. T (value-form T Constants)) Terms) (keyed-mode Rel))]
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Stride (stride (arity-in Rel Relations))
          Start (if (= Source new) [* [<-address r 5] Stride] 0)
          End (if (= Source old) [* [<-address r 5] Stride] [* [<-address r 6] Stride])
       [let r [<-address s (relation-slot Rel Relations)]
         (gen-scan Start End Stride Columns Steps [Relations Constants Indexes] Prefix N)])
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Forms (map (/. T (value-form T Constants)) Terms)
          Find (find-kernel (arity-in Rel Relations) Keys)
          Ctx [Relations Constants Indexes]
       [let r [<-address s (relation-slot Rel Relations)]
         (if (whole-tuple? Rel Keys Relations)
             [let p [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms]
               [if [and [> p 0] [<= p [<-address r (if (= Source old) 5 6)]]]
                   (gen Steps Ctx Prefix N)
                   true]]
             (let Field (index-slot Rel Keys Indexes)
                  Stride (stride (arity-in Rel Relations))
                  First [Find [<-address i 0] [<-address r 2] [<-address i 2] | Forms]
               [let i [<-address r Field]
                 [let p (if (= Source old) [skip-chain First [<-address i 1] [<-address r 5]] First)
                   [if [> p 0]
                       (gen-chain Stride Columns Steps Ctx Prefix N)
                       true]]]))]))

\\ Whether the relation in r has a tuple with these terms in these columns.
(define found-form
  _ [] _ _ -> [> [<-address r 6] 0]
  Rel Keys Terms [Relations Constants Indexes]
  -> (let Forms (map (/. T (value-form T Constants)) Terms)
          Find (find-kernel (arity-in Rel Relations) Keys)
       (if (whole-tuple? Rel Keys Relations)
           [> [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms] 0]
           (let I [<-address r (index-slot Rel Keys Indexes)]
             [> [Find [<-address I 0] [<-address r 2] [<-address I 2] | Forms] 0]))))

\\ A loop over the pairs of an equivalence that List gives, as [X Y] words.
(define gen-pairs
  List Columns Steps Ctx Prefix N
  -> (let Name (loop-name Prefix N)
          Live (loop-live Columns Steps)
          Body (gen-columns Columns [eq [hd [hd l]] [hd [tl [hd l]]]] (nth 2 Ctx) (gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [l s | Live]
                 [if [cons? l]
                     [do Body [Name [tl l] s | Live]]
                     true]]
          _ (set *forms* [Form | (value *forms*)])
       [Name List s | Live]))

\\ A loop over the tuples from byte Start to byte End of the relation in r.
(define gen-scan
  Start End Stride Columns Steps Ctx Prefix N
  -> (let Name (loop-name Prefix N)
          Live (loop-live Columns Steps)
          Body (gen-columns Columns l (nth 2 Ctx) (gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [l e b s | Live]
                 [if [< l e]
                     [do Body [Name [+ l Stride] e b s | Live]]
                     true]]
          _ (set *forms* [Form | (value *forms*)])
       [Name Start End [<-address r 2] s | Live]))

\\ The first of a chain's tuples, given as position plus one, from before position Limit: a chain
\\ runs from the newest.
(define skip-chain
  P Next Limit -> (if (> P Limit) (skip-chain (shen-jit.u32 Next (* 4 (- P 1))) Next Limit) P))

\\ A loop along a chain, from p and the index in i of the relation in r.
(define gen-chain
  Stride Columns Steps Ctx Prefix N
  -> (let Name (loop-name Prefix N)
          Live (loop-live Columns Steps)
          Body (gen-columns Columns l (nth 2 Ctx) (gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [p n b s | Live]
                 [if [> p 0]
                     [let q [- p 1]
                       [let l [* q Stride]
                         [do Body [Name [shen-jit.u32 n [* q 4]] n b s | Live]]]]
                     true]]
          _ (set *forms* [Form | (value *forms*)])
       [Name p [<-address i 1] [<-address r 2] s | Live]))

(define column-form
  [eq X _] 1 -> X
  [eq _ Y] 2 -> Y
  Base I -> [shen-jit.u32 b (if (= I 1) Base [+ Base (* 4 (- I 1))])])

\\ In order, as a check reads only what a column before it bound.
(define gen-columns
  Columns Base Constants Inner -> (gen-columns-or Columns Base Constants Inner true))

\\ The same, giving Otherwise when a check fails.
(define gen-columns-or
  [] _ _ Inner _ -> Inner
  [[bind V I] | Cs] Base Constants Inner Otherwise
  -> [let (var-symbol V) (column-form Base I) (gen-columns-or Cs Base Constants Inner Otherwise)]
  [[check Term I] | Cs] Base Constants Inner Otherwise
  -> [if [= (column-form Base I) (value-form Term Constants)]
         (gen-columns-or Cs Base Constants Inner Otherwise)
         Otherwise]
  [[unpack Term I Binds] | Cs] Base Constants Inner Otherwise
  -> (gen-unpack [Term] [(column-form Base I)] Binds Constants
       (gen-columns-or Cs Base Constants Inner Otherwise) Otherwise))

\\ Terms matched against these words: a record's fields are read from its table once its tag is
\\ checked, and a variable in Binds is bound where it first appears.
(define gen-unpack
  [] [] _ _ Inner _ -> Inner
  [[any] | Ts] [_ | Ws] Binds Constants Inner Otherwise -> (gen-unpack Ts Ws Binds Constants Inner Otherwise)
  [[var V] | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> [let (var-symbol V) W (gen-unpack Ts Ws (remove V Binds) Constants Inner Otherwise)]
     where (element? V Binds)
  [[F | Args] | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> (let Con (constructor F)
          Id (gensym w)
          Stride (stride (nth 6 Con))
          Tuples [<-address [<-address s (nth 5 Con)] 2]
          Fields (map (/. J [shen-jit.u32 Tuples [+ [* Id Stride] (* 4 J)]]) (upto 1 (length Args)))
          Rest (gen-unpack (append Args Ts) (append Fields Ws) Binds Constants Inner Otherwise)
       [let Id W (if (tagged? (nth 2 Con))
                     [if [= [shen-jit.u32 Tuples [* Id Stride]] (nth 3 Con)] Rest Otherwise]
                     Rest)])
     where (record-term? [F | Args])
  [T | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> [if [= W (value-form T Constants)] (gen-unpack Ts Ws Binds Constants Inner Otherwise) Otherwise])

\\ An aggregate's accumulator a, given the next value t: none until min or max has seen one.
(define datalog.mean
  _ 0 -> none
  Sum Count -> (quot Sum Count))

(define fold-init
  count -> 0
  sum -> 0
  _ -> none)

(define fold-update
  count _ -> [+ a 1]
  sum T -> [+ a T]
  min T -> [let t T [if [= a none] t [if [< t a] t a]]]
  max T -> [let t T [if [= a none] t [if [> t a] t a]]])

\\ What a fold gives: a loop over the relation in r, or for a whole tuple's keys whether it is
\\ there.
(define fold-form
  Op Target Rel Keys Terms Columns [Relations Constants Indexes] Prefix N
  -> (let Name (loop-name Prefix N)
          Update (fold-update Op (if (= Target none) 0 (number-form [var Target] Constants)))
          Body (gen-columns-or Columns [eq [hd [hd l]] [hd [tl [hd l]]]] Constants Update a)
          _ (set *forms* [[defun Name [l s a] [if [cons? l] [Name [tl l] s Body] a]] | (value *forms*)])
          Call [Name [eq-pairs r all (list-form Keys) (list-form (map (/. T (value-form T Constants)) Terms))]
                     s (fold-init Op)]
       Call)
     where (and (equivalence? Rel) (not (= Op mean)))
  mean Target Rel Keys Terms Columns Ctx Prefix N
  -> [datalog.mean (fold-form sum Target Rel Keys Terms Columns Ctx Prefix N)
                   (fold-form count none Rel Keys Terms Columns Ctx (cn Prefix "m") N)]
  Op Target Rel Keys Terms Columns [Relations Constants Indexes] Prefix N
  -> (let Stride (stride (arity-in Rel Relations))
          Update (fold-update Op (if (= Target none) 0 (number-form [var Target] Constants)))
          Name (loop-name Prefix N)
          Body (gen-columns-or Columns l Constants Update a)
       (cases (empty? Keys)
              (do (set *forms* [[defun Name [l e b s a]
                                          [if [< l e] [Name [+ l Stride] e b s Body] a]]
                                        | (value *forms*)])
                  [Name 0 [* [<-address r 6] Stride] [<-address r 2] s (fold-init Op)])
              (whole-tuple? Rel Keys Relations)
              [if (found-form Rel Keys Terms [Relations Constants Indexes]) 1 0]
              true
              (let Forms (map (/. T (value-form T Constants)) Terms)
                   Find (find-kernel (arity-in Rel Relations) Keys)
                   _ (set *forms* [[defun Name [p n b s a]
                                             [if [> p 0]
                                                 [let q [- p 1] [let l [* q Stride] [Name [shen-jit.u32 n [* q 4]] n b s Body]]]
                                                 a]]
                                           | (value *forms*)])
                [let i [<-address r (index-slot Rel Keys Indexes)]
                  [Name [Find [<-address i 0] [<-address r 2] [<-address i 2] | Forms]
                        [<-address i 1] [<-address r 2] s (fold-init Op)]]))))

(define gen-plan
  Steps Ctx Prefix
  -> (let Name (intern Prefix)
          Body (gen Steps Ctx Prefix 1)
          Form [defun Name [s] Body]
          _ (set *forms* [Form | (value *forms*)])
       Name))

(define next-name
  Name
  -> (let N (get Name counter)
          _ (put Name counter (+ N 1))
       (cn "datalog." (cn (str Name) (cn ".p" (str N))))))

\\ Generated functions are called from here as closures, which need no arity or lambda table entry.
(define callable
  Name -> (eval-kl [lambda x [Name x]]))

\\ A kernel's form shows what it was written as; it is installed already.
(define install
  Forms -> (map (/. F (if (= (hd F) define-native) skip (eval-kl F))) Forms))

\\ The code for these steps, kept with the program, as [Closure | Forms]. There are only so many
\\ orders a rule can join in.
(define compiled
  Name Steps Relations Constants
  -> (let Cache (get Name compiled)
          Entry (dict-find Cache Steps)
       (if (cons? Entry)
           (tl Entry)
           (let Ctx [Relations Constants (get Name indexes)]
                _ (set *constructors* (nth 7 (datalog.program Name)))
                _ (set *keyed* (nth 9 (datalog.program Name)))
                _ (set *equivalences* (nth 8 (datalog.program Name)))
                _ (set *interned-slot* (interned-slot Relations (value *constructors*)))
                Prefix (next-name Name)
                Fn (gen-either Steps Ctx Prefix)
                Forms (reverse (value *forms*))
                _ (install Forms)
                Code [(callable Fn) | Forms]
                _ (shen.dict-> Cache Steps Code)
             Code))))

\\ ---------------------------------------------------------------------------
\\ Native joins. A plan becomes one kernel of word registers, written with lib/native.shen's
\\ structured control, which looks up, compares and inserts inline and calls nothing. A variable
\\ costs no register: it is read from its tuple's column where it is used. When a relation it adds
\\ to has no room, the kernel gives where its outer loop stood, plus one, and a KL function grows
\\ the relation and calls it again from there, as deriving a tuple twice does no harm. A plan the
\\ registers cannot hold, or anything else the assembler refuses, stays KL.

(set *native* true)
(set *fallbacks* 0)
(set *labels* 0)

(define gen-either
  Steps Ctx Prefix
  -> (if (and (value *native*) (not (kl-only? Steps)))
         (trap-error (do (set *forms* []) (native-plan Steps Ctx Prefix))
                     (/. E (do (set *fallbacks* (+ 1 (value *fallbacks*)))
                               (set *forms* [])
                               (gen-plan Steps Ctx Prefix))))
         (do (set *forms* []) (gen-plan Steps Ctx Prefix))))

\\ Plans that divide, shift by other than a constant from 0 to 31, take a mean, work on strings or
\\ add to a lattice are KL: a kernel has no division, cannot intern or call a lattice's function,
\\ and has no way to say that a value is missing.
(define kl-only?
  [] -> false
  [[emit Rel | _] | _] -> (and (cons? (keyed-mode Rel)) (not (native-lattice? (keyed-mode Rel))))
  [[filter _ A B] | Steps] -> (or (kl-only-term? A) (kl-only-term? B) (kl-only? Steps))
  [[assign _ E] | Steps] -> (or (kl-only-term? E) (kl-only? Steps))
  [[fold _ _ mean | _] | _] -> true
  [_ | Steps] -> (kl-only? Steps))

(define kl-only-term?
  [Op A B] -> (or (not (integer? B)) (< B 0) (> B 31) (kl-only-term? A)) where (element? Op [bshl bshr])
  [Op | Args] -> (or (element? Op [/ % cat strlen substr to-number to-string])
                     (some? (function kl-only-term?) Args))
                 where (function? Op)
  [F | Args] -> (some? (function kl-only-term?) Args) where (record-term? [F | Args])
  _ -> false)

(define some?
  _ [] -> false
  F [X | Xs] -> (or (F X) (some? F Xs)))

(define word-name
  Prefix N -> (intern (cn Prefix (str N))))

\\ A kernel's parameter, as [Name | KL form computing it from s and start], each once.
(define param
  Name Form -> (do (if (cons? (assoc Name (value *params*)))
                       skip
                       (set *params* (append (value *params*) [[Name | Form]])))
                   Name))

(define record-form
  Slot -> [<-address s Slot])

(define tuples-param
  Slot -> (param (word-name "Tup" Slot) [<-address (record-form Slot) 2]))

(define mask
  -> 4294967295)

\\ The word a term stands for: an integer's 32 bits, or an interned value.
(define native-value
  [var V] Env _ -> (tl (assoc V Env))
  C _ _ -> (int-word C) where (integer? C)
  C _ Constants -> (position C Constants 0))

\\ The integer a term stands for, signed: a column read as such, or a word's low half extended.
(define native-integer
  [var V] Env _ -> (signed (tl (assoc V Env)))
  C _ _ -> C)

(define signed
  [u32 Tuples Off] -> [s32 Tuples Off]
  [bit-and R 4294967295] -> R
  W -> [shift-right-signed [shift-left W 32] 32])

\\ A comparison, as statements that compute its expressions and the test after them.
(define native-test
  Op A B Env Ctx Outer
  -> (let Parts (native-terms [A B] Env Ctx Outer)
       [(hd Parts) [Op (hd (hd (tl Parts))) (hd (tl (hd (tl Parts))))]])
     where (and (element? Op [= !=]) (not (expression? A)) (not (expression? B)))
  Op A B Env Ctx _ -> (let L (native-operand A Env Ctx 1)
                         R (native-operand B Env Ctx 2)
                      [(append (hd L) (hd R)) [Op (hd (tl L)) (hd (tl R))]]))

\\ An integer operand as [Statements Form]: an expression is computed into Arith<D>, with what
\\ its operands need from Arith<D+1> on, so that the second operand leaves the first alone.
(define native-operand
  E Env Ctx D -> (let T (word-name "Arith" D)
                   [(native-compute E Env Ctx T (+ D 1)) T])
                 where (expression? E)
  E Env Ctx _ -> [[] (native-integer E Env Ctx)])

(define native-compute
  [Op A B] Env Ctx Target D
  -> (let L (native-operand A Env Ctx D)
          R (native-operand B Env Ctx (+ D 1))
       (append (hd L) (hd R)
               [[word Target [(native-op Op) (hd (tl L)) (hd (tl R))]]
                [unless [u< [+ Target 2147483648] 4294967296] [return-word (overflow-code)]]])))

(define native-op
  band -> bit-and
  bor -> bit-or
  bxor -> bit-xor
  bshl -> shift-left
  bshr -> shift-right-signed
  Op -> Op)

\\ What a kernel returns when arithmetic leaves 32 bits: more than any place to start again from.
(define overflow-code
  -> 1099511627776)

(define overflowed
  -> (error "datalog: arithmetic gave a value outside 32 bits"))

\\ Columns of the tuple whose first byte is Base in Tuples.
(define column-word
  _ [eq X _] 1 -> X
  _ [eq _ Y] 2 -> Y
  Tuples Base I -> [u32 Tuples (offset-form Base (* 4 (- I 1)))])

\\ The variables an atom's columns bind, as the words that read them where used, and the checks
\\ on the rest, in order, as [Env Checks]: a check reads only what came before it, and a record's
\\ fields are read only once its tag is checked, as a field of another constructor may not be a
\\ record at all.
(define native-columns
  [] _ _ Env _ Checks -> [Env (reverse Checks)]
  [[bind V I] | Cs] Tuples Base Env Constants Checks
  -> (native-columns Cs Tuples Base [[V | (column-word Tuples Base I)] | Env] Constants Checks)
  [[check T I] | Cs] Tuples Base Env Constants Checks
  -> (native-columns Cs Tuples Base Env Constants
       [[= (column-word Tuples Base I) (native-value T Env Constants)] | Checks])
  [[unpack T I Binds] | Cs] Tuples Base Env Constants Checks
  -> (let Done (native-unpack [T] [(column-word Tuples Base I)] Binds Env Constants Checks)
       (native-columns Cs Tuples Base (hd Done) Constants (tl Done))))

\\ Terms matched against these words, as [Env | Checks].
(define native-unpack
  [] [] _ Env _ Checks -> [Env | Checks]
  [[any] | Ts] [_ | Ws] Binds Env Constants Checks -> (native-unpack Ts Ws Binds Env Constants Checks)
  [[var V] | Ts] [W | Ws] Binds Env Constants Checks
  -> (native-unpack Ts Ws (remove V Binds) [[V | W] | Env] Constants Checks) where (element? V Binds)
  [[F | Args] | Ts] [W | Ws] Binds Env Constants Checks
  -> (let Con (constructor F)
          Tuples (tuples-param (nth 5 Con))
          Base [* W (stride (nth 6 Con))]
          Fields (map (/. J [u32 Tuples [+ Base (* 4 J)]]) (upto 1 (length Args)))
          Tag (if (tagged? (nth 2 Con)) [[= [u32 Tuples Base] (nth 3 Con)]] [])
       (native-unpack (append Args Ts) (append Fields Ws) Binds Env Constants (append Tag Checks)))
     where (record-term? [F | Args])
  [T | Ts] [W | Ws] Binds Env Constants Checks
  -> (native-unpack Ts Ws Binds Env Constants [[= W (native-value T Env Constants)] | Checks]))

\\ Words for these terms, as [Statements Forms]: a record is made first, found or added in its
\\ table, into a register of its own.
(define native-terms
  [] _ _ _ -> [[] []]
  [T | Ts] Env Ctx Outer
  -> (let A (cases (record-term? T) (native-make T Env Ctx Outer)
                   (expression? T) (let R (native-label "Num")
                                             [(native-compute T Env Ctx R 1) [bit-and R 4294967295]])
                   true [[] (native-value T Env (hd (tl Ctx)))])
          B (native-terms Ts Env Ctx Outer)
       [(append (hd A) (hd B)) [(hd (tl A)) | (hd (tl B))]]))

(define native-make
  [F | Args] Env Ctx Outer
  -> (let Con (constructor F)
          Parts (native-terms Args Env Ctx Outer)
          Slot (nth 5 Con)
          R (native-label "Rec")
          _ (set *made* (adjoin Slot (value *made*)))
          Loop (native-label "make")
       [(append (hd Parts)
                (native-store Slot (stride (nth 6 Con))
                  (pad [(nth 3 Con) | (hd (tl Parts))] (nth 6 Con))
                  (again-code Outer) Loop
                  [[word R (protect Count)]]
                  [[word R [- [bit-and (protect E) (mask)] 1]]]))
        R]))

\\ Statements for these steps. Outer is the outermost scan's position, from which a kernel without
\\ room starts again; none before the first step, and restart when that step is not a scan.
(define native-steps
  [] _ _ _ _ -> []
  [[scan Rel Source Columns] | Steps] Ctx Env Level Outer
  -> (native-class-scan Rel Source Columns Steps Ctx Env Level Outer) where (equivalence? Rel)
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Parts (native-terms Terms Env [Relations Constants Indexes N] Outer)
       (append (hd Parts)
               (native-class-lookup Rel Source Keys (hd (tl Parts)) Columns Steps [Relations Constants Indexes N] Env Level
                 (outer Outer))))
     where (equivalence? Rel)
  [[filter Op A B] | Steps] Ctx Env Level Outer
  -> (let Test (native-test Op A B Env Ctx Outer)
       (append (hd Test) [[when (hd (tl Test)) | (native-steps Steps Ctx Env Level Outer)]]))
  [[assign V E] | Steps] [Relations Constants | More] Env Level Outer
  -> (cases (expression? E)
            (let Target (intern (cn "Val." V))
              (append (native-compute E Env [Relations Constants | More] Target 1)
                      (native-steps Steps [Relations Constants | More]
                        [[V | [bit-and Target 4294967295]] | Env] Level Outer)))
            (record-term? E)
            (let Made (native-make E Env [Relations Constants | More] Outer)
              (append (hd Made)
                      (native-steps Steps [Relations Constants | More] [[V | (hd (tl Made))] | Env] Level Outer)))
            true
            (native-steps Steps [Relations Constants | More]
              [[V | (native-value E Env Constants)] | Env] Level Outer))
  [[absent Rel Keys Terms] | Steps] Ctx Env Level Outer
  -> (native-class-absent Rel Keys Terms Steps Ctx Env Level Outer) where (equivalence? Rel)
  [[absent Rel Keys Terms] | Steps] Ctx Env Level Outer
  -> (native-absent Rel Keys Terms Steps Ctx Env Level Outer)
  [[fold Mode V Op Target Rel Keys Terms Columns] | Steps] Ctx Env Level Outer
  -> (native-fold [Mode V Op Target Rel Keys Terms Columns] Steps Ctx Env Level Outer)
  [[emit Rel | Terms] | _] Ctx Env _ Outer -> (native-insert Rel Terms Ctx Env Outer)
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Stride (stride (arity-in Rel Relations))
          Tuples (tuples-param Slot)
          From (if (and (= Outer none) (= Level 1))
                   (param (intern "Start") start)
                   (param (word-name "From" Level) (if (= Source new) [<-address (record-form Slot) 5] 0)))
          To (if (= Source old)
                 (old-param Slot)
                 (param (word-name "To" Level) [<-address (record-form Slot) 6]))
          P (word-name "P" Level)
          B (word-name "B" Level)
          Cols (native-columns Columns Tuples B Env Constants [])
       [[for P From To
          [word B [* P Stride]]
          | (guarded (hd (tl Cols))
              (native-steps Steps Ctx (hd Cols) (+ Level 1) (if (and (= Outer none) (= Level 1)) P (outer Outer))))]])
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Parts (native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
       (append (hd Parts)
               (if (whole-tuple? Rel Keys Relations)
                   (native-member Rel Source Slot Values Steps Ctx Env Level (outer Outer))
                   (native-chain Rel Source Slot Keys Values Columns Steps Ctx Env Level (outer Outer))))))

\\ Where the old tuples of the relation in Slot end, by position.
(define old-param
  Slot -> (param (word-name "Old" Slot) [<-address (record-form Slot) 5]))

\\ The classes of an equivalence, as kernels read them: X's words, a value at a position's byte B and
\\ its ranges after it, and H's table and mask.
(define class-params
  Slot -> (let C [<-address (record-form Slot) 8]
            [(param (word-name "Cx" Slot) [<-address C 3])
             (param (word-name "Ch" Slot) [<-address C 4])
             (param (word-name "Cm" Slot) [<-address C 5])
             (param (word-name "Cn" Slot) [<-address C 6])
             (param (word-name "Cc" Slot) [<-address C 7])]))

\\ Statements that run Inner for each position Q the value at byte B pairs with, from all, old or
\\ new pairs: its class's range, its old part's, or the class's less the part's. The ranges are read
\\ where used, which costs loads and saves registers, of which a kernel has 16.
(define class-range
  X B all Q Inner -> [[for Q [u32 X [+ B 4]] [u32 X [+ B 8]] | Inner]]
  X B old Q Inner -> [[for Q [u32 X [+ B 12]] [u32 X [+ B 16]] | Inner]]
  X B new Q Inner -> [[for Q [u32 X [+ B 4]] [u32 X [+ B 8]]
                        [unless [and [>= Q [u32 X [+ B 12]]] [< Q [u32 X [+ B 16]]]] | Inner]]])

\\ Every pair, old pair or new one: each value, of those that changed for new ones, and each it
\\ pairs with.
(define native-class-scan
  Rel Source Columns Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Params (class-params Slot)
          X (hd Params)
          P (word-name "P" Level)
          Q (word-name "Eq" Level)
          From (cases (and (= Outer none) (= Level 1)) (param (intern "Start") start)
                      (= Source new) (nth 5 Params)
                      true 0)
          To (nth 4 Params)
          Cols (native-columns Columns X [eq [u32 X [* P 20]] [u32 X [* Q 20]]] Env Constants [])
       [[for P From To
          | (class-range X [* P 20] Source Q
              (guarded (hd (tl Cols))
                (native-steps Steps Ctx (hd Cols) (+ Level 1) (if (and (= Outer none) (= Level 1)) P (outer Outer)))))]]))

\\ The pairs with a known column: the value's position by H, and those it pairs with; or for both,
\\ whether they are in one class, or one old part, which needs the positions only for the test, so
\\ that they share registers with other steps'.
(define native-class-lookup
  Rel Source Keys Values Columns Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Params (class-params Slot)
          X (hd Params)
          B (word-name "B" Level)
          Q (word-name "Eq" Level)
          V (hd Values)
       (if (= Keys [1 2])
           (let Same (if (= Source old)
                         [and [>= (protect Cb) [* [u32 X [+ (protect Ca) 12]] 20]] [< (protect Cb) [* [u32 X [+ (protect Ca) 16]] 20]]]
                         [= [u32 X [+ (protect Cb) 4]] [u32 X [+ (protect Ca) 4]]])
             (class-probe (native-label "probe") V Params (protect Ca)
               (class-probe (native-label "probe") (hd (tl Values)) Params (protect Cb)
                 [[when Same | (native-steps Steps Ctx Env (+ Level 1) Outer)]])))
           (let Cols (native-columns Columns X (if (= Keys [1]) [eq V [u32 X [* Q 20]]] [eq [u32 X [* Q 20]] V]) Env Constants [])
             (class-probe (word-name "probe" Level) V Params B
               (class-range X B Source Q
                 (guarded (hd (tl Cols)) (native-steps Steps Ctx (hd Cols) (+ Level 1) Outer))))))))

\\ Found, with B the byte of V's position, if the classes have V, and then the probe ends, unless
\\ Found leaves already.
(define class-probe
  Probe V [X H Mask | _] B Found
  -> (probe-loop Probe [V] H Mask B 20 [[= [u32 X B] V]]
       (if (= (hd (hd (reverse Found))) exit) Found (append Found [[exit Probe]]))))

\\ Found if two values are in one class: by their positions, whose classes start at one place.
(define class-pair
  [V W] [X | Params] Found
  -> (class-probe (native-label "probe") V [X | Params] (protect Ca)
       (class-probe (native-label "probe") W [X | Params] (protect Cb)
         [[when [= [u32 X [+ (protect Cb) 4]] [u32 X [+ (protect Ca) 4]]] | Found]])))

\\ The steps after a negated atom of an equivalence, which no pair matches: none at all, none of a
\\ value in no class, and none of two values in two.
(define native-class-absent
  Rel Keys Terms Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Params (class-params (relation-slot Rel Relations))
          Rest (native-steps Steps Ctx Env Level Outer)
          Parts (native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
          Block (native-label "absent")
       (append (hd Parts)
               (cases (empty? Keys) [[when [= (nth 4 Params) 0] | Rest]]
                      (= Keys [1 2]) [[block Block | (append (class-pair Values Params [[exit Block]]) Rest)]]
                      true [[block Block | (append (class-probe (native-label "probe") (hd Values) Params
                                                     (protect Ca) [[exit Block]])
                                                   Rest)]]))))

\\ Only a scan at the outermost level can start again partway: below any other step, a kernel with
\\ no room starts again from the beginning.
(define outer
  none -> restart
  Outer -> Outer)

\\ The tuple these values make, if the relation has it, by its own table.
(define native-member
  Rel Source Slot Values Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Stride (stride (arity-in Rel Relations))
          Tuples (tuples-param Slot)
          Table (param (word-name "Tab" Slot) [<-address (record-form Slot) 3])
          Mask (param (word-name "Mask" Slot) [shen-jit.u32 [<-address (record-form Slot) 4] 8])
          Q (word-name "Q" Level)
          Probe (word-name "probe" Level)
          Same (equal-columns Tuples Q Values 1)
          Limit (if (= Source old)
                    (old-param Slot)
                    (param (word-name "Merged" Slot) [<-address (record-form Slot) 6]))
       (probe-loop Probe Values Table Mask Q Stride [[<= [bit-and (protect E) (mask)] Limit] | Same]
         [[do | (native-steps Steps [Relations Constants Indexes N] Env (+ Level 1) Outer)]
          [exit Probe]])))

\\ A table's probe for these values: Q is the byte of each tuple with their fingerprint, Matches
\\ whether it has them, and Found what follows if it does, which leaves the loop itself.
(define probe-loop
  Probe Values Table Mask Q Stride Matches Found
  -> [[word (protect Fp) [shift-right (hash-form Values) 32]]
      [word (protect I) [bit-and (protect Fp) Mask]]
      [while Probe true
        [word (protect E) [u64 Table [shift-left (protect I) 3]]]
        [when [= (protect E) 0] [exit Probe]]
        [when [= [shift-right (protect E) 32] (protect Fp)]
          [word Q [* [- [bit-and (protect E) (mask)] 1] Stride]]
          [when [and | Matches] | Found]]
        [word (protect I) [bit-and [+ (protect I) 1] Mask]]]])

\\ The steps after a negated atom, in a block that a tuple it matches leaves: by the relation's own
\\ table for a whole tuple, an index's table for some columns, and its size for none.
(define native-absent
  Rel Keys Terms Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Rest (native-steps Steps Ctx Env Level Outer)
          Parts (native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
          Stride (stride (arity-in Rel Relations))
          Tuples (tuples-param Slot)
          Block (native-label "absent")
          Q (word-name "Q" Level)
       (append (hd Parts) (cases (empty? Keys)
              [[when [= (param (word-name "Size" Slot) [<-address (record-form Slot) 6]) 0] | Rest]]
              (whole-tuple? Rel Keys Relations)
              [[block Block
                 | (append (probe-loop (native-label "probe") Values
                             (param (word-name "Tab" Slot) [<-address (record-form Slot) 3])
                             (param (word-name "Mask" Slot) [shen-jit.u32 [<-address (record-form Slot) 4] 8])
                             Q Stride (equal-columns Tuples Q Values 1) [[exit Block]])
                           Rest)]]
              true
              (let Field (index-slot Rel Keys Indexes)
                   Index [<-address (record-form Slot) Field]
                [[block Block
                   | (append (probe-loop (native-label "probe") Values
                               (param (index-name "Itab" Slot Field) [<-address Index 0])
                               (param (index-name "Imask" Slot Field) [<-address Index 2])
                               Q Stride (equal-keys Tuples Q Keys Values) [[exit Block]])
                             Rest)]])))))

(define index-name
  Prefix Slot Field -> (intern (cn Prefix (cn (str Slot) (cn "x" (str Field))))))

\\ An aggregate in a register of its own, by a loop over the relation, a probe of its table for a
\\ whole tuple's keys, or a probe of an index and its chain; then the steps after it. min and max
\\ start from just outside 32 bits, where they stay if there was nothing.
(define native-fold
  [Mode V Op Target Rel Keys Terms Columns] Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (relation-slot Rel Relations)
          Stride (stride (arity-in Rel Relations))
          Tuples (tuples-param Slot)
          Acc (native-label "Agg")
          Parts (native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
          P (word-name "P" Level)
          Q (word-name "Q" Level)
          Update (/. T B (let Cols (native-columns Columns T B Env Constants [])
                           (guarded (hd (tl Cols))
                             (native-fold-update Op Acc (if (= Target none) 0 (native-integer [var Target] (hd Cols) Ctx))))))
          Loop (cases (equivalence? Rel) (class-fold-loop Slot Keys Values Update Level)
                      (empty? Keys)
                      [[for P 0 (param (word-name "Size" Slot) [<-address (record-form Slot) 6])
                         [word Q [* P Stride]] | (Update Tuples Q)]]
                      (whole-tuple? Rel Keys Relations)
                      (let Probe (native-label "probe")
                        (probe-loop Probe Values
                          (param (word-name "Tab" Slot) [<-address (record-form Slot) 3])
                          (param (word-name "Mask" Slot) [shen-jit.u32 [<-address (record-form Slot) 4] 8])
                          Q Stride (equal-columns Tuples Q Values 1) [[word Acc 1] [exit Probe]]))
                      true
                      (let Field (index-slot Rel Keys Indexes)
                           Index [<-address (record-form Slot) Field]
                           Probe (native-label "probe")
                        [[word P 0]
                         | (append (probe-loop Probe Values
                                     (param (index-name "Itab" Slot Field) [<-address Index 0])
                                     (param (index-name "Imask" Slot Field) [<-address Index 2])
                                     Q Stride (equal-keys Tuples Q Keys Values)
                                     [[word P [bit-and (protect E) (mask)]] [exit Probe]])
                                   [[while (native-label "chain") [> P 0]
                                      [word Q [* [- P 1] Stride]]
                                      [do | (Update Tuples Q)]
                                      [word P [u32 (param (index-name "Inext" Slot Field) [<-address Index 1])
                                                   [shift-left [- P 1] 2]]]]])]))
          Checked (if (= Op sum)
                      [[unless [u< [+ Acc 2147483648] 4294967296] [return-word (overflow-code)]]]
                      [])
          Bound [[V | [bit-and Acc 4294967295]] | Env]
          After (cases (= Mode compare)
                       [[when [= Acc (native-integer [var V] Env Ctx)] | (native-steps Steps Ctx Env Level Outer)]]
                       (element? Op [min max])
                       [[when [!= Acc (fold-start Op)] | (native-steps Steps Ctx Bound Level Outer)]]
                       true (native-steps Steps Ctx Bound Level Outer))
       (append (hd Parts) [[word Acc (fold-start Op)] | (append Loop (append Checked After))])))

\\ A fold over an equivalence's pairs: every position and its class, a value's class, or two values'
\\ one pair.
(define class-fold-loop
  Slot Keys Values Update Level
  -> (let Params (class-params Slot)
          X (hd Params)
          P (word-name "P" Level)
          Q (word-name "Eq" Level)
          B (word-name "B" Level)
       (cases (empty? Keys)
              [[for P 0 (nth 4 Params)
                 | (class-range X [* P 20] all Q (Update X [eq [u32 X [* P 20]] [u32 X [* Q 20]]]))]]
              (= Keys [1 2]) (class-pair Values Params (Update X [eq (hd Values) (hd (tl Values))]))
              true (class-probe (native-label "probe") (hd Values) Params B
                     (class-range X B all Q
                       (Update X (if (= Keys [1]) [eq (hd Values) [u32 X [* Q 20]]] [eq [u32 X [* Q 20]] (hd Values)])))))))

(define fold-start
  min -> 2147483648
  max -> -2147483649
  _ -> 0)

(define native-fold-update
  count Acc _ -> [[word Acc [+ Acc 1]]]
  sum Acc T -> [[word Acc [+ Acc T]]]
  min Acc T -> [[when [< T Acc] [word Acc T]]]
  max Acc T -> [[when [> T Acc] [word Acc T]]])

\\ A name for a block or loop, of its own within a kernel.
(define native-label
  Kind -> (do (set *labels* (+ 1 (value *labels*)))
              (intern (cn Kind (cn "." (str (value *labels*)))))))

(define equal-columns
  _ _ [] _ -> []
  Tuples Base [V | Vs] I -> [[= (column-word Tuples Base I) V] | (equal-columns Tuples Base Vs (+ I 1))])

(define equal-keys
  _ _ [] [] -> []
  Tuples Base [K | Ks] [V | Vs] -> [[= (column-word Tuples Base K) V] | (equal-keys Tuples Base Ks Vs)])

\\ The tuples with these values for Keys, through an index: its table finds the first, and its chain
\\ the rest.
(define native-chain
  Rel Source Slot Keys Values Columns Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Stride (stride (arity-in Rel Relations))
          Field (index-slot Rel Keys Indexes)
          Index [<-address (record-form Slot) Field]
          Tuples (tuples-param Slot)
          Table (param (index-name "Itab" Slot Field) [<-address Index 0])
          Next (param (index-name "Inext" Slot Field) [<-address Index 1])
          Mask (param (index-name "Imask" Slot Field) [<-address Index 2])
          P (word-name "P" Level)
          Q (word-name "Q" Level)
          Probe (word-name "probe" Level)
          Chain (word-name "chain" Level)
          Cols (native-columns Columns Tuples Q Env Constants [])
       [[word P 0]
        | (append
            (probe-loop Probe Values Table Mask Q Stride (equal-keys Tuples Q Keys Values)
              [[word P [bit-and (protect E) (mask)]] [exit Probe]])
            (append
              (if (= Source old)
                  [[while (native-label "skip") [> P (old-param Slot)]
                     [word P [u32 Next [shift-left [- P 1] 2]]]]]
                  [])
              [[while Chain [> P 0]
                [word Q [* [- P 1] Stride]]
                [do | (guarded (hd (tl Cols)) (native-steps Steps Ctx (hd Cols) (+ Level 1) Outer))]
                [word P [u32 Next [shift-left [- P 1] 2]]]]]))]))

\\ Statements that run only when these checks hold.
(define guarded
  [] Statements -> Statements
  Checks Statements -> [[when [and | Checks] | Statements]])

\\ Adds the tuple these values make, as datalog.insert-kernel does, or gives where to start again.
(define native-insert
  Rel Terms [Relations Constants Indexes N] Env Outer
  -> (let Parts (native-terms Terms Env [Relations Constants Indexes N] Outer)
          Slot (relation-slot Rel Relations)
          Stride (stride (arity-in Rel Relations))
          Mode (keyed-mode Rel)
       (append (hd Parts)
               (if (= Mode none)
                   (native-store Slot Stride (hd (tl Parts)) (again-code Outer) insert [] [])
                   (native-keyed-store Slot Stride (hd (tl Parts)) (again-code Outer) Mode)))))

\\ As datalog.keyed-insert-kernel, inline.
(define native-keyed-store
  Slot Stride Values Again [lattice Op]
  -> (let Keys (reverse (tl (reverse Values)))
       [[word (protect Kv) (hd (reverse Values))]
        | (native-keyed-probe Slot Stride (append Keys [(protect Kv)]) Again
            (/. Old Keep Add [[word (protect Kj) [(native-op Op) Old (protect Kv)]]
                              [when [= (protect Kj) Old] Keep]
                              [word (protect Kv) (protect Kj)]
                              Add]))])
  Slot Stride Values Again Mode
  -> (native-keyed-probe Slot Stride Values Again
       (/. Old Keep Add (keyed-check Mode (hd (reverse Values)) [shift-right-signed [shift-left Old 32] 32] Keep Add))))

\\ The probe of the table by key, then the insert. Check gives the statements for a key that has a
\\ tuple, given the word of its value and two exits: Keep leaves the tuple as it is, and Add goes on
\\ to add the new one.
(define native-keyed-probe
  Slot Stride Values Again Check
  -> (let Tuples (tuples-param Slot)
          KTab (param (word-name "Ktab" Slot) [<-address (record-form Slot) 8])
          Meta (param (word-name "Meta" Slot) [<-address (record-form Slot) 4])
          Keys (reverse (tl (reverse Values)))
          Block (native-label "keyed")
          Probe (native-label "probe")
       [[block Block
          [word (protect Kfp) [shift-right (hash-form Keys) 32]]
          [word (protect Ki) [bit-and (protect Kfp) [u64 Meta 8]]]
          [while Probe true
            [word (protect E) [u64 KTab [shift-left (protect Ki) 3]]]
            [when [= (protect E) 0] [exit Probe]]
            [when [= [shift-right (protect E) 32] (protect Kfp)]
              [word (protect Pe) [* [- [bit-and (protect E) (mask)] 1] Stride]]
              [when [and | (equal-columns Tuples (protect Pe) Keys 1)]
                | (Check [u32 Tuples [+ (protect Pe) (* 4 (length Keys))]] [exit Block] [exit Probe])]]
            [word (protect Ki) [bit-and [+ (protect Ki) 1] [u64 Meta 8]]]]
          | (native-store Slot Stride Values Again (native-label "insert")
              [[u64! KTab [shift-left (protect Ki) 3] [bit-or [shift-left (protect Kfp) 32] [+ (protect Count) 1]]]]
              [])]]))

\\ What a kernel with no room returns: where to start again from, plus one.
(define again-code
  Outer -> (if (element? Outer [none restart]) 1 [+ Outer 1]))

\\ Adds the tuple of these values to the relation in Slot if it is not there, in a loop named Loop,
\\ which runs Added or Found before it leaves, or returns Again if there is no room.
(define native-store
  Slot Stride Values Again Loop Added Found
  -> (let Tuples (tuples-param Slot)
          Table (param (word-name "Tab" Slot) [<-address (record-form Slot) 3])
          Meta (param (word-name "Meta" Slot) [<-address (record-form Slot) 4])
       [[word (protect Count) [u64 Meta 0]]
        [u64! Meta 24 [+ [u64 Meta 24] 1]]
        [word (protect Fp) [shift-right (hash-form Values) 32]]
        [word (protect I) [bit-and (protect Fp) [u64 Meta 8]]]
        [while Loop true
          [word (protect E) [u64 Table [shift-left (protect I) 3]]]
          [when [= (protect E) 0]
            [unless [< (protect Count) [u64 Meta 16]] [return-word Again]]
            [u64! Table [shift-left (protect I) 3] [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
            [word (protect Pe) [* (protect Count) Stride]]
            [do | (store-values Tuples Values 0)]
            [u64! Meta 0 [+ (protect Count) 1]]
            | (append Added [[exit Loop]])]
          [when [= [shift-right (protect E) 32] (protect Fp)]
            [word (protect Pe) [* [- [bit-and (protect E) (mask)] 1] Stride]]
            [when [and | (equal-columns Tuples (protect Pe) Values 1)] | (append Found [[exit Loop]])]]
          [word (protect I) [bit-and [+ (protect I) 1] [u64 Meta 8]]]]]))

(define store-values
  _ [] _ -> []
  Tuples [V | Vs] Off -> [[u32! Tuples (offset-form (protect Pe) Off) V] | (store-values Tuples Vs (+ Off 4))])

(set *made* [])

\\ Grows each relation a kernel adds to, the head and the tables of records it makes.
(define grow-forms
  [Slot] -> [datalog.grow [<-address s Slot]]
  [Slot | Slots] -> [do [datalog.grow [<-address s Slot]] (grow-forms Slots)])

(define head-slot
  [] _ -> (simple-error "datalog: a plan with no head")
  [[emit Rel | _] | _] Relations -> (relation-slot Rel Relations)
  [_ | Steps] Relations -> (head-slot Steps Relations))

\\ The kernel, and the KL that calls it: W starts it where its first loop starts, and W.go grows the
\\ relation it adds to and calls it again for as long as it runs out of room.
(define native-plan
  Steps [Relations Constants Indexes] Prefix
  -> (let N (length Relations)
          Ctx [Relations Constants Indexes N]
          _ (set *params* [])
          _ (set *labels* 0)
          _ (set *made* [])
          Body (native-steps Steps Ctx [] 1 none)
          Params (value *params*)
          Kernel (intern (cn Prefix ".k"))
          Written (append (hash-setup) Body [[return-word 0]])
          Code (shen-jit.assemble Kernel (map (function hd) Params) Written)
          _ (shen-jit.install-code [defun Kernel Code])
          Name (intern Prefix)
          Go (intern (cn Prefix ".go"))
          Head (head-slot Steps Relations)
          First (first-start Steps Relations)
          Call [Kernel | (map (function tl) Params)]
          GoForm [defun Go [s start]
                   [let x Call
                     [cond [[= x 0] true]
                           [[= x (overflow-code)] [overflowed]]
                           [true [do (grow-forms [Head | (value *made*)]) [Go s [- x 1]]]]]]]
          Entry [defun Name [s] [Go s First]]
          _ (set *forms* [Entry GoForm [define-native Kernel (map (function hd) Params) | Written]
                                  | (value *forms*)])
       Name))

\\ Where the first loop starts: the new tuples or all of them; 0 if the plan begins with no loop.
(define first-start
  [[scan Rel new _] | _] Relations -> [<-address [<-address [<-address s (relation-slot Rel Relations)] 8] 7]
                                       where (equivalence? Rel)
  [[scan Rel new _] | _] Relations -> [<-address [<-address s (relation-slot Rel Relations)] 5]
  [[scan _ _ _] | _] _ -> 0
  [[filter | _] | Steps] Relations -> (first-start Steps Relations)
  [[assign | _] | Steps] Relations -> (first-start Steps Relations)
  [[fold | _] | Steps] Relations -> (first-start Steps Relations)
  [[absent | _] | Steps] Relations -> (first-start Steps Relations)
  _ _ -> 0)

\\ The KL of the plan with no sizes to go by.
(define code
  Name
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Constants (nth 5 Program)
          Steps (all-steps (datalog.plans Name))
          _ (set *equivalences* (nth 8 Program))
       (code-h Steps Name Relations Constants)))

(define all-steps
  [] -> []
  [[_ First Variants] | Cs] -> (append First (append Variants (all-steps Cs))))

(define code-h
  [] _ _ _ -> []
  [Steps | More] Name Relations Constants
  -> (let _ (put Name indexes (steps-indexes Steps Relations (get Name indexes)))
          Code (compiled Name Steps Relations Constants)
       (append (tl Code) (code-h More Name Relations Constants))))

\\ ---------------------------------------------------------------------------
\\ Running.

\\ Room for Added more tuples of which every key may be new, and their chains.
(define index-room
  Index Added Count
  -> (let Size (+ 1 (<-address Index 2))
          Wanted (* 2 (+ (<-address Index 4) Added))
          NewSize (power-at-least Size Wanted)
          _ (if (= NewSize Size)
                skip
                (do (address-> Index 0 (larger-table (<-address Index 0) Size NewSize))
                    (address-> Index 2 (- NewSize 1))))
          Next (<-address Index 1)
          Bytes (shen-jit.bytes-length Next)
       (if (>= Bytes (* 4 Count))
           true
           (address-> Index 1 (shen-jit.copy-bytes (shen-jit.bytes (* 8 Count)) 0 Next 0 Bytes)))))

(define power-at-least
  P N -> (if (>= P N) P (power-at-least (* 2 P) N)))

\\ Tuples From up to To into an index, whose kernel is called through a closure kept in it.
(define index-range
  Rec Index From To
  -> (let _ (index-room Index (- To From) To)
          F (<-address Index 3)
          New (F (<-address Index 0) (<-address Index 1) (<-address Rec 2) (<-address Index 2) From To)
       (address-> Index 4 (+ New (<-address Index 4)))))

(define index-all
  [] _ _ _ -> true
  [Slot | Slots] Rec From To -> (do (index-range Rec (<-address Rec Slot) From To)
                                    (index-all Slots Rec From To)))

\\ What was added becomes the new tuples. Gives whether there were any.
\\ Each merge has a number, larger than any before it in this process, and a relation keeps those
\\ its tuples came in, as [[Number | First] ...], the newest first: a round derives only from tuples
\\ merged before it, so these order every derivation, which datalog.explain follows.
(set *merges* 0)

(define merge
  Rec -> (merge-classes Rec) where (classes? Rec)
  Rec -> (let From (<-address Rec 6)
              To (count-of Rec)
              _ (if (> To From)
                    (do (set *merges* (+ 1 (value *merges*)))
                        (address-> Rec 9 [[(value *merges*) | From] | (<-address Rec 9)]))
                    skip)
              _ (index-all (<-address Rec 1) Rec From To)
              _ (address-> Rec 5 From)
              _ (address-> Rec 6 To)
           (> To From)))

\\ An equivalence keeps classes, not pairs. Rules add pairs to its own storage as to any relation's,
\\ an inbox, which each merge empties into a union-find: for each value, its class's cell, which holds
\\ the class's root, size and members, a class joining the larger. The classes that changed are then laid out
\\ again at the end of a buffer X of five u32 a position: a value, its class's range of positions,
\\ and the range of the part of it that was one class when last laid out, values new since being a
\\ part of their own, whose range is empty. So the pairs of a class are its range, the old ones a
\\ value's part, and the new ones the rest, all from the positions where the changed classes start.
\\ Their earlier positions become holes, whose ranges are empty, and a table by value, H, an index of
\\ X's first column, finds a value's latest position, and so the class it was in. When X is full, H
\\ half full or holes outnumber values, every class is laid out again, into new ones. The record:
\\ 0 each value's cell, 1 the cells changed since, 2 how many holes, 3 X, 4 H, 5 H's mask, 6 how many
\\ positions, holes included, 7 where the classes that changed start, 8 how many pairs, 9 whether the
\\ last merge laid any out, 10 the size of a pair's class on average, or -1 until asked for, 11 H's
\\ chains.
(define new-classes
  -> (let C (absvector 12)
          _ (address-> C 0 (shen.dict 64))
          _ (address-> C 1 [])
          _ (address-> C 2 0)
          _ (address-> C 3 (shen-jit.bytes 0))
          _ (address-> C 4 (shen-jit.bytes (* 16 8)))
          _ (address-> C 5 15)
          _ (address-> C 6 0)
          _ (address-> C 7 0)
          _ (address-> C 8 0)
          _ (address-> C 9 false)
          _ (address-> C 10 -1)
          _ (address-> C 11 (shen-jit.bytes 0))
       C))

(define classes?
  Rec -> (absvector? (<-address Rec 8)))

(define size-of
  Rec -> (if (classes? Rec) (<-address (<-address Rec 8) 8) (count-of Rec)))

\\ The inbox into the classes: whether any pair was new, and if so the next round's new pairs are
\\ those, and the relation's size is its pairs, which an add's marks compare.
(define merge-classes
  Rec -> (let C (<-address Rec 8)
              Before (<-address C 8)
              Changed (join-pairs Rec C 0 (count-of Rec) false)
              _ (empty-inbox Rec)
           (if Changed
               (do (address-> Rec 5 Before)
                   (lay-out C)
                   (address-> Rec 6 (<-address C 8))
                   true)
               (do (settle-classes C) false))))

\\ Back to the size a relation starts with, as a round's pairs may be far fewer than the facts'.
(define empty-inbox
  Rec -> (let Meta (<-address Rec 4)
              _ (shen-jit.s64! Meta 0 0)
              _ (shen-jit.s64! Meta 8 15)
              _ (shen-jit.s64! Meta 16 8)
              _ (address-> Rec 2 (shen-jit.bytes (* 8 (<-address Rec 7))))
           (address-> Rec 3 (shen-jit.bytes (* 16 8)))))

(define join-pairs
  Rec C P N Changed
  -> (if (= P N)
         Changed
         (let Tuples (<-address Rec 2)
              New (join C (shen-jit.u32 Tuples (* 8 P)) (shen-jit.u32 Tuples (+ 4 (* 8 P))))
           (join-pairs Rec C (+ P 1) N (or New Changed)))))

\\ Joins two values' classes: whether that changed a class or made one. Each value's entry is its
\\ class's cell, [Root Size Members Changed], shared by its members, so that a join looks each value
\\ up once and re-points only the smaller class's values. The pairs grow by twice the product of the
\\ classes' sizes, or by one for a new value. Cells are told apart by their roots.
(define join
  C A B -> (let EA (dict-find (<-address C 0) A)
                CA (if (cons? EA) (tl EA) (new-cell C A))
                EB (dict-find (<-address C 0) B)
                CB (if (cons? EB) (tl EB) (new-cell C B))
             (cases (= (<-address CA 0) (<-address CB 0)) (and (not (and (cons? EA) (cons? EB))) (changed C CA))
                    (< (<-address CA 1) (<-address CB 1)) (join-into C CB CA)
                    true (join-into C CA CB))))

(define new-cell
  C V -> (let Cell (absvector 4)
              _ (address-> Cell 0 V)
              _ (address-> Cell 1 1)
              _ (address-> Cell 2 [V])
              _ (address-> Cell 3 false)
              _ (shen.dict-> (<-address C 0) V Cell)
              _ (address-> C 8 (+ (<-address C 8) 1))
           Cell))

(define changed
  C Cell -> (do (if (<-address Cell 3)
                    skip
                    (do (address-> Cell 3 true) (address-> C 1 [Cell | (<-address C 1)])))
                true))

\\ The smaller class's values point at the larger's cell, and its own cell, now empty, is left.
(define join-into
  C Big Small
  -> (let _ (point (<-address C 0) (<-address Small 2) Big)
          _ (address-> C 8 (+ (<-address C 8) (* 2 (* (<-address Small 1) (<-address Big 1)))))
          _ (address-> Big 2 (append (<-address Small 2) (<-address Big 2)))
          _ (address-> Big 1 (+ (<-address Big 1) (<-address Small 1)))
          _ (address-> Small 1 0)
       (changed C Big)))

(define point
  _ [] _ -> true
  Cells [V | Vs] Cell -> (do (shen.dict-> Cells V Cell) (point Cells Vs Cell)))

\\ The members of the cells changed since the last layout, but those emptied since.
(define changed-classes
  [] Acc -> Acc
  [Cell | Cells] Acc -> (do (address-> Cell 3 false)
                            (changed-classes Cells (if (= (<-address Cell 1) 0) Acc [(<-address Cell 2) | Acc]))))

\\ Each class once, by the values that are their roots.
(define fold-classes
  F C Acc -> (shen.dict-fold (/. V Cell Acc (if (= V (<-address Cell 0)) (F Cell Acc) Acc)) (<-address C 0) Acc))

\\ The classes that changed, each once, at the end of X; or every class again, into a new X and H,
\\ if there is no room or the holes would outnumber the values.
(define lay-out
  C -> (let Classes (changed-classes (<-address C 1) [])
            Moved (datalog.sum (map (function length) Classes) 0)
            Live (shen.dict-count (<-address C 0))
            _ (address-> C 9 true)
            _ (address-> C 10 -1)
            _ (address-> C 1 [])
         (if (or (> (* 20 (+ (<-address C 6) Moved)) (shen-jit.bytes-length (<-address C 3)))
                 (> (* 2 Live) (<-address C 5))
                 (> (+ (<-address C 2) Moved) Live))
             (lay-out-all C Live)
             (lay-out-some C Classes))))

\\ The classes that changed after the rest, from the positions where the last ones started, which
\\ are old now; their earlier positions holes, and H told where they are.
(define lay-out-some
  C Classes
  -> (let X (<-address C 3)
          From (<-address C 6)
          _ (reset-old X (<-address C 7) From false)
          Changed (filter-parts true (map (/. Ms (parts C Ms)) Classes))
          _ (map (/. Ps (map (/. Part (map (/. V (hole C X V)) (tl Part))) (tl Ps))) Changed)
          End (place-classes X Changed From)
          _ ((index-function 5 [1]) (<-address C 4) (<-address C 11) X (<-address C 5) From End)
          _ (address-> C 6 End)
          _ (address-> C 7 From)
       true))

\\ Every class, those that changed last, into a new X with room for twice the values and an H for
\\ twice that.
(define lay-out-all
  C Live
  -> (let Parts (fold-classes (/. Cell Acc [(parts C (<-address Cell 2)) | Acc]) C [])
          Changed (filter-parts true Parts)
          Room (datalog.max 16 (* 2 Live))
          X (shen-jit.bytes (* 20 Room))
          From (place-classes X (filter-parts false Parts) 0)
          End (place-classes X Changed From)
          Size (power-at-least 16 (* 2 Room))
          H (shen-jit.bytes (* 8 Size))
          Next (shen-jit.bytes (* 4 Room))
          _ ((index-function 5 [1]) H Next X (- Size 1) 0 End)
          _ (address-> C 3 X)
          _ (address-> C 4 H)
          _ (address-> C 5 (- Size 1))
          _ (address-> C 6 End)
          _ (address-> C 7 From)
          _ (address-> C 2 0)
          _ (address-> C 11 Next)
       true))

\\ A value's position, if it has one, made a hole: an empty class that no pair reads.
(define hole
  C X V -> (let P (class-position C V)
             (if (= P 0)
                 skip
                 (let B (* 20 (- P 1))
                      _ (shen-jit.u32! X (+ B 4) 0)
                      _ (shen-jit.u32! X (+ B 8) 0)
                      _ (shen-jit.u32! X (+ B 12) 0)
                      _ (shen-jit.u32! X (+ B 16) 0)
                   (address-> C 2 (+ (<-address C 2) 1))))))

\\ A class's parts: [Changed [Old Values] ... [new Values]], Old where the class each was in when
\\ last laid out starts, before X changes.
(define parts
  C Ms -> (let X (<-address C 3)
               Olds (map (/. V (let P (class-position C V) (if (= P 0) new (shen-jit.u32 X (- (* 20 P) 16))))) Ms)
            (cases (not (all-same? (tl Olds) (hd Olds))) [true | (group-parts Olds Ms (shen.dict 8))]
                   (= (hd Olds) new) [true [new | Ms]]
                   true [false [(hd Olds) | Ms]])))

(define all-same?
  [] _ -> true
  [X | Xs] Y -> (and (= X Y) (all-same? Xs Y)))

(define group-parts
  [] [] Groups -> (let All (shen.dict-fold (/. K Vs Acc [[K | Vs] | Acc]) Groups [])
                    (append (datalog.filter (/. G (not (= (hd G) new))) All) (datalog.filter (/. G (= (hd G) new)) All)))
  [R | Rs] [V | Vs] Groups -> (let E (dict-find Groups R)
                                (do (shen.dict-> Groups R (if (cons? E) [V | (tl E)] [V]))
                                    (group-parts Rs Vs Groups))))

(define datalog.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (datalog.filter F Xs)] (datalog.filter F Xs)))

(define filter-parts
  _ [] -> []
  Flag [[Flag | Parts] | Ps] -> [[Flag | Parts] | (filter-parts Flag Ps)]
  Flag [_ | Ps] -> (filter-parts Flag Ps))

(define place-classes
  _ [] P -> P
  X [[_ | Parts] | Classes] P
  -> (let End (+ P (datalog.sum (map (/. Part (length (tl Part))) Parts) 0))
       (place-classes X Classes (place-parts X Parts P P End))))

(define place-parts
  _ [] _ At _ -> At
  X [[Old | Vs] | Parts] Start At End
  -> (let To (+ At (length Vs))
          Os (if (= Old new) Start At)
          Oe (if (= Old new) Start To)
       (place-parts X Parts Start (place-values X Vs At Start End Os Oe) End)))

(define place-values
  _ [] At _ _ _ _ -> At
  X [V | Vs] At Start End Os Oe
  -> (let B (* 20 At)
          _ (shen-jit.u32! X B V)
          _ (shen-jit.u32! X (+ B 4) Start)
          _ (shen-jit.u32! X (+ B 8) End)
          _ (shen-jit.u32! X (+ B 12) Os)
          _ (shen-jit.u32! X (+ B 16) Oe)
       (place-values X Vs (+ At 1) Start End Os Oe)))

\\ The size of a pair's class, on average over the pairs: the sum of the cubes over that of the
\\ squares, as a real, since the cubes may not fit an integer. Made when a plan asks, and kept until
\\ a class changes.
(define pair-class-size
  C -> (if (< (<-address C 10) 0)
           (let S (<-address C 8)
                W (fold-classes (/. Cell W (let K (<-address Cell 1) (+ W (* K (/ (* K K) S))))) C 0)
                _ (address-> C 10 W)
             W)
           (<-address C 10)))

\\ Nothing new: the old pairs are all, until a class changes again.
(define settle-classes
  C -> (if (<-address C 9)
           (do (reset-old (<-address C 3) (<-address C 7) (<-address C 6) false)
               (address-> C 7 (<-address C 6))
               (address-> C 9 false))
           skip))

\\ Every pair new, for a component's first round.
(define start-classes
  C -> (do (reset-old (<-address C 3) 0 (<-address C 6) true)
           (address-> C 7 0)
           (address-> C 9 true)))

(define reset-old
  X P N Empty -> (if (>= P N)
                     true
                     (let B (* 20 P)
                          S (shen-jit.u32 X (+ B 4))
                          _ (shen-jit.u32! X (+ B 12) S)
                          _ (shen-jit.u32! X (+ B 16) (if Empty S (shen-jit.u32 X (+ B 8))))
                       (reset-old X (+ P 1) N Empty))))

\\ A value's position plus one, or 0.
(define class-position
  C V -> ((key-finder-5) C V))

(define key-finder-5
  -> (let Name class-finder
          Known (dict-find (value *kernels*) Name)
       (if (cons? Known)
           (tl Known)
           (let Find (find-kernel 5 [1])
                F (eval-kl [lambda c [lambda v [Find [<-address c 4] [<-address c 3] [<-address c 5] v]]])
                _ (shen.dict-> (value *kernels*) Name F)
             F))))

\\ The pairs an atom reads, as [X Y] words, from all, old or new pairs, with these columns known.
(define eq-pairs
  Rec Source Keys Values
  -> (let C (<-address Rec 8)
          X (<-address C 3)
       (cases (empty? Keys) (eq-all X Source (if (= Source new) (<-address C 7) 0) (<-address C 6) [])
              (= Keys [1 2])
              (let P (class-position C (hd Values))
                   Q (class-position C (hd (tl Values)))
                (if (and (> P 0) (> Q 0) (in-ranges? (- Q 1) (ranges X (- P 1) Source)))
                    [Values]
                    []))
              true
              (let P (class-position C (hd Values))
                   Others (if (= P 0) [] (range-values X (ranges X (- P 1) Source) []))
                (if (= Keys [1])
                    (map (/. Y [(hd Values) Y]) Others)
                    (map (/. Y [Y (hd Values)]) Others))))))

(define eq-all
  X Source P N Acc
  -> (if (= P N)
         Acc
         (let V (shen-jit.u32 X (* 20 P))
           (eq-all X Source (+ P 1) N
             (append (map (/. Y [V Y]) (range-values X (ranges X P Source) [])) Acc)))))

\\ The ranges of positions a value at P pairs with: its class, its old part, or the rest.
(define ranges
  X P Source -> (let B (* 20 P)
                     Cs (shen-jit.u32 X (+ B 4))
                     Ce (shen-jit.u32 X (+ B 8))
                     Os (shen-jit.u32 X (+ B 12))
                     Oe (shen-jit.u32 X (+ B 16))
                  (cases (= Source all) [[Cs | Ce]]
                         (= Source old) [[Os | Oe]]
                         true [[Cs | Os] [Oe | Ce]])))

(define in-ranges?
  _ [] -> false
  Q [[From | To] | Rs] -> (or (and (>= Q From) (< Q To)) (in-ranges? Q Rs)))

(define range-values
  _ [] Acc -> Acc
  X [[From | To] | Rs] Acc -> (range-values X Rs (values-from X From To Acc)))

(define values-from
  X From To Acc -> (if (>= From To) Acc (values-from X (+ From 1) To [(shen-jit.u32 X (* 20 From)) | Acc])))

(define merge-all
  [] Any -> Any
  [Rel | Rels] Any -> (let Some (merge Rel) (merge-all Rels (or Some Any))))

(define call-all
  [] _ -> true
  [F | Fs] S -> (do (F S) (call-all Fs S)))

\\ Everything so far counts as new, for the first round of a component.
(define start-round
  [] -> true
  [Rel | Rels] -> (do (address-> Rel 5 0)
                      (if (classes? Rel) (start-classes (<-address Rel 8)) skip)
                      (start-round Rels)))

\\ What a run needs: [Name Relations Constants S].
(define run-relation
  Rel [_ Relations _ S] -> (<-address S (relation-slot Rel Relations)))

(define log2
  X N -> (if (<= X 1) N (log2 (shen-jit.shift-right X 1) (+ N 1))))

(define quotient
  A B Q -> (if (< A B) Q (quotient (- A B) B (+ Q 1))))

\\ How many tuples an atom is expected to give for one set of known columns: the average per key if
\\ there is an index to say, and otherwise as if the columns were alike and independent. For an
\\ equivalence, the class of a pair's value, which a join's keys meet more often in a large class
\\ than one value in each class would.
(define estimate
  [Rel | Terms] Bound Run
  -> (let Rec (run-relation Rel Run)
          Size (size-of Rec)
          Keys (key-columns Terms 1 Bound)
          Known (length Keys)
          Arity (length Terms)
       (cases (= Known 0) Size
              (= Size 0) 0
              (= Known Arity) 1
              (classes? Rec) (pair-class-size (<-address Rec 8))
              true (per-key Rec Size Rel Keys Known Arity Run))))

(define per-key
  Rec Size Rel Keys Known Arity [Name | Run]
  -> (let Table (assoc Rel (get Name indexes))
          Slot (if (and (cons? Table) (element? Keys (tl Table)))
                   (index-slot Rel Keys (get Name indexes))
                   none)
       (if (and (not (= Slot none)) (element? Slot (<-address Rec 1)) (> (<-address (<-address Rec Slot) 4) 0))
           (/ Size (<-address (<-address Rec Slot) 4))
           (shen-jit.shift-left 1 (quotient (* (log2 Size 0) (- Arity Known)) Arity 0)))))

(define estimator
  Run -> (if (value *adaptive*)
             (/. Atom Bound (estimate Atom Bound Run))
             []))

\\ Each index these steps look up, started if this run has not used it.
(define prepare
  [] _ -> true
  [Step | Steps] [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          Index (step-index Step Relations)
       (do (if (= Index none) skip (use-index (hd Index) (hd (tl Index)) Run))
           (prepare Steps Run))))

\\ A closure of an index's kernel, for calling it from here.
(define index-function
  N Keys -> (let K (index-kernel N Keys)
              (eval-kl [lambda a [lambda b [lambda c [lambda d [lambda e [lambda f [K a b c d e f]]]]]]])))

(define new-index
  N Keys Count
  -> (let I (absvector 5)
          _ (address-> I 0 (shen-jit.bytes (* 16 8)))
          _ (address-> I 1 (shen-jit.bytes (* 4 (if (> Count 8) Count 8))))
          _ (address-> I 2 15)
          _ (address-> I 3 (index-function N Keys))
          _ (address-> I 4 0)
       I))

(define use-index
  Rel Keys [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (put Name indexes (add-index Rel Keys (get Name indexes)))
          Slot (index-slot Rel Keys (get Name indexes))
          Rec (run-relation Rel Run)
       (cases (element? Slot (<-address Rec 1)) true
              (>= Slot (<-address Rec 0)) (error "datalog: too many indexes on ~A" Rel)
              true (let I (new-index (arity-in Rel Relations) Keys (<-address Rec 6))
                        _ (address-> Rec Slot I)
                        _ (address-> Rec 1 [Slot | (<-address Rec 1)])
                     (index-range Rec I 0 (<-address Rec 6))))))

(define steps-function
  Steps [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (set *equivalences* (nth 8 (datalog.program Name)))
          _ (prepare Steps Run)
          _ (set *plans* (+ 1 (value *plans*)))
       (hd (compiled Name Steps Relations Constants))))

(define first-functions
  [] _ _ -> []
  [R | Rs] Est Run -> (let F (steps-function (plan-rule R Est) Run)
                        [F | (first-functions Rs Est Run)]))

(define variant-functions
  [] _ _ -> []
  [[R P Old] | Vs] Est Run -> (let F (steps-function (plan-variant R P Old Est) Run)
                            [F | (variant-functions Vs Est Run)]))

\\ Sizes to within a power of two: a new plan when one has moved that far.
(define signature
  [] _ -> []
  [[Rel | _] | Rs] Run
  -> [(log2 (size-of (run-relation Rel Run)) 0) | (signature Rs Run)])

(define fixpoint
  Variants Rels Run Functions Signature Rounds
  -> (let Now (signature (hd (tl Run)) Run)
          Replan (and (value *adaptive*) (not (= Now Signature)))
          Fs (if Replan (variant-functions Variants (estimator Run) Run) Functions)
          _ (call-all Fs (nth 4 Run))
          Any (merge-all Rels false)
       (if Any
           (fixpoint Variants Rels Run Fs Now (+ Rounds 1))
           (+ Rounds 1))))

(define run-component
  [C First Variants] Run Rounds
  -> (let Rels (map (/. R (run-relation R Run)) C)
          Est (estimator Run)
          _ (call-all (first-functions First Est Run) (nth 4 Run))
          _ (merge-all Rels false)
          More (if (empty? Variants)
                   0
                   (do (start-round Rels)
                       (fixpoint Variants Rels Run
                         (variant-functions Variants (estimator Run) Run)
                         (signature (hd (tl Run)) Run)
                         0)))
          _ (compact-keyed C Run)
       (+ Rounds More)))

\\ A relation of one tuple a key holds dead tuples once better ones have come: when its component
\\ is done, it is made again from those its keys point to, in the same order, with the merges they
\\ came in, and starts no index until a plan wants one.
(define compact-keyed
  C [Name Relations Constants S]
  -> (map (/. Entry (if (element? (hd Entry) C) (compact (hd Entry) (tl Entry) [Name Relations Constants S]) skip))
          (nth 9 (datalog.program Name))))

(define compact
  Rel Mode [Name Relations Constants S]
  -> (let Slot (relation-slot Rel Relations)
          Rec (<-address S Slot)
          N (arity-in Rel Relations)
          New (new-relation N keyed)
          Merges (compact-h Rec New 0 (count-of Rec) N (key-finder N) (adder-for N Mode)
                   (reverse (<-address Rec 9)) [])
          _ (address-> New 6 (count-of New))
          _ (address-> New 9 Merges)
          _ (shen-jit.s64! (<-address New 4) 24 (shen-jit.s64 (<-address Rec 4) 24))
       (address-> S Slot New)))

(define compact-h
  Rec New P Count N Find Add Merges Acc
  -> (if (= P Count)
         Acc
         (let Words (words-at (<-address Rec 2) (* P (<-address Rec 7)) N)
              Live (= (Find Rec (reverse (tl (reverse Words)))) (+ P 1))
              At (count-of New)
              M (merge-at P Merges 0)
              _ (if Live (Add New Words) skip)
           (compact-h Rec New (+ P 1) Count N Find Add Merges
             (if (and Live (or (empty? Acc) (not (= (hd (hd Acc)) M)))) [[M | At] | Acc] Acc)))))

(define words-at
  _ _ 0 -> []
  Tuples Base N -> [(shen-jit.u32 Tuples Base) | (words-at Tuples (+ Base 4) (- N 1))])

\\ Where a key's tuple is, by the table by key: its position plus one, or 0.
(define key-finder
  N -> (let Name (intern (cn "datalog.key-finder." (str N)))
            Known (dict-find (value *kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let Find (find-kernel N (upto 1 (- N 1)))
                  F (eval-kl [lambda r [lambda l
                               [Find [<-address r 8] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | (list-forms (- N 1) l)]]])
                  _ (shen.dict-> (value *kernels*) Name F)
               F))))

(define run-components
  [] _ Rounds -> Rounds
  [C | Cs] Run Rounds -> (run-components Cs Run (run-component C Run Rounds)))

\\ Values to integers: the program's constants first, in order, which generated code holds as
\\ numbers, then the facts'.
(define datalog.intern
  Value Interned -> (let Entry (dict-find Interned Value)
                      (if (cons? Entry)
                          (tl Entry)
                          (let Id (shen.dict-count Interned)
                               _ (shen.dict-> Interned Value Id)
                               _ (set *fresh* [[Id | Value] | (value *fresh*)])
                            Id))))

\\ The values interned since this was last emptied, for datalog.add to give their numbers.
(set *fresh* [])

(define intern-all
  [] _ -> []
  [V | Vs] Interned -> (let Id (datalog.intern V Interned)
                         [Id | (intern-all Vs Interned)]))

(define list-forms
  0 _ -> []
  N L -> [[hd L] | (list-forms (- N 1) [tl L])])

\\ Closures for adding and finding a tuple given as a list, one for each arity.
(define adder
  N -> (adder-for N none))

(define adder-for
  N [lattice F] -> (/. Rec Words (lattice-insert Rec F Words))
  N Mode -> (let Name (intern (cn "datalog.adder." (cn (str Mode) (cn "." (str N)))))
                 Known (dict-find (value *kernels*) Name)
              (if (cons? Known)
                  (tl Known)
                  (let F (eval-kl [lambda r [lambda l (insert-form N (list-forms N l) Mode)]])
                       _ (shen.dict-> (value *kernels*) Name F)
                    F))))

(define finder
  N -> (let Name (intern (cn "datalog.finder." (str N)))
            Known (dict-find (value *kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let Find (find-kernel N (upto 1 N))
                  F (eval-kl [lambda r [lambda l
                               [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | (list-forms N l)]]])
                  _ (shen.dict-> (value *kernels*) Name F)
               F))))

\\ Facts into their relations. Each relation's record, column types and adder are found once, in a
\\ dictionary, and values are checked as they are encoded; datalog.check-fact says what is wrong.
(define load-facts
  Facts Relations S Interned Constructors Keyed
  -> (load-each Facts (fact-table Relations S 1 (shen.dict 8) Keyed) Relations Interned [S | Constructors]))

(define fact-table
  [] _ _ Table _ -> Table
  [[Rel | Types] | Rs] S I Table Keyed
  -> (let Mode (assoc Rel Keyed)
       (do (shen.dict-> Table Rel [(<-address S I) Types (adder-for (length Types) (if (empty? Mode) none (tl Mode)))])
           (fact-table Rs S (+ I 1) Table Keyed))))

(define load-each
  [] _ _ _ _ -> true
  [[Rel | Values] | Facts] Table Relations Interned Records
  -> (let Entry (dict-find Table Rel)
          _ (if (cons? Entry) skip (check-fact Relations (tl Records) [Rel | Values]))
          Known (tl Entry)
          Ids (encode-checked Values (hd (tl Known)) Interned [Rel | Values] [Relations | Records])
          Add (hd (tl (tl Known)))
          _ (Add (hd Known) Ids)
       (load-each Facts Table Relations Interned Records))
  [Fact | _] _ Relations _ Records -> (check-fact Relations (tl Records) Fact))

(define fill-state
  [] S _ _ _ -> S
  [[Rel | Types] | Rs] S I Equivalences Keyed
  -> (do (address-> S I (new-relation (length Types) (kind Rel Equivalences Keyed)))
         (fill-state Rs S (+ I 1) Equivalences Keyed)))

(define kind
  Rel Equivalences Keyed -> (cases (element? Rel Equivalences) true
                                   (cons? (assoc Rel Keyed)) keyed
                                   true false))

\\ A table for each type's records, after the relations.
(define fill-records
  [] S -> S
  [[_ _ _ _ Slot Width] | Cs] S
  -> (do (if (= (<-address S Slot) 0) (address-> S Slot (new-relation Width false)) skip)
         (fill-records Cs S)))

(define record-slots
  [] -> 0
  [[_ _ _ _ Slot _] | Cs] -> (datalog.max Slot (record-slots Cs)))

\\ A run's state: the values by number, the relations, the tables of records, and the dictionary
\\ that interns values, in which KL makes strings.
(define new-state
  Relations Constructors Interned Equivalences Keyed
  -> (let N (datalog.max (length Relations) (record-slots Constructors))
          S (absvector (+ 2 N))
          _ (zero-state S 1 N)
          _ (address-> S (+ N 1) Interned)
          _ (fill-state Relations S 1 Equivalences Keyed)
       (fill-records Constructors S)))

(define interned-slot
  Relations Constructors -> (+ 1 (datalog.max (length Relations) (record-slots Constructors))))

\\ A string's number, interned now if it is new, as a string function can make one.
(define intern-string
  _ _ [] -> []
  S Slot String -> (let Interned (<-address S Slot)
                        Id (datalog.intern String Interned)
                        _ (if (> (+ Id 1) (limit (<-address S 0)))
                              (address-> S 0 (more-values (<-address S 0) [[Id | String]] (+ Id 1)))
                              (vector-> (<-address S 0) (+ Id 1) String))
                     Id))

(define zero-state
  S I N -> (if (> I N) S (do (address-> S I 0) (zero-state S (+ I 1) N))))

\\ A record's position in the table at Slot, made if it is not there: Words are its constructor's
\\ number and its fields, as wide as the table.
(define record-id
  _ _ Words -> [] where (element? [] Words)
  S Slot Words -> (let Rec (<-address S Slot)
                       P ((interner (length Words)) Rec Words)
                    (if (= P 0)
                        (do (datalog.grow Rec) (record-id S Slot Words))
                        (- P 1))))

(define interner
  N -> (let Name (intern (cn "datalog.interner." (str N)))
            Known (dict-find (value *kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let K (intern-kernel N)
                  F (eval-kl [lambda r [lambda l [K [<-address r 3] [<-address r 2] [<-address r 4] | (list-forms N l)]]])
                  _ (shen.dict-> (value *kernels*) Name F)
               F))))

(define pad
  Words Width -> (if (>= (length Words) Width) Words (pad (append Words [0]) Width)))

\\ A fact's values as the words its columns hold, interning symbols, strings and records, checked
\\ as they go; datalog.check-fact says what is wrong. Ctx is [Relations S | Constructors].
(define encode-checked
  [] [] _ _ _ -> []
  [V | Vs] [integer | Ts] Interned Fact Ctx
  -> (if (int32? V)
         [(int-word V) | (encode-checked Vs Ts Interned Fact Ctx)]
         (fact-error Ctx Fact))
  [V | Vs] [T | Ts] Interned Fact [Relations S | Cs]
  -> (if (value-of? V T Cs)
         (let Id (encode-record V T Interned [S | Cs])
           [Id | (encode-checked Vs Ts Interned Fact [Relations S | Cs])])
         (fact-error [Relations S | Cs] Fact))
     where (cons? V)
  [V | Vs] [T | Ts] Interned Fact Ctx
  -> (if (= (value-type V) T)
         (let Id (datalog.intern V Interned)
           [Id | (encode-checked Vs Ts Interned Fact Ctx)])
         (fact-error Ctx Fact))
  _ _ _ Fact Ctx -> (fact-error Ctx Fact))

(define fact-error
  [Relations _ | Cs] Fact -> (check-fact Relations Cs Fact))

\\ The position of a record, checked already, in its type's table.
(define encode-record
  [C | Vs] _ Interned [S | Cs]
  -> (let Con (assoc C Cs)
       (record-id S (nth 5 Con)
         (pad [(nth 3 Con) | (encode-fields Vs (nth 4 Con) Interned [S | Cs])] (nth 6 Con)))))

(define encode-fields
  [] [] _ _ -> []
  [V | Vs] [integer | Ts] Interned Records -> [(int-word V) | (encode-fields Vs Ts Interned Records)]
  [V | Vs] [T | Ts] Interned Records
  -> (let Id (if (element? T [symbol string]) (datalog.intern V Interned) (encode-record V T Interned Records))
       [Id | (encode-fields Vs Ts Interned Records)]))

\\ The value of a word of type T: what a column holds, read back.
(define word-value
  W integer _ -> (word-int W)
  W symbol [S | _] -> (<-vector (<-address S 0) (+ W 1))
  W string [S | _] -> (<-vector (<-address S 0) (+ W 1))
  Id T [S | Cs]
  -> (let Some (type-constructor T Cs)
          Rec (<-address S (nth 5 Some))
          Tuples (<-address Rec 2)
          Base (* Id (<-address Rec 7))
          Con (tagged T (shen-jit.u32 Tuples Base) Cs)
       [(hd Con) | (field-values Tuples (+ Base 4) (nth 4 Con) [S | Cs])]))

(define field-values
  _ _ [] _ -> []
  Tuples Off [T | Ts] Records
  -> (let V (word-value (shen-jit.u32 Tuples Off) T Records)
       [V | (field-values Tuples (+ Off 4) Ts Records)]))

(define type-constructor
  T [[C T | More] | _] -> [C T | More]
  T [_ | Cs] -> (type-constructor T Cs))

(define tagged
  T Tag [[C T Tag | More] | _] -> [C T Tag | More]
  T Tag [_ | Cs] -> (tagged T Tag Cs))

\\ The word of a value already in the database, or no: a lookup that adds nothing.
(define find-value
  V integer _ _ -> (if (int32? V) (int-word V) no)
  V T Interned [S | Cs]
  -> (let Entry (dict-find Interned V)
       (if (and (cons? Entry) (value-of? V T Cs)) (tl Entry) no))
     where (element? T [symbol string])
  [C | Vs] T Interned [S | Cs]
  -> (let Con (assoc C Cs)
          Words (if (and (cons? Con) (= (nth 2 Con) T) (= (length Vs) (length (nth 4 Con))))
                    (find-values Vs (nth 4 Con) Interned [S | Cs])
                    no)
          Width (if (= Words no) 0 (nth 6 Con))
          P (if (= Words no) 0 ((finder Width) (<-address S (nth 5 Con)) (pad [(nth 3 Con) | Words] Width)))
       (if (= P 0) no (- P 1)))
  _ _ _ _ -> no)

(define find-values
  [] [] _ _ -> []
  [V | Vs] [T | Ts] Interned Records
  -> (let W (find-value V T Interned Records)
          More (if (= W no) no (find-values Vs Ts Interned Records))
       (if (= More no) no [W | More]))
  _ _ _ _ -> no)

\\ The interned values by number, in a vector, so that number N is at N + 1.
(define values-vector
  Interned -> (let V (vector (datalog.max 1 (shen.dict-count Interned)))
                (do (shen.dict-fold (/. K Id Acc (vector-> V (+ Id 1) K)) Interned V) V)))

(define merge-state
  S I End -> (if (> I End)
                 true
                 (do (merge (<-address S I))
                     (zero-derivations (<-address S I))
                     (merge-state S (+ I 1) End))))

(define zero-derivations
  Rec -> (shen-jit.s64! (<-address Rec 4) 24 0))

(define run
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Constants (nth 5 Program)
          Interned (shen.dict 8)
          _ (intern-all Constants Interned)
          N (length Relations)
          S (new-state Relations (nth 7 Program) Interned (nth 8 Program) (nth 9 Program))
          _ (load-facts Facts Relations S Interned (nth 7 Program) (nth 9 Program))
          _ (set *fresh* [])
          _ (address-> S 0 (values-vector Interned))
          _ (merge-state S 1 N)
          Run [Name Relations Constants S]
          _ (set *plans* 0)
          Rounds (run-components (get Name schedule) Run 0)
       [db Name S Interned Rounds (value *plans*) Facts]))

\\ ---------------------------------------------------------------------------
\\ Adding facts to a database. The facts go in, and each relation remembers its size before them,
\\ its mark. Then each component, in order: one that reads only relations that grew goes on from
\\ them, semi-naively, with a variant of each rule for each atom of a relation that grew, reading
\\ what is past its mark; one that negates or aggregates a relation that changed, or reads one
\\ that was evaluated again or that keeps one tuple a key and grew, as a better tuple replaces one,
\\ could lose tuples, so it is emptied to its facts and evaluated again, as is one that reads an
\\ equivalence that grew, whose new pairs since the mark its classes no longer tell; one that reads
\\ nothing that changed stays as it is. The database changes in place.

(define add
  [demand Name Kept] New -> (do (address-> Kept 0 (append (<-address Kept 0) New))
                                (each-kept Kept (/. Db (add Db New)))
                                [demand Name Kept])
  [db Name S Interned Rounds Plans Facts] New
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Constants (nth 5 Program)
          N (length Relations)
          Marks (marks S 1 N)
          _ (set *fresh* [])
          _ (load-facts New Relations S Interned (nth 7 Program) (nth 9 Program))
          _ (address-> S 0 (more-values (<-address S 0) (value *fresh*) (shen.dict-count Interned)))
          _ (merge-each S 1 N)
          All (append Facts New)
          Run [Name Relations Constants S]
          _ (set *plans* 0)
          Grown (grown Relations S Marks 1)
          More (add-components (get Name schedule) (nth 4 Program) Run Marks [All Interned (nth 7 Program)] Grown [] 0)
       [db Name S Interned (+ Rounds More) (+ Plans (value *plans*)) All])
  Db _ -> (error "datalog: datalog.add takes a database that datalog.run made, not ~S" Db))

(define marks
  S I N -> (if (> I N) [] [(<-address (<-address S I) 6) | (marks S (+ I 1) N)]))

(define merge-each
  S I N -> (if (> I N) true (do (merge (<-address S I)) (merge-each S (+ I 1) N))))

\\ The relations that have more tuples than their marks.
(define grown
  [] _ _ _ -> []
  [[Rel | _] | Rs] S [Mark | Marks] I
  -> (if (> (<-address (<-address S I) 6) Mark)
         [Rel | (grown Rs S Marks (+ I 1))]
         (grown Rs S Marks (+ I 1))))

\\ A values vector with room for the new ones: doubled when it is full.
(define more-values
  Values [] _ -> Values
  Values Fresh Count
  -> (let Size (limit Values)
          Bigger (if (>= Size Count)
                     Values
                     (copy-values Values (vector (datalog.max Count (* 2 Size))) 1 Size))
       (do (map (/. F (vector-> Bigger (+ 1 (hd F)) (tl F))) Fresh) Bigger)))

(define copy-values
  From To I N -> (if (> I N) To (do (address-> To I (<-address From I)) (copy-values From To (+ I 1) N))))

\\ Facts is [every fact so far, Interned].
(define add-components
  [] _ _ _ _ _ _ Rounds -> Rounds
  [[C First Variants] | Cs] Rules Run Marks Facts Grown Again Rounds
  -> (let In (rules-in Rules C)
          Changed (union Grown Again)
          Complete (all-complete In)
          Positive (difference (all-positive In) C)
          Kind (cases (or (cons? (keep-in Complete Changed)) (cons? (keep-in Positive Again))) again
                      (cons? (keep-in (union Positive C) Grown)) grow
                      true same)
          More (cases (= Kind again) (datalog.again [C First Variants] Run Facts Rounds)
                      (= Kind grow) (grow-component [C First Variants] In Run Marks Grown Rounds)
                      true Rounds)
          S (nth 4 Run)
          Relations (hd (tl Run))
          Grew (keep-in C (grown Relations S Marks 1))
          Program (datalog.program (hd Run))
          Keyed (keep-in C (append (nth 8 Program) (map (function hd) (nth 9 Program))))
       (add-components Cs Rules Run Marks Facts
         (if (= Kind grow) (union Grew Grown) Grown)
         (cases (= Kind again) (union C Again)
                (= Kind grow) (union Keyed Again)
                true Again)
         More)))

(define all-complete
  [] -> []
  [[_ Body] | Rules] -> (union (complete-relations Body) (all-complete Rules)))

(define all-positive
  [] -> []
  [[_ Body] | Rules] -> (union (map (function hd) (atoms Body)) (all-positive Rules)))

\\ A component emptied to its facts and evaluated as datalog.run would.
(define datalog.again
  [C First Variants] [Name Relations Constants S] [Facts Interned Constructors] Rounds
  -> (let Run [Name Relations Constants S]
          Program (datalog.program Name)
          _ (map (/. Rel (address-> S (relation-slot Rel Relations)
                           (new-relation (arity-in Rel Relations)
                             (kind Rel (nth 8 Program) (nth 9 Program)))))
                 C)
          _ (load-facts (facts-of C Facts) Relations S Interned Constructors (nth 9 Program))
          _ (map (/. Rel (merge (run-relation Rel Run))) C)
       (run-component [C First Variants] Run Rounds)))

(define facts-of
  _ [] -> []
  C [[Rel | Values] | Facts] -> (if (element? Rel C)
                                    [[Rel | Values] | (facts-of C Facts)]
                                    (facts-of C Facts)))

\\ A component that goes on from what grew: each relation that grew reads as new what is past its
\\ mark, a round of every rule with one variant for each atom of such a relation, and then the
\\ component's own rounds until nothing is new.
(define grow-component
  [C First Variants] In Run Marks Grown Rounds
  -> (let S (nth 4 Run)
          Relations (hd (tl Run))
          _ (since-marks Relations S Marks Grown 1)
          Rels (map (/. R (run-relation R Run)) C)
          Est (estimator Run)
          Fs (variant-functions (grown-variants In Grown) Est Run)
          _ (call-all Fs S)
          Any (merge-all Rels false)
          More (if (and Any (cons? Variants))
                   (+ Rounds 1 (fixpoint Variants Rels Run
                                 (variant-functions Variants (estimator Run) Run)
                                 (signature Relations Run) 0))
                   (+ Rounds 1))
          _ (compact-keyed C Run)
       More))

(define since-marks
  [] _ _ _ _ -> true
  [[Rel | _] | Rs] S [Mark | Marks] Grown I
  -> (do (if (element? Rel Grown) (address-> (<-address S I) 5 Mark) skip)
         (since-marks Rs S Marks Grown (+ I 1))))

\\ [Rule Position Old] for each atom whose relation grew, Old those before it.
(define grown-variants
  [] _ -> []
  [R | Rs] Grown -> (append (rule-variants R (positions-in (atoms (hd (tl R))) 1 Grown) [])
                            (grown-variants Rs Grown)))

\\ ---------------------------------------------------------------------------
\\ Removing facts. Tuples are never deleted from storage: a component that holds a relation that
\\ lost a fact, or reads one evaluated again, is emptied to the facts left and evaluated again, in
\\ order, and the rest stay. A fact the database does not have is no change.

(define datalog.remove
  [demand Name Kept] Gone -> (do (address-> Kept 0 (hd (split-facts (<-address Kept 0) (fact-set Gone (shen.dict 8)) [] [])))
                                 (each-kept Kept (/. Db (datalog.remove Db Gone)))
                                 [demand Name Kept])
  [db Name S Interned Rounds Plans Facts] Gone
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Split (split-facts Facts (fact-set Gone (shen.dict 8)) [] [])
          Left (hd Split)
          Lost (tl Split)
          Run [Name Relations (nth 5 Program) S]
          _ (set *plans* 0)
          More (remove-components (get Name schedule) (nth 4 Program) Run [Left Interned (nth 7 Program)] Lost [] 0)
       [db Name S Interned (+ Rounds More) (+ Plans (value *plans*)) Left])
  Db _ -> (error "datalog: datalog.remove takes a database that datalog.run made, not ~S" Db))

(define fact-set
  [] Table -> Table
  [F | Fs] Table -> (do (shen.dict-> Table F true) (fact-set Fs Table)))

\\ [the facts left | the relations of those going that the database has].
(define split-facts
  [] _ Left Lost -> [(reverse Left) | Lost]
  [[Rel | Values] | Fs] Table Left Lost
  -> (if (cons? (dict-find Table [Rel | Values]))
         (split-facts Fs Table Left (adjoin Rel Lost))
         (split-facts Fs Table [[Rel | Values] | Left] Lost)))

\\ Lost are the relations that lost a fact, Again the ones evaluated again so far.
(define remove-components
  [] _ _ _ _ _ Rounds -> Rounds
  [[C First Variants] | Cs] Rules Run Facts Lost Again Rounds
  -> (let In (rules-in Rules C)
          Reads (union (all-complete In) (all-positive In))
       (if (or (cons? (keep-in C Lost)) (cons? (keep-in Reads Again)))
           (remove-components Cs Rules Run Facts Lost (union C Again)
             (datalog.again [C First Variants] Run Facts Rounds))
           (remove-components Cs Rules Run Facts Lost Again Rounds))))

(define relation-of
  [demand | _] _ -> (only-asked)
  [db Name S | _] Rel
  -> (let Relations (nth 3 (datalog.program Name))
       (if (cons? (assoc Rel Relations))
           (<-address S (relation-slot Rel Relations))
           (error "datalog: no relation ~A" Rel))))

(define types-of
  Name Rel -> (tl (assoc Rel (nth 3 (datalog.program Name)))))

(define tuple-at
  _ _ [] _ -> []
  Tuples Base [Type | Types] Records
  -> (let Word (shen-jit.u32 Tuples Base)
          More (tuple-at Tuples (+ Base 4) Types Records)
       [(word-value Word Type Records) | More]))

(define read-tuples
  P To _ _ _ _ Acc -> Acc where (= P To)
  P To Tuples Stride Types Values Acc
  -> (read-tuples (+ P 1) To Tuples Stride Types Values
       [(tuple-at Tuples (* P Stride) Types Values) | Acc]))

(define only-asked
  -> (error "datalog: a database by demand answers datalog.ask and datalog.match; datalog.run makes one for the rest"))

(define tuples
  [demand | _] _ -> (only-asked)
  [naive _ Tables] Rel
  -> (let Table (assoc Rel Tables)
       (if (empty? Table) (error "datalog: no relation ~A" Rel) (tl Table)))
  [db Name S | Rest] Rel
  -> (let Rec (relation-of [db Name S | Rest] Rel)
          Types (types-of Name Rel)
          Records [S | (nth 7 (datalog.program Name))]
       (if (classes? Rec)
           (map (/. P [(word-value (hd P) (hd Types) Records) (word-value (hd (tl P)) (hd Types) Records)])
                (eq-pairs Rec all [] []))
           (read-tuples 0 (<-address Rec 6) (<-address Rec 2) (<-address Rec 7) Types Records []))))

(define datalog.count
  [naive | Rest] Rel -> (length (tuples [naive | Rest] Rel))
  Db Rel -> (size-of (relation-of Db Rel)))

(define holds?
  [demand | _] _ -> (only-asked)
  [naive | Rest] [Rel | Values] -> (element? Values (tuples [naive | Rest] Rel))
  [db Name S Interned | Rest] [Rel | Values]
  -> (let Rec (relation-of [db Name S Interned | Rest] Rel)
          Ids (find-values Values (types-of Name Rel) Interned [S | (nth 7 (datalog.program Name))])
          Find (finder (length Values))
       (cases (= Ids no) false
              (classes? Rec) (cons? (eq-pairs Rec all [1 2] Ids))
              true (> (Find Rec Ids) 0))))

(define match
  [demand Name Kept] Pattern -> (match-demand Name Kept Pattern)
  [db | Rest] [Rel | Terms] -> (match-tuples (tuples-for [db | Rest] Rel Terms) Terms [])
  Db [Rel | Terms] -> (match-tuples (tuples Db Rel) Terms []))

\\ The tuples a pattern may match: by the relation's table if it has no variable, by an index on the
\\ columns of its constants, or all; an equivalence's, all.
(define tuples-for
  Db Rel Terms
  -> (let Keys (key-columns Terms 1 [])
       (cases (or (empty? Keys) (classes? (relation-of Db Rel))) (tuples Db Rel)
              (= (length Keys) (length Terms)) (if (holds? Db [Rel | Terms]) [Terms] [])
              true (tuples-at Db Rel Keys (map (/. K (nth K Terms)) Keys)))))

(define match-tuples
  [] _ Acc -> Acc
  [T | Ts] Terms Acc -> (match-tuples Ts Terms
                          (if (= (naive-match Terms T []) no) Acc [T | Acc])))

\\ Rounds, plans made, and for each relation its tuples, its derivations and its indexes.
(define stats
  [demand | _] -> (only-asked)
  [db Name S _ Rounds Plans | _]
  -> (let Relations (nth 3 (datalog.program Name))
       [[rounds Rounds] [plans Plans]
        | (map (/. R (let Rec (<-address S (relation-slot (hd R) Relations))
                       [(hd R) (size-of Rec) (shen-jit.s64 (<-address Rec 4) 24) (length (<-address Rec 1))]))
               Relations)]))

\\ ---------------------------------------------------------------------------
\\ Explanations. (datalog.explain Db [Rel V ...]) gives why a tuple holds, as a proof: [Tuple fact]
\\ for a fact given, [Tuple equivalence] for a pair an equivalence has as such, [Tuple lattice] for
\\ a value a lattice joined from others, and otherwise
\\ [Tuple Rule Proof ...], the rule as written and a proof of each tuple of its positive atoms, in
\\ order; [] if the tuple does not hold. Nothing is recorded as tuples are derived: a rule instance
\\ is found whose atoms' tuples were all merged before the tuple was, which the one that derived it
\\ is, so that a proof never goes round in a circle.

(define explain
  [demand | _] _ -> (only-asked)
  [db Name S Interned Rounds Plans Facts] [Rel | Values]
  -> (let Program (datalog.program Name)
          _ (if (cons? (assoc Rel (nth 3 Program))) skip (error "datalog: no relation ~A" Rel))
          Ctx [[db Name S Interned Rounds Plans Facts] Program (fact-set Facts (shen.dict 64)) (shen.dict 16) (shen.dict 64)]
          Merge (merge-of Ctx [Rel | Values])
       (if (= Merge none) [] (prove Ctx [Rel | Values] Merge))))

\\ Ctx is [Db Program Facts Tuples Proofs]: the facts as a set, each relation's tuples read so far,
\\ as [[Values | Merge] ...] by relation, and the proofs found, by tuple.
(define prove
  Ctx Tuple Merge
  -> (let Known (dict-find (nth 5 Ctx) Tuple)
       (if (cons? Known)
           (tl Known)
           (let Proof (prove-h Ctx Tuple Merge)
                _ (shen.dict-> (nth 5 Ctx) Tuple Proof)
             Proof))))

(define prove-h
  Ctx [Rel | Values] Merge
  -> (if (cons? (dict-find (nth 3 Ctx) [Rel | Values]))
         [[Rel | Values] fact]
         (let Found (instance (rules-of Rel (nth 4 (nth 2 Ctx))) Ctx Values Merge)
           (cases (not (= Found none))
                  [[Rel | Values] (rule->form (hd (hd Found)) (hd (tl (hd Found))))
                   | (map (/. T (prove Ctx (hd T) (tl T))) (tl Found))]
                  (element? Rel (nth 8 (nth 2 Ctx))) [[Rel | Values] equivalence]
                  (cons? (assoc Rel (nth 9 (nth 2 Ctx)))) [[Rel | Values] lattice]
                  true (error "datalog: no derivation of ~S found" [Rel | Values])))))

\\ The first rule with an instance for these values: [Rule [Tuple | Merge] ...], or none.
(define instance
  [] _ _ _ -> none
  [[[Rel | Terms] Body] | Rules] Ctx Values Merge
  -> (let Env (naive-match Terms Values [])
          Found (if (= Env no) none (body-instance (atoms Body) (conditions Body) Env Ctx Merge []))
       (if (= Found none)
           (instance Rules Ctx Values Merge)
           [[[Rel | Terms] Body] | Found])))

\\ The atoms' tuples, each merged before Merge, in the order written, with the conditions true.
(define body-instance
  [] Conditions Env Ctx _ Acc
  -> (let Tables (map (/. R [R | (map (function hd) (read-relation Ctx R))]) (complete-relations Conditions))
          Bound (naive-bind Conditions Env Conditions false Tables)
       (if (and (not (= Bound no)) (naive-true? Conditions Bound Tables)) (reverse Acc) none))
  [[Rel | Terms] | Atoms] Conditions Env Ctx Merge Acc
  -> (try-tuples (read-relation Ctx Rel) Rel Terms Atoms Conditions Env Ctx Merge Acc))

(define try-tuples
  [] _ _ _ _ _ _ _ _ -> none
  [[Values | M] | Tuples] Rel Terms Atoms Conditions Env Ctx Merge Acc
  -> (let Bound (if (< M Merge) (naive-match Terms Values Env) no)
          Found (if (= Bound no) none (body-instance Atoms Conditions Bound Ctx Merge [[[Rel | Values] | M] | Acc]))
       (if (= Found none)
           (try-tuples Tuples Rel Terms Atoms Conditions Env Ctx Merge Acc)
           Found)))

\\ A relation's tuples, each with the merge it came in, read once for an explanation.
(define read-relation
  Ctx Rel -> (let Cache (nth 4 Ctx)
                  Known (dict-find Cache Rel)
               (if (cons? Known)
                   (tl Known)
                   (let Db (hd Ctx)
                        Rec (relation-of Db Rel)
                        Tuples (if (classes? Rec)
                                   (map (/. T [T | 0]) (tuples Db Rel))
                                   (with-merges (reverse (tuples Db Rel)) 0 (reverse (<-address Rec 9))))
                        _ (shen.dict-> Cache Rel Tuples)
                     Tuples))))

\\ Tuples in the order stored, each paired with the merge of its position.
(define with-merges
  [] _ _ -> []
  [T | Ts] P Merges -> [[T | (merge-at P Merges 0)] | (with-merges Ts (+ P 1) Merges)])

(define merge-at
  P [[M | First] | More] Last -> (if (< P First) Last (merge-at P More M))
  _ [] Last -> Last)

(define merge-of
  Ctx [Rel | Values] -> (let Entry (assoc Values (read-relation Ctx Rel))
                          (if (empty? Entry) none (tl Entry))))

\\ ---------------------------------------------------------------------------
\\ Fact files. A relation's file has a line a tuple, its fields apart by tabs, tsv, or by commas with
\\ RFC 4180's quotes, csv; each field is read as its column's type says: an integer, a symbol, a
\\ string as it is, or a record as Shen reads it, [pt 1 2]. (datalog.bytes->facts Name Rel Bytes
\\ Format) gives the facts of Rel in the bytes of such a file, and (datalog.relation->bytes Db Rel
\\ Format) a relation's tuples as those bytes, so that a program can read and write the file as it
\\ likes, with the I/O library say. (datalog.read-facts Name Rel Path) and (datalog.write-facts Db Rel
\\ Path) do so with Shen's own files, csv for a path ending in .csv and tsv otherwise.

(define bytes->facts
  Name Rel B Format -> (parse-facts Name Rel (freeze B) (separator Format) (make-string "bytes of ~A" Rel)))

(define read-facts
  Name Rel Path -> (parse-facts Name Rel (freeze (shen-jit.string->bytes (read-file-as-string Path)))
                     (separator (format-of Path)) Path))

\\ The bytes are made once the relation is known to be there.
(define parse-facts
  Name Rel Bytes Separator Source
  -> (let Program (datalog.program Name)
          Types (assoc Rel (nth 3 Program))
          _ (if (empty? Types) (error "datalog: no relation ~A" Rel) skip)
          B (thaw Bytes)
       (read-lines B 0 (shen-jit.bytes-length B) 1 [Rel (tl Types) Separator Source (nth 7 Program)] [])))

(define separator
  tsv -> 9
  csv -> 44
  Format -> (error "datalog: ~S is neither tsv nor csv" Format))

(define format-of
  Path -> (if (ends-with? Path ".csv") csv tsv))

(define ends-with?
  S End -> (cases (= S End) true
                  (= S "") false
                  true (ends-with? (tlstr S) End)))

\\ Ctx is [Rel Types Separator Path Constructors].
(define read-lines
  B I N Line Ctx Acc
  -> (if (>= I N)
         (reverse Acc)
         (let Read (read-fields B I N (hd (tl (tl Ctx))) [])
              Fields (hd Read)
           (read-lines B (tl Read) N (+ Line 1) Ctx
             (if (blank? Fields) Acc [(fact-of B Fields Line Ctx) | Acc])))))

(define blank?
  [[I | I]] -> true
  _ -> false)

\\ A line's fields and where the next line starts: [Fields | Next]. A field is its range of bytes,
\\ [From | To], or a quoted one's text.
(define read-fields
  B I N Sep Acc
  -> (if (and (< I N) (= (shen-jit.u8 B I) 34) (= Sep 44))
         (let Quoted (read-quoted B (+ I 1) N "")
              J (tl Quoted)
           (after-field B J N Sep [(hd Quoted) | Acc]))
         (let J (field-end B I N Sep)
              End (if (and (> J I) (= (shen-jit.u8 B (- J 1)) 13) (or (= J N) (= (shen-jit.u8 B J) 10))) (- J 1) J)
           (after-field B J N Sep [[I | End] | Acc]))))

(define after-field
  B J N Sep Acc -> (cases (>= J N) [(reverse Acc) | N]
                          (= (shen-jit.u8 B J) Sep) (read-fields B (+ J 1) N Sep Acc)
                          (= (shen-jit.u8 B J) 13) (after-field B (+ J 1) N Sep Acc)
                          true [(reverse Acc) | (+ J 1)]))

(define field-end
  B I N Sep -> (if (or (>= I N) (= (shen-jit.u8 B I) Sep) (= (shen-jit.u8 B I) 10)) I (field-end B (+ I 1) N Sep)))

\\ A quoted field from after its quote: [Text | where it ends], "" being a quote within it.
(define read-quoted
  B I N Text
  -> (let J (quote-end B I N)
          More (cn Text (shen-jit.bytes->string B I (- J I)))
       (cases (>= J N) (error "datalog: a quoted field does not end")
              (and (< (+ J 1) N) (= (shen-jit.u8 B (+ J 1)) 34)) (read-quoted B (+ J 2) N (cn More "c#34;"))
              true [More | (+ J 1)])))

(define quote-end
  B I N -> (if (or (>= I N) (= (shen-jit.u8 B I) 34)) I (quote-end B (+ I 1) N)))

(define fact-of
  B Fields Line [Rel Types Sep Path Cs]
  -> (if (= (length Fields) (length Types))
         [Rel | (field-values-of B Fields Types Line Path Cs)]
         (error "datalog: ~A, line ~A, has ~A fields where ~A takes ~A" Path Line (length Fields) Rel (length Types))))

(define field-values-of
  _ [] [] _ _ _ -> []
  B [[I | J] | Fs] [integer | Ts] Line Path Cs
  -> (let N (byte-integer B I J)
       (if (and (integer? N) (int32? N))
           [N | (field-values-of B Fs Ts Line Path Cs)]
           (error "datalog: ~A, line ~A: ~S is not an integer of 32 bits" Path Line (shen-jit.bytes->string B I (- J I)))))
  B [F | Fs] [T | Ts] Line Path Cs
  -> (let V (field-value (if (cons? F) (shen-jit.bytes->string B (hd F) (- (tl F) (hd F))) F) T Line Path Cs)
       [V | (field-values-of B Fs Ts Line Path Cs)]))

\\ The integer of these bytes, or [] if they are not one.
(define byte-integer
  B I J -> (cases (>= I J) []
                  (and (= (shen-jit.u8 B I) 45) (< (+ I 1) J)) (negate (byte-digits B (+ I 1) J 0))
                  true (byte-digits B I J 0)))

(define byte-digits
  B I J N -> (if (>= I J)
                 N
                 (let D (- (shen-jit.u8 B I) 48)
                   (if (and (>= D 0) (<= D 9)) (byte-digits B (+ I 1) J (+ (* 10 N) D)) []))))

(define field-value
  Text integer Line Path _
  -> (let N (parse-integer Text)
       (if (and (integer? N) (int32? N))
           N
           (error "datalog: ~A, line ~A: ~S is not an integer of 32 bits" Path Line Text)))
  Text symbol _ _ _ -> (intern Text)
  Text string _ _ _ -> Text
  Text Type Line Path Cs
  -> (let Read (trap-error (read-from-string Text) (/. E []))
          V (if (and (cons? Read) (empty? (tl Read))) (unbracket-term (hd Read)) none)
       (if (value-of? V Type Cs)
           V
           (error "datalog: ~A, line ~A: ~S is not of type ~A" Path Line Text Type))))

(define relation->bytes
  Db Rel Format
  -> (let Csv (= (separator Format) 44)
          Lines (map (/. T (shen-jit.string->bytes (line T Csv))) (tuples Db Rel))
       (join-bytes Lines (shen-jit.bytes (datalog.sum (map (function shen-jit.bytes-length) Lines) 0)) 0)))

(define join-bytes
  [] Out _ -> Out
  [B | Bs] Out I -> (let N (shen-jit.bytes-length B)
                         _ (shen-jit.copy-bytes Out I B 0 N)
                      (join-bytes Bs Out (+ I N))))

\\ The file is written by one call, once every line is made, so that a field it cannot hold leaves
\\ it as it was.
(define write-facts
  Db Rel Path
  -> (let B (relation->bytes Db Rel (format-of Path))
          Out (open Path out)
          _ (shen-jit.write-bytes B 0 (shen-jit.bytes-length B) Out)
          _ (close Out)
       (datalog.count Db Rel)))

(define line
  [V] Csv -> (cn (field-text V Csv) "c#10;")
  [V | Vs] Csv -> (cn (field-text V Csv) (cn (if Csv "," "c#9;") (line Vs Csv))))

(define field-text
  V _ -> (str V) where (number? V)
  V Csv -> (text-field (if (symbol? V) (str V) V) Csv) where (or (symbol? V) (string? V))
  V Csv -> (text-field (make-string "~S" V) Csv))

\\ A tab or a line break cannot be in a tab-separated field.
(define text-field
  T true -> (csv-quote T)
  T false -> (if (plain-tsv? T) T (error "datalog: ~S has a tab or a line break, which a tab-separated file cannot hold" T)))

(define plain-tsv?
  "" -> true
  (@s C Rest) -> (and (not (element? C ["c#9;" "c#10;" "c#13;"])) (plain-tsv? Rest)))

(define csv-quote
  S -> (if (plain? S) S (cn "c#34;" (cn (double-quotes S) "c#34;"))))

(define plain?
  "" -> true
  (@s C Rest) -> (and (not (element? C ["," "c#34;" "c#10;" "c#13;"])) (plain? Rest)))

(define double-quotes
  "" -> ""
  (@s "c#34;" Rest) -> (cn "c#34;c#34;" (double-quotes Rest))
  (@s C Rest) -> (cn C (double-quotes Rest)))

\\ ---------------------------------------------------------------------------
\\ Demand, by magic sets. (datalog.query Name Facts (Rel Term ...)) gives what datalog.ask would of
\\ a run of these facts, computing only what the query needs. Its constants make an adornment, b
\\ for a bound column and f for a free one, and the program is rewritten for it once and kept:
\\ each relation the query reaches through positive atoms has a copy for each adornment it is
\\ reached with, Rel@bf, whose rules begin with a magic relation, magic@Rel@bf, of the values asked
\\ for in its bound columns. A magic relation's rules pass those on, from a head, through the
\\ atoms that bind more, as the planner would order them with no sizes, to the next atom of a
\\ copy. A copy also takes the facts of its relation. What is negated or aggregated must be
\\ complete, and an equivalence or a relation of one tuple a key is right only as a whole, so these
\\ are computed in full, by their
\\ own rules, with all they depend on. The query's constants are the one fact of its magic relation.
\\
\\ (datalog.demand-db Name Facts) is a database that answers datalog.ask and datalog.match by demand.
\\ It keeps the facts, and for each adornment asked, a database of the program rewritten for it,
\\ which the first query of that adornment runs; a later one adds its constants as a fact of the
\\ magic relation, so that it derives only what the queries before it did not. datalog.add and
\\ datalog.remove change every database it keeps, as they change any.

(define solve
  Name Facts [Rel | Terms]
  -> (let Asked (asked Name [Rel | Terms])
          Db (run (hd Asked) [(hd (tl Asked)) | Facts])
       (match-tuples (tuples Db (hd (tl (tl Asked)))) Terms [])))

\\ For a query: the program rewritten for its adornment, the fact that asks it, and the relation that
\\ answers.
(define asked
  Name [Rel | Terms]
  -> (let Program (datalog.program Name)
          Types (assoc Rel (nth 3 Program))
          _ (cases (empty? Types) (error "datalog: no relation ~A" Rel)
                   (not (= (length Terms) (length (tl Types))))
                   (error "datalog: ~A takes ~A values, not ~A" Rel (length (tl Types)) (length Terms))
                   true skip)
          Adorn (map (/. T (if (known? T []) b f)) Terms)
       [(datalog.demand Name Rel Adorn) [(magic-name Rel Adorn) | (at-bound Terms Adorn)]
        (adorned-name Rel Adorn)]))

(define demand-db
  Name Facts -> (let _ (datalog.program Name)
                     Kept (absvector 2)
                     _ (address-> Kept 0 Facts)
                     _ (address-> Kept 1 (shen.dict 8))
                  [demand Name Kept]))

(define match-demand
  Name Kept [Rel | Terms]
  -> (let Asked (asked Name [Rel | Terms])
          Seed (hd (tl Asked))
          Entry (dict-find (<-address Kept 1) (hd Asked))
          Db (cases (not (cons? Entry)) (run (hd Asked) [Seed | (<-address Kept 0)])
                    (holds? (tl Entry) Seed) (tl Entry)
                    true (add (tl Entry) [Seed]))
          _ (shen.dict-> (<-address Kept 1) (hd Asked) Db)
       (match-tuples (tuples-for Db (hd (tl (tl Asked))) Terms) Terms [])))

\\ The tuples whose columns Keys hold these values, by an index on them, started if there is none
\\ and kept as the relation grows: its table finds the newest, and its chain the rest.
(define tuples-at
  [db Name S Interned | Rest] Rel Keys Values
  -> (let Program (datalog.program Name)
          Relations (nth 3 Program)
          Types (types-of Name Rel)
          Records [S | (nth 7 Program)]
          Ids (find-values Values (map (/. K (nth K Types)) Keys) Interned Records)
       (if (= Ids no)
           []
           (let _ (use-index Rel Keys [Name Relations (nth 5 Program) S])
                Rec (<-address S (relation-slot Rel Relations))
                I (<-address Rec (index-slot Rel Keys (get Name indexes)))
             (chain-tuples ((index-finder (length Types) Keys) I (<-address Rec 2) Ids) I Rec Types Records [])))))

(define chain-tuples
  0 _ _ _ _ Acc -> Acc
  P I Rec Types Records Acc
  -> (chain-tuples (shen-jit.u32 (<-address I 1) (* 4 (- P 1))) I Rec Types Records
       [(tuple-at (<-address Rec 2) (* (- P 1) (<-address Rec 7)) Types Records) | Acc]))

\\ A closure of the find kernel for an index on Keys, given the index, the tuples and the values.
(define index-finder
  Arity Keys
  -> (let Name (intern (make-string "datalog.index-finder.~A.~A" Arity Keys))
          Known (dict-find (value *kernels*) Name)
       (if (cons? Known)
           (tl Known)
           (let Find (find-kernel Arity Keys)
                F (eval-kl [lambda i [lambda t [lambda l [Find [<-address i 0] t [<-address i 2] | (list-forms (length Keys) l)]]]])
                _ (shen.dict-> (value *kernels*) Name F)
             F))))

(define each-kept
  Kept F -> (map (/. D (shen.dict-> (<-address Kept 1) D (F (tl (dict-find (<-address Kept 1) D)))))
                 (shen.dict-keys (<-address Kept 1))))

(define datalog.demand
  Name Rel Adorn
  -> (let D (intern (cn (str Name) (cn "@" (str (adorned-name Rel Adorn)))))
          Known (get Name demands)
       (if (element? D Known)
           D
           (do (datalog.define D (demand-items (datalog.program Name) Rel Adorn))
               (put Name demands [D | Known])
               D))))

(define adorned-name
  Rel Adorn -> (intern (cn (str Rel) (cn "@" (adorn-string Adorn)))))

(define magic-name
  Rel Adorn -> (intern (cn "magic@" (str (adorned-name Rel Adorn)))))

(define adorn-string
  [] -> ""
  [A | As] -> (cn (str A) (adorn-string As)))

(define at-bound
  [] [] -> []
  [X | Xs] [b | As] -> [X | (at-bound Xs As)]
  [_ | Xs] [_ | As] -> (at-bound Xs As))

(define demand-items
  [program _ Relations Rules _ _ Constructors Equivalences Keyed] Rel Adorn
  -> (let Whole (append Equivalences (map (function hd) Keyed))
          Derived (difference (unique (map (/. R (hd (hd R))) Rules) []) Whole)
          Done (adorn [[Rel Adorn]] [] (keep-in [Rel] Whole) Rules Derived [])
          Full (full-closure (hd (tl (tl Done))) Rules)
          Copies (hd (tl Done))
       (append (type-items Constructors [])
       (append (map (/. R (cases (element? (hd R) Equivalences) [relation (hd R) (tl R) equivalence]
                                 (cons? (assoc (hd R) Keyed)) [relation (hd R) (tl R) (tl (assoc (hd R) Keyed))]
                                 true [relation (hd R) (tl R)]))
                    Relations)
       (append (mapcan (/. C (copy-items C Relations)) Copies)
       (append (map (/. R [rule (hd R) (map (function literal->data) (hd (tl R)))])
                    (rules-in Rules Full))
               (map (/. R [rule (hd R) (hd (tl R))]) (hd Done))))))))

\\ Each copy and its magic relation, and the rule that gives the copy its relation's facts.
(define copy-items
  [Rel Adorn] Relations
  -> (let Types (tl (assoc Rel Relations))
          Vars (map (/. I [var (cn "D" (str I))]) (upto 1 (length Types)))
       [[relation (adorned-name Rel Adorn) Types]
        [relation (magic-name Rel Adorn) (at-bound Types Adorn)]
        [rule [(adorned-name Rel Adorn) | Vars]
              [[(magic-name Rel Adorn) | (at-bound Vars Adorn)] [Rel | Vars]]]]))

(define type-items
  [] Acc -> (reverse Acc)
  [[C T _ Fields | _] | Cs] Acc
  -> (type-items Cs (if (element? T (map (/. I (hd (tl I))) Acc))
                                (map (/. I (if (= (hd (tl I)) T) (append I [[C | Fields]]) I)) Acc)
                                [[type T [C | Fields]] | Acc])))

(define literal->data
  [aggregate V count _ Atom _] -> [= [var V] [count Atom]]
  [aggregate V Op T Atom _] -> [= [var V] [Op [var T] Atom]]
  L -> L)

\\ Copies to make, as [[Rel Adorn] ...]: gives [Rules Copies Full], Full what must be complete.
(define adorn
  [] Done Full _ _ Acc -> [Acc (reverse Done) Full]
  [Copy | Queue] Done Full Rules Derived Acc
  -> (if (element? Copy Done)
         (adorn Queue Done Full Rules Derived Acc)
         (adorn-each (rules-of (hd Copy) Rules) Copy Queue [Copy | Done] Full Rules Derived Acc)))

(define rules-of
  _ [] -> []
  Rel [[[Rel | Terms] Body] | Rules] -> [[[Rel | Terms] Body] | (rules-of Rel Rules)]
  Rel [_ | Rules] -> (rules-of Rel Rules))

(define adorn-each
  [] _ Queue Done Full Rules Derived Acc -> (adorn Queue Done Full Rules Derived Acc)
  [Rule | More] [Rel Adorn] Queue Done Full Rules Derived Acc
  -> (let R (adorn-rule Rule Adorn Derived Full)
       (adorn-each More [Rel Adorn] (append Queue (hd (tl R))) Done
         (union (hd (tl (tl R))) Full) Rules Derived (append Acc (hd R)))))

\\ A rule's copy for Adorn, and a magic rule for each copy it reads: [Rules Copies Complete].
(define adorn-rule
  [[Rel | Terms] Body] Adorn Derived Full
  -> (let Magic [(magic-name Rel Adorn) | (at-bound Terms Adorn)]
          Conditions (conditions Body)
          Order (sips (atoms Body) Conditions (term-vars (at-bound Terms Adorn) []))
          Atoms (map (/. A (adorn-atom A Derived Full)) Order)
          Data (map (function literal->data) Conditions)
       [[[[(adorned-name Rel Adorn) | Terms] [Magic | (append (map (function hd) Atoms) Data)]]
         | (magic-rules Atoms Magic Conditions [])]
        (mapcan (/. A (tl (tl A))) Atoms)
        (union (complete-relations Body) (difference (map (function hd) (atoms Body)) Derived))]))

\\ [Atom' Bound | Copy]: the atom, a copy's if its relation is derived and not complete, with
\\ what is bound before it.
(define adorn-atom
  [[Rel | Terms] Bound] Derived Full
  -> (if (and (element? Rel Derived) (not (element? Rel Full)))
         (let Adorn (map (/. T (if (known? T Bound) b f)) Terms)
           [[(adorned-name Rel Adorn) | Terms] Bound [Rel Adorn]])
         [[Rel | Terms] Bound]))

(define magic-rules
  [] _ _ _ -> []
  [[Atom Bound | Copy] | Atoms] Magic Conditions Before
  -> (let More (magic-rules Atoms Magic Conditions (append Before [Atom]))
       (if (empty? Copy)
           More
           (let Vars (term-vars (tl Magic) (term-vars (mapcan (function tl) Before) []))
                Ready (hd (close-conditions Conditions Vars))
                Head [(magic-name (hd (hd Copy)) (hd (tl (hd Copy)))) | (at-bound (tl Atom) (hd (tl (hd Copy))))]
             [[Head [Magic | (append Before (map (function literal->data) Ready))]] | More]))))

\\ The order in which bindings pass, [[Atom Bound] ...]: the planner's with no sizes, and the
\\ conditions that bind more as soon as they can.
(define sips
  [] _ _ -> []
  Atoms Conditions Bound
  -> (let B (hd (tl (close-conditions Conditions Bound)))
          Atom (best Atoms B [])
       [[Atom B] | (sips (remove-one Atom Atoms) Conditions (term-vars (tl Atom) B))]))

\\ The conditions that can run given what is bound, and what is bound after: [Ready Bound].
(define close-conditions
  Conditions Bound -> (close-h Conditions Bound [] [] false))

(define close-h
  [] Bound Ready _ false -> [(reverse Ready) Bound]
  [] Bound Ready Left true -> (close-h (reverse Left) Bound Ready [] false)
  [C | Cs] Bound Ready Left Progress
  -> (let B (binder C Bound)
       (cases (subset? (condition-vars C) Bound) (close-h Cs Bound [C | Ready] Left Progress)
              (= B none) (close-h Cs Bound Ready [C | Left] Progress)
              true (close-h Cs [(hd B) | Bound] [C | Ready] Left true))))

\\ These relations and all they depend on.
(define full-closure
  Full Rules -> (let More (union Full (mapcan (/. R (depends R Rules)) Full))
                  (if (same-set? More Full) Full (full-closure More Rules))))

\\ ---------------------------------------------------------------------------
\\ Sorting, for a result that does not depend on the order of evaluation.

(define value<
  A B -> (tuple< A B) where (and (cons? A) (cons? B))
  A _ -> false where (cons? A)
  _ B -> true where (cons? B)
  A B -> (< A B) where (and (number? A) (number? B))
  A _ -> true where (number? A)
  _ B -> false where (number? B)
  A B -> (text< (str A) (str B)) where (= (string? A) (string? B))
  A _ -> (string? A))

(define text<
  "" "" -> false
  "" _ -> true
  _ "" -> false
  A B -> (let X (string->n (pos A 0))
              Y (string->n (pos B 0))
           (cases (< X Y) true
                  (> X Y) false
                  true (text< (tlstr A) (tlstr B)))))

(define tuple<
  [] [] -> false
  [] _ -> true
  _ [] -> false
  [A | As] [B | Bs] -> (cases (value< A B) true
                              (value< B A) false
                              true (tuple< As Bs)))

(define split
  [] A B -> (@p A B)
  [X | Xs] A B -> (split Xs [X | B] A))

(define merge-sorted
  [] Bs Acc -> (append (reverse Acc) Bs)
  As [] Acc -> (append (reverse Acc) As)
  [A | As] [B | Bs] Acc -> (if (tuple< B A)
                               (merge-sorted [A | As] Bs [B | Acc])
                               (merge-sorted As [B | Bs] [A | Acc])))

(define sort
  [] -> []
  [X] -> [X]
  Xs -> (let Halves (split Xs [] [])
          (merge-sorted (sort (fst Halves)) (sort (snd Halves)) [])))

(define sorted
  Db Rel -> (sort (tuples Db Rel)))

\\ ---------------------------------------------------------------------------
\\ The surface: forms to the data above. The reader has turned [a b] into cons forms.

(define unbracket
  [cons H T] -> [H | (unbracket T)]
  X -> X)

(define item
  [relation Name Types] -> [relation Name (unbracket Types)]
  [relation Name Types Mode] -> [relation Name (unbracket Types) Mode]
  [type Name | Constructors] -> [type Name | (map (function unbracket) Constructors)]
  [rule Head <-- | Body] -> [rule (unbracket-atom Head) (map (function unbracket-literal) Body)]
  [rule Head] -> [rule (unbracket-atom Head) []]
  Form -> (error "defdatalog: ~R is neither (relation Name [Types]), with equivalence, min, max or choice after for such, (type Name [Constructor Types] ...) nor (rule Head <-- Body)" Form))

\\ In a rule, brackets are records: [cons X P] is the term of constructor cons.
(define unbracket-literal
  [not Atom] -> [not (unbracket-atom Atom)]
  [Op A B] -> [Op (unbracket-side A) (unbracket-side B)] where (comparison? Op)
  Atom -> (unbracket-atom Atom))

(define unbracket-side
  [count Atom] -> [count (unbracket-atom Atom)]
  [Op T Atom] -> [Op T (unbracket-atom Atom)] where (aggregate? Op)
  T -> (unbracket-term T))

(define unbracket-atom
  [Rel | Terms] -> [Rel | (map (function unbracket-term) Terms)]
  X -> X)

(define unbracket-term
  [cons H T] -> [(unbracket-term H) | (unbracket-term T)]
  [X | Xs] -> (map (function unbracket-term) [X | Xs])
  X -> X)

\\ A form building the data, with variables as [var "X"] and _ as [any]: left as they are they
\\ would be read as Shen's own variables.
(define quote
  [] -> []
  [H | T] -> [cons (quote H) (quote T)]
  X -> [cons any []] where (and (symbol? X) (= (str X) "_"))
  X -> [cons var [cons (str X) []]] where (variable? X)
  X -> X)

(defmacro macro
  [defdatalog Name | Items] -> [datalog.define Name (quote (map (function item) Items))]
  [ask Db Atom] -> [match Db (quote (unbracket-atom Atom))]
  [query Name Facts Atom] -> [solve Name Facts (quote (unbracket-atom Atom))])

)

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

(set datalog.*adaptive* true)
(set datalog.*plans* 0)

\\ ---------------------------------------------------------------------------
\\ Checking a program.

(define datalog.comparison?
  X -> (element? X [< > <= >= = !=]))

(define datalog.ordering?
  X -> (element? X [< > <= >=]))

\\ An integer column holds 32 bits, signed, as itself; symbols and strings are interned.
(define datalog.int32?
  X -> (and (integer? X) (>= X -2147483648) (<= X 2147483647)
            (trap-error (do (shen-jit.bit-or X 0) true) (/. E false))))

(define datalog.value-type
  X -> symbol where (symbol? X)
  X -> string where (string? X)
  X -> integer where (datalog.int32? X)
  _ -> none)

\\ The 32 bits a column holds for an integer, and back.
(define datalog.int-word
  X -> (if (< X 0) (+ X 4294967296) X))

(define datalog.word-int
  W -> (if (> W 2147483647) (- W 4294967296) W))

(define datalog.term->form
  [var Name] -> (intern Name)
  [any] -> (intern "_")
  [F | Args] -> [F | (map (/. T (datalog.term->form T)) Args)]
  X -> X)

(define datalog.atom->form
  [Rel | Terms] -> [Rel | (map (/. T (datalog.term->form T)) Terms)]
  X -> X)

(define datalog.rule->form
  Head [] -> (datalog.atom->form Head)
  Head Body -> [(datalog.atom->form Head) <-- | (map (/. A (datalog.literal->form A)) Body)])

(define datalog.literal->form
  [not Atom] -> [not (datalog.atom->form Atom)]
  [aggregate V count _ Atom _] -> [= (intern V) [count (datalog.atom->form Atom)]]
  [aggregate V Op T Atom _] -> [= (intern V) [Op (intern T) (datalog.atom->form Atom)]]
  [= A B] -> [= (datalog.aggregate->form A) (datalog.aggregate->form B)]
  Literal -> (datalog.atom->form Literal))

(define datalog.aggregate->form
  [count Atom] -> [count (datalog.atom->form Atom)]
  [Op T Atom] -> [Op (datalog.term->form T) (datalog.atom->form Atom)] where (datalog.aggregate? Op)
  T -> (datalog.term->form T))

(define datalog.relations
  _ _ [] Acc -> (reverse Acc)
  Name Known [[relation Rel Types] | Items] Acc
  -> (cases (or (not (symbol? Rel)) (variable? Rel) (datalog.comparison? Rel) (element? Rel [not aggregate]))
            (error "datalog ~A: ~S cannot name a relation" Name Rel)
            (cons? (assoc Rel Acc))
            (error "datalog ~A: relation ~A is declared twice" Name Rel)
            (not (datalog.types? Types Known))
            (error "datalog ~A: relation ~A has columns ~S, which are not a list of symbol, string, integer or declared types" Name Rel Types)
            true (datalog.relations Name Known Items [[Rel | Types] | Acc]))
  Name Known [[rule | _] | Items] Acc -> (datalog.relations Name Known Items Acc)
  Name Known [[type | _] | Items] Acc -> (datalog.relations Name Known Items Acc)
  Name _ [Item | _] _ -> (error "datalog ~A: ~S is neither a relation, a type nor a rule" Name Item))

(define datalog.types?
  [] _ -> true
  [T | Ts] Known -> (and (element? T [symbol string integer | Known]) (datalog.types? Ts Known))
  _ _ -> false)

\\ The variables' types so far, as [["X" | symbol] ...]; each atom of the body adds to them.
(define datalog.check-atom
  Say Relations Env [Rel | Terms]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (datalog.check-terms Say Terms (tl Types) Env)))
  Say _ _ Atom -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.check-terms
  _ [] [] Env -> Env
  Say [[any] | Terms] [_ | Types] Env -> (datalog.check-terms Say Terms Types Env)
  Say [[var V] | Terms] [Type | Types] Env
  -> (let Known (assoc V Env)
       (cases (empty? Known) (datalog.check-terms Say Terms Types [[V | Type] | Env])
              (= (tl Known) Type) (datalog.check-terms Say Terms Types Env)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say [X | Terms] [Type | Types] Env
  -> (datalog.check-terms Say Terms Types
       (datalog.check-terms Say (tl X) (datalog.fields-of Say X Type) Env))
     where (cons? X)
  Say [X | Terms] [Type | Types] Env
  -> (if (= (datalog.value-type X) Type)
         (datalog.check-terms Say Terms Types Env)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define datalog.term-type
  Say Env [var V] -> (let Known (assoc V Env)
                       (if (empty? Known)
                           (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
                           (tl Known)))
  Say _ [any] -> (error "datalog ~A: _ cannot be compared" Say)
  Say Env [Op A B] -> (if (and (= (datalog.term-type Say Env A) integer) (= (datalog.term-type Say Env B) integer))
                          integer
                          (error "datalog ~A: ~A works on integers" Say Op))
                      where (datalog.arithmetic? Op)
  Say Env [C | Args] -> (let Con (datalog.constructor-of Say [C | Args])
                          (do (datalog.check-field-types Say Env Args (datalog.nth 4 Con))
                              (datalog.nth 2 Con)))
  Say _ X -> (let Type (datalog.value-type X)
               (if (= Type none)
                   (error "datalog ~A: ~S is not a value" Say X)
                   Type)))

(define datalog.check-comparison
  Say Env [Op A B]
  -> (let TA (datalog.term-type Say Env A)
          TB (datalog.term-type Say Env B)
       (cases (not (= TA TB)) (error "datalog ~A: ~A and ~A are compared" Say TA TB)
              (and (datalog.ordering? Op) (not (= TA integer)))
              (error "datalog ~A: ~A orders integers" Say Op)
              true Env))
  Say _ Form -> (error "datalog ~A: ~S is not a comparison" Say Form))

\\ A literal of a body is an atom, a comparison, a negated atom or an aggregate; all but the first
\\ are conditions.
(define datalog.atom?
  [Op | _] -> (not (or (datalog.comparison? Op) (element? Op [not aggregate])))
  _ -> true)

\\ (not Atom): no tuple of that relation matches, with every variable in it bound elsewhere.
(define datalog.check-condition
  Say Relations Env [not [Rel | Terms]]
  -> (do (datalog.check-head Say Env Relations [Rel | Terms] true) Env)
  Say _ _ [not Atom] -> (error "datalog ~A: ~S is not an atom" Say Atom)
  Say Relations Env [aggregate V Op Target Atom Keys]
  -> (datalog.check-aggregate Say Relations Env V Op Target Atom Keys)
  Say _ Env Comparison -> (datalog.check-comparison Say Env Comparison))

\\ ---------------------------------------------------------------------------
\\ Aggregates: (= N (count Atom)), and (sum W Atom), (min W Atom) and (max W Atom) over a variable
\\ of the atom. A variable of the atom that appears elsewhere in the body is a key, bound first;
\\ the others are its own, and W must be one of them. Over no tuples, count and sum give 0, and min
\\ and max nothing, so that the rule does not hold. The checker turns each into [aggregate V Op
\\ Target Atom Keys], Target none for count.

(define datalog.aggregate?
  X -> (element? X [count sum min max]))

(define datalog.aggregate-form?
  [count _] -> true
  [Op _ _] -> (datalog.aggregate? Op)
  _ -> false)

(define datalog.aggregate-condition?
  [= A B] -> (or (datalog.aggregate-form? A) (datalog.aggregate-form? B))
  _ -> false)

(define datalog.normalize
  Say Body -> (map (/. L (if (datalog.aggregate-condition? L)
                              (datalog.normalize-aggregate Say L (datalog.remove-one L Body))
                              L))
                   Body))

(define datalog.normalize-aggregate
  Say [= [var V] Agg] Others -> (datalog.aggregate-of Say V Agg Others) where (datalog.aggregate-form? Agg)
  Say [= Agg [var V]] Others -> (datalog.aggregate-of Say V Agg Others) where (datalog.aggregate-form? Agg)
  Say L _ -> (error "datalog ~A: an aggregate stands on one side of =, with a variable on the other, not as in ~R"
                    Say (datalog.literal->form L)))

(define datalog.aggregate-of
  Say V [count Atom] Others -> (datalog.aggregate-h Say V count none Atom Others)
  Say V [Op [var T] Atom] Others -> (datalog.aggregate-h Say V Op T Atom Others)
  Say _ Agg _ -> (error "datalog ~A: ~R is not an aggregate" Say (datalog.aggregate->form Agg)))

(define datalog.aggregate-h
  Say V Op Target [Rel | Terms] Others
  -> (let Own (datalog.term-vars Terms [])
          Keys (datalog.keep-in Own (datalog.body-vars Others))
       (cases (element? V Own)
              (error "datalog ~A: ~A is what the aggregate gives, and in what it reads" Say V)
              (and (not (= Target none)) (not (element? Target Own)))
              (error "datalog ~A: ~A, which ~A reads, is not in its atom" Say Target Op)
              (element? Target Keys)
              (error "datalog ~A: ~A, which ~A reads, must appear only in its atom" Say Target Op)
              true [aggregate V Op Target [Rel | Terms] Keys]))
  Say _ _ _ Atom _ -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.keep-in
  [] _ -> []
  [X | Xs] Ys -> (if (element? X Ys) [X | (datalog.keep-in Xs Ys)] (datalog.keep-in Xs Ys)))

\\ The variables a body's literals name, in any position.
(define datalog.body-vars
  [] -> []
  [L | Ls] -> (union (datalog.literal-vars L) (datalog.body-vars Ls)))

(define datalog.literal-vars
  [not [_ | Terms]] -> (datalog.term-vars Terms [])
  [aggregate V _ _ [_ | Terms] _] -> [V | (datalog.term-vars Terms [])]
  [= A B] -> (union (datalog.aggregate-vars A) (datalog.aggregate-vars B))
  [Op A B] -> (union (datalog.expr-vars A) (datalog.expr-vars B)) where (datalog.comparison? Op)
  [_ | Terms] -> (datalog.term-vars Terms []))

(define datalog.aggregate-vars
  [count [_ | Terms]] -> (datalog.term-vars Terms [])
  [Op T [_ | Terms]] -> (union (datalog.expr-vars T) (datalog.term-vars Terms [])) where (datalog.aggregate? Op)
  E -> (datalog.expr-vars E))

\\ Its keys must be bound, its own variables are typed by its atom, and what it reads is an integer.
(define datalog.check-aggregate
  Say Relations Env V Op Target [Rel | Terms] Keys
  -> (let Unbound (difference Keys (map (function hd) Env))
          _ (if (cons? Unbound) (error "datalog ~A: ~A is not bound by an atom of the body" Say (hd Unbound)) skip)
          Inner (datalog.check-atom Say Relations Env [Rel | Terms])
          _ (if (and (not (= Target none)) (not (= (tl (assoc Target Inner)) integer)))
                (error "datalog ~A: ~A reads integers" Say Op)
                skip)
          Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) integer) Env
              true (error "datalog ~A: ~A is ~A, and an aggregate gives an integer" Say V (tl Known)))))

(define datalog.atoms
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) [L | (datalog.atoms Ls)] (datalog.atoms Ls)))

(define datalog.conditions
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) (datalog.conditions Ls) [L | (datalog.conditions Ls)]))

(define datalog.check-all
  _ _ Env [] -> Env
  F Say Env [L | Ls] -> (datalog.check-all F Say (F Say Env L) Ls))

\\ An atom whose variables are all bound already: a head, or one that is negated, which alone can
\\ hold _.
(define datalog.check-head
  Say Env Relations [Rel | Terms] Negated
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (datalog.check-head-terms Say Env Terms (tl Types) Negated)))
  Say _ _ Atom _ -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.check-head-terms
  _ _ [] [] _ -> true
  Say Env [[any] | Terms] [_ | Types] true -> (datalog.check-head-terms Say Env Terms Types true)
  Say _ [[any] | _] _ false -> (error "datalog ~A: a head cannot hold _" Say)
  Say _ [[any] | _] _ record -> (error "datalog ~A: a record in a negated atom cannot hold _" Say)
  Say Env [[var V] | Terms] [Type | Types] Negated
  -> (let Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) Type) (datalog.check-head-terms Say Env Terms Types Negated)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say Env [X | Terms] [Type | Types] Negated
  -> (do (datalog.check-head-terms Say Env (tl X) (datalog.fields-of Say X Type) (if (= Negated false) false record))
         (datalog.check-head-terms Say Env Terms Types Negated))
     where (cons? X)
  Say Env [X | Terms] [Type | Types] Negated
  -> (if (= (datalog.value-type X) Type)
         (datalog.check-head-terms Say Env Terms Types Negated)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define datalog.check-rule
  Name Relations Head Written
  -> (let Say (make-string "~A, rule ~R" Name (datalog.rule->form Head Written))
          Body (datalog.normalize Say Written)
          Atoms (datalog.check-all (/. S E A (datalog.check-atom S Relations E A)) Say [] (datalog.atoms Body))
          Env (datalog.check-binders Say (datalog.conditions Body) Atoms)
          _ (datalog.check-all (/. S E C (datalog.check-condition S Relations E C)) Say Env (datalog.conditions Body))
          _ (datalog.check-head Say Env Relations Head false)
       [Head Body]))

\\ Arithmetic on integers: (+ A B), (- A B) and (* A B), nested as deep as wanted.
(define datalog.arithmetic?
  X -> (element? X [+ - *]))

(define datalog.expr-vars
  [var V] -> [V]
  [_ | Args] -> (datalog.term-vars Args [])
  _ -> [])

(define datalog.bound?
  Vars Env -> (datalog.subset? Vars (map (function hd) Env)))

\\ (= V E), where V is not bound yet and everything in E is, binds V. What binds one variable can
\\ make another's ready, so this goes on until nothing more is bound.
(define datalog.binder
  [= [var V] B] Bound -> [V B] where (and (not (element? V Bound)) (datalog.subset? (datalog.expr-vars B) Bound))
  [= A [var V]] Bound -> [V A] where (and (not (element? V Bound)) (datalog.subset? (datalog.expr-vars A) Bound))
  [aggregate V Op Target Atom Keys] Bound
  -> [V [aggregate V Op Target Atom Keys]] where (and (not (element? V Bound)) (datalog.subset? Keys Bound))
  _ _ -> none)

(define datalog.binding-type
  Say Env [aggregate | _] -> integer
  Say Env E -> (datalog.term-type Say Env E))

(define datalog.check-binders
  Say Conditions Env -> (datalog.check-binders-h Say Conditions Env Conditions false))

(define datalog.check-binders-h
  _ [] Env _ false -> Env
  Say [] Env All true -> (datalog.check-binders-h Say All Env All false)
  Say [C | Cs] Env All Progress
  -> (let B (datalog.binder C (map (function hd) Env))
       (if (= B none)
           (datalog.check-binders-h Say Cs Env All Progress)
           (datalog.check-binders-h Say Cs [[(hd B) | (datalog.binding-type Say Env (hd (tl B)))] | Env] All true))))

\\ The relations a body reads, and of those, the ones that must be complete before it runs.
(define datalog.body-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (datalog.body-relations Ls))
  [[aggregate _ _ _ [Rel | _] _] | Ls] -> (adjoin Rel (datalog.body-relations Ls))
  [L | Ls] -> (if (datalog.atom? L) (adjoin (hd L) (datalog.body-relations Ls)) (datalog.body-relations Ls)))

(define datalog.complete-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (datalog.complete-relations Ls))
  [[aggregate _ _ _ [Rel | _] _] | Ls] -> (adjoin Rel (datalog.complete-relations Ls))
  [_ | Ls] -> (datalog.complete-relations Ls))

\\ A relation cannot depend on the negation or an aggregate of one that depends on it: there would
\\ be no single answer. What each relation reaches comes from the plans' datalog.reach.
(define datalog.check-strata
  Name Relations Rules
  -> (let Graph (map (/. R [(hd R) | (datalog.depends (hd R) Rules)]) Relations)
          Reach (datalog.reach Graph)
       (map (/. R (datalog.check-rule-strata Name R Reach)) Rules)))

(define datalog.check-rule-strata
  Name [[Head | Terms] Body] Reach
  -> (map (/. N (cases (= N Head)
                       (error "datalog ~A, rule ~R: ~A depends on its own negation or aggregate"
                              Name (datalog.rule->form [Head | Terms] Body) Head)
                       (element? Head (tl (assoc N Reach)))
                       (error "datalog ~A, rule ~R: ~A depends on the negation or an aggregate of ~A, which depends on ~A"
                              Name (datalog.rule->form [Head | Terms] Body) Head N Head)
                       true ok))
          (datalog.complete-relations Body)))

\\ Each relation's stratum, as [[Rel | N] ...]: at least that of each relation its rules read, and
\\ one more than that of each they need complete. The reference evaluates by these.
(define datalog.strata
  Relations Rules -> (datalog.strata-h Rules (map (/. R [(hd R) | 0]) Relations)))

(define datalog.strata-h
  Rules S -> (let Next (datalog.strata-round Rules S)
               (if (= Next S) S (datalog.strata-h Rules Next))))

(define datalog.strata-round
  [] S -> S
  [[[Head | _] Body] | Rules] S
  -> (datalog.strata-round Rules (datalog.raise Head (datalog.body-stratum Body S) S)))

(define datalog.body-stratum
  [] _ -> 0
  [[not [Rel | _]] | Ls] S -> (datalog.max (+ 1 (tl (assoc Rel S))) (datalog.body-stratum Ls S))
  [[aggregate _ _ _ [Rel | _] _] | Ls] S -> (datalog.max (+ 1 (tl (assoc Rel S))) (datalog.body-stratum Ls S))
  [L | Ls] S -> (if (datalog.atom? L)
                    (datalog.max (tl (assoc (hd L) S)) (datalog.body-stratum Ls S))
                    (datalog.body-stratum Ls S)))

(define datalog.raise
  Rel N [[Rel | M] | S] -> [[Rel | (datalog.max N M)] | S]
  Rel N [X | S] -> [X | (datalog.raise Rel N S)])

(define datalog.max
  A B -> (if (> A B) A B))

(define datalog.rules
  _ _ [] -> []
  Name Relations [[relation | _] | Items] -> (datalog.rules Name Relations Items)
  Name Relations [[type | _] | Items] -> (datalog.rules Name Relations Items)
  Name Relations [[rule Head Body] | Items]
  -> [(datalog.check-rule Name Relations Head Body) | (datalog.rules Name Relations Items)]
  Name _ [Item | _] -> (error "datalog ~A: ~S is neither a relation nor a rule" Name Item))

\\ The constants to intern: integers are themselves.
(define datalog.term-constants
  [] Acc -> Acc
  [[var _] | Ts] Acc -> (datalog.term-constants Ts Acc)
  [[any] | Ts] Acc -> (datalog.term-constants Ts Acc)
  [[_ | Args] | Ts] Acc -> (datalog.term-constants (append Args Ts) Acc)
  [X | Ts] Acc -> (datalog.term-constants Ts Acc) where (integer? X)
  [X | Ts] Acc -> (datalog.term-constants Ts (adjoin X Acc)))

(define datalog.constants
  [] Acc -> (reverse Acc)
  [[[_ | Terms] Body] | Rules] Acc
  -> (datalog.constants Rules
       (datalog.body-constants Body (datalog.term-constants Terms Acc))))

(define datalog.body-constants
  [] Acc -> Acc
  [[not [_ | Terms]] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc))
  [[aggregate _ _ _ [_ | Terms] _] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc))
  [[_ | Terms] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc)))

\\ [program Name Relations Rules Constants Strata Constructors].
(define datalog.check
  Name Items -> (let Types (datalog.declared-types Name Items [])
                     Relations (datalog.relations Name (map (function hd) Types) Items [])
                     Constructors (datalog.constructor-table Name Types (length Relations))
                     _ (set datalog.*constructors* Constructors)
                     Rules (datalog.rules Name Relations Items)
                     _ (datalog.check-strata Name Relations Rules)
                  [program Name Relations Rules (datalog.constants Rules []) (datalog.strata Relations Rules) Constructors]))

(define datalog.define
  Name Items -> (let Program (datalog.check Name Items)
                  (do (put Name datalog.program Program)
                      (put Name datalog.schedule (datalog.make-schedule Program))
                      (put Name datalog.demands [])
                      (datalog.forget-code Name)
                      Name)))

(define datalog.forget-code
  Name -> (do (put Name datalog.compiled (shen.dict 8))
              (put Name datalog.indexes [])
              (put Name datalog.counter 0)))

(define datalog.program
  Name -> (trap-error (get Name datalog.program)
                      (/. E (error "datalog: no program ~A" Name))))

(define datalog.check-fact
  Relations Constructors [Rel | Values]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog: fact ~S has no relation" [Rel | Values])
              (not (= (length Values) (length (tl Types))))
              (error "datalog: fact ~S should have ~A values" [Rel | Values] (length (tl Types)))
              true (datalog.check-values [Rel | Values] Values (tl Types) Constructors)))
  _ _ Fact -> (error "datalog: ~S is not a fact" Fact))

(define datalog.check-values
  _ [] [] _ -> true
  Fact [V | Vs] [T | Ts] Cs -> (if (datalog.value-of? V T Cs)
                                   (datalog.check-values Fact Vs Ts Cs)
                                   (error "datalog: fact ~S has ~S in a column of type ~A" Fact V T)))

(define datalog.value-of?
  V integer _ -> (datalog.int32? V)
  V symbol _ -> (symbol? V)
  V string _ -> (string? V)
  [C | Vs] T Cs -> (let Con (assoc C Cs)
                     (and (cons? Con) (= (datalog.nth 2 Con) T) (datalog.values-of? Vs (datalog.nth 4 Con) Cs)))
  _ _ _ -> false)

(define datalog.values-of?
  [] [] _ -> true
  [V | Vs] [T | Ts] Cs -> (and (datalog.value-of? V T Cs) (datalog.values-of? Vs Ts Cs))
  _ _ _ -> false)

\\ ---------------------------------------------------------------------------
\\ Types of records: (type shape [circle integer] [rect integer integer]) declares a type and its
\\ constructors, and a value of it is a list headed by one, as [rect 2 3]; a record is a type of
\\ one constructor, and a field's type may be the type itself. A column of such a type holds the
\\ record's position in a table of its own, where a tuple is its constructor's number and its
\\ fields, as many as the widest constructor has: a record is interned, so equal records are equal
\\ words. The constructors are [[C Type Tag FieldTypes Slot Width] ...], Slot where the table is in
\\ a run's state, after the relations. Checking and generating code read them from here.

(set datalog.*constructors* [])

(define datalog.declared-types
  _ [] Acc -> (reverse Acc)
  Name [[type T | Constructors] | Items] Acc
  -> (cases (or (not (symbol? T)) (variable? T) (element? T [symbol string integer]))
            (error "datalog ~A: ~S cannot name a type" Name T)
            (cons? (assoc T Acc)) (error "datalog ~A: type ~A is declared twice" Name T)
            (empty? Constructors) (error "datalog ~A: type ~A has no constructors" Name T)
            true (datalog.declared-types Name Items [[T | Constructors] | Acc]))
  Name [_ | Items] Acc -> (datalog.declared-types Name Items Acc))

(define datalog.constructor-table
  Name Types N -> (datalog.constructor-table-h Name Types (map (function hd) Types) (+ N 1) []))

(define datalog.constructor-table-h
  _ [] _ _ Acc -> (reverse Acc)
  Name [[T | Cs] | Types] Known Slot Acc
  -> (let Width (+ 1 (datalog.widest Cs 0))
       (datalog.constructor-table-h Name Types Known (+ Slot 1)
         (datalog.constructors-of Name T Cs 0 Known Slot Width Acc))))

(define datalog.widest
  [] N -> N
  [[_ | Fields] | Cs] N -> (datalog.widest Cs (datalog.max N (length Fields)))
  [C | _] _ -> (error "datalog: ~S is not a constructor such as [point integer integer]" C))

(define datalog.constructors-of
  _ _ [] _ _ _ _ Acc -> Acc
  Name T [[C | Fields] | Cs] Tag Known Slot Width Acc
  -> (cases (or (not (symbol? C)) (variable? C) (element? C [var any + - * count sum min max]))
            (error "datalog ~A: ~S cannot name a constructor" Name C)
            (cons? (assoc C Acc)) (error "datalog ~A: constructor ~A is declared twice" Name C)
            (not (datalog.types? Fields Known))
            (error "datalog ~A: constructor ~A has fields ~S, which are not a list of symbol, string, integer or declared types" Name C Fields)
            true (datalog.constructors-of Name T Cs (+ Tag 1) Known Slot Width [[C T Tag Fields Slot Width] | Acc])))

(define datalog.constructor
  C -> (assoc C (value datalog.*constructors*)))

\\ The constructor of a record term, checked against its arity.
(define datalog.constructor-of
  Say [C | Args] -> (let Con (datalog.constructor C)
                      (cases (empty? Con) (error "datalog ~A: ~S is not a value" Say [C | Args])
                             (not (= (length Args) (length (datalog.nth 4 Con))))
                             (error "datalog ~A: ~A takes ~A values, not ~A" Say C (length (datalog.nth 4 Con)) (length Args))
                             true Con)))

\\ The types of a record term's fields, where a value of type Type is wanted.
(define datalog.fields-of
  Say X Type -> (let Con (datalog.constructor-of Say X)
                  (if (= (datalog.nth 2 Con) Type)
                      (datalog.nth 4 Con)
                      (error "datalog ~A: ~R is not of type ~A" Say (datalog.term->form X) Type))))

(define datalog.check-field-types
  _ _ [] [] -> true
  Say Env [A | As] [T | Ts] -> (if (= (datalog.term-type Say Env A) T)
                                   (datalog.check-field-types Say Env As Ts)
                                   (error "datalog ~A: ~R is not of type ~A" Say (datalog.term->form A) T)))

\\ ---------------------------------------------------------------------------
\\ The reference: the plain definition, over lists. Every rule runs over every tuple until a round
\\ adds nothing. It shares only the checker with what follows, and the results must agree.

(define datalog.run-naive
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Rules (datalog.nth 4 Program)
          Strata (datalog.nth 6 Program)
          Check (map (/. F (datalog.check-fact Relations (datalog.nth 7 Program) F)) Facts)
          Tables (map (/. R [(hd R)]) Relations)
       [naive Name (datalog.naive-strata 0 (datalog.highest Strata 0) Rules Strata
                                        (datalog.naive-add-all Facts Tables))]))

\\ Each stratum's rules to a fixed point, lowest first, so that what one negates is complete.
(define datalog.naive-strata
  K Top Rules Strata Tables
  -> (if (> K Top)
         Tables
         (datalog.naive-strata (+ K 1) Top Rules Strata
           (datalog.naive-loop (datalog.in-stratum K Rules Strata) Tables))))

(define datalog.in-stratum
  _ [] _ -> []
  K [[[Head | Terms] Body] | Rules] Strata
  -> (if (= K (tl (assoc Head Strata)))
         [[[Head | Terms] Body] | (datalog.in-stratum K Rules Strata)]
         (datalog.in-stratum K Rules Strata)))

(define datalog.highest
  [] N -> N
  [[_ | M] | S] N -> (datalog.highest S (datalog.max M N)))

(define datalog.nth
  N [X | Xs] -> (if (= N 1) X (datalog.nth (- N 1) Xs)))

(define datalog.naive-add
  [Rel | Values] [[Rel | Tuples] | Tables]
  -> (if (element? Values Tuples)
         [[Rel | Tuples] | Tables]
         [[Rel Values | Tuples] | Tables])
  Fact [Table | Tables] -> [Table | (datalog.naive-add Fact Tables)])

(define datalog.naive-add-all
  [] Tables -> Tables
  [F | Fs] Tables -> (datalog.naive-add-all Fs (datalog.naive-add F Tables)))

(define datalog.naive-loop
  Rules Tables -> (let Next (datalog.naive-add-all (datalog.naive-round Rules Tables []) Tables)
                    (if (= Next Tables) Tables (datalog.naive-loop Rules Next))))

(define datalog.naive-round
  [] _ Acc -> Acc
  [[Head Body] | Rules] Tables Acc
  -> (datalog.naive-round Rules Tables
       (datalog.naive-body (datalog.atoms Body) (datalog.conditions Body) Head [] Tables Acc)))

(define datalog.naive-body
  [] Conditions [Rel | Terms] Env Tables Acc
  -> (let Bound (datalog.naive-bind Conditions Env Conditions false Tables)
       (if (and (not (= Bound no)) (datalog.naive-true? Conditions Bound Tables))
           [[Rel | (map (/. T (datalog.naive-value T Bound)) Terms)] | Acc]
           Acc))
  [[Rel | Terms] | Atoms] Comparisons Head Env Tables Acc
  -> (datalog.naive-tuples (tl (assoc Rel Tables)) Terms Atoms Comparisons Head Env Tables Acc))

(define datalog.naive-tuples
  [] _ _ _ _ _ _ Acc -> Acc
  [Tuple | Tuples] Terms Atoms Comparisons Head Env Tables Acc
  -> (let Bound (datalog.naive-match Terms Tuple Env)
          More (if (= Bound no)
                   Acc
                   (datalog.naive-body Atoms Comparisons Head Bound Tables Acc))
       (datalog.naive-tuples Tuples Terms Atoms Comparisons Head Env Tables More)))

(define datalog.naive-match
  [] [] Env -> Env
  [[any] | Ts] [_ | Vs] Env -> (datalog.naive-match Ts Vs Env)
  [[var X] | Ts] [V | Vs] Env
  -> (let Known (assoc X Env)
       (cases (empty? Known) (datalog.naive-match Ts Vs [[X | V] | Env])
              (= (tl Known) V) (datalog.naive-match Ts Vs Env)
              true no))
  [[C | Args] | Ts] [V | Vs] Env
  -> (let Inner (if (and (cons? V) (= C (hd V))) (datalog.naive-match Args (tl V) Env) no)
       (if (= Inner no) no (datalog.naive-match Ts Vs Inner)))
  [C | Ts] [V | Vs] Env -> (if (= C V) (datalog.naive-match Ts Vs Env) no))

(define datalog.naive-value
  [var X] Env -> (tl (assoc X Env))
  [Op A B] Env -> (datalog.arithmetic Op (datalog.naive-value A Env) (datalog.naive-value B Env))
                  where (datalog.arithmetic? Op)
  [C | Args] Env -> [C | (map (/. T (datalog.naive-value T Env)) Args)]
  C _ -> C)

\\ What each binding condition binds, until nothing more is; once bound, it holds as a comparison.
(define datalog.naive-bind
  [] Env _ false _ -> Env
  [] Env All true Tables -> (datalog.naive-bind All Env All false Tables)
  [C | Cs] Env All Progress Tables
  -> (let B (datalog.binder C (map (function hd) Env))
          Value (if (= B none) [] (datalog.naive-bound (hd (tl B)) Env Tables))
       (cases (= B none) (datalog.naive-bind Cs Env All Progress Tables)
              (empty? Value) no
              true (datalog.naive-bind Cs [[(hd B) | Value] | Env] All true Tables))))

(define datalog.naive-bound
  [aggregate V Op Target Atom Keys] Env Tables -> (datalog.naive-aggregate Op Target Atom Env Tables)
  E Env _ -> (datalog.naive-value E Env))

\\ An aggregate over the tuples its atom matches: [], which no value is, for min or max of none.
(define datalog.naive-aggregate
  Op Target [Rel | Terms] Env Tables
  -> (let Matches (datalog.naive-matches (tl (assoc Rel Tables)) Terms Env)
          Values (if (= Target none) [] (map (/. M (tl (assoc Target M))) Matches))
       (cases (= Op count) (length Matches)
              (= Op sum) (datalog.in-range (datalog.sum Values 0))
              (empty? Values) []
              (= Op min) (datalog.fold-pick (function <) Values)
              true (datalog.fold-pick (function >) Values))))

(define datalog.naive-matches
  [] _ _ -> []
  [Tuple | Tuples] Terms Env -> (let M (datalog.naive-match Terms Tuple Env)
                                  (if (= M no)
                                      (datalog.naive-matches Tuples Terms Env)
                                      [M | (datalog.naive-matches Tuples Terms Env)])))

(define datalog.sum
  [] Acc -> Acc
  [X | Xs] Acc -> (datalog.sum Xs (+ X Acc)))

(define datalog.fold-pick
  F [X | Xs] -> (datalog.fold-pick-h F Xs X))

(define datalog.fold-pick-h
  _ [] Best -> Best
  F [X | Xs] Best -> (datalog.fold-pick-h F Xs (if (F X Best) X Best)))

\\ Each operation on 32-bit integers raises if its result is not one.
(define datalog.arithmetic
  + A B -> (datalog.in-range (+ A B))
  - A B -> (datalog.in-range (- A B))
  * A B -> (datalog.in-range (* A B)))

(define datalog.in-range
  X -> (if (datalog.int32? X) X (error "datalog: arithmetic gave ~A, outside 32 bits" X)))

(define datalog.naive-true?
  [] _ _ -> true
  [[not [Rel | Terms]] | Rest] Env Tables
  -> (and (not (datalog.naive-any? (tl (assoc Rel Tables)) Terms Env))
          (datalog.naive-true? Rest Env Tables))
  [[aggregate V Op Target Atom Keys] | Rest] Env Tables
  -> (and (= (datalog.naive-aggregate Op Target Atom Env Tables) (tl (assoc V Env)))
          (datalog.naive-true? Rest Env Tables))
  [[Op A B] | Rest] Env Tables
  -> (and (datalog.compare Op (datalog.naive-value A Env) (datalog.naive-value B Env))
          (datalog.naive-true? Rest Env Tables)))

(define datalog.naive-any?
  [] _ _ -> false
  [Tuple | Tuples] Terms Env -> (or (not (= (datalog.naive-match Terms Tuple Env) no))
                                    (datalog.naive-any? Tuples Terms Env)))

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

(define datalog.depends
  Rel Rules -> (datalog.depends-h Rel Rules []))

(define datalog.depends-h
  _ [] Acc -> Acc
  Rel [[[Rel | _] Body] | Rules] Acc
  -> (datalog.depends-h Rel Rules (union (datalog.body-relations Body) Acc))
  Rel [_ | Rules] Acc -> (datalog.depends-h Rel Rules Acc))

\\ What each relation reaches, as [[Rel Reached ...] ...], grown until it stops.
(define datalog.reach
  Graph -> (let Next (map (/. Node [(hd Node) | (datalog.reach-from (tl Node) Graph (tl Node))]) Graph)
             (if (= Next Graph) Graph (datalog.reach Next))))

(define datalog.reach-from
  [] _ Acc -> Acc
  [R | Rs] Graph Acc -> (datalog.reach-from Rs Graph (union (tl (assoc R Graph)) Acc)))

(define datalog.component
  Rel Reach -> (datalog.unique [Rel | (datalog.mutual Rel (tl (assoc Rel Reach)) Reach)] []))

(define datalog.unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (datalog.unique Xs (adjoin X Acc)))

(define datalog.mutual
  _ [] _ -> []
  Rel [Rel | Rs] Reach -> (datalog.mutual Rel Rs Reach)
  Rel [R | Rs] Reach -> (if (element? Rel (tl (assoc R Reach)))
                            [R | (datalog.mutual Rel Rs Reach)]
                            (datalog.mutual Rel Rs Reach)))

(define datalog.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (datalog.subset? Xs Ys)))

(define datalog.same-set?
  A B -> (and (datalog.subset? A B) (datalog.subset? B A)))

(define datalog.seen?
  _ [] -> false
  C [D | Ds] -> (or (datalog.same-set? C D) (datalog.seen? C Ds)))

(define datalog.distinct-sets
  [] Acc -> (reverse Acc)
  [C | Cs] Acc -> (if (datalog.seen? C Acc)
                      (datalog.distinct-sets Cs Acc)
                      (datalog.distinct-sets Cs [C | Acc])))

\\ Components with nothing left waiting go first, in the order of the declarations.
(define datalog.order
  [] _ _ Acc -> (reverse Acc)
  Waiting Reach Done Acc -> (datalog.order-h Waiting Waiting Reach Done Acc))

(define datalog.order-h
  [C | Cs] Waiting Reach Done Acc
  -> (if (datalog.subset? (difference (datalog.reached-by C Reach) C) Done)
         (datalog.order (remove C Waiting) Reach (append C Done) [C | Acc])
         (datalog.order-h Cs Waiting Reach Done Acc)))

(define datalog.reached-by
  [] _ -> []
  [R | Rs] Reach -> (union (tl (assoc R Reach)) (datalog.reached-by Rs Reach)))

(define datalog.components
  Relations Rules
  -> (let Names (map (function hd) Relations)
          Graph (map (/. R [R | (datalog.depends R Rules)]) Names)
          Reach (datalog.reach Graph)
          Cs (datalog.distinct-sets (map (/. R (datalog.component R Reach)) Names) [])
       (datalog.order Cs Reach [] [])))

(define datalog.term-vars
  [] Acc -> Acc
  [[var V] | Ts] Acc -> (datalog.term-vars Ts (adjoin V Acc))
  [[_ | Args] | Ts] Acc -> (datalog.term-vars Ts (datalog.term-vars Args Acc))
  [_ | Ts] Acc -> (datalog.term-vars Ts Acc))

(define datalog.known?
  [var V] Bound -> (element? V Bound)
  [any] _ -> false
  [_ | Args] Bound -> (datalog.all-known? Args Bound)
  _ _ -> true)

(define datalog.all-known?
  [] _ -> true
  [T | Ts] Bound -> (and (datalog.known? T Bound) (datalog.all-known? Ts Bound)))

(define datalog.known-count
  [] _ -> 0
  [T | Ts] Bound -> (if (datalog.known? T Bound)
                        (+ 1 (datalog.known-count Ts Bound))
                        (datalog.known-count Ts Bound)))

\\ The next atom. With no sizes to go by, Est is [] and it is the one with the most columns already
\\ known, and the first written of those. With sizes, the one expected to give the fewest tuples.
(define datalog.best
  [A | As] Bound [] -> (datalog.best-h As Bound A (datalog.known-count (tl A) Bound))
  [A | As] Bound Est -> (datalog.cheapest As Bound Est A (Est A Bound)))

(define datalog.best-h
  [] _ Best _ -> Best
  [A | As] Bound Best N -> (let K (datalog.known-count (tl A) Bound)
                             (if (> K N)
                                 (datalog.best-h As Bound A K)
                                 (datalog.best-h As Bound Best N))))

(define datalog.cheapest
  [] _ _ Best _ -> Best
  [A | As] Bound Est Best N -> (let K (Est A Bound)
                                 (if (< K N)
                                     (datalog.cheapest As Bound Est A K)
                                     (datalog.cheapest As Bound Est Best N))))

\\ What to do with each column of an atom: [bind V i], [check T i], [unpack Record i Binds] for a
\\ record, Binds the variables it binds, or nothing.
(define datalog.columns
  [] _ _ -> []
  [[any] | Ts] I Bound -> (datalog.columns Ts (+ I 1) Bound)
  [[var V] | Ts] I Bound
  -> (if (element? V Bound)
         [[check [var V] I] | (datalog.columns Ts (+ I 1) Bound)]
         [[bind V I] | (datalog.columns Ts (+ I 1) [V | Bound])])
  [[F | Args] | Ts] I Bound
  -> (let Binds (reverse (difference (datalog.term-vars Args []) Bound))
       [[unpack [F | Args] I Binds] | (datalog.columns Ts (+ I 1) (append Binds Bound))])
  [C | Ts] I Bound -> [[check C I] | (datalog.columns Ts (+ I 1) Bound)])

(define datalog.key-columns
  [] _ _ -> []
  [T | Ts] I Bound -> (if (datalog.known? T Bound)
                          [I | (datalog.key-columns Ts (+ I 1) Bound)]
                          (datalog.key-columns Ts (+ I 1) Bound)))

(define datalog.key-terms
  [] _ -> []
  [T | Ts] Bound -> (if (datalog.known? T Bound)
                        [T | (datalog.key-terms Ts Bound)]
                        (datalog.key-terms Ts Bound)))

(define datalog.unkey
  [] _ _ -> []
  [T | Ts] I Bound -> (if (datalog.known? T Bound)
                          [[any] | (datalog.unkey Ts (+ I 1) Bound)]
                          [T | (datalog.unkey Ts (+ I 1) Bound)]))

(define datalog.bound-after
  [] Bound -> Bound
  [[bind V _] | Cs] Bound -> (datalog.bound-after Cs [V | Bound])
  [[unpack _ _ Binds] | Cs] Bound -> (datalog.bound-after Cs (append Binds Bound))
  [_ | Cs] Bound -> (datalog.bound-after Cs Bound))

\\ The conditions that can run now, as steps, those left, and what is bound after: [Steps Left
\\ Bound]. A negated atom is [absent Rel Keys Terms]: no tuple has these terms in these columns.
\\ (= V E) whose V is not bound is [assign V E], and may make others ready.
(define datalog.ready
  Conditions Bound -> (datalog.ready-h Conditions Bound [] [] false))

(define datalog.ready-h
  [] Bound Ready Left false -> [(reverse Ready) (reverse Left) Bound]
  [] Bound Ready Left true -> (let More (datalog.ready-h (reverse Left) Bound [] [] false)
                                [(append (reverse Ready) (hd More)) | (tl More)])
  [C | Cs] Bound Ready Left Progress
  -> (let B (datalog.binder C Bound)
       (cases (datalog.subset? (datalog.condition-vars C) Bound)
              (datalog.ready-h Cs Bound [(datalog.condition-step C Bound) | Ready] Left Progress)
              (= B none)
              (datalog.ready-h Cs Bound Ready [C | Left] Progress)
              true
              (datalog.ready-h Cs [(hd B) | Bound] [(datalog.binding-step (hd B) (hd (tl B)) Bound) | Ready] Left true))))

(define datalog.condition-vars
  [not [_ | Terms]] -> (datalog.term-vars Terms [])
  [aggregate V _ _ _ Keys] -> [V | Keys]
  [_ A B] -> (union (datalog.expr-vars A) (datalog.expr-vars B)))

(define datalog.condition-step
  [not [Rel | Terms]] Bound -> [absent Rel (datalog.key-columns Terms 1 Bound) (datalog.key-terms Terms Bound)]
  [aggregate | A] Bound -> (datalog.fold-step compare [aggregate | A] Bound)
  [Op A B] _ -> [filter Op A B])

(define datalog.binding-step
  V [aggregate | A] Bound -> (datalog.fold-step bind [aggregate | A] Bound)
  V E _ -> [assign V E])

\\ [fold Mode V Op Target Rel Keys KeyTerms Columns]: the aggregate over the tuples of Rel with
\\ these terms in the Keys columns, Columns saying what to do with the rest. Mode is bind, or
\\ compare when V is bound already.
(define datalog.fold-step
  Mode [aggregate V Op Target [Rel | Terms] _] Bound
  -> [fold Mode V Op Target Rel (datalog.key-columns Terms 1 Bound) (datalog.key-terms Terms Bound)
      (datalog.columns (datalog.unkey Terms 1 Bound) 1 Bound)])

\\ Steps for the atoms left, each a scan of its tuples or a lookup by its known columns. Those in
\\ Old read the old tuples only, and the rest all.
(define datalog.plan-steps
  [] _ Comparisons Head Bound _
  -> [[emit | Head]]
  Atoms Old Comparisons Head Bound Est
  -> (let Atom (datalog.best Atoms Bound Est)
          Source (if (element? Atom Old) old all)
       (datalog.plan-atom Atom Source (datalog.remove-one Atom Atoms)
         (if (= Source old) (datalog.remove-one Atom Old) Old) Comparisons Head Bound Est)))

(define datalog.remove-one
  X [X | Xs] -> Xs
  X [Y | Xs] -> [Y | (datalog.remove-one X Xs)])

(define datalog.plan-atom
  [Rel | Terms] Source Atoms Old Comparisons Head Bound Est
  -> (let Keys (datalog.key-columns Terms 1 Bound)
       (if (empty? Keys)
           (datalog.plan-scan Rel Source Terms Atoms Old Comparisons Head Bound Est)
           (let KeyTerms (datalog.key-terms Terms Bound)
                Rest (datalog.columns (datalog.unkey Terms 1 Bound) 1 Bound)
             (datalog.plan-next [lookup Rel Source Keys KeyTerms Rest] Rest Atoms Old Comparisons Head Bound Est)))))

(define datalog.plan-scan
  Rel Source Terms Atoms Old Comparisons Head Bound Est
  -> (let Columns (datalog.columns Terms 1 Bound)
       (datalog.plan-next [scan Rel Source Columns] Columns Atoms Old Comparisons Head Bound Est)))

(define datalog.plan-next
  Step Columns Atoms Old Comparisons Head Bound Est
  -> (let Split (datalog.ready Comparisons (datalog.bound-after Columns Bound))
       [Step | (append (hd Split) (datalog.plan-steps Atoms Old (hd (tl Split)) Head (hd (tl (tl Split))) Est))]))

(define datalog.plan-rule
  [Head Body] Est
  -> (let Split (datalog.ready (datalog.conditions Body) [])
       (append (hd Split) (datalog.plan-steps (datalog.atoms Body) [] (hd (tl Split)) Head (hd (tl (tl Split))) Est))))

\\ A variant: the atom at Position reads the new tuples, and goes first, and those at the positions
\\ in Old read the old ones.
(define datalog.plan-variant
  [Head Body] Position Old Est
  -> (let Atoms (datalog.atoms Body)
          Atom (datalog.nth Position Atoms)
          Others (datalog.without Position Atoms)
          Split (datalog.ready (datalog.conditions Body) [])
       (append (hd Split)
               (datalog.plan-scan (hd Atom) new (tl Atom) Others (map (/. P (datalog.nth P Atoms)) Old)
                 (hd (tl Split)) Head (hd (tl (tl Split))) Est))))

(define datalog.without
  1 [_ | Xs] -> Xs
  N [X | Xs] -> [X | (datalog.without (- N 1) Xs)])

(define datalog.positions-in
  [] _ _ -> []
  [[Rel | _] | As] I Component
  -> (if (element? Rel Component)
         [I | (datalog.positions-in As (+ I 1) Component)]
         (datalog.positions-in As (+ I 1) Component)))

(define datalog.head-in?
  [[Rel | _] _] Component -> (element? Rel Component))

(define datalog.rules-in
  [] _ -> []
  [R | Rs] C -> (if (datalog.head-in? R C)
                    [R | (datalog.rules-in Rs C)]
                    (datalog.rules-in Rs C)))

(define datalog.rule-positions
  [_ Body] C -> (datalog.positions-in (datalog.atoms Body) 1 C))

(define datalog.first-rules
  [] _ -> []
  [R | Rs] C -> (if (empty? (datalog.rule-positions R C))
                    [R | (datalog.first-rules Rs C)]
                    (datalog.first-rules Rs C)))

(define datalog.variants
  [] _ -> []
  [R | Rs] C -> (append (datalog.rule-variants R (datalog.rule-positions R C) [])
                        (datalog.variants Rs C)))

\\ [Rule Position Old] for each of these positions, Old those before it.
(define datalog.rule-variants
  _ [] _ -> []
  R [P | Ps] Before -> [[R P Before] | (datalog.rule-variants R Ps [P | Before])])

\\ For each component [Relations First Variants]: First the rules that read nothing of the
\\ component, run once, and Variants the rest as [Rule Position Old], run until nothing is new.
\\ What order each joins in is chosen when it runs.
(define datalog.make-schedule
  [program _ Relations Rules | _]
  -> (map (/. C (let In (datalog.rules-in Rules C)
                  [C (datalog.first-rules In C) (datalog.variants In C)]))
          (datalog.components Relations Rules)))

\\ The plan with no sizes to go by.
(define datalog.plans
  Name -> (map (/. C [(hd C)
                      (map (/. R (datalog.plan-rule R [])) (hd (tl C)))
                      (map (/. V (datalog.plan-variant (hd V) (hd (tl V)) (hd (tl (tl V))) [])) (hd (tl (tl C))))])
               (get Name datalog.schedule)))

\\ ---------------------------------------------------------------------------
\\ Storage. A relation's tuples are u32 columns, one after another in a byte buffer, which the
\\ collector does not scan, and its new tuples and those for the next round are ranges of that. A
\\ table of 64-bit entries, open addressed, finds a tuple or an index's key: the top half of each is
\\ the top half of its hash, which also says where it goes when the table grows, and the bottom half
\\ is the tuple's position plus one, 0 being empty. An index's chain of tuples with one key is
\\ a u32 for each tuple, the position plus one of the next.

(define datalog.stride
  0 -> 4
  N -> (* 4 N))

(set datalog.*kernels* (shen.dict 8))

(eval-kl [defun datalog.dict-find [d k] [shen-jit.dict-find d k]])
(shen.store-arity datalog.dict-find 2)

\\ A generated kernel, once, under its name. Kernels depend only on the shape of a tuple.
(define datalog.kernel
  Name Make -> (if (cons? (datalog.dict-find (value datalog.*kernels*) Name))
                   Name
                   (do (shen-jit.install-code [defun Name (thaw Make)])
                       (shen.dict-> (value datalog.*kernels*) Name true)
                       Name)))

(define datalog.kernel-name
  Prefix N Keys -> (intern (datalog.name-with Keys (cn Prefix (str N)))))

(define datalog.name-with
  [] Name -> Name
  [K | Ks] Name -> (datalog.name-with Ks (cn Name (cn "." (str K)))))

\\ The word registers and parameters of a kernel are named, as protect writes a variable.
(define datalog.column-parameter
  I -> (intern (cn "C" (str I))))

(define datalog.upto
  I N -> (if (> I N) [] [I | (datalog.upto (+ I 1) N)]))

\\ A multiplicative hash of word expressions, whose top half is what goes in the table.
(define datalog.hash-form
  [] -> (protect K)
  [C | Cs] -> (datalog.hash-more Cs [* C (protect K)]))

(define datalog.hash-more
  [] H -> H
  [C | Cs] H -> (datalog.hash-more Cs [* [bit-xor H C] (protect K)]))

(define datalog.hash-setup
  -> [[word (protect K) [bit-or [shift-left 2654435769 32] 2135587861]]])

(define datalog.offset-form
  Base 0 -> Base
  Base Off -> [+ Base Off])

\\ Add a tuple if it is not there: 1 if it was added, 0 if not, 2 if there is no room, for which
\\ datalog.grow makes room. Meta holds the count, the table's mask, how many tuples fit and how many
\\ derivations there have been, at 0, 8, 16 and 24.
(define datalog.insert-kernel
  N -> (datalog.kernel (datalog.kernel-name "datalog.k.insert." N [])
         (freeze (datalog.insert-code N))))

(define datalog.insert-code
  N -> (datalog.table-code (datalog.kernel-name "datalog.k.insert." N []) N 1 0 2))

\\ Find a record, or add it: its position plus one, or 0 if there is no room.
(define datalog.intern-kernel
  N -> (datalog.kernel (datalog.kernel-name "datalog.k.intern." N [])
         (freeze (datalog.table-code (datalog.kernel-name "datalog.k.intern." N []) N
                   [+ (protect Count) 1] [bit-and (protect E) 4294967295] 0))))

(define datalog.table-code
  Name N Added Present Full
  -> (let Cols (map (function datalog.column-parameter) (datalog.upto 1 N))
         (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Meta) | Cols]
           (append (datalog.hash-setup)
             [[word (protect Count) [u64 (protect Meta) 0]]
              [u64! (protect Meta) 24 [+ [u64 (protect Meta) 24] 1]]
              [word (protect Fp) [shift-right (datalog.hash-form Cols) 32]]
              [word (protect Mask) [u64 (protect Meta) 8]]
              [word (protect I) [bit-and (protect Fp) (protect Mask)]]
              [while true
                [word (protect Off) [shift-left (protect I) 3]]
                [word (protect E) [u64 (protect Table) (protect Off)]]
                [when [= (protect E) 0]
                  [unless [< (protect Count) [u64 (protect Meta) 16]] [return-word Full]]
                  [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
                  [word (protect P) [* (protect Count) (datalog.stride N)]]
                  [do | (datalog.store-columns Cols 0)]
                  [u64! (protect Meta) 0 [+ (protect Count) 1]]
                  [return-word Added]]
                [when [= [shift-right (protect E) 32] (protect Fp)]
                  [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                  [when [and | (datalog.same-columns Cols 0)] [return-word Present]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

(define datalog.store-columns
  [] _ -> []
  [C | Cs] Off -> [[u32! (protect Tuples) (datalog.offset-form (protect P) Off) C]
                   | (datalog.store-columns Cs (+ Off 4))])

\\ Tests that the tuple at P holds these values.
(define datalog.same-columns
  [] _ -> []
  [C | Cs] Off -> [[= [u32 (protect Tuples) (datalog.offset-form (protect P) Off)] C]
                   | (datalog.same-columns Cs (+ Off 4))])

\\ Where these key values are in a table: the position plus one of the tuple there, or 0.
(define datalog.find-kernel
  N Keys -> (datalog.kernel (datalog.kernel-name "datalog.k.find." N Keys)
              (freeze (datalog.find-code N Keys))))

(define datalog.key-offsets
  Keys -> (map (/. K (* 4 (- K 1))) Keys))

(define datalog.same-keys
  [] [] -> []
  [Off | Offs] [C | Cs]
  -> [[= [u32 (protect Tuples) (datalog.offset-form (protect P) Off)] C] | (datalog.same-keys Offs Cs)])

(define datalog.find-code
  N Keys
  -> (let Cols (map (function datalog.column-parameter) (datalog.upto 1 (length Keys)))
          Name (datalog.kernel-name "datalog.k.find." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Mask) | Cols]
         (append (datalog.hash-setup)
           [[word (protect Fp) [shift-right (datalog.hash-form Cols) 32]]
            [word (protect I) [bit-and (protect Fp) (protect Mask)]]
            [while true
              [word (protect E) [u64 (protect Table) [shift-left (protect I) 3]]]
              [when [= (protect E) 0] [return-word 0]]
              [when [= [shift-right (protect E) 32] (protect Fp)]
                [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                [when [and | (datalog.same-keys (datalog.key-offsets Keys) Cols)]
                  [return-word [bit-and (protect E) 4294967295]]]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

\\ Adds the tuples from From up to To to an index, whose table has room, and gives how many keys
\\ were new. A tuple goes at the head of its key's chain.
(define datalog.index-kernel
  N Keys -> (datalog.kernel (datalog.kernel-name "datalog.k.index." N Keys)
              (freeze (datalog.index-code N Keys))))

(define datalog.tuple-columns
  [] _ -> []
  [Off | Offs] Base -> [[u32 (protect Tuples) (datalog.offset-form Base Off)] | (datalog.tuple-columns Offs Base)])

\\ Tests that the tuples at Q and Base have the same keys.
(define datalog.same-tuples
  [] -> []
  [Off | Offs]
  -> [[= [u32 (protect Tuples) (datalog.offset-form (protect Q) Off)]
         [u32 (protect Tuples) (datalog.offset-form (protect Base) Off)]]
      | (datalog.same-tuples Offs)])

(define datalog.index-code
  N Keys
  -> (let Offs (datalog.key-offsets Keys)
          Name (datalog.kernel-name "datalog.k.index." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Next) (protect Tuples) (protect Mask) (protect From) (protect To)]
         (append (datalog.hash-setup)
           [[word (protect D) 0]
            [word (protect Mk) (protect Mask)]
            [for (protect Pos) (protect From) (protect To)
              [word (protect Base) [* (protect Pos) (datalog.stride N)]]
              [word (protect Fp) [shift-right (datalog.hash-form (datalog.tuple-columns Offs (protect Base))) 32]]
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
                  [word (protect Q) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                  [when [and | (datalog.same-tuples Offs)]
                    [u32! (protect Next) [shift-left (protect Pos) 2] [bit-and (protect E) 4294967295]]
                    [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Pos) 1]]]
                    [exit probe]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mk)]]]]
            [return-word (protect D)]]))))

\\ Moves a table's entries to a larger one.
(define datalog.rehash-code
  -> (shen-jit.assemble datalog.k.rehash [(protect New) (protect Old) (protect Mask) (protect Size)]
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

(datalog.kernel datalog.k.rehash (freeze (datalog.rehash-code)))

\\ A relation's record: 0 where its indexes end, 1 those in use, 2 its tuples, 3 its table, 4 its
\\ meta, 5 and 6 the tuples that are new, by position, those before 6 being all that a round reads,
\\ 7 the bytes of a tuple, and each index from 8, by a number kept with the program across runs. A
\\ run starts only those it looks up. An index is a vector of its table, chain, mask and keys.
(define datalog.new-relation
  Arity
  -> (let Room (+ 8 (shen-jit.shift-left 1 (if (> Arity 6) 6 Arity)))
          R (absvector Room)
          Stride (datalog.stride Arity)
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
       R))

(define datalog.count-of
  Rec -> (shen-jit.s64 (<-address Rec 4) 0))

\\ A larger table, its entries moved.
(define datalog.larger-table
  Old OldSize NewSize
  -> (let New (shen-jit.bytes (* 8 NewSize))
          _ (datalog.k.rehash New Old (- NewSize 1) OldSize)
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
                (do (address-> Rec 3 (datalog.larger-table (<-address Rec 3) Size NewSize))
                    (shen-jit.s64! Meta 8 (- NewSize 1))))
          _ (shen-jit.s64! Meta 16 (let Half (shen-jit.shift-right NewSize 1) (if (< Half NewFits) Half NewFits)))
       true))

\\ ---------------------------------------------------------------------------
\\ Generating KL. The relations' records and the values are in a vector S, read by position.

(define datalog.position
  X [X | _] N -> N
  X [_ | Ys] N -> (datalog.position X Ys (+ N 1)))

(define datalog.relation-slot
  Rel Relations -> (datalog.position Rel (map (function hd) Relations) 1))

(define datalog.index-slot
  Rel Keys Indexes -> (datalog.position Keys (tl (assoc Rel Indexes)) 8))

(define datalog.steps-indexes
  [] _ Acc -> Acc
  [Step | Steps] Relations Acc
  -> (let Index (datalog.step-index Step Relations)
       (datalog.steps-indexes Steps Relations
         (if (= Index none) Acc (datalog.add-index (hd Index) (hd (tl Index)) Acc)))))

\\ Keys that are every column need no index: the relation's own table finds them. A negated atom
\\ with no keys needs only to know whether the relation is empty.
(define datalog.whole-tuple?
  Rel Keys Relations -> (= (length Keys) (datalog.arity-in Rel Relations)))

\\ The index a step looks up, as [Rel Keys], or none.
(define datalog.step-index
  [lookup Rel _ Keys | _] Relations -> (datalog.index-of Rel Keys Relations)
  [absent Rel Keys | _] Relations -> (datalog.index-of Rel Keys Relations)
  [fold _ _ _ _ Rel Keys | _] Relations -> (datalog.index-of Rel Keys Relations)
  _ _ -> none)

(define datalog.index-of
  Rel Keys Relations -> (if (or (empty? Keys) (datalog.whole-tuple? Rel Keys Relations)) none [Rel Keys]))

(define datalog.arity-in
  Rel Relations -> (- (length (assoc Rel Relations)) 1))

(define datalog.add-index
  Rel Keys [] -> [[Rel Keys]]
  Rel Keys [[Rel | Ks] | Rest] -> [[Rel | (if (element? Keys Ks) Ks (append Ks [Keys]))] | Rest]
  Rel Keys [Other | Rest] -> [Other | (datalog.add-index Rel Keys Rest)])

\\ A term's word: an integer's 32 bits, or an interned value's number.
(define datalog.value-form
  [var V] _ -> (datalog.var-symbol V)
  C _ -> (datalog.int-word C) where (integer? C)
  E Constants -> [datalog.int-word (datalog.number-form E Constants)] where (datalog.expression? E)
  [F | Args] Constants
  -> (let Con (datalog.constructor F)
          Words (datalog.pad [(datalog.nth 3 Con) | (map (/. T (datalog.value-form T Constants)) Args)] (datalog.nth 6 Con))
       [datalog.record-id s (datalog.nth 5 Con) (datalog.list-form Words)])
  C Constants -> (datalog.position C Constants 0))

(define datalog.list-form
  [] -> []
  [X | Xs] -> [cons X (datalog.list-form Xs)])

\\ A record term, as data: not a variable, _ or arithmetic.
(define datalog.record-term?
  [F | _] -> (not (element? F [var any + - *]))
  _ -> false)

\\ Whether a type has more than one constructor, so that its records' tags need checking.
(define datalog.tagged?
  T -> (> (length (mapcan (/. C (if (= (hd (tl C)) T) [C] [])) (value datalog.*constructors*))) 1))

(define datalog.var-symbol
  V -> (intern (cn "V" V)))

\\ An integer term's value, signed, from its word.
(define datalog.number-form
  [var V] _ -> (let W (datalog.var-symbol V) [if [> W 2147483647] [- W 4294967296] W])
  [Op A B] Constants -> [datalog.in-range [Op (datalog.number-form A Constants) (datalog.number-form B Constants)]]
                        where (datalog.arithmetic? Op)
  C _ -> C)

(define datalog.expression?
  [Op _ _] -> (datalog.arithmetic? Op)
  _ -> false)

\\ Values of one type are equal when their words are; an expression is compared as a number.
(define datalog.filter-form
  = A B Constants -> [= (datalog.number-form A Constants) (datalog.number-form B Constants)]
                     where (or (datalog.expression? A) (datalog.expression? B))
  != A B Constants -> [not (datalog.filter-form = A B Constants)]
  = A B Constants -> [= (datalog.value-form A Constants) (datalog.value-form B Constants)]
  Op A B Constants -> [Op (datalog.number-form A Constants) (datalog.number-form B Constants)])

\\ What [assign V E] binds V to: a word, as a column would hold.
(define datalog.assign-form
  E Constants -> [datalog.int-word (datalog.number-form E Constants)] where (datalog.expression? E)
  E Constants -> (datalog.value-form E Constants))

(define datalog.step-uses
  [filter _ A B] -> (union (datalog.expr-vars A) (datalog.expr-vars B))
  [assign _ E] -> (datalog.expr-vars E)
  [fold bind _ _ _ _ _ Terms _] -> (datalog.term-vars Terms [])
  [fold compare V _ _ _ _ Terms _] -> (adjoin V (datalog.term-vars Terms []))
  [absent _ _ Terms] -> (datalog.term-vars Terms [])
  [emit _ | Terms] -> (datalog.term-vars Terms [])
  [scan _ _ Columns] -> (datalog.columns-use Columns)
  [lookup _ _ _ Terms Columns] -> (datalog.term-vars Terms (datalog.columns-use Columns)))

(define datalog.columns-use
  [] -> []
  [[check T _] | Cs] -> (datalog.term-vars [T] (datalog.columns-use Cs))
  [[unpack T _ Binds] | Cs] -> (union (difference (datalog.term-vars [T] []) Binds) (datalog.columns-use Cs))
  [_ | Cs] -> (datalog.columns-use Cs))

(define datalog.step-binds
  [scan _ _ Columns] -> (datalog.columns-bind Columns)
  [lookup _ _ _ _ Columns] -> (datalog.columns-bind Columns)
  [assign V _] -> [V]
  [fold bind V | _] -> [V]
  _ -> [])

(define datalog.columns-bind
  [] -> []
  [[bind V _] | Cs] -> [V | (datalog.columns-bind Cs)]
  [[unpack _ _ Binds] | Cs] -> (append Binds (datalog.columns-bind Cs))
  [_ | Cs] -> (datalog.columns-bind Cs))

\\ What the steps need from before them, for the parameters of a loop.
(define datalog.live
  [] -> []
  [Step | Steps] -> (union (datalog.step-uses Step)
                           (difference (datalog.live Steps) (datalog.step-binds Step))))

(define datalog.loop-name
  Prefix N -> (intern (cn Prefix (cn ".s" (str N)))))

(define datalog.loop-live
  Columns Steps
  -> (map (function datalog.var-symbol)
          (difference (union (datalog.columns-use Columns) (datalog.live Steps))
                      (datalog.columns-bind Columns))))

\\ Add a tuple to the relation in r, growing it if it must. Its first attempt found no room and
\\ changed nothing, so that a second is the whole of it.
(define datalog.insert-form
  N Forms
  -> (let Kernel (datalog.insert-kernel N)
          Call [Kernel [<-address r 3] [<-address r 2] [<-address r 4] | Forms]
       [let x Call [if [= x 2] [do [datalog.grow r] Call] x]]))

\\ The expression for these steps. Each atom's loop is a function of its own, so that it is a
\\ self tail call and named in a backtrace; those go to datalog.*forms*. Ctx is Relations,
\\ Constants and Indexes. A loop keeps the buffer it started with: a round can only add to a
\\ relation it reads, what it reads is already in that buffer, and growing leaves it as it is.
(define datalog.gen
  [] _ _ _ -> true
  [[filter Op A B] | Steps] Ctx Prefix N
  -> [if (datalog.filter-form Op A B (datalog.nth 2 Ctx)) (datalog.gen Steps Ctx Prefix N) true]
  [[assign V E] | Steps] Ctx Prefix N
  -> [let (datalog.var-symbol V) (datalog.assign-form E (datalog.nth 2 Ctx)) (datalog.gen Steps Ctx Prefix N)]
  [[fold Mode V Op Target Rel Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Ctx [Relations Constants Indexes]
          Rest (datalog.gen Steps Ctx Prefix (+ N 1))
       [let r [<-address s (datalog.relation-slot Rel Relations)]
         [let a (datalog.fold-form Op Target Rel Keys Terms Columns Ctx Prefix N)
           (cases (= Mode compare) [if [= (if (= Op sum) [datalog.in-range a] a) (datalog.number-form [var V] Constants)] Rest true]
                  (element? Op [min max]) [if [= a none] true [let (datalog.var-symbol V) [datalog.int-word a] Rest]]
                  true [let (datalog.var-symbol V) [datalog.int-word [datalog.in-range a]] Rest])]])
  [[absent Rel Keys Terms] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (datalog.relation-slot Rel Relations)]
       [if (datalog.found-form Rel Keys Terms [Relations Constants Indexes])
           true
           (datalog.gen Steps [Relations Constants Indexes] Prefix N)]]
  [[emit Rel | Terms] | _] [Relations Constants Indexes] _ _
  -> [let r [<-address s (datalog.relation-slot Rel Relations)]
       (datalog.insert-form (datalog.arity-in Rel Relations)
         (map (/. T (datalog.value-form T Constants)) Terms))]
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Stride (datalog.stride (datalog.arity-in Rel Relations))
          Start (if (= Source new) [* [<-address r 5] Stride] 0)
          End (if (= Source old) [* [<-address r 5] Stride] [* [<-address r 6] Stride])
       [let r [<-address s (datalog.relation-slot Rel Relations)]
         (datalog.gen-scan Start End Stride Columns Steps [Relations Constants Indexes] Prefix N)])
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Forms (map (/. T (datalog.value-form T Constants)) Terms)
          Find (datalog.find-kernel (datalog.arity-in Rel Relations) Keys)
          Ctx [Relations Constants Indexes]
       [let r [<-address s (datalog.relation-slot Rel Relations)]
         (if (datalog.whole-tuple? Rel Keys Relations)
             [let p [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms]
               [if (if (= Source old) [and [> p 0] [<= p [<-address r 5]]] [> p 0])
                   (datalog.gen Steps Ctx Prefix N)
                   true]]
             (let Field (datalog.index-slot Rel Keys Indexes)
                  Stride (datalog.stride (datalog.arity-in Rel Relations))
                  First [Find [<-address i 0] [<-address r 2] [<-address i 2] | Forms]
               [let i [<-address r Field]
                 [let p (if (= Source old) [datalog.skip-chain First [<-address i 1] [<-address r 5]] First)
                   [if [> p 0]
                       (datalog.gen-chain Stride Columns Steps Ctx Prefix N)
                       true]]]))]))

\\ Whether the relation in r has a tuple with these terms in these columns.
(define datalog.found-form
  _ [] _ _ -> [> [<-address r 6] 0]
  Rel Keys Terms [Relations Constants Indexes]
  -> (let Forms (map (/. T (datalog.value-form T Constants)) Terms)
          Find (datalog.find-kernel (datalog.arity-in Rel Relations) Keys)
       (if (datalog.whole-tuple? Rel Keys Relations)
           [> [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms] 0]
           (let I [<-address r (datalog.index-slot Rel Keys Indexes)]
             [> [Find [<-address I 0] [<-address r 2] [<-address I 2] | Forms] 0]))))

\\ A loop over the tuples from byte Start to byte End of the relation in r.
(define datalog.gen-scan
  Start End Stride Columns Steps Ctx Prefix N
  -> (let Name (datalog.loop-name Prefix N)
          Live (datalog.loop-live Columns Steps)
          Body (datalog.gen-columns Columns l (datalog.nth 2 Ctx) (datalog.gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [l e b s | Live]
                 [if [< l e]
                     [do Body [Name [+ l Stride] e b s | Live]]
                     true]]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       [Name Start End [<-address r 2] s | Live]))

\\ The first of a chain's tuples, given as position plus one, from before position Limit: a chain
\\ runs from the newest.
(define datalog.skip-chain
  P Next Limit -> (if (> P Limit) (datalog.skip-chain (shen-jit.u32 Next (* 4 (- P 1))) Next Limit) P))

\\ A loop along a chain, from p and the index in i of the relation in r.
(define datalog.gen-chain
  Stride Columns Steps Ctx Prefix N
  -> (let Name (datalog.loop-name Prefix N)
          Live (datalog.loop-live Columns Steps)
          Body (datalog.gen-columns Columns l (datalog.nth 2 Ctx) (datalog.gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [p n b s | Live]
                 [if [> p 0]
                     [let q [- p 1]
                       [let l [* q Stride]
                         [do Body [Name [shen-jit.u32 n [* q 4]] n b s | Live]]]]
                     true]]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       [Name p [<-address i 1] [<-address r 2] s | Live]))

(define datalog.column-form
  Base I -> [shen-jit.u32 b (if (= I 1) Base [+ Base (* 4 (- I 1))])])

\\ In order, as a check reads only what a column before it bound.
(define datalog.gen-columns
  Columns Base Constants Inner -> (datalog.gen-columns-or Columns Base Constants Inner true))

\\ The same, giving Otherwise when a check fails.
(define datalog.gen-columns-or
  [] _ _ Inner _ -> Inner
  [[bind V I] | Cs] Base Constants Inner Otherwise
  -> [let (datalog.var-symbol V) (datalog.column-form Base I) (datalog.gen-columns-or Cs Base Constants Inner Otherwise)]
  [[check Term I] | Cs] Base Constants Inner Otherwise
  -> [if [= (datalog.column-form Base I) (datalog.value-form Term Constants)]
         (datalog.gen-columns-or Cs Base Constants Inner Otherwise)
         Otherwise]
  [[unpack Term I Binds] | Cs] Base Constants Inner Otherwise
  -> (datalog.gen-unpack [Term] [(datalog.column-form Base I)] Binds Constants
       (datalog.gen-columns-or Cs Base Constants Inner Otherwise) Otherwise))

\\ Terms matched against these words: a record's fields are read from its table once its tag is
\\ checked, and a variable in Binds is bound where it first appears.
(define datalog.gen-unpack
  [] [] _ _ Inner _ -> Inner
  [[any] | Ts] [_ | Ws] Binds Constants Inner Otherwise -> (datalog.gen-unpack Ts Ws Binds Constants Inner Otherwise)
  [[var V] | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> [let (datalog.var-symbol V) W (datalog.gen-unpack Ts Ws (remove V Binds) Constants Inner Otherwise)]
     where (element? V Binds)
  [[F | Args] | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> (let Con (datalog.constructor F)
          Id (gensym w)
          Stride (datalog.stride (datalog.nth 6 Con))
          Tuples [<-address [<-address s (datalog.nth 5 Con)] 2]
          Fields (map (/. J [shen-jit.u32 Tuples [+ [* Id Stride] (* 4 J)]]) (datalog.upto 1 (length Args)))
          Rest (datalog.gen-unpack (append Args Ts) (append Fields Ws) Binds Constants Inner Otherwise)
       [let Id W (if (datalog.tagged? (datalog.nth 2 Con))
                     [if [= [shen-jit.u32 Tuples [* Id Stride]] (datalog.nth 3 Con)] Rest Otherwise]
                     Rest)])
     where (datalog.record-term? [F | Args])
  [T | Ts] [W | Ws] Binds Constants Inner Otherwise
  -> [if [= W (datalog.value-form T Constants)] (datalog.gen-unpack Ts Ws Binds Constants Inner Otherwise) Otherwise])

\\ An aggregate's accumulator a, given the next value t: none until min or max has seen one.
(define datalog.fold-init
  count -> 0
  sum -> 0
  _ -> none)

(define datalog.fold-update
  count _ -> [+ a 1]
  sum T -> [+ a T]
  min T -> [let t T [if [= a none] t [if [< t a] t a]]]
  max T -> [let t T [if [= a none] t [if [> t a] t a]]])

\\ What a fold gives: a loop over the relation in r, or for a whole tuple's keys whether it is
\\ there.
(define datalog.fold-form
  Op Target Rel Keys Terms Columns [Relations Constants Indexes] Prefix N
  -> (let Stride (datalog.stride (datalog.arity-in Rel Relations))
          Update (datalog.fold-update Op (if (= Target none) 0 (datalog.number-form [var Target] Constants)))
          Name (datalog.loop-name Prefix N)
          Body (datalog.gen-columns-or Columns l Constants Update a)
       (cases (empty? Keys)
              (do (set datalog.*forms* [[defun Name [l e b s a]
                                          [if [< l e] [Name [+ l Stride] e b s Body] a]]
                                        | (value datalog.*forms*)])
                  [Name 0 [* [<-address r 6] Stride] [<-address r 2] s (datalog.fold-init Op)])
              (datalog.whole-tuple? Rel Keys Relations)
              [if (datalog.found-form Rel Keys Terms [Relations Constants Indexes]) 1 0]
              true
              (let Forms (map (/. T (datalog.value-form T Constants)) Terms)
                   Find (datalog.find-kernel (datalog.arity-in Rel Relations) Keys)
                   _ (set datalog.*forms* [[defun Name [p n b s a]
                                             [if [> p 0]
                                                 [let q [- p 1] [let l [* q Stride] [Name [shen-jit.u32 n [* q 4]] n b s Body]]]
                                                 a]]
                                           | (value datalog.*forms*)])
                [let i [<-address r (datalog.index-slot Rel Keys Indexes)]
                  [Name [Find [<-address i 0] [<-address r 2] [<-address i 2] | Forms]
                        [<-address i 1] [<-address r 2] s (datalog.fold-init Op)]]))))

(define datalog.gen-plan
  Steps Ctx Prefix
  -> (let Name (intern Prefix)
          Body (datalog.gen Steps Ctx Prefix 1)
          Form [defun Name [s] Body]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       Name))

(define datalog.next-name
  Name
  -> (let N (get Name datalog.counter)
          _ (put Name datalog.counter (+ N 1))
       (cn "datalog." (cn (str Name) (cn ".p" (str N))))))

\\ Generated functions are called from here as closures, which need no arity or lambda table entry.
(define datalog.callable
  Name -> (eval-kl [lambda x [Name x]]))

\\ A kernel's form shows what it was written as; it is installed already.
(define datalog.install
  Forms -> (map (/. F (if (= (hd F) define-native) skip (eval-kl F))) Forms))

\\ The code for these steps, kept with the program, as [Closure | Forms]. There are only so many
\\ orders a rule can join in.
(define datalog.compiled
  Name Steps Relations Constants
  -> (let Cache (get Name datalog.compiled)
          Entry (datalog.dict-find Cache Steps)
       (if (cons? Entry)
           (tl Entry)
           (let Ctx [Relations Constants (get Name datalog.indexes)]
                _ (set datalog.*constructors* (datalog.nth 7 (datalog.program Name)))
                Prefix (datalog.next-name Name)
                Fn (datalog.gen-either Steps Ctx Prefix)
                Forms (reverse (value datalog.*forms*))
                _ (datalog.install Forms)
                Code [(datalog.callable Fn) | Forms]
                _ (shen.dict-> Cache Steps Code)
             Code))))

\\ ---------------------------------------------------------------------------
\\ Native joins. A plan becomes one kernel of word registers, written with lib/native.shen's
\\ structured control, which looks up, compares and inserts inline and calls nothing. A variable
\\ costs no register: it is read from its tuple's column where it is used. When a relation it adds
\\ to has no room, the kernel gives where its outer loop stood, plus one, and a KL function grows
\\ the relation and calls it again from there, as deriving a tuple twice does no harm. A plan the
\\ registers cannot hold, or anything else the assembler refuses, stays KL.

(set datalog.*native* true)
(set datalog.*fallbacks* 0)
(set datalog.*labels* 0)

(define datalog.gen-either
  Steps Ctx Prefix
  -> (if (value datalog.*native*)
         (trap-error (do (set datalog.*forms* []) (datalog.native-plan Steps Ctx Prefix))
                     (/. E (do (set datalog.*fallbacks* (+ 1 (value datalog.*fallbacks*)))
                               (set datalog.*forms* [])
                               (datalog.gen-plan Steps Ctx Prefix))))
         (do (set datalog.*forms* []) (datalog.gen-plan Steps Ctx Prefix))))

(define datalog.word-name
  Prefix N -> (intern (cn Prefix (str N))))

\\ A kernel's parameter, as [Name | KL form computing it from s and start], each once.
(define datalog.param
  Name Form -> (do (if (cons? (assoc Name (value datalog.*params*)))
                       skip
                       (set datalog.*params* (append (value datalog.*params*) [[Name | Form]])))
                   Name))

(define datalog.record-form
  Slot -> [<-address s Slot])

(define datalog.tuples-param
  Slot -> (datalog.param (datalog.word-name "Tup" Slot) [<-address (datalog.record-form Slot) 2]))

(define datalog.mask
  -> 4294967295)

\\ The word a term stands for: an integer's 32 bits, or an interned value.
(define datalog.native-value
  [var V] Env _ -> (tl (assoc V Env))
  C _ _ -> (datalog.int-word C) where (integer? C)
  C _ Constants -> (datalog.position C Constants 0))

\\ The integer a term stands for, signed: a column read as such, or a word's low half extended.
(define datalog.native-integer
  [var V] Env _ -> (datalog.signed (tl (assoc V Env)))
  C _ _ -> C)

(define datalog.signed
  [u32 Tuples Off] -> [s32 Tuples Off]
  [bit-and R 4294967295] -> R
  W -> [shift-right-signed [shift-left W 32] 32])

\\ A comparison, as statements that compute its expressions and the test after them.
(define datalog.native-test
  Op A B Env Ctx Outer
  -> (let Parts (datalog.native-terms [A B] Env Ctx Outer)
       [(hd Parts) [Op (hd (hd (tl Parts))) (hd (tl (hd (tl Parts))))]])
     where (and (element? Op [= !=]) (not (datalog.expression? A)) (not (datalog.expression? B)))
  Op A B Env Ctx _ -> (let L (datalog.native-operand A Env Ctx 1)
                         R (datalog.native-operand B Env Ctx 2)
                      [(append (hd L) (hd R)) [Op (hd (tl L)) (hd (tl R))]]))

\\ An integer operand as [Statements Form]: an expression is computed into Arith<D>, with what
\\ its operands need from Arith<D+1> on, so that the second operand leaves the first alone.
(define datalog.native-operand
  E Env Ctx D -> (let T (datalog.word-name "Arith" D)
                   [(datalog.native-compute E Env Ctx T (+ D 1)) T])
                 where (datalog.expression? E)
  E Env Ctx _ -> [[] (datalog.native-integer E Env Ctx)])

(define datalog.native-compute
  [Op A B] Env Ctx Target D
  -> (let L (datalog.native-operand A Env Ctx D)
          R (datalog.native-operand B Env Ctx (+ D 1))
       (append (hd L) (hd R)
               [[word Target [Op (hd (tl L)) (hd (tl R))]]
                [unless [u< [+ Target 2147483648] 4294967296] [return-word (datalog.overflow-code)]]])))

\\ What a kernel returns when arithmetic leaves 32 bits: more than any place to start again from.
(define datalog.overflow-code
  -> 1099511627776)

(define datalog.overflowed
  -> (error "datalog: arithmetic gave a value outside 32 bits"))

\\ Columns of the tuple whose first byte is Base in Tuples.
(define datalog.column-word
  Tuples Base I -> [u32 Tuples (datalog.offset-form Base (* 4 (- I 1)))])

\\ The variables an atom's columns bind, as the words that read them where used, and the checks
\\ on the rest, in order, as [Env Checks]: a check reads only what came before it, and a record's
\\ fields are read only once its tag is checked, as a field of another constructor may not be a
\\ record at all.
(define datalog.native-columns
  [] _ _ Env _ Checks -> [Env (reverse Checks)]
  [[bind V I] | Cs] Tuples Base Env Constants Checks
  -> (datalog.native-columns Cs Tuples Base [[V | (datalog.column-word Tuples Base I)] | Env] Constants Checks)
  [[check T I] | Cs] Tuples Base Env Constants Checks
  -> (datalog.native-columns Cs Tuples Base Env Constants
       [[= (datalog.column-word Tuples Base I) (datalog.native-value T Env Constants)] | Checks])
  [[unpack T I Binds] | Cs] Tuples Base Env Constants Checks
  -> (let Done (datalog.native-unpack [T] [(datalog.column-word Tuples Base I)] Binds Env Constants Checks)
       (datalog.native-columns Cs Tuples Base (hd Done) Constants (tl Done))))

\\ Terms matched against these words, as [Env | Checks].
(define datalog.native-unpack
  [] [] _ Env _ Checks -> [Env | Checks]
  [[any] | Ts] [_ | Ws] Binds Env Constants Checks -> (datalog.native-unpack Ts Ws Binds Env Constants Checks)
  [[var V] | Ts] [W | Ws] Binds Env Constants Checks
  -> (datalog.native-unpack Ts Ws (remove V Binds) [[V | W] | Env] Constants Checks) where (element? V Binds)
  [[F | Args] | Ts] [W | Ws] Binds Env Constants Checks
  -> (let Con (datalog.constructor F)
          Tuples (datalog.tuples-param (datalog.nth 5 Con))
          Base [* W (datalog.stride (datalog.nth 6 Con))]
          Fields (map (/. J [u32 Tuples [+ Base (* 4 J)]]) (datalog.upto 1 (length Args)))
          Tag (if (datalog.tagged? (datalog.nth 2 Con)) [[= [u32 Tuples Base] (datalog.nth 3 Con)]] [])
       (datalog.native-unpack (append Args Ts) (append Fields Ws) Binds Env Constants (append Tag Checks)))
     where (datalog.record-term? [F | Args])
  [T | Ts] [W | Ws] Binds Env Constants Checks
  -> (datalog.native-unpack Ts Ws Binds Env Constants [[= W (datalog.native-value T Env Constants)] | Checks]))

\\ Words for these terms, as [Statements Forms]: a record is made first, found or added in its
\\ table, into a register of its own.
(define datalog.native-terms
  [] _ _ _ -> [[] []]
  [T | Ts] Env Ctx Outer
  -> (let A (cases (datalog.record-term? T) (datalog.native-make T Env Ctx Outer)
                   (datalog.expression? T) (let R (datalog.native-label "Num")
                                             [(datalog.native-compute T Env Ctx R 1) [bit-and R 4294967295]])
                   true [[] (datalog.native-value T Env (hd (tl Ctx)))])
          B (datalog.native-terms Ts Env Ctx Outer)
       [(append (hd A) (hd B)) [(hd (tl A)) | (hd (tl B))]]))

(define datalog.native-make
  [F | Args] Env Ctx Outer
  -> (let Con (datalog.constructor F)
          Parts (datalog.native-terms Args Env Ctx Outer)
          Slot (datalog.nth 5 Con)
          R (datalog.native-label "Rec")
          _ (set datalog.*made* (adjoin Slot (value datalog.*made*)))
          Loop (datalog.native-label "make")
       [(append (hd Parts)
                (datalog.native-store Slot (datalog.stride (datalog.nth 6 Con))
                  (datalog.pad [(datalog.nth 3 Con) | (hd (tl Parts))] (datalog.nth 6 Con))
                  (datalog.again-code Outer) Loop
                  [[word R (protect Count)]]
                  [[word R [- [bit-and (protect E) (datalog.mask)] 1]]]))
        R]))

\\ Statements for these steps. Outer is the outermost scan's position, from which a kernel without
\\ room starts again; none before the first step, and restart when that step is not a scan.
(define datalog.native-steps
  [] _ _ _ _ -> []
  [[filter Op A B] | Steps] Ctx Env Level Outer
  -> (let Test (datalog.native-test Op A B Env Ctx Outer)
       (append (hd Test) [[when (hd (tl Test)) | (datalog.native-steps Steps Ctx Env Level Outer)]]))
  [[assign V E] | Steps] [Relations Constants | More] Env Level Outer
  -> (cases (datalog.expression? E)
            (let Target (intern (cn "Val." V))
              (append (datalog.native-compute E Env [Relations Constants | More] Target 1)
                      (datalog.native-steps Steps [Relations Constants | More]
                        [[V | [bit-and Target 4294967295]] | Env] Level Outer)))
            (datalog.record-term? E)
            (let Made (datalog.native-make E Env [Relations Constants | More] Outer)
              (append (hd Made)
                      (datalog.native-steps Steps [Relations Constants | More] [[V | (hd (tl Made))] | Env] Level Outer)))
            true
            (datalog.native-steps Steps [Relations Constants | More]
              [[V | (datalog.native-value E Env Constants)] | Env] Level Outer))
  [[absent Rel Keys Terms] | Steps] Ctx Env Level Outer
  -> (datalog.native-absent Rel Keys Terms Steps Ctx Env Level Outer)
  [[fold Mode V Op Target Rel Keys Terms Columns] | Steps] Ctx Env Level Outer
  -> (datalog.native-fold [Mode V Op Target Rel Keys Terms Columns] Steps Ctx Env Level Outer)
  [[emit Rel | Terms] | _] Ctx Env _ Outer -> (datalog.native-insert Rel Terms Ctx Env Outer)
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          From (if (and (= Outer none) (= Level 1))
                   (datalog.param (intern "Start") start)
                   (datalog.param (datalog.word-name "From" Level) (if (= Source new) [<-address (datalog.record-form Slot) 5] 0)))
          To (if (= Source old)
                 (datalog.old-param Slot)
                 (datalog.param (datalog.word-name "To" Level) [<-address (datalog.record-form Slot) 6]))
          P (datalog.word-name "P" Level)
          B (datalog.word-name "B" Level)
          Cols (datalog.native-columns Columns Tuples B Env Constants [])
       [[for P From To
          [word B [* P Stride]]
          | (datalog.guarded (hd (tl Cols))
              (datalog.native-steps Steps Ctx (hd Cols) (+ Level 1) (if (and (= Outer none) (= Level 1)) P (datalog.outer Outer))))]])
  [[lookup Rel Source Keys Terms Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Parts (datalog.native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
       (append (hd Parts)
               (if (datalog.whole-tuple? Rel Keys Relations)
                   (datalog.native-member Rel Source Slot Values Steps Ctx Env Level (datalog.outer Outer))
                   (datalog.native-chain Rel Source Slot Keys Values Columns Steps Ctx Env Level (datalog.outer Outer))))))

\\ Where the old tuples of the relation in Slot end, by position.
(define datalog.old-param
  Slot -> (datalog.param (datalog.word-name "Old" Slot) [<-address (datalog.record-form Slot) 5]))

\\ Only a scan at the outermost level can start again partway: below any other step, a kernel with
\\ no room starts again from the beginning.
(define datalog.outer
  none -> restart
  Outer -> Outer)

\\ The tuple these values make, if the relation has it, by its own table.
(define datalog.native-member
  Rel Source Slot Values Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
          Mask (datalog.param (datalog.word-name "Mask" Slot) [shen-jit.u32 [<-address (datalog.record-form Slot) 4] 8])
          Q (datalog.word-name "Q" Level)
          Probe (datalog.word-name "probe" Level)
          Same (datalog.equal-columns Tuples Q Values 1)
       (datalog.probe-loop Probe Values Table Mask Q Stride
         (if (= Source old) [[<= [bit-and (protect E) (datalog.mask)] (datalog.old-param Slot)] | Same] Same)
         [[do | (datalog.native-steps Steps [Relations Constants Indexes N] Env (+ Level 1) Outer)]
          [exit Probe]])))

\\ A table's probe for these values: Q is the byte of each tuple with their fingerprint, Matches
\\ whether it has them, and Found what follows if it does, which leaves the loop itself.
(define datalog.probe-loop
  Probe Values Table Mask Q Stride Matches Found
  -> [[word (protect Fp) [shift-right (datalog.hash-form Values) 32]]
      [word (protect I) [bit-and (protect Fp) Mask]]
      [while Probe true
        [word (protect E) [u64 Table [shift-left (protect I) 3]]]
        [when [= (protect E) 0] [exit Probe]]
        [when [= [shift-right (protect E) 32] (protect Fp)]
          [word Q [* [- [bit-and (protect E) (datalog.mask)] 1] Stride]]
          [when [and | Matches] | Found]]
        [word (protect I) [bit-and [+ (protect I) 1] Mask]]]])

\\ The steps after a negated atom, in a block that a tuple it matches leaves: by the relation's own
\\ table for a whole tuple, an index's table for some columns, and its size for none.
(define datalog.native-absent
  Rel Keys Terms Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Rest (datalog.native-steps Steps Ctx Env Level Outer)
          Parts (datalog.native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          Block (datalog.native-label "absent")
          Q (datalog.word-name "Q" Level)
       (append (hd Parts) (cases (empty? Keys)
              [[when [= (datalog.param (datalog.word-name "Size" Slot) [<-address (datalog.record-form Slot) 6]) 0] | Rest]]
              (datalog.whole-tuple? Rel Keys Relations)
              [[block Block
                 | (append (datalog.probe-loop (datalog.native-label "probe") Values
                             (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
                             (datalog.param (datalog.word-name "Mask" Slot) [shen-jit.u32 [<-address (datalog.record-form Slot) 4] 8])
                             Q Stride (datalog.equal-columns Tuples Q Values 1) [[exit Block]])
                           Rest)]]
              true
              (let Field (datalog.index-slot Rel Keys Indexes)
                   Index [<-address (datalog.record-form Slot) Field]
                [[block Block
                   | (append (datalog.probe-loop (datalog.native-label "probe") Values
                               (datalog.param (datalog.index-name "Itab" Slot Field) [<-address Index 0])
                               (datalog.param (datalog.index-name "Imask" Slot Field) [<-address Index 2])
                               Q Stride (datalog.equal-keys Tuples Q Keys Values) [[exit Block]])
                             Rest)]])))))

(define datalog.index-name
  Prefix Slot Field -> (intern (cn Prefix (cn (str Slot) (cn "x" (str Field))))))

\\ An aggregate in a register of its own, by a loop over the relation, a probe of its table for a
\\ whole tuple's keys, or a probe of an index and its chain; then the steps after it. min and max
\\ start from just outside 32 bits, where they stay if there was nothing.
(define datalog.native-fold
  [Mode V Op Target Rel Keys Terms Columns] Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          Acc (datalog.native-label "Agg")
          Parts (datalog.native-terms Terms Env Ctx Outer)
          Values (hd (tl Parts))
          P (datalog.word-name "P" Level)
          Q (datalog.word-name "Q" Level)
          Cols (datalog.native-columns Columns Tuples Q Env Constants [])
          Update (datalog.guarded (hd (tl Cols))
                   (datalog.native-fold-update Op Acc (if (= Target none) 0 (datalog.native-integer [var Target] (hd Cols) Ctx))))
          Loop (cases (empty? Keys)
                      [[for P 0 (datalog.param (datalog.word-name "Size" Slot) [<-address (datalog.record-form Slot) 6])
                         [word Q [* P Stride]] | Update]]
                      (datalog.whole-tuple? Rel Keys Relations)
                      (let Probe (datalog.native-label "probe")
                        (datalog.probe-loop Probe Values
                          (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
                          (datalog.param (datalog.word-name "Mask" Slot) [shen-jit.u32 [<-address (datalog.record-form Slot) 4] 8])
                          Q Stride (datalog.equal-columns Tuples Q Values 1) [[word Acc 1] [exit Probe]]))
                      true
                      (let Field (datalog.index-slot Rel Keys Indexes)
                           Index [<-address (datalog.record-form Slot) Field]
                           Probe (datalog.native-label "probe")
                        [[word P 0]
                         | (append (datalog.probe-loop Probe Values
                                     (datalog.param (datalog.index-name "Itab" Slot Field) [<-address Index 0])
                                     (datalog.param (datalog.index-name "Imask" Slot Field) [<-address Index 2])
                                     Q Stride (datalog.equal-keys Tuples Q Keys Values)
                                     [[word P [bit-and (protect E) (datalog.mask)]] [exit Probe]])
                                   [[while (datalog.native-label "chain") [> P 0]
                                      [word Q [* [- P 1] Stride]]
                                      [do | Update]
                                      [word P [u32 (datalog.param (datalog.index-name "Inext" Slot Field) [<-address Index 1])
                                                   [shift-left [- P 1] 2]]]]])]))
          Checked (if (= Op sum)
                      [[unless [u< [+ Acc 2147483648] 4294967296] [return-word (datalog.overflow-code)]]]
                      [])
          Bound [[V | [bit-and Acc 4294967295]] | Env]
          After (cases (= Mode compare)
                       [[when [= Acc (datalog.native-integer [var V] Env Ctx)] | (datalog.native-steps Steps Ctx Env Level Outer)]]
                       (element? Op [min max])
                       [[when [!= Acc (datalog.fold-start Op)] | (datalog.native-steps Steps Ctx Bound Level Outer)]]
                       true (datalog.native-steps Steps Ctx Bound Level Outer))
       (append (hd Parts) [[word Acc (datalog.fold-start Op)] | (append Loop (append Checked After))])))

(define datalog.fold-start
  min -> 2147483648
  max -> -2147483649
  _ -> 0)

(define datalog.native-fold-update
  count Acc _ -> [[word Acc [+ Acc 1]]]
  sum Acc T -> [[word Acc [+ Acc T]]]
  min Acc T -> [[when [< T Acc] [word Acc T]]]
  max Acc T -> [[when [> T Acc] [word Acc T]]])

\\ A name for a block or loop, of its own within a kernel.
(define datalog.native-label
  Kind -> (do (set datalog.*labels* (+ 1 (value datalog.*labels*)))
              (intern (cn Kind (cn "." (str (value datalog.*labels*)))))))

(define datalog.equal-columns
  _ _ [] _ -> []
  Tuples Base [V | Vs] I -> [[= (datalog.column-word Tuples Base I) V] | (datalog.equal-columns Tuples Base Vs (+ I 1))])

(define datalog.equal-keys
  _ _ [] [] -> []
  Tuples Base [K | Ks] [V | Vs] -> [[= (datalog.column-word Tuples Base K) V] | (datalog.equal-keys Tuples Base Ks Vs)])

\\ The tuples with these values for Keys, through an index: its table finds the first, and its chain
\\ the rest.
(define datalog.native-chain
  Rel Source Slot Keys Values Columns Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Field (datalog.index-slot Rel Keys Indexes)
          Index [<-address (datalog.record-form Slot) Field]
          Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.index-name "Itab" Slot Field) [<-address Index 0])
          Next (datalog.param (datalog.index-name "Inext" Slot Field) [<-address Index 1])
          Mask (datalog.param (datalog.index-name "Imask" Slot Field) [<-address Index 2])
          P (datalog.word-name "P" Level)
          Q (datalog.word-name "Q" Level)
          Probe (datalog.word-name "probe" Level)
          Chain (datalog.word-name "chain" Level)
          Cols (datalog.native-columns Columns Tuples Q Env Constants [])
       [[word P 0]
        | (append
            (datalog.probe-loop Probe Values Table Mask Q Stride (datalog.equal-keys Tuples Q Keys Values)
              [[word P [bit-and (protect E) (datalog.mask)]] [exit Probe]])
            (append
              (if (= Source old)
                  [[while (datalog.native-label "skip") [> P (datalog.old-param Slot)]
                     [word P [u32 Next [shift-left [- P 1] 2]]]]]
                  [])
              [[while Chain [> P 0]
                [word Q [* [- P 1] Stride]]
                [do | (datalog.guarded (hd (tl Cols)) (datalog.native-steps Steps Ctx (hd Cols) (+ Level 1) Outer))]
                [word P [u32 Next [shift-left [- P 1] 2]]]]]))]))

\\ Statements that run only when these checks hold.
(define datalog.guarded
  [] Statements -> Statements
  Checks Statements -> [[when [and | Checks] | Statements]])

\\ Adds the tuple these values make, as datalog.insert-kernel does, or gives where to start again.
(define datalog.native-insert
  Rel Terms [Relations Constants Indexes N] Env Outer
  -> (let Parts (datalog.native-terms Terms Env [Relations Constants Indexes N] Outer)
       (append (hd Parts)
               (datalog.native-store (datalog.relation-slot Rel Relations) (datalog.stride (datalog.arity-in Rel Relations))
                 (hd (tl Parts)) (datalog.again-code Outer) insert [] []))))

\\ What a kernel with no room returns: where to start again from, plus one.
(define datalog.again-code
  Outer -> (if (element? Outer [none restart]) 1 [+ Outer 1]))

\\ Adds the tuple of these values to the relation in Slot if it is not there, in a loop named Loop,
\\ which runs Added or Found before it leaves, or returns Again if there is no room.
(define datalog.native-store
  Slot Stride Values Again Loop Added Found
  -> (let Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
          Meta (datalog.param (datalog.word-name "Meta" Slot) [<-address (datalog.record-form Slot) 4])
       [[word (protect Count) [u64 Meta 0]]
        [u64! Meta 24 [+ [u64 Meta 24] 1]]
        [word (protect Fp) [shift-right (datalog.hash-form Values) 32]]
        [word (protect I) [bit-and (protect Fp) [u64 Meta 8]]]
        [while Loop true
          [word (protect E) [u64 Table [shift-left (protect I) 3]]]
          [when [= (protect E) 0]
            [unless [< (protect Count) [u64 Meta 16]] [return-word Again]]
            [u64! Table [shift-left (protect I) 3] [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
            [word (protect Pe) [* (protect Count) Stride]]
            [do | (datalog.store-values Tuples Values 0)]
            [u64! Meta 0 [+ (protect Count) 1]]
            | (append Added [[exit Loop]])]
          [when [= [shift-right (protect E) 32] (protect Fp)]
            [word (protect Pe) [* [- [bit-and (protect E) (datalog.mask)] 1] Stride]]
            [when [and | (datalog.equal-columns Tuples (protect Pe) Values 1)] | (append Found [[exit Loop]])]]
          [word (protect I) [bit-and [+ (protect I) 1] [u64 Meta 8]]]]]))

(define datalog.store-values
  _ [] _ -> []
  Tuples [V | Vs] Off -> [[u32! Tuples (datalog.offset-form (protect Pe) Off) V] | (datalog.store-values Tuples Vs (+ Off 4))])

(set datalog.*made* [])

\\ Grows each relation a kernel adds to, the head and the tables of records it makes.
(define datalog.grow-forms
  [Slot] -> [datalog.grow [<-address s Slot]]
  [Slot | Slots] -> [do [datalog.grow [<-address s Slot]] (datalog.grow-forms Slots)])

(define datalog.head-slot
  [] _ -> (simple-error "datalog: a plan with no head")
  [[emit Rel | _] | _] Relations -> (datalog.relation-slot Rel Relations)
  [_ | Steps] Relations -> (datalog.head-slot Steps Relations))

\\ The kernel, and the KL that calls it: W starts it where its first loop starts, and W.go grows the
\\ relation it adds to and calls it again for as long as it runs out of room.
(define datalog.native-plan
  Steps [Relations Constants Indexes] Prefix
  -> (let N (length Relations)
          Ctx [Relations Constants Indexes N]
          _ (set datalog.*params* [])
          _ (set datalog.*labels* 0)
          _ (set datalog.*made* [])
          Body (datalog.native-steps Steps Ctx [] 1 none)
          Params (value datalog.*params*)
          Kernel (intern (cn Prefix ".k"))
          Written (append (datalog.hash-setup) Body [[return-word 0]])
          Code (shen-jit.assemble Kernel (map (function hd) Params) Written)
          _ (shen-jit.install-code [defun Kernel Code])
          Name (intern Prefix)
          Go (intern (cn Prefix ".go"))
          Head (datalog.head-slot Steps Relations)
          First (datalog.first-start Steps Relations)
          Call [Kernel | (map (function tl) Params)]
          GoForm [defun Go [s start]
                   [let x Call
                     [cond [[= x 0] true]
                           [[= x (datalog.overflow-code)] [datalog.overflowed]]
                           [true [do (datalog.grow-forms [Head | (value datalog.*made*)]) [Go s [- x 1]]]]]]]
          Entry [defun Name [s] [Go s First]]
          _ (set datalog.*forms* [Entry GoForm [define-native Kernel (map (function hd) Params) | Written]
                                  | (value datalog.*forms*)])
       Name))

\\ Where the first loop starts: the new tuples or all of them; 0 if the plan begins with no loop.
(define datalog.first-start
  [[scan Rel new _] | _] Relations -> [<-address [<-address s (datalog.relation-slot Rel Relations)] 5]
  [[scan _ _ _] | _] _ -> 0
  [[filter | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  [[assign | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  [[fold | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  [[absent | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  _ _ -> 0)

\\ The KL of the plan with no sizes to go by.
(define datalog.code
  Name
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          Steps (datalog.all-steps (datalog.plans Name))
       (datalog.code-h Steps Name Relations Constants)))

(define datalog.all-steps
  [] -> []
  [[_ First Variants] | Cs] -> (append First (append Variants (datalog.all-steps Cs))))

(define datalog.code-h
  [] _ _ _ -> []
  [Steps | More] Name Relations Constants
  -> (let _ (put Name datalog.indexes (datalog.steps-indexes Steps Relations (get Name datalog.indexes)))
          Code (datalog.compiled Name Steps Relations Constants)
       (append (tl Code) (datalog.code-h More Name Relations Constants))))

\\ ---------------------------------------------------------------------------
\\ Running.

\\ Room for Added more tuples of which every key may be new, and their chains.
(define datalog.index-room
  Index Added Count
  -> (let Size (+ 1 (<-address Index 2))
          Wanted (* 2 (+ (<-address Index 4) Added))
          NewSize (datalog.power-at-least Size Wanted)
          _ (if (= NewSize Size)
                skip
                (do (address-> Index 0 (datalog.larger-table (<-address Index 0) Size NewSize))
                    (address-> Index 2 (- NewSize 1))))
          Next (<-address Index 1)
          Bytes (shen-jit.bytes-length Next)
       (if (>= Bytes (* 4 Count))
           true
           (address-> Index 1 (shen-jit.copy-bytes (shen-jit.bytes (* 8 Count)) 0 Next 0 Bytes)))))

(define datalog.power-at-least
  P N -> (if (>= P N) P (datalog.power-at-least (* 2 P) N)))

\\ Tuples From up to To into an index, whose kernel is called through a closure kept in it.
(define datalog.index-range
  Rec Index From To
  -> (let _ (datalog.index-room Index (- To From) To)
          F (<-address Index 3)
          New (F (<-address Index 0) (<-address Index 1) (<-address Rec 2) (<-address Index 2) From To)
       (address-> Index 4 (+ New (<-address Index 4)))))

(define datalog.index-all
  [] _ _ _ -> true
  [Slot | Slots] Rec From To -> (do (datalog.index-range Rec (<-address Rec Slot) From To)
                                    (datalog.index-all Slots Rec From To)))

\\ What was added becomes the new tuples. Gives whether there were any.
(define datalog.merge
  Rec -> (let From (<-address Rec 6)
              To (datalog.count-of Rec)
              _ (datalog.index-all (<-address Rec 1) Rec From To)
              _ (address-> Rec 5 From)
              _ (address-> Rec 6 To)
           (> To From)))

(define datalog.merge-all
  [] Any -> Any
  [Rel | Rels] Any -> (let Some (datalog.merge Rel) (datalog.merge-all Rels (or Some Any))))

(define datalog.call-all
  [] _ -> true
  [F | Fs] S -> (do (F S) (datalog.call-all Fs S)))

\\ Everything so far counts as new, for the first round of a component.
(define datalog.start-round
  [] -> true
  [Rel | Rels] -> (do (address-> Rel 5 0) (datalog.start-round Rels)))

\\ What a run needs: [Name Relations Constants S].
(define datalog.run-relation
  Rel [_ Relations _ S] -> (<-address S (datalog.relation-slot Rel Relations)))

(define datalog.log2
  X N -> (if (<= X 1) N (datalog.log2 (shen-jit.shift-right X 1) (+ N 1))))

(define datalog.quotient
  A B Q -> (if (< A B) Q (datalog.quotient (- A B) B (+ Q 1))))

\\ How many tuples an atom is expected to give for one set of known columns: the average per key if
\\ there is an index to say, and otherwise as if the columns were alike and independent.
(define datalog.estimate
  [Rel | Terms] Bound Run
  -> (let Rec (datalog.run-relation Rel Run)
          Size (datalog.count-of Rec)
          Keys (datalog.key-columns Terms 1 Bound)
          Known (length Keys)
          Arity (length Terms)
       (cases (= Known 0) Size
              (= Size 0) 0
              (= Known Arity) 1
              true (datalog.per-key Rec Size Rel Keys Known Arity Run))))

(define datalog.per-key
  Rec Size Rel Keys Known Arity [Name | Run]
  -> (let Table (assoc Rel (get Name datalog.indexes))
          Slot (if (and (cons? Table) (element? Keys (tl Table)))
                   (datalog.index-slot Rel Keys (get Name datalog.indexes))
                   none)
       (if (and (not (= Slot none)) (element? Slot (<-address Rec 1)) (> (<-address (<-address Rec Slot) 4) 0))
           (/ Size (<-address (<-address Rec Slot) 4))
           (shen-jit.shift-left 1 (datalog.quotient (* (datalog.log2 Size 0) (- Arity Known)) Arity 0)))))

(define datalog.estimator
  Run -> (if (value datalog.*adaptive*)
             (/. Atom Bound (datalog.estimate Atom Bound Run))
             []))

\\ Each index these steps look up, started if this run has not used it.
(define datalog.prepare
  [] _ -> true
  [Step | Steps] [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          Index (datalog.step-index Step Relations)
       (do (if (= Index none) skip (datalog.use-index (hd Index) (hd (tl Index)) Run))
           (datalog.prepare Steps Run))))

\\ A closure of an index's kernel, for calling it from here.
(define datalog.index-function
  N Keys -> (let K (datalog.index-kernel N Keys)
              (eval-kl [lambda a [lambda b [lambda c [lambda d [lambda e [lambda f [K a b c d e f]]]]]]])))

(define datalog.new-index
  N Keys Count
  -> (let I (absvector 5)
          _ (address-> I 0 (shen-jit.bytes (* 16 8)))
          _ (address-> I 1 (shen-jit.bytes (* 4 (if (> Count 8) Count 8))))
          _ (address-> I 2 15)
          _ (address-> I 3 (datalog.index-function N Keys))
          _ (address-> I 4 0)
       I))

(define datalog.use-index
  Rel Keys [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (put Name datalog.indexes (datalog.add-index Rel Keys (get Name datalog.indexes)))
          Slot (datalog.index-slot Rel Keys (get Name datalog.indexes))
          Rec (datalog.run-relation Rel Run)
       (cases (element? Slot (<-address Rec 1)) true
              (>= Slot (<-address Rec 0)) (error "datalog: too many indexes on ~A" Rel)
              true (let I (datalog.new-index (datalog.arity-in Rel Relations) Keys (<-address Rec 6))
                        _ (address-> Rec Slot I)
                        _ (address-> Rec 1 [Slot | (<-address Rec 1)])
                     (datalog.index-range Rec I 0 (<-address Rec 6))))))

(define datalog.steps-function
  Steps [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (datalog.prepare Steps Run)
          _ (set datalog.*plans* (+ 1 (value datalog.*plans*)))
       (hd (datalog.compiled Name Steps Relations Constants))))

(define datalog.first-functions
  [] _ _ -> []
  [R | Rs] Est Run -> (let F (datalog.steps-function (datalog.plan-rule R Est) Run)
                        [F | (datalog.first-functions Rs Est Run)]))

(define datalog.variant-functions
  [] _ _ -> []
  [[R P Old] | Vs] Est Run -> (let F (datalog.steps-function (datalog.plan-variant R P Old Est) Run)
                            [F | (datalog.variant-functions Vs Est Run)]))

\\ Sizes to within a power of two: a new plan when one has moved that far.
(define datalog.signature
  [] _ -> []
  [[Rel | _] | Rs] Run
  -> [(datalog.log2 (datalog.count-of (datalog.run-relation Rel Run)) 0) | (datalog.signature Rs Run)])

(define datalog.fixpoint
  Variants Rels Run Functions Signature Rounds
  -> (let Now (datalog.signature (hd (tl Run)) Run)
          Replan (and (value datalog.*adaptive*) (not (= Now Signature)))
          Fs (if Replan (datalog.variant-functions Variants (datalog.estimator Run) Run) Functions)
          _ (datalog.call-all Fs (datalog.nth 4 Run))
          Any (datalog.merge-all Rels false)
       (if Any
           (datalog.fixpoint Variants Rels Run Fs Now (+ Rounds 1))
           (+ Rounds 1))))

(define datalog.run-component
  [C First Variants] Run Rounds
  -> (let Rels (map (/. R (datalog.run-relation R Run)) C)
          Est (datalog.estimator Run)
          _ (datalog.call-all (datalog.first-functions First Est Run) (datalog.nth 4 Run))
          _ (datalog.merge-all Rels false)
          More (if (empty? Variants)
                   0
                   (do (datalog.start-round Rels)
                       (datalog.fixpoint Variants Rels Run
                         (datalog.variant-functions Variants (datalog.estimator Run) Run)
                         (datalog.signature (hd (tl Run)) Run)
                         0)))
       (+ Rounds More)))

(define datalog.run-components
  [] _ Rounds -> Rounds
  [C | Cs] Run Rounds -> (datalog.run-components Cs Run (datalog.run-component C Run Rounds)))

\\ Values to integers: the program's constants first, in order, which generated code holds as
\\ numbers, then the facts'.
(define datalog.intern
  Value Interned -> (let Entry (datalog.dict-find Interned Value)
                      (if (cons? Entry)
                          (tl Entry)
                          (let Id (shen.dict-count Interned)
                               _ (shen.dict-> Interned Value Id)
                               _ (set datalog.*fresh* [[Id | Value] | (value datalog.*fresh*)])
                            Id))))

\\ The values interned since this was last emptied, for datalog.add to give their numbers.
(set datalog.*fresh* [])

(define datalog.intern-all
  [] _ -> []
  [V | Vs] Interned -> (let Id (datalog.intern V Interned)
                         [Id | (datalog.intern-all Vs Interned)]))

(define datalog.list-forms
  0 _ -> []
  N L -> [[hd L] | (datalog.list-forms (- N 1) [tl L])])

\\ Closures for adding and finding a tuple given as a list, one for each arity.
(define datalog.adder
  N -> (let Name (intern (cn "datalog.adder." (str N)))
            Known (datalog.dict-find (value datalog.*kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let F (eval-kl [lambda r [lambda l (datalog.insert-form N (datalog.list-forms N l))]])
                  _ (shen.dict-> (value datalog.*kernels*) Name F)
               F))))

(define datalog.finder
  N -> (let Name (intern (cn "datalog.finder." (str N)))
            Known (datalog.dict-find (value datalog.*kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let Find (datalog.find-kernel N (datalog.upto 1 N))
                  F (eval-kl [lambda r [lambda l
                               [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | (datalog.list-forms N l)]]])
                  _ (shen.dict-> (value datalog.*kernels*) Name F)
               F))))

\\ Facts into their relations. Each relation's record, column types and adder are found once, in a
\\ dictionary, and values are checked as they are encoded; datalog.check-fact says what is wrong.
(define datalog.load-facts
  Facts Relations S Interned Constructors
  -> (datalog.load-each Facts (datalog.fact-table Relations S 1 (shen.dict 8)) Relations Interned [S | Constructors]))

(define datalog.fact-table
  [] _ _ Table -> Table
  [[Rel | Types] | Rs] S I Table
  -> (do (shen.dict-> Table Rel [(<-address S I) Types (datalog.adder (length Types))])
         (datalog.fact-table Rs S (+ I 1) Table)))

(define datalog.load-each
  [] _ _ _ _ -> true
  [[Rel | Values] | Facts] Table Relations Interned Records
  -> (let Entry (datalog.dict-find Table Rel)
          _ (if (cons? Entry) skip (datalog.check-fact Relations (tl Records) [Rel | Values]))
          Known (tl Entry)
          Ids (datalog.encode-checked Values (hd (tl Known)) Interned [Rel | Values] [Relations | Records])
          Add (hd (tl (tl Known)))
          _ (Add (hd Known) Ids)
       (datalog.load-each Facts Table Relations Interned Records))
  [Fact | _] _ Relations _ Records -> (datalog.check-fact Relations (tl Records) Fact))

(define datalog.fill-state
  [] S _ -> S
  [[_ | Types] | Rs] S I
  -> (do (address-> S I (datalog.new-relation (length Types)))
         (datalog.fill-state Rs S (+ I 1))))

\\ A table for each type's records, after the relations.
(define datalog.fill-records
  [] S -> S
  [[_ _ _ _ Slot Width] | Cs] S
  -> (do (if (= (<-address S Slot) 0) (address-> S Slot (datalog.new-relation Width)) skip)
         (datalog.fill-records Cs S)))

(define datalog.record-slots
  [] -> 0
  [[_ _ _ _ Slot _] | Cs] -> (datalog.max Slot (datalog.record-slots Cs)))

(define datalog.new-state
  Relations Constructors
  -> (let N (datalog.max (length Relations) (datalog.record-slots Constructors))
          S (absvector (+ 1 N))
          _ (datalog.zero-state S 1 N)
          _ (datalog.fill-state Relations S 1)
       (datalog.fill-records Constructors S)))

(define datalog.zero-state
  S I N -> (if (> I N) S (do (address-> S I 0) (datalog.zero-state S (+ I 1) N))))

\\ A record's position in the table at Slot, made if it is not there: Words are its constructor's
\\ number and its fields, as wide as the table.
(define datalog.record-id
  S Slot Words -> (let Rec (<-address S Slot)
                       P ((datalog.interner (length Words)) Rec Words)
                    (if (= P 0)
                        (do (datalog.grow Rec) (datalog.record-id S Slot Words))
                        (- P 1))))

(define datalog.interner
  N -> (let Name (intern (cn "datalog.interner." (str N)))
            Known (datalog.dict-find (value datalog.*kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let K (datalog.intern-kernel N)
                  F (eval-kl [lambda r [lambda l [K [<-address r 3] [<-address r 2] [<-address r 4] | (datalog.list-forms N l)]]])
                  _ (shen.dict-> (value datalog.*kernels*) Name F)
               F))))

(define datalog.pad
  Words Width -> (if (>= (length Words) Width) Words (datalog.pad (append Words [0]) Width)))

\\ A fact's values as the words its columns hold, interning symbols, strings and records, checked
\\ as they go; datalog.check-fact says what is wrong. Ctx is [Relations S | Constructors].
(define datalog.encode-checked
  [] [] _ _ _ -> []
  [V | Vs] [integer | Ts] Interned Fact Ctx
  -> (if (datalog.int32? V)
         [(datalog.int-word V) | (datalog.encode-checked Vs Ts Interned Fact Ctx)]
         (datalog.fact-error Ctx Fact))
  [V | Vs] [T | Ts] Interned Fact [Relations S | Cs]
  -> (if (datalog.value-of? V T Cs)
         (let Id (datalog.encode-record V T Interned [S | Cs])
           [Id | (datalog.encode-checked Vs Ts Interned Fact [Relations S | Cs])])
         (datalog.fact-error [Relations S | Cs] Fact))
     where (cons? V)
  [V | Vs] [T | Ts] Interned Fact Ctx
  -> (if (= (datalog.value-type V) T)
         (let Id (datalog.intern V Interned)
           [Id | (datalog.encode-checked Vs Ts Interned Fact Ctx)])
         (datalog.fact-error Ctx Fact))
  _ _ _ Fact Ctx -> (datalog.fact-error Ctx Fact))

(define datalog.fact-error
  [Relations _ | Cs] Fact -> (datalog.check-fact Relations Cs Fact))

\\ The position of a record, checked already, in its type's table.
(define datalog.encode-record
  [C | Vs] _ Interned [S | Cs]
  -> (let Con (assoc C Cs)
       (datalog.record-id S (datalog.nth 5 Con)
         (datalog.pad [(datalog.nth 3 Con) | (datalog.encode-fields Vs (datalog.nth 4 Con) Interned [S | Cs])] (datalog.nth 6 Con)))))

(define datalog.encode-fields
  [] [] _ _ -> []
  [V | Vs] [integer | Ts] Interned Records -> [(datalog.int-word V) | (datalog.encode-fields Vs Ts Interned Records)]
  [V | Vs] [T | Ts] Interned Records
  -> (let Id (if (element? T [symbol string]) (datalog.intern V Interned) (datalog.encode-record V T Interned Records))
       [Id | (datalog.encode-fields Vs Ts Interned Records)]))

\\ The value of a word of type T: what a column holds, read back.
(define datalog.word-value
  W integer _ -> (datalog.word-int W)
  W symbol [S | _] -> (<-vector (<-address S 0) (+ W 1))
  W string [S | _] -> (<-vector (<-address S 0) (+ W 1))
  Id T [S | Cs]
  -> (let Some (datalog.type-constructor T Cs)
          Rec (<-address S (datalog.nth 5 Some))
          Tuples (<-address Rec 2)
          Base (* Id (<-address Rec 7))
          Con (datalog.tagged T (shen-jit.u32 Tuples Base) Cs)
       [(hd Con) | (datalog.field-values Tuples (+ Base 4) (datalog.nth 4 Con) [S | Cs])]))

(define datalog.field-values
  _ _ [] _ -> []
  Tuples Off [T | Ts] Records
  -> (let V (datalog.word-value (shen-jit.u32 Tuples Off) T Records)
       [V | (datalog.field-values Tuples (+ Off 4) Ts Records)]))

(define datalog.type-constructor
  T [[C T | More] | _] -> [C T | More]
  T [_ | Cs] -> (datalog.type-constructor T Cs))

(define datalog.tagged
  T Tag [[C T Tag | More] | _] -> [C T Tag | More]
  T Tag [_ | Cs] -> (datalog.tagged T Tag Cs))

\\ The word of a value already in the database, or no: a lookup that adds nothing.
(define datalog.find-value
  V integer _ _ -> (if (datalog.int32? V) (datalog.int-word V) no)
  V T Interned [S | Cs]
  -> (let Entry (datalog.dict-find Interned V)
       (if (and (cons? Entry) (datalog.value-of? V T Cs)) (tl Entry) no))
     where (element? T [symbol string])
  [C | Vs] T Interned [S | Cs]
  -> (let Con (assoc C Cs)
          Words (if (and (cons? Con) (= (datalog.nth 2 Con) T) (= (length Vs) (length (datalog.nth 4 Con))))
                    (datalog.find-values Vs (datalog.nth 4 Con) Interned [S | Cs])
                    no)
          Width (if (= Words no) 0 (datalog.nth 6 Con))
          P (if (= Words no) 0 ((datalog.finder Width) (<-address S (datalog.nth 5 Con)) (datalog.pad [(datalog.nth 3 Con) | Words] Width)))
       (if (= P 0) no (- P 1)))
  _ _ _ _ -> no)

(define datalog.find-values
  [] [] _ _ -> []
  [V | Vs] [T | Ts] Interned Records
  -> (let W (datalog.find-value V T Interned Records)
          More (if (= W no) no (datalog.find-values Vs Ts Interned Records))
       (if (= More no) no [W | More]))
  _ _ _ _ -> no)

\\ The interned values by number, in a vector, so that number N is at N + 1.
(define datalog.values-vector
  Interned -> (let V (vector (datalog.max 1 (shen.dict-count Interned)))
                (do (shen.dict-fold (/. K Id Acc (vector-> V (+ Id 1) K)) Interned V) V)))

(define datalog.merge-state
  S I End -> (if (> I End)
                 true
                 (do (datalog.merge (<-address S I))
                     (datalog.zero-derivations (<-address S I))
                     (datalog.merge-state S (+ I 1) End))))

(define datalog.zero-derivations
  Rec -> (shen-jit.s64! (<-address Rec 4) 24 0))

(define datalog.run
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          Interned (shen.dict 8)
          _ (datalog.intern-all Constants Interned)
          N (length Relations)
          S (datalog.new-state Relations (datalog.nth 7 Program))
          _ (datalog.load-facts Facts Relations S Interned (datalog.nth 7 Program))
          _ (set datalog.*fresh* [])
          _ (address-> S 0 (datalog.values-vector Interned))
          _ (datalog.merge-state S 1 N)
          Run [Name Relations Constants S]
          _ (set datalog.*plans* 0)
          Rounds (datalog.run-components (get Name datalog.schedule) Run 0)
       [db Name S Interned Rounds (value datalog.*plans*) Facts]))

\\ ---------------------------------------------------------------------------
\\ Adding facts to a database. The facts go in, and each relation remembers its size before them,
\\ its mark. Then each component, in order: one that reads only relations that grew goes on from
\\ them, semi-naively, with a variant of each rule for each atom of a relation that grew, reading
\\ what is past its mark; one that negates or aggregates a relation that changed, or reads one
\\ that was evaluated again, could lose tuples, so it is emptied to its facts and evaluated again;
\\ one that reads nothing that changed stays as it is. The database changes in place.

(define datalog.add
  [db Name S Interned Rounds Plans Facts] New
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          N (length Relations)
          Marks (datalog.marks S 1 N)
          _ (set datalog.*fresh* [])
          _ (datalog.load-facts New Relations S Interned (datalog.nth 7 Program))
          _ (address-> S 0 (datalog.more-values (<-address S 0) (value datalog.*fresh*) (shen.dict-count Interned)))
          _ (datalog.merge-each S 1 N)
          All (append Facts New)
          Run [Name Relations Constants S]
          _ (set datalog.*plans* 0)
          Grown (datalog.grown Relations S Marks 1)
          More (datalog.add-components (get Name datalog.schedule) (datalog.nth 4 Program) Run Marks [All Interned (datalog.nth 7 Program)] Grown [] 0)
       [db Name S Interned (+ Rounds More) (+ Plans (value datalog.*plans*)) All])
  Db _ -> (error "datalog: datalog.add takes a database that datalog.run made, not ~S" Db))

(define datalog.marks
  S I N -> (if (> I N) [] [(<-address (<-address S I) 6) | (datalog.marks S (+ I 1) N)]))

(define datalog.merge-each
  S I N -> (if (> I N) true (do (datalog.merge (<-address S I)) (datalog.merge-each S (+ I 1) N))))

\\ The relations that have more tuples than their marks.
(define datalog.grown
  [] _ _ _ -> []
  [[Rel | _] | Rs] S [Mark | Marks] I
  -> (if (> (<-address (<-address S I) 6) Mark)
         [Rel | (datalog.grown Rs S Marks (+ I 1))]
         (datalog.grown Rs S Marks (+ I 1))))

\\ A values vector with room for the new ones: doubled when it is full.
(define datalog.more-values
  Values [] _ -> Values
  Values Fresh Count
  -> (let Size (limit Values)
          Bigger (if (>= Size Count)
                     Values
                     (datalog.copy-values Values (vector (datalog.max Count (* 2 Size))) 1 Size))
       (do (map (/. F (vector-> Bigger (+ 1 (hd F)) (tl F))) Fresh) Bigger)))

(define datalog.copy-values
  From To I N -> (if (> I N) To (do (address-> To I (<-address From I)) (datalog.copy-values From To (+ I 1) N))))

\\ Facts is [every fact so far, Interned].
(define datalog.add-components
  [] _ _ _ _ _ _ Rounds -> Rounds
  [[C First Variants] | Cs] Rules Run Marks Facts Grown Again Rounds
  -> (let In (datalog.rules-in Rules C)
          Changed (union Grown Again)
          Complete (datalog.all-complete In)
          Positive (difference (datalog.all-positive In) C)
          Kind (cases (or (cons? (datalog.keep-in Complete Changed)) (cons? (datalog.keep-in Positive Again))) again
                      (cons? (datalog.keep-in (union Positive C) Grown)) grow
                      true same)
          More (cases (= Kind again) (datalog.again [C First Variants] Run Facts Rounds)
                      (= Kind grow) (datalog.grow-component [C First Variants] In Run Marks Grown Rounds)
                      true Rounds)
          S (datalog.nth 4 Run)
          Relations (hd (tl Run))
          Grew (datalog.keep-in C (datalog.grown Relations S Marks 1))
       (datalog.add-components Cs Rules Run Marks Facts
         (if (= Kind grow) (union Grew Grown) Grown)
         (if (= Kind again) (union C Again) Again)
         More)))

(define datalog.all-complete
  [] -> []
  [[_ Body] | Rules] -> (union (datalog.complete-relations Body) (datalog.all-complete Rules)))

(define datalog.all-positive
  [] -> []
  [[_ Body] | Rules] -> (union (map (function hd) (datalog.atoms Body)) (datalog.all-positive Rules)))

\\ A component emptied to its facts and evaluated as datalog.run would.
(define datalog.again
  [C First Variants] [Name Relations Constants S] [Facts Interned Constructors] Rounds
  -> (let Run [Name Relations Constants S]
          _ (map (/. Rel (address-> S (datalog.relation-slot Rel Relations)
                           (datalog.new-relation (datalog.arity-in Rel Relations))))
                 C)
          _ (datalog.load-facts (datalog.facts-of C Facts) Relations S Interned Constructors)
          _ (map (/. Rel (datalog.merge (datalog.run-relation Rel Run))) C)
       (datalog.run-component [C First Variants] Run Rounds)))

(define datalog.facts-of
  _ [] -> []
  C [[Rel | Values] | Facts] -> (if (element? Rel C)
                                    [[Rel | Values] | (datalog.facts-of C Facts)]
                                    (datalog.facts-of C Facts)))

\\ A component that goes on from what grew: each relation that grew reads as new what is past its
\\ mark, a round of every rule with one variant for each atom of such a relation, and then the
\\ component's own rounds until nothing is new.
(define datalog.grow-component
  [C First Variants] In Run Marks Grown Rounds
  -> (let S (datalog.nth 4 Run)
          Relations (hd (tl Run))
          _ (datalog.since-marks Relations S Marks Grown 1)
          Rels (map (/. R (datalog.run-relation R Run)) C)
          Est (datalog.estimator Run)
          Fs (datalog.variant-functions (datalog.grown-variants In Grown) Est Run)
          _ (datalog.call-all Fs S)
          Any (datalog.merge-all Rels false)
       (if (and Any (cons? Variants))
           (+ Rounds 1 (datalog.fixpoint Variants Rels Run
                         (datalog.variant-functions Variants (datalog.estimator Run) Run)
                         (datalog.signature Relations Run) 0))
           (+ Rounds 1))))

(define datalog.since-marks
  [] _ _ _ _ -> true
  [[Rel | _] | Rs] S [Mark | Marks] Grown I
  -> (do (if (element? Rel Grown) (address-> (<-address S I) 5 Mark) skip)
         (datalog.since-marks Rs S Marks Grown (+ I 1))))

\\ [Rule Position Old] for each atom whose relation grew, Old those before it.
(define datalog.grown-variants
  [] _ -> []
  [R | Rs] Grown -> (append (datalog.rule-variants R (datalog.positions-in (datalog.atoms (hd (tl R))) 1 Grown) [])
                            (datalog.grown-variants Rs Grown)))

\\ ---------------------------------------------------------------------------
\\ Removing facts. Tuples are never deleted from storage: a component that holds a relation that
\\ lost a fact, or reads one evaluated again, is emptied to the facts left and evaluated again, in
\\ order, and the rest stay. A fact the database does not have is no change.

(define datalog.remove
  [db Name S Interned Rounds Plans Facts] Gone
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Split (datalog.split-facts Facts (datalog.fact-set Gone (shen.dict 8)) [] [])
          Left (hd Split)
          Lost (tl Split)
          Run [Name Relations (datalog.nth 5 Program) S]
          _ (set datalog.*plans* 0)
          More (datalog.remove-components (get Name datalog.schedule) (datalog.nth 4 Program) Run [Left Interned (datalog.nth 7 Program)] Lost [] 0)
       [db Name S Interned (+ Rounds More) (+ Plans (value datalog.*plans*)) Left])
  Db _ -> (error "datalog: datalog.remove takes a database that datalog.run made, not ~S" Db))

(define datalog.fact-set
  [] Table -> Table
  [F | Fs] Table -> (do (shen.dict-> Table F true) (datalog.fact-set Fs Table)))

\\ [the facts left | the relations of those going that the database has].
(define datalog.split-facts
  [] _ Left Lost -> [(reverse Left) | Lost]
  [[Rel | Values] | Fs] Table Left Lost
  -> (if (cons? (datalog.dict-find Table [Rel | Values]))
         (datalog.split-facts Fs Table Left (adjoin Rel Lost))
         (datalog.split-facts Fs Table [[Rel | Values] | Left] Lost)))

\\ Lost are the relations that lost a fact, Again the ones evaluated again so far.
(define datalog.remove-components
  [] _ _ _ _ _ Rounds -> Rounds
  [[C First Variants] | Cs] Rules Run Facts Lost Again Rounds
  -> (let In (datalog.rules-in Rules C)
          Reads (union (datalog.all-complete In) (datalog.all-positive In))
       (if (or (cons? (datalog.keep-in C Lost)) (cons? (datalog.keep-in Reads Again)))
           (datalog.remove-components Cs Rules Run Facts Lost (union C Again)
             (datalog.again [C First Variants] Run Facts Rounds))
           (datalog.remove-components Cs Rules Run Facts Lost Again Rounds))))

(define datalog.relation-of
  [db Name S | _] Rel
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       (if (cons? (assoc Rel Relations))
           (<-address S (datalog.relation-slot Rel Relations))
           (error "datalog: no relation ~A" Rel))))

(define datalog.types-of
  Name Rel -> (tl (assoc Rel (datalog.nth 3 (datalog.program Name)))))

(define datalog.tuple-at
  _ _ [] _ -> []
  Tuples Base [Type | Types] Records
  -> (let Word (shen-jit.u32 Tuples Base)
          More (datalog.tuple-at Tuples (+ Base 4) Types Records)
       [(datalog.word-value Word Type Records) | More]))

(define datalog.read-tuples
  P To _ _ _ _ Acc -> Acc where (= P To)
  P To Tuples Stride Types Values Acc
  -> (datalog.read-tuples (+ P 1) To Tuples Stride Types Values
       [(datalog.tuple-at Tuples (* P Stride) Types Values) | Acc]))

(define datalog.tuples
  [naive _ Tables] Rel
  -> (let Table (assoc Rel Tables)
       (if (empty? Table) (error "datalog: no relation ~A" Rel) (tl Table)))
  [db Name S | Rest] Rel
  -> (let Rec (datalog.relation-of [db Name S | Rest] Rel)
       (datalog.read-tuples 0 (<-address Rec 6) (<-address Rec 2) (<-address Rec 7)
                            (datalog.types-of Name Rel) [S | (datalog.nth 7 (datalog.program Name))] [])))

(define datalog.count
  [naive | Rest] Rel -> (length (datalog.tuples [naive | Rest] Rel))
  Db Rel -> (datalog.count-of (datalog.relation-of Db Rel)))

(define datalog.holds?
  [naive | Rest] [Rel | Values] -> (element? Values (datalog.tuples [naive | Rest] Rel))
  [db Name S Interned | Rest] [Rel | Values]
  -> (let Rec (datalog.relation-of [db Name S Interned | Rest] Rel)
          Ids (datalog.find-values Values (datalog.types-of Name Rel) Interned [S | (datalog.nth 7 (datalog.program Name))])
          Find (datalog.finder (length Values))
       (and (not (= Ids no)) (> (Find Rec Ids) 0))))

(define datalog.match
  Db [Rel | Terms] -> (datalog.match-tuples (datalog.tuples Db Rel) Terms []))

(define datalog.match-tuples
  [] _ Acc -> Acc
  [T | Ts] Terms Acc -> (datalog.match-tuples Ts Terms
                          (if (= (datalog.naive-match Terms T []) no) Acc [T | Acc])))

\\ Rounds, plans made, and for each relation its tuples, its derivations and its indexes.
(define datalog.stats
  [db Name S _ Rounds Plans | _]
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       [[rounds Rounds] [plans Plans]
        | (map (/. R (let Rec (<-address S (datalog.relation-slot (hd R) Relations))
                       [(hd R) (datalog.count-of Rec) (shen-jit.s64 (<-address Rec 4) 24) (length (<-address Rec 1))]))
               Relations)]))

\\ ---------------------------------------------------------------------------
\\ Demand, by magic sets. (datalog.query Name Facts (Rel Term ...)) gives what datalog.ask would of
\\ a run of these facts, computing only what the query needs. Its constants make an adornment, b
\\ for a bound column and f for a free one, and the program is rewritten for it once and kept:
\\ each relation the query reaches through positive atoms has a copy for each adornment it is
\\ reached with, Rel@bf, whose rules begin with a magic relation, magic@Rel@bf, of the values asked
\\ for in its bound columns. A magic relation's rules pass those on, from a head, through the
\\ atoms that bind more, as the planner would order them with no sizes, to the next atom of a
\\ copy. A copy also takes the facts of its relation. What is negated or aggregated must be
\\ complete, so it is computed in full, by its own rules, with all it depends on. The query's
\\ constants are the one fact of its magic relation.

(define datalog.solve
  Name Facts [Rel | Terms]
  -> (let Program (datalog.program Name)
          Types (assoc Rel (datalog.nth 3 Program))
          _ (cases (empty? Types) (error "datalog: no relation ~A" Rel)
                   (not (= (length Terms) (length (tl Types))))
                   (error "datalog: ~A takes ~A values, not ~A" Rel (length (tl Types)) (length Terms))
                   true skip)
          Adorn (map (/. T (if (datalog.known? T []) b f)) Terms)
          Demand (datalog.demand Name Rel Adorn)
          Seed [(datalog.magic-name Rel Adorn) | (datalog.at-bound Terms Adorn)]
          Db (datalog.run Demand [Seed | Facts])
       (datalog.match-tuples (datalog.tuples Db (datalog.adorned-name Rel Adorn)) Terms [])))

(define datalog.demand
  Name Rel Adorn
  -> (let D (intern (cn (str Name) (cn "@" (str (datalog.adorned-name Rel Adorn)))))
          Known (get Name datalog.demands)
       (if (element? D Known)
           D
           (do (datalog.define D (datalog.demand-items (datalog.program Name) Rel Adorn))
               (put Name datalog.demands [D | Known])
               D))))

(define datalog.adorned-name
  Rel Adorn -> (intern (cn (str Rel) (cn "@" (datalog.adorn-string Adorn)))))

(define datalog.magic-name
  Rel Adorn -> (intern (cn "magic@" (str (datalog.adorned-name Rel Adorn)))))

(define datalog.adorn-string
  [] -> ""
  [A | As] -> (cn (str A) (datalog.adorn-string As)))

(define datalog.at-bound
  [] [] -> []
  [X | Xs] [b | As] -> [X | (datalog.at-bound Xs As)]
  [_ | Xs] [_ | As] -> (datalog.at-bound Xs As))

(define datalog.demand-items
  [program _ Relations Rules _ _ Constructors] Rel Adorn
  -> (let Derived (datalog.unique (map (/. R (hd (hd R))) Rules) [])
          Done (datalog.adorn [[Rel Adorn]] [] [] Rules Derived [])
          Full (datalog.full-closure (hd (tl (tl Done))) Rules)
          Copies (hd (tl Done))
       (append (datalog.type-items Constructors [])
       (append (map (/. R [relation (hd R) (tl R)]) Relations)
       (append (mapcan (/. C (datalog.copy-items C Relations)) Copies)
       (append (map (/. R [rule (hd R) (map (function datalog.literal->data) (hd (tl R)))])
                    (datalog.rules-in Rules Full))
               (map (/. R [rule (hd R) (hd (tl R))]) (hd Done))))))))

\\ Each copy and its magic relation, and the rule that gives the copy its relation's facts.
(define datalog.copy-items
  [Rel Adorn] Relations
  -> (let Types (tl (assoc Rel Relations))
          Vars (map (/. I [var (cn "D" (str I))]) (datalog.upto 1 (length Types)))
       [[relation (datalog.adorned-name Rel Adorn) Types]
        [relation (datalog.magic-name Rel Adorn) (datalog.at-bound Types Adorn)]
        [rule [(datalog.adorned-name Rel Adorn) | Vars]
              [[(datalog.magic-name Rel Adorn) | (datalog.at-bound Vars Adorn)] [Rel | Vars]]]]))

(define datalog.type-items
  [] Acc -> (reverse Acc)
  [[C T _ Fields | _] | Cs] Acc
  -> (datalog.type-items Cs (if (element? T (map (/. I (hd (tl I))) Acc))
                                (map (/. I (if (= (hd (tl I)) T) (append I [[C | Fields]]) I)) Acc)
                                [[type T [C | Fields]] | Acc])))

(define datalog.literal->data
  [aggregate V count _ Atom _] -> [= [var V] [count Atom]]
  [aggregate V Op T Atom _] -> [= [var V] [Op [var T] Atom]]
  L -> L)

\\ Copies to make, as [[Rel Adorn] ...]: gives [Rules Copies Full], Full what must be complete.
(define datalog.adorn
  [] Done Full _ _ Acc -> [Acc (reverse Done) Full]
  [Copy | Queue] Done Full Rules Derived Acc
  -> (if (element? Copy Done)
         (datalog.adorn Queue Done Full Rules Derived Acc)
         (datalog.adorn-each (datalog.rules-of (hd Copy) Rules) Copy Queue [Copy | Done] Full Rules Derived Acc)))

(define datalog.rules-of
  _ [] -> []
  Rel [[[Rel | Terms] Body] | Rules] -> [[[Rel | Terms] Body] | (datalog.rules-of Rel Rules)]
  Rel [_ | Rules] -> (datalog.rules-of Rel Rules))

(define datalog.adorn-each
  [] _ Queue Done Full Rules Derived Acc -> (datalog.adorn Queue Done Full Rules Derived Acc)
  [Rule | More] [Rel Adorn] Queue Done Full Rules Derived Acc
  -> (let R (datalog.adorn-rule Rule Adorn Derived Full)
       (datalog.adorn-each More [Rel Adorn] (append Queue (hd (tl R))) Done
         (union (hd (tl (tl R))) Full) Rules Derived (append Acc (hd R)))))

\\ A rule's copy for Adorn, and a magic rule for each copy it reads: [Rules Copies Complete].
(define datalog.adorn-rule
  [[Rel | Terms] Body] Adorn Derived Full
  -> (let Magic [(datalog.magic-name Rel Adorn) | (datalog.at-bound Terms Adorn)]
          Conditions (datalog.conditions Body)
          Order (datalog.sips (datalog.atoms Body) Conditions (datalog.term-vars (datalog.at-bound Terms Adorn) []))
          Atoms (map (/. A (datalog.adorn-atom A Derived Full)) Order)
          Data (map (function datalog.literal->data) Conditions)
       [[[[(datalog.adorned-name Rel Adorn) | Terms] [Magic | (append (map (function hd) Atoms) Data)]]
         | (datalog.magic-rules Atoms Magic Conditions [])]
        (mapcan (/. A (tl (tl A))) Atoms)
        (datalog.complete-relations Body)]))

\\ [Atom' Bound | Copy]: the atom, a copy's if its relation is derived and not complete, with
\\ what is bound before it.
(define datalog.adorn-atom
  [[Rel | Terms] Bound] Derived Full
  -> (if (and (element? Rel Derived) (not (element? Rel Full)))
         (let Adorn (map (/. T (if (datalog.known? T Bound) b f)) Terms)
           [[(datalog.adorned-name Rel Adorn) | Terms] Bound [Rel Adorn]])
         [[Rel | Terms] Bound]))

(define datalog.magic-rules
  [] _ _ _ -> []
  [[Atom Bound | Copy] | Atoms] Magic Conditions Before
  -> (let More (datalog.magic-rules Atoms Magic Conditions (append Before [Atom]))
       (if (empty? Copy)
           More
           (let Vars (datalog.term-vars (tl Magic) (datalog.term-vars (mapcan (function tl) Before) []))
                Ready (hd (datalog.close-conditions Conditions Vars))
                Head [(datalog.magic-name (hd (hd Copy)) (hd (tl (hd Copy)))) | (datalog.at-bound (tl Atom) (hd (tl (hd Copy))))]
             [[Head [Magic | (append Before (map (function datalog.literal->data) Ready))]] | More]))))

\\ The order in which bindings pass, [[Atom Bound] ...]: the planner's with no sizes, and the
\\ conditions that bind more as soon as they can.
(define datalog.sips
  [] _ _ -> []
  Atoms Conditions Bound
  -> (let B (hd (tl (datalog.close-conditions Conditions Bound)))
          Atom (datalog.best Atoms B [])
       [[Atom B] | (datalog.sips (datalog.remove-one Atom Atoms) Conditions (datalog.term-vars (tl Atom) B))]))

\\ The conditions that can run given what is bound, and what is bound after: [Ready Bound].
(define datalog.close-conditions
  Conditions Bound -> (datalog.close-h Conditions Bound [] [] false))

(define datalog.close-h
  [] Bound Ready _ false -> [(reverse Ready) Bound]
  [] Bound Ready Left true -> (datalog.close-h (reverse Left) Bound Ready [] false)
  [C | Cs] Bound Ready Left Progress
  -> (let B (datalog.binder C Bound)
       (cases (datalog.subset? (datalog.condition-vars C) Bound) (datalog.close-h Cs Bound [C | Ready] Left Progress)
              (= B none) (datalog.close-h Cs Bound Ready [C | Left] Progress)
              true (datalog.close-h Cs [(hd B) | Bound] [C | Ready] Left true))))

\\ These relations and all they depend on.
(define datalog.full-closure
  Full Rules -> (let More (union Full (mapcan (/. R (datalog.depends R Rules)) Full))
                  (if (datalog.same-set? More Full) Full (datalog.full-closure More Rules))))

\\ ---------------------------------------------------------------------------
\\ Sorting, for a result that does not depend on the order of evaluation.

(define datalog.value<
  A B -> (datalog.tuple< A B) where (and (cons? A) (cons? B))
  A _ -> false where (cons? A)
  _ B -> true where (cons? B)
  A B -> (< A B) where (and (number? A) (number? B))
  A _ -> true where (number? A)
  _ B -> false where (number? B)
  A B -> (datalog.text< (str A) (str B)) where (= (string? A) (string? B))
  A _ -> (string? A))

(define datalog.text<
  "" "" -> false
  "" _ -> true
  _ "" -> false
  A B -> (let X (string->n (pos A 0))
              Y (string->n (pos B 0))
           (cases (< X Y) true
                  (> X Y) false
                  true (datalog.text< (tlstr A) (tlstr B)))))

(define datalog.tuple<
  [] [] -> false
  [] _ -> true
  _ [] -> false
  [A | As] [B | Bs] -> (cases (datalog.value< A B) true
                              (datalog.value< B A) false
                              true (datalog.tuple< As Bs)))

(define datalog.split
  [] A B -> (@p A B)
  [X | Xs] A B -> (datalog.split Xs [X | B] A))

(define datalog.merge-sorted
  [] Bs Acc -> (append (reverse Acc) Bs)
  As [] Acc -> (append (reverse Acc) As)
  [A | As] [B | Bs] Acc -> (if (datalog.tuple< B A)
                               (datalog.merge-sorted [A | As] Bs [B | Acc])
                               (datalog.merge-sorted As [B | Bs] [A | Acc])))

(define datalog.sort
  [] -> []
  [X] -> [X]
  Xs -> (let Halves (datalog.split Xs [] [])
          (datalog.merge-sorted (datalog.sort (fst Halves)) (datalog.sort (snd Halves)) [])))

(define datalog.sorted
  Db Rel -> (datalog.sort (datalog.tuples Db Rel)))

\\ ---------------------------------------------------------------------------
\\ The surface: forms to the data above. The reader has turned [a b] into cons forms.

(define datalog.unbracket
  [cons H T] -> [H | (datalog.unbracket T)]
  X -> X)

(define datalog.item
  [relation Name Types] -> [relation Name (datalog.unbracket Types)]
  [type Name | Constructors] -> [type Name | (map (function datalog.unbracket) Constructors)]
  [rule Head <-- | Body] -> [rule (datalog.unbracket-atom Head) (map (function datalog.unbracket-literal) Body)]
  [rule Head] -> [rule (datalog.unbracket-atom Head) []]
  Form -> (error "defdatalog: ~R is neither (relation Name [Types]), (type Name [Constructor Types] ...) nor (rule Head <-- Body)" Form))

\\ In a rule, brackets are records: [cons X P] is the term of constructor cons.
(define datalog.unbracket-literal
  [not Atom] -> [not (datalog.unbracket-atom Atom)]
  [Op A B] -> [Op (datalog.unbracket-side A) (datalog.unbracket-side B)] where (datalog.comparison? Op)
  Atom -> (datalog.unbracket-atom Atom))

(define datalog.unbracket-side
  [count Atom] -> [count (datalog.unbracket-atom Atom)]
  [Op T Atom] -> [Op T (datalog.unbracket-atom Atom)] where (datalog.aggregate? Op)
  T -> (datalog.unbracket-term T))

(define datalog.unbracket-atom
  [Rel | Terms] -> [Rel | (map (function datalog.unbracket-term) Terms)]
  X -> X)

(define datalog.unbracket-term
  [cons H T] -> [(datalog.unbracket-term H) | (datalog.unbracket-term T)]
  [X | Xs] -> (map (function datalog.unbracket-term) [X | Xs])
  X -> X)

\\ A form building the data, with variables as [var "X"] and _ as [any]: left as they are they
\\ would be read as Shen's own variables.
(define datalog.quote
  [] -> []
  [H | T] -> [cons (datalog.quote H) (datalog.quote T)]
  X -> [cons any []] where (and (symbol? X) (= (str X) "_"))
  X -> [cons var [cons (str X) []]] where (variable? X)
  X -> X)

(defmacro datalog.macro
  [defdatalog Name | Items] -> [datalog.define Name (datalog.quote (map (function datalog.item) Items))]
  [datalog.ask Db Atom] -> [datalog.match Db (datalog.quote (datalog.unbracket-atom Atom))]
  [datalog.query Name Facts Atom] -> [datalog.solve Name Facts (datalog.quote (datalog.unbracket-atom Atom))])

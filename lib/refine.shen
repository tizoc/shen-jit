\\ Conditions on what functions are given and give, proved by smt of the code that the kernel has typechecked:
\\
\\   (refine.type natural N where (fx<= 0 N))
\\
\\   (define-checked at
\\     {B : buffer.storage --> I : fixnum --> R : fixnum}
\\     {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
\\     {ensures (fx<= 0 R)}
\\     B I -> (shen-jit.u8 B I))
\\
\\ A call of at in typed code must prove its condition from what is known there: patterns, guards, the branch of an if,
\\ and, or or, lets, clauses that did not match, and contracts. Anywhere else, as from untyped code or (fn at), it is tested
\\ as at is called, and so it is where it was proved, until (refine.test -). docs/refine.md has the rules.
\\
\\ The port gives refine each form that the type checker is given under (tc +). It is checked as it was written, and then
\\ walked as it would run (refine-walk.shen), with what is known as formulas for smt (refine-prove.shen). This file has
\\ what is declared.

(shen.x.namespace refine
  (use smt)
  (use shen-jit)
  (use shen)
  (externals [verified fixnum unit define-checked requires ensures trusts layout.made])
  (export define-checked refine.contract => contract refine.type => type refine.trust => trust refine.pure => pure refine.test => test)

\\ ---------------------------------------------------------------------------
\\ What is declared. A contract is [Formals Pre Result Post], what is trusted of a function [Formals Result Post], and a
\\ refined type's condition [Variable P Base Type]. A pure function gives the same for the same arguments, whenever it is
\\ called.

(define declared
  F Key Default -> (shen-jit.property F Key Default))

\\ The contract in force: that of define-checked or of a signature, or those of refine.contract.
(define contract
  F -> (let C (own-contract F) (if (empty? C) (outside-contract F) C)) where (symbol? F)
  _ -> [])

\\ What a define that is being checked defines, and its contract, or [] for an expression, and [F N | Contract] for what is
\\ read together with it, N the place of F's definition there. A contract is its function's once the definition was
\\ evaluated, and is what an expression is checked by, as it is evaluated at once. So is a definition, but by the
\\ contracts of what is defined after it there, as by the types of those.
(set *checking* [])
(set *together* [])
(set *place* 0)

(define own-contract
  F -> (contract-by F (value *checking*)))

(define contract-by
  F [] -> (established F)
  F [F | C] -> C
  F _ -> (contract-together F (assoc F (value *together*))))

(define contract-together
  _ [_ N | C] -> C where (> N (value *place*))
  F _ -> (established F))

\\ It is so of what was defined with it, also while that is tracked, and of nothing that F is defined as after that.
(define established
  F -> (contract-of-definition F (declared F contract [])))

(define contract-of-definition
  F [D | C] -> C where (trap-error (shen-jit.same? D (definition-of F)) (/. E false))
  _ _ -> [])

(define establish
  F C -> (put F contract (if (says-nothing? C) [] [(definition-of F) | C])))

\\ Its source, but for what is in lib/, whose is not kept.
(define definition-of
  F -> (source-or-procedure F (declared F shen.source none)))

(define source-or-procedure
  F none -> (shen-jit.function F)
  _ Source -> Source)

(define says-nothing?
  [_ Pre _ Post] -> (and (= Pre true) (= Post true))
  [] -> true)

\\ Under (tc -) nothing is checked, so this is evaluated after the definition. What was proved of the contract before
\\ calls F then, which tests it.
(define take-contract
  Stamp -> (let Stamped (get Stamp stamped)
                F (hd Stamped)
                _ (establish F (tl Stamped))
                _ (forward F (entry-of (tl Stamped) (declared F bodies [])))
             F))

(define forward
  F [[Formals | _] | B] -> (eval [define B | (append Formals [-> [F | Formals]])])
  _ _ -> skip)

\\ [F N | Contract] of what forms define, and [F | Action], the action of the first clause of F. The last of each name
\\ counts, as its type does. They are made once, in the place there is for them.
(define made-of
  Read -> (made-once Read (<-address Read 1)))

(define made-once
  _ [Contracts | Operations] -> [Contracts | Operations]
  Read _ -> (let Forms (<-address Read 0)
                 Made [(contracts-in Forms 1) | (operations-in Forms)]
                 _ (address-> Read 1 Made)
              Made))

(define contracts-in
  [] _ -> []
  [[define G { | Rest] | Forms] N -> (with-last (contract-in G N Rest (stamp Rest)) (contracts-in Forms (+ N 1)))
  [_ | Forms] N -> (contracts-in Forms (+ N 1)))

(define contract-in
  _ N _ [Stamp] -> (placed N (get Stamp stamped))
  G N Rest [] -> [G N | (signed G (arity G) (hd (signature-of Rest)))])

(define placed
  N [F | C] -> [F N | C])

(define place-of
  Form [X | Forms] N -> (if (shen-jit.same? Form X) N (place-of Form Forms (+ N 1)))
  _ [] N -> N)

(define operations-in
  [] -> []
  [[define G | Rest] | Forms] -> (with-last [G | (first-action Rest)] (operations-in Forms))
  [_ | Forms] -> (operations-in Forms))

(define with-last
  [F | X] Others -> (if (empty? (assoc F Others)) [[F | X] | Others] Others))

(define first-action
  [Arrow Action | _] -> Action where (arrow? Arrow)
  [_ | Tokens] -> (first-action Tokens)
  [] -> none)

\\ What define-checked made is told by its stamp, whose contract it has: in its first clause, (do Stamp E).
(define stamp
  [[do S _] | _] -> [S] where (stamp? S)
  [_ | Tokens] -> (stamp Tokens)
  [] -> [])

(define stamp?
  S -> (and (symbol? S) (cons? (declared S stamped []))))

\\ What is in the braces of a definition, and what is after them.
(define signature-of
  Rest -> (let Split (until-brace none Rest []) [(fst Split) | (snd Split)]))

\\ Those of a function made elsewhere, as one: each that is of this module or one that this requires, or all if there
\\ is no module here. What a module requires of its own does not bind those that require it.
(define outside-contract
  F -> (joined (contracts-from (declared F outside []) (shen-jit.module.loading-list))))

(define contracts-from
  Contracts [] -> (map (fn tl) Contracts)
  Contracts [Here | _] -> (let Modules (assoc Here (shen-jit.module.requires-list))
                            (mapcan (/. Entry (if (element? (hd Entry) Modules) [(tl Entry)] [])) Contracts)))

(define joined
  [] -> []
  [C] -> C
  [[Formals Pre R Post] [Names P S Q] | Cs]
  -> (joined [[Formals (conjunction [Pre (replace Names Formals P)]) R (conjunction [Post (replace [S | Names] [R | Formals] Q)])] | Cs]))

(define trusted
  F -> (if (and (symbol? F) (known? F)) (declared F trusted []) []))

\\ Whether F is what is known by its name: what refine says of a module's function is so once that is loaded, and not of a
\\ program's own, whose source is kept.
(define known?
  F -> (let M (declared F library none)
         (or (= M none) (and (element? M (shen-jit.module.loaded-list))
                             (empty? (assoc F (value *operations*)))
                             (= none (declared F shen.source none))))))

\\ What a type is made with. That of a pair and of a function is written between its parts.
(define type-name
  [_ Op _] -> Op where (element? Op [* -->])
  [Name | _] -> Name
  T -> T)

(define pure?
  F -> (or (and (declared F pure false) (known? F)) (struct-pure? F)))

\\ What a struct's operation is: [make T], [test T], [read T I], I the field's position, [] for another
\\ function or for what reads a field that changes.
(define struct-operation
  F -> (let T (declared F shen-jit.struct.of [])
            Op (if (empty? T) (operation-of F (declared F shen-jit.struct.operation-of [])) [make T])
         (if (or (empty? Op) (made-by-defstruct? F (assoc F (value *operations*)))) Op [])))
\\ Not one that a program has defined again.
(set *operations* [])

(define by-defstruct?
  [Op | _] -> (element? Op [shen-jit.struct.slot! shen-jit.struct.ref shen-jit.struct.tagged])
  _ -> false)

(define made-by-defstruct?
  F [_ | Action] -> (and (by-defstruct? Action) (or (= none (defstruct-procedure F)) (as-it-was? F (defstruct-procedure F))))
  F [] -> (as-it-was? F (defstruct-procedure F)))

(define defstruct-procedure
  F -> (procedure-of F (declared F shen-jit.struct.field [])))

(define as-it-was?
  F Procedure -> (trap-error (shen-jit.same? Procedure (shen-jit.function F)) (/. E false)))

(define procedure-of
  _ [Procedure | _] -> Procedure
  F [] -> (declared F shen-jit.struct.procedure none))

(define operation-of
  _ [] -> []
  F T -> [make T] where (= F (member T ".make"))
  F T -> [test T] where (= F (member T "?"))
  F T -> (read-operation F T (struct-fields T) 1))

(define struct-fields
  T -> (hd (tl (declared T shen-jit.struct.schema [[] []]))))

(define member
  T End -> (intern (cn (str T) End)))

(define read-operation
  _ _ [] _ -> []
  F T [[Label Mutable _] | Fields] I -> (if (= F (shen-jit.struct.reader-name T Label))
                                            (if Mutable [] [read T I])
                                            (read-operation F T Fields (+ I 1))))

(define struct-pure?
  F -> (cons? (struct-operation F)))

\\ What does not test its condition, for each contract that F has had: what was proved to meet one calls that one's. Its
\\ name is one that no program has.
(define body-for
  F C -> (let Entry (entry-of C (declared F bodies [])) (if (cons? Entry) (tl Entry) (new-body F C))))

(define new-body
  F C -> (let B (gensym (intern (cn (str F) ".%body")))
              _ (put F bodies [[C | B] | (declared F bodies [])])
           B))

(define entry-of
  _ [] -> []
  C [[D | B] | Bodies] -> (if (identical? C D) [D | B] (entry-of C Bodies)))

\\ Whether two terms are written the same: 25 and 2.5e1 are equal, and are not.
(define identical?
  [X | Xs] [Y | Ys] -> (and (identical? X Y) (identical? Xs Ys))
  X Y -> (and (= X Y) (or (not (number? X)) (= (str X) (str Y)))))

(define variables?
  [] -> true
  [X | Xs] -> (and (variable? X) (variables? Xs))
  _ -> false)

\\ P with each of some variables replaced by a term. Conditions bind nothing (said-of).
(define replace
  [] _ P -> P
  Xs Ts X -> (replacement Xs Ts X) where (variable? X)
  Xs Ts [P | Ps] -> [(replace Xs Ts P) | (replace Xs Ts Ps)]
  _ _ P -> P)

(define replacement
  [] _ X -> X
  [X | _] [T | _] X -> T
  [_ | Xs] [_ | Ts] X -> (replacement Xs Ts X))

(define without
  _ [] -> []
  X [X | Ys] -> Ys
  X [Y | Ys] -> [Y | (without X Ys)])

(define some-mentioned?
  [] _ -> false
  [X | Xs] Tokens -> (or (mentions? X Tokens) (some-mentioned? Xs Tokens)))

(define comparison?
  Op -> (element? Op [= fx= fx< fx> fx<= fx>= < > <= >= fl< fl> fl<= fl>=]))

\\ A list whose elements are there.
(define written?
  [] -> true
  [cons _ Xs] -> (written? Xs)
  _ -> false)

\\ Those that an and joins, and all of some as one.
(define conditions
  true -> []
  [and P Q] -> (append (conditions P) (conditions Q))
  P -> [P])

(define conjunction
  Ps -> (all-of (mapcan (fn conditions) Ps)))

(define all-of
  [] -> true
  [P] -> P
  [P | Ps] -> [and P (all-of Ps)])

\\ ---------------------------------------------------------------------------
\\ (define-checked F {X : T --> ... --> R : T} {requires P ...} {ensures Q ...} Clause ...): define, with the
\\ arguments and the result named for either section, or neither. With a condition, F tests it.

\\ What is in the braces that tokens start with, if their first word is Key, and the tokens after.
(define section
  F Key [{ Word | Rest] -> (until-brace F Rest []) where (= Key (word Word))
  _ _ Tokens -> (@p [] Tokens))

\\ As a namespace leaves it.
(define word
  [protect X] -> X
  X -> X)

(define until-brace
  _ [} | Rest] Seen -> (@p (reverse Seen) Rest)
  F [X | Rest] Seen -> (until-brace F Rest [X | Seen])
  F [] _ -> (error "define-checked: ~A has a { with no }" F))

(define split-signature
  _ [{ Word | Rest] -> (@p [] [{ Word | Rest]) where (element? (word Word) [requires ensures])
  F [{ | Rest] -> (let Split (until-brace F Rest [])
                    (@p (named (between-arrows (fst Split) []) 1) (snd Split)))
  _ Tokens -> (@p [] Tokens))

(define between-arrows
  [] Part -> [(reverse Part)]
  [--> | Rest] Part -> [(reverse Part) | (between-arrows Rest [])]
  [X | Rest] Part -> (between-arrows Rest [X | Part]))

\\ A name and the tokens of a type. An argument with no name is given one, the same each time it is read.
(define named
  [] _ -> []
  [[X : | Type] | Parts] N -> [(@p X Type) | (named Parts (+ N 1))] where (variable? X)
  [Type | Parts] N -> [(@p (intern (make-string "Argument%~A" N)) Type) | (named Parts (+ N 1))])

(define plain-signature
  [] -> []
  Parts -> [{ | (append (types-between-arrows (map (fn snd) Parts)) [}])])

(define types-between-arrows
  [Type] -> Type
  [Type | Types] -> (append Type [--> | (types-between-arrows Types)]))

\\ [Formals Pre Result Post], with what the types say. A function of no arguments has nothing before its arrow.
(define contract-of
  _ [] [] [] -> [[] true none true]
  F [] _ _ -> (error "define-checked: ~A has conditions, and no signature to name what they are of" F)
  F [(@p _ []) | Parts] Pres Posts -> (contract-of F Parts Pres Posts) where (cons? Parts)
  F Parts Pres Posts -> (let Names (reverse (map (fn fst) Parts))
                             Formals (reverse (tl Names))
                             Types (map (/. Part (one-type (snd Part))) Parts)
                             Twice (twice F Names)
                          [Formals (conjunction [(of-types Formals Types) (said-of F requires Formals Pres)])
                           (hd Names) (conjunction [(of-type (hd Names) (hd (reverse Types))) (said-of F ensures Names Posts)])]))

\\ The contract that the signature of a function F of N arguments alone makes, or [].
(define signed
  _ _ Tokens -> [] where (not (refined-in? Tokens))
  F N Tokens -> (trap-error (contract-of F (named (parts-of-type N Tokens) 1) [] [])
                            (/. E (error "~A, in the signature of ~A" (error-to-string E) F))))

\\ The types of N arguments and of the result, which may be written as one of a function.
(define parts-of-type
  N [--> | Tokens] -> (parts-of-type N Tokens)
  N Tokens -> (unrolled N (between-arrows Tokens [])))

(define unrolled
  0 Parts -> [(fold-arrows Parts)]
  N [[T]] <- (arrow-parts N (shen.curry-type T) (shen.rectify-type T))
  N [Part | Parts] -> [Part | (unrolled (- N 1) Parts)]
  _ [] -> [])

\\ A function's type as it is written, or as its synonym is.
(define arrow-parts
  N [A --> B] _ -> [[A] | (unrolled (- N 1) [[B]])]
  N _ [A --> B] -> [[A] | (unrolled (- N 1) [[B]])]
  _ _ _ -> (fail))

(define fold-arrows
  [Part] -> Part
  [Part | Parts] -> (append Part [--> | (fold-arrows Parts)])
  [] -> [])

(define one-type
  [T] -> T
  Tokens -> Tokens)

(define twice
  _ [] -> false
  F [X | Xs] -> (if (element? X Xs) (error "define-checked: ~A names ~A twice" F X) (twice F Xs)))

(define said-of
  F Key Names Ps -> (let Conditions (map (fn macroexpand) Ps)
                         _ (readable F Conditions)
                         Others (difference (shen.extract-vars Conditions) Names)
                      (if (empty? Others)
                          (conjunction Conditions)
                          (error "refine: ~A ~A something of ~A, which is not a name it can be of" F Key (hd Others)))))

\\ What refine has of its own is not for programs to write, nor what binds.
(define readable
  F [Head | _] -> (error "refine: ~A has a condition with ~A, and conditions bind nothing" F Head) where (element? Head [let lambda])
  F [X | Xs] -> (map (/. Y (readable F Y)) [X | Xs])
  F X -> (error "refine: ~A has ~A, which is refine's own" F X) where (own? X)
  _ X -> X)

(define own?
  X -> (element? X [valued partial again argument applied literal]))

\\ A clause is [Patterns Arrow Action Guard], its guard none if it has none.
(define split-clauses
  _ [] -> []
  F Tokens -> (split-clause F Tokens []))

(define split-clause
  F [Arrow Action where Guard | Rest] Seen -> [[(reverse Seen) Arrow Action Guard] | (split-clauses F Rest)]
    where (arrow? Arrow)
  F [Arrow Action | Rest] Seen -> [[(reverse Seen) Arrow Action none] | (split-clauses F Rest)]
    where (arrow? Arrow)
  F [Pattern | Rest] Seen -> (split-clause F Rest [Pattern | Seen])
  F [] _ -> (error "define-checked: ~A has a clause with no arrow" F))

(define arrow?
  X -> (element? X [-> <-]))

(define join-clauses
  [] -> []
  [[Patterns Arrow Action none] | Cs] -> (append Patterns [Arrow Action | (join-clauses Cs)])
  [[Patterns Arrow Action Guard] | Cs] -> (append Patterns [Arrow Action where Guard | (join-clauses Cs)]))

(define expand-define
  [_ F | Written]
  -> (let Signed (split-signature F Written)
          Required (section F requires (snd Signed))
          Ensured (section F ensures (snd Required))
          Clauses (split-clauses F (no-section F (snd Ensured)))
          Contract (contract-of F (fst Signed) (fst Required) (fst Ensured))
          Check (check-contract F Contract Clauses)
       (expand-contract F (plain-signature (fst Signed)) Contract Clauses))
  _ -> (simple-error "define-checked: no name"))

(define no-section
  F [{ Word | _] -> (error "define-checked: ~A has ~A in braces, where requires can be and then ensures" F (word Word))
  _ Tokens -> Tokens)

(define check-contract
  F _ [] -> (error "define-checked: ~A has no clauses" F)
  F _ [[Patterns | _] | Clauses] -> (error "define-checked: the clauses of ~A do not have as many arguments" F)
    where (not (same-lengths? Patterns Clauses))
  F [[] true none true] _ -> F
  F [Formals | _] [[Patterns | _] | _] -> F where (= (length Formals) (length Patterns))
  F _ _ -> (error "define-checked: the signature of ~A does not have its arguments" F))

(define same-lengths?
  _ [] -> true
  Patterns [[Others | _] | Clauses] -> (and (= (length Patterns) (length Others)) (same-lengths? Patterns Clauses)))

\\ F's first clause is for what does not meet its condition, and has its stamp.
(define expand-contract
  F Signature C Clauses -> [[define F | (append Signature (join-clauses Clauses))]] where (says-nothing? C)
  F Signature C Clauses -> (let Stamp (gensym contract)
                                _ (put Stamp stamped [F | C])
                             [[define F | (append Signature (join-clauses [(stamped Stamp (unmet F C)) | Clauses]))]
                              | (if (tc?) [] [[take-contract Stamp]])]))

(define stamped
  Stamp [Formals Arrow Error Guard] -> [Formals Arrow [do Stamp Error] Guard])

\\ One test of it all is quicker, and what fails is looked for then.
(define unmet
  _ [Formals true | _] -> [Formals -> [simple-error ""] false]
  F [Formals Pre | _] -> [Formals -> (processed (not-met-first F (conditions Pre))) (processed [not Pre])])

\\ As the reader makes code of what is written, where a function with some of its arguments is a lambda.
(define processed
  X -> (shen.process-applications X (shen.find-types X)))

(define not-met-first
  F [P] -> [simple-error (make-string "~A: not so: ~R" F P)]
  F [P | Ps] -> [if P (not-met-first F Ps) (not-met-first F [P])])

\\ What was read after a define-checked may have been of its name too.
(define only-contract
  F C -> F where (says-nothing? C)
  F _ -> (cases (cons? (declared F outside [])) (error "refine.contract: ~A has a contract of its own" F)
                (cons? (trusted F)) (error "refine.trust: ~A has a contract of its own" F)
                true F))

\\ ---------------------------------------------------------------------------
\\ Whether what was proved is tested.

(define here
  -> (let Modules (shen-jit.module.loading-list) (if (empty? Modules) none (hd Modules))))

\\ The modules, none for what is no module's, in which it is not.
(set *untested* [])

(define refine.test
  + -> (do (set *untested* (without (here) (value *untested*))) true)
  - -> (do (set *untested* (adjoin (here) (value *untested*))) false)
  _ -> (simple-error "refine.test expects a + or a -"))

(declare refine.test [symbol --> boolean])

\\ ---------------------------------------------------------------------------
\\ (refine.type T X : Base where P): a name for Base, or the fixnums, and for P of what is given that type, an argument, a
\\ result or a field of a struct. T may have parameters, (nonempty A).

(define expand-type
  [_ T X where P] -> (new-type T X fixnum P) where (variable? X)
  [_ T X : Base where P] -> (new-type T X Base P) where (variable? X)
  Form -> (error "refine.type: ~R is not (refine.type Name Variable : Base where Condition)" Form))

(define new-type
  T X Base P -> (let Name (type-name T)
                     Condition (said-of Name "says" [X] [P])
                     Free (difference (shen.extract-vars Base) (parameters T))
                     Conditions (conditions-of X Base)
                  (cases (mentions? Name Base) (error "refine.type: ~R is under itself" T)
                         (cons? Free) (error "refine.type: ~A is not a parameter of ~R" (hd Free) T)
                         (taken? T Name) (error "refine.type: ~A is a type already" Name)
                         true (do (put Name condition [X Condition (shen.curry-type Base) T])
                                  (put Name refined true)
                                  (set *unchecked* (adjoin Name (value *unchecked*)))
                                  [[synonyms T (shen.rectify-type Base)]])))
    where (and (symbol? (type-name T)) (not (variable? (type-name T))) (not (= (type-name T) (intern "_")))
               (or (symbol? T) (variables? (tl T))))
  T _ _ _ -> (error "refine.type: ~R is not a type" T))

\\ Those whose condition was not seen to be a Boolean, which may call what is defined after it.
(set *unchecked* [])

(define check-types
  [] -> checked
  [T | Ts] -> (do (set *unchecked* Ts) (check-type T (declared T condition [])) (check-types Ts)))

(define check-type
  T [X P Base _] -> (if (boolean-of? [X] [(shen.rectify-type Base) --> boolean] P)
                        checked
                        (do (put T condition refused) (error "refine.type: ~A needs a condition on ~R, not ~R" T Base P))))

\\ Whether a name is that of one of the kernel's types, a struct or a union, a synonym, or a datatype.
(define taken?
  T Name -> (or (element? Name [number fixnum float symbol string boolean verified list vector stream exception lazy in out unit str
                                * --> ==>])
                (cons? (declared Name shen-jit.struct.schema []))
                (and (not (declared Name refined false)) (not (= T (shen.rectify-type T))))
                (some-datatype? (str Name) (value shen.*alldatatypes*))))

\\ A union T has a datatype T.%M for each member M.
(define some-datatype?
  _ [] -> false
  Name [[D | _] | Ds] -> (or (= (str D) (cn Name "#type")) (starts? (str D) (cn Name ".%")) (some-datatype? Name Ds)))

(define starts?
  _ "" -> true
  (@s C S) (@s C P) -> (starts? S P)
  _ _ -> false)

(define parameters
  [_ | Ts] -> Ts
  _ -> [])

(define condition
  T -> (declared (type-name T) condition []) where (symbol? (type-name T))
  _ -> [])

\\ What types say of terms.
(define of-types
  [] _ -> true
  [X | Xs] [T | Ts] -> (conjunction [(of-type X T) (of-types Xs Ts)]))

(define of-type
  X T -> (conditions-of X T) where (empty? (condition T))
  X T -> (of-refined X T (condition T)))

(define of-refined
  _ T refused -> (error "refine: ~A has a condition that was refused" T)
  _ T [_ _ _ Declared] -> (error "refine: ~R is not a type, and ~R is" T Declared)
    where (not (= (length (parameters T)) (length (parameters Declared))))
  X T [V P Base Declared] -> (conjunction [(of-type X (replace (parameters Declared) (parameters T) Base)) (replace [V] [X] P)]))

\\ A type that is not refined says nothing, and has none in it.
(define conditions-of
  X T -> (error "refine: ~R has a refined type in it, which is for a whole argument, result or field" T)
    where (and (cons? T) (refined-in? T) (empty? (condition T)))
  _ _ -> true)

(define refined-in?
  [X | Xs] -> (or (refined-in? X) (refined-in? Xs))
  X -> (and (symbol? X) (refined? X (declared X condition []))))

(define refined?
  _ [] -> false
  X _ -> (if (empty? (declared X shen-jit.struct.schema [])) true (error "refine: ~A is a refined type and a struct" X)))

\\ ---------------------------------------------------------------------------
\\ Other declarations, each read as the name it declares.

\\ (refine.trust (F Formal ...) --> Result where P): what a call gives, whatever its arguments, as said.
(define expand-trust
  [_ [F | Formals] --> R where P] -> (if (cons? (established F))
                                         (error "refine.trust: ~A has a contract of its own" F)
                                         (do (put F trusted [Formals R (said-of F trusts [R | Formals] [P])]) [F]))
    where (and (symbol? F) (variables? Formals) (variable? R))
  Form -> (error "refine.trust: ~R is not (refine.trust (F Formal ...) --> Result where Condition)" Form))

\\ (refine.contract (F X ...) --> R requires P ... trusts Q ...): a contract of a function that is made elsewhere, its
\\ result named for what is trusted, with either part or both. F tests what it must itself: nothing here changes it.
(define expand-contract-of
  [_ [F | Formals] --> R | Tokens] -> (outside F Formals R (words Tokens)) where (and (variable? R) (names? F Formals))
  [_ [F | Formals] | Tokens] -> (outside F Formals (gensym (protect R)) (words Tokens)) where (names? F Formals)
  Form -> (error "refine.contract: ~R is not (refine.contract (F X ...) --> Result requires Condition ... trusts Promise ...)" Form))

\\ What follows requires, and what follows trusts.
(define words
  [Word | Tokens] -> (required-words Tokens []) where (= (word Word) requires)
  [Word | Tokens] -> (@p [] Tokens) where (= (word Word) trusts)
  _ -> (@p [] []))

(define required-words
  [] Ps -> (@p (reverse Ps) [])
  [Word | Tokens] Ps -> (@p (reverse Ps) Tokens) where (= (word Word) trusts)
  [P | Tokens] Ps -> (required-words Tokens [P | Ps]))

(define names?
  F Formals -> (and (symbol? F) (not (variable? F)) (variables? Formals)))

(define outside
  F _ _ (@p [] []) -> (error "refine.contract: ~A has neither requires nor trusts" F)
  F _ _ _ -> (error "refine.contract: ~A has a contract of its own" F) where (cons? (established F))
  F Formals _ _ -> (error "refine.contract: ~A takes ~A, and not the arguments ~R" F (arity F) Formals)
    where (not (element? (arity F) [-1 (length Formals)]))
  F _ _ _ -> (error "refine.contract: ~A is read by refine as what it is, and not as a call" F)
    where (element? F [if and or not let lambda do freeze trap-error type protect cond where fn])
  F Formals R (@p Ps Qs)
  -> (let Contract [Formals (said-of F requires Formals Ps) R (said-of F trusts [R | Formals] Qs)]
          _ (boolean-of F Formals (function-type F) (hd (tl Contract)))
          _ (boolean-of F (append Formals [R]) (with-result (function-type F)) (hd (tl (tl (tl Contract)))))
          _ (map (/. G (put G outside (shen.assoc-> (here) Contract (declared G outside []))))
                 (both-names F (declared F shen-jit.struct.operation-of none)))
       [F]))

\\ A struct's constructor has two.
(define both-names
  F T -> [F (member T ".%make")] where (= F (member T ".make"))
  F _ -> [F])

\\ That a condition is a Boolean, its names being of the types of F's arguments, and of its result.
(define boolean-of
  _ _ [] _ -> true
  F Names T P -> (or (boolean-of? Names T P) (error "refine: not a condition on what ~A takes and gives: ~R" F P)))

(define boolean-of?
  Names T P -> (not (= false (shen.typecheck (abstraction Names P) (giving Names T)))))

(define abstraction
  [] P -> P
  [X | Xs] P -> [lambda X (abstraction Xs P)])

(define giving
  [] _ -> boolean
  [_ | Xs] [A --> B] -> [A --> (giving Xs B)]
  _ _ -> (simple-error "refine: a function of fewer arguments"))

\\ A function's type, its result given as one more argument.
(define with-result
  [] -> []
  [--> B] -> [B --> boolean]
  [A --> B] -> [A --> (with-result B)]
  B -> [B --> boolean])

\\ (refine.pure F ...): the same arguments give the same result, and nothing changes that.
(define expand-pure
  [_ | Fs] -> (map (/. F (do (put F pure true) F)) Fs))

\\ ---------------------------------------------------------------------------

(define initialise
  -> (do (shen.register-source-form define-checked (fn expand-define))
         (shen.register-source-form refine.type (fn expand-type))
         (shen.register-source-form refine.trust (fn expand-trust))
         (shen.register-source-form refine.pure (fn expand-pure))
         (shen.register-source-form refine.contract (fn expand-contract-of))
         (shen.x.namespaces.register-syntax refine.contract (fn namespace-words))
         (shen.x.namespaces.register-syntax define-checked (fn namespace-syntax))
         (shen.x.namespaces.register-definitions define-checked (fn introduced))))

\\ In a namespace the words that start the sections are not its own.
(define namespace-syntax
  [Head F | Tokens] -> [Head F | (protect-sections Tokens)]
  Form -> Form)

(define namespace-words
  [Head | Tokens] -> [Head | (map (/. X (if (element? X [requires trusts]) [protect X] X)) Tokens)])

(define protect-sections
  [{ Key | Tokens] -> [{ [protect Key] | (protect-sections Tokens)] where (element? Key [requires ensures])
  [X | Tokens] -> [X | (protect-sections Tokens)]
  [] -> [])

(define introduced
  [_ F | _] -> [F])

(initialise)

)

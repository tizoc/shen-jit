\\ The walk of what the type checker has checked, as it would run. Each expression is a term (refine-prove.shen), what its
\\ calls promise is known after them, and what they need is asked for where they are. The kernel is asked of what was
\\ written, and nothing of refine's.

(shen.x.namespace refine
  (use smt)
  (use shen-jit)
  (use shen)

\\ Where in the program that is, whether nothing is asked, the calls that were proved, with what does not test them, and the
\\ patterns that were matched, with their terms and what their names are.
(set *where* "")
(set *quiet* false)
(set *proved* [])
(set *matched* [])
(set *bound* [])

(define need
  _ _ true -> true
  _ _ _ -> true where (value *quiet*)
  F Verb P -> (if (aside (freeze (smt.unsat? (ask P))))
                  true
                  (error "type error~A: ~A ~A ~A" (in-where) F Verb (not-proved P (conditions P)))))

(define in-where
  -> (if (= (value *where*) "") "" (cn " in " (value *where*))))

\\ ---------------------------------------------------------------------------
\\ Expressions. Env is [Name | Term], or [Name | (@p again Type)] for what may be something else each time it is read, the
\\ type being (@p F S) for the field that F reads of S, which F's contract tells of.

(define ran
  Env E -> (ran-form Env E (written-as Env E (value *matched*))) where (cons? E)
  Env X -> (ran-name X (assoc X Env)))

\\ A let may bind a constant.
(define ran-name
  X [] -> (constant X)
  _ [X | T] -> (read-again X T))

(define read-again
  X (@p again (@p F S)) -> (let V (new-value [again X (part-type F S)])
                                _ (if (tuple? S) skip (know (promised (contract F) [S] V)))
                             (there-now V))
  X (@p again T) -> (there-now (new-value [again X T]))
  _ T -> T)

(define again-type
  (@p F S) -> (part-type F S)
  T -> T)

(define there-now
  X -> (do (know-fields X) X))

\\ What is written as a pattern was is what that matched, as the kernel takes it. The kernel compiles a definition without
\\ protect, and a datatype's rule may type a cond.
(define ran-form
  _ E [_ | T] -> (read-again E T)
  Env [F | Args] _ -> (applied (ran Env F) (ran-each Env Args)) where (or (cons? F) (cons? (assoc F Env)))
  Env [let X E B] _ -> (let Y (binding X) T (ran Env E) (ran [[Y | (short Y T)] | Env] B))
  Env [do A B] _ -> (let T (ran Env A) (ran Env B))
  Env [if P A B] _ -> (let C (ran Env P) [if C (under C (freeze (ran Env A))) (under [not C] (freeze (ran Env B)))])
  Env [cond [P A] | Cs] _ -> (ran-form Env [if P A [cond | Cs]] [])
  Env [and P Q] _ -> (let C (ran Env P) [and C (under C (freeze (ran Env Q)))])
  Env [or P Q] _ -> (let C (ran Env P) [or C (under [not C] (freeze (ran Env Q)))])
  Env [not P] _ -> [not (ran Env P)]
  Env [lambda X B] _ -> (ran-lambda Env (binding X) B)
  Env [freeze B] _ -> (let T (aside (freeze (ran Env B))) (new-value [freeze]))
  Env [trap-error E H] _ -> (let T (aside (freeze (ran Env E))) U (aside (freeze (ran Env H))) (new-value [trap-error]))
  Env [type E T] _ -> (let X (ran Env E) _ (need (make-string "~R : ~R" (shown X) T) "needs" (of-type X T)) X)
  Env [protect X] _ -> (ran Env X)
  Env [fn F] _ -> (partial-of (tests-itself F) [])
  _ [where _ _] _ -> (error "refine: a where that is no guard~A" (in-where))
  _ [F | _] _ -> (error "refine: ~A is refine's own~A" F (in-where)) where (own? F)
  Env [F | Args] _ -> (made-call F (ran-each Env Args) [F | Args]))

\\ What a let or a lambda binds. The kernel lets it be a constant, whose value is then wherever that is written, and a form,
\\ which is not read here.
(define binding
  X -> (error "refine: a let or a lambda binds ~R~A, which is no name" X (in-where)) where (cons? X)
  X -> X)

(define written-as
  _ _ [] -> []
  Env E [[P | T] | Matched] -> (if (and (as-pattern? E P) (same-names? Env P)) [P | T] (written-as Env E Matched)))

\\ Whether an expression is a pattern, which cannot have protect, as the kernel compares them: by =.
(define as-pattern?
  [protect E] P -> (as-pattern? E P)
  [E | Es] [P | Ps] -> (each-as-pattern? [E | Es] [P | Ps])
  E P -> (= E P))

(define each-as-pattern?
  [] [] -> true
  [E | Es] [P | Ps] -> (and (as-pattern? E P) (each-as-pattern? Es Ps))
  _ _ -> false)

\\ Whether what a pattern has, constants too, is what it was where the pattern matched: a let or a lambda may bind either.
(define same-names?
  Env [X | Y] -> (and (same-names? Env X) (same-names? Env Y))
  Env X -> (shen-jit.same? (assoc X Env) (assoc X (value *bound*))))

\\ Each is known what was before all, in whichever order they run, and what each made known is so after them.
(define ran-each
  _ [] -> []
  Env [E | Es] -> (let Old (value *facts*)
                       T (ran Env E)
                       New (newer Old (value *facts*))
                       _ (set *facts* Old)
                       Ts (ran-each Env Es)
                       _ (set *facts* (append New (value *facts*)))
                    [T | Ts]))

(define newer
  Old Facts -> (first-of (- (length Facts) (length Old)) Facts))

(define first-of
  0 _ -> []
  N [X | Xs] -> [X | (first-of (- N 1) Xs)])

\\ What is known in a part that may not run is known after it as far as that did.
(define under
  P Thunk -> (let F (formula P)
                  Old (value *facts*)
                  _ (set *facts* [F | Old])
                  X (thaw Thunk)
                  New (newer [F | Old] (value *facts*))
                  _ (set *facts* (append (map (/. G [or [not F] G]) New) Old))
               X))

\\ What is known there, and what has a name there only, is not after it.
(define aside
  Thunk -> (let Old (map (fn value) (known-of))
                X (thaw Thunk)
                _ (set-each (known-of) Old)
             X))

(define set-each
  [] _ -> skip
  [X | Xs] [V | Vs] -> (do (set X V) (set-each Xs Vs)))

(define quietly
  Thunk -> (let Old (value *quiet*)
                _ (set *quiet* true)
                X (thaw Thunk)
                _ (set *quiet* Old)
             X))

\\ A term that is long is another, equal to it.
(define short
  X T -> (do (name-value X T) T) where (brief? T)
  X T -> (let V (new-value [argument X (type-of T)])
              _ (if (exact? T) (set *facts* [(equal V T) | (value *facts*)]) skip)
           V))

\\ A term is shown by the first name that it has.
(define name-value
  X T -> (if (cons? T) (set *shown* (append (value *shown*) [[X | T]])) skip))

(define ran-lambda
  Env X [F | Args] -> (aside (freeze (steady-partial Env (tests-itself F) (reverse (tl (reverse Args))))))
    where (and (partial? X F Args) (empty? (assoc F Env)))
  Env X B -> (let T (aside (freeze (ran [[X | (new-value [argument X []])] | Env] B)))
                  E (eta [X] B)
               (if (or (empty? E) (cons? (assoc (hd E) Env)))
                   (new-value [lambda])
                   (aside (freeze (quietly (freeze (steady-partial Env (hd E) (tl E)))))))))

\\ A lambda's function with some of its arguments, which it works out each time that it is called: the same if they are,
\\ and not if they are what a call that is not pure gave, or what may change.
(define steady-partial
  Env F Args -> (let N (length (value *values*))
                     Ts (ran-each Env Args)
                  (if (made-since? N (valued-in Ts)) (new-value [lambda]) (partial-of F Ts))))

(define made-since?
  _ [] -> false
  N [M | Ms] -> (or (> M N) (made-since? N Ms)))

\\ A function that is not called there must test what it needs. What defstruct makes does not.
(define tests-itself
  F -> (if (made-untested? F (own-contract F))
           (error "refine: ~A does not test what its fields' types say, and is only for direct calls" F)
           F))

(define made-untested?
  F [_ Pre | _] -> (and (not (= Pre true)) (not (= none (declared F shen-jit.struct.operation-of (declared F shen-jit.struct.of none)))))
  _ _ -> false)

\\ Whether a lambda of X is what the reader makes of a function F with all but the last of its arguments: that is no call
\\ of it, and F tests its condition.
(define partial?
  X F Args -> (and (symbol? F) (cons? Args) (= X (hd (reverse Args))) (= 1 (occurrences X [F | Args])) (readers-name? (str X))))

\\ Those it makes from here on have more digits than a program's own are likely to.
(set *digits* (length (explode (gensym (protect Y)))))

(define readers-name?
  (@s "Y" S) -> (and (= "" (after-digits S)) (<= (value *digits*) (+ 1 (length (explode S)))))
  _ -> false)

(define after-digits
  (@s C S) -> (after-digits S) where (element? C ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"])
  S -> S)

(define applied
  T Ts -> (there-now (new-value [applied T | Ts])))

(define made-call
  F Ts E -> (let C (contract F)
                 _ (set *replaced* 0)
                 _ (need-of F C Ts E)
                 X (value-of-call (compare-numbers (length Ts) (arity F)) F Ts C)
                 _ (know (divided F Ts))
                 _ (know (promised C Ts X))
              (there-now X)))

(define value-of-call
  same F Ts C -> (call-value F Ts (definition F C))
  less F Ts _ -> (partial-of (tests-itself F) Ts)
  more F Ts _ -> (new-value [applied F | Ts]))

(define need-of
  F [Formals Pre | _] Ts E -> (do (need F "needs" (replace Formals Ts Pre)) (proved F E))
    where (and (not (= Pre true)) (= (length Formals) (length Ts)))
  _ _ _ _ -> skip)

\\ What has divided has not divided by 0.
(define divided
  F [_ D] -> [not [fx= D 0]] where (element? F [fxquotient fxremainder])
  _ _ -> true)

(define promised
  [Formals _ R Post] Ts X -> (replace [R | Formals] [X | Ts] Post) where (= (length Formals) (length Ts))
  _ _ _ -> true)

\\ The fields of a struct that is there are of their types. A list or a pair is none, however long.
(define know-fields
  [Op | _] -> skip where (element? Op [cons @p])
  X -> (let T (type-name (type-of X))
         (if (symbol? T) (map (/. Field (know-field (shen-jit.struct.reader-name T (hd Field)) X)) (struct-fields T)) skip)))

(define know-field
  F X -> (know (field-says (struct-operation F) F X)))

\\ ---------------------------------------------------------------------------
\\ Patterns. [Env Conditions Matched] of patterns on terms: what each variable is, the last of its places, as the kernel
\\ takes it, what must hold for them to match, the last first, and the patterns that have parts, with their terms. A condition
\\ that cannot be read is unclear, and one that a variable is there again is followed by again.

(define bind-each
  [] [] B -> B
  [P | Ps] [T | Ts] B -> (bind-each Ps Ts (bind-one P T B)))

(define bind-one
  P _ B -> B where (= P (intern "_"))
  P T B -> (bind-variable P T (assoc P (hd B)) B) where (variable? P)
  [cons P Q] T B -> (bind-each [P Q] [(part head T) (part tail T)] (matching [cons P Q] T [cons? T] B))
  [@p P Q] T B -> (bind-each [P Q] [(part fst T) (part snd T)] (matching [@p P Q] T [tuple? T] B))
  [F | Ps] T B -> (bind-call (struct-operation F) F Ps T B)
  P T B -> (having (if (tuple? T) unclear [= T P]) B))

(define having
  C [Env Cs Ms] -> [Env [C | Cs] Ms])

(define matching
  P T C [Env Cs Ms] -> [Env [(if (tuple? T) unclear C) | Cs] (if (mentions? (intern "_") P) Ms [[P | T] | Ms])])

(define bind-variable
  X T [] [Env Cs Ms] -> [[[X | T] | Env] Cs Ms]
  X T [_ | S] [Env Cs Ms] -> [[[X | T] | Env] [again (if (or (tuple? S) (tuple? T)) unclear [= S T]) | Cs] Ms])

(define bind-call
  [make S] F Ps T B -> (bind-each Ps (fields-at S (struct-fields S) T) (matching [F | Ps] T [(member S "?") T] B))
  _ F Ps T B -> (bind-each Ps (map (/. P (@p again [])) Ps) (matching [F | Ps] T unclear B)))

\\ The fields of a struct. Those that may change are something else each time they are read.
(define fields-at
  _ [] _ -> []
  S [Field | Fields] T -> (let F (shen-jit.struct.reader-name S (hd Field))
                            [(if (empty? (struct-operation F)) (@p again (@p F T)) (part F T)) | (fields-at S Fields T)]))

(define part
  F (@p again T) -> (@p again (part-type F (@p again T)))
  F T -> (simplify [F T]))

(define part-type
  F T -> (type-of [F (if (tuple? T) (new-value [argument F (again-type (snd T))]) T)]))

\\ ---------------------------------------------------------------------------
\\ Definitions.

\\ F's clauses, by the conditions of its contract C, of arguments of some types.
(define walk-clauses
  _ _ _ [] _ _ -> done
  F C Types [Clause | Cs] N Earlier -> (let _ (walk-clause F C Types Clause (make-string "rule ~A of ~A" N F) Earlier)
                                         (walk-clauses F C Types Cs (+ N 1) (earlier Clause Earlier))))

\\ Those that did not match, the last first, as [Patterns | Guard].
(define earlier
  [Patterns Arrow Action Guard] Earlier -> (if (= Arrow ->) [[Patterns | (fst (guarded Arrow Guard Action))] | Earlier] Earlier))

(define walk-clause
  F C Types [Patterns Arrow Action Guard] Where Earlier
  -> (let Args (arguments Where C Types Patterns)
          _ (map (/. E (deny E Args)) (reverse Earlier))
          B (bind-each Patterns Args [[] [] []])
          Guarded (guarded Arrow Guard Action)
          _ (set *matched* (matched B))
          _ (set *bound* (hd B))
          _ (set *shown* (append (shown-names (append (hd B) (hd (tl (tl B))))) (value *shown*)))
          _ (map (fn know-condition) (reverse (hd (tl B))))
          _ (map (/. E (know-fields (tl E))) (shown-names (hd B)))
          _ (know-guard (hd B) (fst Guarded))
       (walk-action F C Args (hd B) Arrow (snd Guarded))))

\\ The terms of a definition's arguments, about which its condition is known, as a clause is walked.
(define arguments
  Where C Types Patterns -> (let _ (reset)
                                 _ (set *where* Where)
                                 _ (set *quiet* false)
                                 _ (set *matched* [])
                                 Args (typed-arguments (argument-names (formals C) Patterns) Types)
                                 _ (map (fn know-fields) Args)
                                 _ (set *shown* [])
                                 _ (know (given C Args))
                              Args))

(define formals
  [Formals | _] -> Formals
  [] -> [])

(define given
  [Formals Pre | _] Args -> (replace Formals Args Pre)
  [] _ -> true)

\\ An argument is shown by the name it was given, or by its pattern.
(define argument-names
  [X | Xs] [P | Ps] -> [(if (starts? "Argument%" (str X)) P X) | (argument-names Xs Ps)]
  _ Ps -> Ps)

(define typed-arguments
  [] _ -> []
  [X | Xs] [T | Ts] -> [(new-value [argument X T]) | (typed-arguments Xs Ts)]
  [X | Xs] [] -> [(new-value [argument X []]) | (typed-arguments Xs [])])

(define know-condition
  C -> (if (cons? C) (know C) skip))

\\ What is known of a guard is all that it says.
(define know-guard
  _ none -> skip
  Env G -> (assume (ran Env G)))

(define assume
  T -> (set *facts* [(formula T) | (value *facts*)]))

\\ The patterns that the kernel takes for what they matched. Where a variable is there again, or a pattern, what they say of
\\ it is not: 1 may have matched 1.0.
(define matched
  [_ Cs Ms] -> (if (or (element? again Cs) (some-twice? (map (fn hd) Ms))) (map (/. M [(hd M) | (@p again (type-of (tl M)))]) Ms) Ms))

(define some-twice?
  [] -> false
  [X | Xs] -> (or (element? X Xs) (some-twice? Xs)))

(define shown-names
  Entries -> (mapcan (/. E (if (tuple? (tl E)) [] [E])) Entries))

\\ An action (where G E) is E, guarded by G too.
(define guarded
  Arrow G [where H E] -> (guarded Arrow (if (= G none) H [and G H]) E) where (= Arrow ->)
  _ G E -> (@p G E))

\\ That an earlier clause did not match: some pattern failed, or its guard was false. Nothing if that cannot be read.
(define deny
  [Patterns | Guard] Args -> (let B (bind-each Patterns Args [[] [] []])
                                  Cs (hd (tl B))
                               (if (element? unclear Cs)
                                   skip
                                   (denied B (conjunction (reverse (mapcan (/. C (if (cons? C) [C] [])) Cs))) Guard))))

(define denied
  _ P none -> (know [not P])
  B P Guard -> (let _ (set *matched* (matched B))
                    _ (set *bound* (hd B))
                    T (aside (freeze (quietly (freeze (under P (freeze (ran (hd B) Guard)))))))
                    _ (set *matched* [])
                 (assume [not [and P T]])))

\\ The kernel looks for fail-if at the head of the action of a <- clause, which is elsewhere a function that gives (fail).
(define walk-action
  F C Args Env Arrow [fail-if G E] -> (let T (ran Env G) (walk-ends F C Args Env false E)) where (not (= Arrow ->))
  F C Args Env Arrow E -> (walk-ends F C Args Env (not (= Arrow ->)) E))

(define walk-ends
  F [Formals _ R Post] Args Env Retried E -> (each-end Retried (/. T (need F "promises" (replace [R | Formals] [T | Args] Post))) Env E)
  _ _ _ Env _ E -> (ran Env E))

\\ Each value that an expression can give, where it gives it. A let may have the name of what is none of these.
(define each-end
  _ End Env [F | Args] -> (End (ran Env [F | Args])) where (cons? (assoc F Env))
  Retried End Env [let X E B] -> (let Y (binding X) T (ran Env E) (each-end Retried End [[Y | (short Y T)] | Env] B))
  Retried End Env [do A B] -> (let T (ran Env A) (each-end Retried End Env B))
  Retried End Env [if P A B] -> (let C (ran Env P)
                                     _ (under C (freeze (each-end Retried End Env A)))
                                  (under [not C] (freeze (each-end Retried End Env B))))
  Retried End Env E -> (let T (ran Env E) (if (leaves? Retried E) true (End T))))

\\ An expression that gives nothing: it raises, or tries the next clause if (fail) does here.
(define leaves?
  Retried [fail] -> Retried
  _ [F | _] -> (element? F [simple-error shen.f-error])
  _ _ -> false)

\\ What a condition calls is needed there.
(define walk-condition
  F [Formals Pre | Rest] Types -> (let Args (arguments (make-string "the condition of ~A" F) [Formals true | Rest] Types Formals)
                                    (ran (named-terms Formals Args) Pre))
  _ [] _ -> skip)

(define named-terms
  [] _ -> []
  [X | Xs] [T | Ts] -> [[X | T] | (named-terms Xs Ts)])

\\ ---------------------------------------------------------------------------
\\ Bodies, which do not test the condition that F tests, and which what was proved calls where that is not tested.

(define proved
  F E -> (let B (if (or (value *quiet*) (not (element? (here) (value *untested*)))) [] (body-of F (own-contract F)))
           (if (empty? B) skip (set *proved* [[E | (hd B)] | (value *proved*)]))))

\\ In a list, if there is one, or will be as a definition is called: that of what it defines or what comes after it.
(define body-of
  _ [] -> []
  F C -> [(body-for F C)] where (comes? F (value *checking*) (assoc F (value *together*)))
  F C -> (let Entry (entry-of C (declared F bodies [])) (if (and (cons? Entry) (> (arity (tl Entry)) -1)) [(tl Entry)] [])))

(define comes?
  F [F | _] _ -> true
  F [_ | _] [_ N | _] -> (and (> N (value *place*)) (not (made-by-defstruct? F (assoc F (value *operations*)))))
  _ _ _ -> false)

\\ An expression in which each call that was proved is one of a body.
(define rewritten
  E -> E where (empty? (value *proved*))
  [X | Y] -> (rewritten-call [X | Y] (value *proved*))
  E -> E)

(define rewritten-call
  E [] -> [(rewritten (hd E)) | (rewritten (tl E))]
  E [[Call | B] | Proved] -> (if (shen-jit.same? E Call) [B | (rewritten (tl E))] (rewritten-call E Proved)))

\\ F, with its test, or, if it has a body that will be called, its body and what tests for it.
(define tested
  F Type C Clauses -> [define F | (append Type (join-clauses Clauses))] where (or (empty? C) (= true (hd (tl C))))
  F Type C Clauses -> (if (or (element? (here) (value *untested*)) (cons? (entry-of C (declared F bodies []))))
                          (with-body F Type C Clauses (body-for F C))
                          [define F | (append Type (join-clauses [(unmet F C) | Clauses]))]))

(define with-body
  F Type C Clauses B -> (let _ (declare B (function-type F))
                             _ (shen-jit.eval-checked [define B | (append Type (join-clauses Clauses))])
                          [define F | (append Type (join-clauses [(unmet F C) [(hd C) -> [B | (hd C)] none]]))]))

\\ ---------------------------------------------------------------------------
\\ Around each check that the type checker makes (shen-jit.*around-typecheck*): the type of a form, what is evaluated of it,
\\ and what is done after that.

(define around
  Form Read Check -> (let Kept (map (fn value) (kept))
                          Made (made-of Read)
                          _ (set *together* (hd Made))
                          _ (set *place* (place-of Form (<-address Read 0) 1))
                          _ (set *operations* (tl Made))
                          _ (set *proved* [])
                          _ (check-types (value *unchecked*))
                          R (trap-error (@p gave (around-form Form Check)) (/. E (@p raised (error-to-string E))))
                          _ (set-each (kept) Kept)
                        (if (= (fst R) raised) (simple-error (snd R)) (snd R))))

\\ What a file that a side condition loads must leave as it was.
(define kept
  -> [*checking* *together* *place* *operations* *proved*])

(define around-form
  [define F { | Rest] Check -> (let Split (signature-of Rest)
                                    Clauses (trap-error (split-clauses F (tl Split)) (/. E []))
                                 (around-define [define F { | Rest] F (hd Split) Clauses (stamp Rest) Check))
  Form Check -> (let T (Check Form)
                     _ (if (= T false) skip (walk-expression Form))
                  [T (rewritten Form) | (freeze skip)]))

(define walk-expression
  Form -> (let _ (arguments "" [] [] []) (ran [] Form)))

\\ What defstruct makes is as it says.
(define around-define
  Form F Tokens Clauses [] Check -> [(Check Form) Form | (freeze (establish F (signed F (arity F) Tokens)))]
    where (or (empty? Clauses) (by-defstruct? (hd (tl (tl (hd Clauses))))))
  Form F Tokens Clauses [] Check -> (checked-define F Tokens (signed F (arity F) Tokens) Clauses Check)
  Form F Tokens Clauses [Stamp] Check -> (let C (tl (get Stamp stamped)) (checked-define F Tokens C (tl Clauses) Check)))

(define checked-define
  F Tokens C Clauses Check
  -> (let _ (only-contract F C)
          _ (set *checking* [F | C])
          Type [{ | (append Tokens [}])]
          Types (map (/. Part (shen.rectify-type (one-type Part))) (parts-of-type (length (hd (hd Clauses))) Tokens))
          T (Check [define F | (append Type (join-clauses Clauses))])
          _ (if (= T false) skip (walked F C Type Types Clauses Check))
          Own (map (/. Clause (map (fn rewritten) Clause)) Clauses)
       [T (tested F Type (if (= T false) [] C) Own) | (freeze (establish F C))]))

(define walked
  F C Type Types Clauses Check -> (do (checked-contract F Type C Check)
                                      (walk-condition F C Types)
                                      (walk-clauses F C Types Clauses 1 [])))

\\ That its condition and its promise are Booleans.
(define checked-contract
  _ _ [] _ -> skip
  F Type [Formals Pre R Post] Check -> (let Guarded [define F | (append Type Formals [-> [simple-error ""] where Pre])]
                                            _ (if (= Pre true) skip (Check Guarded))
                                         (if (= Post true) true (boolean-of F (append Formals [R]) (with-result (function-type F)) Post))))

(set shen-jit.*around-typecheck* [(fn around)])

)

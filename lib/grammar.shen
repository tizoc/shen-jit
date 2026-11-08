\\ Grammars over byte views: Shen-YACC's notation, compiled to loops over a buffer, a position
\\ and an end. Load buffer.shen first, then this, then the grammars, under (tc -). docs/grammar.md
\\ has the notation and the API.
\\
\\ (defgrammar <digits> (+ <digit>);)
\\ (defgrammar <digit> B where (and (>= B 48) (<= B 57));)
\\ (grammar.match? <digits> (buffer.from-string "2026"))    \\ true
\\
\\ Each definition becomes (define Name Buf At End S -> ...), returning the position after its
\\ match, -1 when it does not match, or -2 when a require failed, with that position and message in
\\ S's slots 1 and 2. A rule with := leaves its value in slot 0. (* Item) becomes a function of its
\\ own, Name/1 and so on, which loops by calling itself.

(define grammar.error
  S At Message -> (do (address-> S 1 At) (address-> S 2 Message) -2))

(define grammar.state
  -> (address-> (absvector 3) 0 skip))

(define grammar.result
  P S At End Fail -> (if (= P End) (<-address S 0) (grammar.failed P S At Fail)))

(define grammar.failed
  P S At Fail -> (cases (= P -2) (Fail (<-address S 1) (<-address S 2))
                        (= P -1) (Fail At "no match")
                        true (Fail P "trailing input")))

\\ The view is checked once, then read as cursor.shen reads it: owner, start, end in slots 1 to 3.
(define grammar.parse
  Rule View Fail ->
    (let V (buffer.check View) S (grammar.state) At (<-address V 2) End (<-address V 3)
      (grammar.result ((fn Rule) (<-address V 1) At End S) S At End Fail)))

(define grammar.match?
  Rule View -> (let V (buffer.check View) End (<-address V 3)
                 (= ((fn Rule) (<-address V 1) (<-address V 2) End (grammar.state)) End)))

\\ The same over a range of storage that a library has already checked.
(define grammar.parse-range
  Rule Buffer At End Fail -> (let S (grammar.state) (grammar.result ((fn Rule) Buffer At End S) S At End Fail)))

\\ The compiler. A position is [Var Offset], known up to a constant; Fail is the code to give
\\ when an item does not match: -1, or inside a require, its error. Done makes the code that
\\ follows a match, given its position. A context is [Name Buf End S Count Values Stack Scope
\\ Inner Rule], where Values maps each rule named in the semantics to the variable holding its value,
\\ Stack lists the rules being inlined, Scope the variables bound so far, Inner is true inside a
\\ repetition or an option, which bind no values, and Rule holds the captures the rule's end builds.

(define grammar.nonterminal?
  X -> (and (symbol? X) (not (variable? X))
            (let B (shen-jit.string->bytes (str X)) N (shen-jit.bytes-length B)
              (and (> N 2) (= (shen-jit.u8 B (- N 1)) 62) (grammar.opens? B 0 N)))))

\\ A < first, or after the dot of a prefix, as in http.<token>.
(define grammar.opens?
  B I N -> false where (>= I N)
  B I N -> true where (and (= (shen-jit.u8 B I) 60) (or (= I 0) (= (shen-jit.u8 B (- I 1)) 46)))
  B I N -> (grammar.opens? B (+ I 1) N))

(define grammar.wildcard?
  X -> (and (symbol? X) (= (str X) "_")))

(define grammar.pos
  [Var 0] -> Var
  [Var Off] -> [+ Var Off])

(define grammar.buf
  [_ Buf | _] -> Buf)

(define grammar.end
  [_ _ End | _] -> End)

(define grammar.s
  [_ _ _ S | _] -> S)

(define grammar.inner
  [Name Buf End S Count Values Stack Scope _ _] -> [Name Buf End S Count Values Stack Scope true []])

(define grammar.bind
  [Name Buf End S Count Values Stack Scope Inner Rule] X -> [Name Buf End S Count Values Stack [X | Scope] Inner Rule])

(define grammar.inner?
  [_ _ _ _ _ _ _ _ Inner | _] -> Inner)

\\ A rule as an item or an entry: <rule>, or (<rule> Arguments...) for a rule with parameters.
(define grammar.rule-form?
  [R | _] -> (grammar.nonterminal? R)
  R -> (grammar.nonterminal? R))

(define grammar.rule-name
  [R | _] -> R
  R -> R)

(define grammar.rule-args
  [_ | Args] -> Args
  _ -> [])

(define grammar.subst
  [_ _ _ _ _ Values | _] X -> (grammar.replace Values X))

(define grammar.replace
  Values [X | Y] -> (map (/. Z (grammar.replace Values Z)) [X | Y])
  Values X -> (let Found (assoc X Values) (if (empty? Found) X (tl Found))))

(define grammar.last
  L -> (hd (reverse L)))

(define grammar.butlast
  L -> (reverse (tl (reverse L))))

(define grammar.define
  Name Params Body ->
    (let Signed (grammar.signed Name Params Body)
         Sig (fst Signed)
         Rules (map (/. R (grammar.split-rule R [])) (grammar.split (snd Signed) [] []))
         _ (if (empty? Rules) (error "defgrammar ~A: no rules" Name) skip)
         _ (put Name grammar.type Sig)
         _ (put Name grammar.value (grammar.every? (/. R (not (= (hd (tl R)) grammar.none))) Rules))
         _ (put Name grammar.class (if (empty? Params) (grammar.class Rules) []))
         _ (put Name grammar.params Params)
         _ (put Name grammar.inline (grammar.inlinable Name Rules))
         _ (grammar.arity [Name | (+ 4 (length Params))])
         _ (map (function grammar.arity) (mapcan (function grammar.called) (map (function hd) Rules)))
         Buf (gensym (protect Buf)) At (gensym (protect At)) End (gensym (protect End))
         S (gensym (protect S)) Count (address-> (absvector 1) 0 0)
         Def (append [define Name Buf At End S | Params]
                     [-> (grammar.alternatives
                           (map (/. R (grammar.rule [Name Buf End S Count (grammar.values Name R) [] Params false []]
                                                    R [At 0]))
                                Rules))])
         _ (put Name grammar.code Def)
         Checked (if (empty? Sig) [] (grammar.typed Name Params Sig Rules))
      (if (tc?) (do (grammar.stub Name Def) (if (empty? Sig) Name Checked)) Def)))

\\ Typed grammars. A signature, {T1 --> T2 ==> B}, gives the parameters' types and the value's,
\\ and is read as its symbols. What an alternative names, it gives to a function annotated with
\\ (type ...), whose body has the value's type and checks the guards, the messages and the
\\ arguments; the loader checks it under (tc +). A rule cannot be checked itself, as values pass
\\ through the state, so under (tc +) every rule is defined as a stub, which the loader does not
\\ see, and compiled at its first call, as a loop is. Typed code parses with <rule>.parse and
\\ <rule>.match?.

(define grammar.signed
  Name Params [X | Body] -> (grammar.signature Name Params Body []) where (= X (intern "{"))
  _ _ Body -> (@p [] Body))

(define grammar.signature
  Name Params [X | Body] Acc ->
    (let Sig (grammar.sig-types (reverse Acc) [])
      (if (and (cons? Sig) (= (length (hd Sig)) (length Params)))
          (@p Sig Body)
          (error "defgrammar ~A: a signature gives a type for each parameter, then ==> and the value's type" Name)))
    where (= X (intern "}"))
  Name Params [X | Body] Acc -> (grammar.signature Name Params Body [X | Acc])
  Name _ _ _ -> (error "defgrammar ~A: a signature without }" Name))

\\ {T1 --> T2 ==> Value} gives [[T1 T2] Value], and a value of a function type is curried.
(define grammar.sig-types
  [X | Value] Types -> [(reverse Types) (grammar.curry Value)] where (and (= X (intern "==>")) (cons? Value))
  [T X | Tokens] Types -> (grammar.sig-types Tokens [T | Types]) where (= X (grammar.arrow))
  [T X | Tokens] Types -> (grammar.sig-types [X | Tokens] [T | Types]) where (= X (intern "==>"))
  _ _ -> [])

(define grammar.curry
  [T] -> T
  [T X | Ts] -> [T X (grammar.curry Ts)] where (cons? Ts)
  Ts -> Ts)

(define grammar.arrow
  -> (intern "-->"))

(define grammar.arrows
  [] B -> B
  [T | Ts] B -> [T (grammar.arrow) (grammar.arrows Ts B)])

(define grammar.sig-of
  R -> (trap-error (get R grammar.type) (/. E [])))

(define grammar.typed
  Name Params [Types Value] Rules ->
    (let Checked (grammar.types Name Params Types Value Rules)
         View (gensym (protect V)) Fail (gensym (protect F))
         Parse (grammar.client-name Name ".parse")
         Match (grammar.client-name Name ".match?")
         _ (declare Parse (grammar.arrows (append Types [buffer.view (grammar.arrows [number string] Value)]) Value))
         _ (declare Match (grammar.arrows (append Types [buffer.view]) boolean))
         _ (eval (append [define Parse | Params] [View Fail -> (grammar.parse-form [Name | Params] View Fail)]))
         _ (eval (append [define Match | Params] [View -> (grammar.match-form [Name | Params] View)]))
      Checked))

(define grammar.client-name
  Name Suffix -> (intern (cn (str Name) Suffix)))

\\ The alternatives as the clauses of Name.types, a function of everything any of them names, so
\\ that a type error says which alternative it is in: the parameters, the numbers the items bind,
\\ and a variable for each rule named, with the type of its value or its capture.
(define grammar.types
  Name Params Types Value Rules ->
    (let Kinds (map (/. R (grammar.named Name R)) Rules)
         Vars (grammar.unique (mapcan (/. R (difference (grammar.scope (hd R)) Params)) Rules) [])
         Named (map (/. K [K | (gensym (protect V))]) (grammar.unique (mapcan (/. K K) Kinds) []))
         Sig (append Types (map (/. V number) Vars) (map (/. N (grammar.value-type Name (hd N))) Named))
      (append [define (grammar.client-name Name ".types") (intern "{")
               | (if (empty? Sig) [(grammar.arrow) Value] (append (mapcan (/. T [T (grammar.arrow)]) Sig) [Value]))]
              [(intern "}") | (mapcan (/. RK (grammar.clause Named (append Params Vars (map (function tl) Named))
                                                            (hd RK) (tl RK)))
                                      (grammar.zip Rules Kinds))])))

\\ The rules an alternative names, each as [Rule How], matched plain, as text, or as a span.
(define grammar.named
  Name [_ grammar.none _] -> (error "defgrammar ~A: a typed rule gives a value with := in every alternative" Name)
  Name [Items Sem Guard] -> (let Top (grammar.top Items)
                              (map (/. V [(hd V) (tl (assoc (hd V) Top))]) (grammar.values Name [Items Sem Guard]))))

(define grammar.clause
  Named Patterns [Items Sem Guard] Kinds ->
    (let Values (map (/. K [(hd K) | (tl (assoc K Named))]) Kinds)
         Checks (grammar.replace Values (append (if (= Guard grammar.none) [] [Guard]) (grammar.checks Items)))
         Result (grammar.replace Values Sem)
      (append Patterns [(intern "->") (if (empty? Checks) Result [if (grammar.conj Checks) Result Result])])))

(define grammar.value-type
  _ [_ text] -> string
  _ [_ span] -> buffer.view
  Name [R _] -> (let Sig (grammar.sig-of R)
                  (if (empty? Sig)
                      (error "defgrammar ~A: ~A's value has no type: give ~A a signature" Name R R)
                      (hd (tl Sig)))))

\\ The numbers an alternative's items bind: bytes, positions and fields.
(define grammar.scope
  [] -> []
  [X | Items] -> [X | (grammar.scope Items)] where (variable? X)
  [[F V] | Items] -> [V | (grammar.scope Items)] where (and (element? F [at u16-be u32-be]) (variable? V))
  [[require | Rest] | Items] -> (append (grammar.scope (grammar.butlast Rest)) (grammar.scope Items))
  [_ | Items] -> (grammar.scope Items))

\\ Guards are booleans, messages strings, and arguments have the types of a typed rule's parameters.
(define grammar.checks
  [] -> []
  [[where G] | Items] -> [G | (grammar.checks Items)]
  [[require | Rest] | Items] ->
    (append (grammar.checks (grammar.butlast Rest)) [[= (grammar.last Rest) ""] | (grammar.checks Items)])
  [[F X] | Items] -> (append (grammar.checks [X]) (grammar.checks Items)) where (element? F [* + ? text span])
  [[R | Args] | Items] -> [(append [(grammar.client-name R ".match?") | Args] [[buffer.new 0]]) | (grammar.checks Items)]
    where (and (grammar.nonterminal? R) (cons? Args) (cons? (grammar.sig-of R)))
  [_ | Items] -> (grammar.checks Items))

\\ A function compiled at its first call: Def, saved, and a stub that compiles it.
(define grammar.stub
  H Def -> (let Params (grammar.parameters Def)
                _ (put H grammar.loop Def)
             (eval (append [define H | Params] [-> [grammar.compile H (grammar.list Params)]]))))

\\ A byte class, B where Guard and nothing else, is tested in place by the rules read after it.
(define grammar.class
  [[[V] Sem Guard]] -> [V Guard] where (and (variable? V) (= Sem grammar.none) (not (= Guard grammar.none)))
  _ -> [])

\\ A small rule that does not name itself is compiled in place by the rules read after it, up to
\\ three deep, instead of called.
(define grammar.inlinable
  Name Rules -> (let Items (map (function hd) Rules)
                  (if (and (<= (grammar.size Items) 12)
                           (not (element? Name (map (function hd) (grammar.called (mapcan (/. X X) Items))))))
                      Rules
                      [])))

(define grammar.size
  [] -> 0
  [X | Y] -> (+ (grammar.size X) (grammar.size Y))
  _ -> 1)

\\ A file is read whole before any of it runs, so a rule's arity is stored as it is read, for
\\ calls to it, earlier or later in the file, to be direct, as for define.
(define grammar.arity
  [R | N] -> (if (= (arity R) -1) (shen.store-arity R N) skip))

\\ The rules items call, each with the arity of the call.
(define grammar.called
  [] -> []
  [X | Items] -> [[X | 4] | (grammar.called Items)] where (and (grammar.nonterminal? X) (not (element? X [<e> <end>])))
  [[R | Args] | Items] -> [[R | (+ 4 (length Args))] | (grammar.called Items)] where (grammar.nonterminal? R)
  [[F | Args] | Items] -> (append (grammar.called (if (= F require) (grammar.butlast Args) Args))
                                  (grammar.called Items)) where (element? F [* + ? text span require])
  [_ | Items] -> (grammar.called Items))

(define grammar.every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (grammar.every? F Xs)))

(define grammar.split
  [] [] Rules -> (reverse Rules)
  [] Rule Rules -> (reverse [(reverse Rule) | Rules])
  [X | Body] Rule Rules -> (grammar.split Body [] [(reverse Rule) | Rules]) where (= X (intern ";"))
  [X | Body] Rule Rules -> (grammar.split Body [X | Rule] Rules))

(define grammar.split-rule
  [] Items -> [(reverse Items) grammar.none grammar.none]
  [X Sem] Items -> [(reverse Items) Sem grammar.none] where (= X (intern ":="))
  [X Sem where Guard] Items -> [(reverse Items) Sem Guard] where (= X (intern ":="))
  [where Guard] Items -> [(reverse Items) grammar.none Guard]
  [X | Rest] Items -> (grammar.split-rule Rest [X | Items])
    where (not (or (= X (intern ":=")) (= X where)))
  Rest _ -> (error "defgrammar: expected Items := Value where Guard;, not ~R" Rest))

(define grammar.alternatives
  [Code] -> Code
  [Code | Codes] -> (let R (gensym (protect R)) [let R Code [if [= R -1] (grammar.alternatives Codes) R]]))

\\ The rules a rule's semantics name, each with a fresh variable for its value. Only a rule matched
\\ outside a repetition has one, and only a rule with := gives one.
(define grammar.values
  Name [Items Sem Guard] ->
    (let Used (grammar.symbols [Sem Guard | (mapcan (function grammar.item-uses) Items)])
         Named (grammar.top Items)
      (mapcan (/. R (grammar.value Name R Named)) (grammar.unique (grammar.nonterminals Used) []))))

(define grammar.nonterminals
  Xs -> (mapcan (/. X (if (grammar.nonterminal? X) [X] [])) Xs))

(define grammar.unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (grammar.unique Xs (if (element? X Acc) Acc [X | Acc])))

(define grammar.value
  Name R Named ->
    (let Found (assoc R Named)
      (cases (empty? Found) (error "defgrammar ~A: ~A is named but not matched outside a repetition" Name R)
             (and (= (tl Found) plain) (= (trap-error (get R grammar.value) (/. E unknown)) false))
               (error "defgrammar ~A: ~A gives no value, having no :=" Name R)
             true [[R | (gensym (protect V))]])))

(define grammar.symbols
  [X | Y] -> (append (grammar.symbols X) (grammar.symbols Y))
  X -> [X] where (symbol? X)
  _ -> [])

(define grammar.item-uses
  [where G] -> [G]
  [require | Rest] -> [(grammar.last Rest) | (mapcan (function grammar.item-uses) (grammar.butlast Rest))]
  [R | Args] -> Args where (grammar.nonterminal? R)
  [F X] -> (grammar.item-uses X) where (element? F [* + ? text span])
  _ -> [])

(define grammar.top
  [] -> []
  [X | Items] -> [[X | plain] | (grammar.top Items)] where (grammar.nonterminal? X)
  [[R | _] | Items] -> [[R | plain] | (grammar.top Items)] where (grammar.nonterminal? R)
  [[Capture R] | Items] -> [[(grammar.rule-name R) | Capture] | (grammar.top Items)]
    where (and (element? Capture [text span]) (grammar.rule-form? R))
  [[require | Rest] | Items] -> (append (grammar.top (grammar.butlast Rest)) (grammar.top Items))
  [_ | Items] -> (grammar.top Items))

\\ What items bind: their variables, and the rules they name.
(define grammar.bound
  Items -> (append (map (function hd) (grammar.top Items)) (grammar.variables Items)))

(define grammar.variables
  [X | Y] -> (append (grammar.variables X) (grammar.variables Y))
  X -> [X] where (variable? X)
  _ -> [])

(define grammar.rule
  [Name Buf End S Count Values Stack Scope Inner _] [Items Sem Guard] Pos ->
    (let Cell (address-> (address-> (absvector 2) 0 []) 1 (grammar.symbols (mapcan (function grammar.item-uses) Items)))
         C [Name Buf End S Count Values Stack Scope Inner Cell]
      (grammar.seq C Items Pos -1 (/. P (grammar.done C P Sem Guard)))))

\\ The captures left for the end are built before the guard if it names them, and after it if not.
(define grammar.done
  C P Sem Guard ->
    (let Cell (grammar.cell C)
         Deferred (if (absvector? Cell) (reverse (<-address Cell 0)) [])
         Checked (if (= Guard grammar.none) [] (grammar.subst C Guard))
         Named (grammar.symbols Checked)
         Early (mapcan (/. D (if (element? (hd D) Named) [D] [])) Deferred)
         Late (mapcan (/. D (if (element? (hd D) Named) [] [D])) Deferred)
         Value (grammar.binds Late
                 (if (= Sem grammar.none)
                     (grammar.pos P)
                     [do [address-> (grammar.s C) 0 (grammar.subst C Sem)] (grammar.pos P)]))
      (grammar.binds Early (if (= Guard grammar.none) Value [if Checked Value -1]))))

(define grammar.cell
  [_ _ _ _ _ _ _ _ _ Cell | _] -> Cell)

(define grammar.binds
  [] Code -> Code
  [[V | E] | Rest] Code -> [let V E (grammar.binds Rest Code)])

(define grammar.seq
  _ [] Pos _ Done -> (Done Pos)
  C [X | Items] Pos Fail Done -> (grammar.terminals C (grammar.run [X | Items] []) Pos Fail Done)
    where (or (number? X) (string? X))
  C [X | Items] Pos Fail Done -> (grammar.item C X Items Pos Fail Done))

(define grammar.run
  [X | Items] Bytes -> (grammar.run Items (append Bytes (grammar.bytes X))) where (or (number? X) (string? X))
  Items Bytes -> (@p Bytes Items))

(define grammar.bytes
  N -> [N] where (and (integer? N) (>= N 0) (<= N 255))
  S -> (let B (shen-jit.string->bytes S) (grammar.byte-list B (shen-jit.bytes-length B) [])) where (string? S)
  X -> (error "defgrammar: ~S is not a byte or a string" X))

(define grammar.byte-list
  _ 0 Acc -> Acc
  B N Acc -> (grammar.byte-list B (- N 1) [(shen-jit.u8 B (- N 1)) | Acc]))

\\ One bounds check for a run of literal bytes, then a test of each.
(define grammar.terminals
  C (@p [] Items) Pos Fail Done -> (grammar.seq C Items Pos Fail Done)
  C (@p Bytes Items) [Var Off] Fail Done ->
    (let N (length Bytes)
      [if (grammar.conj [[< (grammar.pos [Var (+ Off (- N 1))]) (grammar.end C)]
                         | (grammar.compares C Bytes Var Off)])
          (grammar.seq C Items [Var (+ Off N)] Fail Done)
          Fail]))

(define grammar.compares
  _ [] _ _ -> []
  C [Byte | Bytes] Var Off -> [[= [shen-jit.u8 (grammar.buf C) (grammar.pos [Var Off])] Byte]
                               | (grammar.compares C Bytes Var (+ Off 1))])

(define grammar.conj
  [X] -> X
  [X | Xs] -> [and X (grammar.conj Xs)])

(define grammar.byte
  C Pos Fail Rest -> [if [< (grammar.pos Pos) (grammar.end C)] Rest Fail])

(define grammar.next
  [Var Off] -> [Var (+ Off 1)])

(define grammar.item
  C X Items Pos Fail Done ->
    (cases (grammar.wildcard? X) (grammar.byte C Pos Fail (grammar.seq C Items (grammar.next Pos) Fail Done))
           (variable? X)
             (grammar.byte C Pos Fail
               [let X [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)]
                 (grammar.seq (grammar.bind C X) Items (grammar.next Pos) Fail Done)])
           (= X <e>) (grammar.seq C Items Pos Fail Done)
           (= X <end>) [if [< (grammar.pos Pos) (grammar.end C)] Fail (grammar.seq C Items Pos Fail Done)]
           (grammar.nonterminal? X)
             (let Class (trap-error (get X grammar.class) (/. E []))
               (if (empty? Class)
                   (grammar.call C X Pos Fail (/. P [<-address (grammar.s C) 0]) false Items Done)
                   (grammar.inline C X Items Pos Fail Done)))
           (cons? X) (grammar.form C X Items Pos Fail Done)
           true (error "defgrammar: ~R is not an item" X)))

(define grammar.inline
  C X Items Pos Fail Done ->
    (let B (gensym (protect B))
      (grammar.byte C Pos Fail
        [let B [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)]
          [if (grammar.in-class X B) (grammar.seq C Items (grammar.next Pos) Fail Done) Fail]])))

\\ A class's test, as a form that the macro turns into its guard, or that a loop compiled at its
\\ first call turns into a lookup in a table of the 256 bytes.
(define grammar.in-class
  X B -> (let Class (get X grammar.class) [grammar.in-class X B (grammar.replace [[(hd Class) | B]] (hd (tl Class)))]))

\\ A loop over a byte class tests its first byte in place, and is called only if it matches.
(define grammar.class-of
  X -> (trap-error (get X grammar.class) (/. E [])) where (grammar.nonterminal? X)
  _ -> [])

(define grammar.class-test
  C X Pos ->
    (let B (gensym (protect B))
      [and [< (grammar.pos Pos) (grammar.end C)]
           [let B [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)] (grammar.in-class X B)]]))

(define grammar.args
  C Pos -> [(grammar.buf C) (grammar.pos Pos) (grammar.end C) (grammar.s C)])

\\ Calls R, binds its value if the semantics name it, and goes on from where it stopped.
(define grammar.call
  C R Pos Fail Value Capture Items Done ->
    (grammar.after (grammar.invoke C R Pos) Fail
      (/. P (let Name (grammar.rule-name R)
                 Found (assoc Name (grammar.subst-values C))
                 Bind (and (cons? Found) (not (grammar.inner? C)))
                 Defer (and Bind Capture (grammar.defer C Name (tl Found) (Value P)))
                 Now (and Bind (not Defer))
                 Rest (grammar.seq (if Now (grammar.bind C (tl Found)) C) Items [P 0] Fail Done)
              (if Now [let (tl Found) (Value P) Rest] Rest)))))

\\ A capture that no later item names is left for the rule's end, so that a match that fails after
\\ it does not build it. A rule's own value must be read at once, before the next call replaces it.
(define grammar.defer
  C Name Var Code ->
    (let Cell (grammar.cell C)
      (if (and (absvector? Cell) (not (element? Name (<-address Cell 1))))
          (do (address-> Cell 0 [[Var | Code] | (<-address Cell 0)]) true)
          false)))

(define grammar.subst-values
  [_ _ _ _ _ Values | _] -> Values)

\\ R's alternatives in place, when it is small, or a call to it. In place, its parameters are
\\ renamed and bound to the arguments, which are evaluated first.
(define grammar.invoke
  [Name Buf End S Count Values Stack Scope Inner _] R Pos ->
    (let Callee (grammar.rule-name R)
         Args (grammar.replace Values (grammar.rule-args R))
         Params (trap-error (get Callee grammar.params) (/. E Args))
         _ (if (= (length Params) (length Args)) skip
               (error "defgrammar ~A: ~A takes ~A arguments, not ~R" Name Callee (length Params) Args))
         Rules (trap-error (get Callee grammar.inline) (/. E []))
      (if (or (empty? Rules) (= Callee Name) (element? Callee Stack) (>= (length Stack) 3))
          (append [Callee Buf (grammar.pos Pos) End S] Args)
          (let Fresh (map (/. X (gensym (protect A))) Params)
            (grammar.lets Fresh Args
              (grammar.alternatives
                (map (/. Alt (grammar.rule [Name Buf End S Count (grammar.values Callee Alt) [Callee | Stack] Fresh false []]
                                           Alt Pos))
                     (grammar.replace (grammar.zip Params Fresh) Rules))))))))

(define grammar.zip
  [] [] -> []
  [X | Xs] [Y | Ys] -> [[X | Y] | (grammar.zip Xs Ys)])

(define grammar.lets
  [] [] Code -> Code
  [X | Xs] [E | Es] Code -> [let X E (grammar.lets Xs Es Code)])

\\ A call's result is a position, -1 or -2: -1 fails as this item fails, and -2 goes up as it is.
(define grammar.after
  Call Fail K ->
    (let P (gensym (protect P))
         Body (K P)
      (if (and (= Body P) (= Fail -1))
          Call
          [let P Call [if [< P 0] (if (= Fail -1) P [if [= P -1] Fail P]) Body]])))

(define grammar.form
  C [R | Args] Items Pos Fail Done ->
    (grammar.call C [R | Args] Pos Fail (/. P [<-address (grammar.s C) 0]) false Items Done)
    where (grammar.nonterminal? R)
  C [* X] Items Pos Fail Done ->
    (let Class (grammar.class-of X)
         Helper (grammar.loop C X)
         Loop (append [(hd Helper) | (grammar.args C [(grammar.pos Pos) (if (empty? Class) 0 1)])] (tl Helper))
      (if (empty? Class)
          (grammar.after Loop -1 (/. P (grammar.seq C Items [P 0] Fail Done)))
          (let P (gensym (protect P))
            [let P [if (grammar.class-test C X Pos) Loop (grammar.pos Pos)]
              (grammar.seq C Items [P 0] Fail Done)])))
  C [+ X] Items Pos Fail Done -> (grammar.seq C [X [* X] | Items] Pos Fail Done)
  C [? X] Items Pos Fail Done ->
    (let R (gensym (protect R))
         Inner (grammar.seq (grammar.inner C) [X] Pos -1 (function grammar.pos))
      (grammar.after [let R Inner [if [= R -1] (grammar.pos Pos) R]] -1
        (/. P (grammar.seq C Items [P 0] Fail Done))))
  C [text R] Items Pos Fail Done ->
    (grammar.call C R Pos Fail
      (/. P [shen-jit.bytes->string (grammar.buf C) (grammar.pos Pos) [- P (grammar.pos Pos)]]) true Items Done)
    where (grammar.rule-form? R)
  C [span R] Items Pos Fail Done ->
    (grammar.call C R Pos Fail (/. P [buffer.make (grammar.buf C) (grammar.pos Pos) P]) true Items Done)
    where (grammar.rule-form? R)
  C [require | Rest] Items Pos Fail Done ->
    (let Message (grammar.last Rest)
         Required (grammar.butlast Rest)
         _ (if (empty? (intersection (grammar.symbols Message) (grammar.bound Required)))
               skip
               (error "defgrammar: the message of ~R names what it requires" [require | Rest]))
      (grammar.seq C Required Pos [grammar.error (grammar.s C) (grammar.pos Pos) (grammar.subst C Message)]
        (/. P (grammar.seq C Items P Fail Done))))
    where (cons? Rest)
  C [where G] Items Pos Fail Done -> [if (grammar.subst C G) (grammar.seq C Items Pos Fail Done) Fail]
  C [at V] Items Pos Fail Done -> [let V (grammar.pos Pos) (grammar.seq (grammar.bind C V) Items Pos Fail Done)]
    where (variable? V)
  C [u16-be V] Items Pos Fail Done -> (grammar.fixed C V 2 Items Pos Fail Done) where (variable? V)
  C [u32-be V] Items Pos Fail Done -> (grammar.fixed C V 4 Items Pos Fail Done) where (variable? V)
  _ [F | Items] _ _ _ _ -> (error "defgrammar: (~A Item) takes one item: name a sequence as a rule, in ~R"
                                   F [F | Items]) where (element? F [* + ?])
  _ X _ _ _ _ -> (error "defgrammar: ~R is not an item" X))

\\ A big-endian unsigned field of N bytes, bound to V.
(define grammar.fixed
  C V N Items [Var Off] Fail Done ->
    [if [< (grammar.pos [Var (+ Off (- N 1))]) (grammar.end C)]
        [let V (grammar.big-endian C Var Off N 0)
          (grammar.seq (grammar.bind C V) Items [Var (+ Off N)] Fail Done)]
        Fail])

(define grammar.big-endian
  _ _ _ 0 Acc -> Acc
  C Var Off N Acc ->
    (grammar.big-endian C Var (+ Off 1) (- N 1)
      (let Byte [shen-jit.u8 (grammar.buf C) (grammar.pos [Var Off])]
        (if (= Acc 0) Byte [+ [shen-jit.shift-left Acc 8] Byte]))))

\\ (* X) as a function of its own: it stops where X no longer matches, or matches nothing. The
\\ macro runs as its file is read, before the file's own functions exist, and a definition
\\ compiled then would call them through fn; so it defines a stub, and the stub compiles the loop
\\ at its first call.
(define grammar.loop
  [Name Buf End S Count Values Stack Scope Inner _] X ->
    (let N (+ (<-address Count 0) 1)
         _ (address-> Count 0 N)
         H (intern (make-string "~A/~A" Name N))
         At (gensym (protect At))
         P (gensym (protect P))
         Body (grammar.seq [Name Buf End S Count Values Stack Scope true []] [X] [At 0] -1 (function grammar.pos))
         Free (grammar.unique (intersection (grammar.symbols Body) Scope) [])
         Params [Buf At End S | Free]
         _ (grammar.arity [H | (length Params)])
         _ (grammar.stub H (append [define H | Params]
                             [-> [let P Body [if [> P At] (append [H Buf P End S] Free) [if [= P -2] P At]]]]))
      [H | Free]))

(define grammar.list
  [] -> []
  [X | Xs] -> [cons X (grammar.list Xs)])

(define grammar.compile
  H Args -> (do (eval (grammar.tables (get H grammar.loop))) (grammar.apply (fn H) Args)))

(define grammar.apply
  F [] -> F
  F [X | Xs] -> (grammar.apply (F X) Xs))

\\ By a loop's first call, the functions a class's guard calls exist: a guard that depends only on
\\ its byte, as a class's must, is evaluated once for each byte. One that raises stays a test.
(define grammar.tables
  [grammar.in-class _ B Guard] ->
    (let Table (trap-error (grammar.fill (eval [/. B Guard]) (shen-jit.bytes 256) 0) (/. E none))
      (if (= Table none) Guard [= [shen-jit.u8 Table B] 1]))
  [X | Y] -> (map (function grammar.tables) [X | Y])
  X -> X)

(define grammar.fill
  _ Table 256 -> Table
  F Table B -> (grammar.fill F (if (F B) (shen-jit.u8! Table B 1) Table) (+ B 1)))

(defmacro grammar.macro
  [defgrammar Name | Body] -> (grammar.define Name [] Body) where (grammar.nonterminal? Name)
  [defgrammar [Name | Params] | Body] -> (grammar.define Name Params Body)
    where (and (grammar.nonterminal? Name) (grammar.every? (function variable?) Params))
  [defgrammar | Form] -> (error "defgrammar: expected <name> or (<name> Parameters...), and rules, in ~R" Form)
  [grammar.in-class _ _ Guard] -> Guard
  [grammar.parse Rule View Fail] -> (grammar.client Rule ".parse" [View Fail] (grammar.parse-form Rule View Fail))
    where (grammar.rule-form? Rule)
  [grammar.match? Rule View] -> (grammar.client Rule ".match?" [View] (grammar.match-form Rule View))
    where (grammar.rule-form? Rule)
  [grammar.parse-range Rule Buffer At End Fail] -> (grammar.range-form Rule Buffer At End Fail)
    where (grammar.rule-form? Rule)
  [grammar.read Rule Reader Fail] ->
    [grammar.read-from (grammar.rule-name Rule) (grammar.list (grammar.rule-args Rule)) Reader [io.window-size Reader] Fail]
    where (grammar.rule-form? Rule)
  [grammar.read-within Rule Reader Limit Fail] ->
    [grammar.read-from (grammar.rule-name Rule) (grammar.list (grammar.rule-args Rule)) Reader Limit Fail]
    where (grammar.rule-form? Rule))

\\ Typed code calls a typed rule's own functions, which have types.
(define grammar.client
  Rule Suffix Rest Code ->
    (if (and (tc?) (cons? (grammar.sig-of (grammar.rule-name Rule))))
        (append [(grammar.client-name (grammar.rule-name Rule) Suffix) | (grammar.rule-args Rule)] Rest)
        Code))

\\ A call of a rule from outside a grammar: Rule is <rule>, or (<rule> Arguments...).
(define grammar.call-rule
  Rule Buf At End S -> (append [(grammar.rule-name Rule) Buf At End S] (grammar.rule-args Rule)))

\\ With the rule named, a parse calls it directly, and Fail is evaluated only when it fails.
(define grammar.parse-form
  Rule View Fail ->
    (let V (gensym (protect V)) S (gensym (protect S)) At (gensym (protect At)) End (gensym (protect End))
      [let V [buffer.check View] S [grammar.state] At [<-address V 2] End [<-address V 3]
        (grammar.finish (grammar.call-rule Rule [<-address V 1] At End S) S At End Fail)]))

(define grammar.finish
  Call S At End Fail ->
    (let P (gensym (protect P))
      [let P Call [if [= P End] [<-address S 0] [grammar.failed P S At Fail]]]))

(define grammar.match-form
  Rule View ->
    (let V (gensym (protect V)) End (gensym (protect End))
      [let V [buffer.check View] End [<-address V 3]
        [= (grammar.call-rule Rule [<-address V 1] [<-address V 2] End [grammar.state]) End]]))

(define grammar.range-form
  Rule Buffer At End Fail ->
    (let B (gensym (protect B)) A (gensym (protect A)) E (gensym (protect E)) S (gensym (protect S))
      [let B Buffer A At E End S [grammar.state]
        (grammar.finish (grammar.call-rule Rule B A E S) S A E Fail)]))

\\ Reading from an I/O reader as input arrives. A rule's streaming variant, <rule>/stream, is its
\\ code rewritten at the first streaming call: each bounds check compares with the end of what has
\\ arrived, kept in slot 0 of a stream record that the rule gets as its end, and fills the reader
\\ when it fails; calls go to streaming variants, and views of captures copy their bytes, as the
\\ reader's buffer is reused after the value. The parse reads in place, in the reader's buffer, and
\\ consumes the value's bytes only when it is complete. Load io.shen to use it.

(define grammar.read
  Rule Reader Fail -> (grammar.read-from Rule [] Reader (io.window-size Reader) Fail))

(define grammar.read-within
  Rule Reader Limit Fail -> (grammar.read-from Rule [] Reader Limit Fail))

\\ The stream record: what has arrived, the reader, why there is no more, and the limit.
(define grammar.read-from
  Rule Args R Limit Fail ->
    (let G (grammar.prepare Rule)
         Storage (io.window R)
         Start (io.position R)
         Bound (io.min (buffer.index Limit) (io.window-size R))
         E (address-> (address-> (address-> (address-> (absvector 4) 0 (io.window-fill R 0)) 1 R) 2 []) 3 Bound)
         S (grammar.state)
         P (grammar.apply (fn G) [Storage 0 E S | Args])
      (grammar.read-result P S E Start Fail)))

\\ A parse that read into the end of the input could have matched with more: at EOF, that is
\\ "input ended", whichever rule failed. One that did not is the grammar's own failure.
(define grammar.read-result
  P S E Start Fail ->
    (let R (<-address E 1) Why (<-address E 2) End (<-address E 0)
      (cases (>= P 0) (do (io.consume R P) [ok (<-address S 0)])
             (= Why limit) (Fail (+ Start End) "input exceeds the limit")
             (and (= End 0) (= Why [eof])) [eof]
             (and (cons? Why) (not (= Why [eof]))) (io.reader-terminal R)
             (= Why [eof]) (Fail (+ Start End) "input ended")
             (= P -2) (Fail (+ Start (<-address S 1)) (<-address S 2))
             true (Fail Start "no match"))))

\\ A bounds check that failed: fill towards the byte at X, and say why there is none if there is not.
(define grammar.refill
  E X -> (let R (<-address E 1)
              Limit (<-address E 3)
              N (io.min (io.window-fill R (io.min (+ X 1) Limit)) Limit)
              _ (address-> E 0 N)
           (or (> N X)
               (do (address-> E 2 (if (>= X Limit) limit (<-address R 5))) false))))

(define grammar.copy-span
  Buf At End -> (buffer.wrap (shen-jit.copy-bytes (shen-jit.bytes (- End At)) 0 Buf At (- End At))))

(define grammar.source
  F -> (let Code (trap-error (get F grammar.code) (/. E []))
         (if (empty? Code) (trap-error (get F grammar.loop) (/. E [])) Code)))

\\ F's streaming variant, defined as a stub that compiles it at its first call, again if F changed.
(define grammar.stream
  F -> (let G (intern (cn (str F) "/stream"))
            Def (grammar.source F)
            _ (if (empty? Def) (error "grammar: ~A is not a grammar rule" F) skip)
            _ (if (shen-jit.same? (trap-error (get G grammar.made-from) (/. E [])) Def)
                  skip
                  (let Params (grammar.parameters Def)
                       _ (shen.store-arity G (length Params))
                       _ (put G grammar.made-from Def)
                       _ (put G grammar.stream-of F)
                    (eval (append [define G | Params] [-> [grammar.compile-stream G F (grammar.list Params)]]))))
         G))

\\ Compiles F's streaming variant and every one it calls now, rather than at their first calls, so
\\ that the compiling happens before a parse, and outside any deadline. A variant compiled for
\\ the current definition is left as it is.
(define grammar.prepare
  F -> (let G (grammar.stream F)
         (if (shen-jit.same? (trap-error (get G grammar.compiled) (/. E [])) (grammar.source F))
             G
             (do (map (function grammar.prepare) (grammar.install G F)) G))))

(define grammar.parameters
  [define _ | Rest] -> (grammar.before (intern "->") Rest))

(define grammar.before
  X [X | _] -> []
  X [Y | Ys] -> [Y | (grammar.before X Ys)])

(define grammar.compile-stream
  G F Args -> (do (grammar.install G F) (grammar.apply (fn G) Args)))

\\ Defines G from F's code rewritten, and gives the rules whose streaming variants it calls.
(define grammar.install
  G F ->
    (let Def (grammar.source F)
         Params (grammar.parameters Def)
         Buf (hd Params)
         End (hd (tl (tl Params)))
         Code (grammar.rewrite Buf End (hd (tl (grammar.from (intern "->") Def))))
         _ (eval (grammar.tables (append [define G | Params] [-> Code])))
         _ (put G grammar.compiled Def)
      (grammar.unique (mapcan (/. X (let Of (trap-error (get X grammar.stream-of) (/. E []))
                                      (if (and (symbol? Of) (not (= X G))) [Of] [])))
                              (grammar.symbols Code))
                      [])))

(define grammar.from
  X [X | Rest] -> [X | Rest]
  X [_ | Rest] -> (grammar.from X Rest))

(define grammar.rewrite
  Buf End [< X End] -> (let Y (grammar.rewrite Buf End X) [or [< Y [<-address End 0]] [grammar.refill End Y]])
  Buf End [buffer.make Buf A Z] -> [grammar.copy-span Buf (grammar.rewrite Buf End A) (grammar.rewrite Buf End Z)]
  Buf End [F Buf A End S | Rest] ->
    [(grammar.stream F) Buf (grammar.rewrite Buf End A) End S | (map (/. X (grammar.rewrite Buf End X)) Rest)]
    where (and (symbol? F) (cons? (grammar.source F)))
  Buf End [X | Y] -> (map (/. Z (grammar.rewrite Buf End Z)) [X | Y])
  _ _ X -> X)

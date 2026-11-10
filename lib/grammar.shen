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

(shen.x.namespace grammar
  (use buffer)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [? at defgrammar eof grammar-read-results none ok plain require skip span text u16-be
    u32-be unknown])
  (shadow bind call compile every? inline list pos read run stream subst type value)
  (export match? parse parse-range prepare read read-result read-within defgrammar)

(define grammar.error
  S At Message -> (do (address-> S 1 At) (address-> S 2 Message) -2))

(define state
  -> (address-> (absvector 3) 0 skip))

(define result
  P S At End Fail -> (if (= P End) (<-address S 0) (failed P S At Fail)))

(define failed
  P S At Fail -> (cases (= P -2) (Fail (<-address S 1) (<-address S 2))
                        (= P -1) (Fail At "no match")
                        true (Fail P "trailing input")))

\\ The view is checked once, then read as cursor.shen reads it: owner, start and end.
(define parse
  Rule View Fail ->
    (let V (buffer.check View) S (state) At (buffer.view.start V) End (buffer.view.end V)
      (result ((fn Rule) (buffer.view.owner V) At End S) S At End Fail)))

(define match?
  Rule View -> (let V (buffer.check View) End (buffer.view.end V)
                 (= ((fn Rule) (buffer.view.owner V) (buffer.view.start V) End (state)) End)))

\\ The same over a range of storage that a library has already checked.
(define parse-range
  Rule Buffer At End Fail -> (let S (state) (result ((fn Rule) Buffer At End S) S At End Fail)))

\\ The compiler. A position is [Var Offset], known up to a constant; Fail is the code to give
\\ when an item does not match: -1, or inside a require, its error. Done makes the code that
\\ follows a match, given its position. A context is [Name Buf End S Count Values Stack Scope
\\ Inner Rule], where Values maps each rule named in the semantics to the variable holding its value,
\\ Stack lists the rules being inlined, Scope the variables bound so far, Inner is true inside a
\\ repetition or an option, which bind no values, and Rule holds the captures the rule's end builds.

(define nonterminal?
  X -> (and (symbol? X) (not (variable? X))
            (let B (shen-jit.string->bytes (str X)) N (shen-jit.bytes-length B)
              (and (> N 2) (= (shen-jit.u8 B (- N 1)) 62) (opens? B 0 N)))))

\\ A < first, or after the dot of a prefix, as in http.<token>.
(define opens?
  B I N -> false where (>= I N)
  B I N -> true where (and (= (shen-jit.u8 B I) 60) (or (= I 0) (= (shen-jit.u8 B (- I 1)) 46)))
  B I N -> (opens? B (+ I 1) N))

(define wildcard?
  X -> (and (symbol? X) (= (str X) "_")))

(define pos
  [Var 0] -> Var
  [Var Off] -> [+ Var Off])

(define buf
  [_ Buf | _] -> Buf)

(define end
  [_ _ End | _] -> End)

(define s
  [_ _ _ S | _] -> S)

(define inner
  [Name Buf End S Count Values Stack Scope _ _] -> [Name Buf End S Count Values Stack Scope true []])

(define bind
  [Name Buf End S Count Values Stack Scope Inner Rule] X -> [Name Buf End S Count Values Stack [X | Scope] Inner Rule])

(define inner?
  [_ _ _ _ _ _ _ _ Inner | _] -> Inner)

\\ A rule as an item or an entry: <rule>, or (<rule> Arguments...) for a rule with parameters.
(define rule-form?
  [R | _] -> (nonterminal? R)
  R -> (nonterminal? R))

(define rule-name
  [R | _] -> R
  R -> R)

(define rule-args
  [_ | Args] -> Args
  _ -> [])

(define subst
  [_ _ _ _ _ Values | _] X -> (replace Values X))

(define replace
  Values [X | Y] -> (map (/. Z (replace Values Z)) [X | Y])
  Values X -> (let Found (assoc X Values) (if (empty? Found) X (tl Found))))

(define last
  L -> (hd (reverse L)))

(define butlast
  L -> (reverse (tl (reverse L))))

(define grammar.define
  Name Params Body ->
    (let Signed (signed Name Params Body)
         Sig (fst Signed)
         Rules (map (/. R (split-rule R [])) (split (snd Signed) [] []))
         _ (if (empty? Rules) (error "defgrammar ~A: no rules" Name) skip)
         _ (put Name type Sig)
         _ (put Name value (every? (/. R (not (= (hd (tl R)) grammar.none))) Rules))
         _ (put Name class (if (empty? Params) (class Rules) []))
         _ (put Name params Params)
         _ (put Name inline (inlinable Name Rules))
         _ (grammar.arity [Name | (+ 4 (length Params))])
         _ (map (function grammar.arity) (mapcan (function called) (map (function hd) Rules)))
         Buf (gensym (protect Buf)) At (gensym (protect At)) End (gensym (protect End))
         S (gensym (protect S)) Count (address-> (absvector 1) 0 0)
         Def (append [define Name Buf At End S | Params]
                     [-> (alternatives
                           (map (/. R (rule [Name Buf End S Count (values Name R) [] Params false []]
                                                    R [At 0]))
                                Rules))])
         _ (put Name code Def)
         Checked (if (empty? Sig) [] (typed Name Params Sig Rules))
      (if (tc?) (do (stub Name Def) (if (empty? Sig) Name Checked)) Def)))

\\ Typed grammars. A signature, {T1 --> T2 ==> B}, gives the parameters' types and the value's,
\\ and is read as its symbols. What an alternative names, it gives to a function annotated with
\\ (type ...), whose body has the value's type and checks the guards, the messages and the
\\ arguments; the loader checks it under (tc +). A rule cannot be checked itself, as values pass
\\ through the state, so under (tc +) every rule is defined as a stub, which the loader does not
\\ see, and compiled at its first call, as a loop is. Typed code parses with <rule>.parse and
\\ <rule>.match?.

(define signed
  Name Params [X | Body] -> (signature Name Params Body []) where (= X (intern "{"))
  _ _ Body -> (@p [] Body))

(define signature
  Name Params [X | Body] Acc ->
    (let Sig (sig-types (reverse Acc) [])
      (if (and (cons? Sig) (= (length (hd Sig)) (length Params)))
          (@p Sig Body)
          (error "defgrammar ~A: a signature gives a type for each parameter, then ==> and the value's type" Name)))
    where (= X (intern "}"))
  Name Params [X | Body] Acc -> (signature Name Params Body [X | Acc])
  Name _ _ _ -> (error "defgrammar ~A: a signature without }" Name))

\\ {T1 --> T2 ==> Value} gives [[T1 T2] Value], and a value of a function type is curried.
(define sig-types
  [X | Value] Types -> [(reverse Types) (curry Value)] where (and (= X (intern "==>")) (cons? Value))
  [T X | Tokens] Types -> (sig-types Tokens [T | Types]) where (= X (arrow))
  [T X | Tokens] Types -> (sig-types [X | Tokens] [T | Types]) where (= X (intern "==>"))
  _ _ -> [])

(define curry
  [T] -> T
  [T X | Ts] -> [T X (curry Ts)] where (cons? Ts)
  Ts -> Ts)

(define arrow
  -> (intern "-->"))

(define arrows
  [] B -> B
  [T | Ts] B -> [T (arrow) (arrows Ts B)])

(define sig-of
  R -> (trap-error (get R type) (/. E [])))

(define typed
  Name Params [Types Value] Rules ->
    (let Checked (types Name Params Types Value Rules)
         View (gensym (protect V)) Fail (gensym (protect F)) R (gensym (protect R)) Limit (gensym (protect L))
         Parse (client-name Name ".parse")
         Match (client-name Name ".match?")
         Read (client-name Name ".read")
         Result [read-result Value]
         _ (declare Parse (arrows (append Types [buffer.view (arrows [number string] Value)]) Value))
         _ (declare Match (arrows (append Types [buffer.view]) boolean))
         _ (declare Read (arrows (append Types [io.reader number (arrows [number string] Result)]) Result))
         _ (eval (append [define Parse | Params] [View Fail -> (parse-form [Name | Params] View Fail)]))
         _ (eval (append [define Match | Params] [View -> (match-form [Name | Params] View)]))
         _ (eval (append [define Read | Params] [R Limit Fail -> (read-form [Name | Params] R Limit Fail)]))
      Checked))

(define client-name
  Name Suffix -> (intern (cn (str Name) Suffix)))

\\ The alternatives as the clauses of Name.types, a function of everything any of them names, so
\\ that a type error says which alternative it is in: the parameters, the numbers the items bind,
\\ and a variable for each rule named, with the type of its value or its capture.
(define types
  Name Params Types Value Rules ->
    (let Kinds (map (/. R (named Name R)) Rules)
         Vars (unique (mapcan (/. R (difference (scope (hd R)) Params)) Rules) [])
         Named (map (/. K [K | (gensym (protect V))]) (unique (mapcan (/. K K) Kinds) []))
         Sig (append Types (map (/. V number) Vars) (map (/. N (value-type Name (hd N))) Named))
      (append [define (client-name Name ".types") (intern "{")
               | (if (empty? Sig) [(arrow) Value] (append (mapcan (/. T [T (arrow)]) Sig) [Value]))]
              [(intern "}") | (mapcan (/. RK (clause Named (append Params Vars (map (function tl) Named))
                                                            (hd RK) (tl RK)))
                                      (zip Rules Kinds))])))

\\ The rules an alternative names, each as [Rule How], matched plain, as text, or as a span.
(define named
  Name [_ grammar.none _] -> (error "defgrammar ~A: a typed rule gives a value with := in every alternative" Name)
  Name [Items Sem Guard] -> (let Top (top Items)
                              (map (/. V [(hd V) (tl (assoc (hd V) Top))]) (values Name [Items Sem Guard]))))

(define clause
  Named Patterns [Items Sem Guard] Kinds ->
    (let Values (map (/. K [(hd K) | (tl (assoc K Named))]) Kinds)
         Checks (replace Values (append (if (= Guard grammar.none) [] [Guard]) (checks Items)))
         Result (replace Values Sem)
      (append Patterns [(intern "->") (if (empty? Checks) Result [if (conj Checks) Result Result])])))

(define value-type
  _ [_ text] -> string
  _ [_ span] -> buffer.view
  Name [R _] -> (let Sig (sig-of R)
                  (if (empty? Sig)
                      (error "defgrammar ~A: ~A's value has no type: give ~A a signature" Name R R)
                      (hd (tl Sig)))))

\\ The numbers an alternative's items bind: bytes, positions and fields.
(define scope
  [] -> []
  [X | Items] -> [X | (scope Items)] where (variable? X)
  [[F V] | Items] -> [V | (scope Items)] where (and (element? F [at u16-be u32-be]) (variable? V))
  [[require | Rest] | Items] -> (append (scope (butlast Rest)) (scope Items))
  [_ | Items] -> (scope Items))

\\ Guards are booleans, messages strings, and arguments have the types of a typed rule's parameters.
(define checks
  [] -> []
  [[where G] | Items] -> [G | (checks Items)]
  [[require | Rest] | Items] ->
    (append (checks (butlast Rest)) [[= (last Rest) ""] | (checks Items)])
  [[F X] | Items] -> (append (checks [X]) (checks Items)) where (element? F [* + ? text span])
  [[R | Args] | Items] -> [(append [(client-name R ".match?") | Args] [[buffer.new 0]]) | (checks Items)]
    where (and (nonterminal? R) (cons? Args) (cons? (sig-of R)))
  [_ | Items] -> (checks Items))

\\ A function compiled at its first call: Def, saved, and a stub that compiles it.
(define stub
  H Def -> (let Params (parameters Def)
                _ (put H loop Def)
             (eval (append [define H | Params] [-> [compile H (list Params)]]))))

\\ A byte class, B where Guard and nothing else, is tested in place by the rules read after it.
(define class
  [[[V] Sem Guard]] -> [V Guard] where (and (variable? V) (= Sem grammar.none) (not (= Guard grammar.none)))
  _ -> [])

\\ A small rule that does not name itself is compiled in place by the rules read after it, up to
\\ three deep, instead of called.
(define inlinable
  Name Rules -> (let Items (map (function hd) Rules)
                  (if (and (<= (size Items) 12)
                           (not (element? Name (map (function hd) (called (mapcan (/. X X) Items))))))
                      Rules
                      [])))

(define size
  [] -> 0
  [X | Y] -> (+ (size X) (size Y))
  _ -> 1)

\\ A file is read whole before any of it runs, so a rule's arity is stored as it is read, for
\\ calls to it, earlier or later in the file, to be direct, as for define.
(define grammar.arity
  [R | N] -> (if (= (arity R) -1) (shen.store-arity R N) skip))

\\ The rules items call, each with the arity of the call.
(define called
  [] -> []
  [X | Items] -> [[X | 4] | (called Items)] where (and (nonterminal? X) (not (element? X [<e> <end>])))
  [[R | Args] | Items] -> [[R | (+ 4 (length Args))] | (called Items)] where (nonterminal? R)
  [[F | Args] | Items] -> (append (called (if (= F require) (butlast Args) Args))
                                  (called Items)) where (element? F [* + ? text span require])
  [_ | Items] -> (called Items))

(define every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (every? F Xs)))

(define split
  [] [] Rules -> (reverse Rules)
  [] Rule Rules -> (reverse [(reverse Rule) | Rules])
  [X | Body] Rule Rules -> (split Body [] [(reverse Rule) | Rules]) where (= X (intern ";"))
  [X | Body] Rule Rules -> (split Body [X | Rule] Rules))

(define split-rule
  [] Items -> [(reverse Items) grammar.none grammar.none]
  [X Sem] Items -> [(reverse Items) Sem grammar.none] where (= X (intern ":="))
  [X Sem where Guard] Items -> [(reverse Items) Sem Guard] where (= X (intern ":="))
  [where Guard] Items -> [(reverse Items) grammar.none Guard]
  [X | Rest] Items -> (split-rule Rest [X | Items])
    where (not (or (= X (intern ":=")) (= X where)))
  Rest _ -> (error "defgrammar: expected Items := Value where Guard;, not ~R" Rest))

(define alternatives
  [Code] -> Code
  [Code | Codes] -> (let R (gensym (protect R)) [let R Code [if [= R -1] (alternatives Codes) R]]))

\\ The rules a rule's semantics name, each with a fresh variable for its value. Only a rule matched
\\ outside a repetition has one, and only a rule with := gives one.
(define values
  Name [Items Sem Guard] ->
    (let Used (symbols [Sem Guard | (mapcan (function item-uses) Items)])
         Named (top Items)
      (mapcan (/. R (value Name R Named)) (unique (nonterminals Used) []))))

(define nonterminals
  Xs -> (mapcan (/. X (if (nonterminal? X) [X] [])) Xs))

(define unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (unique Xs (if (element? X Acc) Acc [X | Acc])))

(define value
  Name R Named ->
    (let Found (assoc R Named)
      (cases (empty? Found) (error "defgrammar ~A: ~A is named but not matched outside a repetition" Name R)
             (and (= (tl Found) plain) (= (trap-error (get R value) (/. E unknown)) false))
               (error "defgrammar ~A: ~A gives no value, having no :=" Name R)
             true [[R | (gensym (protect V))]])))

(define symbols
  [X | Y] -> (append (symbols X) (symbols Y))
  X -> [X] where (symbol? X)
  _ -> [])

(define item-uses
  [where G] -> [G]
  [require | Rest] -> [(last Rest) | (mapcan (function item-uses) (butlast Rest))]
  [R | Args] -> Args where (nonterminal? R)
  [F X] -> (item-uses X) where (element? F [* + ? text span])
  _ -> [])

(define top
  [] -> []
  [X | Items] -> [[X | plain] | (top Items)] where (nonterminal? X)
  [[R | _] | Items] -> [[R | plain] | (top Items)] where (nonterminal? R)
  [[Capture R] | Items] -> [[(rule-name R) | Capture] | (top Items)]
    where (and (element? Capture [text span]) (rule-form? R))
  [[require | Rest] | Items] -> (append (top (butlast Rest)) (top Items))
  [_ | Items] -> (top Items))

\\ What items bind: their variables, and the rules they name.
(define bound
  Items -> (append (map (function hd) (top Items)) (variables Items)))

(define variables
  [X | Y] -> (append (variables X) (variables Y))
  X -> [X] where (variable? X)
  _ -> [])

\\ What a rule's end builds, latest first, and the symbols its items name, which are built at once.
(defstruct captures
  (mutable deferred)
  used)

(define rule
  [Name Buf End S Count Values Stack Scope Inner _] [Items Sem Guard] Pos ->
    (let Cell (captures.make [] (symbols (mapcan (function item-uses) Items)))
         C [Name Buf End S Count Values Stack Scope Inner Cell]
      (seq C Items Pos -1 (/. P (done C P Sem Guard)))))

\\ The captures left for the end are built before the guard if it names them, and after it if not.
(define done
  C P Sem Guard ->
    (let Cell (cell C)
         Deferred (if (captures? Cell) (reverse (captures.deferred Cell)) [])
         Checked (if (= Guard grammar.none) [] (subst C Guard))
         Named (symbols Checked)
         Early (mapcan (/. D (if (element? (hd D) Named) [D] [])) Deferred)
         Late (mapcan (/. D (if (element? (hd D) Named) [] [D])) Deferred)
         Value (binds Late
                 (if (= Sem grammar.none)
                     (pos P)
                     [do [address-> (s C) 0 (subst C Sem)] (pos P)]))
      (binds Early (if (= Guard grammar.none) Value [if Checked Value -1]))))

(define cell
  [_ _ _ _ _ _ _ _ _ Cell | _] -> Cell)

(define binds
  [] Code -> Code
  [[V | E] | Rest] Code -> [let V E (binds Rest Code)])

(define seq
  _ [] Pos _ Done -> (Done Pos)
  C [X | Items] Pos Fail Done -> (terminals C (run [X | Items] []) Pos Fail Done)
    where (or (number? X) (string? X))
  C [X | Items] Pos Fail Done -> (item C X Items Pos Fail Done))

(define run
  [X | Items] Bytes -> (run Items (append Bytes (bytes X))) where (or (number? X) (string? X))
  Items Bytes -> (@p Bytes Items))

(define bytes
  N -> [N] where (and (integer? N) (>= N 0) (<= N 255))
  S -> (let B (shen-jit.string->bytes S) (byte-list B (shen-jit.bytes-length B) [])) where (string? S)
  X -> (error "defgrammar: ~S is not a byte or a string" X))

(define byte-list
  _ 0 Acc -> Acc
  B N Acc -> (byte-list B (- N 1) [(shen-jit.u8 B (- N 1)) | Acc]))

\\ One bounds check for a run of literal bytes, then a test of each.
(define terminals
  C (@p [] Items) Pos Fail Done -> (seq C Items Pos Fail Done)
  C (@p Bytes Items) [Var Off] Fail Done ->
    (let N (length Bytes)
      [if (conj [[< (pos [Var (+ Off (- N 1))]) (end C)]
                         | (compares C Bytes Var Off)])
          (seq C Items [Var (+ Off N)] Fail Done)
          Fail]))

(define compares
  _ [] _ _ -> []
  C [Byte | Bytes] Var Off -> [[= [shen-jit.u8 (buf C) (pos [Var Off])] Byte]
                               | (compares C Bytes Var (+ Off 1))])

(define conj
  [X] -> X
  [X | Xs] -> [and X (conj Xs)])

(define byte
  C Pos Fail Rest -> [if [< (pos Pos) (end C)] Rest Fail])

(define next
  [Var Off] -> [Var (+ Off 1)])

(define item
  C X Items Pos Fail Done ->
    (cases (wildcard? X) (byte C Pos Fail (seq C Items (next Pos) Fail Done))
           (variable? X)
             (byte C Pos Fail
               [let X [shen-jit.u8 (buf C) (pos Pos)]
                 (seq (bind C X) Items (next Pos) Fail Done)])
           (= X <e>) (seq C Items Pos Fail Done)
           (= X <end>) [if [< (pos Pos) (end C)] Fail (seq C Items Pos Fail Done)]
           (nonterminal? X)
             (let Class (trap-error (get X class) (/. E []))
               (if (empty? Class)
                   (call C X Pos Fail (/. P [<-address (s C) 0]) false Items Done)
                   (inline C X Items Pos Fail Done)))
           (cons? X) (form C X Items Pos Fail Done)
           true (error "defgrammar: ~R is not an item" X)))

(define inline
  C X Items Pos Fail Done ->
    (let B (gensym (protect B))
      (byte C Pos Fail
        [let B [shen-jit.u8 (buf C) (pos Pos)]
          [if (in-class X B) (seq C Items (next Pos) Fail Done) Fail]])))

\\ A class's test, as a form that the macro turns into its guard, or that a loop compiled at its
\\ first call turns into a lookup in a table of the 256 bytes.
(define in-class
  X B -> (let Class (get X class) [in-class X B (replace [[(hd Class) | B]] (hd (tl Class)))]))

\\ A loop over a byte class tests its first byte in place, and is called only if it matches.
(define class-of
  X -> (trap-error (get X class) (/. E [])) where (nonterminal? X)
  _ -> [])

(define class-test
  C X Pos ->
    (let B (gensym (protect B))
      [and [< (pos Pos) (end C)]
           [let B [shen-jit.u8 (buf C) (pos Pos)] (in-class X B)]]))

(define args
  C Pos -> [(buf C) (pos Pos) (end C) (s C)])

\\ Calls R, binds its value if the semantics name it, and goes on from where it stopped.
(define call
  C R Pos Fail Value Capture Items Done ->
    (after (invoke C R Pos) Fail
      (/. P (let Name (rule-name R)
                 Found (assoc Name (subst-values C))
                 Bind (and (cons? Found) (not (inner? C)))
                 Defer (and Bind Capture (defer C Name (tl Found) (Value P)))
                 Now (and Bind (not Defer))
                 Rest (seq (if Now (bind C (tl Found)) C) Items [P 0] Fail Done)
              (if Now [let (tl Found) (Value P) Rest] Rest)))))

\\ A capture that no later item names is left for the rule's end, so that a match that fails after
\\ it does not build it. A rule's own value must be read at once, before the next call replaces it.
(define defer
  C Name Var Code ->
    (let Cell (cell C)
      (if (and (captures? Cell) (not (element? Name (captures.used Cell))))
          (do (captures.deferred-> Cell [[Var | Code] | (captures.deferred Cell)]) true)
          false)))

(define subst-values
  [_ _ _ _ _ Values | _] -> Values)

\\ R's alternatives in place, when it is small, or a call to it. In place, its parameters are
\\ renamed and bound to the arguments, which are evaluated first.
(define invoke
  [Name Buf End S Count Values Stack Scope Inner _] R Pos ->
    (let Callee (rule-name R)
         Args (replace Values (rule-args R))
         Params (trap-error (get Callee params) (/. E Args))
         _ (if (= (length Params) (length Args)) skip
               (error "defgrammar ~A: ~A takes ~A arguments, not ~R" Name Callee (length Params) Args))
         Rules (trap-error (get Callee inline) (/. E []))
      (if (or (empty? Rules) (= Callee Name) (element? Callee Stack) (>= (length Stack) 3))
          (append [Callee Buf (pos Pos) End S] Args)
          (let Fresh (map (/. X (gensym (protect A))) Params)
            (lets Fresh Args
              (alternatives
                (map (/. Alt (rule [Name Buf End S Count (values Callee Alt) [Callee | Stack] Fresh false []]
                                           Alt Pos))
                     (replace (zip Params Fresh) Rules))))))))

(define zip
  [] [] -> []
  [X | Xs] [Y | Ys] -> [[X | Y] | (zip Xs Ys)])

(define lets
  [] [] Code -> Code
  [X | Xs] [E | Es] Code -> [let X E (lets Xs Es Code)])

\\ A call's result is a position, -1 or -2: -1 fails as this item fails, and -2 goes up as it is.
(define after
  Call Fail K ->
    (let P (gensym (protect P))
         Body (K P)
      (if (and (= Body P) (= Fail -1))
          Call
          [let P Call [if [< P 0] (if (= Fail -1) P [if [= P -1] Fail P]) Body]])))

(define form
  C [R | Args] Items Pos Fail Done ->
    (call C [R | Args] Pos Fail (/. P [<-address (s C) 0]) false Items Done)
    where (nonterminal? R)
  C [* X] Items Pos Fail Done ->
    (let Class (class-of X)
         Helper (loop C X)
         Loop (append [(hd Helper) | (args C [(pos Pos) (if (empty? Class) 0 1)])] (tl Helper))
      (if (empty? Class)
          (after Loop -1 (/. P (seq C Items [P 0] Fail Done)))
          (let P (gensym (protect P))
            [let P [if (class-test C X Pos) Loop (pos Pos)]
              (seq C Items [P 0] Fail Done)])))
  C [+ X] Items Pos Fail Done -> (seq C [X [* X] | Items] Pos Fail Done)
  C [? X] Items Pos Fail Done ->
    (let R (gensym (protect R))
         Inner (seq (inner C) [X] Pos -1 (function pos))
      (after [let R Inner [if [= R -1] (pos Pos) R]] -1
        (/. P (seq C Items [P 0] Fail Done))))
  C [text R] Items Pos Fail Done ->
    (call C R Pos Fail
      (/. P [shen-jit.bytes->string (buf C) (pos Pos) [- P (pos Pos)]]) true Items Done)
    where (rule-form? R)
  C [span R] Items Pos Fail Done ->
    (call C R Pos Fail (/. P [buffer.make (buf C) (pos Pos) P]) true Items Done)
    where (rule-form? R)
  C [require | Rest] Items Pos Fail Done ->
    (let Message (last Rest)
         Required (butlast Rest)
         _ (if (empty? (intersection (symbols Message) (bound Required)))
               skip
               (error "defgrammar: the message of ~R names what it requires" [require | Rest]))
      (seq C Required Pos [grammar.error (s C) (pos Pos) (subst C Message)]
        (/. P (seq C Items P Fail Done))))
    where (cons? Rest)
  C [where G] Items Pos Fail Done -> [if (subst C G) (seq C Items Pos Fail Done) Fail]
  C [at V] Items Pos Fail Done -> [let V (pos Pos) (seq (bind C V) Items Pos Fail Done)]
    where (variable? V)
  C [u16-be V] Items Pos Fail Done -> (fixed C V 2 Items Pos Fail Done) where (variable? V)
  C [u32-be V] Items Pos Fail Done -> (fixed C V 4 Items Pos Fail Done) where (variable? V)
  _ [F | Items] _ _ _ _ -> (error "defgrammar: (~A Item) takes one item: name a sequence as a rule, in ~R"
                                   F [F | Items]) where (element? F [* + ?])
  _ X _ _ _ _ -> (error "defgrammar: ~R is not an item" X))

\\ A big-endian unsigned field of N bytes, bound to V.
(define fixed
  C V N Items [Var Off] Fail Done ->
    [if [< (pos [Var (+ Off (- N 1))]) (end C)]
        [let V (big-endian C Var Off N 0)
          (seq (bind C V) Items [Var (+ Off N)] Fail Done)]
        Fail])

(define big-endian
  _ _ _ 0 Acc -> Acc
  C Var Off N Acc ->
    (big-endian C Var (+ Off 1) (- N 1)
      (let Byte [shen-jit.u8 (buf C) (pos [Var Off])]
        (if (= Acc 0) Byte [+ [shen-jit.shift-left Acc 8] Byte]))))

\\ (* X) as a function of its own: it stops where X no longer matches, or matches nothing. The
\\ macro runs as its file is read, before the file's own functions exist, and a definition
\\ compiled then would call them through fn; so it defines a stub, and the stub compiles the loop
\\ at its first call.
(define loop
  [Name Buf End S Count Values Stack Scope Inner _] X ->
    (let N (+ (<-address Count 0) 1)
         _ (address-> Count 0 N)
         H (intern (make-string "~A/~A" Name N))
         At (gensym (protect At))
         P (gensym (protect P))
         Body (seq [Name Buf End S Count Values Stack Scope true []] [X] [At 0] -1 (function pos))
         Free (unique (intersection (symbols Body) Scope) [])
         Params [Buf At End S | Free]
         _ (grammar.arity [H | (length Params)])
         _ (stub H (append [define H | Params]
                             [-> [let P Body [if [> P At] (append [H Buf P End S] Free) [if [= P -2] P At]]]]))
      [H | Free]))

(define list
  [] -> []
  [X | Xs] -> [cons X (list Xs)])

(define compile
  H Args -> (do (eval (tables (get H loop))) (apply (fn H) Args)))

(define apply
  F [] -> F
  F [X | Xs] -> (apply (F X) Xs))

\\ By a loop's first call, the functions a class's guard calls exist: a guard that depends only on
\\ its byte, as a class's must, is evaluated once for each byte. One that raises stays a test.
(define tables
  [in-class _ B Guard] ->
    (let Table (trap-error (fill (eval [/. B Guard]) (shen-jit.bytes 256) 0) (/. E none))
      (if (= Table none) Guard [= [shen-jit.u8 Table B] 1]))
  [X | Y] -> (map (function tables) [X | Y])
  X -> X)

(define fill
  _ Table 256 -> Table
  F Table B -> (fill F (if (F B) (shen-jit.u8! Table B 1) Table) (+ B 1)))

(defmacro macro
  [defgrammar Name | Body] -> (grammar.define Name [] Body) where (nonterminal? Name)
  [defgrammar [Name | Params] | Body] -> (grammar.define Name Params Body)
    where (and (nonterminal? Name) (every? (function variable?) Params))
  [defgrammar | Form] -> (error "defgrammar: expected <name> or (<name> Parameters...), and rules, in ~R" Form)
  [in-class _ _ Guard] -> Guard
  [parse Rule View Fail] -> (client Rule ".parse" [View Fail] (parse-form Rule View Fail))
    where (rule-form? Rule)
  [match? Rule View] -> (client Rule ".match?" [View] (match-form Rule View))
    where (rule-form? Rule)
  [parse-range Rule Buffer At End Fail] -> (range-form Rule Buffer At End Fail)
    where (rule-form? Rule)
  [read Rule Reader Fail] ->
    (let R (gensym (protect R))
      [let R Reader (client Rule ".read" [R [io.window-size R] Fail] (read-form Rule R [io.window-size R] Fail))])
    where (rule-form? Rule)
  [read-within Rule Reader Limit Fail] ->
    (client Rule ".read" [Reader Limit Fail] (read-form Rule Reader Limit Fail))
    where (rule-form? Rule))

(define read-form
  Rule Reader Limit Fail ->
    [read-from (rule-name Rule) (list (rule-args Rule)) Reader Limit Fail])

\\ Typed code calls a typed rule's own functions, which have types.
(define client
  Rule Suffix Rest Code ->
    (if (and (tc?) (cons? (sig-of (rule-name Rule))))
        (append [(client-name (rule-name Rule) Suffix) | (rule-args Rule)] Rest)
        Code))

\\ A call of a rule from outside a grammar: Rule is <rule>, or (<rule> Arguments...).
(define call-rule
  Rule Buf At End S -> (append [(rule-name Rule) Buf At End S] (rule-args Rule)))

\\ With the rule named, a parse calls it directly, and Fail is evaluated only when it fails.
(define parse-form
  Rule View Fail ->
    (let V (gensym (protect V)) S (gensym (protect S)) At (gensym (protect At)) End (gensym (protect End))
      [let V [buffer.check View] S [state] At [buffer.view.start V] End [buffer.view.end V]
        (finish (call-rule Rule [buffer.view.owner V] At End S) S At End Fail)]))

(define finish
  Call S At End Fail ->
    (let P (gensym (protect P))
      [let P Call [if [= P End] [<-address S 0] [failed P S At Fail]]]))

(define match-form
  Rule View ->
    (let V (gensym (protect V)) End (gensym (protect End))
      [let V [buffer.check View] End [buffer.view.end V]
        [= (call-rule Rule [buffer.view.owner V] [buffer.view.start V] End [state]) End]]))

(define range-form
  Rule Buffer At End Fail ->
    (let B (gensym (protect B)) A (gensym (protect A)) E (gensym (protect E)) S (gensym (protect S))
      [let B Buffer A At E End S [state]
        (finish (call-rule Rule B A E S) S A E Fail)]))

\\ Reading from an I/O reader as input arrives. A rule's streaming variant, <rule>/stream, is its
\\ code rewritten at the first streaming call: each bounds check compares with the end of what has
\\ arrived, kept in slot 0 of a stream record that the rule gets as its end, and fills the reader
\\ when it fails; calls go to streaming variants, and views of captures copy their bytes, as the
\\ reader's buffer is reused after the value. The parse reads in place, in the reader's buffer, and
\\ consumes the value's bytes only when it is complete. Load io.shen to use it.

(define read
  Rule Reader Fail -> (read-from Rule [] Reader (io.window-size Reader) Fail))

(define read-within
  Rule Reader Limit Fail -> (read-from Rule [] Reader Limit Fail))

\\ What a read of a typed rule gives typed code, Fail's result included.
(datatype grammar-read-results
  V : A;
  ========================================
  [ok V] : (read-result A);

  ________________________________________
  [eof] : (read-result A);

  Error : io.error;
  ========================================
  [error Error] : (read-result A);)

\\ The stream record: what has arrived, the reader, why there is no more, and the limit.
(define read-from
  Rule Args R Limit Fail ->
    (let G (prepare Rule)
         Storage (io.window R)
         Start (io.position R)
         Bound (io.min (buffer.index Limit) (io.window-size R))
         \\ What is already in the window counts against the bound too, as later fills do.
         E (address-> (address-> (address-> (address-> (absvector 4) 0 (io.min (io.window-fill R 0) Bound)) 1 R) 2 [])
                      3 Bound)
         S (state)
         P (apply (fn G) [Storage 0 E S | Args])
      (read-result P S E Start Fail)))

\\ A parse that read into the end of the input could have matched with more: at EOF, that is
\\ "input ended", whichever rule failed. One that did not is the grammar's own failure.
(define read-result
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
(define refill
  E X -> (let R (<-address E 1)
              Limit (<-address E 3)
              N (io.min (io.window-fill R (io.min (+ X 1) Limit)) Limit)
              _ (address-> E 0 N)
           (or (> N X)
               (do (address-> E 2 (if (>= X Limit) limit (io.reader.terminal R))) false))))

(define copy-span
  Buf At End -> (buffer.wrap (shen-jit.copy-bytes (shen-jit.bytes (- End At)) 0 Buf At (- End At))))

(define source
  F -> (let Code (trap-error (get F code) (/. E []))
         (if (empty? Code) (trap-error (get F loop) (/. E [])) Code)))

\\ F's streaming variant, defined as a stub that compiles it at its first call, again if F changed.
(define stream
  F -> (let G (intern (cn (str F) "/stream"))
            Def (source F)
            _ (if (empty? Def) (error "grammar: ~A is not a grammar rule" F) skip)
            _ (if (shen-jit.same? (trap-error (get G made-from) (/. E [])) Def)
                  skip
                  (let Params (parameters Def)
                       _ (shen.store-arity G (length Params))
                       _ (put G made-from Def)
                       _ (put G stream-of F)
                    (eval (append [define G | Params] [-> [compile-stream G F (list Params)]]))))
         G))

\\ Compiles F's streaming variant and every one it calls now, rather than at their first calls, so
\\ that the compiling happens before a parse, and outside any deadline. A variant compiled for
\\ the current definition is left as it is.
(define prepare
  F -> (let G (stream F)
         (if (shen-jit.same? (trap-error (get G compiled) (/. E [])) (source F))
             G
             (do (map (function prepare) (install G F)) G))))

(define parameters
  [define _ | Rest] -> (before (intern "->") Rest))

(define before
  X [X | _] -> []
  X [Y | Ys] -> [Y | (before X Ys)])

(define compile-stream
  G F Args -> (do (install G F) (apply (fn G) Args)))

\\ Defines G from F's code rewritten, and gives the rules whose streaming variants it calls.
(define install
  G F ->
    (let Def (source F)
         Params (parameters Def)
         Buf (hd Params)
         End (hd (tl (tl Params)))
         Code (rewrite Buf End (hd (tl (from (intern "->") Def))))
         _ (eval (tables (append [define G | Params] [-> Code])))
         _ (put G compiled Def)
      (unique (mapcan (/. X (let Of (trap-error (get X stream-of) (/. E []))
                                      (if (and (symbol? Of) (not (= X G))) [Of] [])))
                              (symbols Code))
                      [])))

(define from
  X [X | Rest] -> [X | Rest]
  X [_ | Rest] -> (from X Rest))

(define rewrite
  Buf End [< X End] -> (let Y (rewrite Buf End X) [or [< Y [<-address End 0]] [refill End Y]])
  Buf End [buffer.make Buf A Z] -> [copy-span Buf (rewrite Buf End A) (rewrite Buf End Z)]
  Buf End [F Buf A End S | Rest] ->
    [(stream F) Buf (rewrite Buf End A) End S | (map (/. X (rewrite Buf End X)) Rest)]
    where (and (symbol? F) (cons? (source F)))
  Buf End [X | Y] -> (map (/. Z (rewrite Buf End Z)) [X | Y])
  _ _ X -> X)

)

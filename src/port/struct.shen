\\ Fixed managed structs, expanded before ordinary macros. Fields are read-only unless mutable.
\\ The generated functions use one tagged absvector and constant slot numbers; no field registry
\\ is consulted by a constructor, reader or setter at run time. The private tag is the record's
\\ printer, which the kernel's writer calls: a default one, or (printer F) to call F on the record.
\\ Fields may have types, all or none: (x : number) or (mutable y : number). Under (tc +) the
\\ definitions are typed, over helpers with types only generated code may rely on; under (tc -)
\\ they are the plain ones, followed by declarations for typed clients. A typed struct may take
\\ type variables as parameters, (defstruct (cell A) (value : A)), and its type is then (cell A).
\\ A two-parameter declaration writes them as one product argument, (pair (A * B)).
\\ Anonymous fields, _ or (_ : T), are immutable and used as (:T E1 ... En). A layout has either
\\ named or anonymous fields. Both syntaxes rewrite to the positional internal
\\ constructor T.%make, which is never written by hand, and a pattern handler matches that.

(shen.x.namespace shen-jit.struct
  (use shen)
  (use shen-jit)
  (use struct)
  (externals [defstruct mutable printer make %make %match %struct-tag struct { } --> string boolean number symbol
    fixnum float])

(define initialise
  -> (do (shen.register-source-form defstruct (fn expand))
         (shen.register-source-form struct.union (fn expand-union))
         (shen.record-macro shen-jit.struct.make-macro (fn make-macro))
         (shen.x.namespaces.register-syntax defstruct (fn namespace-syntax))
         (shen.x.namespaces.register-syntax struct.make (fn namespace-syntax))
         (shen.x.namespaces.register-syntax (intern ":") (fn namespace-syntax))
         (shen.x.namespaces.register-definitions defstruct (fn introduced-names))
         (shen.x.namespaces.publish struct
           [[defstruct | defstruct]
            [make | struct.make]
            [union | struct.union]])
         (shen.initialise-arity-table [slot 2 slot! 3 ref 3 allocate 2 tagged 2 shown 2 pattern 4 record-reader 3
                                       record-constructor 1 constructor-rule-needed? 1])
         (shen.set-lambda-form-entry (shen.lambda-entry pattern))
         (shen.x.programmable-pattern-matching.register-handler pattern)
         (declare slot [(protect A) --> [number --> (protect B)]])
         (declare ref [(protect A) --> [number --> [number --> (protect B)]]])
         (declare slot! [(protect A) --> [number --> [(protect B) --> (protect A)]]])
         (declare allocate [number --> [symbol --> (protect A)]])
         (declare tagged [(protect A) --> [symbol --> boolean]])
         (declare record-reader [symbol --> [number --> [number --> symbol]]])
         (declare record-constructor [symbol --> symbol])
         (declare shown [(protect A) --> [string --> string]])))

\\ What typed definitions are made of. Each is one primitive, inlined wherever it is used.
(define slot
  Record I -> (<-address Record I))

(define slot!
  Record I Value -> (address-> Record I Value))

\\ Field I of a record of Size elements, its tag among them: tested as a vector at least Size long, so
\\ that the JIT knows a slot that passed holds every field.
(define ref
  Record I Size -> (shen-jit.struct-ref Record I Size))

(define allocate
  N Tag -> (address-> (absvector N) 0 Tag))

(define tagged
  Record Tag -> (shen-jit.tagged? Record Tag))

(define shown
  X Rest -> (shen.app X Rest shen.s))

(define shen-jit.struct.fail
  Name Message X -> (error "struct ~A: ~A: ~R" Name Message X))

(define name?
  X -> (and (symbol? X) (not (variable? X))))

(define syntax-value
  [protect X] -> (syntax-value X)
  X -> X)

\\ A field as written, with any protection around a whole descriptor taken off: a protected label
\\ stays protected, and so as written.
(define field-syntax
  [protect X] -> (field-syntax X) where (cons? X)
  X -> X)

\\ A label the namespace annotator protected is as written; any other loses what precedes its last
\\ dot, as the package form prefixes the labels in it.
(define local-label
  [protect X] -> X where (name? X)
  X -> (intern (local-text (str X) "")) where (name? X)
  X -> (shen-jit.struct.fail defstruct "expected a field name" X))

(define local-text
  "" Local -> Local
  (@s "." Rest) _ -> (local-text Rest "")
  (@s C Rest) Local -> (local-text Rest (cn Local C)))

(define marker
  [protect X] -> (marker X)
  X -> (local-label X) where (name? X)
  _ -> [])

(define colon?
  X -> (= (syntax-value X) (intern ":")))

(define fields
  _ _ [] _ -> []
  Name Params [[Marker Field Colon Type] | Rest] Seen -> (field Name Params Field true [Type] Rest Seen)
    where (and (= (marker Marker) mutable) (colon? Colon))
  Name Params [[Field Colon Type] | Rest] Seen -> (field Name Params Field false [Type] Rest Seen)
    where (colon? Colon)
  Name Params [[Marker Field] | Rest] Seen -> (field Name Params Field true [] Rest Seen)
    where (= (marker Marker) mutable)
  Name Params [[Marker _] | Rest] Seen -> (fields Name Params Rest Seen)
    where (= (marker Marker) printer)
  Name Params [Field | Rest] Seen -> (field Name Params Field false [] Rest Seen))

\\ [] for the default printer, or [F] for (printer F).
(define printer-option
  _ [] Found -> Found
  Name [[Marker F] | Rest] [] -> (printer-option Name Rest [F])
    where (= (marker Marker) printer)
  Name [[Marker _] | _] _ -> (shen-jit.struct.fail Name "more than one printer" Marker)
    where (= (marker Marker) printer)
  Name [_ | Rest] Found -> (printer-option Name Rest Found))

\\ A field is [Label Mutable Type]; an anonymous label is its one-based position. Type is []
\\ when the field has none and [T] when it has T. Positions make anonymous layouts stable on reload.
(define field
  Name Params Raw Mutable Type Rest Seen
  -> (let Written (local-label Raw)
          Label (if (= (str Written) "_") (+ 1 (length Seen)) Written)
       (cond ((and (number? Label) Mutable)
              (shen-jit.struct.fail Name "anonymous fields are immutable" Raw))
             ((and (cons? Seen) (not (= (number? Label) (number? (hd Seen)))))
              (shen-jit.struct.fail Name "fields must be all named or all anonymous" Raw))
             ((or (= Label make) (= (pos (str Label) 0) "%"))
              (shen-jit.struct.fail Name "reserved field name" Label))
             ((element? Label Seen)
              (shen-jit.struct.fail Name "duplicate field" Label))
             ((and (cons? Type) (not (empty? (difference (type-variables (hd Type)) Params))))
              (shen-jit.struct.fail Name "a field's type has a variable that is not a parameter" (hd Type)))
             (true
              [[Label Mutable Type] | (fields Name Params Rest [Label | Seen])]))))

(define type-variables
  [X | Y] -> (union (type-variables X) (type-variables Y))
  X -> [X] where (variable? X)
  _ -> [])

\\ A declaration's head: Name, or (Name P1 ... Pn) with distinct type variables as parameters.
(define head-name
  [Name | _] -> Name
  Name -> Name)

(define head-params
  [_ | Params] -> Params
  _ -> [])

(define head?
  [Name | Params] -> (and (name? Name) (cons? Params) (all? (fn variable?) Params) (distinct? Params))
  Name -> (name? Name))

\\ An arrow is [Input --> Output]. A product argument gives a two-parameter
\\ nominal type a different shape.
(define type-parameters
  _ [Name [A * B]] -> [A B] where (head? [Name A B])
  _ [Name A B] -> (shen-jit.struct.fail Name "use one product argument for two type parameters" [Name [A * B]])
    where (head? [Name A B])
  _ Head -> (head-params Head) where (head? Head)
  _ [Name | Params] -> (shen-jit.struct.fail Name "expected distinct type variables as parameters" Params)
    where (name? Name)
  Form Head -> (shen-jit.struct.fail Form "expected a literal type name" Head))

(define struct-type
  Name [] -> Name
  Name [A B] -> [Name [A * B]]
  Name Params -> [Name | Params])

\\ Whether the fields have types: all of them, or none. A struct with no fields has them all.
(define typed?
  Fields -> (all? (/. F (cons? (field-type-list F))) Fields))

(define field-type-list
  [_ _ Type] -> Type)

\\ Show a rejected layout as field declarations, including positional fields.
(define field-form
  [Label Mutable Type] ->
    (let Name (if (number? Label) (intern "_") Label)
         Entry (if Mutable [mutable Name] [Name])
      (cond ((cons? Type) (append Entry [(intern ":") | Type]))
            (Mutable Entry)
            (true Name))))

(define member
  Name Field -> (intern (cn (str Name) (cn "." (str Field)))))

(define reader-name
  Name Field -> (member Name (intern (cn "%field" (str Field)))) where (number? Field)
  Name Field -> (member Name Field))

(define anonymous?
  [[Label | _] | _] -> (number? Label)
  _ -> false)

(define predicate-name
  Name -> (intern (cn (str Name) "?")))

(define setter-name
  Name Field -> (intern (cn (str (member Name Field)) "->")))

\\ The public functions a declaration defines: all but the private tag's printer.
(define operations
  Name Fields -> (map (fn hd) (tl (functions Name [] Fields [] []))))

(define distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (distinct? Xs)))

(define describe
  Name Params Written
  -> (let Fields (fields Name Params (map (fn field-syntax) Written) [])
          Typed (typed? Fields)
       (cond ((and (not Typed) (not (all? (/. F (empty? (field-type-list F))) Fields)))
              (shen-jit.struct.fail Name "every field needs a type, or none" Written))
             ((and (cons? Params) (not Typed))
              (shen-jit.struct.fail Name "a struct with parameters needs field types" Params))
             ((distinct? (operations Name Fields)) Fields)
             (true (shen-jit.struct.fail Name "generated operation names collide" Written)))))

\\ [Tag Fields] for a struct without parameters, and [Tag Fields Params] for one with them.
(define schema
  Name -> (trap-error (get Name shen-jit.struct.schema) (/. E [])))

(define schema-params
  [_ _ Params] -> Params
  _ -> [])

(define check-operations
  _ [] -> true
  Name [F | Fs]
  -> (if (and (= (arity F) -1) (= (operation-of F Name) Name))
         (check-operations Name Fs)
         (shen-jit.struct.fail Name "operation is already defined" F)))

\\ The struct whose declaration generates F: declarations read together are all expanded before
\\ any is defined, so arity does not yet show another's.
(define operation-of
  F Name -> (trap-error (get F shen-jit.struct.operation-of) (/. E Name)))

(define register
  Name Params Fields
  -> (let Old (schema Name)
       (cond ((and (cons? Old) (= Fields (hd (tl Old))) (= Params (schema-params Old)))
              Old)
             ((cons? Old)
              (shen-jit.struct.fail Name "incompatible layout redefinition" (map (fn field-form) Fields)))
             (true
              (let Operations (operations Name Fields)
                   _ (check-operations Name Operations)
                   Tag (fresh-tag Name)
                   Description (if (empty? Params) [Tag Fields] [Tag Fields Params])
                (do (put Name shen-jit.struct.schema Description)
                    (put (member Name %make) shen-jit.struct.of Name)
                    (map (/. F (put F shen-jit.struct.operation-of Name)) Operations)
                    Description))))))

\\ Record each field's position after its reader is installed, tied to that procedure, and where typed
\\ code may keep its value. A later redefinition cannot inherit the unchecked read merely by keeping
\\ the reader's name.
(define positions
  _ [] _ -> []
  Name [Field | Fields] I
  -> [[record-reader (reader-name Name (hd Field)) I (register-kind (field-type Field))]
      | (positions Name Fields (+ I 1))])

\\ Where typed code may keep a field's value: 1 for a fixnum, in a word register, 2 for a float, in a
\\ float register, and 0 for anything else, in a slot. A number, as the call is code of the caller's.
(define register-kind
  Type -> (cond ((= Type fixnum) 1) ((= Type float) 2) (true 0)))

(define record-reader
  F I Kind -> (do (put F shen-jit.struct.field [(shen-jit.function F) | I])
                  (put F shen-jit.struct.field-kind [(shen-jit.function F) | Kind])
                  F))

\\ Each layout gets a fresh tag of its own, bound only to its printer. Re-reading it reuses the
\\ stored tag, including after an image reload. A public type or constructor name never becomes
\\ the record's printer.
(define fresh-tag
  Name -> (let Tag (gensym (member Name %struct-tag))
            (if (= (arity Tag) -1) Tag (fresh-tag Name))))

\\ A constructor's parameters are fixed names in their own definition, not captured expressions.
(define arguments
  0 _ -> []
  N I -> [(intern (cn "StructField" (str I))) | (arguments (- N 1) (+ I 1))])

\\ Each generated function is [F Type Args Body], with Body over the typed helpers. Under (tc +) it
\\ is defined with its type; otherwise each helper is replaced by its primitive, and a typed struct
\\ declares the types for typed clients.
(define functions
  Name Params Fields Printer Tag
  -> (let Args (arguments (length Fields) 1)
          Self (struct-type Name Params)
          Type (curried (map (fn field-type) Fields) Self)
          Make (stores [allocate (+ 1 (length Fields)) Tag] Args 1)
       [[Tag [Self --> string] [(protect Record)] (printer-body Name Fields Printer)]
        [(member Name make) Type Args Make]
        [(member Name %make) Type Args Make]
        [(predicate-name Name) [(protect A) --> boolean] [(protect Record)] [tagged (protect Record) Tag]]
        | (accessors Name Self Fields 1 (+ 1 (length Fields)))]))

(define field-type
  [_ _ [Type]] -> Type
  _ -> [])

\\ Each store returns the vector, so the constructor is one nested expression.
(define stores
  Vector [] _ -> Vector
  Vector [Arg | Args] I -> (stores [slot! Vector I Arg] Args (+ I 1)))

\\ The default printer shows the type and each field: #<point x: 1 y: 2>.
(define printer-body
  _ _ [F] -> [F (protect Record)]
  Name Fields [] -> [cn (cn "#<" (str Name)) (field-strings Fields 1)])

(define field-strings
  [] _ -> ">"
  [[Field | _] | Fields] I
  -> [cn " " [shown [slot (protect Record) I] (field-strings Fields (+ I 1))]]
    where (number? Field)
  [[Field | _] | Fields] I
  -> [cn (cn " " (cn (str Field) ": "))
         [shown [slot (protect Record) I] (field-strings Fields (+ I 1))]])

(define accessors
  _ _ [] _ _ -> []
  Name Self [Field | Fields] I Size
  -> (let Label (hd Field)
          Type (field-type Field)
          Rest (accessors Name Self Fields (+ I 1) Size)
          Read [(reader-name Name Label) [Self --> Type] [(protect Record)] [ref (protect Record) I Size]]
       (if (hd (tl Field))
           [Read [(setter-name Name Label) [Self --> [Type --> Self]] [(protect Record) (protect Value)]
                  [slot! (protect Record) I (protect Value)]]
            | Rest]
           [Read | Rest])))

(define typed
  [F Type Args Body] -> [define F { | (append Type [} | (append Args [-> Body])])])

(define plain
  [F _ Args Body] -> [define F | (append Args [-> (primitive Body)])])

(define declaration
  [F Type | _] -> [declare F (quoted Type)])

\\ shen.app has no type: typed code reaches it through shown.
(define primitive
  [allocate N Tag] -> [address-> [absvector N] 0 Tag]
  [shown X Rest] -> [shen.app (primitive X) (primitive Rest) shen.s]
  [X | Y] -> (map (fn primitive) [X | Y])
  slot -> <-address
  slot! -> address->
  ref -> shen-jit.struct-ref
  tagged -> shen-jit.tagged?
  X -> X)

\\ Remember the entry installed by the generated declaration. A later declaration
\\ for the same name installs a new entry, even when the function is unchanged.
(define record-constructor
  F -> (do (put F constructor-signature (assoc F (value shen.*sigf*))) F))

(define constructor-rule-needed?
  F -> (or (not (shen.type-theory-enabled?))
           (let Entry (assoc F (value shen.*sigf*))
             (or (empty? Entry)
                 (not (shen-jit.same? Entry (trap-error (get F constructor-signature) (/. E []))))))))

(define generate
  Name Params Fields Printer
  -> (let Typed (typed? Fields)
          Functions (functions Name Params Fields Printer (hd (schema Name)))
          Positions (positions Name Fields 1)
          Rules [[record-constructor (member Name %make)] (pattern-rule Name Params Fields)]
       (cond ((tc?) (append (map (fn typed) Functions) Positions Rules))
             (Typed (append (map (fn plain) Functions) (map (fn declaration) (tl Functions))
                            Positions Rules))
             (true (append (map (fn plain) Functions) Positions)))))

(define pattern-rule
  Name Params Fields
  -> [datatype (member Name %match) | (pattern-premises Name Fields (struct-type Name Params))])

\\ The constructor signature types the call, and membership widens its result.
\\ Only the introduction rule needs the guard. The left rule gives the fields
\\ their types whenever the pattern is among the hypotheses.
(define pattern-premises
  Name Fields Type
  -> (let Vars (map (/. F (gensym (protect StructField))) Fields)
          Constructor (member Name %make)
          Pattern [[Constructor | Vars] (intern ":") Type]
          Semicolon (intern ";")
       (append [if [constructor-rule-needed? Constructor]]
               (field-judgements Vars Fields Semicolon Semicolon)
               [(intern "_____")] Pattern [Semicolon]
               (pattern-left Vars Fields Pattern))))

(define pattern-left
  [] [] _ -> []
  Vars Fields Pattern
  -> (let Goal (gensym (protect Goal))
       (append (field-judgements Vars Fields (intern ",") (intern ">>"))
               [Goal (intern ";") (intern "_____")] Pattern [(intern ">>") Goal (intern ";")])))

(define field-judgements
  [] [] _ _ -> []
  [Var | Vars] [Field | Fields] Separator End
  -> [Var (intern ":") (field-type Field) (if (empty? Vars) End Separator)
      | (field-judgements Vars Fields Separator End)])

(define curried
  [] Result -> [--> Result]
  [T] Result -> [T --> Result]
  [T | Ts] Result -> [T --> (curried Ts Result)])

\\ A type as an expression that builds it: a variable is a symbol there.
(define quoted
  [] -> []
  [X | Y] -> [cons (quoted X) (quoted Y)]
  X -> [protect X] where (variable? X)
  X -> X)

\\ (struct.union Type S1 ... Sn): each typed struct Si is a Type, and its pattern matches a Type. A
\\ union stays open: another declaration can add structs to the same type later. A union with
\\ parameters, (struct.union (result (E * A)) (ok A) (err E)), gives each member the
\\ types it has in the union, which use only the union's parameters.
(define expand-union
  [struct.union Type | Members]
  -> (let Params (type-parameters struct.union Type)
       (mapcan (/. Member [(union-rules Type Params Member)]) Members))
  [struct.union | Args] -> (shen-jit.struct.fail struct.union "expected a type name" Args)
  Form -> (shen-jit.struct.fail struct.union "invalid declaration" Form))

\\ Unpack the product for field substitution. A unary member may itself
\\ take a product as its sole argument.
(define member-arguments
  [_ _] [_ [A * B]] -> [A B]
  [_ _] Member -> (shen-jit.struct.fail (head-name Member) "use one product argument for two parameters" Member)
  _ Member -> (head-params Member))

(define union-rules
  Type UnionParams Member
  -> (let Name (head-name Member)
          Schema (schema Name)
          Union (head-name Type)
          Fields (if (cons? Schema)
                     (hd (tl Schema))
                     (shen-jit.struct.fail Union "not a struct" Name))
          _ (if (typed? Fields) skip (shen-jit.struct.fail Union "a member needs field types" Name))
          Params (schema-params Schema)
          Args (member-arguments Params Member)
          _ (if (= (length Args) (length Params))
                skip
                (shen-jit.struct.fail Union "a member takes as many types as it has parameters" Member))
          _ (if (empty? (difference (type-variables Args) UnionParams))
                skip
                (shen-jit.struct.fail Union "a member's types use only the union's parameters" Member))
          Value (gensym (protect StructValue))
       [datatype (intern (cn (str Union) (cn ".%" (str Name))))
        Value (intern ":") (struct-type Name Args) (intern ";")
        (intern "_____") Value (intern ":") Type (intern ";")
        | (pattern-premises Name (instantiate (pairs Params Args) Fields) Type)]))

(define pairs
  [] [] -> []
  [X | Xs] [Y | Ys] -> [[X | Y] | (pairs Xs Ys)])

\\ X with each parameter replaced by its type, all at once.
(define instantiate
  Assoc [X | Y] -> [(instantiate Assoc X) | (instantiate Assoc Y)]
  Assoc X -> (let Entry (assoc X Assoc) (if (cons? Entry) (tl Entry) X)) where (variable? X)
  _ X -> X)

(define expand
  [defstruct Head | Written]
  -> (let Params (type-parameters defstruct Head)
          Name (head-name Head)
          Fields (describe Name Params Written)
          Printer (printer-option Name (map (fn syntax-value) Written) [])
          _ (if (and (tc?) (not (typed? Fields)))
                (shen-jit.struct.fail Name "under (tc +) every field needs a type; add them or load under (tc -)"
                                      (map (fn hd) Fields))
                skip)
          _ (register Name Params Fields)
       (generate Name Params Fields Printer))
  Form -> (shen-jit.struct.fail defstruct "invalid declaration" Form))

\\ (:T f <- V ...) and (struct.make T f <- V ...) become (T.%make V1 ... Vn), in declaration
\\ order: a pattern for the handler below, or a construction. Values that may have effects and are
\\ not already in declaration order are each bound first, in source order. With a final ..., the
\\ fields left out are fresh variables: wildcards in a pattern, and free variables, so an error, in an
\\ expression.
(define dots?
  X -> (= (syntax-value X) (intern "...")))

(define named-fields
  _ [] _ _ -> []
  _ [Dots] _ _ -> [] where (dots? Dots)
  Name [Raw Arrow Value | Rest] Fields Seen
  -> (let Args [Raw Arrow Value | Rest]
          Label (if (name? (syntax-value Raw)) (local-label Raw) Raw)
       (cond ((dots? Raw)
              (shen-jit.struct.fail Name "... comes after the last field" Raw))
             ((= (syntax-value Raw) (intern ";"))
              (shen-jit.struct.fail Name "fields are not separated by ;" Args))
             ((not (name? (syntax-value Raw)))
              (shen-jit.struct.fail Name "expected a field name" Raw))
             ((not (arrow? Arrow))
              (shen-jit.struct.fail Name "expected <- before a field value" Arrow))
             ((empty? (assoc Label Fields))
              (shen-jit.struct.fail Name "unknown field" Raw))
             ((element? Label Seen)
              (shen-jit.struct.fail Name "duplicate field" Raw))
             (true
              [[Label Value (gensym (protect StructValue))]
               | (named-fields Name Rest Fields [Label | Seen])])))
  Name Args _ _ -> (shen-jit.struct.fail Name "expected Field <- Value" Args))

(define partial?
  [Dots] -> true where (dots? Dots)
  [_ _ _ | Rest] -> (partial? Rest)
  _ -> false)

(define named-code
  Name Args Fields
  -> (let Named (named-fields Name Args Fields [])
          Partial (partial? Args)
          Make (member Name %make)
          Impure (impure Named)
       (if (in-order? (map (fn hd) Impure) (map (fn hd) Fields))
           [Make | (values Name Fields (map (fn written) Named) Partial)]
           (bind-values Impure [Make | (values Name Fields (map (fn written-or-bound) Named) Partial)]))))

\\ Whether Labels come in the order of Order, so that the call evaluates them as written. Then
\\ nothing is bound, and a pattern of another kind, which looks like a call, stays a pattern.
(define in-order?
  [] _ -> true
  [L | Ls] [L | Os] -> (in-order? Ls Os)
  Ls [_ | Os] -> (in-order? Ls Os)
  _ _ -> false)

\\ A value that may have effects is bound to its variable first, in source order; any other stays
\\ where it is, so a pattern, whose values are all pure, becomes the call itself.
(define impure
  [] -> []
  [N | Named] -> (impure Named) where (pure? (hd (tl N)))
  [N | Named] -> [N | (impure Named)])

(define written-or-bound
  [Label Value Variable] -> [Label (if (pure? Value) Value Variable)])

(define written
  [Label Value _] -> [Label Value])

(define values
  _ [] _ _ -> []
  Name [[Field | _] | Fields] Named Partial
  -> [(let Entry (assoc Field Named)
        (cond ((cons? Entry) (hd (tl Entry)))
              (Partial (left-out Field))
              (true (shen-jit.struct.fail Name "missing field" Field))))
      | (values Name Fields Named Partial)])

\\ A fresh variable for a field ... leaves out, marked so the handler knows it from one written.
(define left-out
  Field -> (let Variable (gensym (intern (cn "Missing-" (str Field))))
             (do (put Variable shen-jit.struct.left-out true) Variable)))

\\ Not every?, which a host with the standard library, as Shen/Scheme, knows as a system function:
\\ this namespace would leave that name unqualified there, and the generated files would differ.
(define all?
  _ [] -> true
  F [X | Xs] -> (and (F X) (all? F Xs)))

\\ What cannot have effects, so its order does not matter: what patterns are made of.
(define pure?
  [protect X] -> (pure? X)
  [vector 0] -> true
  [C A B] -> (and (pure? A) (pure? B)) where (element? C [cons @p @s @v])
  [Make | Args] -> (all? (fn pure?) Args)
    where (constructor? Make)
  [_ | _] -> false
  _ -> true)

\\ The struct whose internal constructor T.%make is, or [].
(define struct-of
  Make -> (trap-error (get Make shen-jit.struct.of) (/. E [])))

(define constructor?
  Make -> (symbol? (struct-of Make)))

(define arrow?
  X -> (= X (intern "<-")))

(define struct-syntax?
  X -> (or (= X struct.make) (= X (intern ":"))))


(define bind-values
  [] Call -> Call
  [[_ Value Variable] | Named] Call -> [let Variable Value (bind-values Named Call)])

(define make-macro
  [Head Name | Args]
  -> (let Schema (schema Name)
       (if (cons? Schema) (construction Name Args (hd (tl Schema)))
           (error "unknown struct type: ~R" Name)))
    where (struct-syntax? Head)
  [struct.make | Args] -> (error "struct.make expects a struct type: ~R" Args)
  Form -> Form)

(define construction
  Name Args Fields
  -> (cond ((not (all? (/. Arg (not (or (dots? Arg) (arrow? Arg)))) Args))
             (shen-jit.struct.fail Name "anonymous fields require positional values" Args))
           ((not (= (length Args) (length Fields)))
             (shen-jit.struct.fail Name "expected one value per anonymous field" Args))
           (true [(member Name %make) | Args]))
    where (anonymous? Fields)
  Name Args Fields -> (named-code Name Args Fields))

\\ Whether a (: ...) form is written as struct syntax: other uses of : are left alone.
(define labels?
  [] -> true
  [Dots] -> true where (dots? Dots)
  [_ Arrow _ | Rest] -> (labels? Rest) where (arrow? Arrow)
  _ -> false)

\\ The pattern handler: (T.%make P1 ... Pn) tests T? and binds each Pi to its field. A fresh
\\ variable for a field left out by ... is not read.
(define pattern
  Self AddTest Bind [Make | Ps]
  -> (let Name (struct-of Make)
          Fields (hd (tl (schema Name)))
       (if (= (length Ps) (length Fields))
           (do (AddTest [(predicate-name Name) Self])
               (bind-fields Self Bind Name Fields Ps))
           (fail)))
    where (constructor? Make)
  _ _ _ _ -> (fail))

(define bind-fields
  _ _ _ [] [] -> handled
  Self Bind Name [[Field | _] | Fields] [P | Ps]
  -> (do (if (missing? P) skip (Bind P [(reader-name Name Field) Self]))
         (bind-fields Self Bind Name Fields Ps)))

(define missing?
  X -> (and (variable? X) (trap-error (get X shen-jit.struct.left-out) (/. E false))))

\\ One annotation per syntax head, independent of any particular struct's schema.
(define namespace-syntax
  [defstruct Name | Written] -> [defstruct Name | (map (fn protect-field) Written)]
  [struct.make Name | Args] -> [struct.make Name | (protect-labels Args)] where (labels? Args)
  [Colon Name | Args] -> [Colon Name | (protect-labels Args)]
    where (and (= Colon (intern ":")) (labels? Args))
  Form -> Form)

\\ A printer's function and a field's type resolve in the caller's scope like any other reference.
(define protect-field
  [protect X] -> [protect X]
  [Marker F] -> [[protect Marker] F] where (= (marker Marker) printer)
  [Marker Field Colon Type] -> [[protect Marker] [protect Field] [protect Colon] Type]
    where (and (= (marker Marker) mutable) (= Colon (intern ":")))
  [Marker Field] -> [[protect Marker] [protect Field]] where (= (marker Marker) mutable)
  [Field Colon Type] -> [[protect Field] [protect Colon] Type] where (= Colon (intern ":"))
  Field -> [protect Field])

(define protect-labels
  [] -> []
  [Dots] -> [[protect Dots]] where (= Dots (intern "..."))
  [Field Arrow Value | Rest]
  -> [[protect Field] Arrow Value | (protect-labels Rest)] where (arrow? Arrow)
  Args -> (error "expected Field <- Value: ~R" Args))

\\ Enumerate bindings without expanding the declaration or installing its schema. Only a namespace
\\ asks, so the labels are protected, as written, whether or not the annotator has done it yet.
(define introduced-names
  [defstruct Head | Written]
  -> (let Params (type-parameters defstruct Head)
          Name (head-name Head)
       [Name | (operations Name (describe Name Params (map (fn protect-field) Written)))])
  Form -> (shen-jit.struct.fail defstruct "invalid declaration" Form))

)

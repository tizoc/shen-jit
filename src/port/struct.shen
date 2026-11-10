\\ Fixed managed structs, expanded before ordinary macros. Fields are read-only unless mutable.
\\ The generated functions use one tagged absvector and constant slot numbers; no field registry
\\ is consulted by a constructor, reader or setter at run time. The private tag is the record's
\\ printer, which the kernel's writer calls: a default one, or (printer F) to call F on the record.
\\ Fields may have types, all or none: (x : number) or (mutable y : number). Under (tc +) the
\\ definitions are typed, over helpers with types only generated code may rely on; under (tc -)
\\ they are the plain ones, followed by declarations for typed clients.
\\ (:T f <- E ...) constructs and matches: the macro rewrites it to the positional internal
\\ constructor T.%make, which is never written by hand, and a pattern handler matches that.

(package shen-jit.struct
  [defstruct mutable printer make %make %match %struct-tag struct struct.make shen-jit.tagged? shen.app shen.s
   { } --> string boolean number symbol]

(define initialise
  -> (do (shen.register-source-form defstruct (fn expand))
         (shen.record-macro shen-jit.struct.make-macro (fn make-macro))
         (shen.x.namespaces.register-syntax defstruct (fn namespace-syntax))
         (shen.x.namespaces.register-syntax struct.make (fn namespace-syntax))
         (shen.x.namespaces.register-syntax (intern ":") (fn namespace-syntax))
         (shen.x.namespaces.register-definitions defstruct (fn introduced-names))
         (shen.x.namespaces.publish struct
           [[defstruct | defstruct]
            [make | struct.make]])
         (shen.initialise-arity-table [slot 2 slot! 3 allocate 2 tagged 2 shown 2 pattern 4])
         (shen.set-lambda-form-entry (shen.lambda-entry pattern))
         (shen.x.programmable-pattern-matching.register-handler pattern)
         (declare slot [(protect A) --> [number --> (protect B)]])
         (declare slot! [(protect A) --> [number --> [(protect B) --> (protect A)]]])
         (declare allocate [number --> [symbol --> (protect A)]])
         (declare tagged [(protect A) --> [symbol --> boolean]])
         (declare shown [(protect A) --> [string --> string]])))

\\ What typed definitions are made of. Each is one primitive, inlined wherever it is used.
(define slot
  Record I -> (<-address Record I))

(define slot!
  Record I Value -> (address-> Record I Value))

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

(define local-label
  [protect X] -> (local-label X)
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
  _ [] _ -> []
  Name [[Marker Field Colon Type] | Rest] Seen -> (field Name Field true [Type] Rest Seen)
    where (and (= (marker Marker) mutable) (colon? Colon))
  Name [[Field Colon Type] | Rest] Seen -> (field Name Field false [Type] Rest Seen)
    where (colon? Colon)
  Name [[Marker Field] | Rest] Seen -> (field Name Field true [] Rest Seen)
    where (= (marker Marker) mutable)
  Name [[Marker _] | Rest] Seen -> (fields Name Rest Seen)
    where (= (marker Marker) printer)
  Name [Field | Rest] Seen -> (field Name Field false [] Rest Seen))

\\ [] for the default printer, or [F] for (printer F).
(define printer-option
  _ [] Found -> Found
  Name [[Marker F] | Rest] [] -> (printer-option Name Rest [F])
    where (= (marker Marker) printer)
  Name [[Marker _] | _] _ -> (shen-jit.struct.fail Name "more than one printer" Marker)
    where (= (marker Marker) printer)
  Name [_ | Rest] Found -> (printer-option Name Rest Found))

\\ A field is [Label Mutable Type], with Type [] when the field has none and [T] when it has T.
(define field
  Name Raw Mutable Type Rest Seen
  -> (let Label (local-label Raw)
       (cond ((or (= Label make) (= (pos (str Label) 0) "%"))
              (shen-jit.struct.fail Name "reserved field name" Label))
             ((element? Label Seen)
              (shen-jit.struct.fail Name "duplicate field" Label))
             ((and (cons? Type) (not (closed? (hd Type))))
              (shen-jit.struct.fail Name "a field's type has no variables" (hd Type)))
             (true
              [[Label Mutable Type] | (fields Name Rest [Label | Seen])]))))

(define closed?
  [X | Y] -> (and (closed? X) (closed? Y))
  X -> (not (variable? X)))

\\ Whether the fields have types: all of them, or none. A struct with no fields has them all.
(define typed?
  Fields -> (let Types (map (/. F (hd (tl (tl F)))) Fields)
              (cond ((not (element? [] Types)) true)
                    ((every? (fn empty?) Types) false)
                    (true (shen-jit.struct.fail defstruct "every field needs a type, or none" Fields)))))

(define member
  Name Field -> (intern (cn (str Name) (cn "." (str Field)))))

(define predicate-name
  Name -> (intern (cn (str Name) "?")))

(define setter-name
  Name Field -> (intern (cn (str (member Name Field)) "->")))

\\ The public functions a declaration defines: all but the private tag's printer.
(define operations
  Name Fields -> (map (fn hd) (tl (functions Name Fields [] []))))

(define distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (distinct? Xs)))

(define describe
  Name Written
  -> (let Fields (fields Name (map (fn syntax-value) Written) [])
          Typed (typed? Fields)
       (if (distinct? (operations Name Fields))
           Fields
           (shen-jit.struct.fail Name "generated operation names collide" Written)))
    where (name? Name)
  Name _ -> (shen-jit.struct.fail defstruct "expected a literal struct name" Name))

(define schema
  Name -> (trap-error (get Name shen-jit.struct.schema) (/. E [])))

(define check-operations
  _ [] -> true
  Name [F | Fs]
  -> (if (= (arity F) -1)
         (check-operations Name Fs)
         (shen-jit.struct.fail Name "operation is already defined" F)))

(define register
  Name Fields
  -> (let Old (schema Name)
       (cond ((and (cons? Old) (= Fields (hd (tl Old))))
              Old)
             ((cons? Old)
              (shen-jit.struct.fail Name "incompatible layout redefinition" Fields))
             (true
              (let _ (check-operations Name (operations Name Fields))
                   Tag (fresh-tag Name)
                   Description [Tag Fields]
                (do (put Name shen-jit.struct.schema Description)
                    (put (member Name %make) shen-jit.struct.of Name)
                    Description))))))

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
  Name Fields Printer Tag
  -> (let Args (arguments (length Fields) 1)
          Type (curried (map (fn field-type) Fields) Name)
          Make (stores [allocate (+ 1 (length Fields)) Tag] Args 1)
       [[Tag [Name --> string] [(protect Record)] (printer-body Name Fields Printer)]
        [(member Name make) Type Args Make]
        [(member Name %make) Type Args Make]
        [(predicate-name Name) [(protect A) --> boolean] [(protect Record)] [tagged (protect Record) Tag]]
        | (accessors Name Fields 1)]))

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
  -> [cn (cn " " (cn (str Field) ": "))
         [shown [slot (protect Record) I] (field-strings Fields (+ I 1))]])

(define accessors
  _ [] _ -> []
  Name [Field | Fields] I
  -> (let Label (hd Field)
          Type (field-type Field)
          Rest (accessors Name Fields (+ I 1))
          Read [(member Name Label) [Name --> Type] [(protect Record)] [slot (protect Record) I]]
       (if (hd (tl Field))
           [Read [(setter-name Name Label) [Name --> [Type --> Name]] [(protect Record) (protect Value)]
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
  tagged -> shen-jit.tagged?
  X -> X)

(define generate
  Name Fields Printer
  -> (let Typed (typed? Fields)
          Functions (functions Name Fields Printer (hd (schema Name)))
       (cond ((and (tc?) Typed) (append (map (fn typed) Functions) [(pattern-rule Name Fields)]))
             ((tc?)
              (shen-jit.struct.fail Name "under (tc +) every field needs a type; add them or load under (tc -)"
                                    (map (fn hd) Fields)))
             (Typed (append (map (fn plain) Functions) (map (fn declaration) (tl Functions))
                            [(pattern-rule Name Fields)]))
             (true (map (fn plain) Functions)))))

\\ How the typechecker reads a pattern: (T.%make X Y) : T when X and Y have the fields' types.
(define pattern-rule
  Name Fields
  -> (let Vars (arguments (length Fields) 1)
       [datatype (member Name %match)
        | (append (premises Vars Fields)
                  [(if (empty? Fields) (intern "_____") (intern "====="))
                   [(member Name %make) | Vars] (intern ":") Name (intern ";")])]))

(define premises
  [] [] -> []
  [Var | Vars] [Field | Fields]
  -> [Var (intern ":") (field-type Field) (intern ";") | (premises Vars Fields)])

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

(define expand
  [defstruct Name | Written]
  -> (let Fields (describe Name Written)
          Printer (printer-option Name (map (fn syntax-value) Written) [])
          _ (register Name Fields)
       (generate Name Fields Printer))
  Form -> (shen-jit.struct.fail defstruct "invalid declaration" Form))

\\ (:T f <- V ...) and (struct.make T f <- V ...) become (T.%make V1 ... Vn), in declaration
\\ order: a pattern for the handler below, or a construction. When a value may have effects, each
\\ is bound first, in source order. With a final ..., the fields left out are fresh variables:
\\ wildcards in a pattern, and free variables, so an error, in an expression.
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
  [] -> false
  [Dots] -> true where (dots? Dots)
  [_ | Rest] -> (partial? Rest))

(define named-code
  Name Args Fields
  -> (let Named (named-fields Name Args Fields [])
          Partial (partial? Args)
          Make (member Name %make)
       (bind-values (impure Named)
         [Make | (values Name Fields (map (fn written-or-bound) Named) Partial)])))

\\ A value that may have effects is bound to its variable first, in source order; any other stays
\\ where it is, so a pattern, whose values are all pure, becomes the call itself.
(define impure
  [] -> []
  [N | Named] -> (impure Named) where (pure? (hd (tl N)))
  [N | Named] -> [N | (impure Named)])

(define written-or-bound
  [Label Value Variable] -> [Label (if (pure? Value) Value Variable)])

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

(define every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (every? F Xs)))

\\ What cannot have effects, so its order does not matter: what patterns are made of.
(define pure?
  [protect _] -> true
  [vector 0] -> true
  [C A B] -> (and (pure? A) (pure? B)) where (element? C [cons @p @s @v])
  [Make | Args] -> (every? (fn pure?) Args)
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
       (cond ((cons? Schema) (named-code Name Args (hd (tl Schema))))
             ((or (= Head struct.make) (labels? Args))
              (shen-jit.struct.fail struct.make "unknown struct type" Name))
             (true [Head Name | Args])))
    where (struct-syntax? Head)
  [struct.make | Args] -> (shen-jit.struct.fail struct.make "expected a struct type" Args)
  Form -> Form)

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
  -> (do (if (missing? P) skip (Bind P [(member Name Field) Self]))
         (bind-fields Self Bind Name Fields Ps)))

(define missing?
  X -> (and (variable? X) (trap-error (get X shen-jit.struct.left-out) (/. E false))))

\\ One annotation per syntax head, independent of any particular struct's schema.
(define namespace-syntax
  [defstruct Name | Written] -> [defstruct Name | (map (fn protect-field) Written)]
  [struct.make Name | Args] -> [struct.make Name | (protect-labels Args)]
  [Colon Name | Args] -> [Colon Name | (protect-labels Args)]
    where (and (= Colon (intern ":")) (labels? Args))
  Form -> Form)

\\ A printer's function and a field's type resolve in the caller's scope like any other reference.
(define protect-field
  [Marker F] -> [[protect Marker] F] where (= (marker Marker) printer)
  [Marker Field Colon Type] -> [[protect Marker] [protect Field] [protect Colon] Type]
    where (and (= (marker Marker) mutable) (= Colon (intern ":")))
  [Field Colon Type] -> [[protect Field] [protect Colon] Type] where (= Colon (intern ":"))
  Field -> [protect Field])

(define protect-labels
  [] -> []
  [Dots] -> [[protect Dots]] where (= Dots (intern "..."))
  [Field Arrow Value | Rest]
  -> [[protect Field] Arrow Value | (protect-labels Rest)] where (arrow? Arrow)
  Args -> (shen-jit.struct.fail struct.make "expected Field <- Value" Args))

\\ Enumerate bindings without expanding the declaration or installing its schema.
(define introduced-names
  [defstruct Name | Written]
  -> [Name | (operations Name (describe Name Written))]
  Form -> (shen-jit.struct.fail defstruct "invalid declaration" Form))

)

\\ Fixed managed structs, expanded before ordinary macros. Fields are read-only unless mutable.
\\ The generated functions use one tagged absvector and constant slot numbers; no field registry
\\ is consulted by a constructor, reader or setter at run time. The private tag is the record's
\\ printer, which the kernel's writer calls: a default one, or (printer F) to call F on the record.
\\ Fields may have types, all or none: (x : number) or (mutable y : number). Under (tc +) the
\\ definitions are typed, over helpers with types only generated code may rely on; under (tc -)
\\ they are the plain ones, followed by declarations for typed clients.

(package shen-jit.struct
  [defstruct mutable printer make %struct-tag struct struct.make shen-jit.tagged? shen.app shen.s
   { } --> string boolean number symbol]

(define initialise
  -> (do (shen.register-source-form defstruct (fn expand))
         (shen.record-macro shen-jit.struct.make-macro (fn make-macro))
         (shen.x.namespaces.register-syntax defstruct (fn namespace-syntax))
         (shen.x.namespaces.register-syntax struct.make (fn namespace-syntax))
         (shen.x.namespaces.register-definitions defstruct (fn introduced-names))
         (shen.x.namespaces.publish struct
           [[defstruct | defstruct]
            [make | struct.make]])
         (shen.initialise-arity-table [slot 2 slot! 3 allocate 2 tagged 2 shown 2])
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

(define typed?
  Fields -> (cons? Fields) where (every-typed? Fields)
  Fields -> false where (none-typed? Fields)
  Fields -> (shen-jit.struct.fail defstruct "every field needs a type, or none" Fields))

(define every-typed?
  [] -> true
  [[_ _ [_]] | Fields] -> (every-typed? Fields)
  _ -> false)

(define none-typed?
  [] -> true
  [[_ _ []] | Fields] -> (none-typed? Fields)
  _ -> false)

(define member
  Name Field -> (intern (cn (str Name) (cn "." (str Field)))))

(define predicate-name
  Name -> (intern (cn (str Name) "?")))

(define setter-name
  Name Field -> (intern (cn (str (member Name Field)) "->")))

(define operations
  Name Fields -> [(member Name make) (predicate-name Name) | (field-operations Name Fields)])

(define field-operations
  _ [] -> []
  Name [[Field Mutable _] | Fields]
  -> (append (if Mutable
                 [(member Name Field) (setter-name Name Field)]
                 [(member Name Field)])
             (field-operations Name Fields)))

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

\\ Each store returns the vector, so the constructor is one nested expression of primitives.
(define stores
  Vector [] _ -> Vector
  Vector [Arg | Args] I -> (stores [address-> Vector I Arg] Args (+ I 1)))

(define definition
  Name Args Body -> [define Name | (append Args [-> Body])])

(define generate
  Name Fields Printer
  -> (cond ((and (tc?) (or (empty? Fields) (typed? Fields))) (typed-definitions Name Fields Printer))
           ((tc?)
            (shen-jit.struct.fail Name "under (tc +) every field needs a type; add them or load under (tc -)"
                                  (map (fn hd) Fields)))
           ((typed? Fields) (append (definitions Name Fields Printer) (declarations Name Fields)))
           (true (definitions Name Fields Printer))))

(define definitions
  Name Fields Printer
  -> (let Tag (hd (schema Name))
          Args (arguments (length Fields) 1)
       [(definition Tag [(protect Record)] (printer-body Name Fields Printer <-address))
        (definition
          (member Name make)
          Args
          (stores [address-> [absvector (+ 1 (length Fields))] 0 Tag] Args 1))
        (definition
          (predicate-name Name)
          [(protect Record)]
          [shen-jit.tagged? (protect Record) Tag])
        | (accessors Name Fields 1)]))

\\ The default printer shows the type and each field: #<point x: 1 y: 2>.
(define printer-body
  _ _ [F] _ -> [F (protect Record)]
  Name Fields [] Read -> [cn (cn "#<" (str Name)) (field-strings Fields 1 Read)])

(define field-strings
  [] _ _ -> ">"
  [[Field | _] | Fields] I Read
  -> [cn (cn " " (cn (str Field) ": "))
         (show Read [Read (protect Record) I] (field-strings Fields (+ I 1) Read))])

\\ shen.app has no type; typed code reaches it through shown.
(define show
  <-address Value Rest -> [shen.app Value Rest shen.s]
  _ Value Rest -> [shown Value Rest])

(define accessors
  _ [] _ -> []
  Name [[Field Mutable _] | Fields] I
  -> [(definition
        (member Name Field)
        [(protect Record)]
        [<-address (protect Record) I])
      | (append
          (if Mutable
              [(definition
                 (setter-name Name Field)
                 [(protect Record) (protect Value)]
                 [address-> (protect Record) I (protect Value)])]
              [])
          (accessors Name Fields (+ I 1)))])

\\ Typed definitions, for (tc +): the same code over the typed helpers.
(define typed-definition
  Name Signature Args Body -> [define Name { | (append Signature [} | (append Args [-> Body])])])

(define typed-definitions
  Name Fields Printer
  -> (let Tag (hd (schema Name))
          Args (arguments (length Fields) 1)
          Types (map (/. F (hd (hd (tl (tl F))))) Fields)
       [(typed-definition Tag [Name --> string] [(protect Record)]
          (printer-body Name Fields Printer slot))
        (typed-definition (member Name make) (signature Types Name) Args
          (typed-stores [allocate (+ 1 (length Fields)) Tag] Args 1))
        (typed-definition (predicate-name Name) [(protect A) --> boolean] [(protect Record)]
          [tagged (protect Record) Tag])
        | (typed-accessors Name Fields 1)]))

(define signature
  [] Result -> [--> Result]
  Types Result -> (append (intersperse Types) [--> Result]))

(define intersperse
  [T] -> [T]
  [T | Ts] -> [T --> | (intersperse Ts)])

(define typed-stores
  Vector [] _ -> Vector
  Vector [Arg | Args] I -> (typed-stores [slot! Vector I Arg] Args (+ I 1)))

(define typed-accessors
  _ [] _ -> []
  Name [[Field Mutable [Type]] | Fields] I
  -> [(typed-definition (member Name Field) [Name --> Type] [(protect Record)]
        [slot (protect Record) I])
      | (append
          (if Mutable
              [(typed-definition (setter-name Name Field) [Name --> Type --> Name]
                 [(protect Record) (protect Value)]
                 [slot! (protect Record) I (protect Value)])]
              [])
          (typed-accessors Name Fields (+ I 1)))])

\\ Under (tc -), declarations let typed clients use a typed struct.
(define declarations
  Name Fields
  -> (let Types (map (/. F (hd (hd (tl (tl F))))) Fields)
       [[declare (member Name make) (quoted (curried Types Name))]
        [declare (predicate-name Name) (quoted [(protect A) --> boolean])]
        | (field-declarations Name Fields)]))

(define field-declarations
  _ [] -> []
  Name [[Field Mutable [Type]] | Fields]
  -> (append [[declare (member Name Field) (quoted [Name --> Type])]]
             (if Mutable
                 [[declare (setter-name Name Field) (quoted [Name --> [Type --> Name]])]]
                 [])
             (field-declarations Name Fields)))

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

\\ Labelled construction preserves source evaluation order, then calls the ordinary .make.
(define named-fields
  _ [] _ _ -> []
  Name [Raw Arrow Value End | Rest] Fields Seen
  -> (let Label (local-label Raw)
       (cond ((not (= Arrow (intern "<-")))
              (shen-jit.struct.fail Name "expected <- before a field value" Arrow))
             ((not (= End (intern ";")))
              (shen-jit.struct.fail Name "expected ; after a field value" End))
             ((empty? (assoc Label Fields))
              (shen-jit.struct.fail Name "unknown field" Raw))
             ((element? Label Seen)
              (shen-jit.struct.fail Name "duplicate field" Raw))
             (true
              [[Label Value (gensym (protect StructValue))]
               | (named-fields Name Rest Fields [Label | Seen])])))
  Name Args _ _ -> (shen-jit.struct.fail Name "expected Field <- Expression;" Args))

(define named-code
  Name Args Fields
  -> (let Named (named-fields Name Args Fields [])
       (if (= (length Named) (length Fields))
           (bind-values Named [(member Name make) | (ordered-values Fields Named)])
           (shen-jit.struct.fail Name "missing fields" Args))))

(define ordered-values
  [] _ -> []
  [[Field | _] | Fields] Named
  -> [(hd (tl (tl (assoc Field Named)))) | (ordered-values Fields Named)])

(define bind-values
  [] Call -> Call
  [[_ Value Variable] | Named] Call -> [let Variable Value (bind-values Named Call)])

(define make-macro
  [struct.make Name | Args]
  -> (let Schema (if (name? Name) (schema Name) [])
       (if (cons? Schema)
           (named-code Name Args (hd (tl Schema)))
           (shen-jit.struct.fail struct.make "unknown struct type" Name)))
  [struct.make | Args] -> (shen-jit.struct.fail struct.make "expected a struct type" Args)
  Form -> Form)

\\ One annotation per syntax head, independent of any particular struct's schema.
(define namespace-syntax
  [defstruct Name | Written] -> [defstruct Name | (map (fn protect-field) Written)]
  [struct.make Name | Args] -> [struct.make Name | (protect-labels Args)]
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
  [Field Arrow Expression End | Rest]
  -> [[protect Field] Arrow Expression End | (protect-labels Rest)]
    where (and (= Arrow (intern "<-")) (= End (intern ";")))
  Args -> (shen-jit.struct.fail struct.make "expected Field <- Expression;" Args))

\\ Enumerate bindings without expanding the declaration or installing its schema.
(define introduced-names
  [defstruct Name | Written]
  -> [Name | (operations Name (describe Name Written))]
  Form -> (shen-jit.struct.fail defstruct "invalid declaration" Form))

)

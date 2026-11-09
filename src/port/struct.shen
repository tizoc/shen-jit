\\ Fixed managed structs, expanded before ordinary macros. Fields are read-only unless mutable.
\\ The generated functions use one tagged absvector and constant slot numbers; no field registry
\\ is consulted by a constructor, reader or setter at run time.

(package shen-jit.struct
  [defstruct mutable make %struct-tag struct struct.make shen-jit.tagged?]

(define initialise
  -> (do (shen.register-source-form defstruct (fn expand))
         (shen.record-macro shen-jit.struct.make-macro (fn make-macro))
         (shen.x.namespaces.register-syntax defstruct (fn namespace-syntax))
         (shen.x.namespaces.register-syntax struct.make (fn namespace-syntax))
         (shen.x.namespaces.register-definitions defstruct (fn introduced-names))
         (shen.x.namespaces.publish struct
           [[defstruct | defstruct]
            [make | struct.make]])))

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

(define fields
  _ [] _ -> []
  Name [[Marker Field] | Rest] Seen -> (field Name Field true Rest Seen)
    where (and (name? Marker) (= (local-label Marker) mutable))
  Name [Field | Rest] Seen -> (field Name Field false Rest Seen))

(define field
  Name Raw Mutable Rest Seen
  -> (let Label (local-label Raw)
       (cond ((or (= Label make) (= (pos (str Label) 0) "%"))
              (shen-jit.struct.fail Name "reserved field name" Label))
             ((element? Label Seen)
              (shen-jit.struct.fail Name "duplicate field" Label))
             (true
              [[Label Mutable] | (fields Name Rest [Label | Seen])]))))

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
  Name [[Field Mutable] | Fields]
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
                (do (systemf Tag)
                    (put Name shen-jit.struct.schema Description)
                    Description))))))

\\ Each layout gets an unbound tag of its own. Re-reading it reuses the stored tag, including
\\ after an image reload. A public type/constructor name can therefore never become its printer.
(define fresh-tag
  Name -> (let Tag (gensym (member Name %struct-tag))
            (if (= (arity Tag) -1) Tag (fresh-tag Name))))

\\ A constructor's parameters are fixed names in their own definition, not captured expressions.
(define arguments
  0 _ -> []
  N I -> [(intern (cn "StructField" (str I))) | (arguments (- N 1) (+ I 1))])

(define stores
  [] _ -> [(protect Record)]
  [Arg | Args] I
  -> [[address-> (protect Record) I Arg] | (stores Args (+ I 1))])

(define definition
  Name Args Body -> [define Name | (append Args [-> Body])])

(define generate
  Name Fields
  -> (let Tag (hd (schema Name))
          Args (arguments (length Fields) 1)
       [(definition
          (member Name make)
          Args
          [let (protect Record) [absvector (+ 1 (length Fields))]
            [do [address-> (protect Record) 0 Tag] | (stores Args 1)]])
        (definition
          (predicate-name Name)
          [(protect Record)]
          [shen-jit.tagged? (protect Record) Tag])
        | (accessors Name Fields 1)]))

(define accessors
  _ [] _ -> []
  Name [[Field Mutable] | Fields] I
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

(define expand
  [defstruct Name | Written]
  -> (let Fields (describe Name Written)
          _ (register Name Fields)
       (generate Name Fields))
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
  [[Field _] | Fields] Named
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

(define protect-field
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

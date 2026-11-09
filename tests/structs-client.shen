\\ Struct declarations expand while reading, so constructors work later in this same file.
(defstruct struct-test.cell key (mutable value))
(defstruct struct-test.other key (mutable value))
(defstruct struct-test.empty)
(defstruct struct-test.declared (name : string) (mutable count : number))
(define struct-test.show R -> (make-string "#<shown ~A>" (struct-test.shown.key R)))
(defstruct struct-test.shown (printer struct-test.show) key)
(defstruct struct-test.inline key (printer (/. R (make-string "inline ~A" (struct-test.inline.key R)))))

(shen.x.namespace struct-test.printing
  (import struct defstruct)
  (export point point.make)
  \\ The printer resolves in this namespace, as any reference does.
  (define show P -> (make-string "point ~A" (point.x P)))
  (defstruct point (printer show) x))

(shen.x.namespace struct-test.tools
  (shadow length)
  (export length)
  (define length N -> (+ N 10)))

(shen.x.namespace struct-test.model
  (use struct)
  (import struct defstruct)
  (import struct-test.tools length => size)
  (shadow absvector address-> <-address)
  (export row row.make row? row.size row.length row.value row.value-> sample)

  \\ Imported aliases and system names are labels here, not references to those functions.
  (defstruct row size length (mutable value))
  (define sample
    -> (struct.make row
         value <- (size 1);
         length <- 2;
         size <- 3;))
  \\ A generated constructor/reader/setter must not capture these caller definitions.
  (define absvector _ -> (simple-error "captured caller's absvector"))
  (define address-> _ _ _ -> (simple-error "captured caller's address->"))
  (define <-address _ _ -> (simple-error "captured caller's <-address")))

(shen.x.namespace struct-test.client
  (use struct)
  (use struct-test.model => m)
  (import struct-test.model row => entry row.make => create)
  (export result positional)
  (define positional -> (create 3 2 1))
  (define result
    -> (let R (struct.make entry
                length <- 12;
                value <- 13;
                size <- 11;)
         (do (m.row.value-> R 14)
             [(m.row? R) (m.row.size R) (m.row.length R) (m.row.value R)]))))

(shen.x.namespace struct-test.syntax
  (import struct defstruct => record make => build)
  (export first first? first.size first.value second second? second.size sample)
  (record first size (mutable value))
  (record second size)
  (define sample
    -> [(build first
          value <- 2;
          size <- 1;)
        (build second size <- 3;)]))

(shen.x.namespace struct-test.ordinary
  (export sample)
  (define defstruct X -> X)
  (define sample -> (defstruct 42)))

\\ The older package form qualifies syntax names along with its ordinary symbols.
(package struct-test.legacy [defstruct struct.make]
  (defstruct row key (mutable value))
  (define sample
    -> (struct.make row
         value <- 2;
         key <- 1;)))

(set struct-test.saved (struct-test.cell.make saved 17))

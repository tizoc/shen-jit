(set *hush* false)
(set struct-test.*passed* 0)
(set struct-test.*failed* 0)

(define struct-test.check
  Name Expected F
  -> (let Actual (trap-error (thaw F) (/. E [error (error-to-string E)]))
       (if (= Expected Actual)
           (set struct-test.*passed* (+ 1 (value struct-test.*passed*)))
           (do (set struct-test.*failed* (+ 1 (value struct-test.*failed*)))
               (output "FAIL ~A: expected ~R, got ~R~%" Name Expected Actual)))))

(define struct-test.refused?
  Source -> (trap-error (do (read-from-string Source) false) (/. E true)))

(define struct-test.install
  Source -> (map (fn eval) (read-from-string Source)))

(define struct-test.mark
  X -> (do (set struct-test.*order* (append (value struct-test.*order*) [X])) X))

(struct-test.check "positional and first class constructor" [true a 1]
  (freeze (let Make (fn struct-test.cell.make) R (Make a 1)
            [(struct-test.cell? R) (struct-test.cell.key R) (struct-test.cell.value R)])))
(struct-test.check "mutable alias and setter return" [true 3]
  (freeze (let R (struct-test.cell.make a 1) Alias R
            [(shen-jit.same? R (struct-test.cell.value-> R 3)) (struct-test.cell.value Alias)])))
(struct-test.check "read-only field has no setter" -1 (freeze (arity struct-test.cell.key->)))
(struct-test.check "nominal identity" false (freeze (struct-test.other? (struct-test.cell.make a 1))))
(struct-test.check "empty struct" true (freeze (struct-test.empty? (struct-test.empty.make))))
(struct-test.check "arbitrary managed values" ["text" [a b]]
  (freeze (let R (struct-test.cell.make "text" [a b]) [(struct-test.cell.key R) (struct-test.cell.value R)])))
(struct-test.check "predicate is safe on other values" [false false false false false false false false]
  (freeze (map (fn struct-test.cell?) [1 "x" a [] [a] (absvector 0) (vector 0) (@p 1 2)])))
(struct-test.check "private tag is not a printer" -1 (freeze (arity (<-address (struct-test.cell.make a 1) 0))))
(struct-test.check "printing does not call a public type-name function" true
  (freeze (do (struct-test.install "(define struct-test.cell X -> (simple-error c#34;called as printerc#34;))")
              (let R (struct-test.cell.make a 1)
                (= (make-string "<<~A a 1>>" (<-address R 0)) (make-string "~S" R))))))

(struct-test.check "label order and source evaluation order" [first second [second first]]
  (freeze (let _ (set struct-test.*order* [])
               R (struct.make struct-test.cell value <- (struct-test.mark second); key <- (struct-test.mark first);)
            [(struct-test.cell.key R) (struct-test.cell.value R) (value struct-test.*order*)])))
(struct-test.check "namespace field labels and initializer references" [true 3 2 11]
  (freeze (let R (struct-test.model.sample)
            [(struct-test.model.row? R) (struct-test.model.row.size R)
             (struct-test.model.row.length R) (struct-test.model.row.value R)])))
(struct-test.check "namespace renamed type import and mutable accessor" [true 11 12 14]
  (freeze (struct-test.client.result)))
(struct-test.check "ordinary positional constructor still supports renamed imports" [3 2 1]
  (freeze (let R (struct-test.client.positional)
            [(struct-test.model.row.size R) (struct-test.model.row.length R) (struct-test.model.row.value R)])))
(struct-test.check "shared constructor handles empty structs" true
  (freeze (struct-test.empty? (struct.make struct-test.empty))))
(struct-test.check "unknown struct type" true
  (freeze (struct-test.refused? "(struct.make struct-test.missing key <- a;)")))
(struct-test.check "shared constructor requires a literal type" true
  (freeze (struct-test.refused? "(struct.make Type key <- a;)")))
(struct-test.check "shared constructor requires a type" true
  (freeze (struct-test.refused? "(struct.make)")))
(struct-test.check "shared constructor requires labelled initializers" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell a b)")))
(struct-test.check "renamed syntax imports serve multiple struct declarations" [true 1 2 true 3]
  (freeze (let Records (struct-test.syntax.sample) A (hd Records) B (hd (tl Records))
            [(struct-test.syntax.first? A) (struct-test.syntax.first.size A) (struct-test.syntax.first.value A)
             (struct-test.syntax.second? B) (struct-test.syntax.second.size B)])))
(struct-test.check "namespace-local defstruct remains an ordinary function" 42
  (freeze (struct-test.ordinary.sample)))
(struct-test.check "construction requires a preceding declaration" true
  (freeze (struct-test.refused?
    "(shen.x.namespace struct-test.forward (use struct) (import struct defstruct) (define sample -> (struct.make row key <- a;)) (defstruct row key))")))
(struct-test.check "initializer protection survives macro expansion" (intern "Y")
  (freeze (do (struct-test.install
                "(shen.x.namespace struct-test.protected (use struct) (use struct-test) (define sample -> (struct-test.cell.value (struct.make struct-test.cell key <- a; value <- (protect Y);))))")
              (struct-test.protected.sample))))
(struct-test.check "legacy package declaration" [1 2]
  (freeze (let R (struct-test.legacy.sample)
            [(struct-test.legacy.row.key R) (struct-test.legacy.row.value R)])))
(struct-test.check "source keyword leaves the ordinary function binding available" [left right]
  (freeze (do (struct-test.install "(define defstruct A B -> [A B])")
              (let F (fn defstruct) (F left right)))))

(struct-test.check "duplicate field" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad x x)")))
(struct-test.check "duplicate mutable field" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad x (mutable x))")))
(struct-test.check "reserved constructor field" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad make)")))
(struct-test.check "reserved private field" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad %private)")))
(struct-test.check "generated operation collision" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad (mutable x) x->)")))
(struct-test.check "invalid field syntax" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad (unknown x))")))
(struct-test.check "variable struct name" true
  (freeze (struct-test.refused? "(defstruct Bad x)")))
(struct-test.check "variable field name" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad X)")))
(struct-test.check "existing operation is preserved" true
  (freeze (do (struct-test.install "(define struct-test.taken.key X -> X)")
              (and (struct-test.refused? "(defstruct struct-test.taken key)")
                   (= (struct-test.taken.key 4) 4)))))
(struct-test.check "identical declaration reload preserves old values" [saved 17]
  (freeze (do (struct-test.install "(defstruct struct-test.cell key (mutable value))")
              [(struct-test.cell.key (value struct-test.saved)) (struct-test.cell.value (value struct-test.saved))])))
(struct-test.check "layout reorder is refused" true
  (freeze (struct-test.refused? "(defstruct struct-test.cell (mutable value) key)")))
(struct-test.check "mutability change is refused" true
  (freeze (struct-test.refused? "(defstruct struct-test.cell key value)")))
(struct-test.check "failed redefinition preserves existing operations" [saved 17]
  (freeze [(struct-test.cell.key (value struct-test.saved)) (struct-test.cell.value (value struct-test.saved))]))

(struct-test.check "missing labelled field" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a;)")))
(struct-test.check "unknown labelled field" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell unknown <- a; value <- b;)")))
(struct-test.check "duplicate labelled field" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a; key <- b;)")))
(struct-test.check "missing field terminator" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a; value <- b)")))
(struct-test.check "mixed positional and labelled fields" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a; b)")))
(struct-test.check "generated operation cannot replace an imported name" true
  (freeze (struct-test.refused?
    "(shen.x.namespace struct-test.collision (import struct defstruct) (import struct-test.tools length => row.key) (defstruct row key))")))
(struct-test.check "unexported field access stays private" true
  (freeze (struct-test.refused?
    "(shen.x.namespace struct-test.private (use struct-test.model => m) (define f -> m.row.%struct-tag))")))

(shen-jit.collect)
(struct-test.check "managed field survives collection" [saved 17]
  (freeze [(struct-test.cell.key (value struct-test.saved)) (struct-test.cell.value (value struct-test.saved))]))
(output "~A passed, ~A failed (structs)~%" (value struct-test.*passed*) (value struct-test.*failed*))
(if (= (value struct-test.*failed*) 0) true (simple-error "struct checks failed"))

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
(struct-test.check "default printer" "#<struct-test.cell key: a value: c#34;textc#34;>"
  (freeze (make-string "~S" (struct-test.cell.make a "text"))))
(struct-test.check "default printer nests and prints empty structs" "[#<struct-test.cell key: #<struct-test.empty> value: [1 2]>]"
  (freeze (make-string "~S" [(struct-test.cell.make (struct-test.empty.make) [1 2])])))
(struct-test.check "printing does not call a public type-name function" "#<struct-test.cell key: a value: 1>"
  (freeze (do (struct-test.install "(define struct-test.cell X -> (simple-error c#34;called as printerc#34;))")
              (make-string "~S" (struct-test.cell.make a 1)))))
(struct-test.check "custom printer function" "#<shown 7>"
  (freeze (make-string "~S" (struct-test.shown.make 7))))
(struct-test.check "custom printer expression" "inline 8"
  (freeze (make-string "~A" (struct-test.inline.make 8))))
(struct-test.check "namespace printer resolves locally" "point 9"
  (freeze (make-string "~S" (struct-test.printing.point.make 9))))
(struct-test.check "printer is not a field" [1 true]
  (freeze (let R (struct-test.shown.make 1) [(struct-test.shown.key R) (struct-test.shown? R)])))
(struct-test.check "one printer at most" true
  (freeze (struct-test.refused? "(defstruct struct-test.bad (printer f) (printer g) x)")))
(struct-test.check "a changed printer keeps the layout and old values" ["changed" saved]
  (freeze (let Old (struct-test.shown.make saved)
               _ (struct-test.install "(defstruct struct-test.shown (printer (/. R c#34;changedc#34;)) key)")
               Text (make-string "~A" Old)
               _ (struct-test.install "(defstruct struct-test.shown (printer struct-test.show) key)")
            [Text (struct-test.shown.key Old)])))

(struct-test.check "label order and source evaluation order" [first second [second first]]
  (freeze (let _ (set struct-test.*order* [])
               R (struct.make struct-test.cell value <- (struct-test.mark second) key <- (struct-test.mark first))
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
  (freeze (struct-test.refused? "(struct.make struct-test.missing key <- a)")))
(struct-test.check "shared constructor requires a literal type" true
  (freeze (struct-test.refused? "(struct.make Type key <- a)")))
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
    "(shen.x.namespace struct-test.forward (use struct) (import struct defstruct) (define sample -> (struct.make row key <- a)) (defstruct row key))")))
(struct-test.check "initializer protection survives macro expansion" (intern "Y")
  (freeze (do (struct-test.install
                "(shen.x.namespace struct-test.protected (use struct) (use struct-test) (define sample -> (struct-test.cell.value (struct.make struct-test.cell key <- a value <- (protect Y)))))")
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
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a)")))
(struct-test.check "unknown labelled field" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell unknown <- a value <- b)")))
(struct-test.check "duplicate labelled field" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a key <- b)")))
(struct-test.check "fields are not separated by ;" [true true]
  (freeze [(struct-test.refused? "(struct.make struct-test.cell key <- a; value <- b)")
           (struct-test.refused? "(define struct-test.bad (:struct-test.pt x <- X; ...) -> X)")]))
(struct-test.check "mixed positional and labelled fields" true
  (freeze (struct-test.refused? "(struct.make struct-test.cell key <- a b)")))
(struct-test.check "generated operation cannot replace an imported name" true
  (freeze (struct-test.refused?
    "(shen.x.namespace struct-test.collision (import struct defstruct) (import struct-test.tools length => row.key) (defstruct row key))")))
(struct-test.check "unexported field access stays private" true
  (freeze (struct-test.refused?
    "(shen.x.namespace struct-test.private (use struct-test.model => m) (define f -> m.row.%struct-tag))")))

(define struct-test.refused-typed?
  Source -> (let _ (tc +) Refused (struct-test.refused? Source) _ (tc -) Refused))

(define struct-test.type-of
  F -> (trap-error (shen.get-type F) (/. E none)))

(struct-test.check "typed construction, readers and setter" [7 1 6]
  (freeze (let P (struct-test.tbump (struct-test.tbuild 5))
            [(struct-test.tnorm P) (struct-test.tpoint.x P) (struct-test.tpoint.y P)])))
(struct-test.check "typed printer" "#<struct-test.tpoint x: 1 y: 2>"
  (freeze (make-string "~S" (struct-test.tbuild 2))))
(struct-test.check "typed empty struct" true (freeze (struct-test.tempty? (struct-test.tempty.make))))
(struct-test.check "typed predicate accepts anything" false (freeze (struct-test.tpoint? 3)))
(struct-test.check "declared under (tc -) for typed clients" "n"
  (freeze (struct-test.tuntyped-client (struct-test.declared.make "n" 0))))
(struct-test.check "namespaced field types" 4
  (freeze (struct-test.tns.unwrap (struct-test.tns.wrapper.make (struct-test.tns.cell.make 4 [])))))
(struct-test.check "typed operations check their arguments" [number false false]
  (freeze (map (/. S (shen.typecheck (hd (read-from-string S)) (protect A)))
               ["(struct-test.tnorm (struct-test.tbuild 1))"
                "(struct-test.tpoint.x 5)"
                "(struct-test.tpoint.y-> (struct-test.tbuild 1) a)"])))
(struct-test.check "under (tc +) fields need types" true
  (freeze (struct-test.refused-typed? "(defstruct struct-test.untyped-tc x)")))
(struct-test.check "every field typed, or none" true
  (freeze (struct-test.refused? "(defstruct struct-test.mixed (x : number) y)")))
(struct-test.check "no type variables" true
  (freeze (struct-test.refused? "(defstruct struct-test.poly (x : A))")))
(struct-test.check "a changed type is an incompatible layout" true
  (freeze (struct-test.refused? "(defstruct struct-test.declared (name : symbol) (mutable count : number))")))
(struct-test.check "an identical typed declaration reloads" "again"
  (freeze (do (struct-test.install "(defstruct struct-test.declared (name : string) (mutable count : number))")
              (struct-test.declared.name (struct-test.declared.make "again" 1)))))

(struct-test.check "colon construction in source order" [[3 [2]] [first second]]
  (freeze (let _ (set struct-test.*order* [])
               R (:struct-test.pt y <- (struct-test.mark first) x <- (struct-test.mark second))
               P (struct-test.colon-build 2)
            [[(struct-test.pt.x P) (struct-test.pt.y P)] (value struct-test.*order*)])))
(struct-test.check "struct.make is the same construction" true
  (freeze (= (struct.make struct-test.pt x <- 1 y <- 2) (:struct-test.pt y <- 2 x <- 1))))
(struct-test.check "partial match and fallthrough" [2 none none]
  (freeze [(struct-test.x-of (struct-test.pt.make 2 3)) (struct-test.x-of 5)
           (struct-test.x-of (struct-test.seg.make 1 2))]))
(struct-test.check "list pattern in a field" [7 none]
  (freeze [(struct-test.first-y (struct-test.pt.make 0 [7 8])) (struct-test.first-y (struct-test.pt.make 0 []))]))
(struct-test.check "repeated variable" [true false]
  (freeze [(struct-test.diagonal? (struct-test.pt.make 3 3)) (struct-test.diagonal? (struct-test.pt.make 3 4))]))
(struct-test.check "literal fields" [true false]
  (freeze [(struct-test.origin? (struct-test.pt.make 0 0)) (struct-test.origin? (struct-test.pt.make 0 1))]))
(struct-test.check "nested patterns" [true false]
  (freeze [(struct-test.vertical? (struct-test.seg.make (struct-test.pt.make 1 0) (struct-test.pt.make 1 9)))
           (struct-test.vertical? (struct-test.seg.make (struct-test.pt.make 1 0) (struct-test.pt.make 2 9)))]))
(struct-test.check "guards and wildcards" [big small none]
  (freeze [(struct-test.size (struct-test.pt.make 20 0)) (struct-test.size (struct-test.pt.make 1 0))
           (struct-test.size 1)]))
(struct-test.check "one clause per struct" [segment point other]
  (freeze [(struct-test.kind (struct-test.seg.make 1 2)) (struct-test.kind (struct-test.pt.make 1 2))
           (struct-test.kind (@p 1 2))]))
(struct-test.check "patterns read only the fields they name" true
  (freeze (let Code (ps struct-test.x-of) (= 0 (occurrences struct-test.pt.y Code)))))
(struct-test.check "colon through a namespace alias" [7 [3 2]]
  (freeze (let P (struct-test.geo-client.gmake 3)
            [(struct-test.geo-client.gx (struct-test.geo.pt.make 7 8))
             [(struct-test.geo.pt.x P) (struct-test.geo.pt.y P)]])))
(struct-test.check "a pattern compiles after an image reload" 4
  (freeze (do (struct-test.install "(define struct-test.late (:struct-test.pt y <- Y ...) -> Y)")
              (struct-test.late (struct-test.pt.make 3 4)))))
(struct-test.check "missing field" true
  (freeze (struct-test.refused? "(define struct-test.bad (:struct-test.pt x <- X) -> X)")))
(struct-test.check "unknown field in a pattern" true
  (freeze (struct-test.refused? "(define struct-test.bad (:struct-test.pt z <- X ...) -> X)")))
(struct-test.check "duplicate field in a pattern" true
  (freeze (struct-test.refused? "(define struct-test.bad (:struct-test.pt x <- X x <- Y) -> X)")))
(struct-test.check "... comes last" true
  (freeze (struct-test.refused? "(define struct-test.bad (:struct-test.pt ... x <- X) -> X)")))
(struct-test.check "... in a construction" true
  (freeze (trap-error (do (struct-test.install "(define struct-test.bad -> (:struct-test.pt x <- 1 ...))") false)
                      (/. E true))))
(struct-test.check "unknown struct after :" true
  (freeze (struct-test.refused? "(define struct-test.bad (:struct-test.nothing x <- X) -> X)")))
(struct-test.check "typed colon construction and matching" [6 true]
  (freeze [(struct-test.tmatch-x (struct-test.tcolon 5))
           (struct-test.tvertical? (struct-test.tseg.make (struct-test.tcolon 1) (struct-test.tcolon 1)))]))
(struct-test.check "typed match on a struct declared under (tc -)" "n"
  (freeze (struct-test.tdeclared-name (struct-test.declared.make "n" 0))))
(struct-test.check "typed patterns check their fields" [false false false]
  (freeze (map (/. S (shen.typecheck (hd (read-from-string S)) (protect A)))
               ["(/. P (struct-test.tmatch-x (:struct-test.tpoint x <- a y <- 1)))"
                "(:struct-test.tpoint x <- 1 y <- b)"
                "(struct-test.tmatch-x (:struct-test.tseg from <- (struct-test.tcolon 1) to <- (struct-test.tcolon 2)))"])))

(struct-test.check "fields without separators" [[1 2] 1 [1 2] 5]
  (freeze (let P (struct-test.unterminated)
            [[(struct-test.pt.x P) (struct-test.pt.y P)] (struct-test.unterminated-x P)
             (struct-test.unterminated-both P)
             (struct-test.unterminated-nested (struct-test.seg.make (struct-test.pt.make 5 0) 0))])))
(struct-test.check "struct.make without separators" true
  (freeze (= (struct.make struct-test.pt x <- 1 y <- 2) (struct-test.unterminated))))

(struct-test.check "the same expression in two fields" [1 2]
  (freeze (let _ (set struct-test.*counter* 0) P (struct-test.twice)
            [(struct-test.pt.x P) (struct-test.pt.y P)])))
(struct-test.check "a pattern variable may be named Missing-" [1 2]
  (freeze (struct-test.named-missing (struct-test.pt.make 1 2))))
(struct-test.check "a bad label names the struct" "struct struct-test.pt: expected a field name: 3"
  (freeze (trap-error (do (read-from-string "(:struct-test.pt 3 <- 1 y <- 2)") ok) (/. E (error-to-string E)))))

(struct-test.check "a typed union matches each member" [3 6 [12 4]]
  (freeze [(struct-test.area (struct-test.circle.make 1)) (struct-test.area (struct-test.rect.make 2 3))
           (map (fn struct-test.area) (struct-test.shapes 2))]))
(struct-test.check "a union stays open" [16 3]
  (freeze [(struct-test.area2 (struct-test.square.make 4)) (struct-test.area2 (struct-test.circle.make 1))]))
(struct-test.check "a union in a namespace" [0 5]
  (freeze [(struct-test.geometry.length-of (struct-test.geometry.dot.make 1))
           (struct-test.geometry.length-of (struct-test.geometry.line.make 2 7))]))
(struct-test.check "a union does not make a member of any other" [false false false]
  (freeze (map (/. S (shen.typecheck (hd (read-from-string S)) (protect A)))
               ["(struct-test.circle.radius (head (struct-test.shapes 1)))"
                "(struct-test.area (struct-test.tcolon 1))"
                "(struct-test.circle.radius (struct-test.rect.make 1 2))"])))
(struct-test.check "union members need field types" true
  (freeze (struct-test.refused? "(struct.union struct-test.loose struct-test.pt)")))
(struct-test.check "union members are structs" true
  (freeze (struct-test.refused? "(struct.union struct-test.loose struct-test.nothing)")))

(shen-jit.collect)
(struct-test.check "managed field survives collection" [saved 17]
  (freeze [(struct-test.cell.key (value struct-test.saved)) (struct-test.cell.value (value struct-test.saved))]))
(output "~A passed, ~A failed (structs)~%" (value struct-test.*passed*) (value struct-test.*failed*))
(if (= (value struct-test.*failed*) 0) true (simple-error "struct checks failed"))

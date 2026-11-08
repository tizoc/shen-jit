\\ Bounded C source facts. Load through main.shen, after its library dependencies.

(set source-facts.query
  "(function_definition) @definition
   (call_expression function: (identifier) @call)")

(set source-facts.configured-query
  (cn (value source-facts.query) "c#10;(declaration) @declaration"))

(define source-facts.declarator-node
  _ 0 -> 0
  T ID ->
    (let Kind (treesitter.kind T ID)
      (cond ((= Kind "identifier") ID)
            ((= Kind "parenthesized_declarator")
              (source-facts.declarator-node T (source-facts.first-named T (treesitter.children T ID))))
            (true (source-facts.declarator-node T (treesitter.child-by-field T ID "declarator"))))))

(define source-facts.first-named
  _ [] -> 0
  T [ID | Rest] -> (if (treesitter.named? T ID) ID (source-facts.first-named T Rest)))

(define source-facts.enclosing-function
  _ 0 -> 0
  T ID ->
    (if (= (treesitter.kind T ID) "function_definition") ID
        (source-facts.enclosing-function T (treesitter.parent T ID))))

(define source-facts.static?
  _ [] -> false
  T [ID | Rest] ->
    (or (and (= (treesitter.kind T ID) "storage_class_specifier") (= (treesitter.text T ID) "static"))
        (source-facts.static? T Rest)))

(define source-facts.static-declarators
  _ [] Names -> Names
  T [ID | Rest] Names ->
    (let Name (if (= (treesitter.field T ID) "declarator") (source-facts.declarator-node T ID) 0)
         _ (if (= Name 0) true (shen.dict-> Names (treesitter.text T Name) true))
      (source-facts.static-declarators T Rest Names)))

\\ A prior static prototype can give an otherwise unqualified definition internal linkage.
\\ Inspect file-scope declarations across all preprocessor branches conservatively.
(define source-facts.static-names
  T ->
    (treesitter.fold
      (/. Names ID
        (if (and (= (treesitter.kind T ID) "declaration")
                 (= (source-facts.enclosing-function T (treesitter.parent T ID)) 0)
                 (source-facts.static? T (treesitter.children T ID)))
            (source-facts.static-declarators T (treesitter.children T ID) Names) Names))
      (shen.dict 32) T))

(define source-facts.linkage
  T Definition Name StaticNames ->
    (cond ((not (= (source-facts.enclosing-function T (treesitter.parent T Definition)) 0)) "unknown")
          ((or (source-facts.static? T (treesitter.children T Definition))
               (trap-error (shen.<-dict StaticNames (treesitter.text T Name)) (/. E false))) "internal")
          (true "external")))

\\ The nearest declarator constructor distinguishes a function from a function-pointer variable.
(define source-facts.function-name?
  _ 0 -> false
  T ID ->
    (let Kind (treesitter.kind T ID)
      (cond ((= Kind "function_declarator") true)
            ((element? Kind ["pointer_declarator" "array_declarator" "declaration"]) false)
            (true (source-facts.function-name? T (treesitter.parent T ID))))))

(define source-facts.site-fields
  Path T Kind ID Owner OwnerByte Error ->
    (let Point (treesitter.start-point T ID)
      [["path" Path] ["kind" Kind] ["name" (treesitter.text T ID)]
       ["container" Owner] ["container_byte" OwnerByte]
       ["start_byte" (treesitter.start-byte T ID)] ["end_byte" (treesitter.end-byte T ID)]
       ["row" (hd Point)] ["column" (hd (tl Point))] ["syntax_error" Error]]))

(define source-facts.declarations
  _ _ _ _ _ _ [] -> [ok done]
  Writer State Path T Error StaticNames [ID | Rest] ->
    (let Name (if (= (treesitter.field T ID) "declarator") (source-facts.declarator-node T ID) 0)
         Result (if (and (not (= Name 0)) (source-facts.function-name? T (treesitter.parent T Name)))
                    (source-facts.emit Writer State
                      [object | (append (source-facts.site-fields Path T "declaration" Name "" null Error)
                                  [["linkage" (source-facts.linkage T (treesitter.parent T ID) Name StaticNames)]])])
                    [ok done])
      (io.let-ok _ Result
        (source-facts.declarations Writer State Path T Error StaticNames Rest))))

(define source-facts.write-result
  [accepted _] -> [ok done]
  [error E _] -> [error E])

\\ State counts records, encoded bytes and files; the writer never accumulates an entire repository.
(define source-facts.emit
  Writer State Value ->
    (let Bytes (json.encode Value [[byte-limit 65536]])
         N (+ (buffer.length Bytes) 1)
      (if (or (>= (<-address State 0) 100000) (> N (- 67108864 (<-address State 1))))
          [error (io.native-error source-facts limit 0 "facts" "total fact output limit exceeded")]
          (io.let-ok _ (source-facts.write-result (io.write Writer Bytes))
            (io.let-ok _ (source-facts.write-result (io.write Writer (buffer.from-string "c#10;")))
              (do (address-> State 0 (+ (<-address State 0) 1))
                  (address-> State 1 (+ (<-address State 1) N))
                  [ok done]))))))

(define source-facts.captures
  _ _ _ _ _ _ At End -> [ok done] where (> At End)
  Writer State Path T Error StaticNames At End ->
    (let ID (treesitter.capture-node T At)
         Result (if (= (source-facts.enclosing-function T ID) 0)
                    (source-facts.declarations Writer State Path T Error StaticNames (treesitter.children T ID))
                    [ok done])
      (io.let-ok _ Result
        (source-facts.captures Writer State Path T Error StaticNames (+ At 1) End)))
      where (= (treesitter.capture-name T At) "declaration")
  Writer State Path T Error StaticNames At End ->
    (let Captured (treesitter.capture-node T At)
         Kind (treesitter.capture-name T At)
         ID (if (= Kind "definition")
                (source-facts.declarator-node T (treesitter.child-by-field T Captured "declarator"))
                Captured)
         _ (if (= ID 0) (error "unsupported function declarator") true)
         Definition (source-facts.enclosing-function T Captured)
         Owner (if (= Definition 0) 0
                   (source-facts.declarator-node T (treesitter.child-by-field T Definition "declarator")))
         OwnerByte (if (= Owner 0) null (treesitter.start-byte T Owner))
         Fields (source-facts.site-fields Path T Kind ID
                  (if (= Owner 0) "" (treesitter.text T Owner)) OwnerByte Error)
         Fact [object | (if (= Kind "definition")
                           (append Fields [["linkage" (source-facts.linkage T Definition ID StaticNames)]])
                           Fields)]
      (io.let-ok _ (source-facts.emit Writer State Fact)
        (source-facts.captures Writer State Path T Error StaticNames (+ At 1) End))))

(define source-facts.parsed
  _ _ Path [error E] ->
    [error (io.native-error source-facts (treesitter.error-domain E) (treesitter.error-code E)
                           Path (treesitter.error-message E))]
  Writer State Path [ok T] ->
    (let Error (treesitter.has-error? T 1)
         Fields [["path" Path] ["kind" "file"] ["syntax_error" Error] ["byte_count" (treesitter.end-byte T 1)]]
         Context (<-address State 3)
         Extra (if (= Context []) [["schema_version" 2]]
                   [["schema_version" 3] ["configuration" Context] ["coordinates" "preprocessed"]
                    ["directory" (<-address State 4)] ["arguments" (<-address State 5)]])
         Fact [object | (append Fields Extra)]
      (io.let-ok _ (source-facts.emit Writer State Fact)
        (do (address-> State 2 (+ (<-address State 2) 1))
            (source-facts.captures Writer State Path T Error (source-facts.static-names T)
              1 (treesitter.capture-count T))))))

(define source-facts.file
  Language Writer State Path ->
    (io.let-ok Input (io.read-file Path 8388608)
      (source-facts.parsed Writer State Path
        (treesitter.query Language Input (value source-facts.query) []))))

(define source-facts.visit-result
  [ok _] -> continue
  [error E] -> [error E])

(define source-facts.visit
  Language Writer State Info Depth ->
    (let Path (fs.path Info)
         Kind (fs.kind Info)
      (cond ((and (= Kind directory) (element? (fs.name Path) [".git" ".deps" "build"])) skip)
            ((and (= Kind file) (element? (fs.extension Path) [".c" ".h"]))
              (source-facts.visit-result (source-facts.file Language Writer State Path)))
            (true continue))))

(define source-facts.extract
  Language Root Out ->
    (let State (io.record [0 0 0 [] "" []])
         Writer (io.writer Out [[chunk-size 4096]])
      (io.let-ok _ (fs.walk Root [[entry-limit 10000] [depth-limit 64] [name-byte-limit 16777216]]
                    (/. Info Depth (source-facts.visit Language Writer State Info Depth)))
        [ok (@p (<-address State 2) (<-address State 0))])))

(define source-facts.finish
  [ok (@p Files Records)] -> (output "Extracted ~A records from ~A files~%" Records Files)
  [error E] -> (error "source-facts: ~A: ~A" (io.error-resource E) (io.error-message E)))

(define source-facts.start
  Root Output [ok Language] ->
    (source-facts.finish
      (fs.with-replacement Output (/. Out (source-facts.extract Language Root Out))))
  _ _ [error E] -> (error "source-facts: ~A" (treesitter.error-message E)))

(define source-facts.main
  [_ Grammar "--compile-commands" Database Configuration Output] ->
    (source-facts.finish (source-build.start Grammar Database Configuration Output))
  [_ Grammar Root Output] ->
    (source-facts.start Root Output (treesitter.load-language "C" [Grammar] "tree_sitter_c"))
  _ -> (error "usage: source-facts GRAMMAR ROOT OUTPUT, or GRAMMAR --compile-commands DATABASE CONFIGURATION OUTPUT"))

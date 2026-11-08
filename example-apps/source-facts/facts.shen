\\ Bounded C source facts. Load through main.shen, after its library dependencies.

(set source-facts.query
  "(function_definition) @definition
   (call_expression function: (identifier) @call)")

(define source-facts.declarator-node
  _ 0 -> 0
  T ID ->
    (if (= (treesitter.kind T ID) "identifier")
        ID
        (source-facts.declarator-node T (treesitter.child-by-field T ID "declarator"))))

(define source-facts.container
  _ 0 -> ""
  T ID ->
    (if (= (treesitter.kind T ID) "function_definition")
        (let Name (source-facts.declarator-node T (treesitter.child-by-field T ID "declarator"))
          (if (= Name 0) "" (treesitter.text T Name)))
        (source-facts.container T (treesitter.parent T ID))))

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
  _ _ _ _ _ At End -> [ok done] where (> At End)
  Writer State Path T Error At End ->
    (let Captured (treesitter.capture-node T At)
         Kind (treesitter.capture-name T At)
         ID (if (= Kind "definition")
                (source-facts.declarator-node T (treesitter.child-by-field T Captured "declarator"))
                Captured)
         Point (treesitter.start-point T ID)
         Fact [object ["path" Path] ["kind" Kind]
                      ["name" (treesitter.text T ID)] ["container" (source-facts.container T ID)]
                      ["start_byte" (treesitter.start-byte T ID)] ["end_byte" (treesitter.end-byte T ID)]
                      ["row" (hd Point)] ["column" (hd (tl Point))] ["syntax_error" Error]]
      (io.let-ok _ (source-facts.emit Writer State Fact)
        (source-facts.captures Writer State Path T Error (+ At 1) End))))

(define source-facts.parsed
  _ _ Path [error E] ->
    [error (io.native-error source-facts (treesitter.error-domain E) (treesitter.error-code E)
                           Path (treesitter.error-message E))]
  Writer State Path [ok T] ->
    (let Error (treesitter.has-error? T 1)
         Fact [object ["path" Path] ["kind" "file"] ["syntax_error" Error]
                      ["byte_count" (treesitter.end-byte T 1)]]
      (io.let-ok _ (source-facts.emit Writer State Fact)
        (do (address-> State 2 (+ (<-address State 2) 1))
            (source-facts.captures Writer State Path T Error 1 (treesitter.capture-count T))))))

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
    (let State (io.record [0 0 0])
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
  [_ Grammar Root Output] ->
    (source-facts.start Root Output (treesitter.load-language "C" [Grammar] "tree_sitter_c"))
  _ -> (error "usage: shen-jit script example-apps/source-facts/main.shen GRAMMAR ROOT OUTPUT"))

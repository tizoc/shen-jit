\\ Bounded diagnostics travel with the export, including when analysis runs on another machine.
(define source-facts.diagnostic
  T Input ID ->
    (let Start (treesitter.start-byte T ID)
         Point (treesitter.start-point T ID)
         From (if (> Start 32) (- Start 32) 0)
      [object ["kind" (if (treesitter.missing? T ID) "missing" "error")]
              ["node_kind" (treesitter.kind T ID)]
              ["start_byte" Start] ["end_byte" (treesitter.end-byte T ID)]
              ["row" (hd Point)] ["column" (hd (tl Point))]
              ["excerpt" (source-syntax.excerpt Input From)]]))

(define source-facts.diagnostics
  T Input ->
    (treesitter.fold
      (/. State ID
        (if (or (treesitter.error? T ID) (treesitter.missing? T ID))
            (do (if (< (<-address State 0) 8)
                    (address-> State 1 [(source-facts.diagnostic T Input ID) | (<-address State 1)]) true)
                (address-> State 0 (+ (<-address State 0) 1))
                State) State))
      (io.record [0 []]) T))

(define source-facts.capture-stats
  _ At End Counts -> Counts where (> At End)
  T At End Counts ->
    (let Reason (if (= (treesitter.capture-name T At) "call")
                   (source-syntax.capture-reason T (treesitter.capture-node T At)) [])
         _ (cond ((= Reason annotation) (address-> Counts 0 (+ (<-address Counts 0) 1)))
                 ((= Reason preprocessor) (address-> Counts 1 (+ (<-address Counts 1) 1)))
                 (true true))
      (source-facts.capture-stats T (+ At 1) End Counts)))

(define source-facts.parse-info
  T State ->
    (let Diagnostics (source-facts.diagnostics T (<-address State 6))
         Captures (source-facts.capture-stats T 1 (treesitter.capture-count T) (io.record [0 0]))
         Profile (<-address State 7)
      [object ["profile" (if (= Profile []) "c" "c-facts-v1")]
              ["normalizations" [object ["attributes" (if (= Profile []) 0 (<-address Profile 1))]
                                        ["nullability" (if (= Profile []) 0 (<-address Profile 2))]
                                        ["block_pointers" (if (= Profile []) 0 (<-address Profile 3))]]]
              ["error_count" (<-address Diagnostics 0)] ["errors" (reverse (<-address Diagnostics 1))]
              ["ignored_captures" [object ["annotation" (<-address Captures 0)]
                                          ["preprocessor" (<-address Captures 1)]]]]))

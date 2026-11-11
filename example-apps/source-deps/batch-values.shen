\\ Optional ordinary-value transport. Load source-deps/load.shen and
\\ lib/parallel-map.shen first, under tc-. The CLI keeps its byte protocol.

(define source-deps.value-ids
  _ End End Reversed -> (reverse Reversed)
  Bytes At End Reversed ->
    (source-deps.value-ids Bytes (+ At 4) End [(shen-jit.u32 Bytes At) | Reversed]))

(define source-deps.value-job
  [Mode Root] ->
    (let _ (if (and (element? Mode [0 1]) (integer? Root) (>= Root 0)) true
               (error "batch values: invalid query"))
         G (sdg.check (parallel.shared))
         Answer (sdg.query G Mode Root true)
      [Mode Root (source-deps.value-ids Answer 0 (shen-jit.bytes-length Answer) [])])
  _ -> (error "batch values: expected [direction root]"))

(define source-deps.value-names
  _ [] _ Reversed -> (reverse Reversed)
  Names [ID | Rest] Previous Reversed ->
    (if (and (integer? ID) (> ID Previous) (< ID (limit Names)))
        (source-deps.value-names Names Rest ID [(<-address Names (+ ID 1)) | Reversed])
        (error "batch values: invalid answer ID"))
  _ _ _ _ -> (error "batch values: expected a proper answer list"))

(define source-deps.values-decode
  _ [] [] Reversed -> (reverse Reversed)
  Names [[Mode Root] | Queries] [[Mode Root IDs] | Replies] Reversed ->
    (source-deps.values-decode Names Queries Replies
      [[(if (= Mode 0) reach impact) (<-address Names (+ Root 1))
        (source-deps.value-names Names IDs -1 [])] | Reversed])
  _ _ _ _ -> (error "batch values: unexpected reply"))

(define source-deps.values-batch
  Export Scope Queries ->
    (source-deps.values-decode (<-address Export 2) Queries (parallel.map Scope Queries) []))

(define source-deps.with-value-workers
  Export Image Workers Body ->
    (parallel.with-map Image (intern "source-deps.value-job") Workers
      (source-deps.batch-config Export Workers) Body))

(define source-deps.batch-execute-values
  Export Queries Workers Image ->
    (source-deps.with-value-workers Export Image Workers
      (/. Scope (source-deps.values-batch Export Scope Queries))))

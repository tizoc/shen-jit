\\ Load libraries with tc off, then this client with tc on.
(define io-typed.chunk
  {(io.result (option.t buffer.view)) --> string}
  (:result.ok [V]) -> (buffer.string V)
  (:result.ok []) -> "end"
  (:result.err E) -> (io.error-message E))
(define io-typed.transfer
  {(io.result fixnum) --> fixnum}
  (:result.ok N) -> N
  (:result.err E) -> (io.error-progress E))
(define io-typed.value
  {(io.result string) --> string}
  (:result.ok S) -> S
  (:result.err E) -> (io.error-message E))
(define io-typed.file
  {string --> (io.result buffer.view)}
  Path -> (io.read-file Path 1024))
(define io-typed.close
  {io.endpoint --> (io.result result.empty)}
  E -> (io.close E))
(define io-typed.make
  {--> io.endpoint}
  -> (io.endpoint "typed" read 4 (/. B (:result.ok [])) (function io.no-write) (freeze (:result.ok []))))
(define io-typed.scoped-progress
  {io.endpoint --> io.error --> (io.result string)}
  E Error -> (io.with-endpoint E (/. X (:result.err (io.progress Error 7)))))
(define io-typed.file-progress
  {string --> (io.endpoint --> (io.result string)) --> (io.result string)}
  Path F -> (io.with-output-file Path F))
(define io-typed.run
  {--> boolean}
  -> (let E (io.input-buffer (buffer.from-string "abc")) R (io.reader E [[chunk-size 2]])
          A (io-typed.chunk (io.read-chunk R)) B (io-typed.chunk (io.read-chunk R))
          C (io-typed.chunk (io.read-chunk R)) _ (io.close E)
          V (buffer.new 3) Sink (io.output-buffer V)
          N (io-typed.transfer (io.write-all Sink (buffer.from-string "xyz") [])) _ (io.close Sink)
          Scope (io.with-endpoint (io-typed.make) (/. X (:result.ok "scope")))
       (and (and (= [A B C] ["ab" "c" "end"]) (= N 3))
            (and (= (buffer.string V) "xyz") (= (io-typed.value Scope) "scope")))))
(output "~A~%" (if (io-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))

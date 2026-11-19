(define listener-typed.finished?
  {http.wait-result --> boolean}
  (:result.ok []) -> true
  (:result.err _) -> false)

(define listener-typed.handler
  {http.request --> http.response}
  Q -> (http.response 200 [] (http.body Q)))

(define listener-typed.with-state
  {string --> http.request --> http.response}
  Text _ -> (http.response 200 [] (buffer.from-string Text)))

(define listener-typed.run
  {--> boolean}
  -> (let S (http.listen "127.0.0.1" 0 [listener-typed.with-state "typed"]
              [[max-connections 2] [shutdown-grace 0]
               (http.from-server-option (http.from-chunk-option [chunk-count-limit 4]))
               (http.from-server-option (http.from-response-option [response-chunk-size 1024]))])
          _ (http.stop S)
       (listener-typed.finished? (http.run S))))

(define listener-typed.message
  {http.wait-result --> string}
  (:result.err E) -> (io.error-message E)
  (:result.ok []) -> "stopped")

(output "~A~%"
  (if (= (listener-typed.message (:result.err (io.error listen "test" "failed"))) "failed")
      "1 passed, 0 failed"
      "0 passed, 1 failed"))

(let Passed (trap-error (listener-typed.run)
               (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                         true (simple-error (error-to-string X)))))
  (output "~A~%" (if Passed "1 passed, 0 failed" "0 passed, 1 failed")))

(define listener-typed.finished?
  {http.wait-result --> boolean}
  [ok] -> true
  [pending] -> false
  [error _] -> false)

(define listener-typed.handler
  {http.request --> http.response}
  Q -> (http.response 200 [] (http.body Q)))

(define listener-typed.run
  {--> boolean}
  -> (let S (http.listen "127.0.0.1" 0 (function listener-typed.handler)
              [[max-connections 2] [shutdown-grace 0] [body-limit 1024]])
          _ (http.stop S)
       (listener-typed.finished? (http.run S))))

(define listener-typed.message
  {http.wait-result --> string}
  [error E] -> (io.error-message E)
  [ok] -> "stopped"
  [pending] -> "pending")

(output "~A~%"
  (if (= (listener-typed.message [error (io.error listen "test" "failed")]) "failed")
      "1 passed, 0 failed"
      "0 passed, 1 failed"))

(let Passed (trap-error (listener-typed.run)
               (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                         true (simple-error (error-to-string X)))))
  (output "~A~%" (if Passed "1 passed, 0 failed" "0 passed, 1 failed")))

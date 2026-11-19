\\ A zero-length body is known from the head, but its view is only available after reading.
(define request-metadata-test.completed
  {(io.result http.request) --> boolean}
  (:result.err _) -> false
  (:result.ok Request) ->
    (and (= (http.content-length Request) 0)
         (= (buffer.length (http.body Request)) 0)
         (= (http.trailers Request) [])))

(define request-metadata-test.checked
  {(io.result http.request) --> boolean}
  (:result.err _) -> false
  (:result.ok Request) ->
    (let E (io.input-buffer (buffer.new 0))
         Read (http.read-body (http.body-reader (io.reader E []) Request))
         _ (io.close E)
      (and (= (http.method Request) "GET")
           (= (http.target Request) "/")
           (= (http.version Request) "HTTP/1.1")
           (= (http.headers Request) [["host" "h"] ["x" "first"] ["x" "second"]])
           (= (http.header-values Request "X") ["first" "second"])
           (= (http.content-length Request) 0)
           (not (http.chunked? Request))
           (trap-error (do (http.body Request) false)
             (/. Error (= (error-to-string Error) "http: request body has not been read")))
           (request-metadata-test.completed Read))))

(define request-metadata-test.run
  {--> boolean}
  -> (request-metadata-test.checked
       (http.parse-request
         (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: hc#13;c#10;X: firstc#13;c#10;X: secondc#13;c#10;c#13;c#10;")
         0)))

(let Count (if (request-metadata-test.run) 1 0)
  (output "~A passed, ~A failed~%" Count (- 1 Count)))

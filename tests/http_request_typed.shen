\\ Typed metadata, body completion, response encoding and the one-request driver.
(define request-typed.handler
  {http.request --> http.response}
  Request -> (http.response 200 [["Content-Type" "application/octet-stream"]] (http.body Request)))

(define request-typed.serve
  {io.endpoint --> (io.result number)}
  E -> (http.serve-one E (function request-typed.handler)
                      [[head-limit 4096] [body-limit 1024] [write-timeout 1000]
                       [chunk-metadata-limit 1024] [trailer-limit 256]]))

(define request-typed.completed
  {(io.result http.request) --> boolean}
  [error Error] -> false
  [ok Request] ->
    (let Wire (http.encode-response Request (request-typed.handler Request) 4096 1024)
      (and (= (http.method Request) "POST") (> (buffer.length Wire) 3))))

(define request-typed.parsed
  {(io.result http.request) --> boolean}
  [error Error] -> false
  [ok Request] ->
    (let E (io.input-buffer (buffer.from-string "abc"))
         R (io.reader E [])
         B (http.body-reader R Request)
         Result (request-typed.completed (http.read-body B))
         _ (io.close E)
      Result))

(define request-typed.run
  {--> boolean}
  -> (request-typed.parsed (http.parse-request
       (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;") 3)))

(define request-typed.chunked-complete
  {(io.result http.request) --> boolean}
  [error _] -> false
  [ok Q] -> (and (http.chunked? Q) (= (http.content-length Q) 3)
                 (= (http.trailers Q) [["x" "yes"]]) (= (buffer.string (http.body Q)) "abc")))

(define request-typed.chunked-parsed
  {(io.result http.request) --> boolean}
  [error _] -> false
  [ok Q] ->
    (let E (io.input-buffer (buffer.from-string "3c#13;c#10;abcc#13;c#10;0c#13;c#10;X: yesc#13;c#10;c#13;c#10;"))
         B (http.body-reader-with (io.reader E []) Q [[chunk-count-limit 2] [trailer-limit 16]])
         Good (request-typed.chunked-complete (http.read-body B))
         _ (io.close E)
      Good))

(define request-typed.chunked
  {--> boolean}
  -> (let Parsed (http.parse-request
                    (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 3)
       (request-typed.chunked-parsed Parsed)))

\\ Two heads read in place from one reader, then the end.
(define request-typed.target
  {(grammar.read-result http.request) --> string}
  [ok Q] -> (http.target Q)
  [eof] -> "eof"
  [error E] -> (io.error-message E))

(define request-typed.read
  {--> boolean}
  -> (let R (io.reader (io.input-buffer (buffer.from-string "GET /a HTTP/1.1c#13;c#10;Host: hc#13;c#10;c#13;c#10;GET /b HTTP/1.1c#13;c#10;Host: hc#13;c#10;c#13;c#10;")) [])
          A (request-typed.target (http.read-request R 4096 0))
          B (request-typed.target (http.read-request R 4096 0))
       (= [A B (request-typed.target (http.read-request R 4096 0))] ["/a" "/b" "eof"])))

(let Count (+ (if (request-typed.run) 1 0) (if (request-typed.chunked) 1 0) (if (request-typed.read) 1 0))
  (output "~A passed, ~A failed~%" Count (- 3 Count)))

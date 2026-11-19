(define stream-typed.source
  {--> http.source}
  -> (http.source (/. Maximum D (:result.ok [])) (freeze (:result.ok []))))

(define stream-typed.response
  {http.request --> http.response}
  Q -> (http.close-after
         (http.stream-response 200 [] [chunked] (stream-typed.source))))

(define stream-typed.send
  {io.endpoint --> http.request --> deadline --> (io.result number)}
  E Q D -> (http.send-response E Q (stream-typed.response Q) D
             [[response-chunk-size 1024] [response-chunk-count-limit 4]]))

(define stream-typed.serve
  {io.endpoint --> (io.result number)}
  E -> (http.serve-connection E (function stream-typed.response)
         [[read-buffer-size 1024] [request-limit 2] [idle-timeout 100] [connection-timeout 1000]
          [response-chunk-size 1024] [response-chunk-count-limit 4]]))

(define stream-typed.sent
  {(io.result number) --> boolean}
  (:result.ok N) -> (> N 0)
  (:result.err _) -> false)

(define stream-typed.parsed
  {(io.result http.request) --> boolean}
  (:result.err _) -> false
  (:result.ok Q) ->
    (let E (io.output-buffer (buffer.new 256))
         Good (stream-typed.sent (stream-typed.send E Q (deadline.after (freeze 0) 100)))
         _ (io.close E)
      Good))

(let Good (stream-typed.parsed (http.parse-request
            (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") 0))
  (output "~A passed, ~A failed~%" (if Good 1 0) (if Good 0 1)))

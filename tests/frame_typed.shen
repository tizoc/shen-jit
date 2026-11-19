\\ Public framing and socket types, checked after loading the libraries with tc off.
(define frame-typed.text
  {(io.result (option.t frame.frame)) --> (io.result string)}
  (:result.ok [(:frame.frame Tag Payload)]) -> (result.ok (buffer.string Payload))
  (:result.ok []) -> (result.ok "end")
  (:result.err Error) -> (result.err Error))

(define frame-typed.socket
  {number --> io.endpoint}
  S -> (io.socket S "typed socket"))

(define frame-typed.shutdown
  {io.endpoint --> io.close-result}
  E -> (io.shutdown-write E))

\\ Typed code connects with socket's own calls; this loads, and calls nothing.
(define frame-typed.connect
  {string --> number --> io.endpoint}
  Host Port -> (io.socket (socket.connect Host Port) Host))

(define frame-typed.run
  {--> boolean}
  ->
    (let Wire (frame.encode 42 (buffer.from-string "typed") 8)
         E (io.input-buffer Wire)
         F (frame.reader (io.reader E [[chunk-size 1]]) 8)
         A (frame-typed.text (frame.next F))
         B (frame-typed.text (frame.next F))
         Position (frame.position F)
         _ (io.close E)
      (and (= [A B] [(:result.ok "typed") (:result.ok "end")]) (= Position 11))))

(output "~A~%" (if (frame-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))

(define http-test.check-rules
  Expected -> (let Active (included)
                   Rules [http.request.t http.response.t http.server.t http.listener.t
                          http.buffered-response.%match http.stream-description.%match
                          http.response.%http.buffered-response http.response.%http.stream-description]
                   Found (intersection Rules Active)
                (if (and (empty? (difference Expected Found)) (empty? (difference Found Expected)))
                    true (error "expected HTTP rules ~S, found ~S" Expected Found))))

(module.use [http])
(http-test.check-rules [])
(module.use [http/request])
(http-test.check-rules [http.request.t])
(module.use [http/response])
(http-test.check-rules [http.request.t http.response.t])
(module.use [http/server])
(http-test.check-rules [http.request.t http.response.t http.server.t])
(module.use [http/listener])
(http-test.check-rules [http.request.t http.response.t http.server.t http.listener.t])
(output "5 passed, 0 failed (HTTP rule scope)~%")

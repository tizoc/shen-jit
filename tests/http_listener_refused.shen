\\ Server options are listener options, not the reverse.
(define listener-refused.option {http.listener-option --> http.option} X -> X)
\\ next
(define listener-refused.response {http.listener-option --> http.response-option} X -> X)
\\ next
(define listener-refused.handler
  {--> http.handler}
  -> n->string)
\\ next
(define listener-refused.with-state
  {string --> http.request --> http.response}
  _ _ -> (http.response 200 [] (buffer.new 0)))
(define listener-refused.wrong-state
  {--> http.handler}
  -> [listener-refused.with-state 17])

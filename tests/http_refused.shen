\\ Response and chunk options are server options, not the reverse.
(define http-refused.option {http.option --> http.response-option} X -> X)
\\ next
(define http-refused.chunk {http.option --> http.chunk-option} X -> X)

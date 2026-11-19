(shen.x.namespace http
  (export from-chunk-option from-response-option)

(define from-chunk-option
  {chunk-option --> option}
  Setting -> Setting)

(define from-response-option
  {response-option --> option}
  Setting -> Setting)

)

(shen.x.namespace json
  (use buffer)
  (shadow value)
  (export from-string from-number from-array from-null parse stringify)

(define parse
  {string --> (list option) --> value}
  Text Options -> (decode (buffer.from-string Text) Options))

(define stringify
  {value --> (list option) --> string}
  Value Options -> (buffer.string (encode Value Options)))

(define from-string
  {string --> value}
  Text -> Text)

(define from-number
  {number --> value}
  Number -> Number)

(define from-array
  {(list value) --> value}
  Items -> Items)

(define from-null
  {--> value}
  -> null)

)

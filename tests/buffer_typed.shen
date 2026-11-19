\\ Load after buffer.shen/cursor.shen with (tc +).
(define buffer-typed.take
  {string --> fixnum --> string}
  Text N -> (cursor.string (cursor.new (buffer.from-string Text)) N))

(define buffer-typed.copy
  {string --> boolean}
  Text -> (let V (buffer.from-string Text)
            (buffer.equal? V (buffer.wrap (buffer.bytes V)))))

(define buffer-typed.report
  {--> string}
  -> (if (and (= (buffer-typed.take "hello" 3) "hel") (buffer-typed.copy "abc"))
         "2 passed, 0 failed"
         "0 passed, 2 failed"))

(output "~A~%" (buffer-typed.report))

\\ Load after buffer.shen/cursor.shen with (tc +).
(define buffer-typed.take
  {string --> fixnum --> string}
  Text N -> (cursor.string (cursor.new (buffer.from-string Text)) N))

(define buffer-typed.copy
  {string --> boolean}
  Text -> (let V (buffer.from-string Text)
            (buffer.equal? V (buffer.wrap (buffer.bytes V)))))

(define buffer-typed.endian
  {fixnum --> fixnum --> boolean}
  A B -> (let V (buffer.new 6)
           (do (buffer.u16-be-> V 0 A)
               (buffer.u32-be-> V 2 B)
               (and (= (buffer.u16-be V 0) A) (= (buffer.u32-be V 2) B)))))

(define buffer-typed.mutations
  {--> boolean}
  -> (let Source (buffer.from-string "xyz")
          Target (buffer.new 2)
          Builder (buffer.builder 3)
       (do (buffer.u8-> Source 0 97)
           (buffer.copy-into! Target 0 Source 0 2)
           (buffer.append! Builder Target)
           (buffer.append-byte! Builder 33)
           (= (buffer.string (buffer.finish Builder)) "ay!"))))

(define buffer-typed.report
  {--> string}
  -> (if (and (= (buffer-typed.take "hello" 3) "hel") (buffer-typed.copy "abc")
              (buffer-typed.endian 65534 4294967294) (buffer-typed.mutations))
         "4 passed, 0 failed"
         "0 passed, 4 failed"))

(output "~A~%" (buffer-typed.report))

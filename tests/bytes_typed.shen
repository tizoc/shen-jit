\\ The declared types, from typed code: a header's name, lowered, and its value without blanks.
(define bytes-test.field
  {buffer.storage --> fixnum --> fixnum --> string --> (list string)}
  B At End Blank ->
    (let Colon (bytes.find B At End 58)
         Start (bytes.span B (fx+ Colon 1) End Blank)
         Stop (bytes.span-back B Start End Blank)
         _ (bytes.lower! B At Colon)
      [(shen-jit.bytes->string B At (fx- Colon At)) (shen-jit.bytes->string B Start (fx- Stop Start))
       (bytes.hex B At (fx+ At 2)) (str (bytes.decimal B Start Stop 1000000))]))

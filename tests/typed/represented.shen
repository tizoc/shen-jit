(datatype rep.seq-rules
  X : fixnum;
  ____________________
  (rep.seq-of X) : rep.seq;

  X : rep.seq;
  ____________________
  (rep.seq-number X) : fixnum;)

(define rep.add {rep.seq --> fixnum --> rep.seq}
  S N -> (rep.seq-of (shen-jit.bit-and (fx+ (rep.seq-number S) N) 4294967295)))

\\ A loop over a value of the type: its parameter goes to a word register, as a fixnum's would.
(define rep.walk {fixnum --> rep.seq --> fixnum}
  0 S -> (rep.seq-number S)
  K S -> (rep.walk (fx- K 1) (rep.add S 1000)))

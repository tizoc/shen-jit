\\ Evaluates the cases tests/bignum_oracle.py writes, one a line: an operation and its operands, integers
\\ in base 10, apart from spaces. Prints each result on a line of its own, after a line that says so.
\\
\\   shen-jit eval -m bignum -l tests/bignum_oracle.shen -e '(bignum-oracle.run "cases.txt")'

(define bignum-oracle.run
  File -> (let B (shen-jit.string->bytes (read-file-as-string File))
            (do (output "results:~%")
                (bignum-oracle.lines B 0 (shen-jit.bytes-length B)))))

(define bignum-oracle.lines
  _ I N -> done where (>= I N)
  B I N -> (let End (bignum-oracle.find 10 B I N)
                Words (bignum-oracle.words B I End)
                _ (pr (cn (trap-error (bignum-oracle.show (bignum-oracle.apply (hd Words) (map (fn bignum-oracle.integer) (tl Words))))
                                      (/. E (cn "! " (error-to-string E))))
                          "c#10;") (stoutput))
             (bignum-oracle.lines B (+ End 1) N)))

(define bignum-oracle.find
  _ _ I N -> N where (>= I N)
  C B I N -> I where (= (shen-jit.u8 B I) C)
  C B I N -> (bignum-oracle.find C B (+ I 1) N))

(define bignum-oracle.words
  _ I End -> [] where (>= I End)
  B I End -> (let J (bignum-oracle.find 32 B I End)
               [(shen-jit.bytes->string B I (- J I)) | (bignum-oracle.words B (+ J 1) End)]))

(define bignum-oracle.integer
  S -> (bignum.of-string S))

(define bignum-oracle.show
  X -> (bignum.to-string X) where (bignum.integer? X)
  X -> (cn (bignum-oracle.show (fst X)) (cn " " (bignum-oracle.show (snd X)))) where (tuple? X)
  X -> X where (string? X)
  X -> (str X))

(define bignum-oracle.apply
  "+" [A B] -> (bignum.+ A B)
  "-" [A B] -> (bignum.- A B)
  "*" [A B] -> (bignum.* A B)
  "quotient" [A B] -> (bignum.quotient A B)
  "remainder" [A B] -> (bignum.remainder A B)
  "quotient-remainder" [A B] -> (bignum.quotient-remainder A B)
  "floor-quotient" [A B] -> (bignum.floor-quotient A B)
  "modulo" [A B] -> (bignum.modulo A B)
  "compare" [A B] -> (bignum.compare A B)
  "=" [A B] -> (= A B)
  "<" [A B] -> (bignum.< A B)
  "<=" [A B] -> (bignum.<= A B)
  ">" [A B] -> (bignum.> A B)
  ">=" [A B] -> (bignum.>= A B)
  "sign" [A] -> (bignum.sign A)
  "negate" [A] -> (bignum.negate A)
  "abs" [A] -> (bignum.abs A)
  "even?" [A] -> (bignum.even? A)
  "odd?" [A] -> (bignum.odd? A)
  "expt" [A N] -> (bignum.expt A N)
  "expt-mod" [B E M] -> (bignum.expt-mod B E M)
  "invert" [A M] -> (bignum.invert A M)
  "gcd" [A B] -> (bignum.gcd A B)
  "gcd-extended" [A B] -> (bignum.gcd-extended A B)
  "lcm" [A B] -> (bignum.lcm A B)
  "sqrt" [A] -> (bignum.sqrt A)
  "square?" [A] -> (bignum.square? A)
  "prime?" [A] -> (bignum.prime? A)
  "next-prime" [A] -> (bignum.next-prime A)
  "factorial" [N] -> (bignum.factorial N)
  "binomial" [N K] -> (bignum.binomial N K)
  "fibonacci" [N] -> (bignum.fibonacci N)
  "bit-and" [A B] -> (bignum.bit-and A B)
  "bit-or" [A B] -> (bignum.bit-or A B)
  "bit-xor" [A B] -> (bignum.bit-xor A B)
  "bit-not" [A] -> (bignum.bit-not A)
  "bit-set?" [A I] -> (bignum.bit-set? A I)
  "bit-length" [A] -> (bignum.bit-length A)
  "bit-count" [A] -> (bignum.bit-count A)
  "shift-left" [A N] -> (bignum.shift-left A N)
  "shift-right" [A N] -> (bignum.shift-right A N)
  "to-string-base" [A Base] -> (bignum.to-string-base A Base)
  "of-string-base" [A Base] -> (bignum.of-string-base (bignum.to-string-base A Base) Base)
  "to-float" [A] -> (bignum.to-float A)
  "of-float" [A] -> (bignum.of-float (bignum.to-float A))
  "fixnum?" [A] -> (shen-jit.fixnum? A))

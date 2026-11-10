\\ Operands and native loop compilation are outside the clock. Each row checks
\\ its result and reports repetitions, seconds and the Boolean consumed.

(define eq-bench.loop
  _ _ R 0 -> R
  A B _ N -> (eq-bench.loop A B (= A B) (- N 1)))

(define eq-bench.time
  Name A B N Expected ->
    (let Warm (eq-bench.loop A B false 1)
         _ (if (= Warm Expected) true (simple-error "equality warm-up differs"))
         Start (get-time unix)
         Result (eq-bench.loop A B false N)
         End (get-time unix)
         _ (if (= Result Expected) true (simple-error "equality result differs"))
      (output "eqbench|~A|~A|~A|~A~%" Name N (- End Start) Result)))

(define eq-bench.tree
  N -> [branch [leaf N] [branch [leaf (+ N 1)] [leaf (+ N 2)]]])

(define eq-bench.binary
  0 N -> [leaf N]
  Depth N -> [branch (eq-bench.binary (- Depth 1) N)
                    (eq-bench.binary (- Depth 1) (+ N 1))])

(define eq-bench.list
  0 -> []
  N -> [N | (eq-bench.list (- N 1))])

(define eq-bench.vector
  V 0 -> V
  V N -> (eq-bench.vector (vector-> V N N) (- N 1)))

(define eq-bench.mixed
  0 X -> X
  N X -> (vector-> (vector 1) 1 [(eq-bench.mixed (- N 1) X)]))

(define eq-bench.changed-bytes
  N -> (let B (shen-jit.bytes N)
         (do (shen-jit.u8! B (- N 1) 1) B)))

(define eq-bench.string
  0 -> ""
  N -> (cn "abcdefghijklmnop" (eq-bench.string (- N 1))))

(define eq-bench.byte-vector
  V 0 -> V
  V N -> (eq-bench.byte-vector (vector-> V N (shen-jit.bytes 33)) (- N 1)))

(define eq-bench.run
  Scale ->
    (let TreeA (eq-bench.tree 1) TreeB (eq-bench.tree 1)
         BinaryA (eq-bench.binary 5 1) BinaryB (eq-bench.binary 5 1)
         ListA (eq-bench.list 32) ListB (eq-bench.list 32)
         VecA (eq-bench.vector (vector 32) 32)
         VecB (eq-bench.vector (vector 32) 32)
         MixedA (eq-bench.mixed 16 1) MixedB (eq-bench.mixed 16 1)
         BytesA (shen-jit.bytes 33) BytesB (shen-jit.bytes 33)
         BytesC (eq-bench.changed-bytes 33)
         LargeA (shen-jit.bytes 1024) LargeB (shen-jit.bytes 1024)
         StringA (cn "abcdefghijklmnop" "qrstuvwxyz012345")
         StringB (cn "abcdefghijklmnop" "qrstuvwxyz012345")
         LongA (eq-bench.string 64) LongB (eq-bench.string 64)
         PayloadA (eq-bench.byte-vector (vector 8) 8)
         PayloadB (eq-bench.byte-vector (vector 8) 8)
      (do
        (eq-bench.time numeric 1 1.5 (* Scale 5000000) false)
        (eq-bench.time nested TreeA TreeB (* Scale 2000000) true)
        (eq-bench.time binary BinaryA BinaryB (* Scale 100000) true)
        (eq-bench.time list ListA ListB (* Scale 1000000) true)
        (eq-bench.time vector VecA VecB (* Scale 1000000) true)
        (eq-bench.time mixed MixedA MixedB (* Scale 300000) true)
        (eq-bench.time bytes-33 BytesA BytesB (* Scale 2000000) true)
        (eq-bench.time bytes-last-mismatch BytesA BytesC (* Scale 2000000) false)
        (eq-bench.time bytes-1024 LargeA LargeB (* Scale 1000000) true)
        (eq-bench.time string-32 StringA StringB (* Scale 2000000) true)
        (eq-bench.time string-1024 LongA LongB (* Scale 1000000) true)
        (eq-bench.time vector-of-bytes PayloadA PayloadB (* Scale 500000) true))))

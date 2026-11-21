(shen.x.namespace hll-test
  (use buffer)
  (use hyperloglog => h)
  (use shen-jit)
  (use word)
  (use words)
  (externals [word.t words.t hyperloglog.t hyperloglog.t.storage buffer.view buffer.storage])
  (export exercise command)

(define expect
  {boolean --> string --> boolean}
  true _ -> true
  false Message -> (error "HyperLogLog++ test: ~A" Message))

(define rejects?
  {(lazy A) --> boolean}
  Operation -> (trap-error (do (thaw Operation) false) (/. Error true)))

(define word64
  {fixnum --> fixnum --> word.t}
  High Low -> (word.bit-or (word.shl (word.of High) 32) (word.of Low)))

(define fill-bytes
  {buffer.view --> fixnum --> buffer.view}
  B I ->
    (if (fx>= I (buffer.length B)) B
        (fill-bytes (buffer.u8-> B I (shen-jit.bit-and (fx+ (fx* I 37) 113) 255)) (fx+ I 1))))

\\ XXH64 from the vendored C implementation, seed zero and slices at offset one.
(define hash-vectors
  {--> (list (list fixnum))}
  -> [[0 4014398263 1373170073]
      [1 4231744126 2149078842]
      [3 4056716991 2303016639]
      [4 1501681597 2174801157]
      [7 414219284 1978080144]
      [8 1926032233 3844197197]
      [15 2647966113 68805721]
      [16 3446603149 548267909]
      [23 1025442075 2386513379]
      [24 52158270 424696018]
      [31 3299404669 953209378]
      [32 1850492581 3662012720]
      [33 1200019101 1168028658]
      [63 2785793271 1891001972]
      [64 996809867 2046274567]
      [65 1249506254 2906221126]
      [255 2152952359 3810400323]
      [256 1381871353 1718085376]
      [1024 2736057363 500070628]])

(define hash-vectors-check
  {buffer.view --> (list (list fixnum)) --> boolean}
  _ [] -> true
  B [[Size High Low] | Rest] ->
    (do (expect (= (h.hash-bytes (buffer.slice B 1 Size)) (word64 High Low)) "XXH64 vector")
        (hash-vectors-check B Rest)))

\\ SplitMix64's finalizer is a permutation. Consecutive counters have distinct
\\ hashes, so a test knows the exact cardinality without keeping a set.
(define sample
  {fixnum --> word.t}
  I ->
    (let A (word.* (word.of I) (word64 2654435769 2135587861))
         B (word.* (word.bit-xor A (word.shr A 30)) (word64 3210233709 484763065))
         C (word.* (word.bit-xor B (word.shr B 27)) (word64 2496678331 321982955))
      (word.bit-xor C (word.shr C 31))))

(define add-range
  {hyperloglog.t --> fixnum --> fixnum --> hyperloglog.t}
  S I End ->
    (if (fx>= I End) S (add-range (h.add-hash! S (sample I)) (fx+ I 1) End)))

(define fill-hashes
  {words.t --> fixnum --> fixnum --> words.t}
  Words I End ->
    (if (fx>= I End) Words
        (fill-hashes (words.set Words I (sample I)) (fx+ I 1) End)))

(define hashes
  {fixnum --> words.t}
  N -> (fill-hashes (words.new N) 0 N))

(define near?
  {float --> float --> float --> boolean}
  Actual Expected Tolerance ->
    (fl<= (flmax (fl- Actual Expected) (fl- Expected Actual)) Tolerance))

(define flmax
  {float --> float --> float}
  A B -> (if (fl> A B) A B))

(define sparse-check
  {--> boolean}
  -> (let S (h.new 14)
          _ (expect (= (h.storage-bytes S) 16) "16-byte initial table")
          _ (expect (= (h.estimate S) (float 0)) "empty estimate")
          _ (add-range S 0 600)
          E (h.estimate S)
          _ (expect (h.sparse? S) "keeps 25-bit sparse precision")
          _ (expect (near? E (float 600) 0.1) "sparse precision")
          _ (add-range S 0 600)
          _ (expect (= (h.estimate S) E) "duplicate sparse input")
       (expect (fx<= (h.storage-bytes S) 16384) "bounded sparse storage")))

(define same-storage?
  {hyperloglog.t --> hyperloglog.t --> boolean}
  S T -> (buffer.equal? (buffer.wrap (hyperloglog.t.storage S))
                        (buffer.wrap (hyperloglog.t.storage T))))

(define string-check
  {--> boolean}
  -> (let Bytes (buffer.from-string "first")
          S (h.add-string! (h.new 14) "first")
          _ (h.add! S Bytes)
          _ (h.add-hash! S (h.hash-bytes Bytes))
          _ (h.add! S (buffer.from-string ""))
          _ (h.add-string! S "")
          _ (expect (near? (h.estimate S) (float 2) 0.000001) "strings, views and prehashed inputs agree")
          Dense (h.add-string! (h.add-string! (add-range (h.new 4) 0 64) "first") "")
       (expect (same-storage? Dense (h.add! (h.add! (add-range (h.new 4) 0 64) Bytes)
                                            (buffer.from-string "")))
               "a string and a view of its bytes are the same key")))

(define prehashed-range
  {buffer.view --> hyperloglog.t --> hyperloglog.t --> fixnum --> boolean}
  _ S Prehashed 96 ->
    (expect (buffer.equal? (buffer.wrap (hyperloglog.t.storage S))
                           (buffer.wrap (hyperloglog.t.storage Prehashed)))
            "byte and prehashed inserts produce the same sketch")
  B S Prehashed Length ->
    (let View (buffer.slice B 1 Length)
         _ (h.add! S View)
         _ (h.add-hash! Prehashed (h.hash-bytes View))
      (prehashed-range B S Prehashed (fx+ Length 1))))

(define prehashed-check
  {--> boolean}
  -> (let B (fill-bytes (buffer.new 96) 0)
          _ (prehashed-range B (h.new 14) (h.new 14) 0)
          Dense (add-range (h.new 4) 0 8)
          Reference (add-range (h.new 4) 0 8)
       (prehashed-range B Dense Reference 0)))

(define stamp-fixed-keys
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.storage}
  B _ _ I I -> B
  B At Width I End ->
    (let _ (if (fx>= Width 4) (shen-jit.u32! B At I) (shen-jit.u8! B At I))
      (stamp-fixed-keys B (fx+ At Width) Width (fx+ I 1) End)))

(define add-fixed-scalar
  {hyperloglog.t --> buffer.view --> fixnum --> fixnum --> fixnum --> hyperloglog.t}
  S _ _ At At -> S
  S View Width At End ->
    (add-fixed-scalar (h.add! S (buffer.slice View At Width)) View Width (fx+ At Width) End))

(define fixed-width-check
  {fixnum --> boolean}
  Width ->
    (let Count (fixnum 160)
         Length (fx* Count Width)
         B (fill-bytes (buffer.new (fx+ Length 1)) 0)
         _ (stamp-fixed-keys (buffer.owner B) 1 Width 0 Count)
         View (buffer.slice B 1 Length)
         Sparse (h.add-fixed! (h.new 14) View Width)
         Dense (h.add-fixed! (h.new 4) View Width)
         _ (expect (h.sparse? Sparse) "batch grows the sparse table")
         _ (expect (not (h.sparse? Dense)) "batch promotes and continues in dense mode")
         _ (expect (same-storage? Sparse (add-fixed-scalar (h.new 14) View Width 0 Length))
                   "batch matches scalar sparse cells")
         _ (expect (same-storage? (h.add-fixed! Dense View Width)
                                  (add-fixed-scalar (h.new 4) View Width 0 Length))
                   "dense batch and replay match scalar registers")
      true))

(define fixed-widths-check
  {(list fixnum) --> boolean}
  [] -> true
  [Width | Rest] -> (do (fixed-width-check Width) (fixed-widths-check Rest)))

(define fixed-bounds-check
  {--> boolean}
  -> (let B (buffer.new 32)
          S (h.new 14)
          _ (expect (rejects? (freeze (h.add-fixed! S B 0))) "zero key width")
          _ (expect (rejects? (freeze (h.add-fixed! S B -8))) "negative key width")
          _ (expect (rejects? (freeze (h.add-fixed! S (buffer.slice B 1 31) 8))) "partial final key")
          _ (expect (same-storage? S (h.new 14)) "invalid batches leave the sketch empty")
       (expect (same-storage? (h.add-fixed! S (buffer.slice B 32 0) 128) (h.new 14))
               "empty packed view")))

(define put-rank-extremes
  {hyperloglog.t --> fixnum --> hyperloglog.t}
  S 16 -> S
  S I -> (put-rank-extremes (h.add-hash! S (word.shl (word.of I) 60)) (fx+ I 1)))

(define extremes-check
  {--> boolean}
  -> (let S (h.new 4)
          _ (h.add-hash! S (word.shl (word.of 1) 38))
          _ (put-rank-extremes S 0)
          Expected (fl* 0.673 36893488147419103232.0)
          _ (expect (not (h.sparse? S)) "promotes at low precision")
          _ (expect (= (h.storage-bytes S) 16) "one byte per dense register")
       (expect (near? (h.estimate S) Expected (fl* Expected 0.000000000001))
               "rank 61, duplicate prefix and zero-suffix promotion")))

(define merge-check
  {--> boolean}
  -> (let Sparse1 (add-range (h.new 10) 0 55)
          Sparse2 (add-range (h.new 10) 20 95)
          Small (add-range (h.new 10) 0 95)
          _ (h.merge! Sparse1 Sparse2)
          _ (expect (= (h.estimate Sparse1) (h.estimate Small)) "sparse/sparse union")
          Dense1 (add-range (h.new 10) 10 1200)
          Dense2 (add-range (h.new 10) 950 1700)
          _ (h.merge! Dense1 Dense2)
          _ (h.merge! Dense1 Small)
          Whole (add-range (h.new 10) 0 1700)
          E (h.estimate Whole)
          _ (expect (= (h.estimate Dense1) E) "dense/dense and dense/sparse unions")
          _ (h.merge! Small Dense1)
          _ (expect (not (h.sparse? Small)) "sparse/dense promotes")
          _ (h.merge! Small Small)
          _ (expect (= (h.estimate Small) E) "sparse/dense union and idempotence")
          _ (expect (rejects? (freeze (h.merge! Small (h.new 9)))) "different precisions")
       (expect (= (h.estimate Small) E) "failed merge keeps destination")))

(define bulk-check
  {--> boolean}
  -> (let Hashes (hashes 10000)
          S (h.add-hashes! (h.new 12) Hashes)
          R (add-range (h.new 12) 0 10000)
          _ (expect (not (h.sparse? S)) "batch promotes while consuming the array")
       (expect (same-storage? S R) "scalar/batch agreement")))

(define squared-error
  {fixnum --> fixnum --> fixnum --> float --> float}
  _ 0 _ Sum -> Sum
  P Trials N Sum ->
    (let Start (fx* Trials 2000000)
         S (add-range (h.new P) Start (fx+ Start N))
         Relative (fl- (fl/ (h.estimate S) (fx->fl N)) (float 1))
      (squared-error P (fx- Trials 1) N (fl+ Sum (fl* Relative Relative)))))

(define accuracy-check
  {--> boolean}
  -> (let Mid (flsqrt (fl/ (squared-error 10 48 1200 (float 0)) (float 48)))
          Large (flsqrt (fl/ (squared-error 14 12 150000 (float 0)) (float 12)))
          S (add-range (h.new 18) 0 400000)
          _ (expect (fl< Mid 0.05) "bias-corrected range RMSE")
          _ (expect (fl< Large 0.015) "large count RMSE")
          _ (expect (= (h.storage-bytes S) 262144) "256 KiB maximum dense payload")
       (expect (near? (h.estimate S) (float 400000) (float 4000)) "precision eighteen")))

(define run-checks
  {(list (lazy boolean)) --> number --> number}
  [] N -> N
  [Check | Checks] N -> (do (thaw Check) (run-checks Checks (+ N 1))))

(define exercise
  {--> boolean}
  -> (let N (run-checks
              [(freeze (expect (rejects? (freeze (h.new 3))) "low precision"))
               (freeze (expect (rejects? (freeze (h.new 19))) "high precision"))
               (freeze (hash-vectors-check (fill-bytes (buffer.new 1025) 0) (hash-vectors)))
               (freeze (sparse-check))
               (freeze (string-check))
               (freeze (prehashed-check))
               (freeze (fixed-widths-check [1 4 7 8 9 16 31 32 33 64 127 128 129]))
               (freeze (fixed-bounds-check))
               (freeze (extremes-check))
               (freeze (merge-check))
               (freeze (bulk-check))
               (freeze (accuracy-check))]
              0)
       (do (output "~A passed, 0 failed~%" N) true)))

(define repeat-batch
  {hyperloglog.t --> words.t --> fixnum --> hyperloglog.t}
  S _ 0 -> S
  S Words Rounds -> (repeat-batch (h.add-hashes! S Words) Words (fx- Rounds 1)))

(define repeat-hash
  {buffer.view --> fixnum --> boolean}
  _ 0 -> true
  B Rounds -> (do (h.hash-bytes B) (repeat-hash B (fx- Rounds 1))))

(define repeat-add
  {hyperloglog.t --> buffer.view --> buffer.view --> fixnum --> hyperloglog.t}
  S _ _ 0 -> S
  S Short Long Rounds ->
    (do (h.add! S Short)
        (h.add! S Long)
        (h.add-string! S "a key that is a string")
        (repeat-add S Short Long (fx- Rounds 1))))

(define repeat-fixed
  {hyperloglog.t --> buffer.view --> buffer.view --> buffer.view --> fixnum --> hyperloglog.t}
  S _ _ _ 0 -> S
  S Narrow Medium Wide Rounds ->
    (do (h.add-fixed! S Narrow 8)
        (h.add-fixed! S Medium 32)
        (h.add-fixed! S Wide 128)
        (repeat-fixed S Narrow Medium Wide (fx- Rounds 1))))

(define allocation-check
  {boolean --> boolean --> boolean}
  Repeat Control ->
    (let Words (hashes 2048)
         S (h.add-hashes! (h.new 9) Words)
         _ (expect (not (h.sparse? S)) "warm batch is dense")
         _ (if Repeat (repeat-batch S Words 64) S)
         Bytes (fill-bytes (buffer.new 160) 0)
         Short (buffer.slice Bytes 1 8)
         Long (buffer.slice Bytes 1 159)
         Small (h.new 9)
         _ (repeat-add Small Short Long 1)
         _ (if Repeat (repeat-add Small Short Long 8) Small)
         _ (if Repeat (repeat-add S Short Long 8) S)
         Narrow (buffer.slice Bytes 1 16)
         Medium (buffer.slice Bytes 1 64)
         Wide (buffer.slice Bytes 1 128)
         _ (repeat-fixed Small Narrow Medium Wide 1)
         _ (if Repeat (repeat-fixed Small Narrow Medium Wide 8) Small)
         _ (if Repeat (repeat-fixed S Narrow Medium Wide 8) S)
         \\ Each hash boxes its word, whatever the key's length.
         _ (repeat-hash (if Repeat Long Short) 8)
         _ (if Control (buffer.length (buffer.new 7)) (fixnum 7))
      (do (output "HyperLogLog++ checks passed~%") true)))

\\ Times each way in, in ns a key, over 2,048 keys of 32 bytes, and a merge: bench, passed to the saved test.
(define key-views
  {buffer.view --> fixnum --> fixnum --> (vector buffer.view) --> (vector buffer.view)}
  B Width I Keys ->
    (if (fx> I (fxlimit Keys)) Keys
        (do (fxvector-> Keys I (buffer.slice B (fx* (fx- I 1) Width) Width))
            (key-views B Width (fx+ I 1) Keys))))

(define key-strings
  {(vector buffer.view) --> fixnum --> (vector string) --> (vector string)}
  Views I Keys ->
    (if (fx> I (fxlimit Keys)) Keys
        (do (fxvector-> Keys I (buffer.string (fx<-vector Views I)))
            (key-strings Views (fx+ I 1) Keys))))

(define add-views
  {hyperloglog.t --> (vector buffer.view) --> fixnum --> hyperloglog.t}
  S Keys I -> (if (fx> I (fxlimit Keys)) S (add-views (h.add! S (fx<-vector Keys I)) Keys (fx+ I 1))))

(define add-strings
  {hyperloglog.t --> (vector string) --> fixnum --> hyperloglog.t}
  S Keys I ->
    (if (fx> I (fxlimit Keys)) S (add-strings (h.add-string! S (fx<-vector Keys I)) Keys (fx+ I 1))))

(define rounds
  {(lazy A) --> fixnum --> boolean}
  _ 0 -> true
  F N -> (do (thaw F) (rounds F (fx- N 1))))

(define timed
  {string --> string --> number --> (lazy A) --> boolean}
  Name Unit Per F ->
    (let Start (get-time unix)
         _ (rounds F 2000)
         Stop (get-time unix)
      (do (output "~A: ~A ns/~A~%" Name (/ (* 1000000000 (- Stop Start)) (* Per 2000)) Unit) true)))

(define bench
  {--> boolean}
  -> (let B (fill-bytes (buffer.new (fx* 2048 32)) 0)
          _ (stamp-fixed-keys (buffer.owner B) 0 32 0 2048)
          Views (key-views B 32 1 (vector 2048))
          Strings (key-strings Views 1 (vector 2048))
          Words (hashes 2048)
          Dense (h.add-fixed! (h.add-hashes! (h.new 14) (hashes 100000)) B 32)
          Other (h.add-hashes! (h.new 14) (hashes 50000))
       (do (timed "prehashed, dense" "key" 2048 (freeze (h.add-hashes! Dense Words)))
           (timed "views, dense" "key" 2048 (freeze (add-views Dense Views 1)))
           (timed "strings, dense" "key" 2048 (freeze (add-strings Dense Strings 1)))
           (timed "packed, dense" "key" 2048 (freeze (h.add-fixed! Dense B 32)))
           (timed "prehashed, sparse from empty" "key" 2048 (freeze (h.add-hashes! (h.new 14) Words)))
           (timed "views, sparse from empty" "key" 2048 (freeze (add-views (h.new 14) Views 1)))
           (timed "packed, sparse from empty" "key" 2048 (freeze (h.add-fixed! (h.new 14) B 32)))
           (timed "merge of a dense sketch, precision 14" "merge" 1 (freeze (h.merge! Dense Other))))))

(define command
  {string --> boolean}
  "0" -> (allocation-check false false)
  "1" -> (allocation-check true false)
  "2" -> (allocation-check true true)
  "bench" -> (bench)
  _ -> (exercise))

)

(shen.x.namespace hyperloglog
  (use buffer)
  (use shen-jit)
  (externals [buffer.storage])
  (export estimate)

\\ Precision-specific linear-counting cutoffs from the HLL++ paper's appendix.
(define cutoff
  {fixnum --> fixnum}
  4 -> 10
  5 -> 20
  6 -> 40
  7 -> 80
  8 -> 220
  9 -> 400
  10 -> 900
  11 -> 1800
  12 -> 3100
  13 -> 6500
  14 -> 11500
  15 -> 20000
  16 -> 50000
  17 -> 120000
  18 -> 350000)

(define alpha
  {fixnum --> float --> float}
  4 _ -> 0.673
  5 _ -> 0.697
  6 _ -> 0.709
  _ M -> (fl/ 0.7213 (fl+ (float 1) (fl/ 1.079 M))))

\\ Atanh's odd-power series in Horner form. Range reduction keeps |X| <= 1/3,
\\ and taking the integer difference first preserves accuracy for sparse counts.
(define atanh-series
  {float --> fixnum --> float --> float}
  X2 1 Acc -> (fl+ (float 1) (fl* X2 Acc))
  X2 Denom Acc ->
    (atanh-series X2 (fx- Denom 2) (fl+ (fl/ (float 1) (fx->fl Denom)) (fl* X2 Acc))))

(define log-ratio
  {fixnum --> fixnum --> fixnum --> float}
  N D Twos ->
    (if (fx>= N (fx+ D D)) (log-ratio N (fx+ D D) (fx+ Twos 1))
        (let X (fl/ (fx->fl (fx- N D)) (fx->fl (fx+ N D)))
             Rest (fl* (fl+ X X) (atanh-series (fl* X X) 31 (float 0)))
          (fl+ (fl* 0.6931471805599453 (fx->fl Twos)) Rest))))

(define linear-count
  {fixnum --> fixnum --> float}
  M Empty -> (fl* (fx->fl M) (log-ratio M Empty 0)))

(define hex-value
  {fixnum --> fixnum}
  Digit -> (if (fx<= Digit 57) (fx- Digit 48) (fx- Digit 87)))

(define decode-knot
  {buffer.storage --> fixnum --> fixnum --> fixnum --> float}
  B At End Value ->
    (if (= At End) (fl/ (fx->fl (fx- Value 1048576)) (float 1048576))
        (decode-knot B (fx+ At 1) End
          (fx+ (shen-jit.shift-left Value 4) (hex-value (shen-jit.u8 B At))))))

(define bias-knot
  {fixnum --> fixnum --> float}
  P I ->
    (let B (shen-jit.string->bytes (bias-block P (fxquotient I 12)))
         At (fx* 6 (fxremainder I 12))
      (decode-knot B At (fx+ At 6) 0)))

(define bias
  {fixnum --> float --> float}
  P Raw ->
    (let Pos (fl* (fl- Raw 0.5) (float 16))
         I (fl->fx Pos)
         Weight (fl- Pos (fx->fl I))
         Lower (bias-knot P I)
         Upper (bias-knot P (fx+ I 1))
      (fl+ Lower (fl* Weight (fl- Upper Lower)))))

(define corrected
  {fixnum --> fixnum --> float --> float}
  P Registers Mass ->
    (let M (fx->fl Registers)
         Raw (fl/ (fl* (alpha P M) M) Mass)
      (fl* M (if (fl< Raw (float 5)) (fl- Raw (bias P Raw)) Raw))))

(define dense-result
  {fixnum --> fixnum --> fixnum --> float --> float}
  P Registers Empty Mass ->
    (if (= Empty 0) (corrected P Registers Mass)
        (let Linear (linear-count Registers Empty)
          (if (fl<= Linear (fx->fl (cutoff P))) Linear (corrected P Registers Mass)))))

\\ Factoring out the first bit keeps the integer denominator a positive fixnum,
\\ even at the largest possible rank (61 at precision four).
(define mass-at
  {fixnum --> float}
  0 -> (float 1)
  Rank -> (fl/ 0.5 (fx->fl (shen-jit.shift-left 1 (fx- Rank 1)))))

(define dense-estimate
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> float --> float}
  B P At End Empty Mass ->
    (if (fx>= At End) (dense-result P End Empty Mass)
        (let Rank (shen-jit.u8 B At)
          (dense-estimate B P (fx+ At 1) End
            (if (= Rank 0) (fx+ Empty 1) Empty) (fl+ Mass (mass-at Rank))))))

(define estimate
  {t --> float}
  S ->
    (if (sparse? S)
        (let M (shen-jit.shift-left 1 (sparse-precision))
          (linear-count M (fx- M (t.occupied S))))
        (dense-estimate (t.storage S) (t.precision S) 0 (t.registers S) 0 (float 0))))
)

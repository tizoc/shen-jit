\\ The programs of numeric.shen as typed Shen, which a typed build compiles with floats in registers
\\ where a definition calls no other (docs/modules.md, Typed programs). make bench-numeric builds
\\ numeric-typed.shenmod and compares it with numeric.shen, numeric-raw.shen and numeric.c, whose
\\ checks it must give to the last digit. Arithmetic is by kind (docs/numbers.md), and a float with no
\\ fraction is (float N), as the reader makes 1.0 the integer 1.

\\ ---------------------------------------------------------------------------
\\ Dense matrix multiplication.

(define mat.at {fixnum --> fixnum --> fixnum --> fixnum} N I J -> (fx* 8 (fx+ (fx* I N) J)))

(define mat.dot {buffer.storage --> fixnum --> buffer.storage --> fixnum --> fixnum --> fixnum --> float --> float}
  A AI B BI End Step Acc -> Acc where (fx>= AI End)
  A AI B BI End Step Acc -> (mat.dot A (fx+ AI 8) B (fx+ BI Step) End Step
                                     (fl+ Acc (fl* (shen-jit.f64 A AI) (shen-jit.f64 B BI)))))

(define mat.row {buffer.storage --> buffer.storage --> buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> symbol}
  _ _ _ _ _ J N -> done where (fx>= J N)
  A B C I Bytes J N -> (let RowStart (fx* I Bytes)
                         (do (shen-jit.f64! C (fx+ RowStart (fx* J 8))
                                            (mat.dot A RowStart B (fx* J 8) (fx+ RowStart Bytes) Bytes (float 0)))
                             (mat.row A B C I Bytes (fx+ J 1) N))))

(define mat.rows {buffer.storage --> buffer.storage --> buffer.storage --> fixnum --> fixnum --> fixnum --> symbol}
  _ _ _ I _ N -> done where (fx>= I N)
  A B C I Bytes N -> (do (mat.row A B C I Bytes 0 N) (mat.rows A B C (fx+ I 1) Bytes N)))

(define mat.trace {buffer.storage --> fixnum --> fixnum --> float --> float}
  _ I N Acc -> Acc where (fx>= I N)
  C I N Acc -> (mat.trace C (fx+ I 1) N (fl+ Acc (shen-jit.f64 C (mat.at N I I)))))

\\ ---------------------------------------------------------------------------
\\ The Mandelbrot set.

(define mand.iter {float --> float --> float --> float --> fixnum --> fixnum --> fixnum}
  _ _ _ _ Limit Limit -> Limit
  X Y CX CY N Limit -> (let XX (fl* X X)
                            YY (fl* Y Y)
                         (if (fl> (fl+ XX YY) (float 4))
                             N
                             (mand.iter (fl+ (fl- XX YY) CX) (fl+ (fl* (float 2) (fl* X Y)) CY) CX CY
                                        (fx+ N 1) Limit))))

(define mand.row {float --> float --> fixnum --> fixnum --> fixnum --> float --> fixnum --> fixnum}
  _ _ _ I Size _ Acc -> Acc where (fx>= I Size)
  CY Step Limit I Size X0 Acc
  -> (mand.row CY Step Limit (fx+ I 1) Size X0
               (fx+ Acc (mand.iter (float 0) (float 0) (fl+ X0 (fl* (fx->fl I) Step)) CY 0 Limit))))

(define mand.rows {float --> fixnum --> fixnum --> fixnum --> float --> fixnum --> fixnum}
  _ _ J Size _ Acc -> Acc where (fx>= J Size)
  Step Limit J Size Y0 Acc -> (mand.rows Step Limit (fx+ J 1) Size Y0
                                         (mand.row (fl+ Y0 (fl* (fx->fl J) Step)) Step Limit 0 Size (float -2) Acc)))

\\ ---------------------------------------------------------------------------
\\ Spectral norm.

(define sn.a {fixnum --> fixnum --> float}
  I J -> (fl/ (float 1) (fl+ (fl* (fl* 0.5 (fx->fl (fx+ I J))) (fx->fl (fx+ I (fx+ J 1)))) (fx->fl (fx+ I 1)))))

(define sn.at-row {buffer.storage --> fixnum --> boolean --> fixnum --> fixnum --> float --> float}
  _ _ _ J N Acc -> Acc where (fx>= J N)
  V I T J N Acc -> (sn.at-row V I T (fx+ J 1) N
                              (fl+ Acc (fl* (if T (sn.a J I) (sn.a I J)) (shen-jit.f64 V (fx* J 8))))))

(define sn.times {buffer.storage --> buffer.storage --> boolean --> fixnum --> fixnum --> symbol}
  _ _ _ I N -> done where (fx>= I N)
  V Out T I N -> (do (shen-jit.f64! Out (fx* I 8) (sn.at-row V I T 0 N (float 0)))
                     (sn.times V Out T (fx+ I 1) N)))

(define sn.at-a-t {buffer.storage --> buffer.storage --> buffer.storage --> fixnum --> symbol}
  V Out Tmp N -> (do (sn.times V Tmp false 0 N)
                     (sn.times Tmp Out true 0 N)))

(define sn.power {fixnum --> buffer.storage --> buffer.storage --> buffer.storage --> fixnum --> symbol}
  0 _ _ _ _ -> done
  K U V Tmp N -> (do (sn.at-a-t U V Tmp N)
                     (sn.at-a-t V U Tmp N)
                     (sn.power (fx- K 1) U V Tmp N)))

(define sn.ones {buffer.storage --> fixnum --> fixnum --> symbol}
  _ I N -> done where (fx>= I N)
  U I N -> (do (shen-jit.f64! U (fx* I 8) (float 1)) (sn.ones U (fx+ I 1) N)))

(define sn.dot {buffer.storage --> buffer.storage --> fixnum --> fixnum --> float --> float}
  _ _ I N Acc -> Acc where (fx>= I N)
  A B I N Acc -> (sn.dot A B (fx+ I 1) N (fl+ Acc (fl* (shen-jit.f64 A (fx* I 8)) (shen-jit.f64 B (fx* I 8))))))

\\ ---------------------------------------------------------------------------
\\ N bodies, x y z vx vy vz mass each.

\\ A field of the body at offset O, its index times 56. The loops step offsets by 56, as the
\\ hand-written version does and C's compiler does with its indices.
(define nb.at {buffer.storage --> fixnum --> fixnum --> float} B O F -> (shen-jit.f64 B (fx+ O (fx* F 8))))
(define nb.set {buffer.storage --> fixnum --> fixnum --> float --> buffer.storage} B O F X -> (shen-jit.f64! B (fx+ O (fx* F 8)) X))
(define nb.get {buffer.storage --> fixnum --> fixnum --> float} B I F -> (nb.at B (fx* I 56) F))
(define nb.put {buffer.storage --> fixnum --> fixnum --> float --> buffer.storage} B I F X -> (nb.set B (fx* I 56) F X))

(define nb.pair {buffer.storage --> fixnum --> fixnum --> float --> buffer.storage}
  B OI OJ Dt -> (let Dx (fl- (nb.at B OI 0) (nb.at B OJ 0))
                     Dy (fl- (nb.at B OI 1) (nb.at B OJ 1))
                     Dz (fl- (nb.at B OI 2) (nb.at B OJ 2))
                     D2 (fl+ (fl+ (fl* Dx Dx) (fl* Dy Dy)) (fl* Dz Dz))
                     Mag (fl/ Dt (fl* D2 (flsqrt D2)))
                     MI (fl* (nb.at B OI 6) Mag)
                     MJ (fl* (nb.at B OJ 6) Mag)
                  (do (nb.set B OI 3 (fl- (nb.at B OI 3) (fl* Dx MJ)))
                      (nb.set B OI 4 (fl- (nb.at B OI 4) (fl* Dy MJ)))
                      (nb.set B OI 5 (fl- (nb.at B OI 5) (fl* Dz MJ)))
                      (nb.set B OJ 3 (fl+ (nb.at B OJ 3) (fl* Dx MI)))
                      (nb.set B OJ 4 (fl+ (nb.at B OJ 4) (fl* Dy MI)))
                      (nb.set B OJ 5 (fl+ (nb.at B OJ 5) (fl* Dz MI))))))

(define nb.with {buffer.storage --> fixnum --> fixnum --> fixnum --> float --> symbol}
  _ _ J N _ -> done where (fx>= J N)
  B I J N Dt -> (do (nb.pair B I J Dt) (nb.with B I (fx+ J 56) N Dt)))

(define nb.forces {buffer.storage --> fixnum --> fixnum --> float --> symbol}
  _ I N _ -> done where (fx>= I N)
  B I N Dt -> (do (nb.with B I (fx+ I 56) N Dt) (nb.forces B (fx+ I 56) N Dt)))

(define nb.move {buffer.storage --> fixnum --> fixnum --> float --> symbol}
  _ O End _ -> done where (fx>= O End)
  B O End Dt -> (do (nb.set B O 0 (fl+ (nb.at B O 0) (fl* Dt (nb.at B O 3))))
                    (nb.set B O 1 (fl+ (nb.at B O 1) (fl* Dt (nb.at B O 4))))
                    (nb.set B O 2 (fl+ (nb.at B O 2) (fl* Dt (nb.at B O 5))))
                    (nb.move B (fx+ O 56) End Dt)))

(define nb.steps {fixnum --> buffer.storage --> fixnum --> float --> symbol}
  0 _ _ _ -> done
  K B N Dt -> (let End (fx* N 56)
                (do (nb.forces B 0 End Dt) (nb.move B 0 End Dt) (nb.steps (fx- K 1) B N Dt))))

\\ ---------------------------------------------------------------------------
\\ Red-black relaxation on a grid.

(define heat.cells {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> symbol}
  _ _ I End _ -> done where (fx>= I End)
  G W I End Stride -> (do (shen-jit.f64! G I
                                         (fl* 0.25 (fl+ (fl+ (shen-jit.f64 G (fx- I 8)) (shen-jit.f64 G (fx+ I 8)))
                                                        (fl+ (shen-jit.f64 G (fx- I Stride)) (shen-jit.f64 G (fx+ I Stride))))))
                          (heat.cells G W (fx+ I 16) End Stride)))

(define heat.rows {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> symbol}
  _ _ J H _ _ -> done where (fx>= J (fx- H 1))
  G W J H Stride Colour
  -> (let Odd (shen-jit.bit-and (fx+ J Colour) 1)
       (do (heat.cells G W (fx+ (fx* J Stride) (fx* 8 (fx+ 1 Odd))) (fx+ (fx* J Stride) (fx- Stride 8)) Stride)
           (heat.rows G W (fx+ J 1) H Stride Colour))))

(define heat.sweeps {fixnum --> buffer.storage --> fixnum --> fixnum --> fixnum --> symbol}
  0 _ _ _ _ -> done
  K G W H Stride -> (do (heat.rows G W 1 H Stride 0)
                        (heat.rows G W 1 H Stride 1)
                        (heat.sweeps (fx- K 1) G W H Stride)))

(define heat.edge {buffer.storage --> fixnum --> fixnum --> symbol}
  _ I End -> done where (fx>= I End)
  G I End -> (do (shen-jit.f64! G I (float 100)) (heat.edge G (fx+ I 8) End)))

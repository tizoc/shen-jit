\\ Numeric programs written as ordinary Shen, with boxed floats in foreign memory or in variables,
\\ for make bench-numeric to compare with numeric-raw.shen, the same with float registers, and with
\\ numeric.c. Each prints its time and a check, which all three must agree on to the last digit.

(define now -> (get-time unix))

(define report
  Name Check T0 -> (output "~A ~A s check ~A~%" Name (- (now) T0) Check))

\\ ---------------------------------------------------------------------------
\\ Dense matrix multiplication: the innermost loop reads two floats and adds their product.

(define mat.at N I J -> (* 8 (+ (* I N) J)))

(define mat.fill-row
  _ _ _ J N -> done where (>= J N)
  M I F J N -> (do (shen-jit.f64! M (mat.at N I J) (F I J))
                   (mat.fill-row M I F (+ J 1) N)))

(define mat.fill
  _ _ I N -> done where (>= I N)
  M F I N -> (do (mat.fill-row M I F 0 N) (mat.fill M F (+ I 1) N)))

(define mat.dot
  A AI B BI End Step Acc -> Acc where (>= AI End)
  A AI B BI End Step Acc -> (mat.dot A (+ AI 8) B (+ BI Step) End Step
                                     (+ Acc (* (shen-jit.f64 A AI) (shen-jit.f64 B BI)))))

(define mat.row
  _ _ _ _ _ J N -> done where (>= J N)
  A B C I Bytes J N -> (let RowStart (* I Bytes)
                         (do (shen-jit.f64! C (+ RowStart (* J 8))
                                            (mat.dot A RowStart B (* J 8) (+ RowStart Bytes) Bytes 0.0))
                             (mat.row A B C I Bytes (+ J 1) N))))

(define mat.rows
  _ _ _ I _ N -> done where (>= I N)
  A B C I Bytes N -> (do (mat.row A B C I Bytes 0 N) (mat.rows A B C (+ I 1) Bytes N)))

(define mat.trace
  _ I N Acc -> Acc where (>= I N)
  C I N Acc -> (mat.trace C (+ I 1) N (+ Acc (shen-jit.f64 C (mat.at N I I)))))

(define matmul
  N -> (let Bytes (* N 8)
            A (memory.alloc (* N Bytes))
            B (memory.alloc (* N Bytes))
            C (memory.alloc (* N Bytes))
            _ (mat.fill A (/. I J (/ 1.0 (+ I J 1))) 0 N)
            _ (mat.fill B (/. I J (+ 1.0 (* 0.5 (- I J)))) 0 N)
            T0 (now)
            _ (mat.rows A B C 0 Bytes N)
         (report "matmul" (mat.trace C 0 N 0.0) T0)))

\\ ---------------------------------------------------------------------------
\\ The Mandelbrot set: no memory at all, only floats in variables.

(define mand.iter
  _ _ _ _ Limit Limit -> Limit
  X Y CX CY N Limit -> (let XX (* X X)
                            YY (* Y Y)
                         (if (> (+ XX YY) 4.0)
                             N
                             (mand.iter (+ (- XX YY) CX) (+ (* 2.0 (* X Y)) CY) CX CY (+ N 1) Limit))))

(define mand.row
  _ _ _ I Size _ Acc -> Acc where (>= I Size)
  CY Step Limit I Size X0 Acc -> (mand.row CY Step Limit (+ I 1) Size X0
                                           (+ Acc (mand.iter 0.0 0.0 (+ X0 (* I Step)) CY 0 Limit))))

(define mand.rows
  _ _ J Size _ Acc -> Acc where (>= J Size)
  Step Limit J Size Y0 Acc -> (mand.rows Step Limit (+ J 1) Size Y0
                                         (mand.row (+ Y0 (* J Step)) Step Limit 0 Size -2.0 Acc)))

(define mandelbrot
  Size Limit -> (let T0 (now)
                     Check (mand.rows (/ 3.0 Size) Limit 0 Size -1.5 0)
                  (report "mandelbrot" Check T0)))

\\ ---------------------------------------------------------------------------
\\ Spectral norm: a function call for each matrix element, and memory for the vectors.

(define sn.a I J -> (/ 1.0 (+ (* (* 0.5 (+ I J)) (+ I J 1)) I 1)))

(define sn.at-row
  _ _ _ J N Acc -> Acc where (>= J N)
  V I T J N Acc -> (sn.at-row V I T (+ J 1) N
                              (+ Acc (* (if T (sn.a J I) (sn.a I J)) (shen-jit.f64 V (* J 8))))))

(define sn.times
  _ _ _ I N -> done where (>= I N)
  V Out T I N -> (do (shen-jit.f64! Out (* I 8) (sn.at-row V I T 0 N 0.0))
                     (sn.times V Out T (+ I 1) N)))

(define sn.at-a-t
  V Out Tmp N -> (do (sn.times V Tmp false 0 N)
                     (sn.times Tmp Out true 0 N)))

(define sn.power
  0 _ _ _ _ -> done
  K U V Tmp N -> (do (sn.at-a-t U V Tmp N)
                     (sn.at-a-t V U Tmp N)
                     (sn.power (- K 1) U V Tmp N)))

(define sn.ones
  _ I N -> done where (>= I N)
  U I N -> (do (shen-jit.f64! U (* I 8) 1.0) (sn.ones U (+ I 1) N)))

(define sn.dot
  _ _ I N Acc -> Acc where (>= I N)
  A B I N Acc -> (sn.dot A B (+ I 1) N (+ Acc (* (shen-jit.f64 A (* I 8)) (shen-jit.f64 B (* I 8))))))

(define spectral
  N -> (let U (memory.alloc (* N 8))
            V (memory.alloc (* N 8))
            Tmp (memory.alloc (* N 8))
            _ (sn.ones U 0 N)
            T0 (now)
            _ (sn.power 10 U V Tmp N)
         (report "spectral" (/ (sn.dot U V 0 N 0.0) (sn.dot V V 0 N 0.0)) T0)))

\\ ---------------------------------------------------------------------------
\\ N bodies: an array of structs in memory, each 7 floats, updated in place: x y z vx vy vz mass.
\\ The square root is C's, through the FFI, as a Shen program would have it.

(shen-jit.library numeric.libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
(define-foreign numeric.sqrt numeric.libm "sqrt" (double) --> double)

(define nb.get B I F -> (shen-jit.f64 B (+ (* I 56) (* F 8))))
(define nb.put B I F X -> (shen-jit.f64! B (+ (* I 56) (* F 8)) X))

(define nb.pair
  B I J Dt -> (let Dx (- (nb.get B I 0) (nb.get B J 0))
                   Dy (- (nb.get B I 1) (nb.get B J 1))
                   Dz (- (nb.get B I 2) (nb.get B J 2))
                   D2 (+ (+ (* Dx Dx) (* Dy Dy)) (* Dz Dz))
                   Mag (/ Dt (* D2 (numeric.sqrt D2)))
                   MI (* (nb.get B I 6) Mag)
                   MJ (* (nb.get B J 6) Mag)
                (do (nb.put B I 3 (- (nb.get B I 3) (* Dx MJ)))
                    (nb.put B I 4 (- (nb.get B I 4) (* Dy MJ)))
                    (nb.put B I 5 (- (nb.get B I 5) (* Dz MJ)))
                    (nb.put B J 3 (+ (nb.get B J 3) (* Dx MI)))
                    (nb.put B J 4 (+ (nb.get B J 4) (* Dy MI)))
                    (nb.put B J 5 (+ (nb.get B J 5) (* Dz MI))))))

(define nb.with
  _ _ J N _ -> done where (>= J N)
  B I J N Dt -> (do (nb.pair B I J Dt) (nb.with B I (+ J 1) N Dt)))

(define nb.forces
  _ I N _ -> done where (>= I N)
  B I N Dt -> (do (nb.with B I (+ I 1) N Dt) (nb.forces B (+ I 1) N Dt)))

(define nb.move
  _ I N _ -> done where (>= I N)
  B I N Dt -> (do (nb.put B I 0 (+ (nb.get B I 0) (* Dt (nb.get B I 3))))
                  (nb.put B I 1 (+ (nb.get B I 1) (* Dt (nb.get B I 4))))
                  (nb.put B I 2 (+ (nb.get B I 2) (* Dt (nb.get B I 5))))
                  (nb.move B (+ I 1) N Dt)))

(define nb.steps
  0 _ _ _ -> done
  K B N Dt -> (do (nb.forces B 0 N Dt) (nb.move B 0 N Dt) (nb.steps (- K 1) B N Dt)))

(define nb.place
  _ I N -> done where (>= I N)
  B I N -> (do (nb.put B I 0 (* 1.25 I))
               (nb.put B I 1 (- 7.0 (* 0.5 I)))
               (nb.put B I 2 (* 0.25 (* I I)))
               (nb.put B I 3 (* 0.125 (- 3.0 I)))
               (nb.put B I 4 (* 0.0625 I))
               (nb.put B I 5 (- 0.03125 (* 0.01 I)))
               (nb.put B I 6 (+ 1.0 (* 0.5 I)))
               (nb.place B (+ I 1) N)))

(define nbody
  N Steps -> (let B (memory.alloc (* N 56))
                  _ (nb.place B 0 N)
                  T0 (now)
                  _ (nb.steps Steps B N 0.01)
               (report "nbody" (nb.get B 0 0) T0)))

\\ ---------------------------------------------------------------------------
\\ Red-black relaxation on a grid in memory: reads neighbours and stores in one loop.

(define heat.cells
  _ _ I End _ -> done where (>= I End)
  G W I End Stride -> (do (shen-jit.f64! G I
                                         (* 0.25 (+ (+ (shen-jit.f64 G (- I 8)) (shen-jit.f64 G (+ I 8)))
                                                    (+ (shen-jit.f64 G (- I Stride)) (shen-jit.f64 G (+ I Stride))))))
                          (heat.cells G W (+ I 16) End Stride)))

(define heat.rows
  _ _ J H _ _ -> done where (>= J (- H 1))
  G W J H Stride Colour
  -> (let Odd (shen-jit.bit-and (+ J Colour) 1)
       (do (heat.cells G W (+ (* J Stride) (* 8 (+ 1 Odd))) (+ (* J Stride) (- Stride 8)) Stride)
           (heat.rows G W (+ J 1) H Stride Colour))))

(define heat.sweeps
  0 _ _ _ _ -> done
  K G W H Stride -> (do (heat.rows G W 1 H Stride 0)
                        (heat.rows G W 1 H Stride 1)
                        (heat.sweeps (- K 1) G W H Stride)))

(define heat.edge
  _ I End -> done where (>= I End)
  G I End -> (do (shen-jit.f64! G I 100.0) (heat.edge G (+ I 8) End)))

(define heat
  W H Sweeps -> (let Stride (* W 8)
                     G (memory.alloc (* H Stride))
                     _ (heat.edge G 0 Stride)
                     T0 (now)
                     _ (heat.sweeps Sweeps G W H Stride)
                  (report "heat" (shen-jit.f64 G (+ (* (/ H 2) Stride) (* 8 (/ W 2)))) T0)))

\\ ---------------------------------------------------------------------------

(matmul 400)
(mandelbrot 400 200)
(spectral 500)
(nbody 64 200)
(heat 512 512 200)

\\ What numeric-typed.shen leaves untyped: setting up, timing and reporting, as in numeric.shen.

(define now -> (get-time unix))

(define report
  Name Check T0 -> (output "~A ~A s check ~A~%" Name (- (now) T0) Check))

(define mat.fill-row
  _ _ _ J N -> done where (>= J N)
  M I F J N -> (do (shen-jit.f64! M (mat.at N I J) (F I J))
                   (mat.fill-row M I F (+ J 1) N)))

(define mat.fill
  _ _ I N -> done where (>= I N)
  M F I N -> (do (mat.fill-row M I F 0 N) (mat.fill M F (+ I 1) N)))

(define matmul
  N -> (let Bytes (* N 8)
            A (memory.alloc (* N Bytes))
            B (memory.alloc (* N Bytes))
            C (memory.alloc (* N Bytes))
            _ (mat.fill A (/. I J (/ 1.0 (+ I J 1))) 0 N)
            _ (mat.fill B (/. I J (+ 1.0 (* 0.5 (- I J)))) 0 N)
            T0 (now)
            _ (mat.rows A B C 0 Bytes N)
         (report "matmul" (mat.trace C 0 N (float 0)) T0)))

(define mandelbrot
  Size Limit -> (let T0 (now)
                     Check (mand.rows (/ 3.0 Size) Limit 0 Size -1.5 0)
                  (report "mandelbrot" Check T0)))

(define spectral
  N -> (let U (memory.alloc (* N 8))
            V (memory.alloc (* N 8))
            Tmp (memory.alloc (* N 8))
            _ (sn.ones U 0 N)
            T0 (now)
            _ (sn.power 10 U V Tmp N)
         (report "spectral" (/ (sn.dot U V 0 N (float 0)) (sn.dot V V 0 N (float 0))) T0)))

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

(define heat
  W H Sweeps -> (let Stride (* W 8)
                     G (memory.alloc (* H Stride))
                     _ (heat.edge G 0 Stride)
                     T0 (now)
                     _ (heat.sweeps Sweeps G W H Stride)
                  (report "heat" (shen-jit.f64 G (+ (* (/ H 2) Stride) (* 8 (/ W 2)))) T0)))

(define numeric-typed-main
  -> (do (matmul 400) (mandelbrot 400 200) (spectral 500) (nbody 64 200) (heat 512 512 200)))

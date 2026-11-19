\\ What trace-typed.shen leaves untyped: setting up the scene, timing and reporting, as in trace.shen.

(define trace.spheres
  -> [[-1000.5 0 0 1000 0.75 0.25 0.25 0 0 0 0]         \\ the left wall
      [1000.5 0 0 1000 0.25 0.25 0.75 0 0 0 0]          \\ the right wall
      [0 -1000.5 0 1000 0.75 0.75 0.75 0 0 0 0]         \\ the floor
      [0 1000.5 0 1000 0.75 0.75 0.75 0 0 0 0]          \\ the ceiling
      [0 0 -1001 1000 0.75 0.75 0.75 0 0 0 0]           \\ the back wall
      [0 0 1003 1000 0 0 0 0 0 0 0]                     \\ behind the camera
      [-0.25 -0.25 -0.5 0.25 0.875 0.875 0.875 0 0 0 1] \\ a mirror
      [0.25 -0.3125 -0.25 0.1875 0.25 0.75 0.25 0 0 0 0] \\ a green ball
      [0 1 -0.5 0.625 0 0 0 6 6 6 0]])                  \\ the light

(define trace.put-floats
  _ _ [] -> done
  M I [X | Xs] -> (do (shen-jit.f64! M I (* 1.0 X)) (trace.put-floats M (+ I 8) Xs)))

(define trace.put-spheres
  _ _ [] -> done
  M I [S | Ss] -> (do (trace.put-floats M I S) (trace.put-spheres M (+ I 88) Ss)))

(define trace.seed
  M High Low -> (shen-jit.u32! (shen-jit.u32! M 0 Low) 4 High))

(define trace.hex
  _ 0 -> ""
  V N -> (cn (trace.hex (shen-jit.shift-right V 4) (- N 1))
             (pos "0123456789abcdef" (shen-jit.bit-and V 15))))

(define trace.render
  W H N -> (let Spheres (trace.spheres)
                Scene (memory.alloc (* 88 (length Spheres)))
                _ (trace.put-spheres Scene 0 Spheres)
                Size (* W H 3)
                State (trace.seed (memory.alloc 8) 1234567 89101112)
                Hash (memory.alloc 8)
                Tmp (memory.alloc 32)
                Light (memory.alloc (* 8 Size))
                Image (memory.alloc Size)
                T0 (get-time unix)
                _ (trace.light Scene (* 88 (length Spheres)) State Tmp Light 0 W H N)
                _ (trace.develop Light Image 0 Size (float N)
                                 (word.+ (word.shl (word.of 3421674724) 32) (word.of 2216829733)) Hash)
                T1 (get-time unix)
             (output "trace ~A s check ~A~A~%" (- T1 T0) (trace.hex (shen-jit.u32 Hash 4) 8)
                     (trace.hex (shen-jit.u32 Hash 0) 8))))

(define trace-typed-main
  -> (trace.render 240 180 16))

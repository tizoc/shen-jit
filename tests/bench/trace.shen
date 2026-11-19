\\ A path tracer: a room of spheres, one of them a light, rendered to memory, hashed, and written to
\\ a file if asked. The rendering and developing are native code in float and word registers; setting
\\ up and saving are ordinary Shen. Load after lib/ffi.shen, lib/native.shen, lib/memory.shen,
\\ lib/mmap.shen and lib/handle.shen. trace.c is the same in C, to the last bit of the image.
\\
\\ (trace.render 240 180 16 "room.ppm") gives the hash as a string, and prints the time.

\\ ---------------------------------------------------------------------------
\\ The scene: each sphere is 11 floats, x y z radius, colour, light, mirror, in memory.

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
  M I [X | Xs] -> (do (shen-jit.f64! M I X) (trace.put-floats M (+ I 8) Xs)))

(define trace.put-spheres
  _ _ [] -> done
  M I [S | Ss] -> (do (trace.put-floats M I S) (trace.put-spheres M (+ I 88) Ss)))

(define trace.scene
  -> (let Spheres (trace.spheres)
          M (handle.wrap (memory.alloc (* 88 (length Spheres))) (/. X (memory.free X)))
       (do (trace.put-spheres M 0 Spheres) M)))

\\ ---------------------------------------------------------------------------
\\ The rendering, loops within loops: each row, column and sample, each bounce of the path, each
\\ sphere it may hit, and the drawing of a random direction. Out gets the light of each pixel.

(define-native trace.light (Scene End State Out W0 H0 N0)
  (word W W0)
  (word H H0)
  (word N N0)
  (word Stop End)
  (word R (u64 State 0))
  (word Mult (+ (* 625341585 4294967296) 1332534557))
  (float Unit (/ 1 9007199254740992))
  (float Scale (/ 2 H))
  (float HalfW (* W 0.5))
  (float HalfH (* H 0.5))
  (for Y 0 H
    (for X 0 W
      (word Pixel (* (+ (* Y W) X) 24))
      (for Sample 0 N

        \\ The ray through this pixel, jittered.
        (word R (bit-xor R (shift-right R 12)))
        (word R (bit-xor R (shift-left R 25)))
        (word R (bit-xor R (shift-right R 27)))
        (float Px (* (- (+ X (* (shift-right (* R Mult) 11) Unit)) HalfW) Scale))
        (word R (bit-xor R (shift-right R 12)))
        (word R (bit-xor R (shift-left R 25)))
        (word R (bit-xor R (shift-right R 27)))
        (float Py (* (- (- HalfH Y) (* (shift-right (* R Mult) 11) Unit)) Scale))
        (float Norm (sqrt (+ (* Px Px) (+ (* Py Py) 4))))
        (float Dx (/ Px Norm))
        (float Dy (/ Py Norm))
        (float Dz (/ -2 Norm))
        (float Ox 0) (float Oy 0) (float Oz 2)
        (float Tr 1) (float Tg 1) (float Tb 1)
        (float Rr 0) (float Rg 0) (float Rb 0)
        (word Left 6)
        (while bounce true
          (float Best 1e30)
          (word Hit -1)
          (word K 0)
          (while (< K Stop)
            (float Sr (f64 Scene (+ K 24)))
            (float Cx (- Ox (f64 Scene K)))
            (float Cy (- Oy (f64 Scene (+ K 8))))
            (float Cz (- Oz (f64 Scene (+ K 16))))
            (float B (+ (* Cx Dx) (+ (* Cy Dy) (* Cz Dz))))
            (float Disc (- (* B B) (- (+ (* Cx Cx) (+ (* Cy Cy) (* Cz Cz))) (* Sr Sr))))
            (when (> Disc 0)
              (float Root (sqrt Disc))
              (float T (- (- 0 B) Root))
              (unless (> T 0.0009765625) (float T (+ (- 0 B) Root)))
              (when (and (> T 0.0009765625) (< T Best))
                (float Best T)
                (word Hit K)))
            (word K (+ K 88)))

          \\ It left the room, or it takes what it hit, and goes on from there.
          (unless (>= Hit 0) (exit bounce))
          (float Rr (+ Rr (* Tr (f64 Scene (+ Hit 56)))))
          (float Rg (+ Rg (* Tg (f64 Scene (+ Hit 64)))))
          (float Rb (+ Rb (* Tb (f64 Scene (+ Hit 72)))))
          (float Tr (* Tr (f64 Scene (+ Hit 32))))
          (float Tg (* Tg (f64 Scene (+ Hit 40))))
          (float Tb (* Tb (f64 Scene (+ Hit 48))))
          (float Ox (+ Ox (* Best Dx)))
          (float Oy (+ Oy (* Best Dy)))
          (float Oz (+ Oz (* Best Dz)))
          (float Radius (f64 Scene (+ Hit 24)))
          (float Nx (/ (- Ox (f64 Scene Hit)) Radius))
          (float Ny (/ (- Oy (f64 Scene (+ Hit 8))) Radius))
          (float Nz (/ (- Oz (f64 Scene (+ Hit 16))) Radius))
          (float Dn (+ (* Dx Nx) (+ (* Dy Ny) (* Dz Nz))))
          (when (> Dn 0)
            (float Nx (- 0 Nx))
            (float Ny (- 0 Ny))
            (float Nz (- 0 Nz))
            (float Dn (- 0 Dn)))
          (if (> (f64 Scene (+ Hit 80)) 0)
              (do (float Twice (+ Dn Dn))
                  (float Dx (- Dx (* Twice Nx)))
                  (float Dy (- Dy (* Twice Ny)))
                  (float Dz (- Dz (* Twice Nz))))

              \\ A dull surface: three floats in -1 to 1, until they lie inside the unit sphere.
              (do (while draw true
                    (word R (bit-xor R (shift-right R 12)))
                    (word R (bit-xor R (shift-left R 25)))
                    (word R (bit-xor R (shift-right R 27)))
                    (float Ux (- (* 2 (* (shift-right (* R Mult) 11) Unit)) 1))
                    (word R (bit-xor R (shift-right R 12)))
                    (word R (bit-xor R (shift-left R 25)))
                    (word R (bit-xor R (shift-right R 27)))
                    (float Uy (- (* 2 (* (shift-right (* R Mult) 11) Unit)) 1))
                    (word R (bit-xor R (shift-right R 12)))
                    (word R (bit-xor R (shift-left R 25)))
                    (word R (bit-xor R (shift-right R 27)))
                    (float Uz (- (* 2 (* (shift-right (* R Mult) 11) Unit)) 1))
                    (float Len (+ (* Ux Ux) (+ (* Uy Uy) (* Uz Uz))))
                    (when (and (< Len 1) (> Len 0.0009765625)) (exit draw)))
                  (float Root (sqrt Len))
                  (float Dx (+ Nx (/ Ux Root)))
                  (float Dy (+ Ny (/ Uy Root)))
                  (float Dz (+ Nz (/ Uz Root)))
                  (float Norm (sqrt (+ (* Dx Dx) (+ (* Dy Dy) (* Dz Dz)))))
                  (float Dx (/ Dx Norm))
                  (float Dy (/ Dy Norm))
                  (float Dz (/ Dz Norm))))
          (word Left (- Left 1))
          (unless (> Left 0) (exit bounce)))

        (f64! Out Pixel (+ (f64 Out Pixel) Rr))
        (f64! Out (+ Pixel 8) (+ (f64 Out (+ Pixel 8)) Rg))
        (f64! Out (+ Pixel 16) (+ (f64 Out (+ Pixel 16)) Rb)))))
  (u64! State 0 R)
  (return Out))

\\ Turns light into bytes, and hashes them with FNV-1a.
(define-native trace.develop (Light Image Count Samples Hash)
  (word N Count)
  (float Each Samples)
  (word H (u64 Hash 0))
  (word Prime 1099511628211)
  (for I 0 N
    (word B (truncate (* (sqrt (/ (f64 Light (* I 8)) Each)) 255.5)))
    (when (> B 255) (word B 255))
    (u8! Image I B)
    (word H (* (bit-xor H B) Prime)))
  (u64! Hash 0 H)
  (return Image))

\\ A word of 64 bits, read as text.
(define trace.hex
  _ 0 -> ""
  V N -> (cn (trace.hex (shen-jit.shift-right V 4) (- N 1))
             (pos "0123456789abcdef" (shen-jit.bit-and V 15))))

(define trace.word-hex
  M -> (cn (trace.hex (shen-jit.u32 M 4) 8) (trace.hex (shen-jit.u32 M 0) 8)))

(define trace.write-header
  M I [] -> I
  M I [C | Cs] -> (do (shen-jit.u8! M I C) (trace.write-header M (+ I 1) Cs)))

(define trace.save
  Path Image W H
  -> (let Header (trace.string-bytes (make-string "P6c#10;~A ~Ac#10;255c#10;" W H))
          Size (* W H 3)
          M (handle.wrap (mmap.create Path (+ (length Header) Size)) (/. X (mmap.close X)))
          At (trace.write-header M 0 Header)
          _ (shen-jit.copy-bytes M At Image 0 Size)
       (handle.close M)))

(define trace.string-bytes
  "" -> []
  S -> [(string->n (pos S 0)) | (trace.string-bytes (tlstr S))])

(define trace.render
  W H N Path
  -> (let Scene (trace.scene)
          End (shen-jit.bytes-length Scene)
          Size (* W H 3)
          State (handle.wrap (memory.alloc 8) (/. X (memory.free X)))
          Hash (handle.wrap (memory.alloc 8) (/. X (memory.free X)))
          Light (handle.wrap (memory.alloc (* 8 Size)) (/. X (memory.free X)))
          Image (handle.wrap (memory.alloc Size) (/. X (memory.free X)))
          _ (trace.seed State 1234567 89101112)
          _ (trace.seed Hash 3421674724 2216829733)
          T0 (get-time unix)
          _ (trace.light Scene End State Light W H N)
          _ (trace.develop Light Image Size N Hash)
          T1 (get-time unix)
          Check (trace.word-hex Hash)
          _ (if (= Path "") skip (trace.save Path Image W H))
       (do (output "trace ~A s check ~A~%" (- T1 T0) Check) Check)))

(define trace.seed
  M High Low -> (shen-jit.u32! (shen-jit.u32! M 0 Low) 4 High))

\\ Set trace.*image* first to have the image in a file.
(define trace.image-path
  -> (trap-error (value trace.*image*) (/. E "")))

(trace.render 240 180 16 (trace.image-path))

\\ The path tracer of trace.shen as typed Shen, which a typed build compiles with floats and fixnums in
\\ registers (docs/modules.md, Typed programs). make bench-numeric builds trace-typed.shenmod and
\\ compares it with trace.shen and trace.c, whose hash of the image it must give to the last bit.
\\
\\ It is written as typed Shen is: a loop is a definition calling itself, and a definition gives one
\\ value, so one that finds more puts the rest in memory, Tmp. The random numbers' state of 64 bits
\\ and the hash are words (lib/word.shen).

\\ ---------------------------------------------------------------------------
\\ Random numbers: xorshift64*, as next_word in trace.c, on the state in S's 8 bytes.

(define rnd.next {word.t --> word.t}
  X -> (let A (word.bit-xor X (word.shr X 12))
            B (word.bit-xor A (word.shl A 25))
         (word.bit-xor B (word.shr B 27))))

(define rnd.mult {--> word.t}
  -> (word.+ (word.shl (word.of 625341585) 32) (word.of 1332534557)))

\\ A float in 0 to 1: the top 53 bits of the new state times 2685821657736338717, times 2^-53, which
\\ the reader reads exactly.
(define rnd.float {buffer.storage --> float}
  S -> (let X (rnd.next (word.get S 0))
         (do (word.set S 0 X)
             (fl* (fx->fl (word.to-fixnum (word.shr (word.* X (rnd.mult)) 11))) 1.1102230246251565e-16))))

\\ ---------------------------------------------------------------------------
\\ The rendering. The scene is 11 floats for each sphere, x y z radius, colour, light, mirror.

\\ The nearer root of a sphere that is ahead, as trace.c takes it.
(define trace.distance {float --> float --> float}
  B Root -> (let T (fl- (fl- (float 0) B) Root)
              (if (fl> T 0.0009765625) T (fl+ (fl- (float 0) B) Root))))

\\ The sphere a ray hits first, from K on, or -1; its distance goes to Tmp at 0.
(define trace.nearest {buffer.storage --> fixnum --> fixnum --> float --> float --> float --> float --> float --> float
                       --> float --> fixnum --> buffer.storage --> fixnum}
  _ K Stop _ _ _ _ _ _ Best Hit Tmp -> (do (shen-jit.f64! Tmp 0 Best) Hit) where (fx>= K Stop)
  Scene K Stop Ox Oy Oz Dx Dy Dz Best Hit Tmp
  -> (let Sr (shen-jit.f64 Scene (fx+ K 24))
          Cx (fl- Ox (shen-jit.f64 Scene K))
          Cy (fl- Oy (shen-jit.f64 Scene (fx+ K 8)))
          Cz (fl- Oz (shen-jit.f64 Scene (fx+ K 16)))
          B (fl+ (fl* Cx Dx) (fl+ (fl* Cy Dy) (fl* Cz Dz)))
          Disc (fl- (fl* B B) (fl- (fl+ (fl* Cx Cx) (fl+ (fl* Cy Cy) (fl* Cz Cz))) (fl* Sr Sr)))
          T (if (fl> Disc (float 0)) (trace.distance B (flsqrt Disc)) (float 0))
       (if (and (fl> T 0.0009765625) (fl< T Best))
           (trace.nearest Scene (fx+ K 88) Stop Ox Oy Oz Dx Dy Dz T K Tmp)
           (trace.nearest Scene (fx+ K 88) Stop Ox Oy Oz Dx Dy Dz Best Hit Tmp))))

\\ Three floats in -1 to 1, until they lie inside the unit sphere: their length squared, and them in
\\ Tmp at 8, 16 and 24.
(define trace.draw {buffer.storage --> buffer.storage --> float}
  S Tmp -> (let Ux (fl- (fl* (float 2) (rnd.float S)) (float 1))
                Uy (fl- (fl* (float 2) (rnd.float S)) (float 1))
                Uz (fl- (fl* (float 2) (rnd.float S)) (float 1))
                Len (fl+ (fl* Ux Ux) (fl+ (fl* Uy Uy) (fl* Uz Uz)))
             (if (and (fl< Len (float 1)) (fl> Len 0.0009765625))
                 (do (shen-jit.f64! Tmp 8 Ux) (shen-jit.f64! Tmp 16 Uy) (shen-jit.f64! Tmp 24 Uz) Len)
                 (trace.draw S Tmp))))

\\ What a path brings to pixel P of Out, added there.
(define trace.add {buffer.storage --> fixnum --> float --> float --> float --> buffer.storage}
  Out P R G B -> (do (shen-jit.f64! Out P (fl+ (shen-jit.f64 Out P) R))
                     (shen-jit.f64! Out (fx+ P 8) (fl+ (shen-jit.f64 Out (fx+ P 8)) G))
                     (shen-jit.f64! Out (fx+ P 16) (fl+ (shen-jit.f64 Out (fx+ P 16)) B))
                     Out))

\\ A path from O along D, carrying T and bringing R, with Left bounces left: it leaves the room, or
\\ takes what it hit and goes on from there, mirrored or in a random direction.
(define trace.path {buffer.storage --> fixnum --> buffer.storage --> buffer.storage --> buffer.storage --> fixnum
                    --> float --> float --> float --> float --> float --> float --> float --> float --> float
                    --> float --> float --> float --> fixnum --> buffer.storage}
  Scene Stop S Tmp Out P Ox Oy Oz Dx Dy Dz Tr Tg Tb Rr Rg Rb Left
  -> (let Hit (trace.nearest Scene 0 Stop Ox Oy Oz Dx Dy Dz 1e30 -1 Tmp)
       (if (fx< Hit 0)
           (trace.add Out P Rr Rg Rb)
           (let Best (shen-jit.f64 Tmp 0)
                Rr1 (fl+ Rr (fl* Tr (shen-jit.f64 Scene (fx+ Hit 56))))
                Rg1 (fl+ Rg (fl* Tg (shen-jit.f64 Scene (fx+ Hit 64))))
                Rb1 (fl+ Rb (fl* Tb (shen-jit.f64 Scene (fx+ Hit 72))))
                Tr1 (fl* Tr (shen-jit.f64 Scene (fx+ Hit 32)))
                Tg1 (fl* Tg (shen-jit.f64 Scene (fx+ Hit 40)))
                Tb1 (fl* Tb (shen-jit.f64 Scene (fx+ Hit 48)))
                Ox1 (fl+ Ox (fl* Best Dx))
                Oy1 (fl+ Oy (fl* Best Dy))
                Oz1 (fl+ Oz (fl* Best Dz))
                Radius (shen-jit.f64 Scene (fx+ Hit 24))
                Nx0 (fl/ (fl- Ox1 (shen-jit.f64 Scene Hit)) Radius)
                Ny0 (fl/ (fl- Oy1 (shen-jit.f64 Scene (fx+ Hit 8))) Radius)
                Nz0 (fl/ (fl- Oz1 (shen-jit.f64 Scene (fx+ Hit 16))) Radius)
                Dn0 (fl+ (fl* Dx Nx0) (fl+ (fl* Dy Ny0) (fl* Dz Nz0)))
                Flip (fl> Dn0 (float 0))
                Nx (if Flip (fl- (float 0) Nx0) Nx0)
                Ny (if Flip (fl- (float 0) Ny0) Ny0)
                Nz (if Flip (fl- (float 0) Nz0) Nz0)
                Dn (if Flip (fl- (float 0) Dn0) Dn0)
             (if (fl> (shen-jit.f64 Scene (fx+ Hit 80)) (float 0))
                 (let Twice (fl+ Dn Dn)
                   (if (fx> Left 1)
                       (trace.path Scene Stop S Tmp Out P Ox1 Oy1 Oz1 (fl- Dx (fl* Twice Nx)) (fl- Dy (fl* Twice Ny))
                                   (fl- Dz (fl* Twice Nz)) Tr1 Tg1 Tb1 Rr1 Rg1 Rb1 (fx- Left 1))
                       (trace.add Out P Rr1 Rg1 Rb1)))
                 (let Root (flsqrt (trace.draw S Tmp))
                      Ex (fl+ Nx (fl/ (shen-jit.f64 Tmp 8) Root))
                      Ey (fl+ Ny (fl/ (shen-jit.f64 Tmp 16) Root))
                      Ez (fl+ Nz (fl/ (shen-jit.f64 Tmp 24) Root))
                      Norm (flsqrt (fl+ (fl* Ex Ex) (fl+ (fl* Ey Ey) (fl* Ez Ez))))
                   (if (fx> Left 1)
                       (trace.path Scene Stop S Tmp Out P Ox1 Oy1 Oz1 (fl/ Ex Norm) (fl/ Ey Norm) (fl/ Ez Norm)
                                   Tr1 Tg1 Tb1 Rr1 Rg1 Rb1 (fx- Left 1))
                       (trace.add Out P Rr1 Rg1 Rb1))))))))

\\ N samples of the pixel at X, Y, each through a jittered point.
(define trace.samples {buffer.storage --> fixnum --> buffer.storage --> buffer.storage --> buffer.storage --> fixnum
                       --> float --> float --> float --> float --> float --> fixnum --> buffer.storage}
  _ _ _ _ Out _ _ _ _ _ _ 0 -> Out
  Scene Stop S Tmp Out P X Y HalfW HalfH Scale N
  -> (let Px (fl* (fl- (fl+ X (rnd.float S)) HalfW) Scale)
          Py (fl* (fl- (fl- HalfH Y) (rnd.float S)) Scale)
          Norm (flsqrt (fl+ (fl* Px Px) (fl+ (fl* Py Py) (float 4))))
       (do (trace.path Scene Stop S Tmp Out P (float 0) (float 0) (float 2) (fl/ Px Norm) (fl/ Py Norm)
                       (fl/ (float -2) Norm) (float 1) (float 1) (float 1) (float 0) (float 0) (float 0) 6)
           (trace.samples Scene Stop S Tmp Out P X Y HalfW HalfH Scale (fx- N 1)))))

(define trace.columns {buffer.storage --> fixnum --> buffer.storage --> buffer.storage --> buffer.storage --> fixnum
                       --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.storage}
  _ _ _ _ Out X _ W _ _ -> Out where (fx>= X W)
  Scene Stop S Tmp Out X Y W H N
  -> (do (trace.samples Scene Stop S Tmp Out (fx* (fx+ (fx* Y W) X) 24) (fx->fl X) (fx->fl Y)
                        (fl* (fx->fl W) 0.5) (fl* (fx->fl H) 0.5) (fl/ (float 2) (fx->fl H)) N)
         (trace.columns Scene Stop S Tmp Out (fx+ X 1) Y W H N)))

(define trace.light {buffer.storage --> fixnum --> buffer.storage --> buffer.storage --> buffer.storage --> fixnum
                     --> fixnum --> fixnum --> fixnum --> buffer.storage}
  _ _ _ _ Out Y _ H _ -> Out where (fx>= Y H)
  Scene Stop S Tmp Out Y W H N -> (do (trace.columns Scene Stop S Tmp Out 0 Y W H N)
                                      (trace.light Scene Stop S Tmp Out (fx+ Y 1) W H N)))

\\ ---------------------------------------------------------------------------
\\ Light into bytes, hashed with FNV-1a, whose prime is 256 * 2^32 + 435.

\\ A byte of the image from X, which is not negative: X truncated, and 255 at most, as in trace.c.
(define trace.byte {float --> fixnum}
  X -> (let B (fl->fx X) (if (fx> B 255) 255 B)))

(define trace.develop {buffer.storage --> buffer.storage --> fixnum --> fixnum --> float --> word.t
                       --> buffer.storage --> buffer.storage}
  _ Image I N _ H Hash -> (do (word.set Hash 0 H) Image) where (fx>= I N)
  Light Image I N Each H Hash
  -> (let B (trace.byte (fl* (flsqrt (fl/ (shen-jit.f64 Light (fx* I 8)) Each)) 255.5))
       (do (shen-jit.u8! Image I B)
           (trace.develop Light Image (fx+ I 1) N Each
                          (word.* (word.bit-xor H (word.of B)) (word.+ (word.shl (word.of 256) 32) (word.of 435)))
                          Hash))))

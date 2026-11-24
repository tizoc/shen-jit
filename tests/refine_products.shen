\\ Products of unknowns: indices by row and column, pages, areas, and what is not so. Each case is loaded in turn.
(define-checked from-0 {I : fixnum --> fixnum} {requires (fx<= 0 I)} I -> I)
(define-checked byte {B : buffer.storage --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))} B I -> (shen-jit.u8 B I))
(refine.type range P : (fixnum * fixnum) where (and (fx<= 0 (fst P)) (fx<= (fst P) (snd P))))
(defstruct grid (store : buffer.storage) (w : fixnum) (h : fixnum))
(refine.type good-grid G : grid where
  (and (fx<= 0 (grid.w G)) (fx<= 0 (grid.h G)) (fx<= (fx* (grid.w G) (grid.h G)) (shen-jit.bytes-length (grid.store G)))))
\\ loads
(define-checked cell
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= (fx* W H) (shen-jit.bytes-length B))}
  B W H X Y -> (byte B (fx+ (fx* Y W) X)))
\\ says type error in rule 1 of cell: byte needs (fx< (fx+ (fx* X W) Y) (shen-jit.bytes-length B)), which may not be so, as if X is 1 and W is 2 and Y is 0 and (shen-jit.bytes-length B) is 2
(define-checked cell
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= (fx* W H) (shen-jit.bytes-length B))}
  B W H X Y -> (byte B (fx+ (fx* X W) Y)))
\\ says type error in rule 1 of cell: byte needs (fx< (fx+ (fx* Y W) X) (shen-jit.bytes-length B)), which may not be so, as if X is 0 and W is 1 and Y is 0 and (shen-jit.bytes-length B) is 0
(define-checked cell
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx<= Y H) (fx<= (fx* W H) (shen-jit.bytes-length B))}
  B W H X Y -> (byte B (fx+ (fx* Y W) X)))
\\ says type error in rule 1 of cell: byte needs (fx< (fx+ (fx* Y W) X) (shen-jit.bytes-length B)), which may not be so, as if X is 0 and W is 0 and Y is 0 and (shen-jit.bytes-length B) is 0
(define-checked cell
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx<= X W) (fx<= 0 Y) (fx< Y H) (fx<= (fx* W H) (shen-jit.bytes-length B))}
  B W H X Y -> (byte B (fx+ (fx* Y W) X)))
\\ loads
(define-checked pixel
  {B : buffer.storage --> Stride : fixnum --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= W Stride) (fx<= 0 Y) (fx< Y H) (fx<= (fx* Stride H) (shen-jit.bytes-length B))}
  B Stride W H X Y -> (byte B (fx+ (fx* Y Stride) X)))
\\ loads
(define-checked channel
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> C : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= 0 C) (fx< C 4) (fx<= (fx* 4 (fx* W H)) (shen-jit.bytes-length B))}
  B W H X Y C -> (byte B (fx+ (fx* 4 (fx+ (fx* Y W) X)) C)))
\\ loads
(define-checked voxel
  {B : buffer.storage --> W : fixnum --> H : fixnum --> D : fixnum --> X : fixnum --> Y : fixnum --> Z : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= 0 Z) (fx< Z D) (fx<= (fx* (fx* W H) D) (shen-jit.bytes-length B))}
  B W H D X Y Z -> (byte B (fx+ (fx* (fx+ (fx* Z H) Y) W) X)))
\\ loads
(define-checked voxel-otherwise
  {B : buffer.storage --> W : fixnum --> H : fixnum --> D : fixnum --> X : fixnum --> Y : fixnum --> Z : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= 0 Z) (fx< Z D) (fx<= (fx* W (fx* D H)) (shen-jit.bytes-length B))}
  B W H D X Y Z -> (byte B (fx+ (fx* Z (fx* W H)) (fx+ (fx* Y W) X))))
\\ loads
(define-checked row-of-8
  {B : buffer.storage --> W : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y 8) (fx<= (fx* 8 W) (shen-jit.bytes-length B))}
  B W X Y -> (byte B (fx+ (fx* Y W) X)))
\\ loads
(define-checked sum-rows
  {B : buffer.storage --> W : fixnum --> H : fixnum --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx<= Y H) (fx<= (fx* W H) (shen-jit.bytes-length B))}
  B W H X Y -> (if (fx= Y H)
                   0
                   (if (fx= (fx+ X 1) W)
                       (fx+ (byte B (fx+ (fx* Y W) X)) (sum-rows B W H 0 (fx+ Y 1)))
                       (fx+ (byte B (fx+ (fx* Y W) X)) (sum-rows B W H (fx+ X 1) Y)))))
(define-checked sum-grid
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  B W H -> (if (and (fx< 0 W) (fx<= 0 H) (fx<= (fx* W H) (shen-jit.bytes-length B))) (sum-rows B W H 0 0) -1))
(if (and (= (sum-grid (shen-jit.bytes 6) 3 2) 0) (= (sum-grid (shen-jit.bytes 5) 3 2) -1)) true (simple-error "not 0 and -1"))
\\ loads
(define-checked grid-at
  {G : good-grid --> X : fixnum --> Y : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X (grid.w G)) (fx<= 0 Y) (fx< Y (grid.h G))}
  G X Y -> (byte (grid.store G) (fx+ (fx* Y (grid.w G)) X)))
(define-checked make-grid
  {W : fixnum --> H : fixnum --> good-grid}
  {requires (fx<= 0 W) (fx<= 0 H)}
  W H -> (grid.make (shen-jit.bytes (fx* W H)) W H))
\\ says type error in rule 1 of make-grid-of: make-grid-of promises (fx<= (fx* (grid.w (grid.make (shen-jit.bytes N) W H)) (grid.h (grid.make (shen-jit.bytes N) W H))) (shen-jit.bytes-length (grid.store (grid.make (shen-jit.bytes N) W H)))), which may not be so, as if W is 1 and H is 1 and (shen-jit.bytes-length (shen-jit.bytes N)) is 0
(define-checked make-grid-of
  {W : fixnum --> H : fixnum --> N : fixnum --> good-grid}
  {requires (fx<= 0 W) (fx<= 0 H) (fx<= 0 N)}
  W H N -> (grid.make (shen-jit.bytes N) W H))
\\ loads
(define-checked page
  {Total : fixnum --> Size : fixnum --> N : fixnum --> R : range}
  {requires (fx<= 0 Total) (fx< 0 Size) (fx<= 0 N)}
  {ensures (fx<= (snd R) Total)}
  Total Size N -> (let Start (fx* Size N)
                    (if (fx>= Start Total)
                        (@p Total Total)
                        (if (fx> (fx+ Start Size) Total) (@p Start Total) (@p Start (fx+ Start Size))))))
\\ says type error in rule 1 of page: page promises (fx<= 0 (fst (@p Start (fx+ Start Size)))), which may not be so, as if N is -1 and Size is 1
(define-checked page
  {Total : fixnum --> Size : fixnum --> N : fixnum --> R : range}
  {requires (fx<= 0 Total) (fx< 0 Size)}
  {ensures (fx<= (snd R) Total)}
  Total Size N -> (let Start (fx* Size N)
                    (if (fx>= Start Total)
                        (@p Total Total)
                        (if (fx> (fx+ Start Size) Total) (@p Start Total) (@p Start (fx+ Start Size))))))
\\ loads
(define-checked pages
  {Total : fixnum --> Size : fixnum --> R : fixnum}
  {requires (fx<= 0 Total) (fx< 0 Size)}
  {ensures (fx<= Total (fx* R Size))}
  Total Size -> (fxquotient (fx+ Total (fx- Size 1)) Size))
(define-checked column
  {I : fixnum --> W : fixnum --> R : fixnum}
  {requires (fx<= 0 I) (fx< 0 W)}
  {ensures (fx<= 0 R) (fx< R W) (fx= I (fx+ (fx* W (fxquotient I W)) R))}
  I W -> (fxremainder I W))
\\ says type error in rule 1 of pages: pages promises (fx<= Total (fx* (fxquotient Total Size) Size)), which may not be so, as if Size is 2 and Total is 1 and (fxquotient Total Size) is 0
(define-checked pages
  {Total : fixnum --> Size : fixnum --> R : fixnum}
  {requires (fx<= 0 Total) (fx< 0 Size)}
  {ensures (fx<= Total (fx* R Size))}
  Total Size -> (fxquotient Total Size))
\\ loads
(define-checked area
  {W : fixnum --> H : fixnum --> R : fixnum}
  {requires (fx<= 0 W) (fx<= W 4096) (fx<= 0 H) (fx<= H 4096)}
  {ensures (fx<= 0 R) (fx<= R 16777216)}
  W H -> (fx* W H))
\\ says type error in rule 1 of area: area promises (fx<= (fx* W H) 16777215), which may not be so, as if H is 4096 and W is 4096
(define-checked area
  {W : fixnum --> H : fixnum --> R : fixnum}
  {requires (fx<= 0 W) (fx<= W 4096) (fx<= 0 H) (fx<= H 4096)}
  {ensures (fx<= 0 R) (fx<= R 16777215)}
  W H -> (fx* W H))
\\ loads
(define-checked volume
  {W : fixnum --> H : fixnum --> D : fixnum --> R : fixnum}
  {requires (fx<= 1 W) (fx<= 1 H) (fx<= 1 D)}
  {ensures (fx>= R W) (fx>= R H) (fx>= R D)}
  W H D -> (fx* W (fx* H D)))
(define-checked below
  {W : fixnum --> H : fixnum --> R : fixnum}
  {requires (fx<= W 0) (fx<= 0 H)}
  {ensures (fx<= R 0)}
  W H -> (fx* W H))
(define-checked above
  {W : fixnum --> H : fixnum --> R : fixnum}
  {requires (fx< W 0) (fx< H 0)}
  {ensures (fx>= R 1)}
  W H -> (fx* W H))
(define-checked distance
  {X : fixnum --> Y : fixnum --> X2 : fixnum --> Y2 : fixnum --> R : fixnum}
  {ensures (fx<= 0 R)}
  X Y X2 Y2 -> (let DX (fx- X X2) (let DY (fx- Y Y2) (fx+ (fx* DX DX) (fx* DY DY)))))
(define-checked spent
  {Money : fixnum --> Price : fixnum --> N : fixnum --> R : fixnum}
  {requires (fx<= 0 Price) (fx<= 0 N) (fx<= (fx* Price N) Money)}
  {ensures (fx<= 0 R)}
  Money Price N -> (fx- Money (fx* N Price)))
(define-checked lengths {Xs : (list A) --> Ys : (list B) --> R : number} {ensures (>= R 0)} Xs Ys -> (* (length Xs) (length Ys)))
(define-checked nothing {A : fixnum --> B : fixnum --> fixnum} {requires (fx<= 1 A) (fx<= 1 B) (fx<= (fx* A B) 0)} A B -> (from-0 -1))
(define-checked minus {A : fixnum --> B : fixnum --> C : fixnum --> R : fixnum} {ensures (fx= R (fx- (fx* C A) (fx* B C)))} A B C -> (fx* (fx- A B) C))
(define-checked beside {W : fixnum --> H : fixnum --> X : fixnum --> R : fixnum} {requires (fx<= 0 X) (fx< X W) (fx< X H)} {ensures (fx<= 0 R)} W H X -> (fx* W H))
(define-checked voxel-shared
  {B : buffer.storage --> W : fixnum --> H : fixnum --> D : fixnum --> X : fixnum --> Y : fixnum --> Z : fixnum --> fixnum}
  {requires (fx<= 0 X) (fx< X W) (fx<= 0 Y) (fx< Y H) (fx<= 0 Z) (fx< Z D) (fx<= (fx* W (fx* H D)) (shen-jit.bytes-length B))}
  B W H D X Y Z -> (byte B (fx+ (fx* (fx+ (fx* Z H) Y) W) X)))
(define-checked equal {A : fixnum --> B : fixnum --> C : fixnum --> R : fixnum} {requires (= A B)} {ensures (fx= R (fx* B C))} A B C -> (fx* C A))
(define-checked multiplied {A : fixnum --> B : fixnum --> R : fixnum} {ensures (fx= R (fx- (fx+ (fx* B A) B) (fx* 2 A)))} A B -> (fx- (fx* B (fx+ A 1)) (fx+ A A)))
(define-checked three {A : fixnum --> B : fixnum --> R : fixnum} {requires (fx= A 3)} {ensures (fx= R (fx* 3 B))} A B -> (fx* A B))
\\ says type error in rule 1 of multiplied: multiplied promises (fx= (fx* B (fx+ A 1)) (fx+ (fx* B A) A)), which may not be so, as if B is -1 and A is 0
(define-checked multiplied {A : fixnum --> B : fixnum --> R : fixnum} {ensures (fx= R (fx+ (fx* B A) A))} A B -> (fx* B (fx+ A 1)))
\\ says type error in rule 1 of cube: from-0 needs (fx<= 0 (fx* A (fx* A A))), which may not be so, as if A is -1
(define-checked cube {A : fixnum --> fixnum} A -> (from-0 (fx* A (fx* A A))))
\\ says type error in rule 1 of determinant: from-0 needs (fx<= 0 (fx- (fx* A D) (fx* B C))), which may not be so, as if B is -2 and C is -2 and A is -1 and D is -1
(define-checked determinant {A : fixnum --> B : fixnum --> C : fixnum --> D : fixnum --> fixnum} A B C D -> (from-0 (fx- (fx* A D) (fx* B C))))
\\ says type error in rule 1 of twice: from-0 needs (fx<= 0 (fx- (fx+ (fx* A A) (fx* B B)) (fx* 2 (fx* A B)))), which is not proved: little is known of products of unknowns
(define-checked twice {A : fixnum --> B : fixnum --> fixnum} A B -> (from-0 (fx- (fx+ (fx* A A) (fx* B B)) (fx* 2 (fx* A B)))))
\\ says type error in rule 1 of large: from-0 needs (fx<= 0 (fx- 5 (fx* A B))), which is not proved: little is known of products of unknowns
(define-checked large {A : fixnum --> B : fixnum --> fixnum} {requires (fx> A 1000000000000) (fx> B 1000000000000)} A B -> (from-0 (fx- 5 (fx* A B))))
\\ loads
(define-checked powers {X : fixnum --> fixnum} {requires (fx<= 0 X)}
  X -> (let A (fx+ X 1) (let B (fx* A A) (let C (fx* B B) (let D (fx* C C) (let E (fx* D D) (let F (fx* E E) (if (fx< F 0) 0 (from-0 X)))))))))
\\ says type error in rule 1 of cubed: cubed promises (fx<= 0 (fx* S (fx* S S))), which is not proved: little is known of products of unknowns
(define-checked cubed {A : fixnum --> B : fixnum --> C : fixnum --> D : fixnum --> R : fixnum} {ensures (fx<= 0 R)}
  A B C D -> (let S (fx+ A (fx+ B (fx+ C D))) (fx* S (fx* S S))))
\\ says type error in rule 1 of cube: from-0 needs (fx<= 0 (fx* A (fx* A A))), which may not be so, as if A is -1
(define-checked cube {A : fixnum --> fixnum} A -> (from-0 (fx* A (fx* A A))))
\\ A product is the same however it is written.
\\ loads
(define-checked needs-product {X : fixnum --> Y : fixnum --> Z : fixnum --> fixnum} {requires (fx> (fx* X (fx* Y Z)) 7)} _ _ _ -> 1)
(define other-product {fixnum --> fixnum --> fixnum --> fixnum} X Y Z -> (if (fx> (fx* (fx* Z X) Y) 7) (needs-product X Y Z) 0))

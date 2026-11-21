(shen.x.namespace hyperloglog
  (use buffer)
  (use shen-jit)
  (use word)
  (use words)
  (import struct defstruct)
  (externals [buffer.storage word.t words.t])
  (export t new precision sparse? storage-bytes add! add-string! add-fixed!
          add-hash! add-hashes! merge!)

\\ Dense registers are bytes. Sparse cells are 32-bit (25-bit index, 6-bit rank)
\\ pairs in an open-addressed table. A rank is at least one, leaving zero vacant.
\\ Keys' hashes are written into hash, up to eight at a time, and read from there into registers.
(defstruct t
  (precision : fixnum)
  (registers : fixnum)
  (hash : buffer.storage)
  (mutable storage : buffer.storage)
  (mutable mask : fixnum)
  (mutable occupied : fixnum))

(define new
  {fixnum --> t}
  P -> (if (or (fx< P 4) (fx> P 18))
           (error "hyperloglog: precision must be in 4..18")
           (:t precision <- P registers <- (shen-jit.shift-left 1 P) hash <- (shen-jit.bytes 64)
               storage <- (shen-jit.bytes 16) mask <- 3 occupied <- 0)))

(define precision
  {t --> fixnum}
  S -> (t.precision S))

(define sparse?
  {t --> boolean}
  S -> (fx>= (t.occupied S) 0))

(define storage-bytes
  {t --> fixnum}
  S -> (shen-jit.bytes-length (t.storage S)))

(define sparse-precision {--> fixnum} -> 25)

(define dense-put
  {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B Index Rank -> (if (fx> Rank (shen-jit.u8 B Index)) (shen-jit.u8! B Index Rank) B))

(define cell-index
  {fixnum --> fixnum}
  Cell -> (shen-jit.shift-right Cell 6))

(define cell-rank
  {fixnum --> fixnum}
  Cell -> (shen-jit.bit-and Cell 63))

(define sparse-cell
  {word.t --> fixnum}
  H -> (pack-hash H (sparse-precision)))

(define slot-offset
  {fixnum --> fixnum}
  I -> (shen-jit.shift-left I 2))

(define find-slot
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
  B Mask Index I ->
    (let Cell (shen-jit.u32 B (slot-offset I))
      (if (or (= Cell 0) (= Index (cell-index Cell))) I
          (find-slot B Mask Index (shen-jit.bit-and (fx+ I 1) Mask)))))

(define home-slot
  {fixnum --> fixnum --> fixnum}
  Index Mask -> (shen-jit.bit-and Index Mask))

\\ When the table grows, its cells go into the new one, which has room for all of them.
(define copy-sparse
  {buffer.storage --> fixnum --> fixnum --> buffer.storage --> fixnum --> buffer.storage}
  From I End To Mask -> (let _ (insert-run To Mask From I End 0) To))

(define promote-cell
  {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B Delta Cell ->
    (let Index (cell-index Cell)
         Bucket (shen-jit.shift-right Index Delta)
         Suffix (shen-jit.bit-and Index (fx- (shen-jit.shift-left 1 Delta) 1))
         Rank (if (= Suffix 0)
                  (fx+ Delta (cell-rank Cell))
                  (fx- (shen-jit.clz Suffix) (fx- 61 Delta)))
      (dense-put B Bucket Rank)))

(define promote-slots
  {buffer.storage --> fixnum --> fixnum --> buffer.storage --> fixnum --> buffer.storage}
  From I End To Delta ->
    (if (fx>= I End) To
        (let Cell (shen-jit.u32 From I)
             _ (if (= Cell 0) To (promote-cell To Delta Cell))
          (promote-slots From (fx+ I 4) End To Delta))))

(define promote
  {t --> buffer.storage}
  S ->
    (let Old (t.storage S)
         Delta (fx- (sparse-precision) (t.precision S))
         Dense (promote-slots Old 0 (shen-jit.bytes-length Old)
                              (shen-jit.bytes (t.registers S)) Delta)
      (do (t.storage-> S Dense)
          (t.occupied-> S -1)
          Dense)))

(define grow-and-insert
  {t --> fixnum --> fixnum --> t}
  S Cell Count ->
    (let Old (t.storage S)
         Bytes (shen-jit.bytes-length Old)
      (if (fx>= Bytes (t.registers S))
          (let Dense (promote S)
               _ (promote-cell Dense (fx- (sparse-precision) (t.precision S)) Cell)
            S)
          (let Mask (fx- (shen-jit.shift-right Bytes 1) 1)
               New (copy-sparse Old 0 Bytes (shen-jit.bytes (fx+ Bytes Bytes)) Mask)
               Index (cell-index Cell)
               Pos (find-slot New Mask Index (home-slot Index Mask))
               _ (shen-jit.u32! New (slot-offset Pos) Cell)
            (do (t.storage-> S New) (t.mask-> S Mask)
                (t.occupied-> S Count) S)))))

\\ A table holds at most three quarters of its slots.
(define sparse-limit
  {fixnum --> fixnum}
  Mask -> (fx- Mask (shen-jit.shift-right Mask 2)))

(define insert-sparse
  {t --> fixnum --> t}
  S Cell ->
    (let B (t.storage S)
         Mask (t.mask S)
         Index (cell-index Cell)
         Pos (slot-offset (find-slot B Mask Index (home-slot Index Mask)))
         Old (shen-jit.u32 B Pos)
      (cases (= Old 0)
               (let Count (fx+ (t.occupied S) 1)
                 (if (fx> Count (sparse-limit Mask)) (grow-and-insert S Cell Count)
                     (do (shen-jit.u32! B Pos Cell) (t.occupied-> S Count) S)))
             (fx> Cell Old) (do (shen-jit.u32! B Pos Cell) S)
             true S)))

\\ Adds the hash in the sketch's 8 bytes. Read here into a register, it is never boxed, as
\\ it would be when passed to a call the lowerer did not inline.
(define add-stored!
  {t --> t}
  S ->
    (let H (word.get (t.hash S) 0)
      (if (sparse? S) (insert-sparse S (sparse-cell H))
          (let P (t.precision S)
            (do (dense-put (t.storage S) (hash-index H P) (hash-rank H P)) S)))))

(define add-hash!
  {t --> word.t --> t}
  S H -> (do (word.set (t.hash S) 0 H) (add-stored! S)))

(define add-key!
  {t --> buffer.storage --> fixnum --> fixnum --> t}
  S Bytes At N -> (do (shen-jit.xxh64 (t.hash S) Bytes At N 1) (add-stored! S)))

(define add!
  {t --> buffer.view --> t}
  S View ->
    (let Checked (buffer.check View)
         Start (buffer.view.start Checked)
      (add-key! S (buffer.view.owner Checked) Start (fx- (buffer.view.end Checked) Start))))

(define add-string!
  {t --> string --> t}
  S Text -> (do (hash-string (t.hash S) Text) (add-stored! S)))

(define add-dense-hashes
  {buffer.storage --> fixnum --> buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B P From At End ->
    (if (fx>= At End) B
        (let H (word.get From At)
             _ (dense-put B (hash-index H P) (hash-rank H P))
          (add-dense-hashes B P From (fx+ At 8) End))))

\\ Registers keep nothing across a call, so a loop that called insert-sparse for each hash
\\ would box each one. The cells of up to eight are made first, into the sketch's hash bytes,
\\ by a loop that makes no calls; written behind what is read, they may replace the hashes.
(define cells!
  {buffer.storage --> fixnum --> fixnum --> buffer.storage --> fixnum --> buffer.storage}
  From At End To I ->
    (if (fx>= At End) To
        (do (shen-jit.u32! To I (sparse-cell (word.get From At)))
            (cells! From (fx+ At 8) End To (fx+ I 4)))))

\\ A cell after a promotion goes into the dense registers, as promote does with the others, and a
\\ zero one is none.
(define insert-cell
  {t --> fixnum --> t}
  S Cell -> (cases (= Cell 0) S
                   (sparse? S) (insert-sparse S Cell)
                   true (do (promote-cell (t.storage S) (fx- (sparse-precision) (t.precision S)) Cell) S)))

\\ The cells from I to End of B, 16 at a time by insert-run while the table has room for all of
\\ them, and one at a time where it may grow.
(define insert-cells
  {t --> buffer.storage --> fixnum --> fixnum --> t}
  S B I End ->
    (let Next (if (fx< (fx- End I) 64) End (fx+ I 64))
      (cases (fx>= I End) S
             (and (sparse? S) (fx<= (fx+ (t.occupied S) 16) (sparse-limit (t.mask S))))
               (do (t.occupied-> S (insert-run (t.storage S) (t.mask S) B I Next (t.occupied S)))
                   (insert-cells S B Next End))
             true (insert-cells (insert-cell S (shen-jit.u32 B I)) B (fx+ I 4) End))))

(define add-hash-range
  {t --> buffer.storage --> fixnum --> fixnum --> t}
  S From At End ->
    (cases (fx>= At End) S
           (sparse? S)
             (let Next (if (fx< (fx- End At) 64) End (fx+ At 64))
                  Cells (cells! From At Next (t.hash S) 0)
               (add-hash-range (insert-cells S Cells 0 (fxquotient (fx- Next At) 2)) From Next End))
           true (do (add-dense-hashes (t.storage S) (t.precision S) From At End) S)))

(define add-hashes!
  {t --> words.t --> t}
  S Hashes ->
    (let B (words.bytes Hashes)
      (add-hash-range S B 0 (shen-jit.bytes-length B))))

\\ Eight keys are hashed by each call, which costs more than hashing one.
(define add-fixed-range!
  {t --> buffer.storage --> fixnum --> fixnum --> fixnum --> t}
  S Bytes At End Width ->
    (if (fx>= At End) S
        (let Keys (fxquotient (fx- End At) Width)
             Count (if (fx< Keys 8) Keys 8)
             Hashes (shen-jit.xxh64 (t.hash S) Bytes At Width Count)
          (add-fixed-range! (add-hash-range S Hashes 0 (fx* Count 8))
                            Bytes (fx+ At (fx* Count Width)) End Width))))

\\ The width and the view are checked before the first key goes in.
(define add-fixed!
  {t --> buffer.view --> fixnum --> t}
  S View Width ->
    (let Checked (buffer.check View)
         Start (buffer.view.start Checked)
         End (buffer.view.end Checked)
      (cases (fx<= Width 0) (error "hyperloglog: key width must be positive")
             (not (= (fxremainder (fx- End Start) Width) 0))
               (error "hyperloglog: view length is not a multiple of ~A bytes" Width)
             true (add-fixed-range! S (buffer.view.owner Checked) Start End Width))))

(define merge!
  {t --> t --> t}
  To From ->
    (let _ (if (= (t.precision To) (t.precision From)) true
                (error "hyperloglog: sketch precisions differ"))
         B (t.storage From)
      (if (sparse? From) (insert-cells To B 0 (shen-jit.bytes-length B))
          (let Dense (if (sparse? To) (promote To) (t.storage To))
            (do (max-bytes! Dense B (t.registers To)) To)))))
)

(shen.x.namespace git
  (use fs)
  (use buffer)
  (use shen-jit)
  (import struct defstruct)
  (externals [file directory])

\\ A pack's index, and the pack's bytes once read, with the delta bases unpacked from it by offset.
(defstruct pack-index path view count first-id offsets large checksum (mutable bytes) (mutable bases))

(define pack-path
  Path -> (cn (before Path ".idx") ".pack"))

(define fans
  V At End Last ->
    (if (= At End) Last
        (let N (buffer.u32-be V At)
             _ (ensure (>= N Last) "invalid pack fanout table")
          (fans V (+ At 4) End N))))

\\ Index version 2: header, fanout, IDs, CRCs, offsets, large offsets, then the pack's checksum.
(define index-open
  Repo Path ->
    (let Width (repo.width Repo)
         V (verify-digest Width (read-view Path (pack-limit)) "pack index")
         End (- (buffer.length V) Width)
         Start (+ (pack-index-header.size) 1024)
         _ (ensure (and (>= End Start) (= (pack-index-header.signature V 0) (pack-index-signature))
                        (= (pack-index-header.version V 0) 2))
                   "unsupported pack index version")
         Count (fans V (pack-index-header.size) Start 0)
         Offset (+ Start (* Count (+ Width 4)))
         Large (+ Offset (* Count 4))
         _ (ensure (and (<= Large End) (= (shen-jit.bit-and (- End Large) 7) 0)) "invalid pack index size")
      (:pack-index path <- (pack-path Path) view <- V count <- Count first-id <- Start offsets <- Offset
         large <- Large checksum <- (buffer.slice V End Width) bytes <- [] bases <- (dictionary))))

(define pack-indexes-from
  _ _ [] -> []
  Repo Dir [Name | Names] ->
    (let Path (fs.join Dir Name)
      (if (and (suffix? ".idx" Name) (= (node Path) file) (= (node (pack-path Path)) file))
          [(index-open Repo Path) | (pack-indexes-from Repo Dir Names)]
          (pack-indexes-from Repo Dir Names))))

(define pack-indexes
  Repo -> (loaded-indexes Repo (repo.pack-indexes Repo)))

(define loaded-indexes
  _ [Indexes] -> Indexes
  Repo [] -> (let Indexes (mapcan (pack-directory Repo) (repo.object-dirs Repo))
               (do (repo.pack-indexes-> Repo [Indexes]) Indexes)))

(define pack-directory
  Repo Objects ->
    (let Path (fs.join Objects "pack")
      (if (= (node Path) directory) (pack-indexes-from Repo Path (names Path)) [])))

(define slice-order
  _ _ At End -> 0 where (= At End)
  A B At End ->
    (let D (- (buffer.u8 A At) (buffer.u8 B At))
      (if (= D 0) (slice-order A B (+ At 1) End) D)))

(define pack-id-at
  I N Width -> (buffer.slice (pack-index.view I) (+ (pack-index.first-id I) (* N Width)) Width))

(define pack-find-row
  _ _ _ Low High -> -1 where (>= Low High)
  I Id Width Low High ->
    (let Mid (shen-jit.shift-right (+ Low High) 1)
         Compare (slice-order Id (pack-id-at I Mid Width) 0 Width)
      (cases (= Compare 0) Mid
             (< Compare 0) (pack-find-row I Id Width Low Mid)
             true (pack-find-row I Id Width (+ Mid 1) High))))

(define pack-offset
  I N Width ->
    (let V (pack-index.view I)
         X (buffer.u32-be V (+ (pack-index.offsets I) (* N 4)))
      (if (>= X 2147483648)
          (let At (+ (pack-index.large I) (* 8 (- X 2147483648)))
               _ (ensure (<= (+ At 8) (- (buffer.length V) Width)) "invalid large pack offset")
               _ (ensure (= (buffer.u32-be V At) 0) "pack offset exceeds file size limit")
            (buffer.u32-be V (+ At 4)))
          X)))

(define pack-find
  [] _ _ -> []
  [I | Rest] Id Width ->
    (let Row (pack-find-row I Id Width 0 (pack-index.count I))
      (if (>= Row 0) [(@p I (pack-offset I Row Width))] (pack-find Rest Id Width))))

\\ The pack's own checksum, which its index records, stands for its contents, as in Git.
(define pack-load
  Repo I ->
    (let Raw (read-view (pack-index.path I) (pack-limit))
         Size (buffer.length Raw)
         Width (repo.width Repo)
         _ (ensure (>= Size (+ (pack-header.size) Width)) "truncated pack")
         _ (ensure (buffer.equal? (pack-index.checksum I) (buffer.slice Raw (- Size Width) Width))
                   "pack and index have different checksums")
         V (buffer.slice Raw 0 (- Size Width))
         _ (ensure (= (pack-header.signature V 0) (pack-signature)) "invalid pack signature")
         _ (ensure (element? (pack-header.version V 0) [2 3]) "unsupported pack version")
         _ (ensure (= (pack-header.count V 0) (pack-index.count I)) "pack object count does not match index")
      (do (pack-index.bytes-> I [V]) V)))

(define pack-bytes
  Repo I -> (let Loaded (pack-index.bytes I) (if (empty? Loaded) (pack-load Repo I) (hd Loaded))))

(define reset-packs!
  Repo -> (do (repo.pack-indexes-> Repo []) (repo.base-size-> Repo 0)))

(define pack-int-tail
  V Byte At Shift Size ->
    (if (< Byte 128) (@p Size At)
        (let _ (ensure (<= Shift 32) "pack entry size exceeds limit")
             Next (buffer.u8 V At)
             Part (shen-jit.shift-left (shen-jit.bit-and Next 127) Shift)
          (pack-int-tail V Next (+ At 1) (+ Shift 7) (+ Size Part)))))

(define ofs-tail
  V Byte At Offset ->
    (if (< Byte 128) (@p Offset At)
        (let _ (ensure (<= Offset (pack-limit)) "pack delta offset exceeds limit")
             Next (buffer.u8 V At)
          (ofs-tail V Next (+ At 1) (+ (* (+ Offset 1) 128) (shen-jit.bit-and Next 127))))))

(define delta-varint
  V At Shift Value ->
    (let _ (ensure (<= Shift 35) "invalid delta length")
         Byte (buffer.u8 V At)
         Sum (+ Value (shen-jit.shift-left (shen-jit.bit-and Byte 127) Shift))
      (if (< Byte 128) (@p Sum (+ At 1)) (delta-varint V (+ At 1) (+ Shift 7) Sum))))

(define delta-field
  _ _ At Bits Bits Value -> (@p Value At)
  V Flags At Bit Bits Value ->
    (if (= (shen-jit.bit-and Flags 1) 0)
        (delta-field V (shen-jit.shift-right Flags 1) At (+ Bit 1) Bits Value)
        (delta-field V (shen-jit.shift-right Flags 1) (+ At 1) (+ Bit 1) Bits
                     (+ Value (shen-jit.shift-left (buffer.u8 V At) (* 8 Bit))))))

(define delta-copied
  V Base Out At Pos Byte ->
    (let Offset (delta-field V Byte At 0 4 0)
         Length (delta-field V (shen-jit.shift-right Byte 4) (snd Offset) 0 3 0)
         Size (if (= (fst Length) 0) 65536 (fst Length))
      (do (buffer.copy-into! Out Pos Base (fst Offset) Size)
          (delta-apply V Base Out (snd Length) (+ Pos Size)))))

(define delta-apply
  V Base Out At Pos ->
    (if (= At (buffer.length V))
        (do (ensure (= Pos (buffer.length Out)) "delta output length does not match") Out)
        (let Byte (buffer.u8 V At)
          (cases (>= Byte 128) (delta-copied V Base Out (+ At 1) Pos Byte)
                 (> Byte 0) (do (buffer.copy-into! Out Pos V (+ At 1) Byte)
                                (delta-apply V Base Out (+ (+ At 1) Byte) (+ Pos Byte)))
                 true (git-error "invalid zero delta instruction")))))

(define apply-delta
  Base Change ->
    (let Have (delta-varint Change 0 0 0)
         Need (delta-varint Change (snd Have) 0 0)
         _ (ensure (= (fst Have) (buffer.length Base)) "delta base length does not match")
         _ (ensure (<= (fst Need) (object-limit)) "delta output exceeds object size limit")
      (delta-apply Change Base (buffer.new (fst Need)) (snd Need) 0)))

(define pack-inflate
  V At Size ->
    (let Info (inflate V At (buffer.length V) Size)
         Payload (fst Info)
      (do (ensure (= (buffer.length Payload) Size) "pack object length does not match") Payload)))

(define pack-type
  1 -> "commit"
  2 -> "tree"
  3 -> "blob"
  4 -> "tag"
  _ -> (git-error "invalid Git pack object type"))

(define unpack-delta
  Base V At Size -> (@p (fst Base) (apply-delta (snd Base) (pack-inflate V At Size))))

(define unpack-object
  Repo I At Depth ->
    (let V (pack-bytes Repo I)
         _ (ensure (and (<= Depth 256) (>= At (pack-header.size)) (< At (buffer.length V)))
                   "invalid pack offset or too many delta levels")
         Byte (buffer.u8 V At)
         Header (pack-int-tail V Byte (+ At 1) 4 (shen-jit.bit-and Byte 15))
         Kind (shen-jit.bit-and (shen-jit.shift-right Byte 4) 7)
         Size (fst Header)
         Pos (snd Header)
         _ (ensure (<= Size (object-limit)) "pack entry exceeds object size limit")
      (cases (= Kind 6)
               (let First (buffer.u8 V Pos)
                    Delta (ofs-tail V First (+ Pos 1) (shen-jit.bit-and First 127))
                    _ (ensure (> (fst Delta) 0) "invalid zero pack delta offset")
                 (unpack-delta (delta-base Repo I (- At (fst Delta)) (+ Depth 1)) V (snd Delta) Size))
             (= Kind 7)
               (let Width (repo.width Repo)
                    Base (hex (buffer.slice V Pos Width))
                 (unpack-delta (object-read-internal Repo Base (+ Depth 1)) V (+ Pos Width) Size))
             true (@p (pack-type Kind) (pack-inflate V Pos Size)))))

\\ Delta bases by offset, up to 16 MiB for all packs, so that reading along a chain does not
\\ unpack the chain again for each object.
(define delta-base
  Repo I At Depth ->
    (let Found (lookup (pack-index.bases I) At)
      (if (cons? Found) (hd Found) (remember-base Repo I At (unpack-object Repo I At Depth)))))

(define remember-base
  Repo I At Object ->
    (let Charge (+ 256 (buffer.length (snd Object)))
         Limit 16777216
      (if (> Charge Limit) Object
          (do (if (> (+ Charge (repo.base-size Repo)) Limit)
                  (do (map (/. J (pack-index.bases-> J (dictionary))) (pack-indexes Repo))
                      (repo.base-size-> Repo 0))
                  true)
              (remember (pack-index.bases I) At Object)
              (repo.base-size-> Repo (+ Charge (repo.base-size Repo)))
              Object))))

(define packed-object
  Repo Id Depth ->
    (let Found (pack-find (pack-indexes Repo) (unhex Id (repo.width Repo)) (repo.width Repo))
      (if (empty? Found) [] [(unpack-object Repo (fst (hd Found)) (snd (hd Found)) Depth)])))
)

(shen.x.namespace git
  (use fs)
  (use buffer)
  (use shen-jit)
  (import struct defstruct)
  (export read-index entry entry.path entry.mode entry.id entry.stage write-tree!)

(defstruct entry
  (path : string) (mode : number) (id : string) (stage : number) (stat : buffer.view)
  (flags : number) (extended : number))

(define checked-work-path
  Path ->
    (let Parts (split Path 47)
      (do (ensure (and (<= (size Path) 4096) (not (suffix? "/" Path))
                        (not (empty? Parts))) (make-string "invalid index path ~S" Path))
          (map (fn checked-name) Parts)
          Path)))

(define make-entry
  Path Mode Id -> (stat-entry Path Mode Id (buffer.new (index-stat.size))))

(define stat-entry
  Path Mode Id Stat ->
    (:entry path <- Path mode <- Mode id <- Id stage <- 0 stat <- Stat flags <- 0 extended <- 0))

(define same-bytes?
  _ _ At At -> true
  A B At End -> (and (= (buffer.u8 A At) (buffer.u8 B At)) (same-bytes? A B (+ At 1) End)))

\\ Stat data that matches the file's, but for the mode, which the caller compares, and that is
\\ not as recent as the index file, whose writer could have missed a later change in the same tick.
(define unchanged?
  Repo [E] Stat -> (and (unchanged-stat? (entry.stat E) Stat) (not (racy? Repo (entry.stat E))))
  _ _ _ -> false)

(define unchanged-stat?
  Old Stat -> (and (same-bytes? Old Stat 0 24) (same-bytes? Old Stat 28 40)))

(define racy?
  Repo Stat -> (racy-since? Stat (repo.index-stamp Repo)))

(define racy-since?
  _ [] -> false
  Stat [Stamp] -> (let S (index-stat.mtime-seconds Stat 0)
                       T (index-stat.mtime-seconds Stamp 0)
                    (or (> S T) (and (= S T) (>= (index-stat.mtime-nanoseconds Stat 0)
                                                  (index-stat.mtime-nanoseconds Stamp 0))))))

\\ A zero size makes a racily clean entry whose file changed look changed to Git and to us.
(define smudge
  E -> (let Stat (buffer.new (index-stat.size))
            _ (buffer.copy-into! Stat 0 (entry.stat E) 0 (index-stat.size))
         (:entry path <- (entry.path E) mode <- (entry.mode E) id <- (entry.id E)
                 stage <- (entry.stage E) stat <- (index-stat.file-size-> Stat 0 0)
                 flags <- (entry.flags E) extended <- (entry.extended E))))

(define index-mode
  Mode -> (cases (= (shen-jit.bit-and Mode 61440) 32768)
                   (if (= (shen-jit.bit-and Mode 64) 0) 33188 33261)
                 (element? Mode [40960 57344]) Mode
                 true (git-error "unsupported index file mode")))

(define read-index-name
  V At End Version Old ->
    (let Prefix (if (= Version 4)
                    (let B (buffer.u8 V At)
                      (ofs-tail V B (+ At 1) (shen-jit.bit-and B 127)))
                    (@p 0 At))
         Nul (find-byte V 0 (snd Prefix) End)
         _ (ensure (< Nul End) "unterminated index path")
         Suffix (buffer.string (buffer.slice V (snd Prefix) (- Nul (snd Prefix))))
         _ (ensure (<= (fst Prefix) (size Old)) "invalid index path prefix")
         Path (if (= Version 4)
                  (cn (nth-byte Old 0 (- (size Old) (fst Prefix))) Suffix)
                  Suffix)
      (@p (checked-work-path Path) (+ Nul 1))))

(define round-eight
  N -> (shen-jit.bit-and (+ N 7) -8))

(define check-padding
  _ At At -> true
  V At End ->
    (and (= (buffer.u8 V At) 0) (check-padding V (+ At 1) End)))

(define entry-before?
  A B ->
    (if (= (entry.path A) (entry.path B)) (< (entry.stage A) (entry.stage B))
        (bytes< (entry.path A) (entry.path B))))

(define read-index-entries
  V _ 0 At _ Rev -> (do (check-index-extensions V At (buffer.length V)) (reverse Rev))
  V Width Left At Version Rev ->
    (let Stat (buffer.slice V At (index-stat.size))
         Mode (index-mode (index-stat.mode Stat 0))
         Id (hex (buffer.slice V (+ At (index-stat.size)) Width))
         FlagsAt (+ (+ At (index-stat.size)) Width)
         Flags (buffer.u16-be V FlagsAt)
         HasExtended (> (shen-jit.bit-and Flags 16384) 0)
         _ (ensure (or (not HasExtended) (> Version 2)) "extended flags in index version 2")
         Extended (if HasExtended (buffer.u16-be V (+ FlagsAt 2)) 0)
         _ (ensure (= (shen-jit.bit-and Extended 40959) 0) "unsupported index entry flags")
         NameAt (+ FlagsAt (if HasExtended 4 2))
         Old (if (empty? Rev) "" (entry.path (hd Rev)))
         Found (read-index-name V NameAt (buffer.length V) Version Old)
         Path (fst Found)
         Next (if (= Version 4) (snd Found) (+ At (round-eight (- (snd Found) At))))
         _ (ensure (<= Next (buffer.length V)) "truncated index padding")
         _ (ensure (check-padding V (snd Found) Next) "nonzero index padding")
         Stage (shen-jit.bit-and (shen-jit.shift-right Flags 12) 3)
         _ (ensure (= (shen-jit.bit-and Flags 4095) (if (< (size Path) 4095) (size Path) 4095))
                   "index path length does not match")
         E (:entry path <- Path mode <- Mode id <- Id stage <- Stage stat <- Stat
                   flags <- (shen-jit.bit-and Flags 32768) extended <- Extended)
         _ (ensure (or (empty? Rev) (entry-before? (hd Rev) E)) "unordered or duplicate index entry")
      (read-index-entries V Width (- Left 1) Next Version [E | Rev])))

(define check-index-extensions
  _ At At -> true
  V At End ->
    (let _ (ensure (<= (+ At 8) End) "truncated index extension")
         Key (buffer.u8 V At)
         Size (buffer.u32-be V (+ At 4))
         _ (ensure (and (>= Key 65) (<= Key 90))
                   (cn "unsupported required index extension " (buffer.string (buffer.slice V At 4))))
         Next (+ (+ At 8) Size)
         _ (ensure (<= Next End) "truncated index extension data")
      (check-index-extensions V Next End)))

(define index-path
  Repo -> (fs.join (repo.dir Repo) "index"))

(define parse-index
  Repo Raw ->
    (let V (verify-digest (repo.width Repo) Raw "index")
         _ (ensure (>= (buffer.length V) (index-header.size)) "truncated index header")
         _ (ensure (= (index-header.signature V 0) (index-signature)) "invalid index signature")
         Version (index-header.version V 0)
         _ (ensure (element? Version [2 3 4]) "unsupported index version")
         Count (index-header.count V 0)
         _ (ensure (<= Count 1000000) "index entry count exceeds limit")
      (read-index-entries V (repo.width Repo) Count (index-header.size) Version [])))

\\ The index file's stat data, taken before reading it, dates its entries' stat data.
(define read-index
  Repo ->
    (let Path (index-path Repo)
         _ (repo.index-stamp-> Repo (stat-block Path))
         Raw (read-optional Path (object-limit))
      (if (empty? Raw) [] (parse-index Repo (hd Raw)))))

(define index-extended?
  [] -> false
  [E | More] -> (or (> (entry.extended E) 0) (index-extended? More)))

(define serialize-entry
  B Width E ->
    (let Size (size (entry.path E))
         Extended (entry.extended E)
         Flags (+ (+ (+ (entry.flags E) (* 4096 (entry.stage E)))
                      (if (= Extended 0) 0 16384))
                  (if (< Size 4095) Size 4095))
         Start (buffer.builder-length B)
         Stat (buffer.new (index-stat.size))
         _ (buffer.copy-into! Stat 0 (entry.stat E) 0 (index-stat.size))
         _ (index-stat.mode-> Stat 0 (entry.mode E))
         _ (buffer.append! B Stat)
         _ (buffer.append! B (unhex (entry.id E) Width))
         _ (store-u16 B Flags)
         _ (if (= Extended 0) B (store-u16 B Extended))
         _ (store-text B (entry.path E))
         _ (buffer.append-byte! B 0)
         Length (- (buffer.builder-length B) Start)
         Pad (- (round-eight Length) Length)
      (buffer.append! B (buffer.new Pad))))

(define serialize-entries
  B _ [] -> B
  B Width [E | More] -> (serialize-entries (serialize-entry B Width E) Width More))

(define encode-index
  Repo Index ->
    (let Count (length Index)
         _ (ensure (<= Count 1000000) "index entry count exceeds limit")
         B (buffer.builder (object-limit))
         _ (buffer.append! B (encode-index-header (if (index-extended? Index) 3 2) Count))
         _ (serialize-entries B (repo.width Repo) Index)
      (with-digest (repo.width Repo) (buffer.finish B))))

(define finish-index!
  Repo Lock Index ->
    (finish-lock Lock (index-path Repo) (encode-index Repo (order-by (fn entry-before?) Index))))

(define regular-index?
  [] -> true
  [E | More] -> (and (= (entry.stage E) 0)
                    (= (shen-jit.bit-and (entry.extended E) 8192) 0)
                    (regular-index? More)))

(define tree-key
  E -> (mode-path (tree-entry.mode E) (tree-entry.name E)))

(define tree-before?
  A B -> (bytes< (tree-key A) (tree-key B)))

(define split-path
  Path -> (partition-text Path 47))

(define insert-tree-path
  Table Path Mode Id ->
    (let Part (split-path Path)
         Name (fst Part)
         Rest (snd Part)
         Found (lookup Table Name)
      (if (= Rest "")
          (do (ensure (empty? Found) (cn "duplicate tree path " Path))
              (remember Table Name (:tree-entry name <- Name mode <- Mode id <- Id)))
          (let Sub (if (empty? Found) (dictionary)
                       (do (ensure (shen.dict? (hd Found)) (cn "file and directory collide at " Name))
                           (hd Found)))
            (do (insert-tree-path Sub Rest Mode Id) (remember Table Name Sub))))))

(define tree-from-index
  [] D -> D
  [E | More] D ->
    (do (insert-tree-path D (entry.path E) (entry.mode E) (entry.id E))
        (tree-from-index More D)))

(define materialize-tree
  Repo [Name | Item] ->
    (if (shen.dict? Item)
        (:tree-entry name <- Name mode <- 16384 id <- (write-tree-table Repo Item))
        Item))

(define encode-tree-entries
  B _ [] -> (buffer.finish B)
  B Width [E | Rest] ->
    (do (store-text B (cn (file-mode-text (tree-entry.mode E)) (cn " " (tree-entry.name E))))
        (buffer.append-byte! B 0)
        (buffer.append! B (unhex (tree-entry.id E) Width))
        (encode-tree-entries B Width Rest)))

(define write-tree-table
  Repo Table ->
    (let Items (map (materialize-tree Repo) (entries Table))
         Sorted (order-by (fn tree-before?) Items)
      (write-object! Repo "tree" (encode-tree-entries (buffer.builder (object-limit)) (repo.width Repo) Sorted))))

(define write-tree!
  Repo Index ->
    (do (ensure (regular-index? Index) "cannot write tree with unresolved or intent-to-add entries")
        (write-tree-table Repo (tree-from-index Index (dictionary)))))

(define expand-tree-entries
  _ [] _ _ Acc -> Acc
  Repo [E | Rest] Path Depth Acc ->
    (let Name (cn Path (tree-entry.name E))
         Mode (tree-entry.mode E)
         Next (if (= Mode 16384)
                  (expand-tree Repo (tree-entry.id E) (cn Name "/") (+ Depth 1) Acc)
                  [(make-entry (checked-work-path Name) Mode (tree-entry.id E)) | Acc])
      (expand-tree-entries Repo Rest Path Depth Next)))

(define expand-tree
  Repo Id Path Depth Acc ->
    (do (ensure (<= Depth 256) "too many tree levels")
        (expand-tree-entries Repo (tree-entries Repo Id) Path Depth Acc)))

(define committed-index
  Repo Id -> (order-by (fn entry-before?) (expand-tree Repo (as-tree Repo Id) "" 0 [])))

(declare read-index [repo --> [list entry]])
(declare write-tree! [repo --> [[list entry] --> string]])
)

(shen.x.namespace git
  (use buffer)
  (use option)
  (use shen-jit)
  (export worktree-changes staged-changes revision-changes change change-code change.path change.before
    change.after write-patch quote-path)

(define worktree-changes
  Repo Base ->
    (let Index (diff-index Repo)
         Before (if (empty? Base) Index (committed-index Repo (hd Base)))
      (checkout-changes (compare-trees Before (working-index Repo Index)))))

(define staged-changes
  Repo Base ->
    (let Before (if (empty? Base) (head-index Repo) (committed-index Repo (hd Base)))
      (checkout-changes (compare-trees Before (diff-index Repo)))))

(define revision-changes
  Repo A B ->
    (checkout-changes (compare-trees (committed-index Repo A) (committed-index Repo B))))

(define diff-index
  Repo ->
    (let Index (read-index Repo)
      (do (ensure (regular-index? Index) "diff needs a resolved index") Index)))

(define change-code
  C -> (entry-change (change.before C) (change.after C)))

\\ Git's C-style quoting, with core.quotepath's default: control bytes, " and \\, and bytes from 127.
(define quote-path
  Text QuoteSpaces ->
    (let V (buffer.from-string Text)
         N (buffer.length V)
      (if (or (and QuoteSpaces (< (find-byte V 32 0 N) N)) (needs-quote? V 0 N))
          (force-quote-path V N)
          Text)))

(define needs-quote?
  _ At At -> false
  V At End ->
    (let C (buffer.u8 V At)
      (or (< C 32) (>= C 127) (= C 34) (= C 92) (needs-quote? V (+ At 1) End))))

(define write-quoted-bytes
  B _ At At -> B
  B V At End ->
    (let C (buffer.u8 V At)
         Letter (if (and (>= C 7) (<= C 13)) (nth (- C 6) [97 98 116 110 118 102 114]) 0)
         _ (cases (> Letter 0) (do (buffer.append-byte! B 92) (buffer.append-byte! B Letter))
                  (element? C [34 92]) (do (buffer.append-byte! B 92) (buffer.append-byte! B C))
                  (or (< C 32) (>= C 127))
                    (do (buffer.append-byte! B 92)
                        (buffer.append-byte! B (+ 48 (shen-jit.shift-right C 6)))
                        (buffer.append-byte! B (+ 48 (shen-jit.bit-and 7 (shen-jit.shift-right C 3))))
                        (buffer.append-byte! B (+ 48 (shen-jit.bit-and 7 C))))
                  true (buffer.append-byte! B C))
      (write-quoted-bytes B V (+ At 1) End)))

(define force-quote-path
  V N ->
    (let B (buffer.builder (+ 2 (* 4 N)))
      (do (buffer.append-byte! B 34)
          (write-quoted-bytes B V 0 N)
          (buffer.append-byte! B 34)
          (buffer.string (buffer.finish B)))))

(define working-index
  Repo Index -> (mapcan (work-index-item Repo) Index))

(define work-index-item
  Repo E ->
    (if (or (> (shen-jit.bit-and (entry.extended E) 16384) 0) (> (entry.flags E) 0))
        [E]
        (work-entry Repo (entry.path E) [E] false)))

(define binary-view?
  V ->
    (let N (buffer.length V) Probe (if (> N 8000) 8000 N)
      (< (find-byte V 0 0 Probe) Probe)))

(define patch-lines
  _ At At Rev -> (reverse Rev)
  V At End Rev ->
    (let Next (find-byte V 10 At End)
         Stop (if (= Next End) End (+ Next 1))
      (patch-lines V Stop End [(buffer.string (buffer.slice V At (- Stop At))) | Rev])))

(define patch-range
  Start Count ->
    (if (= Count 1) (str (+ Start 1))
        (make-string "~A,~A" (if (= Count 0) Start (+ Start 1)) Count)))

(define emit-line
  Emit Text -> (Emit (newline Text)))

(define show-patch-line
  Emit Prefix S ->
    (do (Emit (cn Prefix S))
        (if (suffix? (lf) S) true
            (emit-line Emit "c#10;c#92; No newline at end of file"))))

\\ Lines as vectors of numbers, the same number for the same line, which compare cheaply.
(define line-vector
  Lines -> (fill-vector Lines (vector (length Lines)) 1))

(define fill-vector
  [] V _ -> V
  [X | Xs] V I -> (do (vector-> V I X) (fill-vector Xs V (+ I 1))))

(define line-code
  D Next S -> (let Found (lookup D S)
                (if (cons? Found) (hd Found)
                    (let Code (<-vector Next 1)
                      (do (vector-> Next 1 (+ Code 1)) (remember D S Code) Code)))))

\\ Myers' minimal diff in linear space: the middle snake of an optimal path splits the box from
\\ (L, T) to (R, Bt) in two, which are diffed the same way. Positions count from 0.
(define diff-path
  A B L T R Bt -> (diff-split A B L T R Bt (middle-snake A B L T R Bt)))

(define diff-split
  _ _ _ _ _ _ [] -> []
  A B L T R Bt [SX SY FX FY] ->
    (append (or-point (diff-path A B L T SX SY) [SX SY])
            (or-point (diff-path A B FX FY R Bt) [FX FY])))

(define or-point
  [] Point -> [Point]
  Path _ -> Path)

(define middle-snake
  A B L T R Bt ->
    (let Size (+ (- R L) (- Bt T))
         Off (+ (shen-jit.shift-right (+ Size 1) 1) 2)
      (if (= Size 0) []
          (snake-round A B [L T R Bt (- (- R L) (- Bt T))
                            (vector-> (vector (+ (* 2 Off) 1)) (+ Off 1) L)
                            (vector-> (vector (+ (* 2 Off) 1)) (+ Off 1) Bt) Off] 0))))

(define snake-round
  A B Box D ->
    (let Ahead (snake-forward A B Box D D)
      (if (cons? Ahead) Ahead
          (let Behind (snake-backward A B Box D D)
            (if (cons? Behind) Behind (snake-round A B Box (+ D 1)))))))

(define slide-forward
  A B X Y R Bt ->
    (if (and (< X R) (< Y Bt) (= (<-vector A (+ X 1)) (<-vector B (+ Y 1))))
        (slide-forward A B (+ X 1) (+ Y 1) R Bt) X))

(define slide-backward
  A B X Y L T ->
    (if (and (> X L) (> Y T) (= (<-vector A X) (<-vector B Y)))
        (slide-backward A B (- X 1) (- Y 1) L T) Y))

(define snake-forward
  _ _ _ D K -> [] where (< K (- 0 D))
  A B [L T R Bt Delta VF VB Off] D K ->
    (let Down (or (= K (- 0 D))
                  (and (not (= K D)) (< (<-vector VF (+ Off (- K 1))) (<-vector VF (+ Off (+ K 1))))))
         PX (<-vector VF (+ Off (if Down (+ K 1) (- K 1))))
         X0 (if Down PX (+ PX 1))
         Y0 (- (+ T (- X0 L)) K)
         PY (if (or (= D 0) (not (= X0 PX))) Y0 (- Y0 1))
         X (slide-forward A B X0 Y0 R Bt)
         Y (- (+ T (- X L)) K)
         _ (vector-> VF (+ Off K) X)
         C (- K Delta)
      (if (and (= (shen-jit.bit-and Delta 1) 1) (> C (- 0 D)) (< C D) (>= Y (<-vector VB (+ Off C))))
          [PX PY X Y]
          (snake-forward A B [L T R Bt Delta VF VB Off] D (- K 2)))))

(define snake-backward
  _ _ _ D C -> [] where (< C (- 0 D))
  A B [L T R Bt Delta VF VB Off] D C ->
    (let Up (or (= C (- 0 D))
                (and (not (= C D)) (> (<-vector VB (+ Off (- C 1))) (<-vector VB (+ Off (+ C 1))))))
         PY (<-vector VB (+ Off (if Up (+ C 1) (- C 1))))
         Y0 (if Up PY (- PY 1))
         K (+ C Delta)
         X0 (+ L (+ (- Y0 T) K))
         PX (if (or (= D 0) (not (= Y0 PY))) X0 (+ X0 1))
         Y (slide-backward A B X0 Y0 L T)
         X (+ L (+ (- Y T) K))
         _ (vector-> VB (+ Off C) Y)
      (if (and (= (shen-jit.bit-and Delta 1) 0) (>= K (- 0 D)) (<= K D) (<= X (<-vector VF (+ Off K))))
          [X Y PX PY]
          (snake-backward A B [L T R Bt Delta VF VB Off] D (- C 2)))))

\\ The changed blocks [X0 X1 Y0 Y1] along the path's points, in order.
(define path-blocks
  A B [[X1 Y1] [X2 Y2] | Points] Open Acc ->
    (let Step (segment-blocks A B X1 Y1 X2 Y2 Open Acc)
      (path-blocks A B [[X2 Y2] | Points] (fst Step) (snd Step)))
  _ _ [[X Y]] Open Acc -> (reverse (close-block Open X Y Acc))
  _ _ [] _ _ -> [])

(define segment-blocks
  A B X Y X2 Y2 Open Acc ->
    (cases (and (< X X2) (< Y Y2) (= (<-vector A (+ X 1)) (<-vector B (+ Y 1))))
             (segment-blocks A B (+ X 1) (+ Y 1) X2 Y2 [] (close-block Open X Y Acc))
           (< (- X2 X) (- Y2 Y)) (segment-blocks A B X (+ Y 1) X2 Y2 (open-block Open X Y) Acc)
           (> (- X2 X) (- Y2 Y)) (segment-blocks A B (+ X 1) Y X2 Y2 (open-block Open X Y) Acc)
           true (@p Open Acc)))

(define open-block
  [] X Y -> [X Y]
  Open _ _ -> Open)

(define close-block
  [] _ _ Acc -> Acc
  [X0 Y0] X Y Acc -> [[X0 X Y0 Y] | Acc])

\\ Changes at most twice the context apart share a hunk, as in Git.
(define hunk-groups
  [] -> []
  [Block | Blocks] -> (hunk-run [Block] Blocks))

(define hunk-run
  Run [] -> [(reverse Run)]
  [Last | Run] [Block | Blocks] ->
    (if (<= (- (hd Block) (nth 2 Last)) 6)
        (hunk-run [Block Last | Run] Blocks)
        [(reverse [Last | Run]) | (hunk-run [Block] Blocks)]))

(define show-lines
  Emit Prefix V At End ->
    (if (>= At End) true
        (do (show-patch-line Emit Prefix (<-vector V (+ At 1)))
            (show-lines Emit Prefix V (+ At 1) End))))

(define show-blocks
  Emit Old New At End [] -> (show-lines Emit " " Old At End)
  Emit Old New At End [[X0 X1 Y0 Y1] | Blocks] ->
    (do (show-lines Emit " " Old At X0)
        (show-lines Emit "-" Old X0 X1)
        (show-lines Emit "+" New Y0 Y1)
        (show-blocks Emit Old New X1 End Blocks)))

(define show-hunk
  Emit Old New Group ->
    (let First (hd Group)
         Last (hd (reverse Group))
         Start (if (> (hd First) 3) (- (hd First) 3) 0)
         End (if (> (- (limit Old) (nth 2 Last)) 3) (+ (nth 2 Last) 3) (limit Old))
         NewStart (- (nth 3 First) (- (hd First) Start))
         NewEnd (+ (nth 4 Last) (- End (nth 2 Last)))
      (do (emit-line Emit (make-string "@@ -~A +~A @@" (patch-range Start (- End Start))
                                                       (patch-range NewStart (- NewEnd NewStart))))
          (show-blocks Emit Old New Start End Group))))

(define unified-hunks
  Emit Before After ->
    (let D (dictionary)
         Next (vector-> (vector 1) 1 0)
         Old (line-vector Before)
         New (line-vector After)
         A (line-vector (map (line-code D Next) Before))
         B (line-vector (map (line-code D Next) After))
         Blocks (path-blocks A B (diff-path A B 0 0 (limit A) (limit B)) [] [])
      (map (show-hunk Emit Old New) (hunk-groups Blocks))))

(define patch-object
  _ [] -> (buffer.new 0)
  Repo [E] ->
    (if (= (entry.mode E) 57344)
        (buffer.from-string (newline (cn "Subproject commit " (entry.id E))))
        (require-type Repo (entry.id E) "blob")))

(define patch-work
  _ [] -> (buffer.new 0)
  Repo [E] ->
    (if (or (= (entry.mode E) 57344) (> (entry.extended E) 0) (> (entry.flags E) 0))
        (patch-object Repo [E])
        (let Name (entry.path E)
             _ (ensure (parents-clear? Repo (parent-prefix Name)) (cn "path changed during diff: " Name))
             Body (file-data (work-path Repo Name) (path-mode Repo Name))
             _ (ensure (= (entry.id E) (object-id Repo "blob" Body))
                       (cn "file changed during diff: " Name))
          Body)))

(define patch-id
  [] -> "0000000"
  [E] -> (nth-byte (entry.id E) 0 7))

(define show-mode-change
  Emit [] [New] -> (emit-line Emit (cn "new file mode " (display-mode (entry.mode New))))
  Emit [Old] [] -> (emit-line Emit (cn "deleted file mode " (display-mode (entry.mode Old))))
  Emit [Old] [New] ->
    (if (= (entry.mode Old) (entry.mode New)) true
        (do (emit-line Emit (cn "old mode " (display-mode (entry.mode Old))))
            (emit-line Emit (cn "new mode " (display-mode (entry.mode New)))))))

(define show-index-line
  Emit Old New ->
    (let Mode (if (and (cons? Old) (cons? New) (= (entry.mode (hd Old)) (entry.mode (hd New))))
                   (cn " " (display-mode (entry.mode (hd New)))) "")
      (emit-line Emit (make-string "index ~A..~A~A" (patch-id Old) (patch-id New) Mode))))

\\ Git ends a name with a space in the ---/+++ lines with a tab.
(define name-tab
  Name -> (let V (buffer.from-string Name)
            (if (< (find-byte V 32 0 (buffer.length V)) (buffer.length V)) (cn Name "c#9;") Name)))

(define patch-content
  Emit A B Old New Left Right ->
    (do (show-index-line Emit Old New)
        (cases (and (= (buffer.length Left) 0) (= (buffer.length Right) 0)) true
               (or (binary-view? Left) (binary-view? Right))
                 (emit-line Emit (make-string "Binary files ~A and ~A differ" A B))
               true
                 (do (emit-line Emit (cn "--- " (name-tab A)))
                     (emit-line Emit (cn "+++ " (name-tab B)))
                     (unified-hunks Emit (patch-lines Left 0 (buffer.length Left) [])
                                    (patch-lines Right 0 (buffer.length Right) []))))))

(define write-patch
  Repo Work C Emit ->
    (let Path (change.path C)
         Old (change.before C)
         New (change.after C)
         A (quote-path (cn "a/" Path) false)
         B (quote-path (cn "b/" Path) false)
         _ (emit-line Emit (make-string "diff --git ~A ~A" A B))
         _ (show-mode-change Emit Old New)
         Oid (map (fn entry.id) Old)
         Nid (map (fn entry.id) New)
      (do (if (= Oid Nid) true
              (patch-content Emit (if (empty? Old) "/dev/null" A)
                             (if (empty? New) "/dev/null" B)
                             Old New (patch-object Repo Old)
                             (if Work (patch-work Repo New) (patch-object Repo New))))
          true)))

(declare worktree-changes [repo --> [[option.t string] --> [list change]]])
(declare staged-changes [repo --> [[option.t string] --> [list change]]])
(declare revision-changes [repo --> [string --> [string --> [list change]]]])
(declare change-code [change --> string])
(declare write-patch [repo --> [boolean --> [change --> [[string --> A] --> boolean]]]])
(declare quote-path [string --> [boolean --> string]])
)

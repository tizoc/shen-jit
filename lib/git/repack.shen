(shen.x.namespace git
  (use fs)
  (use buffer)
  (use shen-jit)
  (export repack! clone!)
  (externals [file directory])

(define graph-width
  -> 1000000)

(define object-edges
  Repo _ "tree" Body ->
    (mapcan (/. E (if (= (tree-entry.mode E) 57344) [] [(tree-entry.id E)]))
      (read-tree-items Body (repo.width Repo) 0 (buffer.length Body) "" []))
  Repo Id "commit" Body ->
    [(one-header Body "tree")
     | (if (element? Id (repo.shallow Repo)) [] (header-values Body "parent"))]
  _ _ "tag" Body -> [(one-header Body "object")]
  _ _ "blob" _ -> [])

(define gather-objects
  _ [] _ Rev _ -> (reverse Rev)
  Repo [Id | Pending] D Rev Count ->
    (if (cons? (lookup D Id)) (gather-objects Repo Pending D Rev Count)
        (let _ (ensure (< Count (graph-width)) "reachable objects exceed count limit")
             Object (read-object Repo Id)
             Edges (object-edges Repo Id (fst Object) (snd Object))
          (do (remember D Id true)
              (gather-objects Repo (append Edges Pending) D [Id | Rev] (+ Count 1))))))

(define pack-kind
  "commit" -> 1
  "tree" -> 2
  "blob" -> 3
  "tag" -> 4)

(define pack-length-tail
  B 0 -> B
  B N ->
    (let Next (shen-jit.shift-right N 7)
         Byte (shen-jit.bit-or (shen-jit.bit-and N 127) (if (= Next 0) 0 128))
      (pack-length-tail (buffer.append-byte! B Byte) Next)))

(define pack-record
  Object ->
    (let Body (snd Object)
         Size (buffer.length Body)
         B (buffer.builder (+ (+ Size (shen-jit.shift-right Size 8)) 128))
         Rest (shen-jit.shift-right Size 4)
         Kind (shen-jit.shift-left (pack-kind (fst Object)) 4)
         Byte (+ (+ Kind (shen-jit.bit-and Size 15)) (if (= Rest 0) 0 128))
         _ (buffer.append-byte! B Byte)
         _ (pack-length-tail B Rest)
         _ (buffer.append! B (deflate Body))
      (buffer.finish B)))

(define crc32
  V -> (c-crc32 (buffer.owner V) (buffer.offset V) (buffer.length V)))

(define pack-rows
  _ [] _ Rev -> Rev
  Repo [Id | Ids] B Rev ->
    (let Offset (buffer.builder-length B)
         Chunk (pack-record (read-object Repo Id))
         CRC (crc32 Chunk)
      (do (buffer.append! B Chunk) (pack-rows Repo Ids B [[Id Offset CRC] | Rev]))))

(define zero-fanout
  Counts 257 -> Counts
  Counts At -> (do (vector-> Counts At 0) (zero-fanout Counts (+ At 1))))

(define fanout-counts
  [] Counts -> Counts
  [[Id _ _] | Rest] Counts ->
    (let V (buffer.from-string Id)
         Byte (+ (* (nibble (buffer.u8 V 0)) 16) (nibble (buffer.u8 V 1)))
      (do (vector-> Counts (+ Byte 1) (+ (<-vector Counts (+ Byte 1)) 1))
          (fanout-counts Rest Counts))))

(define emit-fanout
  _ _ 256 _ -> true
  B Counts At Total ->
    (let Next (+ Total (<-vector Counts (+ At 1)))
      (do (store-u32 B Next) (emit-fanout B Counts (+ At 1) Next))))

(define rows-by-id
  [A _ _] [B _ _] -> (bytes< A B))

(define pack-index-bytes
  Width Rows Sum ->
    (let B (buffer.builder (pack-limit))
         Counts (fanout-counts Rows (zero-fanout (vector 256) 1))
         _ (buffer.append! B (encode-pack-index-header))
         _ (emit-fanout B Counts 0 0)
         _ (map (/. Row (buffer.append! B (unhex (hd Row) Width))) Rows)
         _ (map (/. Row (store-u32 B (nth 3 Row))) Rows)
         _ (map (/. Row (store-u32 B (nth 2 Row))) Rows)
         _ (buffer.append! B Sum)
      (with-digest Width (buffer.finish B))))

(define create-pack
  Repo [] -> []
  Repo Objects ->
    (let B (buffer.builder (- (pack-limit) (repo.width Repo)))
         _ (buffer.append! B (encode-pack-header (length Objects)))
         Rows (order-by (fn rows-by-id) (pack-rows Repo Objects B []))
         Width (repo.width Repo)
         Pack (with-digest Width (buffer.finish B))
         Sum (buffer.slice Pack (- (buffer.length Pack) Width) Width)
      [(@p (hex Sum) (@p Pack (pack-index-bytes Width Rows Sum)))]))

(define store-pack
  _ [] -> []
  Repo [(@p Digest (@p Pack Index))] ->
    (let Stem (fs.join (fs.join (hd (repo.object-dirs Repo)) "pack") (cn "pack-" Digest))
         _ (folders (fs.parent Stem))
      (do (write-new (cn Stem ".pack") Pack 292)
          (write-new (cn Stem ".idx") Index 292)
          (reset-packs! Repo)
          [Digest])))

(define pack-roots
  Repo Roots -> (create-pack Repo (gather-objects Repo Roots (dictionary) [] 0)))

\\ One pack of what refs, HEAD and the indexes of every worktree reach. Objects of the old packs
\\ that it leaves out are written loose first, so that nothing is lost; then the old packs and the
\\ loose copies of what it holds go. A pack with a .keep file stays as it is.
(define repack!
  Repo ->
    (let Objects (gather-objects Repo (repack-roots Repo) (dictionary) [] 0)
         Own (fs.join (hd (repo.object-dirs Repo)) "pack")
         Old (mapcan (/. I (if (and (= (fs.parent (pack-index.path I)) Own)
                                    (= (node (pack-stem I ".keep")) absent)) [I] []))
                     (pack-indexes Repo))
         Kept (dictionary)
         _ (map (/. Id (remember Kept Id true)) Objects)
         Stored (store-pack Repo (create-pack Repo Objects))
         New (map (/. Digest (fs.join Own (cn "pack-" (cn Digest ".pack")))) Stored)
         Gone (mapcan (/. I (if (element? (pack-index.path I) New) [] [I])) Old)
         _ (map (loosen-pack! Repo Kept) Gone)
         _ (map (/. I (map (/. Ext (remove-present! (pack-stem I Ext))) [".bitmap" ".rev" ".mtimes" ".idx" ".pack"]))
                Gone)
         _ (if (empty? Gone) true (remove-present! (fs.join Own "multi-pack-index")))
         _ (prune-packed! (hd (repo.object-dirs Repo)) Kept)
      (do (reset-packs! Repo) Stored)))

(define repack-roots
  Repo ->
    (let Base (fs.join (repo.common Repo) "worktrees")
         Linked (if (= (node Base) directory) (map (/. Name (fs.join Base Name)) (names Base)) [])
      (append (ref-value Repo "HEAD") (map (fn snd) (refs Repo))
              (mapcan (index-roots Repo) [(repo.common Repo) | Linked])
              (mapcan (/. Dir (let Head (strip-eol (control-or (fs.join Dir "HEAD") ""))
                                (if (hex? Head (repo.width Repo)) [Head] [])))
                      Linked))))

(define index-roots
  Repo Dir ->
    (let Raw (read-optional (fs.join Dir "index") (object-limit))
      (if (empty? Raw) []
          (mapcan (/. E (if (= (entry.mode E) 57344) [] [(entry.id E)])) (parse-index Repo (hd Raw))))))

(define pack-stem
  I Ext -> (cn (before (pack-index.path I) ".pack") Ext))

(define remove-present!
  Path -> (if (= (node Path) absent) true (unwrap (fs.remove-file Path))))

(define loosen-pack!
  Repo Kept I -> (loosen-rows Repo Kept I 0))

(define loosen-rows
  Repo Kept I N ->
    (if (= N (pack-index.count I)) true
        (let Id (hex (pack-id-at I N (repo.width Repo)))
             _ (if (cons? (lookup Kept Id)) true
                   (let Object (read-object Repo Id)
                     (write-loose! Repo Id (object-data (fst Object) (snd Object)))))
          (loosen-rows Repo Kept I (+ N 1)))))

\\ Loose objects that the new pack holds, and the fan-out directories that empties.
(define prune-packed!
  Objects Kept ->
    (map (/. Fan (let Dir (fs.join Objects Fan)
                   (if (and (= (size Fan) 2) (hex-bytes? (buffer.from-string Fan) 0 2) (= (node Dir) directory))
                       (do (map (/. Name (if (cons? (lookup Kept (cn Fan Name)))
                                             (unwrap (fs.remove-file (fs.join Dir Name))) true))
                                (names Dir))
                           (if (empty? (names Dir)) (unwrap (fs.remove-directory Dir)) true))
                       true)))
         (names Objects)))

(define clone-refs
  Repo -> (mapcan (/. Pair (if (or (prefix? "refs/heads/" (fst Pair))
                                (prefix? "refs/tags/" (fst Pair))) [Pair] [])) (refs Repo)))

(define copy-clone-refs
  _ _ _ [] -> true
  Repo Bare Initial [(@p Ref Id) | Rest] ->
    (do (cases (or Bare (prefix? "refs/tags/" Ref)) (require-update (set-ref! Repo Ref Id []) Ref)
               (= Ref Initial) true
               true (let Remote (cn "refs/remotes/origin/" (after "refs/heads/" Ref))
                      (require-update (set-ref! Repo Remote Id []) Remote)))
        (copy-clone-refs Repo Bare Initial Rest)))

\\ A failed clone removes what it made.
(define clone!
  Source Directory Bare ->
    (let _ (ensure (empty-directory? Directory) "clone destination must be an empty directory")
         Existed (= (node Directory) directory)
      (shen-jit.on-error (freeze (clone-into Source Directory Bare))
                         (freeze (if Existed
                                     (map (/. Name (remove-tree! (fs.join Directory Name))) (names Directory))
                                     (remove-tree! Directory))))))

(define clone-into
  Source Directory Bare ->
    (let Origin (open-repo Source)
         _ (ensure (= (repo.shallow Origin) []) "local clone needs complete history")
         Head (head-ref Origin)
         Selected (ref-value Origin "HEAD")
         R (clone-refs Origin)
         Packed (pack-roots Origin (append Selected (map (fn snd) R)))
         Branch (if (prefix? "refs/heads/" Head) (after "refs/heads/" Head) "main")
         Dest (init Directory Bare Branch (if (= (repo.width Origin) 20) "sha1" "sha256"))
         _ (store-pack Dest Packed)
         _ (copy-clone-refs Dest Bare Head R)
      (do (if (empty? Selected) true
              (let Id (hd Selected)
                   Path (ref-path Dest "HEAD")
                   Expected (control Path)
                (cases (and Bare (= Head "HEAD"))
                         (with-lock Path (/. Lock (finish-lock Lock Path (buffer.from-string (newline Id)))))
                       Bare true
                       (= Head "HEAD") (require-switch (checkout! Dest Id Path Expected Id))
                       true (do (require-switch (checkout! Dest Id Path Expected (cn "ref: " Head)))
                                (require-update (set-ref! Dest Head Id []) Head)))))
          Dest)))

(define remove-tree!
  Path -> (if (= (node Path) directory)
              (do (map (/. Name (remove-tree! (fs.join Path Name))) (names Path))
                  (unwrap (fs.remove-directory Path)))
              (unwrap (fs.remove-file Path))))

(declare clone! [string --> [string --> [boolean --> repo]]])
(declare repack! [repo --> [list string]])
)

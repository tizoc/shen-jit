(shen.x.namespace git
  (use fs)
  (use buffer)
  (use shen-jit)
  (import struct defstruct)
  (externals [directory file])
  (export object-id read-object write-object! hash-file resolve-revision as-tree
    tree-entries tree-entry tree-entry.name tree-entry.mode tree-entry.id commit-parents mode-kind
    display-mode)

(defstruct tree-entry (name : string) (mode : number) (id : string))

(define git-type?
  Kind -> (element? Kind ["blob" "tree" "commit" "tag"]))

(define object-data
  Kind Body ->
    (let _ (ensure (git-type? Kind) "invalid object type")
         _ (ensure (<= (buffer.length Body) (object-limit)) "object exceeds size limit")
         Header (buffer.from-string (make-string "~A ~A~A" Kind (buffer.length Body) (zero)))
         Bytes (buffer.new (+ (buffer.length Header) (buffer.length Body)))
      (do (buffer.copy-into! Bytes 0 Header 0 (buffer.length Header))
          (buffer.copy-into! Bytes (buffer.length Header) Body 0 (buffer.length Body))
          Bytes)))

(define object-id
  Repo Kind Body -> (hex (digest (repo.width Repo) (object-data Kind Body))))

(define loose-path
  Objects Id ->
    (fs.join Objects (cn (nth-byte Id 0 2) (cn "/" (nth-byte Id 2 (- (size Id) 2))))))

(define hash-file
  Repo Path Kind Write ->
    (let Body (read-view Path (object-limit))
      (if Write (write-object! Repo Kind Body) (object-id Repo Kind Body))))

(define object-location
  Repo Id -> (loose-path (hd (repo.object-dirs Repo)) Id))

(define loose-object
  [] _ -> []
  [Directory | More] Id ->
    (let Found (read-optional (loose-path Directory Id) (+ (object-limit) 1048576))
      (if (cons? Found) Found (loose-object More Id))))

\\ Loose objects are read-only, as Git writes them.
(define write-object!
  Repo Kind Body ->
    (let Raw (object-data Kind Body)
         Id (hex (digest (repo.width Repo) Raw))
      (do (if (has-object? Repo Id) true (write-loose! Repo Id Raw)) Id)))

(define write-loose!
  Repo Id Raw ->
    (let Path (object-location Repo Id)
      (do (folders (fs.parent Path)) (write-new Path (deflate Raw) 292))))

(define has-object?
  Repo Id ->
    (or (cons? (lookup (repo.object-cache Repo) Id))
        (cons? (pack-find (pack-indexes Repo) (unhex Id (repo.width Repo)) (repo.width Repo)))
        (some? (/. Dir (= (node (loose-path Dir Id)) file)) (repo.object-dirs Repo))))

(define loose-body
  Repo Id Bytes ->
    (let Result (inflate Bytes 0 (buffer.length Bytes) (+ (object-limit) 40))
         Raw (fst Result)
         N (buffer.length Raw)
         _ (ensure (= (snd Result) (buffer.length Bytes)) "trailing data in loose object")
         _ (ensure (= (hex (digest (repo.width Repo) Raw)) Id) "loose object hash does not match")
         Space (find-byte Raw 32 0 N)
         End (find-byte Raw 0 Space N)
         _ (ensure (and (< Space End) (< End N)) "missing loose object header")
         Kind (buffer.string (buffer.slice Raw 0 Space))
         _ (ensure (git-type? Kind) "invalid loose object type")
         Len (decimal (buffer.string (buffer.slice Raw (+ Space 1) (- (- End Space) 1))))
         _ (ensure (= Len (- (- N End) 1)) "loose object length does not match")
      (@p Kind (buffer.slice Raw (+ End 1) Len))))

(define cache-object
  Repo Id Object ->
    (let Charge (+ 256 (buffer.length (snd Object)))
         Used (+ Charge (repo.cache-size Repo))
      (do (if (<= Used 33554432)
              (do (remember (repo.object-cache Repo) Id Object)
                  (repo.cache-size-> Repo Used))
              true)
          Object)))

(define read-uncached
  Repo Id Depth ->
    (read-found Repo Id Depth (loose-object (repo.object-dirs Repo) Id)))

(define read-found
  Repo Id _ [Bytes] -> (loose-body Repo Id Bytes)
  Repo Id Depth [] -> (packed-found Id (packed-object Repo Id Depth)))

(define packed-found
  _ [Object] -> Object
  Id [] -> (git-error (cn "missing object " Id)))

(define object-read-internal
  Repo Id Depth ->
    (do (ensure (<= Depth 256) "too many pack delta levels")
        (let Found (lookup (repo.object-cache Repo) Id)
          (if (cons? Found) (hd Found) (cache-object Repo Id (read-uncached Repo Id Depth))))))

(define read-object
  Repo Id ->
    (do (ensure (hex? Id (repo.width Repo)) (make-string "invalid object ID ~S" Id))
        (object-read-internal Repo (lowercase Id) 0)))

(define require-type
  Repo Id Kind ->
    (let Object (read-object Repo Id)
      (do (ensure (= (fst Object) Kind) (make-string "~A is a ~A, expected ~A" Id (fst Object) Kind))
          (snd Object))))

(define file-part?
  S ->
    (let V (buffer.from-string S)
         N (buffer.length V)
      (and (> N 0) (not (element? (lowercase S) ["." ".." ".git" "git~1"]))
           (= (find-byte V 0 0 N) N) (= (find-byte V 47 0 N) N))))

(define checked-name
  S -> (do (ensure (file-part? S) (make-string "unsupported or invalid Git pathname component ~S" S)) S))

(define file-mode
  "40000" -> 16384
  "040000" -> 16384
  "100644" -> 33188
  "100755" -> 33261
  "100664" -> 33188
  "120000" -> 40960
  "160000" -> 57344
  S -> (git-error (cn "unsupported tree file mode " S)))

(define file-mode-text
  16384 -> "40000"
  33188 -> "100644"
  33261 -> "100755"
  40960 -> "120000"
  57344 -> "160000"
  _ -> (git-error "unsupported file mode"))

(define display-mode
  16384 -> "040000"
  Mode -> (file-mode-text Mode))

(define mode-kind
  16384 -> "tree"
  57344 -> "commit"
  _ -> "blob")

(define mode-path
  16384 Path -> (cn Path "/")
  _ Path -> Path)

(define read-tree-items
  _ _ At At _ Rev -> (reverse Rev)
  V Width At End Last Rev ->
    (let Space (find-byte V 32 At End)
         Nul (find-byte V 0 Space End)
         Next (+ (+ Nul 1) Width)
         _ (ensure (and (< Space Nul) (<= Next End)) "truncated tree entry")
         Mode (file-mode (buffer.string (buffer.slice V At (- Space At))))
         Name (checked-name (buffer.string (buffer.slice V (+ Space 1) (- (- Nul Space) 1))))
         Key (mode-path Mode Name)
         _ (ensure (or (= Last "") (bytes< Last Key)) "unordered or duplicate tree entry")
         Id (hex (buffer.slice V (+ Nul 1) Width))
      (read-tree-items V Width Next End Key [(:tree-entry name <- Name mode <- Mode id <- Id) | Rev])))

(define tree-entries
  Repo Id ->
    (let V (require-type Repo Id "tree")
      (read-tree-items V (repo.width Repo) 0 (buffer.length V) "" [])))

(define first-lines
  _ [] -> []
  _ ["" | _] -> []
  Prefix [S | Rest] ->
    (if (prefix? Prefix S) [(after Prefix S) | (first-lines Prefix Rest)] (first-lines Prefix Rest)))

(define header-values
  V Key ->
    (let S (buffer.string V)
      (first-lines (cn Key " ") (split S 10))))

(define one-header
  V Key -> (one-header-line (split (buffer.string V) 10) Key))

(define one-header-line
  Lines Key ->
    (let H (first-lines (cn Key " ") Lines)
      (do (ensure (= (length H) 1) (cn "expected exactly one " (cn Key " header"))) (hd H))))

(define commit-parents
  Repo Id ->
    (if (element? Id (repo.shallow Repo)) []
        (header-values (require-type Repo Id "commit") "parent")))

(define peel
  Repo Id Depth ->
    (let _ (ensure (< Depth 32) "too many annotated tag levels")
         O (read-object Repo Id)
      (if (= (fst O) "tag") (peel Repo (one-header (snd O) "object") (+ Depth 1)) Id)))

(define as-commit
  Repo Id -> (let Commit (peel Repo Id 0)
               (do (require-type Repo Commit "commit") Commit)))

(define as-tree
  Repo Id ->
    (let Point (peel Repo Id 0)
         O (read-object Repo Point)
      (cases (= (fst O) "tree") Point
             (= (fst O) "commit") (one-header (snd O) "tree")
             true (git-error (cn "expected a commit or tree: " Id)))))

(define short-id?
  S Width ->
    (let V (buffer.from-string S) N (buffer.length V)
      (and (>= N 4) (< N (* Width 2)) (hex-bytes? V 0 N))))

(define short-loose
  [] _ _ Found -> Found
  _ _ _ [A B] -> [A B]
  [Directory | More] S Width Found ->
    (let Fan (nth-byte S 0 2)
         Path (fs.join Directory Fan)
         Next (if (= (node Path) directory) (scan-short-loose (names Path) Fan S Width Found) Found)
      (short-loose More S Width Next)))

(define scan-short-loose
  [] _ _ _ Found -> Found
  _ _ _ _ [A B] -> [A B]
  [S | Rest] Fan Prefix Width Found ->
    (let Id (cn Fan S)
      (scan-short-loose Rest Fan Prefix Width
        (if (and (hex? Id Width) (prefix? Prefix Id) (not (element? Id Found))) [Id | Found] Found))))

(define short-pack-first
  _ _ _ Low High -> Low where (>= Low High)
  I Prefix Width Low High ->
    (let Mid (shen-jit.shift-right (+ Low High) 1)
         Id (hex (pack-id-at I Mid Width))
      (if (bytes< Id Prefix)
          (short-pack-first I Prefix Width (+ Mid 1) High)
          (short-pack-first I Prefix Width Low Mid))))

(define short-pack-rows
  I Prefix Width At Found ->
    (if (or (= At (pack-index.count I)) (= (length Found) 2)) Found
        (let Id (hex (pack-id-at I At Width))
          (if (prefix? Prefix Id)
              (short-pack-rows I Prefix Width (+ At 1) (if (element? Id Found) Found [Id | Found]))
              Found))))

(define short-packs
  [] _ _ Found -> Found
  _ _ _ [A B] -> [A B]
  [I | Rest] Prefix Width Found ->
    (let At (short-pack-first I Prefix Width 0 (pack-index.count I))
      (short-packs Rest Prefix Width (short-pack-rows I Prefix Width At Found))))

(define expand-short
  Repo S ->
    (let Prefix (lowercase S)
         Found (short-packs (pack-indexes Repo) Prefix (repo.width Repo) (short-loose (repo.object-dirs Repo) Prefix (repo.width Repo) []))
      (do (ensure (= (length Found) 1) (make-string "object abbreviation ~A is missing or ambiguous" S))
          (hd Found))))

(define resolve-candidates
  _ [] -> []
  Repo [R | Rest] ->
    (if (or (= R "HEAD") (ref-name? R))
        (let Found (ref-value Repo R) (if (cons? Found) Found (resolve-candidates Repo Rest)))
        (resolve-candidates Repo Rest)))

(define resolve-base
  Repo Text ->
    (let S (if (= Text "@") "HEAD" Text)
         Width (repo.width Repo)
      (if (hex? S Width)
          (do (read-object Repo S) (lowercase S))
          (let Found (resolve-candidates Repo [S (cn "refs/tags/" S) (cn "refs/heads/" S)
                                                  (cn "refs/remotes/" S)])
            (cases (cons? Found) (hd Found)
                   (short-id? S Width) (expand-short Repo S)
                   true (git-error (make-string "unknown revision ~S" Text)))))))

(define revision-end
  V At End ->
    (if (or (= At End) (element? (buffer.u8 V At) [94 126])) At
        (revision-end V (+ At 1) End)))

(define first-parent
  _ Id 0 -> Id
  Repo Id N -> (first-parent Repo (nth-parent Repo Id 1) (- N 1)))

(define nth-parent
  Repo Id 0 -> (as-commit Repo Id)
  Repo Id N ->
    (let Parents (commit-parents Repo (as-commit Repo Id))
      (do (ensure (<= N (length Parents)) (cn "missing parent of " Id))
          (nth N Parents))))

(define revision-suffix
  _ Id _ At At -> Id
  Repo Id V At End ->
    (let Stop (revision-end V (+ At 1) End)
         S (buffer.string (buffer.slice V (+ At 1) (- (- Stop At) 1)))
         Caret (= (buffer.u8 V At) 94)
         Next (cases (and Caret (= S "{}")) (peel Repo Id 0)
                     (and Caret (= S "{commit}")) (as-commit Repo Id)
                     (and Caret (= S "{tree}")) (as-tree Repo Id)
                     true (let N (if (= S "") 1 (decimal S))
                                _ (ensure (<= N 100000) "revision parent count exceeds limit")
                             (if Caret
                                 (nth-parent Repo Id N)
                                 (first-parent Repo (as-commit Repo Id) N))))
      (revision-suffix Repo Next V Stop End)))

(define resolve-object-name
  Repo Spec ->
    (let V (buffer.from-string Spec)
         N (buffer.length V)
         End (revision-end V 0 N)
         Base (resolve-base Repo (buffer.string (buffer.slice V 0 End)))
      (revision-suffix Repo Base V End N)))
(define inspect-tree-path
  _ Id [] -> Id
  Repo Id [Name | Rest] ->
    (inspect-tree-step Repo (tree-entries Repo Id) (checked-name Name) Rest))

(define inspect-tree-step
  _ [] Name _ -> (git-error (cn "no such tree path component: " Name))
  Repo [E | More] Name Rest ->
    (if (= (tree-entry.name E) Name)
        (do (ensure (or (empty? Rest) (= (tree-entry.mode E) 16384)) (cn "not a tree: " Name))
            (inspect-tree-path Repo (tree-entry.id E) Rest))
        (inspect-tree-step Repo More Name Rest)))

(define resolve-revision
  Repo Spec ->
    (let Control (partition-text Spec 58)
         Name (fst Control)
         Path (snd Control)
      (cases (= Name Spec) (resolve-object-name Repo Spec)
             (= Name "")
               (let Item (index-find (index-table (read-index Repo) (dictionary)) (checked-work-path Path))
                 (if (cons? Item) (entry.id (hd Item)) (git-error (cn "path is not staged: " Path))))
             true (let Tree (as-tree Repo (resolve-object-name Repo Name))
                    (if (= Path "") Tree
                        (inspect-tree-path Repo Tree (split (checked-work-path Path) 47)))))))

(declare resolve-revision [repo --> [string --> string]])
(declare read-object [repo --> [string --> [string * buffer.view]]])
(declare object-id [repo --> [string --> [buffer.view --> string]]])
(declare write-object! [repo --> [string --> [buffer.view --> string]]])
(declare hash-file [repo --> [string --> [string --> [boolean --> string]]]])
(declare as-tree [repo --> [string --> string]])
(declare tree-entries [repo --> [string --> [list tree-entry]]])
(declare commit-parents [repo --> [string --> [list string]]])
(declare mode-kind [number --> string])
(declare display-mode [number --> string])
)

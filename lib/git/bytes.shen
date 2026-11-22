(shen.x.namespace git
  (use bytes)
  (use fs)
  (use io)
  (use buffer)
  (use option)
  (use result)
  (use shen-jit)
  (import struct defstruct)
  (externals [define-foreign-procedure posix crt file directory symlink other entry-limit name-byte-limit])
  (export *adapter-files* after decimal ensure git-error prefix? some? switched would-overwrite untracked
    merged fast-forward conflict multiple-bases diverged committed nothing-to-commit updated
    changed-concurrently)

\\ The outcomes the operations give; git-typed.shen makes each family a type.
(defstruct switched (_ : string))
(defstruct would-overwrite (_ : (list string)))
(defstruct untracked (_ : (list string)))
(defstruct merged (_ : string))
(defstruct fast-forward (_ : string))
(defstruct conflict (_ : (list string)))
(defstruct multiple-bases (_ : (list string)))
(defstruct diverged)
(defstruct committed (_ : string))
(defstruct nothing-to-commit)
(defstruct updated (_ : (option.t string)))
(defstruct changed-concurrently (_ : (option.t string)))

(if (bound? *adapter-files*) true
    (set *adapter-files* ["build/shen-git-native.so" "lib/shen-git-native.so" "shen-git-native.so"]))
(shen-jit.library adapter (value *adapter-files*))
(define-foreign-procedure c-digest adapter "shen_git_digest" 4)
(define-foreign-procedure c-crc32 adapter "shen_git_crc32" 3)
(define-foreign-procedure c-deflate adapter "shen_git_deflate" 3)
(define-foreign-procedure c-inflate adapter "shen_git_inflate" 4)
(define-foreign-procedure c-stat adapter "shen_git_stat" 1)

(define object-limit -> 134217728)
(define pack-limit -> 536870912)
(define control-limit -> 16777216)
(define zero -> "c#0;")
(define lf -> "c#10;")

(define git-error
  Text -> (error "git: ~A" Text))

(define ensure
  true _ -> true
  false Message -> (git-error Message))

(define unwrap
  (:result.ok X) -> X
  (:result.err E) -> (git-error (make-string "~A: ~A" (io.error-resource E) (io.error-message E))))

(define absent-error?
  E -> (and (element? (io.error-domain E) [posix crt])
            (element? (io.error-code E) [2 20])))

(define node
  Path -> (node-result (fs.lstat Path)))

(define node-result
  (:result.ok Info) -> (fs.kind Info)
  (:result.err E) -> (if (absent-error? E) absent (unwrap (:result.err E))))

(define read-view
  Path Limit -> (unwrap (io.read-file Path Limit)))

(define read-optional
  Path Limit ->
    (case-node (node Path) Path Limit))

(define case-node
  absent _ _ -> []
  file Path Limit -> [(read-view Path Limit)]
  _ Path _ -> (git-error (make-string "expected a regular file at ~A" Path)))

(define control
  Path -> (map (fn buffer.string) (read-optional Path (control-limit))))

(define folders
  Dir -> (unwrap (fs.mkdirs Dir)))

(define names
  Dir -> (unwrap (fs.list Dir [[entry-limit 1000000] [name-byte-limit 67108864]])))

\\ An environment variable, "" when it is not set.
(define env
  Name -> (env-text (fs.getenv Name)))

(define env-text
  [Value] -> Value
  [] -> "")

(define real-path
  Path -> (unwrap (fs.real-path Path)))

\\ Index stat data for Path, from lstat, or [] if it is missing.
(define stat-block
  Path -> (let B (c-stat Path) (if (empty? B) [] [(buffer.wrap B)])))

\\ Git's mode at Path: -1 when missing, 0 for what Git does not track.
(define mode-at
  Path -> (let B (c-stat Path) (if (empty? B) -1 (index-stat.mode (buffer.wrap B) 0))))

\\ A new file at Path with permissions Mode filtered by umask, true when written and false when
\\ something is already there.
(define write-new
  Path V Mode -> (new-result (fs.write-new Path V Mode)))

(define new-result
  (:result.ok _) -> true
  (:result.err E) -> (if (= (io.error-code E) 17) false (unwrap (:result.err E))))

(define lock-name
  Path -> (cn Path ".lock"))

(define with-lock
  Path F ->
    (let Lock (lock-name Path)
         Owned (vector-> (vector 1) 1 true)
         _ (folders (fs.parent Path))
         _ (ensure (write-new Lock (buffer.new 0) 438)
                   (cn Lock " exists: another Git process may be running"))
      (shen-jit.finally
        (freeze (F (@p Lock Owned)))
        (freeze (if (<-vector Owned 1) (unwrap (fs.remove-file Lock)) true)))))

(define prepare-lock
  Lock V -> (unwrap (io.write-file (fst Lock) V)))

(define publish-lock
  Lock Path -> (do (unwrap (fs.replace (fst Lock) Path))
                   (vector-> (snd Lock) 1 false)
                   true))

(define finish-lock
  Lock Path V -> (do (prepare-lock Lock V) (publish-lock Lock Path)))

(define digest
  Width V -> (buffer.wrap (c-digest (buffer.owner V) (buffer.offset V) (buffer.length V) Width)))

(define deflate
  V -> (buffer.wrap (c-deflate (buffer.owner V) (buffer.offset V) (buffer.length V))))

(define inflate
  V At End Limit ->
    (let Offset (buffer.offset-at V At (- End At))
         Result (c-inflate (buffer.owner V) Offset (- End At) Limit)
      (@p (buffer.wrap (hd Result)) (tl Result))))

(define nibble
  C -> (cases (and (>= C 48) (<= C 57)) (- C 48)
              (and (>= C 97) (<= C 102)) (- C 87)
              (and (>= C 65) (<= C 70)) (- C 55)
              true -1))

(define hex
  V -> (let N (buffer.length V)
            At (buffer.offset-at V 0 N)
         (bytes.hex (buffer.owner V) At (+ At N))))

(define hex-digits -> (bytes.class [[48 57] [97 102] [65 70]]))

(define hex-bytes?
  V At End -> (let Start (buffer.offset-at V At (- End At))
                   Stop (+ Start (- End At))
                (= (bytes.span (buffer.owner V) Start Stop (hex-digits)) Stop)))

(define hex?
  S Width -> (let N (shen-jit.bytes-length S)
               (and (= N (* Width 2)) (= (bytes.span S 0 N (hex-digits)) N))))

(define unhex
  S Width -> (let _ (ensure (hex? S Width) (make-string "invalid object ID ~S" S))
                  To (buffer.new Width)
                  _ (bytes.unhex! (buffer.owner To) (buffer.offset-at To 0 Width) S 0 (* 2 Width))
               To))

(define nth-byte
  S From Count -> (shen-jit.bytes->string S From Count))

(define size
  S -> (shen-jit.bytes-length S))

(define same-bytes-at?
  _ _ _ 0 -> true
  A At B N -> (and (= (shen-jit.u8 A (+ At (- N 1))) (shen-jit.u8 B (- N 1)))
                   (same-bytes-at? A At B (- N 1))))

(define no-bytes?
  V Bad At End ->
    (if (= At End) true
        (and (not (element? (buffer.u8 V At) Bad)) (no-bytes? V Bad (+ At 1) End))))

\\ Where the first B from At is in V, or End.
(define find-byte
  V B At End -> (let Start (buffer.offset-at V At (- End At))
                  (+ At (- (bytes.find (buffer.owner V) Start (+ Start (- End At)) B) Start))))

(define split-at-byte
  V B At End ->
    (let Stop (find-byte V B At End)
      (@p (buffer.string (buffer.slice V At (- Stop At))) Stop)))

(define split-loop
  _ _ End End Rev -> (reverse Rev)
  V B At End Rev ->
    (let Part (split-at-byte V B At End)
      (split-loop V B (if (= End (snd Part)) End (+ (snd Part) 1)) End [(fst Part) | Rev])))

(define split
  S B -> (let V (buffer.from-string S) (split-loop V B 0 (buffer.length V) [])))

(define prefix?
  Prefix Text ->
    (let N (size Prefix)
      (and (<= N (size Text)) (same-bytes-at? Text 0 Prefix N))))

(define suffix?
  Suffix Text ->
    (let N (size Suffix)
         M (size Text)
      (and (<= N M) (same-bytes-at? Text (- M N) Suffix N))))

(define after
  Prefix Text -> (let N (size Prefix) (nth-byte Text N (- (size Text) N))))

(define before
  Text Suffix -> (nth-byte Text 0 (- (size Text) (size Suffix))))

(define partition-text
  S B ->
    (let V (buffer.from-string S)
         N (buffer.length V)
         P (find-byte V B 0 N)
      (@p (nth-byte S 0 P) (if (= P N) "" (nth-byte S (+ P 1) (- (- N P) 1))))))

(define join-text
  _ [] -> ""
  _ [S] -> S
  Separator [S | Rest] ->
    (let B (store-text (buffer.builder (object-limit)) S)
      (do (map (/. X (store-text (store-text B Separator) X)) Rest)
          (buffer.string (buffer.finish B)))))

(define space-byte?
  B -> (element? B [9 10 13 32]))

(define spaces -> (bytes.class [9 10 13 32]))

(define trim
  S -> (let N (shen-jit.bytes-length S)
            Start (bytes.span S 0 N (spaces))
            End (bytes.span-back S Start N (spaces))
         (shen-jit.bytes->string S Start (- End Start))))

(define strip-eol
  S -> (if (suffix? (lf) S) (before S (lf)) S))

(define lowercase
  S -> (bytes.lower S))

(define decimal
  S -> (let N (shen-jit.bytes-length S)
            _ (ensure (> N 0) "empty decimal field")
            Value (bytes.decimal S 0 N 999999999999999999)
         (if (< Value 0) (git-error "invalid decimal field") Value)))

(define bytes<
  A B -> (bytes-before? A B 0 (size A) (size B)))

(define bytes-before?
  _ _ A A B -> (< A B)
  _ _ B _ B -> false
  A B At X Y -> (let L (shen-jit.u8 A At) R (shen-jit.u8 B At)
                  (if (= L R) (bytes-before? A B (+ At 1) X Y) (< L R))))

(define store-u32
  Builder N -> (do (buffer.append-byte! Builder (shen-jit.shift-right N 24))
                   (buffer.append-byte! Builder (shen-jit.bit-and (shen-jit.shift-right N 16) 255))
                   (store-u16 Builder (shen-jit.bit-and N 65535))))

(define store-u16
  Builder N -> (do (buffer.append-byte! Builder (shen-jit.shift-right N 8))
                   (buffer.append-byte! Builder (shen-jit.bit-and N 255))))

(define store-text
  Builder S -> (buffer.append! Builder (buffer.from-string S)))

(define with-digest
  Width V -> (let B (buffer.new (+ (buffer.length V) Width))
              (do (buffer.copy-into! B 0 V 0 (buffer.length V))
                  (buffer.copy-into! B (buffer.length V) (digest Width V) 0 Width)
                  B)))

(define verify-digest
  Width V Kind ->
    (let End (- (buffer.length V) Width)
         _ (ensure (>= End 0) (cn "truncated " Kind))
         Payload (buffer.slice V 0 End)
         _ (ensure (buffer.equal? (digest Width Payload) (buffer.slice V End Width))
                   (cn Kind " checksum does not match"))
      Payload))
(define newline
  Text -> (cn Text (lf)))

(define some?
  _ [] -> false
  F [X | Xs] -> (or (F X) (some? F Xs)))

(define parent-prefix
  Path -> (let Parent (fs.parent Path) (if (= Parent ".") "" Parent)))

\\ Remove Root/Relative and its parents below Root while they are empty directories.
(define prune-empty!
  _ "" -> true
  Root Relative ->
    (let Path (fs.join Root Relative)
      (if (and (= (node Path) directory) (empty? (names Path)))
          (do (unwrap (fs.remove-directory Path)) (prune-empty! Root (parent-prefix Relative)))
          true)))

(define require-file
  Path -> (required (control Path) Path))

(define required
  [Text] _ -> Text
  [] Path -> (git-error (make-string "missing ~A" Path)))

\\ The text of a control file, or Default when it is missing.
(define control-or
  Path Default -> (let Text (control Path) (if (empty? Text) Default (hd Text))))

(define dictionary -> (shen.dict 8))

(eval-kl [defun dict-entry [d key] [shen-jit.dict-find d key]])
(shen.store-arity dict-entry 2)

(define entries
  D -> (shen.dict-fold (/. Key Value Acc [[Key | Value] | Acc]) D []))

(define lookup
  D Key -> (let Item (dict-entry D Key) (if (cons? Item) [(tl Item)] [])))

(define remember
  D Key Value -> (do (shen.dict-> D Key Value) D))

(define merge-by
  _ [] Ys -> Ys
  _ Xs [] -> Xs
  Less [X | Xs] [Y | Ys] ->
    (if (Less Y X)
        [Y | (merge-by Less [X | Xs] Ys)]
        [X | (merge-by Less Xs [Y | Ys])]))

(define halves
  [] Left Right -> (@p Left Right)
  [X] Left Right -> (@p [X | Left] Right)
  [X Y | Rest] Left Right -> (halves Rest [X | Left] [Y | Right]))

(define order-by
  _ [] -> []
  _ [X] -> [X]
  Less Xs -> (let Parts (halves Xs [] [])
               (merge-by Less (order-by Less (fst Parts)) (order-by Less (snd Parts)))))

(declare prefix? [string --> [string --> boolean]])
(declare after [string --> [string --> string]])
(declare decimal [string --> number])
(declare some? [[A --> boolean] --> [[list A] --> boolean]])
(declare ensure [boolean --> [string --> boolean]])
(declare git-error [string --> A])
(declare join-text [string --> [[list string] --> string]])
)

(shen.x.namespace git
  (use fs)
  (use buffer)
  (use option)
  (use shen-jit)
  (import struct defstruct)
  (externals [file directory symlink])
  (export open-repo init repo repo? repo.root repo.dir repo.common repo.width resolve-from
    ref-value refs set-ref! delete-ref! head-ref any null-id config-value set-config!)

(defstruct repo
  root dir common width (mutable config) object-dirs shallow
  (mutable pack-indexes) (mutable base-size) object-cache
  (mutable cache-size) (mutable index-stamp))

\\ Git's config syntax: comments, sections, subsections kept as written, and values with quotes,
\\ escapes and comments. A key without = has the value true, which reads as "".
(define parse-config
  Text D -> (let V (buffer.from-string Text) (config-items V 0 (buffer.length V) "" D)))

(define config-items
  _ End End _ D -> D
  V At End Section D ->
    (let B (buffer.u8 V At)
      (cases (space-byte? B) (config-items V (+ At 1) End Section D)
             (element? B [35 59]) (config-items V (line-end V At End) End Section D)
             (= B 91) (let Header (config-section V (+ At 1) End)
                        (config-items V (snd Header) End (fst Header) D))
             true (config-entry V At End Section D))))

(define line-end
  V At End -> (find-byte V 10 At End))

(define name-byte?
  B -> (or (and (>= B 97) (<= B 122)) (and (>= B 65) (<= B 90)) (and (>= B 48) (<= B 57)) (= B 45)))

(define name-end
  V At End -> (if (and (< At End) (name-byte? (buffer.u8 V At))) (name-end V (+ At 1) End) At))

(define blank-end
  V At End -> (if (and (< At End) (element? (buffer.u8 V At) [9 32])) (blank-end V (+ At 1) End) At))

(define section-end
  V At End -> (if (and (< At End) (or (name-byte? (buffer.u8 V At)) (= (buffer.u8 V At) 46)))
                  (section-end V (+ At 1) End) At))

(define config-section
  V At End ->
    (let Stop (section-end V At End)
         Name (lowercase (buffer.string (buffer.slice V At (- Stop At))))
         Next (blank-end V Stop End)
         _ (ensure (and (> Stop At) (< Next End)) "invalid config section")
         C (buffer.u8 V Next)
      (cases (= C 93) (@p Name (+ Next 1))
             (and (= C 34) (> Next Stop))
               (let Sub (config-subsection V (+ Next 1) End (buffer.builder (control-limit)))
                    _ (ensure (and (< (snd Sub) End) (= (buffer.u8 V (snd Sub)) 93)) "invalid config section")
                 (@p (cn Name (cn "." (fst Sub))) (+ (snd Sub) 1)))
             true (git-error "invalid config section"))))

(define config-subsection
  V At End B ->
    (let _ (ensure (and (< At End) (not (= (buffer.u8 V At) 10))) "invalid config subsection")
         C (buffer.u8 V At)
      (cases (= C 34) (@p (buffer.string (buffer.finish B)) (+ At 1))
             (and (= C 92) (< (+ At 1) End))
               (config-subsection V (+ At 2) End (buffer.append-byte! B (buffer.u8 V (+ At 1))))
             true (config-subsection V (+ At 1) End (buffer.append-byte! B C)))))

(define config-entry
  V At End Section D ->
    (let Stop (name-end V At End)
         _ (ensure (and (> Stop At) (not (= Section ""))) "invalid config line")
         Key (cn Section (cn "." (lowercase (buffer.string (buffer.slice V At (- Stop At))))))
         Next (blank-end V Stop End)
         B (if (< Next End) (buffer.u8 V Next) 10)
      (cases (= B 61) (let Value (config-value-text V (+ Next 1) End (buffer.builder (control-limit)) [] false)
                        (config-items V (snd Value) End Section (remember D Key (fst Value))))
             (element? B [10 13 35 59]) (config-items V Next End Section (remember D Key true))
             true (git-error "invalid config line"))))

\\ Whitespace outside quotes is kept only between other bytes; Pending holds it in reverse.
(define config-value-text
  V At End B _ Quoted -> (do (ensure (not Quoted) "unterminated config quote") (@p (buffer.string (buffer.finish B)) At))
    where (or (= At End) (= (buffer.u8 V At) 10))
  V At End B Pending Quoted ->
    (let C (buffer.u8 V At)
      (cases (and (not Quoted) (space-byte? C))
               (config-value-text V (+ At 1) End B (if (> (buffer.builder-length B) 0) [C | Pending] []) false)
             (and (not Quoted) (element? C [35 59]))
               (config-value-text V (line-end V At End) End B [] false)
             (= C 34) (config-value-text V (+ At 1) End (flush-pending B Pending) [] (not Quoted))
             (= C 92) (let Next (if (< (+ At 1) End) (buffer.u8 V (+ At 1)) 0)
                        (if (= Next 10)
                            (config-value-text V (+ At 2) End B Pending Quoted)
                            (config-value-text V (+ At 2) End
                              (buffer.append-byte! (flush-pending B Pending) (config-escape Next)) [] Quoted)))
             true (config-value-text V (+ At 1) End (buffer.append-byte! (flush-pending B Pending) C) [] Quoted))))

(define flush-pending
  B Pending -> (do (map (buffer.append-byte! B) (reverse Pending)) B))

(define config-escape
  116 -> 9
  98 -> 8
  110 -> 10
  92 -> 92
  34 -> 34
  _ -> (git-error "invalid escape in config value"))

(define config-into
  Path D -> (parse-config (control-or Path "") D))

(define text-setting
  true -> ""
  S -> S)

(define setting
  D Key Default -> (let Found (lookup D Key) (if (empty? Found) Default (text-setting (hd Found)))))

\\ Git's booleans, where a key without a value is true and an integer is true unless 0.
(define config-flag
  D Key Default -> (let Found (lookup D Key) (if (empty? Found) Default (boolean-value (hd Found)))))

(define boolean-value
  true -> true
  S -> (let L (lowercase S)
         (cases (element? L ["true" "yes" "on"]) true
                (element? L ["false" "no" "off" ""]) false
                true (not (= (trap-error (decimal L) (/. E (git-error (cn "invalid boolean " S)))) 0)))))

(define config-bool
  Repo Key Default -> (config-flag (repo.config Repo) Key Default))

(define worktree-config
  Dir D -> (if (config-flag D "extensions.worktreeconfig" false)
              (config-into (fs.join Dir "config.worktree") D) D))

\\ Section and key names ignore case; a subsection between them does not.
(define config-key
  Key -> (let V (buffer.from-string Key)
              N (buffer.length V)
              First (find-byte V 46 0 N)
              Last (last-byte V 46 N)
           (if (>= First Last) (lowercase Key)
               (cn (lowercase (nth-byte Key 0 First))
                   (cn (nth-byte Key First (- Last First)) (lowercase (nth-byte Key Last (- N Last))))))))

(define last-byte
  _ _ 0 -> -1
  V B At -> (if (= (buffer.u8 V (- At 1)) B) (- At 1) (last-byte V B (- At 1))))

(define config-value
  Repo Key -> (map (fn text-setting) (lookup (repo.config Repo) (config-key Key))))

(define null-id
  Repo -> (hex (buffer.new (repo.width Repo))))

(define config-token?
  Text ->
    (let V (buffer.from-string (lowercase Text))
         N (buffer.length V)
      (and (> N 0) (config-token-loop V 0 N))))

(define config-token-loop
  _ At At -> true
  V At End ->
    (let B (buffer.u8 V At)
      (and (or (and (>= B 97) (<= B 122)) (and (>= B 48) (<= B 57)) (= B 45))
           (config-token-loop V (+ At 1) End))))

(define set-config!
  Repo Key Value ->
    (let Pair (partition-text Key 46)
         _ (ensure (and (config-token? (fst Pair)) (config-token? (snd Pair))) "expected SECTION.NAME")
         _ (ensure (and (not (= (lowercase (fst Pair)) "extensions"))
                        (not (element? (lowercase Key) ["core.repositoryformatversion" "core.bare" "core.worktree"])))
                   "refusing to change repository format settings")
         _ (ensure (no-bytes? (buffer.from-string Value) [0 10 13 34 92] 0 (size Value)) "unsupported config value")
         Path (fs.join (repo.common Repo) "config")
      (with-lock Path (/. Lock
        (let Text (control-or Path "")
             Added (make-string "~%[~A]~%	~A = c#34;~Ac#34;~%" (fst Pair) (snd Pair) Value)
             Contents (cn Text Added)
             D (worktree-config (repo.dir Repo) (parse-config Contents (dictionary)))
          (do (finish-lock Lock Path (buffer.from-string Contents))
              (repo.config-> Repo D)
              true))))))

(define resolve-from
  Dir Path -> (real-path (fs.join Dir Path)))

(define read-gitdir
  Root Entry ->
    (let S (strip-eol (require-file Entry))
         Prefix "gitdir: "
         _ (ensure (prefix? Prefix S) (make-string "invalid gitdir file ~A" Entry))
      (resolve-from Root (after Prefix S))))

(define setup-repo
  Root Dir ->
    (let Linked (control (fs.join Dir "commondir"))
         Common (if (empty? Linked) Dir (resolve-from Dir (strip-eol (hd Linked))))
         D (config-into (fs.join Common "config") (dictionary))
         V (setting D "core.repositoryformatversion" "0")
         _ (ensure (element? V ["0" "1"]) (cn "unsupported repository format " V))
         _ (check-extensions (entries D))
         Format (setting D "extensions.objectformat" "sha1")
         Width (cases (= Format "sha1") 20
                      (= Format "sha256") 32
                      true (git-error (cn "unsupported object format " Format)))
         _ (worktree-config Dir D)
         WorkTree (setting D "core.worktree" "")
         Work (if (= WorkTree "") Root (resolve-from Dir WorkTree))
         Shallow (mapcan (/. Id (if (= Id "") [] [Id])) (split (control-or (fs.join Common "shallow") "") 10))
         _ (map (/. Id (ensure (hex? Id Width) "invalid shallow object ID")) Shallow)
         Objects (object-paths [(fs.join Common "objects")] [] 0)
      (:repo root <- (if (= Work []) [] [Work]) dir <- Dir common <- Common width <- Width config <- D
             object-dirs <- Objects shallow <- Shallow pack-indexes <- [] base-size <- 0
             object-cache <- (dictionary) cache-size <- 0 index-stamp <- [])))

(define object-paths
  [] Found _ -> (reverse Found)
  [Path | More] Found Count ->
    (let Dir (real-path Path)
      (if (element? Dir Found) (object-paths More Found Count)
          (let _ (ensure (< Count 64) "too many Git object directories")
               Alternate (mapcan (/. P (if (or (= P "") (prefix? "#" P)) [] [(fs.join Dir P)]))
                                 (split (control-or (fs.join Dir "info/alternates") "") 10))
            (object-paths (append Alternate More) [Dir | Found] (+ Count 1))))))

(define check-extensions
  [] -> true
  [[Key | _] | Entries] ->
    (do (ensure (or (not (prefix? "extensions." Key))
                    (element? Key ["extensions.objectformat" "extensions.worktreeconfig" "extensions.noop"]))
                (cn "unsupported repository extension " Key))
        (check-extensions Entries)))

(define bare-dir?
  Dir -> (and (= (node (fs.join Dir "HEAD")) file)
              (= (node (fs.join Dir "objects")) directory)
              (= (node (fs.join Dir "refs")) directory)))

(define discover
  Path ->
    (let Entry (fs.join Path ".git")
         Kind (node Entry)
      (cases (= Kind directory) (setup-repo Path Entry)
             (= Kind file) (setup-repo Path (read-gitdir Path Entry))
             (bare-dir? Path) (setup-repo [] Path)
             (= Path (fs.parent Path)) (git-error "outside a Git repository")
             true (discover (fs.parent Path)))))

(define open-repo
  Path -> (discover (real-path Path)))

(define ref-char?
  B -> (and (> B 32) (not (element? B [42 58 63 91 92 94 126 127]))))

(define ref-chars?
  _ At At -> true
  V At End -> (and (ref-char? (buffer.u8 V At)) (ref-chars? V (+ At 1) End)))

(define contains-pair?
  _ _ _ At End -> false where (>= (+ At 1) End)
  V A B At End ->
    (or (and (= (buffer.u8 V At) A) (= (buffer.u8 V (+ At 1)) B))
        (contains-pair? V A B (+ At 1) End)))

(define ref-parts?
  [] -> true
  [S | Rest] -> (and (> (size S) 0) (not (prefix? "." S)) (not (suffix? ".lock" S))
                      (ref-parts? Rest)))

(define ref-name?
  Name -> (let V (buffer.from-string Name)
               End (buffer.length V)
            (and (prefix? "refs/" Name)
                 (not (suffix? "/" Name))
                 (not (suffix? "." Name))
                 (not (contains-pair? V 46 46 0 End))
                 (not (contains-pair? V 64 123 0 End))
                 (ref-chars? V 0 End)
                 (ref-parts? (split Name 47)))))

(define checked-ref
  Name -> (do (ensure (or (= Name "HEAD") (ref-name? Name))
                       (make-string "invalid ref name ~S" Name))
              Name))

(define branch-ref
  Name -> (do (ensure (and (> (size Name) 0) (not (prefix? "-" Name)) (not (= Name "HEAD")))
                      (make-string "invalid branch name ~S" Name))
              (checked-ref (cn "refs/heads/" Name))))

(define private-ref?
  Name -> (or (= Name "HEAD")
              (prefix? "refs/bisect/" Name)
              (prefix? "refs/worktree/" Name)
              (prefix? "refs/rewritten/" Name)))

(define ref-base
  Repo Name -> (if (private-ref? Name) (repo.dir Repo) (repo.common Repo)))

(define ref-path
  Repo Name -> (fs.join (ref-base Repo Name) (checked-ref Name)))

(define loose-ref
  Repo Name -> (let Path (ref-path Repo Name)
                (if (= (node Path) directory) [] (map (fn strip-eol) (control Path)))))

(define parse-packed-refs
  _ [] D -> D
  Repo [S | Lines] D ->
    (if (or (= S "") (prefix? "#" S) (prefix? "^" S))
        (parse-packed-refs Repo Lines D)
        (let Pair (partition-text S 32)
             Name (snd Pair)
             Id (fst Pair)
             _ (ensure (and (ref-name? Name) (hex? Id (repo.width Repo)))
                       "invalid packed ref")
          (do (remember D Name Id) (parse-packed-refs Repo Lines D)))))

(define packed-refs
  Repo ->
    (parse-packed-refs Repo (split (control-or (fs.join (repo.common Repo) "packed-refs") "") 10)
                       (dictionary)))

(define ref-follow
  Repo Name Trace ->
    (let _ (ensure (and (< (length Trace) 16) (not (element? Name Trace))) "symbolic ref loop")
      (ref-contents Repo Name Trace (loose-ref Repo Name))))

(define ref-contents
  Repo Name _ [] -> (if (private-ref? Name) [] (lookup (packed-refs Repo) Name))
  Repo Name Trace [S] ->
    (if (prefix? "ref: " S)
        (ref-follow Repo (after "ref: " S) [Name | Trace])
        (do (ensure (hex? S (repo.width Repo)) (cn "invalid ref contents: " Name)) [S])))

(define ref-value
  Repo Name -> (ref-follow Repo Name []))

(define ref-target
  Repo Name Trace ->
    (let _ (ensure (and (< (length Trace) 16) (not (element? Name Trace))) "symbolic ref loop")
         Loose (loose-ref Repo Name)
      (if (and (cons? Loose) (prefix? "ref: " (hd Loose)))
          (ref-target Repo (after "ref: " (hd Loose)) [Name | Trace])
          Name)))

(define head-ref
  Repo -> (ref-target Repo "HEAD" []))

\\ Name moves to New if it still has the value Old expects: git.any, [] for none or [Id]. The
\\ outcome is (updated [New]), or (changed-concurrently Found) with the value found instead.
(define set-ref!
  Repo Name New Old ->
    (let Target (ref-target Repo Name [])
         Path (ref-path Repo Target)
         Object (read-object Repo New)
         Id (lowercase New)
         _ (ensure (or (not (prefix? "refs/heads/" Target)) (= (fst Object) "commit"))
                   "branch must point to a commit")
      (with-lock Path
        (/. Lock
          (let Found (ref-value Repo Name)
            (if (and (= Target (ref-target Repo Name [])) (or (= Old any) (= Old Found)))
                (do (validate-ref-hierarchy Repo Target)
                    (finish-lock Lock Path (buffer.from-string (newline Id)))
                    (updated.make [Id]))
                (changed-concurrently.make Found)))))))

(define ref-conflicts?
  Target Other ->
    (or (prefix? (cn Target "/") Other) (prefix? (cn Other "/") Target)))

(define validate-ref-hierarchy
  Repo Target ->
    (ensure (or (= Target "HEAD")
                (not (some? (/. Pair (ref-conflicts? Target (fst Pair))) (refs Repo))))
            (cn "ref conflicts with an existing ref: " Target)))

(define keep-packed-lines
  [] _ _ Acc -> (reverse Acc)
  [Line | Lines] Name Drop Acc ->
    (cases (prefix? "^" Line)
             (keep-packed-lines Lines Name Drop (if Drop Acc [Line | Acc]))
           (and (not (= Line "")) (not (prefix? "#" Line))
                (= (snd (partition-text Line 32)) Name))
             (keep-packed-lines Lines Name true Acc)
           true (keep-packed-lines Lines Name false [Line | Acc])))

(define delete-packed-ref!
  Repo Name ->
    (let Path (fs.join (repo.common Repo) "packed-refs")
      (if (= (node Path) absent) true
          (with-lock Path
            (/. Lock
              (let Old (require-file Path)
                   New (keep-packed-lines (split Old 10) Name false [])
                (finish-lock Lock Path
                             (buffer.from-string
                               (if (empty? New) "" (newline (join-text (lf) New)))))))))))

(define delete-ref!
  Repo Name Old ->
    (let Target (ref-target Repo Name [])
         _ (ensure (not (= Target "HEAD")) "cannot delete HEAD")
         Path (ref-path Repo Target)
         Outcome (with-lock Path (/. Lock
                   (let Found (ref-value Repo Name)
                     (if (and (= Target (ref-target Repo Name [])) (or (= Old any) (= Old Found)))
                         (do (if (private-ref? Target) true (delete-packed-ref! Repo Target))
                             (if (= (node Path) file) (unwrap (fs.remove-file Path)) true)
                             (updated.make []))
                         (changed-concurrently.make Found)))))
      (do (prune-ref-parents! Repo Target) Outcome)))

\\ Empty directories a deleted ref leaves, up to its category, such as refs/heads, as Git does.
(define prune-ref-parents!
  Repo Target -> (prune-ref-dirs (ref-base Repo Target) (split Target 47)))

(define prune-ref-dirs
  Base [Refs Category Name | Rest] ->
    (prune-empty! (fs.join Base (cn Refs (cn "/" Category)))
                  (join-text "/" (reverse (tl (reverse [Name | Rest])))))
  _ _ -> true)

(define loose-names
  Repo D Dir Prefix ->
    (if (= (node Dir) directory)
        (walk-ref-names Repo D Dir Prefix (names Dir)) D))

(define walk-ref-names
  _ D _ _ [] -> D
  Repo D Dir Prefix [Name | Names] ->
    (let Path (fs.join Dir Name)
         Relative (cn Prefix Name)
         Kind (node Path)
      (do (cases (= Kind directory) (loose-names Repo D Path (cn Relative "/"))
                 (and (= Kind file) (ref-name? Relative))
                   (let Found (ref-value Repo Relative) (if (empty? Found) D (remember D Relative (hd Found))))
                 true D)
          (walk-ref-names Repo D Dir Prefix Names))))

(define ref-before?
  [A | _] [B | _] -> (bytes< A B))

(define refs
  Repo ->
    (let Table (packed-refs Repo)
         _ (loose-names Repo Table (fs.join (repo.common Repo) "refs") "refs/")
         _ (if (= (repo.common Repo) (repo.dir Repo)) Table
               (loose-names Repo Table (fs.join (repo.dir Repo) "refs") "refs/"))
      (map (/. Pair (@p (hd Pair) (tl Pair))) (order-by (fn ref-before?) (entries Table)))))

(define empty-directory?
  Dir -> (or (= (node Dir) absent)
             (and (= (node Dir) directory) (= (names Dir) []))))

(define init
  Directory Bare Branch Format ->
    (let Head (branch-ref Branch)
         _ (ensure (element? Format ["sha1" "sha256"]) "expected sha1 or sha256")
         _ (folders Directory)
         Root (real-path Directory)
         Dir (if Bare Root (fs.join Root ".git"))
         _ (ensure (empty-directory? Dir) (cn "repository already exists or is not empty: " Dir))
         _ (folders (fs.join Dir "objects/info"))
         _ (folders (fs.join Dir "objects/pack"))
         _ (folders (fs.join Dir "refs/heads"))
         _ (folders (fs.join Dir "refs/tags"))
         BareText (if Bare "true" "false")
         Version (if (= Format "sha1") "0" "1")
         Extension (if (= Format "sha1") "" "[extensions]c#10;	objectFormat = sha256c#10;")
         _ (write-new (fs.join Dir "config")
                      (buffer.from-string
                        (make-string "[core]~%	repositoryformatversion = ~A~%	filemode = true~%	bare = ~A~%~A"
                                     Version BareText Extension)) 438)
         _ (write-new (fs.join Dir "HEAD") (buffer.from-string (newline (cn "ref: " Head))) 438)
      (setup-repo (if Bare [] Root) Dir)))

(declare open-repo [string --> repo])
(declare init [string --> [boolean --> [string --> [string --> repo]]]])
(declare repo? [A --> boolean])
(declare repo.root [repo --> [option.t string]])
(declare repo.dir [repo --> string])
(declare repo.common [repo --> string])
(declare repo.width [repo --> number])
(declare resolve-from [string --> [string --> string]])
(declare refs [repo --> [list [string * string]]])
(declare ref-value [repo --> [string --> [option.t string]]])
(declare head-ref [repo --> string])
(declare null-id [repo --> string])
(declare set-ref! [repo --> [string --> [string --> [expectation --> ref-update]]]])
(declare delete-ref! [repo --> [string --> [expectation --> ref-update]]])
(declare config-value [repo --> [string --> [option.t string]]])
(declare set-config! [repo --> [string --> [string --> boolean]]])
)

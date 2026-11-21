(shen.x.namespace git
  (use fs)
  (use buffer)
  (use option)
  (use shen-jit)
  (externals [file directory symlink])
  (export stage! unstage! restore-staged! status-records commit! work-root relative-path)

(define work-root
  Repo -> (let Root (repo.root Repo)
            (do (ensure (cons? Root) "operation requires a worktree") (hd Root))))

(define work-path
  Repo "" -> (work-root Repo)
  Repo Path -> (fs.join (work-root Repo) Path))

(define below?
  Path "" -> (not (= Path ""))
  Path "/" -> (and (not (= Path "/")) (prefix? "/" Path))
  Path Prefix -> (prefix? (cn Prefix "/") Path))

(define covers?
  Path Root -> (or (= Root "") (= Root Path) (below? Path Root)))

(define relative-to
  Root Path ->
    (do (ensure (covers? Path Root) (cn "path outside worktree: " Path))
        (if (= Path Root) "" (after (if (= Root "/") Root (cn Root "/")) Path))))

(define normalize-path
  [] Seen -> (join-text "/" (reverse Seen))
  ["" | Parts] Seen -> (normalize-path Parts Seen)
  ["." | Parts] Seen -> (normalize-path Parts Seen)
  [".." | Parts] [P | Seen] -> (normalize-path Parts Seen)
  [".." | _] [] -> (git-error "path escapes worktree")
  [P | Parts] Seen -> (normalize-path Parts [(checked-name P) | Seen]))

(define relative-path
  Repo Cwd Text ->
    (let Root (work-root Repo)
         _ (ensure (> (size Text) 0) "empty path argument")
         Rel (if (prefix? "/" Text) (relative-to Root Text)
                 (let Prefix (relative-to Root Cwd)
                   (if (= Prefix "") Text (cn Prefix (cn "/" Text)))))
      (normalize-path (split Rel 47) [])))

(define parents-clear?
  _ "" -> true
  Repo Path ->
    (and (parents-clear? Repo (parent-prefix Path))
         (element? (node (work-path Repo Path)) [directory absent])))

(define gitlink?
  Repo Path ->
    (let Marker (node (fs.join (work-path Repo Path) ".git"))
      (element? Marker [file directory])))

(define path-mode
  Repo Path ->
    (if (parents-clear? Repo (parent-prefix Path))
        (mode-at (work-path Repo Path))
        -1))

(define work-stat
  Repo Path ->
    (if (parents-clear? Repo (parent-prefix Path)) (stat-block (work-path Repo Path)) []))

(define local-file-mode
  Repo Mode Old ->
    (if (element? Mode [33188 33261])
        (let Prior (if (cons? Old) (entry.mode (hd Old)) 33188)
          (cases (and (not (config-bool Repo "core.filemode" true))
                      (element? Prior [33188 33261])) Prior
                 (and (not (config-bool Repo "core.symlinks" true))
                      (= Prior 40960)) 40960
                 true Mode))
        Mode))

(define file-data
  Path 40960 -> (buffer.from-string (unwrap (fs.read-link Path)))
  Path _ -> (read-view Path (object-limit)))

\\ The entry for Path in the worktree. Its stat data comes before its contents, so a later change
\\ shows in the stat data, and contents whose stat data has not changed are not read again.
(define work-entry
  Repo Path Previous Persist ->
    (let Stat (work-stat Repo Path)
      (if (empty? Stat) []
          (work-entry-stat Repo Path Previous Persist (hd Stat) (index-stat.mode (hd Stat) 0)))))

(define work-entry-stat
  _ _ _ _ _ 0 -> []
  Repo Path _ _ _ 16384 ->
    (if (gitlink? Repo Path)
        (let Sub (open-repo (work-path Repo Path))
             _ (ensure (= (repo.width Repo) (repo.width Sub)) "incompatible submodule object format")
             Ref (ref-value Sub "HEAD")
          (if (empty? Ref) [] [(make-entry Path 57344 (hd Ref))]))
        [])
  Repo Path Previous Persist Stat Mode ->
    (let Corrected (local-file-mode Repo Mode Previous)
         Id (if (unchanged? Repo Previous Stat)
                (entry.id (hd Previous))
                (let Data (file-data (work-path Repo Path) Mode)
                  (if Persist (write-object! Repo "blob" Data) (object-id Repo "blob" Data))))
      [(stat-entry Path Corrected Id Stat)]))

\\ Before a new index replaces one, a carried entry as recent as the old index is checked
\\ against its file, and smudged if that changed, as Git does.
(define settle
  Repo E -> (if (and (racy? Repo (entry.stat E)) (changed-in-tick? Repo E (work-stat Repo (entry.path E))))
                (smudge E)
                E))

(define changed-in-tick?
  _ _ [] -> false
  Repo E [Stat] -> (and (unchanged-stat? (entry.stat E) Stat)
                        (not (= (entry.id E) (object-id Repo "blob"
                                               (file-data (work-path Repo (entry.path E))
                                                          (index-stat.mode Stat 0)))))))

(define append-path
  "" Name -> Name
  Path Name -> (cn Path (cn "/" Name)))

\\ The paths under Path that ignore rules leave visible. With Tracked as [D], where D holds the
\\ directories with index entries, a directory with none stands for its files as "dir/", as in
\\ Git's status, if it has any.
(define visible-files
  Repo Path Rules Acc Tracked ->
    (let Local (append Rules (local-ignore Repo Path))
      (visible-children Repo (names (work-path Repo Path)) Path Local Acc Tracked)))

(define visible-children
  _ [] _ _ Acc _ -> Acc
  Repo [Name | Rest] Path Rules Acc Tracked ->
    (let Child (append-path Path Name)
         Next (if (file-part? Name)
                  (let Mode (mode-at (work-path Repo Child))
                       Dir (= Mode 16384)
                    (cases (ignored-here? Rules Child Dir) Acc
                           (and Dir (not (gitlink? Repo Child)))
                             (if (and (cons? Tracked) (empty? (lookup (hd Tracked) Child)))
                                 (if (empty? (visible-files Repo Child Rules [] [])) Acc [(cn Child "/") | Acc])
                                 (visible-files Repo Child Rules Acc Tracked))
                           (element? Mode [16384 33188 33261 40960]) [Child | Acc]
                           true Acc))
                  Acc)
      (visible-children Repo Rest Path Rules Next Tracked)))

(define path-ignore-check
  _ [] _ _ _ -> false
  Repo [Name | Rest] Parent Rules IsDir ->
    (let Path (append-path Parent Name)
         Local (append Rules (local-ignore Repo Parent))
         Directory (or (cons? Rest) IsDir)
      (or (ignored-here? Local Path Directory)
          (path-ignore-check Repo Rest Path Local IsDir))))

(define ignore-before
  _ [] _ Rules -> Rules
  Repo [Name | Rest] Parent Rules ->
    (ignore-before Repo Rest (append-path Parent Name) (append Rules (local-ignore Repo Parent))))

(define tracked-subset
  [] _ Acc -> Acc
  [E | More] Root Acc ->
    (let Path (entry.path E)
      (tracked-subset More Root (if (covers? Path Root) [Path | Acc] Acc))))

(define directory-candidates
  Repo Path Existing Global Forced ->
    (if (and (not Forced) (path-ignore-check Repo (split Path 47) "" Global true))
        Existing
        (let Rules (if Forced [] (ignore-before Repo (split Path 47) "" Global))
          (if Forced (all-files Repo Path Existing) (visible-files Repo Path Rules Existing [])))))

(define all-files
  Repo Path Acc -> (all-children Repo (names (work-path Repo Path)) Path Acc))

(define all-children
  _ [] _ Acc -> Acc
  Repo [Name | Rest] Path Acc ->
    (let Child (append-path Path Name)
         Next (if (file-part? Name)
                  (let Mode (mode-at (work-path Repo Child))
                    (cases (and (= Mode 16384) (not (gitlink? Repo Child))) (all-files Repo Child Acc)
                           (element? Mode [16384 33188 33261 40960]) [Child | Acc]
                           true Acc))
                  Acc)
      (all-children Repo Rest Path Next)))

(define index-table
  [] D -> D
  [E | More] D ->
    (let Path (entry.path E)
         Old (entries-at D Path)
      (do (remember D Path [E | Old]) (index-table More D))))

(define stage-zero
  [] -> []
  [E | More] -> (if (= (entry.stage E) 0) [E] (stage-zero More)))

(define index-find
  D Path -> (stage-zero (entries-at D Path)))

(define entries-at
  D Path -> (let Found (lookup D Path) (if (empty? Found) [] (hd Found))))

(define collect-to-stage
  Repo Path Index Table Global TrackedOnly Forced ->
    (let Existing (tracked-subset Index Path [])
         Kind (if (= Path "") 16384 (path-mode Repo Path))
      (cases TrackedOnly
               (do (ensure (or (= Path "") (cons? Existing))
                           (cn "path matches no tracked files: " Path)) Existing)
             (and (= Kind 16384) (not (and (> (size Path) 0) (gitlink? Repo Path))))
               (directory-candidates Repo Path Existing Global Forced)
             (= Kind -1)
               (do (ensure (cons? Existing) (cn "path does not exist: " Path)) Existing)
             true
               (do (ensure (or Forced (cons? (lookup Table Path))
                               (not (path-ignore-check Repo (split Path 47) "" Global (= Kind 16384))))
                           (cn "ignored path: " Path))
                   (ensure (element? Kind [16384 33188 33261 40960]) (cn "unsupported file type: " Path))
                   [Path | Existing]))))

(define mark-unique
  [] _ -> true
  [Path | Paths] Set -> (do (remember Set Path true) (mark-unique Paths Set)))

(define collect-paths
  _ [] _ _ _ _ _ Set -> Set
  Repo [Path | Paths] Index Table Global TrackedOnly Forced Set ->
    (do (mark-unique (collect-to-stage Repo Path Index Table Global TrackedOnly Forced) Set)
        (collect-paths Repo Paths Index Table Global TrackedOnly Forced Set)))

(define remove-conflicting-entries
  [] _ _ Acc -> Acc
  [E | Index] Staged Parents Acc ->
    (let Path (entry.path E)
      (remove-conflicting-entries Index Staged Parents
        (if (or (cons? (lookup Staged Path)) (selected-ancestor? Staged Path)
                (cons? (lookup Parents Path)))
            Acc [E | Acc]))))

(define selected-ancestor?
  Table Path ->
    (let Parent (parent-prefix Path)
      (and (not (= Parent ""))
           (or (and (cons? (lookup Table Parent)) (cons? (hd (lookup Table Parent))))
               (selected-ancestor? Table Parent)))))

(define note-parents
  D "" -> D
  D Path -> (do (remember D Path true) (note-parents D (parent-prefix Path))))

(define stage-parents
  Staged -> (shen.dict-fold (/. Path Value D
              (if (cons? Value) (note-parents D (parent-prefix Path)) D)) Staged (dictionary)))

(define prepare-stage
  _ [] _ D -> D
  Repo [[Path | _] | Paths] Original D ->
    (let Prior (index-find Original Path)
         _ (ensure (or (empty? Prior)
                       (= (shen-jit.bit-and (entry.extended (hd Prior)) 16384) 0))
                   (cn "path is marked skip-worktree: " Path))
         New (work-entry Repo Path Prior true)
      (do (remember D Path New) (prepare-stage Repo Paths Original D))))

(define checked-paths
  Paths -> (map (/. Path (if (= Path "") Path (checked-work-path Path))) Paths))

(define stage!
  Repo Paths TrackedOnly Forced ->
    (do (work-root Repo)
        (checked-paths Paths)
        (with-lock (index-path Repo)
          (/. Lock
            (let Index (read-index Repo)
                 Table (index-table Index (dictionary))
                 Global (ignore-global Repo)
                 Set (collect-paths Repo Paths Index Table Global TrackedOnly Forced (dictionary))
                 Staged (prepare-stage Repo (entries Set) Table (dictionary))
                 Keep (map (settle Repo) (remove-conflicting-entries Index Staged (stage-parents Staged) []))
                 All (shen.dict-fold (/. Key Value Acc (append Value Acc)) Staged Keep)
              (finish-index! Repo Lock All))))))

(define same-entry?
  [] [] -> true
  [A] [B] -> (and (= (entry.id A) (entry.id B)) (= (entry.mode A) (entry.mode B)))
  _ _ -> false)

(define head-index
  Repo -> (let Head (ref-value Repo "HEAD") (if (empty? Head) [] (committed-index Repo (hd Head)))))

(define unstage!
  Repo Paths Forced ->
    (do (work-root Repo)
        (checked-paths Paths)
        (with-lock (index-path Repo)
          (/. Lock
            (let Index (read-index Repo)
                 Head (index-table (head-index Repo) (dictionary))
                 Keep (map (settle Repo) (remove-staged Repo Index Paths Head Forced [] 0))
              (finish-index! Repo Lock Keep))))))

(define matching-path?
  _ [] -> false
  Name [Path | Rest] -> (or (covers? Name Path) (matching-path? Name Rest)))

(define remove-staged
  _ [] _ _ _ Acc Count ->
    (do (ensure (> Count 0) "path matches no index entries") Acc)
  Repo [E | More] Paths Head Forced Acc Count ->
    (let Name (entry.path E)
      (if (matching-path? Name Paths)
          (do (ensure (or Forced (same-entry? [E] (index-find Head Name))
                          (same-entry? [E] (work-entry Repo Name [E] false)))
                      (cn "staged contents differ from both HEAD and worktree: " Name))
              (remove-staged Repo More Paths Head Forced Acc (+ Count 1)))
          (remove-staged Repo More Paths Head Forced [E | Acc] Count))))

(define extract-matches
  Index Paths ->
    (mapcan (/. E (if (matching-path? (entry.path E) Paths) [E] [])) Index))

(define restore-staged!
  Repo Paths Source ->
    (do (work-root Repo)
        (checked-paths Paths)
        (with-lock (index-path Repo)
          (/. Lock
            (let Index (read-index Repo)
                 Base (if (empty? Source) (head-index Repo) (committed-index Repo (hd Source)))
                 Kept (mapcan (/. E (if (matching-path? (entry.path E) Paths) [] [(settle Repo E)])) Index)
                 Restore (extract-matches Base Paths)
                 _ (ensure (or (cons? Restore) (cons? (extract-matches Index Paths)))
                           "path matches neither the index nor the source tree")
                 Next (order-by (fn entry-before?) (append Kept Restore))
                 _ (validate-index-paths Next (dictionary))
              (finish-index! Repo Lock Next))))))

(define validate-index-paths
  [] _ -> true
  [E | More] Seen ->
    (let Path (entry.path E)
         _ (ensure (not (has-index-parent? Seen (parent-prefix Path)))
                   (cn "index paths collide at " Path))
      (do (remember Seen Path true) (validate-index-paths More Seen))))

(define has-index-parent?
  _ "" -> false
  Seen Path -> (or (cons? (lookup Seen Path)) (has-index-parent? Seen (parent-prefix Path))))

(define entry-change
  [] [] -> " "
  [] [_] -> "A"
  [_] [] -> "D"
  [A] [B] ->
    (if (= (shen-jit.bit-and (entry.mode A) 61440) (shen-jit.bit-and (entry.mode B) 61440))
        (if (same-entry? [A] [B]) " " "M")
        "T"))

(define entry-stages
  [] Acc -> Acc
  [E | More] Acc -> (entry-stages More (shen-jit.bit-or Acc (shen-jit.shift-left 1 (entry.stage E)))))

(define conflict-code
  2 -> "DD"
  4 -> "AU"
  6 -> "UD"
  8 -> "UA"
  10 -> "DU"
  12 -> "AA"
  _ -> "UU")

(define tracked-status
  Repo Name Index Head ->
    (let Group (entries-at Index Name)
         A (index-find Head Name)
         B (stage-zero Group)
         Present (if (cons? B) B A)
         Work (if (cons? B)
                  (if (or (> (shen-jit.bit-and (entry.extended (hd B)) 16384) 0)
                          (> (entry.flags (hd B)) 0)) B (work-entry Repo Name Present false))
                  [])
         Code (if (and (empty? B) (cons? Group))
                  (conflict-code (entry-stages Group 0))
                  (cn (entry-change A B) (entry-change B Work)))
      (if (= Code "  ") [] [(@p Code Name)])))

(define status-path-before?
  A B -> (bytes< (snd A) (snd B)))

\\ Untracked is no, normal, which shows a directory without tracked files as "dir/", or all.
(define status-records
  Repo Untracked ->
    (do (work-root Repo)
        (let Index (index-table (read-index Repo) (dictionary))
             Head (index-table (head-index Repo) (dictionary))
             Keys (shen.dict-fold (/. Key Value D (remember D Key true)) Head (dictionary))
             _ (shen.dict-fold (/. Key Value D (remember D Key true)) Index Keys)
             Tracked (mapcan (/. Pair (tracked-status Repo (hd Pair) Index Head)) (entries Keys))
             Directories (if (= Untracked normal)
                             [(shen.dict-fold (/. Key Value D (note-parents D (parent-prefix Key))) Index
                                              (dictionary))]
                             [])
             Others (if (= Untracked no) []
                        (mapcan (/. Path (cases (cons? (lookup Index Path)) []
                                                (and (not (suffix? "/" Path))
                                                     (= (mode-at (work-path Repo Path)) 16384))
                                                  [(@p "??" (cn Path "/"))]
                                                true [(@p "??" Path)]))
                          (visible-files Repo "" (ignore-global Repo) [] Directories)))
          (append (order-by (fn status-path-before?) Tracked) (order-by (fn status-path-before?) Others)))))

(define config-identity
  Repo Key Env ->
    (let Local (env Env)
         Value (config-value Repo Key)
      (cases (not (= Local "")) Local
             (cons? Value) (hd Value)
             true (global-identity Key))))

(define global-identity
  Key ->
    (let Home (env "HOME")
         Override (env "GIT_CONFIG_GLOBAL")
         Xdg (env "XDG_CONFIG_HOME")
         D (dictionary)
         _ (cases (not (= Override "")) (config-into Override D)
                  (not (= Home ""))
                    (do (config-into (if (= Xdg "") (fs.join Home ".config/git/config") (fs.join Xdg "git/config")) D)
                        (config-into (fs.join Home ".gitconfig") D))
                  true D)
      (setting D Key "")))

(define checked-identity
  Key S ->
    (let V (buffer.from-string S)
         N (buffer.length V)
      (do (ensure (and (> N 0) (no-bytes? V [0 10 13 60 62] 0 N)) (cn "invalid or missing " Key)) S)))

(define format-person
  Repo Role Time ->
    (let Name (checked-identity "user.name" (config-identity Repo "user.name" (cn Role "_NAME")))
         Email (checked-identity "user.email" (config-identity Repo "user.email" (cn Role "_EMAIL")))
         Date (env (cn Role "_DATE"))
         When (if (= Date "") (cn (str Time) " +0000") (git-date Date))
      (make-string "~A <~A> ~A" Name Email When)))

(define git-date
  S ->
    (let Parts (split (if (prefix? "@" S) (after "@" S) S) 32)
      (do (ensure (= (length Parts) 2) "date must be Unix seconds and a numeric timezone")
          (let _ (decimal (hd Parts))
               Zone (hd (tl Parts))
               _ (ensure (and (= (size Zone) 5) (element? (nth-byte Zone 0 1) ["+" "-"]))
                          "invalid timezone")
               _ (decimal (nth-byte Zone 1 4))
            (cn (hd Parts) (cn " " Zone))))))

(define commit-data
  Repo Tree Parents Message ->
    (let Now (shen-jit.truncate (get-time unix))
         Author (format-person Repo "GIT_AUTHOR" Now)
         Committer (format-person Repo "GIT_COMMITTER" Now)
         _ (ensure (and (not (= (trim Message) "")) (= (find-byte (buffer.from-string Message) 0 0 (size Message)) (size Message)))
                   "empty or invalid commit message")
      (buffer.from-string
        (make-string "tree ~A~%~Aauthor ~A~%committer ~A~%~%~A"
                     Tree (join-text "" (map (/. Id (newline (cn "parent " Id))) Parents))
                     Author Committer (if (suffix? (lf) Message) Message (newline Message))))))

(define require-idle-worktree
  Repo ->
    (ensure
      (not (some? (/. Name (not (= (node (fs.join (repo.dir Repo) Name)) absent)))
           ["MERGE_HEAD" "CHERRY_PICK_HEAD" "REVERT_HEAD" "rebase-apply" "rebase-merge" "sequencer"]))
      "repository has a Git operation in progress"))

(define commit!
  Repo Message AllowEmpty ->
    (do (work-root Repo)
        (with-lock (index-path Repo)
          (/. Locked
            (let _ (require-idle-worktree Repo)
                 Index (read-index Repo)
                 Parents (ref-value Repo "HEAD")
                 Tree (write-tree! Repo Index)
                 Old (if (empty? Parents) [] [(as-tree Repo (hd Parents))])
              (if (or AllowEmpty (and (empty? Parents) (cons? Index))
                      (and (cons? Parents) (not (= Old [Tree]))))
                  (let Id (write-object! Repo "commit" (commit-data Repo Tree Parents Message))
                    (do (require-update (set-ref! Repo "HEAD" Id Parents) "HEAD") (committed.make Id)))
                  (nothing-to-commit.make)))))))

(declare work-root [repo --> string])
(declare relative-path [repo --> [string --> [string --> string]]])
(declare stage! [repo --> [[list string] --> [boolean --> [boolean --> boolean]]]])
(declare unstage! [repo --> [[list string] --> [boolean --> boolean]]])
(declare restore-staged! [repo --> [[list string] --> [[option.t string] --> boolean]]])
(declare status-records [repo --> [untracked-files --> [list [string * string]]]])
(declare commit! [repo --> [string --> [boolean --> commit-outcome]]])
)

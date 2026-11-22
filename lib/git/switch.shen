(shen.x.namespace git
  (use fs)
  (use io)
  (use result)
  (use buffer)
  (use option)
  (use shen-jit)
  (import struct defstruct)
  (externals [directory file symlink])
  (export switch! fast-forward! merge! create-branch! delete-branch!)

(defstruct change (path : string) (before : (option.t entry)) (after : (option.t entry)))

(define compare-trees
  Before After ->
    (let A (index-table Before (dictionary))
         B (index-table After (dictionary))
         Keys (shen.dict-fold (/. Key Value D (remember D Key true)) A (dictionary))
         _ (shen.dict-fold (/. Key Value D (remember D Key true)) B Keys)
         D (dictionary)
      (shen.dict-fold (/. Path Value Acc
        (let Old (index-find A Path)
             New (index-find B Path)
          (if (same-entry? Old New) Acc
              (remember Acc Path (:change path <- Path before <- Old after <- New))))) Keys D)))

(define disappears?
  Changes Name ->
    (let Found (lookup Changes Name)
      (and (cons? Found) (cons? (change.before (hd Found))) (empty? (change.after (hd Found))))))

(define directory-drained?
  Repo Path Changes ->
    (drained-names? Repo Path Changes (names (work-path Repo Path))))

(define drained-names?
  _ _ _ [] -> true
  Repo Path Changes [Name | Rest] ->
    (let Child (append-path Path Name)
         Kind (node (work-path Repo Child))
      (and (if (= Kind directory) (directory-drained? Repo Child Changes)
               (disappears? Changes Child))
           (drained-names? Repo Path Changes Rest))))

(define checkout-parents?
  Repo Parent Changes ->
    (checkout-parents-from? Repo (split Parent 47) "" Changes))

(define checkout-parents-from?
  _ [] _ _ -> true
  Repo [Name | Rest] Parent Changes ->
    (let Part (append-path Parent Name)
      (or (disappears? Changes Part)
          (and (element? (node (work-path Repo Part)) [directory absent])
               (checkout-parents-from? Repo Rest Part Changes)))))

(define checkout-changes
  D -> (order-by (/. A B (bytes< (change.path A) (change.path B)))
                 (map (fn tl) (entries D))))

(define load-checkout-entry
  _ [] -> true
  Repo [E] ->
    (let Mode (entry.mode E)
         _ (ensure (not (= Mode 57344)) (cn "switch would change a submodule: " (entry.path E)))
         Body (require-type Repo (entry.id E) "blob")
      (if (and (= Mode 40960) (config-bool Repo "core.symlinks" true))
          (ensure (and (> (buffer.length Body) 0) (<= (buffer.length Body) 4095)
                       (= (find-byte Body 0 0 (buffer.length Body)) (buffer.length Body)))
                  (cn "invalid symlink target in " (entry.path E)))
          true)))

\\ The paths a switch would lose local changes at, and those where an untracked file is in
\\ the way, as (@p Overwritten Untracked).
(define verify-checkout
  _ _ _ [] Found -> Found
  Repo Index Changes [Change | Rest] (@p Overwritten Untracked) ->
    (let Path (change.path Change)
         Old (change.before Change)
         New (change.after Change)
         Staged (index-find Index Path)
         _ (load-checkout-entry Repo Old)
         _ (load-checkout-entry Repo New)
         Local (or (not (same-entry? Old Staged))
                   (and (cons? Staged) (not (= (entry.extended (hd Staged)) 0)))
                   (and (cons? Staged) (not (same-entry? Staged (work-entry Repo Path Staged false)))))
         Blocked (and (empty? Old) (cons? New) (not Local) (untracked-in-way? Repo Path Changes))
      (verify-checkout Repo Index Changes Rest
        (@p (if Local [Path | Overwritten] Overwritten) (if Blocked [Path | Untracked] Untracked)))))

(define untracked-in-way?
  Repo Path Changes ->
    (let Kind (path-mode Repo Path)
      (not (and (or (= Kind -1) (and (= Kind 16384) (directory-drained? Repo Path Changes)))
                (checkout-parents? Repo (parent-prefix Path) Changes)))))

\\ The new index, with the stat data of the files the switch wrote.
(define next-index
  Repo Keep Plan ->
    (order-by (fn entry-before?)
              (append Keep (map (/. E (let Stat (work-stat Repo (entry.path E))
                                        (if (empty? Stat) E
                                            (stat-entry (entry.path E) (entry.mode E) (entry.id E) (hd Stat)))))
                                (mapcan (fn change.after) Plan)))))

(define clear-empty-tree!
  Path ->
    (let _ (ensure (= (node Path) directory) (cn "expected directory at " Path))
         _ (map (/. Name (clear-empty-tree! (fs.join Path Name))) (names Path))
      (unwrap (fs.remove-directory Path))))

(define write-work-entry!
  Repo E ->
    (let Relative (entry.path E)
         _ (ensure (parents-clear? Repo (parent-prefix Relative)) (cn "parent changed: " Relative))
         Path (work-path Repo Relative)
         _ (if (= (node Path) directory) (clear-empty-tree! Path) true)
         _ (ensure (= (node Path) absent) (cn "path changed: " Relative))
         _ (folders (fs.parent Path))
         Mode (entry.mode E)
         Body (require-type Repo (entry.id E) "blob")
      (if (and (= Mode 40960) (config-bool Repo "core.symlinks" true))
          (unwrap (fs.symlink (buffer.string Body) Path))
          (ensure (write-new Path Body (if (= Mode 33261) 511 438)) (cn "path changed: " Relative)))))

(define take-work-files!
  _ [] _ _ -> true
  Repo [C | Plan] Index Journal ->
    (do (if (empty? (change.before C)) true
            (let Old (hd (change.before C))
                 Path (entry.path Old)
                 _ (ensure (same-entry? [Old] (work-entry Repo Path (index-find Index Path) false))
                           (cn "path changed during switch: " Path))
                 _ (unwrap (fs.remove-file (work-path Repo Path)))
              (vector-> Journal 1 [Old | (<-vector Journal 1)])))
        (take-work-files! Repo Plan Index Journal)))

(define put-work-files!
  _ [] _ -> true
  Repo [C | Plan] Journal ->
    (do (if (empty? (change.after C)) true
            (let E (hd (change.after C))
              (do (write-work-entry! Repo E)
                  (vector-> Journal 2 [E | (<-vector Journal 2)]))))
        (put-work-files! Repo Plan Journal)))

(define restore-switch!
  Repo Journal Metadata Old New ->
    (do (map (/. E (let Path (entry.path E)
                     (do (unwrap (fs.remove-file (work-path Repo Path)))
                         (prune-empty! (work-root Repo) (parent-prefix Path))))) (<-vector Journal 2))
        (map (write-work-entry! Repo) (<-vector Journal 1))
        (if (<-vector Journal 3)
            (with-lock Metadata (/. Lock
              (do (ensure (= (control Metadata) [New]) "ref changed during rollback")
                  (if (empty? Old) (unwrap (fs.remove-file Metadata))
                      (finish-lock Lock Metadata (buffer.from-string (hd Old)))))))
            true)))

(define checkout-publish!
  Repo Plan Table IndexLock Metadata RefLock Old New Keep ->
    (let Journal (vector 3)
         _ (vector-> Journal 1 [])
         _ (vector-> Journal 2 [])
         _ (vector-> Journal 3 false)
         _ (prepare-lock RefLock (buffer.from-string New))
      (trap-error
        (do (take-work-files! Repo Plan Table Journal)
            (put-work-files! Repo Plan Journal)
            (map (/. C (if (empty? (change.after C))
                           (prune-empty! (work-root Repo) (parent-prefix (change.path C))) true)) Plan)
            (prepare-lock IndexLock (encode-index Repo (next-index Repo Keep Plan)))
            (publish-lock RefLock Metadata)
            (vector-> Journal 3 true)
            (publish-lock IndexLock (index-path Repo))
            true)
        (/. E
          (let OldError (error-to-string E)
               Recovery (trap-error (do (restore-switch! Repo Journal Metadata Old New) [])
                          (/. R [(error-to-string R)]))
            (simple-error (if (empty? Recovery) OldError
                              (make-string "~A~%rollback failed: ~A" OldError (hd Recovery)))))))))

(define checkout!
  Repo Id Metadata Expected Text ->
    (transition! Repo Id Metadata Expected Text (ref-value Repo "HEAD") false))

\\ (switched Id) once the worktree, the index and Metadata show Id, or what keeps them from it.
(define transition!
  Repo Id Metadata Expected Text Head CleanIndex ->
    (do (work-root Repo)
        (with-lock (index-path Repo) (/. IndexLock
          (with-lock Metadata (/. RefLock
            (let _ (require-idle-worktree Repo)
                 _ (ensure (and (= (control Metadata) Expected) (= (ref-value Repo "HEAD") Head))
                            "ref changed concurrently")
                 Index (read-index Repo)
                 _ (ensure (regular-index? Index) "checkout needs a resolved index")
                 Base (if (empty? Head) [] (committed-index Repo (hd Head)))
                 Staged (if CleanIndex (map (fn change.path) (checkout-changes (compare-trees Base Index))) [])
                 Changes (compare-trees Base (committed-index Repo Id))
                 Plan (checkout-changes Changes)
                 Table (index-table Index (dictionary))
                 Found (if (cons? Staged) (@p Staged []) (verify-checkout Repo Table Changes Plan (@p [] [])))
              (cases (cons? (fst Found)) (would-overwrite.make (reverse (fst Found)))
                     (cons? (snd Found)) (untracked.make (reverse (snd Found)))
                     true (let Keep (mapcan (/. E (if (empty? (lookup Changes (entry.path E)))
                                                      [(settle Repo E)] [])) Index)
                               _ (ensure (= (ref-value Repo "HEAD") Head) "HEAD changed concurrently")
                               _ (checkout-publish! Repo Plan Table IndexLock Metadata RefLock Expected
                                                    (newline Text) Keep)
                            (switched.make Id))))))))))

(define same-index?
  [] [] -> true
  [A | As] [B | Bs] -> (and (= (entry.path A) (entry.path B)) (same-entry? [A] [B]) (same-index? As Bs))
  _ _ -> false)

(define head-is?
  Repo Dir Ref ->
    (and (not (= (repo.dir Repo) Dir))
         (= (control (fs.join Dir "HEAD")) [(newline (cn "ref: " Ref))])))

(define taken-branch?
  Repo Ref ->
    (let Base (fs.join (repo.common Repo) "worktrees")
      (or (head-is? Repo (repo.common Repo) Ref)
          (and (= (node Base) directory)
               (some? (/. Name (head-is? Repo (fs.join Base Name) Ref)) (names Base))))))

(define head-live-branch!
  Repo Ref -> (ensure (not (taken-branch? Repo Ref)) (cn "branch is checked out in another worktree: " Ref)))

(define require-ref
  Repo Ref -> (let Found (ref-value Repo Ref)
                (if (cons? Found) (hd Found) (git-error (cn "no such ref: " Ref)))))

(define switch!
  Repo Spec Detached ->
    (let Ref (if Detached "" (branch-ref Spec))
         Id (if Detached (as-commit Repo (resolve-revision Repo Spec))
                (as-commit Repo (require-ref Repo Ref)))
         _ (if Detached true (head-live-branch! Repo Ref))
      (checkout! Repo Id (ref-path Repo "HEAD") (control (ref-path Repo "HEAD"))
                 (if Detached Id (cn "ref: " Ref)))))

(define reaches
  _ _ [] _ -> false
  Repo Goal [Id | Todo] Seen ->
    (cases (= Goal Id) true
           (cons? (lookup Seen Id)) (reaches Repo Goal Todo Seen)
           true (do (remember Seen Id true)
                    (reaches Repo Goal (append (commit-parents Repo Id) Todo) Seen))))

(define fast-forward!
  Repo Spec ->
    (let Id (as-commit Repo (resolve-revision Repo Spec))
         Current (ref-value Repo "HEAD")
      (cases (and (cons? Current) (reaches Repo Id Current (dictionary))) (fast-forward.make (hd Current))
             (or (empty? Current) (reaches Repo (hd Current) [Id] (dictionary)))
               (moved (move-current! Repo Current Id) (fast-forward.make Id))
             true (diverged.make))))

(define create-branch!
  Repo Name Id -> (set-ref! Repo (branch-ref Name) (as-commit Repo Id) []))

(define delete-branch!
  Repo Name Forced ->
    (let Ref (branch-ref Name)
         _ (ensure (not (= (head-ref Repo) Ref)) "cannot delete the current branch")
         _ (head-live-branch! Repo Ref)
         Id (require-ref Repo Ref)
         _ (ensure (or Forced (reaches Repo Id (ref-value Repo "HEAD") (dictionary)))
                   (cn "branch is not merged into HEAD: " Name))
      (delete-ref! Repo Ref [Id])))

(define move-current!
  Repo Current Id ->
    (let Target (head-ref Repo)
         Path (ref-path Repo Target)
         _ (validate-ref-hierarchy Repo Target)
         _ (clear-ref-dir! Path)
      (transition! Repo Id Path (control Path) Id Current true)))

(define mark-ancestors
  _ [] Seen -> Seen
  Repo [Id | Rest] Seen ->
    (if (cons? (lookup Seen Id)) (mark-ancestors Repo Rest Seen)
        (do (remember Seen Id true)
            (mark-ancestors Repo (append (commit-parents Repo Id) Rest) Seen))))

(define first-commons
  _ [] _ _ Found -> Found
  Repo [Id | Rest] Seen Ours Found ->
    (if (cons? (lookup Seen Id)) (first-commons Repo Rest Seen Ours Found)
        (do (remember Seen Id true)
            (if (cons? (lookup Ours Id)) (first-commons Repo Rest Seen Ours [Id | Found])
                (first-commons Repo (append (commit-parents Repo Id) Rest) Seen Ours Found)))))

(define merge-bases
  Repo A B ->
    (let Ours (mark-ancestors Repo [A] (dictionary))
         Common (first-commons Repo [B] (dictionary) Ours [])
         Best (mapcan (/. Id
                  (if (some? (/. Other (and (not (= Id Other)) (reaches Repo Id [Other] (dictionary)))) Common)
                      [] [Id])) Common)
         _ (ensure (cons? Best) "histories have no common merge base")
      Best))

\\ The merged entries at Path, or the path itself when both sides changed it differently.
(define merge-path
  Path Base A B ->
    (cases (same-entry? A B) A
           (same-entry? Base A) B
           (same-entry? Base B) A
           true Path))

(define merge-index
  Base Ours Theirs ->
    (let D (index-table Base (dictionary))
         A (index-table Ours (dictionary))
         B (index-table Theirs (dictionary))
         Paths (shen.dict-fold (/. P V Acc (remember Acc P true)) A (dictionary))
         _ (shen.dict-fold (/. P V Acc (remember Acc P true)) B Paths)
         _ (shen.dict-fold (/. P V Acc (remember Acc P true)) D Paths)
         Merged (map (/. Pair (let P (hd Pair) (merge-path P (index-find D P) (index-find A P) (index-find B P))))
                     (order-by (fn ref-before?) (entries Paths)))
      (@p (mapcan (/. X (if (string? X) [] X)) Merged) (mapcan (/. X (if (string? X) [X] [])) Merged))))

\\ The paths of a sorted index below another of its paths, which no tree can hold.
(define index-collisions
  [] _ Found -> (reverse Found)
  [E | More] Seen Found ->
    (let Path (entry.path E)
         Hit (has-index-parent? Seen (parent-prefix Path))
      (do (remember Seen Path true) (index-collisions More Seen (if Hit [Path | Found] Found)))))

\\ A three-way merge of paths each side changed, or the reason it stopped.
(define merge!
  Repo Spec Message ->
    (let Id (as-commit Repo (resolve-revision Repo Spec))
         Current (ref-value Repo "HEAD")
      (if (or (empty? Current) (reaches Repo (hd Current) [Id] (dictionary))
              (reaches Repo Id Current (dictionary)))
          (fast-forward! Repo Spec)
          (let A (hd Current)
               Bases (merge-bases Repo A Id)
            (if (cons? (tl Bases)) (multiple-bases.make Bases)
                (let Index (merge-index (committed-index Repo (hd Bases)) (committed-index Repo A)
                                        (committed-index Repo Id))
                     Conflicts (append (snd Index) (index-collisions (fst Index) (dictionary) []))
                  (if (cons? Conflicts) (conflict.make Conflicts)
                      (let Tree (write-tree! Repo (fst Index))
                           New (write-object! Repo "commit" (commit-data Repo Tree [A Id] Message))
                        (moved (move-current! Repo Current New) (merged.make New))))))))))

(declare create-branch! [repo --> [string --> [string --> ref-update]]])
(declare delete-branch! [repo --> [string --> [boolean --> ref-update]]])
(declare switch! [repo --> [string --> [boolean --> switch-outcome]]])
(declare fast-forward! [repo --> [string --> merge-outcome]])
(declare merge! [repo --> [string --> [string --> merge-outcome]]])
)

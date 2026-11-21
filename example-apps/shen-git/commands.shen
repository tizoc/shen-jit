\\ The shen-git command line, typed: each command gives true, or raises a message for the user.
(shen.x.namespace shen-git
  (use git)
  (use fs)
  (use buffer)
  (use option)
  (import git after decimal ensure git-error prefix? some? committed nothing-to-commit updated
    changed-concurrently switched would-overwrite untracked merged fast-forward conflict
    multiple-bases diverged)
  (export entry)

(define join-with
  {string --> (list string) --> string}
  _ [] -> ""
  _ [S] -> S
  Separator [S | More] -> (cn S (cn Separator (join-with Separator More))))

(define print-lines
  {(list string) --> boolean}
  Lines -> (do (map (fn print-line) Lines) true))

(define cli-help
  {--> boolean}
  -> (print-text
"usage: shen-git [-C DIRECTORY] COMMAND [ARGUMENTS]
  init [--bare] [-b NAME] [--object-format=sha1|sha256] [DIRECTORY]
  clone [--bare] SOURCE DIRECTORY
  repack
  status [--short|--porcelain] [-uno|-unormal|-uall] [-z]
  add [-A|-u] [-f] [--] [PATH ...]
  rm --cached [-f] [--] PATH ...
  restore --staged [--source REVISION] [--] PATH ...
  commit [-m MESSAGE] [--allow-empty]
  log [--oneline|--first-parent] [-n COUNT] [REVISION]
  branch [NAME [REVISION]] | branch [-d|-D] NAME
  tag [NAME [REVISION]]
  switch [--detach] BRANCH-OR-REVISION
  merge [--ff-only] REVISION [-m MESSAGE]
  diff [--name-status] [--cached | REVISION REVISION]
  rev-parse REVISION ...
  show-ref
  ls-files [-s] [-z]
  ls-tree [-r] [-z] REVISION
  hash-object [-w] [-t TYPE] FILE
  cat-file -t|-s|-p|-e REVISION
  show [REVISION[:PATH]]
  write-tree
  update-ref NAME NEW [OLD] | update-ref -d NAME [OLD]
  config [--local] [--get] KEY [VALUE]
"))

(define entry
  {--> boolean}
  -> (trap-error (cli (git.resolve-from "." ".") (arguments)) (fn cli-error)))

(define cli
  {string --> (list string) --> boolean}
  Cwd ["-C" Path | Args] -> (cli (if (= Path "") Cwd (git.resolve-from Cwd Path)) Args)
  _ [] -> (cli-help)
  _ ["--help"] -> (cli-help)
  _ ["--version"] -> (print-line "shen-git 0.1")
  Cwd ["init" | Args] -> (cli-init Cwd Args false "main" "sha1" Cwd)
  Cwd ["clone" "--bare" Source Directory] -> (cli-clone Cwd Source Directory true)
  Cwd ["clone" Source Directory] -> (cli-clone Cwd Source Directory false)
  Cwd Args -> (repository-command (git.open-repo Cwd) Cwd Args))

(define cli-clone
  {string --> string --> string --> boolean --> boolean}
  Cwd Source Directory Bare ->
    (let Repo (git.clone! (fs.join Cwd Source) (fs.join Cwd Directory) Bare)
      (print-line (cn "Cloned repository into " (if Bare (git.repo.dir Repo) (git.work-root Repo))))))

\\ Directory is the working directory until an argument names another.
(define cli-init
  {string --> (list string) --> boolean --> string --> string --> string --> boolean}
  _ [] Bare Branch Format Directory ->
    (let Repo (git.init Directory Bare Branch Format)
      (print-line (cn "Initialized Git repository in " (git.repo.dir Repo))))
  Cwd ["--bare" | Args] _ Branch Format Dir -> (cli-init Cwd Args true Branch Format Dir)
  Cwd ["-b" Name | Args] Bare _ Format Dir -> (cli-init Cwd Args Bare Name Format Dir)
  Cwd ["--initial-branch" Name | Args] Bare _ Format Dir -> (cli-init Cwd Args Bare Name Format Dir)
  Cwd [Arg | Args] Bare Branch Format Dir ->
    (cases (prefix? "--initial-branch=" Arg)
             (cli-init Cwd Args Bare (after "--initial-branch=" Arg) Format Dir)
           (prefix? "--object-format=" Arg)
             (cli-init Cwd Args Bare Branch (after "--object-format=" Arg) Dir)
           (and (not (prefix? "-" Arg)) (= Dir Cwd))
             (cli-init Cwd Args Bare Branch Format (fs.join Cwd Arg))
           true (git-error (cn "invalid init argument " Arg))))

(define repository-command
  {git.repo --> string --> (list string) --> boolean}
  R Cwd ["status" | Args] -> (cli-status R Args git.normal false)
  R Cwd ["add" | Args] -> (cli-stage R Cwd Args false false false)
  R Cwd ["rm" "--cached" "-f" | Paths] -> (cli-unstage R Cwd Paths true)
  R Cwd ["rm" "--cached" | Paths] -> (cli-unstage R Cwd Paths false)
  R Cwd ["restore" "--staged" | Args] -> (cli-restore-staged R Cwd Args (option.none))
  R _ ["commit" | Args] -> (cli-commit R Args [] false)
  R _ ["log" | Args] -> (cli-log R Args 100000 "HEAD" false)
  R _ ["branch" | Args] -> (cli-branch R Args)
  R _ ["tag" | Args] -> (cli-tag R Args)
  R _ ["switch" "--detach" Spec] -> (report-switch (git.switch! R Spec true))
  R _ ["switch" Name] -> (report-switch (git.switch! R Name false))
  R _ ["checkout" "--detach" Spec] -> (report-switch (git.switch! R Spec true))
  R _ ["checkout" Name] -> (report-switch (git.switch! R Name false))
  R _ ["merge" "--ff-only" Spec] -> (report-merge (git.fast-forward! R Spec))
  R _ ["merge" Spec] -> (report-merge (git.merge! R Spec (cn "Merge " Spec)))
  R _ ["merge" Spec "-m" Message] -> (report-merge (git.merge! R Spec Message))
  R _ ["diff" | Args] -> (cli-diff R Args false false [])
  R _ ["show"] -> (cli-cat R "-p" (git.resolve-revision R "HEAD"))
  R _ ["show" Spec] -> (cli-cat R "-p" (git.resolve-revision R Spec))
  R _ ["rev-parse" "--show-toplevel"] -> (print-line (git.work-root R))
  R _ ["rev-parse" "--git-dir"] -> (print-line (git.repo.dir R))
  R _ ["rev-parse" "--show-object-format"] -> (print-line (if (= (git.repo.width R) 20) "sha1" "sha256"))
  R _ ["rev-parse" Revision | Rest] -> (print-lines (map (git.resolve-revision R) [Revision | Rest]))
  R _ ["show-ref"] -> (show-refs (git.refs R))
  R _ ["ls-files" | Args] -> (cli-ls-files R Args false false)
  R _ ["ls-tree" | Args] -> (cli-ls-tree R Args false false)
  R Cwd ["hash-object" | Args] -> (cli-hash R Cwd Args "blob" false)
  R _ ["cat-file" Option Spec] -> (cli-cat R Option (git.resolve-revision R Spec))
  R _ ["write-tree"] -> (print-line (git.write-tree! R (git.read-index R)))
  R _ ["repack"] -> (print-lines (git.repack! R))
  R _ ["update-ref" "-d" Name] -> (ref-updated Name (git.delete-ref! R Name git.any))
  R _ ["update-ref" "-d" Name Old] -> (ref-updated Name (git.delete-ref! R Name (expected-id R Old)))
  R _ ["update-ref" Name New] -> (cli-set-ref R Name New git.any)
  R _ ["update-ref" Name New Old] -> (cli-set-ref R Name New (expected-id R Old))
  R _ ["config" | Args] -> (cli-config R Args)
  _ _ [Command | _] -> (git-error (cn "unsupported command or options: " Command)))

\\ Outcomes other than the one asked for are errors for the command line.
(define report-switch
  {git.switch-outcome --> boolean}
  (:switched _) -> true
  (:would-overwrite Paths) -> (paths-error "local changes would be overwritten" Paths)
  (:untracked Paths) -> (paths-error "untracked files would be overwritten" Paths))

(define report-merge
  {git.merge-outcome --> boolean}
  (:merged Id) -> (print-line Id)
  (:fast-forward Id) -> (print-line Id)
  (:conflict Paths) -> (paths-error "merge conflict in" Paths)
  (:multiple-bases Ids) -> (paths-error "several merge bases" Ids)
  (:diverged) -> (git-error "not possible to fast-forward")
  (:would-overwrite Paths) -> (paths-error "local changes would be overwritten" Paths)
  (:untracked Paths) -> (paths-error "untracked files would be overwritten" Paths))

(define report-commit
  {git.commit-outcome --> boolean}
  (:committed Id) -> (print-line Id)
  (:nothing-to-commit) -> (git-error "nothing to commit"))

(define ref-updated
  {string --> git.ref-update --> boolean}
  _ (:updated _) -> true
  Name (:changed-concurrently Found) -> (git-error (cn "ref changed concurrently: " (found-at Name Found))))

(define found-at
  {string --> (option.t string) --> string}
  Name [] -> (cn "no " Name)
  Name [Id] -> (make-string "~A is at ~A" Name Id))

(define paths-error
  {string --> (list string) --> boolean}
  Text Paths -> (git-error (cn Text (cn ": " (join-with " " Paths)))))

(define show-refs
  {(list (string * string)) --> boolean}
  [] -> (quit 1)
  Refs -> (print-lines (map (/. Ref (cn (snd Ref) (cn " " (fst Ref)))) Refs)))

(define write-path-record
  {string --> string --> boolean --> boolean}
  Prefix Path true -> (print-text (cn Prefix (cn Path "c#0;")))
  Prefix Path false -> (print-line (cn Prefix (git.quote-path Path false))))

(define cli-status
  {git.repo --> (list string) --> git.untracked-files --> boolean --> boolean}
  R [] Untracked Zero ->
    (do (map (/. Pair
               (let Prefix (cn (fst Pair) " ")
                 (if Zero (write-path-record Prefix (snd Pair) true)
                     (print-line (cn Prefix (git.quote-path (snd Pair) true))))))
             (git.status-records R Untracked))
        true)
  R ["-uno" | Args] _ Zero -> (cli-status R Args git.no Zero)
  R ["--untracked-files=no" | Args] _ Zero -> (cli-status R Args git.no Zero)
  R ["-uall" | Args] _ Zero -> (cli-status R Args git.all Zero)
  R ["--untracked-files=all" | Args] _ Zero -> (cli-status R Args git.all Zero)
  R ["-unormal" | Args] _ Zero -> (cli-status R Args git.normal Zero)
  R ["--untracked-files=normal" | Args] _ Zero -> (cli-status R Args git.normal Zero)
  R ["-z" | Args] U _ -> (cli-status R Args U true)
  R [Opt | Args] U Z ->
    (do (ensure (element? Opt ["--short" "-s" "--porcelain" "--porcelain=v1"])
                (cn "unsupported status option " Opt))
        (cli-status R Args U Z)))

(define cli-stage
  {git.repo --> string --> (list string) --> boolean --> boolean --> boolean --> boolean}
  R Cwd ["-f" | Args] Tracked _ All -> (cli-stage R Cwd Args Tracked true All)
  R Cwd ["--force" | Args] Tracked _ All -> (cli-stage R Cwd Args Tracked true All)
  R Cwd ["-A" | Args] Tracked Forced _ -> (cli-stage R Cwd Args Tracked Forced true)
  R Cwd ["--all" | Args] Tracked Forced _ -> (cli-stage R Cwd Args Tracked Forced true)
  R Cwd ["-u" | Args] _ Forced _ -> (cli-stage R Cwd Args true Forced true)
  R Cwd ["--update" | Args] _ Forced _ -> (cli-stage R Cwd Args true Forced true)
  R Cwd ["--" | Paths] Tracked Forced All -> (stage-paths R Cwd Paths Tracked Forced All)
  R Cwd Paths Tracked Forced All ->
    (do (ensure (not (some? (prefix? "-") Paths)) "unsupported add option")
        (stage-paths R Cwd Paths Tracked Forced All)))

(define stage-paths
  {git.repo --> string --> (list string) --> boolean --> boolean --> boolean --> boolean}
  R _ [] Tracked Forced true -> (git.stage! R [""] Tracked Forced)
  _ _ [] _ _ false -> (git-error "specify paths or use add -A")
  R Cwd Paths Tracked Forced _ ->
    (git.stage! R (map (git.relative-path R Cwd) Paths) Tracked Forced))

(define cli-unstage
  {git.repo --> string --> (list string) --> boolean --> boolean}
  R Cwd ["--" | Paths] Force -> (cli-unstage R Cwd Paths Force)
  R Cwd Paths Force -> (git.unstage! R (map (git.relative-path R Cwd) Paths) Force))

(define cli-restore-staged
  {git.repo --> string --> (list string) --> (option.t string) --> boolean}
  R Cwd ["--source" Spec | Args] _ ->
    (cli-restore-staged R Cwd Args (option.some (git.resolve-revision R Spec)))
  R Cwd ["--" | Paths] Source -> (git.restore-staged! R (map (git.relative-path R Cwd) Paths) Source)
  R Cwd Paths Source ->
    (do (ensure (not (some? (prefix? "-") Paths)) "unsupported restore option")
        (git.restore-staged! R (map (git.relative-path R Cwd) Paths) Source)))

(define cli-commit
  {git.repo --> (list string) --> (list string) --> boolean --> boolean}
  _ [] [] _ -> (git-error "supply a commit message with -m")
  R [] Rev Allow -> (report-commit (git.commit! R (join-with "c#10;c#10;" (reverse Rev)) Allow))
  R ["-m" Message | Args] Rev Allow -> (cli-commit R Args [Message | Rev] Allow)
  R ["--allow-empty" | Args] Messages _ -> (cli-commit R Args Messages true)
  _ _ _ _ -> (git-error "unsupported commit arguments"))

(define print-log-record
  {git.log-entry --> boolean}
  Entry -> (print-line (cn (first-bytes (git.log-entry.id Entry) 7) (cn " " (git.log-entry.subject Entry)))))

(define cli-log
  {git.repo --> (list string) --> number --> string --> boolean --> boolean}
  Repo [] N Spec Single ->
    (git.each-commit Repo (git.resolve-revision Repo Spec) N Single (fn print-log-record))
  R ["--oneline" | Rest] N Spec Single -> (cli-log R Rest N Spec Single)
  R ["--first-parent" | Rest] N Spec _ -> (cli-log R Rest N Spec true)
  R ["-n" N | Rest] _ Spec Single -> (cli-log R Rest (decimal N) Spec Single)
  R ["--max-count" N | Rest] _ Spec Single -> (cli-log R Rest (decimal N) Spec Single)
  R [Revision] N _ Single -> (cli-log R [] N Revision Single)
  _ _ _ _ _ -> (git-error "unsupported log arguments"))

(define names-under
  {string --> (list (string * string)) --> (list string)}
  _ [] -> []
  Prefix [(@p Name _) | Refs] ->
    (if (prefix? Prefix Name) [(after Prefix Name) | (names-under Prefix Refs)] (names-under Prefix Refs)))

(define cli-branch
  {git.repo --> (list string) --> boolean}
  R [] -> (let Head (git.head-ref R)
            (print-lines (map (/. Name (cn (if (= Head (cn "refs/heads/" Name)) "* " "  ") Name))
                              (names-under "refs/heads/" (git.refs R)))))
  R ["-d" Name] -> (ref-updated Name (git.delete-branch! R Name false))
  R ["-D" Name] -> (ref-updated Name (git.delete-branch! R Name true))
  R [Name] -> (cli-branch R [Name "HEAD"])
  R [Name Revision] -> (ref-updated Name (git.create-branch! R Name (git.resolve-revision R Revision)))
  _ _ -> (git-error "unsupported branch arguments"))

(define cli-tag
  {git.repo --> (list string) --> boolean}
  R [] -> (print-lines (names-under "refs/tags/" (git.refs R)))
  R ["-d" Name] -> (ref-updated Name (git.delete-ref! R (cn "refs/tags/" Name) git.any))
  R [Name] -> (cli-tag R [Name "HEAD"])
  R [Name Revision] ->
    (ref-updated Name (git.set-ref! R (cn "refs/tags/" Name) (git.resolve-revision R Revision) []))
  _ _ -> (git-error "unsupported tag arguments"))

(define cli-diff
  {git.repo --> (list string) --> boolean --> boolean --> (list string) --> boolean}
  R ["--cached" | Args] Names _ Revs -> (cli-diff R Args Names true Revs)
  R ["--staged" | Args] Names _ Revs -> (cli-diff R Args Names true Revs)
  R ["--name-status" | Args] _ Cached Revs -> (cli-diff R Args true Cached Revs)
  R [Spec | Rest] Names Cached Revs ->
    (do (ensure (and (not (prefix? "-" Spec)) (< (length Revs) 2)) "unsupported diff arguments")
        (cli-diff R Rest Names Cached [Spec | Revs]))
  R [] Names false [] -> (diff-output R Names true (git.worktree-changes R (option.none)))
  R [] Names true [] -> (diff-output R Names false (git.staged-changes R (option.none)))
  R [] Names true [Spec] ->
    (diff-output R Names false (git.staged-changes R (option.some (git.resolve-revision R Spec))))
  R [] Names false [B A] ->
    (diff-output R Names false (git.revision-changes R (git.resolve-revision R A) (git.resolve-revision R B)))
  R [] Names false [Spec] ->
    (diff-output R Names true (git.worktree-changes R (option.some (git.resolve-revision R Spec))))
  _ _ _ _ _ -> (git-error "unsupported diff arguments"))

(define diff-output
  {git.repo --> boolean --> boolean --> (list git.change) --> boolean}
  _ true _ Changes ->
    (do (map (/. C (write-path-record (cn (git.change-code C) "c#9;") (git.change.path C) false)) Changes)
        true)
  R false Work Changes ->
    (do (map (/. C (git.write-patch R Work C (fn print-text))) Changes) true))

(define cli-ls-files
  {git.repo --> (list string) --> boolean --> boolean --> boolean}
  R [] Stage Zero ->
    (do (map (/. E
               (write-path-record
                 (if Stage
                     (make-string "~A ~A ~A~A" (git.display-mode (git.entry.mode E)) (git.entry.id E)
                                  (git.entry.stage E) "c#9;")
                     "")
                 (git.entry.path E) Zero))
             (git.read-index R))
        true)
  R ["-s" | Rest] _ Zero -> (cli-ls-files R Rest true Zero)
  R ["--stage" | Rest] _ Zero -> (cli-ls-files R Rest true Zero)
  R ["-z" | Rest] Stage _ -> (cli-ls-files R Rest Stage true)
  _ _ _ _ -> (git-error "unsupported ls-files options"))

(define tree-display
  {git.repo --> (list git.tree-entry) --> string --> boolean --> boolean --> boolean}
  _ [] _ _ _ -> true
  Repo [E | More] Prefix Recursive Zero ->
    (let Mode (git.tree-entry.mode E)
         Name (cn Prefix (git.tree-entry.name E))
         Id (git.tree-entry.id E)
         _ (if (and Recursive (= Mode 16384))
               (tree-display Repo (git.tree-entries Repo Id) (cn Name "/") true Zero)
               (write-path-record (make-string "~A ~A ~A~A" (git.display-mode Mode) (git.mode-kind Mode) Id "c#9;")
                                  Name Zero))
      (tree-display Repo More Prefix Recursive Zero)))

(define cli-ls-tree
  {git.repo --> (list string) --> boolean --> boolean --> boolean}
  R ["-r" | Rest] _ Zero -> (cli-ls-tree R Rest true Zero)
  R ["-z" | Rest] Recursive _ -> (cli-ls-tree R Rest Recursive true)
  R [Spec] Recursive Zero ->
    (tree-display R (git.tree-entries R (git.as-tree R (git.resolve-revision R Spec))) "" Recursive Zero)
  _ _ _ _ -> (git-error "usage: ls-tree [-r] [-z] REVISION"))

(define cli-cat
  {git.repo --> string --> string --> boolean}
  Repo "-t" Id -> (print-line (fst (git.read-object Repo Id)))
  Repo "-s" Id -> (print-line (str (buffer.length (snd (git.read-object Repo Id)))))
  Repo "-e" Id -> (do (git.read-object Repo Id) true)
  Repo "-p" Id -> (show-object Repo Id (git.read-object Repo Id))
  _ _ _ -> (git-error "usage: cat-file -t|-s|-p|-e REVISION"))

(define show-object
  {git.repo --> string --> (string * buffer.view) --> boolean}
  Repo Id (@p "tree" _) -> (tree-display Repo (git.tree-entries Repo Id) "" false false)
  _ _ (@p _ Body) -> (stdout Body))

(define cli-hash
  {git.repo --> string --> (list string) --> string --> boolean --> boolean}
  R Cwd ["-t" Kind | Rest] _ Write -> (cli-hash R Cwd Rest Kind Write)
  R Cwd ["-w" | Rest] Kind _ -> (cli-hash R Cwd Rest Kind true)
  R Cwd [Name] Kind Write ->
    (print-line (git.hash-file R (fs.join Cwd Name) Kind Write))
  _ _ _ _ _ -> (git-error "usage: hash-object [-w] [-t TYPE] FILE"))

(define expected-id
  {git.repo --> string --> git.expectation}
  Repo Spec ->
    (if (= (git.null-id Repo) Spec)
        []
        [(git.resolve-revision Repo Spec)]))

(define cli-set-ref
  {git.repo --> string --> string --> git.expectation --> boolean}
  Repo Name Spec Expected ->
    (ref-updated Name (git.set-ref! Repo Name (git.resolve-revision Repo Spec) Expected)))

(define print-config
  {(option.t string) --> boolean}
  [Value] -> (print-line Value)
  [] -> (quit 1))

(define cli-config
  {git.repo --> (list string) --> boolean}
  Repo ["--local" | Rest] -> (cli-config Repo Rest)
  Repo ["--get" Key] -> (cli-config Repo [Key])
  Repo [Key] -> (print-config (git.config-value Repo Key))
  Repo [Key Value] -> (git.set-config! Repo Key Value)
  _ _ -> (git-error "usage: config [--local] [--get] SECTION.NAME [VALUE]"))
)

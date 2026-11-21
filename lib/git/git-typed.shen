\\ The Git library's types for typed clients: the outcome families and the values a ref update
\\ may expect. The untyped files declare their functions' types.
(shen.x.namespace git
  (use buffer)
  (use option)
  (import struct union)
  (export id expectation untracked-files no normal all any switch-outcome merge-outcome commit-outcome
    ref-update)

\\ Object IDs are hexadecimal strings.
(synonyms id string)

(union switch-outcome switched would-overwrite untracked)
(union merge-outcome merged fast-forward conflict multiple-bases diverged would-overwrite untracked)
(union commit-outcome committed nothing-to-commit)
(union ref-update updated changed-concurrently)

(datatype untracked-files
  ______________________
  no : untracked-files;

  ______________________
  normal : untracked-files;

  ______________________
  all : untracked-files;)

(datatype expectation
  _________________
  any : expectation;

  _________________
  [] : expectation;

  Id : string;
  _________________
  [Id] : expectation;)

\\ The library's own steps that must happen, or raise.
(define require-update
  {ref-update --> string --> boolean}
  (:updated _) _ -> true
  (:changed-concurrently _) Name -> (git-error (cn "ref changed concurrently: " Name)))

(define require-switch
  {switch-outcome --> boolean}
  (:switched _) -> true
  (:would-overwrite Paths) -> (git-error (cn "local changes would be overwritten: " (join-text " " Paths)))
  (:untracked Paths) -> (git-error (cn "untracked files would be overwritten: " (join-text " " Paths))))

\\ A merge's outcome once HEAD moves, or what kept it from moving.
(define moved
  {switch-outcome --> merge-outcome --> merge-outcome}
  (:switched _) Outcome -> Outcome
  (:would-overwrite Paths) _ -> (would-overwrite.make Paths)
  (:untracked Paths) _ -> (untracked.make Paths))

)

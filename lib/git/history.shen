(shen.x.namespace git
  (use buffer)
  (import struct defstruct)
  (export each-commit log-entry log-entry.time log-entry.id log-entry.subject log-entry.parents)

\\ A commit as log shows it: its committer's time, ID, subject and parents.
(defstruct log-entry (time : number) (id : string) (subject : string) (parents : (list string)))

(define commit-subject
  Lines -> (commit-subject-lines Lines false))

(define commit-subject-lines
  [] _ -> ""
  ["" | More] _ -> (commit-subject-lines More true)
  [S | More] false -> (commit-subject-lines More false)
  [S | _] true -> S)

(define log-record
  Repo Id ->
    (let V (require-type Repo Id "commit")
         Lines (split (buffer.string V) 10)
         Identity (one-header-line Lines "committer")
         Tail (trim (snd (partition-text Identity 62)))
         Date (decimal (fst (partition-text Tail 32)))
      (log-entry.make Date Id (commit-subject Lines)
                      (if (element? Id (repo.shallow Repo)) [] (first-lines "parent " Lines)))))

(define log-take
  _ _ 0 _ _ _ -> true
  _ [] _ _ _ _ -> true
  Repo [Entry | Rest] Left Single Seen Visit ->
    (let _ (Visit Entry)
         Parents (log-entry.parents Entry)
         Candidates (if (and Single (cons? Parents)) [(hd Parents)] Parents)
         More (log-load Repo Candidates Seen Rest)
      (log-take Repo (order-by (/. A B (> (log-entry.time A) (log-entry.time B))) More) (- Left 1)
                Single Seen Visit)))

(define log-load
  _ [] _ Acc -> Acc
  R [Id | Ids] Seen Acc ->
    (if (cons? (lookup Seen Id))
        (log-load R Ids Seen Acc)
        (do (remember Seen Id true) (log-load R Ids Seen [(log-record R Id) | Acc]))))

(define each-commit
  Repo Id Count FirstParent Visit ->
    (let _ (ensure (and (integer? Count) (>= Count 0)) "invalid commit count")
         Seen (dictionary)
      (log-take Repo (log-load Repo [(as-commit Repo Id)] Seen []) Count FirstParent Seen Visit)))

(declare each-commit [repo --> [string --> [number --> [boolean --> [[log-entry --> A] --> boolean]]]]])
)

\\ Syntactic C call matching. Function identity includes file, name and definition byte.
(defdatalog source-deps.program
  (type function [fn string string integer])
  (type site [at string integer integer integer integer])
  (relation source-file [string integer integer])
  (relation source-definition [site string])
  (relation source-call [site string string])
  (relation usable-file [string])
  (relation excluded-file [string])
  (relation defined [string string integer])
  (relation function [function])
  (relation call-file [site string])
  (relation call [site string string])
  (relation local-count [string string integer])
  (relation global-count [string integer])
  (relation unique-local [string string integer])
  (relation unique-global [string string integer])
  (relation owned [site function string])
  (relation unowned [site string string integer])
  (relation resolved [site function function])
  (relation ambiguous [site function string integer symbol])
  (relation unresolved [site function string])
  (relation edge [function function])
  (relation file-edge [string string])
  (rule (usable-file File) <-- (source-file File _ 0))
  (rule (excluded-file File) <-- (source-file File _ 1))
  (rule (defined File Name Byte) <-- (source-definition [at File Byte _ _ _] Name) (usable-file File))
  (rule (function [fn File Name Byte]) <-- (defined File Name Byte))
  (rule (call-file [at File Start End Row Column] File)
    <-- (source-call [at File Start End Row Column] _ _))
  (rule (call Site Owner Name) <-- (source-call Site Owner Name) (call-file Site File) (usable-file File))
  (rule (local-count File Name N) <-- (defined File Name _) (= N (count (defined File Name _))))
  (rule (global-count Name N) <-- (defined _ Name _) (= N (count (defined _ Name _))))
  (rule (unique-local File Name Byte) <-- (defined File Name Byte) (local-count File Name 1))
  (rule (unique-global File Name Byte) <-- (defined File Name Byte) (global-count Name 1))
  (rule (owned Site [fn File Owner Byte] Name)
    <-- (call Site Owner Name) (call-file Site File) (unique-local File Owner Byte))
  (rule (unowned Site Owner Name 0)
    <-- (call Site Owner Name) (call-file Site File) (not (local-count File Owner _)))
  (rule (unowned Site Owner Name N)
    <-- (call Site Owner Name) (call-file Site File) (local-count File Owner N) (> N 1))
  (rule (resolved Site From [fn File Name Byte])
    <-- (owned Site From Name) (call-file Site File) (unique-local File Name Byte))
  (rule (resolved Site From [fn Target Name Byte])
    <-- (owned Site From Name) (call-file Site File)
        (not (local-count File Name _)) (unique-global Target Name Byte))
  (rule (ambiguous Site From Name N local)
    <-- (owned Site From Name) (call-file Site File) (local-count File Name N) (> N 1))
  (rule (ambiguous Site From Name N global)
    <-- (owned Site From Name) (call-file Site File)
        (not (local-count File Name _)) (global-count Name N) (> N 1))
  (rule (unresolved Site From Name) <-- (owned Site From Name) (not (global-count Name _)))
  (rule (edge From To) <-- (resolved _ From To))
  (rule (file-edge From To) <-- (edge [fn From _ _] [fn To _ _]) (!= From To)))

\\ One root and one direction: no all-pairs transitive closure in a default report.
(defdatalog source-deps.walk
  (type function [fn string string integer])
  (relation edge [function function])
  (relation root [function])
  (relation forward [])
  (relation backward [])
  (relation reached [function])
  (rule (reached To) <-- (forward) (root From) (edge From To))
  (rule (reached To) <-- (forward) (reached From) (edge From To))
  (rule (reached From) <-- (backward) (root To) (edge From To))
  (rule (reached From) <-- (backward) (reached To) (edge From To)))

(define source-deps.select
  _ [] -> [ok []]
  Db [Mode File Name] ->
    (source-deps.selected Mode File Name (datalog.match Db [defined File Name [var "Byte"]])))

(define source-deps.selected
  Mode File Name [[File Name Byte]] -> [ok [Mode [fn File Name Byte]]]
  _ File Name [] -> [error (io.error select File (make-string "no usable definition of ~A" Name))]
  _ File Name _ ->
    [error (io.error select File (make-string "multiple definitions of ~A; query is ambiguous" Name))])

(define source-deps.walk-db
  _ [] -> []
  Db [Mode Root] ->
    (datalog.run source-deps.walk
      [[root Root] [(if (= Mode reach) forward backward)] |
       (map (/. Edge [edge | Edge]) (datalog.tuples Db edge))]))

(define source-deps.analyze
  Data Query ->
    (trap-error
      (let Db (datalog.run source-deps.program (<-address Data 1))
        (io.let-ok Selected (source-deps.select Db Query)
          [ok (io.record [source-deps.analysis Data Db Selected (source-deps.walk-db Db Selected)])]))
      (/. E [error (io.native-error analyze shen 0 "source facts" (error-to-string E))])))

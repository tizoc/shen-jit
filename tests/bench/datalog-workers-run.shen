\\ Entry points for datalog-workers.py. Facts and rules match the existing
\\ Datalog benchmark; all times are elapsed seconds, with no subtraction.
(define dwb.case
  Case ->
    (do (set db.*seed* 2463534242)
      (cond ((= Case "closure-sparse") [db.closure (db.random-edges 3000 2000 [])])
            ((= Case "closure-dense") [db.closure (db.random-edges 1500 300 [])])
            ((= Case "skewed-join") [db.skew (db.skewed 8000 5 3000 [])])
            (true (error "unknown case ~A" Case)))))

(define dwb.counts
  Db Rs -> (map (/. R [(hd R) (datalog.count Db (hd R))]) Rs))

(define dwb.serial-rounds
  0 _ _ _ -> true
  N Name Facts Rs ->
    (let T (get-time unix) Db (datalog.run Name Facts)
         Counts (dwb.counts Db Rs) Elapsed (- (get-time unix) T)
      (do (output "SAMPLE ~A ~S~%" Elapsed Counts)
          (dwb.serial-rounds (- N 1) Name Facts Rs))))

(define dwb.parallel-rounds
  0 _ -> true
  N S ->
    (let T (get-time unix) Counts (datalog.parallel.evaluate S) Elapsed (- (get-time unix) T)
      (do (output "SAMPLE ~A ~S~%" Elapsed Counts)
          (dwb.parallel-rounds (- N 1) S))))

(define dwb.serial
  Case Rounds ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         Rs (datalog.nth 3 (datalog.program Name))
         T (get-time unix) Db (datalog.run Name Facts)
         Counts (dwb.counts Db Rs) First (- (get-time unix) T)
      (do (output "FIRST ~A ~S~%" First Counts)
          (dwb.serial-rounds Rounds Name Facts Rs))))

(define dwb.parallel
  Case Count Image Rounds ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         T (get-time unix)
         _ (datalog.parallel.with-workers Name Facts Count Image
             (/. S (let Counts (datalog.parallel.evaluate S) First (- (get-time unix) T)
                     (do (output "FIRST ~A ~S~%" First Counts)
                         (dwb.parallel-rounds Rounds S)))))
      (output "SCOPE ~A~%" (- (get-time unix) T))))

\\ Public API: each call includes its scope, evaluation, packed collection,
\\ parent index reconstruction and join. The returned database is usable.
(define dwb.public-rounds
  0 _ _ _ _ _ -> true
  N Name Facts Rs Image Count ->
    (let T (get-time unix) Db (datalog.parallel.run Name Facts Image Count)
         Counts (dwb.counts Db Rs) Elapsed (- (get-time unix) T)
      (do (output "SAMPLE ~A ~S~%" Elapsed Counts)
          (dwb.public-rounds (- N 1) Name Facts Rs Image Count))))

(define dwb.public
  Case Count Image Rounds ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         Rs (datalog.nth 3 (datalog.program Name))
         T (get-time unix) Db (datalog.parallel.run Name Facts Image Count)
         Counts (dwb.counts Db Rs) First (- (get-time unix) T)
      (do (output "FIRST ~A ~S~%" First Counts)
          (dwb.public-rounds Rounds Name Facts Rs Image Count))))

(define dwb.public-output
  Case Count Image Dir ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         Db (datalog.parallel.run Name Facts Image Count)
      (sf.results Dir Db (datalog.nth 3 (datalog.program Name)))))

(define dwb.export
  Case Dir ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         P (datalog.program Name) Rs (datalog.nth 3 P) Rules (datalog.nth 4 P)
         _ (sf.program (cn Dir "/program.dl") Rs Rules ".output ~A")
      (sf.facts Dir Rs Facts)))

(define dwb.write-relation
  S Rel Dir ->
    (let Stream (open (cn Dir (cn "/" (cn (sf.name Rel) ".workers"))) out)
         _ (datalog.parallel.fold-tuples S Rel
               (/. Acc Tuples (do (sf.write-all Stream
                    (map (/. T (cn (sf.tsv T) "c#10;")) Tuples)) Acc)) true)
      (close Stream)))

(define dwb.check-output
  Case Image Dir ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
         Rs (datalog.nth 3 (datalog.program Name))
      (datalog.parallel.with-workers Name Facts 4 Image
        (/. S (do (datalog.parallel.evaluate S)
                  (map (/. R (dwb.write-relation S (hd R) Dir)) Rs))))))

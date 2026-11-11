\\ Direct elapsed intervals: initialized workers, repeated fixed-point
\\ evaluation, and optional collection into a normal database. Warm up once.
(define dps.work-once
  Case P Name Facts Scope Print ->
    (let T (get-time unix) Counts (datalog.parallel.evaluate Scope) E (get-time unix)
         Db (datalog.parallel.collect-db Name Facts Scope) End (get-time unix)
         Parent (dwb.counts Db (datalog.nth 3 (datalog.program Name)))
         _ (if (= Parent Counts) true (error "collected counts differ"))
      (if Print (output "WORK ~A ~A ~A ~A ~A~%" Case P (- E T) (- End E) (- End T)) true)))

(define dps.work-rounds
  0 _ _ _ _ _ -> true
  N Case P Name Facts Scope ->
    (do (dps.work-once Case P Name Facts Scope true)
        (dps.work-rounds (- N 1) Case P Name Facts Scope)))

(define dps.materialized-work
  Case P Image Rounds ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
      (datalog.parallel.with-workers Name Facts P Image
        (/. Scope (do (dps.work-once Case P Name Facts Scope false)
                      (dps.work-rounds Rounds Case P Name Facts Scope))))))

(define dps.relation
  "skewed-join" -> two
  _ -> path)

(define dps.patterns
  Rel -> (map (/. X [Rel X [var "Y"]]) [0 1 2 7 31 127 255 511]))

(define dps.normal-answers
  Db Rel -> [(datalog.count Db Rel) |
             (map (/. Q (datalog.sort (datalog.match Db Q))) (dps.patterns Rel))])

(define dps.view-answers
  V Rel -> [(datalog.parallel.count V Rel) |
            (map (/. Q (datalog.sort (datalog.parallel.match V Q))) (dps.patterns Rel))])

(define dps.batch-answers
  V Rel -> [(datalog.parallel.count V Rel) |
            (map (function datalog.sort) (datalog.parallel.match-many V (dps.patterns Rel)))])

(define dps.scoped-answers
  V Rel Mode -> (if (= Mode batch) (dps.batch-answers V Rel) (dps.view-answers V Rel)))

(define dps.cold
  Case P Image Mode ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data)) Rel (dps.relation Case)
         T (get-time unix)
         Answer (if (element? Mode [view batch])
                    (datalog.parallel.with-db Name Facts Image P (/. V (dps.scoped-answers V Rel Mode)))
                    (dps.normal-answers (datalog.parallel.run Name Facts Image P) Rel))
         Elapsed (- (get-time unix) T)
      [Elapsed Answer]))

(define dps.steady-once
  Case P Name Facts Scope V Mode Print ->
    (let T (get-time unix) _ (datalog.parallel.evaluate Scope)
         Answer (if (element? Mode [view batch]) (dps.scoped-answers V (dps.relation Case) Mode)
                    (dps.normal-answers (datalog.parallel.collect-db Name Facts Scope) (dps.relation Case)))
         Elapsed (- (get-time unix) T)
         _ (if (= Answer (value dps.expected)) true (error "steady answers differ"))
         _ (if Print (output "STEADY ~A~%" Elapsed) true)
      Answer))

(define dps.steady-rounds
  0 _ _ _ _ _ _ _ -> true
  N Case P Name Facts Scope V Mode ->
    (do (dps.steady-once Case P Name Facts Scope V Mode true)
        (dps.steady-rounds (- N 1) Case P Name Facts Scope V Mode)))

(define dps.steady
  Case P Image Mode Rounds ->
    (let Data (dwb.case Case) Name (hd Data) Facts (hd (tl Data))
      (if (element? Mode [view batch])
          (datalog.parallel.with-db Name Facts Image P
            (/. V (let S (datalog.parallel.view.source V)
                    (do (dps.steady-once Case P Name Facts S V Mode false)
                        (dps.steady-rounds Rounds Case P Name Facts S V Mode)))))
          (datalog.parallel.with-workers Name Facts P Image
            (/. S (do (dps.steady-once Case P Name Facts S [] Mode false)
                      (dps.steady-rounds Rounds Case P Name Facts S [] Mode)))))))

(define dps.compare
  Case P Image Mode Rounds ->
    (let Expected (hd (tl (dps.cold Case 1 "unused" normal)))
         _ (set dps.expected Expected)
         Result (dps.cold Case P Image Mode)
         _ (if (= Expected (hd (tl Result))) true (error "workflow answers differ"))
         _ (output "COLD ~A~%" (hd Result))
      (dps.steady Case P Image Mode Rounds)))

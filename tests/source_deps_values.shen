(define svt.ok [ok X] -> X X -> (error "value adapter test: ~S" X))
(define svt.run
  [Image Input Output QueryFile Workers] ->
    (let Limits (source-deps.limits)
         Queries (svt.ok (source-deps.read-queries QueryFile))
         Data (svt.ok (io.with-input-file Input
                        (/. In (source-deps.read (io.reader In []) Input Limits))))
         Analysis (svt.ok (source-deps.analyze Data [])) Db (<-address Analysis 2)
         Export (source-deps.export Db)
         Selected (svt.ok (source-deps.resolve-queries Db Export Queries))
         P (source-deps.uint (json.parse Workers []))
         Answers (source-deps.batch-execute-values Export Selected P Image)
         _ (shen-jit.collect)
      (svt.ok (fs.with-replacement Output
                 (/. Out (source-deps.batch-report Analysis Answers Out Limits))))))
(define svt.main
  -> (trap-error (svt.run (value *argv*))
       (/. E (do (set *hush* false) (output "value adapter test: ~A~%" (error-to-string E))
                 (shen-jit.exit 2)))))

(define svt.pure
  -> (let Names (vector 2) _ (address-> Names 1 [fn "a.c" "a" 0])
          _ (address-> Names 2 [fn "a.c" "b" 10])
          _ (if (= (source-deps.values-decode Names [[0 0]] [[0 0 [0 1]]] [])
                   [[reach [fn "a.c" "a" 0] [[fn "a.c" "a" 0] [fn "a.c" "b" 10]]]])
                true (error "value adapter decode differs"))
          Bad [[] [[0 1 []]] [[1 0 []]] [[0 0 [0 0]]] [[0 0 [-1]]]
               [[0 0 [2]]] [[0 0 [1 0]]] [[0 0 [0 | improper]]]
               [[0 0 []] [0 0 []]] [[0 0 not-a-list]]]
          _ (map (/. Reply (if (trap-error
                                 (do (source-deps.values-decode Names [[0 0]] Reply []) false)
                                 (/. E true)) true (error "accepted malformed value reply"))) Bad)
       (do (set *hush* false) (output "11 passed, 0 failed (value reply validation)~%"))))

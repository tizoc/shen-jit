(set process-pure.passed 0)
(set process-pure.failed 0)

(define process-pure.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set process-pure.passed (+ 1 (value process-pure.passed)))
          (do (set process-pure.failed (+ 1 (value process-pure.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define process-pure.raises
  Name F ->
    (process-pure.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(process-pure.check "spawn inherits stdio" [0 0 0]
  (freeze (let C (process.options [] false)
            (map (/. I (<-address (<-address (<-address C 3) I) 0)) [0 1 2]))))
(process-pure.check "run uses three pipes and a group" [2 2 2 true]
  (freeze (let C (process.options [] true)
            (append (map (/. I (<-address (<-address (<-address C 3) I) 0)) [0 1 2])
                    [(<-address C 4)]))))
(process-pure.check "streaming quota does not allocate an output buffer" 1073741824
  (freeze (<-address (process.options [[stdout-limit 1073741824]] true) 8)))
(process-pure.raises "capture has a separate allocation limit"
  (freeze (process.capture-limits (process.options [[stdout-limit 1073741824]] true))))

(map (/. Text (process-pure.raises "bad program rejected"
               (freeze (process.spawn Text [] []))))
  ["" "badc#0;program" 3])
(map (/. Args (process-pure.raises "bad argument list rejected"
               (freeze (process.strings Args 0 8388608))))
  [[3] ["badc#0;arg"] ["good" | bad]])
(map (/. Name (process-pure.raises "bad environment name"
               (freeze (process.env-name Name)))) ["" "A=B" "ac#0;b"])
(process-pure.check "empty argument is retained" true
  (freeze (process.strings ["" "a b" "a'bc#34;d" "c#92;c#92;"] 0 8388608)))
(process-pure.check "empty environment value and unset are accepted" true
  (freeze (process.env-options [["A" ""] ["B" []]])))
(map (/. Options (process-pure.raises "invalid spawn options"
                  (freeze (process.options Options false))))
  [[[unknown 1]] [[cwd ""]] [[group 1]] [[clear-environment []]]
   [[stdin [append "file"]]] [[stdout [file ""]]] [[stderr nope]]
   [[group true] [group false]] [[timeout 1]] [[environment [["A=B" "x"]]]]
   [[cwd "x" "y"]]])
(map (/. Options (process-pure.raises "invalid communication options"
                  (freeze (process.communication-options Options))))
  [[[timeout -1]] [[cleanup-timeout 0]] [[chunk-size 0]] [[chunk-size 65537]]
   [[stdout-limit -1]] [[stderr-limit (+ 0.5 0.5)]] [[cwd "."]] [[group true]]
   [[stdout null]] [[timeout 1] [timeout 2]]])
(map (/. Commands (process-pure.raises "invalid pipeline"
                   (freeze (process.commands Commands 0))))
  [[] [["tool"]] [[3 []]] [["tool" [3]]]])
(output "~A passed, ~A failed~%" (value process-pure.passed) (value process-pure.failed))

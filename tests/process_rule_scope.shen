(define process-test.check-type
  Source Type Expected ->
    (let Actual (shen.typecheck (hd (read-from-string Source)) Type)
      (if (= Actual Expected) true
          (error "~A as ~A expected ~A, got ~A" Source Type Expected Actual))))

(define process-test.check-scope
  HasIO ->
    (do (if (and (element? process.t (included))
                 (= HasIO (element? process.io.t (included))))
            true (error "unexpected process datatypes in ~S" (included)))
        (process-test.check-type "[stdout [file c#34;logc#34;]]" process.option process.option)
        (map (/. Source (process-test.check-type Source process.option (if HasIO process.option false)))
             ["[timeout 100]" "[cleanup-timeout 100]" "[terminate-grace 10]"
              "[stdout-limit 64]" "[stderr-limit 64]" "[chunk-size 16]" "[cancel (freeze false)]"])
        (process-test.check-type "[c#34;programc#34; []]" process.command (if HasIO process.command false))))

(module.use [process])
(process-test.check-scope false)
(module.use [process/io])
(process-test.check-scope true)
(output "2 passed, 0 failed (process rule scope)~%")

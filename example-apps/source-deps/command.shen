(shen.x.namespace source-deps
  (use fs)
  (use io)
  (use json)
  (use shen-jit)
  (use source-deps)
  (shadow read run)
  (externals [*argv* chunk-size impact ok reach])

(define query-option
  [] -> []
  ["--reach" File Name] -> [reach (text File false) (text Name false)]
  ["--impact" File Name] -> [impact (text File false) (text Name false)]
  ["--reach" File Name Byte] ->
    [reach (text File false) (text Name false) (uint (json.parse Byte []))]
  ["--impact" File Name Byte] ->
    [impact (text File false) (text Name false) (uint (json.parse Byte []))]
  _ -> (error "expected --reach FILE NAME [BYTE] or --impact FILE NAME [BYTE]"))

(define run
  Input Output Query Limits ->
    (io.let-ok Data (io.with-input-file Input
                     (/. In (read (io.reader In [[chunk-size 16384]]) Input Limits)))
      (io.let-ok Analysis (source-deps.analyze Data Query)
        (fs.with-replacement Output (/. Out (source-deps.report Analysis Out Limits))))))

(define finish
  [ok N] -> (output "Wrote ~A dependency records~%" N)
  [error Error] ->
    (error "~A: ~A" (io.error-resource Error) (io.error-message Error)))

(define main
  [_ Input Output "--batch" Queries | Options] ->
    (finish (batch-run Input Output Queries Options (limits)))
  [_ Input Output | Options] ->
    (finish
      (run Input Output (query-option Options) (limits)))
  _ -> (error "usage: source-deps FACTS OUTPUT [--reach FILE NAME [BYTE] | --impact FILE NAME [BYTE] | --batch QUERIES [--workers COUNT (0..64)]]"))

(define entry
  -> (trap-error (main (value *argv*))
       (/. E (do (output "source-deps: ~A~%" (error-to-string E)) (shen-jit.exit 2)))))

)

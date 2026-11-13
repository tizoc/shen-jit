(define source-deps.query-option
  [] -> []
  ["--reach" File Name] -> [reach (source-deps.text File false) (source-deps.text Name false)]
  ["--impact" File Name] -> [impact (source-deps.text File false) (source-deps.text Name false)]
  ["--reach" File Name Byte] ->
    [reach (source-deps.text File false) (source-deps.text Name false) (source-deps.uint (json.parse Byte []))]
  ["--impact" File Name Byte] ->
    [impact (source-deps.text File false) (source-deps.text Name false) (source-deps.uint (json.parse Byte []))]
  _ -> (error "expected --reach FILE NAME [BYTE] or --impact FILE NAME [BYTE]"))

(define source-deps.run
  Input Output Query Limits ->
    (io.let-ok Data (io.with-input-file Input
                     (/. In (source-deps.read (io.reader In [[chunk-size 16384]]) Input Limits)))
      (io.let-ok Analysis (source-deps.analyze Data Query)
        (fs.with-replacement Output (/. Out (source-deps.report Analysis Out Limits))))))

(define source-deps.finish
  [ok N] -> (output "Wrote ~A dependency records~%" N)
  [error Error] ->
    (error "~A: ~A" (io.error-resource Error) (io.error-message Error)))

(define source-deps.main
  [_ Input Output "--batch" Queries | Options] ->
    (source-deps.finish (source-deps.batch-run Input Output Queries Options (source-deps.limits)))
  [_ Input Output | Options] ->
    (source-deps.finish
      (source-deps.run Input Output (source-deps.query-option Options) (source-deps.limits)))
  _ -> (error "usage: source-deps FACTS OUTPUT [--reach FILE NAME [BYTE] | --impact FILE NAME [BYTE] | --batch QUERIES [--workers COUNT (0..64)]]"))

(define source-deps.entry
  -> (trap-error (source-deps.main (value *argv*))
       (/. E (do (output "source-deps: ~A~%" (error-to-string E)) (shen-jit.exit 2)))))

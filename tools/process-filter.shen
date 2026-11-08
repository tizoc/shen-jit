\\ Stream a binary file through an external program, publishing output only after exit status 0.
(let Quiet (hush?)
     _ (hush +)
     _ (map (function load)
         ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen"
          "lib/deadline.shen" "lib/clock.shen" "lib/fs.shen"
          "lib/process.shen" "lib/process-io.shen"])
  (set *hush* Quiet))

(define process-filter.accept
  _ [ok Report] -> [ok (process.output-count Report)] where (process.success? Report)
  Program [ok Report] ->
    [error (io.native-error run child (hd (tl (process.status Report))) Program
             (make-string "child finished with ~A" (process.status Report)))]
  _ [error Error] -> [error Error]
  _ [error Error _] -> [error Error])

(define process-filter.run
  From To Program Args ->
    (fs.with-replacement To
      (/. Output
        (io.with-input-file From
          (/. Input
            (io.with-endpoint (io.output-buffer (buffer.new 65536))
              (/. Errors
                (process-filter.accept Program
                  (process.run-to Program Args Input Output Errors
                    [[stdout-limit 1073741824] [stderr-limit 65536] [timeout 60000]])))))))))

(define process-filter.finished
  [ok N] -> (output "Filtered ~A bytes~%" N)
  [error Error] ->
    (error "filter: ~A (~A; ~A bytes acknowledged)"
      (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define process-filter.main
  [_ From To Program | Args] -> (process-filter.finished (process-filter.run From To Program Args))
  _ -> (error "usage: shen-jit script tools/process-filter.shen INPUT OUTPUT PROGRAM [ARG ...]"))

(process-filter.main (value *argv*))

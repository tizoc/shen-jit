\\ Stream a binary file through an external program, publishing output only after exit status 0.

(shen.x.namespace process-filter
  (import process exited signalled)
  (import result ok err)
  (use buffer)
  (use fs)
  (use io)
  (use process)
  (use process-filter)
  (externals [*argv* child stderr-limit
    stdout-limit timeout])

(define child-error
  Program (:exited Code) -> (io.native-error run child Code Program (make-string "child exited with code ~A" Code))
  Program (:signalled N) -> (io.native-error run child N Program (make-string "child terminated by signal ~A" N)))

(define accept
  _ (:ok Report) -> (:ok (process.output-count Report)) where (process.success? Report)
  Program (:ok Report) -> (:err (child-error Program (process.status Report)))
  _ (:err (@p Error _)) -> (:err Error))

(define process-filter.run
  From To Program Args ->
    (fs.with-replacement To
      (/. Output
        (io.with-input-file From
          (/. Input
            (io.with-endpoint (io.output-buffer (buffer.new 65536))
              (/. Errors
                (accept Program
                  (process.run-to Program Args Input Output Errors
                    [[stdout-limit 1073741824] [stderr-limit 65536] [timeout 60000]])))))))))

(define finished
  (:ok N) -> (output "Filtered ~A bytes~%" N)
  (:err Error) ->
    (error "filter: ~A (~A; ~A bytes acknowledged)"
      (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define main
  [_ From To Program | Args] -> (finished (process-filter.run From To Program Args))
  _ -> (error "usage: shen-jit script tools/process-filter.shenmod INPUT OUTPUT PROGRAM [ARG ...]"))

(main (value *argv*))

)

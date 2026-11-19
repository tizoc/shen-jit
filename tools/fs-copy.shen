\\ Copy through bounded I/O and replace only after writing and closing succeed. Build with make fs.

(shen.x.namespace fs-copy
  (import result ok err)
  (use fs)
  (use io)
  (externals [*argv*])

(define finished
  (:ok N) -> (output "Copied ~A bytes~%" N)
  (:err Error) ->
    (error "copy: ~A (~A; ~A bytes processed)"
      (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define main
  [_ From To] -> (finished (fs.copy-file From To 1073741824))
  _ -> (error "usage: shen-jit script tools/fs-copy.shenmod SOURCE DESTINATION"))

(main (value *argv*))

)

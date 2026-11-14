\\ Copy through bounded I/O and replace only after writing and closing succeed. Build with make fs.

(shen.x.namespace fs-copy
  (use fs)
  (use io)
  (externals [*argv* ok])

(let Quiet (hush?)
     _ (hush +)
     _ (map (function load)
         ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/fs.shen"])
  (set *hush* Quiet))

(define finished
  [ok N] -> (output "Copied ~A bytes~%" N)
  [error Error] ->
    (error "copy: ~A (~A; ~A bytes processed)"
      (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define main
  [_ From To] -> (finished (fs.copy-file From To 1073741824))
  _ -> (error "usage: shen-jit script tools/fs-copy.shen SOURCE DESTINATION"))

(main (value *argv*))

)

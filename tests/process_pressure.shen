\\ Hold the first output callback while the child fills its bounded OS pipe.
(define process-pressure.write
  State Marker Bytes ->
    (let _ (if (= (<-address State 0) 0)
               (do (process.c-pause [] 100)
                   (let Read (io.read-file Marker 32)
                        N (hd (read-from-string (buffer.string (hd (tl Read)))))
                     (if (and (> N 0) (< N 2097152))
                         (address-> State 1 N)
                         (error "producer ran ahead of blocked sink")))) true)
         N (shen-jit.bytes-length Bytes)
         _ (address-> State 0 (+ (<-address State 0) N))
      [written N]))

(let State (io.record [0 0])
     Source (io.input-buffer (buffer.new 0))
     Marker (cn (value process-test.root) "/producer-count")
     Sink (io.endpoint "held sink" write 16384 (function io.no-read)
            (/. B (process-pressure.write State Marker B)) (freeze [ok]))
     Err (io.output-buffer (buffer.new 0))
     Result (process.run-to (value process-test.helper) ["progress" "8388608" Marker] Source Sink Err
                [[stdout-limit 8388608] [timeout 30000]])
     _ (io.close Source)
     _ (io.close Sink)
     _ (io.close Err)
  (if (and (= (hd Result) ok) (= (<-address State 0) 8388608))
      (output "process pressure ok ~A~%" (<-address State 1))
      (error "held process stream failed")))

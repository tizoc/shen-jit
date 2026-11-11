(if (and (= (shen-jit.bytes-length (value worker-test.closed-view)) 0)
         (trap-error (do (shen-jit.u32 (value worker-test.closed-view) 0) false) (/. E true)))
    (output "closed worker view image passed~%")
    (error "closed worker view survived an image as live storage"))

(define hello-main
  -> (do (output "hello ~S ~A~%" (tl (value *argv*)) (mod-b 2))
         (output "redefined: ~A~%" (trap-error (do (eval (head (read-from-string "(define mod-b X -> X)"))) yes)
                                               (/. E (error-to-string E))))))

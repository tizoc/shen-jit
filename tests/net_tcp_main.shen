(define tcp-test.main
  -> (let Mode (hd (tl (value *argv*)))
          OK (cases (= Mode "wire") (tcp-test.checks 128)
                    (= Mode "0") (tcp-test.verify 0 false)
                    (= Mode "1") (tcp-test.verify 1000 false)
                    (= Mode "2") (tcp-test.verify 16 true)
                    true (error "unknown TCP test mode ~S" Mode))
       (if OK (output "TCP checks passed~%") (error "TCP check failed"))))

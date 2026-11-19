(define udp-test.main
  -> (let Mode (hd (tl (value *argv*)))
          OK (cases (= Mode "wire") (udp-test.run)
                    (= Mode "0") (udp-alloc.run 0 false)
                    (= Mode "1") (udp-alloc.run 10000 false)
                    (= Mode "2") (udp-alloc.run 16 true)
                    true (error "unknown UDP test mode ~S" Mode))
       (if OK (output "UDP checks passed~%") (error "UDP check failed"))))

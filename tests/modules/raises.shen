(set mod-attempts (+ 1 (trap-error (value mod-attempts) (/. E 0))))
(simple-error "source failed")

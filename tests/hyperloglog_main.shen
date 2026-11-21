(define hll-test.entry
  -> (let Args (tl (value *argv*))
       (hll-test.command (if (empty? Args) "check" (hd Args)))))

\\ Compile into the test image before collection-on-every-allocation is enabled.
(define fs-gc.check
  Expected Result ->
    (if (= Result Expected) true (error "filesystem ownership changed under collection")))

(define fs-gc.run
  Root ->
    (let Names (fs.list (fs.join Root "listing") [])
         Info (fs.stat (fs.join Root "data"))
         Temp (fs.with-temp-file Root "gc-" (/. P E [ok P]))
         _ (shen-jit.collect)
         _ (fs-gc.check [ok ["a" "b"]] Names)
         _ (fs-gc.check 6 (fs.size (hd (tl Info))))
         _ (fs-gc.check [ok false] (fs.exists? (hd (tl Temp))))
         _ (fs-gc.check [ok 2] (fs.write-replace (fs.join Root "gc-output")
                                (buffer.from-string "gc")))
      true))

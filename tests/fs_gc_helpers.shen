\\ Compile into the test image before collection-on-every-allocation is enabled.
(define fs-gc.check
  Expected Result ->
    (if (= Result Expected) true (error "filesystem ownership changed under collection")))

(define fs-gc.run
  Root ->
    (let Names (fs.list (fs.join Root "listing") [])
         Info (fs.stat (fs.join Root "data"))
         Temp (fs.with-temp-file Root "gc-" (/. P E (:result.ok P)))
         _ (shen-jit.collect)
         _ (fs-gc.check (:result.ok ["a" "b"]) Names)
         _ (fs-gc.check 6 (fs.size (fixture.success Info)))
         _ (fs-gc.check (:result.ok false) (fs.exists? (fixture.success Temp)))
         _ (fs-gc.check (:result.ok 2) (fs.write-replace (fs.join Root "gc-output")
                                (buffer.from-string "gc")))
      true))

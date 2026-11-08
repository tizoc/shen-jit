(shen-jit.library ts-gc.wait ["libc.so.6" "libSystem.dylib" "kernel32.dll"])
(define-foreign ts-gc.poll ts-gc.wait "poll" (pointer int64 int32) --> int32 blocking)
(define-foreign ts-gc.sleep ts-gc.wait "Sleep" (int32) --> void blocking)

(define ts-gc.pause
  -> (if (= (value *os*) "Windows") (ts-gc.sleep 10) (ts-gc.poll [] 0 10)))

(define ts-gc.worker
  Done 0 -> (address-> Done 0 true)
  Done N -> (do (shen-jit.collect) (ts-gc.pause) (ts-gc.worker Done (- N 1))))

(define ts-gc.join
  Done N -> true where (<-address Done 0)
  _ 0 -> (error "Tree-sitter GC worker did not finish")
  Done N -> (do (ts-gc.pause) (ts-gc.join Done (- N 1))))

(define ts-gc.padding
  0 Text -> Text
  N Text -> (ts-gc.padding (- N 1) (cn Text Text)))

(define ts-gc.run
  Language ->
    (let Input (buffer.from-string
                 (cn "/*" (cn (ts-gc.padding 18 " ") "*/ int kept(void) { return callee(); }")))
         Done (address-> (absvector 1) 0 false)
         _ (thread (freeze (ts-gc.worker Done 10)))
         Result (treesitter.query Language Input "(identifier) @name" [])
         T (ts-test.ok Result)
         _ (shen-jit.collect)
         _ (if (and (= (treesitter.capture-count T) 2)
                    (= (treesitter.text T (treesitter.capture-node T 1)) "kept"))
               true (error "Tree-sitter snapshot changed under collection"))
         _ (ts-gc.join Done 1000)
      true))

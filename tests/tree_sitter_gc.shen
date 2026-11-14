(define ts-gc.run
  Language ->
    (let Input (buffer.from-string "int kept(void) { return callee(); }")
         Result (treesitter.query Language Input "(identifier) @name" [])
         T (ts-test.ok Result)
         _ (shen-jit.collect)
         _ (if (and (= (treesitter.capture-count T) 2)
                    (= (treesitter.text T (treesitter.capture-node T 1)) "kept"))
               true (error "Tree-sitter snapshot changed under collection"))
      true))

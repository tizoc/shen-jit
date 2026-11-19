\\ Run from an image with the libraries already loaded, collecting at every allocation.
(let B (buffer.from-string "abcdef") V (buffer.slice B 1 3) C (cursor.new V)
     _ (shen-jit.collect) Before (cursor.peek C) Owned (cursor.bytes C 3)
     _ (buffer.u8-> B 1 88) _ (shen-jit.collect)
  (if (and (= Before 98) (= (buffer.string V) "Xcd")
           (= (buffer.string (buffer.wrap Owned)) "bcd")
           (= (cursor.position C) 3) (= (cursor.read C) -1))
      (output "gc ok~%")
      (error "buffer ownership failed under GC stress")))

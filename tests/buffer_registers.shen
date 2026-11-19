\\ Run sealed under (optimise +): a typed loop over a view reads its bytes in registers, as the
\\ buffer's checks and accessors are typed (lib/buffer-typed.shen) and inline into it, and they
\\ still check the view and the index as before.
(set buffer-registers.passed 0)
(set buffer-registers.failed 0)

(define buffer-registers.check
  Name Expected Actual
  -> (if (= Expected Actual)
         (set buffer-registers.passed (+ 1 (value buffer-registers.passed)))
         (do (set buffer-registers.failed (+ 1 (value buffer-registers.failed)))
             (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual))))

(define buffer-registers.instructions
  F -> (let Code (hd (tl (tl (shen-jit.code F)))) (hd (tl (tl (tl (tl (tl Code))))))))

(define buffer-registers.has?
  _ [] -> false
  Op [[Op | _] | _] -> true
  Op [_ | Is] -> (buffer-registers.has? Op Is))

(define buffer-registers.calls?
  _ [] -> false
  F [[call-sealed _ _ F | _] | _] -> true
  F [_ | Is] -> (buffer-registers.calls? F Is))

(define buffer-registers.error
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))

(tc +)
(load "tests/buffer_loop.shen")
(tc -)

(let Is (buffer-registers.instructions buffer-loop.sum)
  (buffer-registers.check "a byte read in registers, with nothing called" [true false false]
    [(buffer-registers.has? word-load8 Is) (buffer-registers.calls? buffer.u8 Is)
     (buffer-registers.calls? buffer.check Is)]))
(let V (buffer.from-string "abc")
  (do (buffer-registers.check "the sum" 294 (buffer-loop.sum V 0 (buffer.length V) 0))
      (buffer-registers.check "past the end" "buffer: range 3 + 1 exceeds 3 bytes"
        (buffer-registers.error (freeze (buffer-loop.sum V 0 4 0))))
      (buffer-registers.check "a slice" 197 (let S (buffer.slice V 1 2) (buffer-loop.sum S 0 2 0)))
      (buffer-registers.check "a negative index" "buffer: -1 is not a nonnegative index"
        (buffer-registers.error (freeze (buffer.u8 V -1))))))

(output "~A passed, ~A failed~%" (value buffer-registers.passed) (value buffer-registers.failed))

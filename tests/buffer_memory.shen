\\ Foreign owners, read-only storage and handles. The managed tests run separately on static builds.
(if (trap-error (do (memory.free (memory.alloc 1)) false)
                (/. E (= (error-to-string E) "foreign: this static build cannot load libraries")))
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(set buffer-memory.*passed* 0)
(set buffer-memory.*failed* 0)
(define buffer-memory.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. E [error (error-to-string E)]))
      (if (= Expected Got)
          (set buffer-memory.*passed* (+ 1 (value buffer-memory.*passed*)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set buffer-memory.*failed* (+ 1 (value buffer-memory.*failed*)))))))
(define buffer-memory.raises
  Name F -> (buffer-memory.check Name true
              (freeze (trap-error (do (thaw F) false) (/. E true)))))

(let M (memory.alloc 8) V (buffer.wrap M) S (buffer.slice V 2 3) C (cursor.new S)
  (do (buffer.u8-> S 0 7)
      (buffer.u16-be-> S 1 4660)
      (buffer-memory.check "same owner object" true (freeze (shen-jit.same? M (buffer.owner S))))
      (shen-jit.collect)
      (buffer-memory.check "foreign read after collection" 7 (freeze (cursor.read C)))
      (buffer-memory.check "foreign big-endian read after collection" 4660 (freeze (buffer.u16-be S 1)))
      (let Saved (buffer.bytes S)
        (do (memory.free M)
            (buffer-memory.check "owned capture after close" 7 (freeze (shen-jit.u8 Saved 0)))))
      (buffer-memory.raises "view after close" (freeze (buffer.u8 S 0)))
      (buffer-memory.raises "empty slice after close" (freeze (buffer.slice S 0 0)))
      (buffer-memory.raises "cursor after close" (freeze (cursor.peek C)))
      (buffer-memory.raises "wrap closed pointer" (freeze (buffer.wrap M)))))

(let M (memory.alloc 4) _ (shen-jit.u8! M 0 9)
     ReadOnly (shen-jit.pointer-read-only M) V (buffer.wrap ReadOnly)
  (do (buffer-memory.check "read-only read" 9 (freeze (buffer.u8 V 0)))
      (buffer-memory.raises "read-only store" (freeze (buffer.u8-> V 0 8)))
      (buffer-memory.raises "read-only u16-be store" (freeze (buffer.u16-be-> V 0 0)))
      (buffer-memory.raises "read-only u32-be store" (freeze (buffer.u32-be-> V 0 0)))
      (buffer-memory.check "read-only u32-be read" 150994944 (freeze (buffer.u32-be V 0)))
      (buffer-memory.raises "read-only copy destination" (freeze (buffer.copy-into! V 0 (buffer.new 4) 0 4)))
      (buffer-memory.check "read-only source copy" 9 (freeze (shen-jit.u8 (buffer.bytes V) 0)))
      \\ This explicit independent pointer copy must be killed before its original allocation is freed.
      (shen-jit.pointer-kill ReadOnly)
      (memory.free M)))

(let H (handle.wrap (memory.alloc 4) (/. M (memory.free M))) V (buffer.wrap H)
  (do (buffer.u8-> V 1 42)
      (buffer-memory.check "handle-backed view" 42 (freeze (buffer.u8 V 1)))
      (handle.close H)
      (buffer-memory.raises "handle close invalidates view" (freeze (buffer.string V)))))

\\ A release can free storage and then raise. Its shared handle must already be dead.
(let H (handle.wrap (memory.alloc 4) (/. M (do (memory.free M) (error "release failed"))))
     V (buffer.wrap H)
  (do (buffer-memory.raises "release failure propagates" (freeze (handle.close H)))
      (buffer-memory.check "release failure still kills owner" 0 (freeze (shen-jit.pointer-address H)))
      (buffer-memory.raises "faulted close invalidates view"
        (freeze (if (= (shen-jit.pointer-address H) 0) (buffer.u8 V 0) no-error)))
      (buffer-memory.check "faulted close is not repeated" false (freeze (handle.close H)))))

(output "~A passed, ~A failed~%" (value buffer-memory.*passed*) (value buffer-memory.*failed*))

(define pc.emit
  _ End End -> (output "~%")
  B At End -> (do (output "~A " (shen-jit.u8 B At)) (pc.emit B (+ At 1) End)))
(define pc.roundtrip
  Text -> (let Input (buffer.from-string Text)
               Value (parallel.decode Input) Out (parallel.encode Value 1048576)
               Bytes (parallel.bytes Out) _ (set *hush* false)
            (do (output "CODEC|") (pc.emit Bytes 0 (shen-jit.bytes-length Bytes)))))

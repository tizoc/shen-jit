(define pt.worker
  Request ->
    (let Op (shen-jit.u8 Request 0)
      (cond ((= Op 1) (let Out (buffer.new 8)
                            _ (shen-jit.u32! (buffer.owner Out) 0 (parallel.index))
                            _ (shen-jit.u32! (buffer.owner Out) 4 (parallel.shared-u32 (parallel.shared) 0))
                         (parallel.reply Out)))
            ((= Op 2) (error "parallel fixture failure"))
            ((= Op 3) (do (shen-jit.u8! (parallel.shared) 0 0) []))
            ((= Op 4) [[(parallel.shared) 0 4]])
            (true (parallel.reply (buffer.wrap Request))))))

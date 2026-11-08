(define ts-test.flags
  T ID ->
    (+ (if (treesitter.named? T ID) 1 0)
       (+ (if (treesitter.missing? T ID) 2 0)
          (+ (if (treesitter.error? T ID) 4 0)
             (+ (if (treesitter.has-error? T ID) 8 0) (if (treesitter.extra? T ID) 16 0))))))

(define ts-test.dump-node
  T ID ->
    (let Start (treesitter.start-point T ID)
         End (treesitter.end-point T ID)
      (output "Nc#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~Ac#9;~A~%"
        ID (treesitter.parent T ID) (treesitter.kind T ID) (treesitter.field T ID) (ts-test.flags T ID)
        (treesitter.start-byte T ID) (treesitter.end-byte T ID)
        (hd Start) (hd (tl Start)) (hd End) (hd (tl End)))))

(define ts-test.dump-captures
  T ID End -> true where (> ID End)
  T ID End ->
    (do (output "Cc#9;~Ac#9;~Ac#9;~Ac#9;~A~%" (treesitter.capture-match T ID)
          (treesitter.capture-pattern T ID) (treesitter.capture-name T ID) (treesitter.capture-node T ID))
        (ts-test.dump-captures T (+ ID 1) End)))

(define ts-test.dump
  T ->
    (do (treesitter.fold (/. Acc ID (do (ts-test.dump-node T ID) true)) true T)
        (ts-test.dump-captures T 1 (treesitter.capture-count T))))

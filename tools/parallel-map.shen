\\ Load buffer.shen, parallel.shen and parallel-map.shen before this example.
\\ Save it with parallel-demo.main as the entry. The executable is its worker image.
(define parallel-demo.sum
  _ 0 Total -> Total
  Start Left Total -> (parallel-demo.sum (+ Start 1) (- Left 1) (+ Total Start)))

(define parallel-demo.job
  [Label Start Count] ->
    (if (and (string? Label) (integer? Start) (integer? Count) (>= Count 0) (<= Count 10000000))
        [Label (parallel-demo.sum Start Count 0)]
        (error "expected a label, integer start and count 0..10000000")))

(define parallel-demo.jobs
  -> [["first" 0 1000000] ["second" 1000000 1000000]
      ["third" 2000000 1000000] ["fourth" 3000000 1000000]])

(define parallel-demo.count
  Text -> (let Read (read-from-string Text)
            (if (and (cons? Read) (empty? (tl Read)))
                (parallel.check-count (hd Read))
                (error "expected one integer worker count from 1 to 64"))))

(define parallel-demo.run
  [_ "--sequential"] -> (map (function parallel-demo.job) (parallel-demo.jobs))
  [Image "--workers" Count] ->
    (parallel.with-map Image (intern "parallel-demo.job") (parallel-demo.count Count)
      (parallel.config 16777216 67108864 (buffer.new 0))
      (/. Scope (parallel.map Scope (parallel-demo.jobs))))
  _ -> (error "usage: parallel-map-demo --sequential | --workers COUNT (1..64)"))

(define parallel-demo.main
  -> (trap-error (do (set *hush* false) (output "~S~%" (parallel-demo.run (value *argv*))))
       (/. E (do (set *hush* false) (output "parallel-map: ~A~%" (error-to-string E)) (shen-jit.exit 2)))))

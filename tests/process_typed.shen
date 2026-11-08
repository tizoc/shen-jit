(define process-typed.ok?
  {(process.result process.report) --> boolean}
  [ok Report] -> (and (process.success? Report)
                     (>= (process.input-count Report) 0)
                     (>= (process.input-read-count Report) 0)
                     (= (buffer.length (process.pending-input Report)) 0)
                     (= (process.status Report) [exited 0]))
  [error _] -> false
  [error _ _] -> false)

(define process-typed.pipeline?
  {(process.result (list process.report)) --> boolean}
  [ok Reports] -> (= (length Reports) 2)
  [error _] -> false
  [error _ _] -> false)

(define process-typed.child?
  {(io.result process.child) --> boolean}
  [ok Child] ->
    (let PID (process.pid Child)
         Status (process.wait Child 1000)
         Closed (process.close Child)
      (and (> PID 0) (= Status [ok [exited 0]]) (= Closed [ok])))
  [error _] -> false)

(define process-typed.run
  {string --> boolean}
  Program ->
    (let Captured (process.run Program ["echo"] (buffer.from-string "typed")
                     [[timeout 2000] [environment [["TYPED" "yes"]]]])
         Source (io.input-buffer (buffer.from-string "typed"))
         Out (io.output-buffer (buffer.new 5))
         Err (io.output-buffer (buffer.new 0))
         Streamed (process.run-to Program ["echo"] Source Out Err [[stdout-limit 1073741824]])
         _ (io.close Source)
         _ (io.close Out)
         _ (io.close Err)
         Pipeline (process.pipeline [[Program ["echo"]] [Program ["echo"]]] (buffer.new 0) [])
         Child (process.spawn Program ["exit" "0"] [[stdin null] [stdout null] [stderr null]])
      (and (process-typed.ok? Captured) (process-typed.ok? Streamed)
           (process-typed.pipeline? Pipeline) (process-typed.child? Child))))

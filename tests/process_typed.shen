(shen.x.namespace process-typed
  (import process running exited signalled)
  (use process)
  (export exited-zero?)

  (define exited-zero?
    {process.status --> boolean}
    (:exited Code) -> (= Code 0)
    (:signalled _) -> false
    (:running) -> false))

(define process-typed.ok?
  {(process.result process.report) --> boolean}
  (:result.ok Report) -> (and (process.success? Report)
                     (fx>= (process.input-count Report) 0)
                     (fx>= (process.input-read-count Report) 0)
                     (= (buffer.length (process.pending-input Report)) 0)
                     (process-typed.exited-zero? (process.status Report)))
  (:result.err _) -> false)

(define process-typed.pipeline?
  {(process.result (list process.report)) --> boolean}
  (:result.ok Reports) -> (= (length Reports) 2)
  (:result.err (@p _ Started)) -> false)

(define process-typed.child?
  {(io.result process.child) --> boolean}
  (:result.ok Child) ->
    (let PID (process.pid Child)
         Status (process.wait Child 1000)
         Closed (process.close Child)
      (and (> PID 0) (= Status (:result.ok [(:process.exited 0)])) (= Closed (:result.ok []))))
  (:result.err _) -> false)

\\ A process result is a result.t, so its chain gives a value of another type.
(define process-typed.echoed
  {string --> (process.result string)}
  Program -> (result.let-ok Report (process.run Program ["echo"] (buffer.from-string "typed") [[timeout 2000]])
               (:result.ok (buffer.string (process.output-bytes Report)))))

(define process-typed.redirect-path
  {process.stream --> string}
  [file Path] -> Path
  [append Path] -> Path
  _ -> "")

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
           (process-typed.pipeline? Pipeline) (process-typed.child? Child)
           (= (process-typed.echoed Program) (:result.ok "typed"))
           (= (process-typed.redirect-path [file "input"]) "input")
           (= (process-typed.redirect-path [append "output"]) "output"))))

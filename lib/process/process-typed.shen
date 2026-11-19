(shen.x.namespace process
  (use buffer)
  (use clock)
  (use deadline)
  (use io)
  (use option)
  (use result)
  (use shen-jit)
  (import result ok err let-ok)
  (externals [deadline])
  (shadow limit)
  (export pid process.stdin => stdin process.stdout => stdout process.stderr => stderr process.wait => wait)

(define limit
  {number --> fixnum --> boolean --> fixnum}
  Value Maximum Positive ->
    (let N (buffer.index (fixnum Value))
      (if (and (fx<= N Maximum) (or (not Positive) (fx> N 0)))
          N
          (error "process: option is outside its supported range"))))

(define check
  {child --> child}
  Child -> (if (child? Child) Child (error "process: not a child handle")))

(define live
  {child --> buffer.storage}
  Child ->
    (let _ (check Child)
         Token (native-token (child.raw Child))
      (if (or (child.closed Child) (= (shen-jit.pointer-address Token) 0))
          (error "process: child is closed or stale")
          Token)))

(define pid
  {child --> number}
  Child -> (native-pid (child.raw (check Child))))

(define required-pipe
  {(option.t io.endpoint) --> io.endpoint}
  [E] -> E
  [] -> (error "process: standard stream was not piped"))

(define process.stdin
  {child --> io.endpoint}
  Child -> (do (live Child) (required-pipe (child.input Child))))

(define process.stdout
  {child --> io.endpoint}
  Child -> (do (live Child) (required-pipe (child.output Child))))

(define process.stderr
  {child --> io.endpoint}
  Child -> (do (live Child) (required-pipe (child.diagnostics Child))))

(define wait-loop
  {child --> deadline --> (io.result (option.t status))}
  Child Budget ->
    (let-ok Status (poll Child)
      (cases (not (running? Status)) (ok (option.some Status))
             (deadline.expired? Budget) (ok (option.none))
             true (do (c-pause [] (deadline.slice Budget 20))
                      (wait-loop Child Budget)))))

(define process.wait
  {child --> number --> (io.result (option.t status))}
  Child Milliseconds ->
    (do (live Child)
        (limit Milliseconds 2147483647 false)
        (wait-loop Child (clock.deadline Milliseconds))))

(define close-pipes
  {(list (option.t io.endpoint)) --> (io.result result.empty) --> (io.result result.empty)}
  [] Result -> Result
  [Pipe | Rest] Result -> (close-pipes Rest (io.finish Result (close-child-pipe Pipe))))

(define close-child-pipe
  {(option.t io.endpoint) --> (io.result result.empty)}
  [] -> (ok [])
  [E] -> (io.close E))

)

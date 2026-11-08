\\ Dedicated application state keeps the image's every-allocation checks bounded.
(define source-image.ok
  [ok X] -> X
  X -> (error "source-deps image: ~S" X))

(set source-image.data
  (source-image.ok
    (io.with-endpoint (io.input-buffer (buffer.from-string (value source-image.text)))
      (/. Endpoint (source-deps.read (io.reader Endpoint [[chunk-size 17]])
                     "image fixture" (source-deps.limits))))))
(set source-image.text "")

(define source-image.walk
  Walk -> (datalog.add Walk [[edge [fn "b.c" "leaf" 0] [fn "b.c" "after" 20]]]))

(define source-image.extend
  A -> (let Db (datalog.add (<-address A 2)
                 [[source-call [at "a.c" 140 144 0 140] "main" 0 "leaf"]])
            Walk (source-image.walk (<-address A 4))
         [Db Walk]))

\\ Warm the update plans before saving, so reloading exercises the saved native rules.
(source-image.extend
  (source-image.ok (source-deps.analyze (value source-image.data) [reach "a.c" "main"])))
(set source-image.analysis
  (source-image.ok (source-deps.analyze (value source-image.data) [reach "a.c" "main"])))

\\ Normal reload updates both models; every-allocation stress updates the small recursive walker.
(define source-image.check
  Full ->
    (let A (value source-image.analysis)
         Db (<-address A 2)
         Walk (<-address A 4)
         _ (shen-jit.collect)
         _ (if (and (= (<-address (value source-image.data) 2) 8)
                    (= (datalog.count Db edge) 3)
                    (= (datalog.count Walk reached) 3)
                    (datalog.holds? Db [edge [fn "a.c" "helper" 10] [fn "b.c" "leaf" 0]]))
               true (error "source-deps saved facts/model changed"))
         Updated (if Full (source-image.extend A) [Db (source-image.walk Walk)])
         Db (hd Updated)
         Walk (hd (tl Updated))
         _ (shen-jit.collect)
      (if (and (= (datalog.count Db edge) (if Full 4 3))
               (or (not Full) (datalog.holds? Db [edge [fn "a.c" "main" 0] [fn "b.c" "leaf" 0]]))
               (= (datalog.count Walk reached) 4)
               (datalog.holds? Walk [reached [fn "b.c" "after" 20]]))
          (output "source-deps image gc ok~%")
          (error "source-deps saved native rules changed"))))

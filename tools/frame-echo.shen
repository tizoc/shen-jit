\\ One connected client, bounded frames, one flushed reply per frame.
\\ tools/frame-echo.shenmod loads what it needs.

(shen.x.namespace frame-echo
  (import frame frame)
  (import result ok err)
  (use frame)
  (use io)
  (externals [frame.limit])

(define serve
  E Limit ->
    (let Max (frame.limit Limit)
      (io.with-endpoint E
        (/. Connection
          (let F (frame.reader (io.reader Connection []) Max)
               W (io.writer Connection [])
            (loop F W Max 0))))))

(define loop
  F W Limit Count -> (next F W Limit Count (frame.next F)))

(define next
  _ _ _ Count (:ok []) -> (:ok Count)
  _ _ _ _ (:err Error) -> (:err Error)
  F W Limit Count (:ok [(:frame Tag Payload)]) ->
    (written F W Limit Count (io.write W (frame.encode Tag Payload Limit))))

(define written
  _ _ _ _ (:err Error) -> (:err Error)
  F W Limit Count (:ok _) -> (flushed F W Limit Count (io.flush W)))

(define flushed
  _ _ _ _ (:err Error) -> (:err Error)
  F W Limit Count (:ok _) -> (loop F W Limit (+ Count 1)))

)

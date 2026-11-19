\\ Bounded streaming download. Build the optional adapter with make curl first.

(shen.x.namespace curl-fetch
  (import result ok err)
  (use buffer)
  (use curl)
  (use io)
  (shadow open)
  (externals [*argv* body-limit chunk-size download http timeout write])

(define open
  Path R ->
    (if (and (>= (curl.status R) 200) (< (curl.status R) 300))
        (io.open-file Path write)
        (:err (io.native-error download http (curl.status R) (curl.url R) "download requires a 2xx response"))))

(define finished
  (:ok R) -> (output "Saved ~A bytes~%" (curl.body-length R))
  (:err Error) -> (error "download: ~A (~A; ~A bytes written)"
                    (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define main
  [_ URL Path] ->
    (finished
      (curl.with-client
        (/. Client
          (curl.request-with-sink Client "GET" URL [] (buffer.new 0) (/. Head (open Path Head))
            [[body-limit 1073741824] [chunk-size 16384] [timeout 30000]]))))
  _ -> (error "usage: shen-jit script tools/curl-fetch.shenmod URL FILE"))

(main (value *argv*))

)

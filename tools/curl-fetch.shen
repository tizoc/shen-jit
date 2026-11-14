\\ Bounded streaming download. Build the optional adapter with make curl first.

(shen.x.namespace curl-fetch
  (use buffer)
  (use curl)
  (use io)
  (shadow open)
  (externals [*argv* body-limit chunk-size download http ok timeout write])

(let Quiet (hush?)
     _ (hush +)
     _ (map (function load) ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/curl.shen"])
  (set *hush* Quiet))

(define open
  Path R ->
    (if (and (>= (curl.status R) 200) (< (curl.status R) 300))
        (io.open-file Path write)
        [error (io.native-error download http (curl.status R) (curl.url R) "download requires a 2xx response")]))

(define finished
  [ok R] -> (output "Saved ~A bytes~%" (curl.body-length R))
  [error Error] -> (error "download: ~A (~A; ~A bytes written)"
                    (io.error-message Error) (io.error-code Error) (io.error-progress Error)))

(define main
  [_ URL Path] ->
    (finished
      (curl.with-client
        (/. Client
          (curl.request-with-sink Client "GET" URL [] (buffer.new 0) (/. Head (open Path Head))
            [[body-limit 1073741824] [chunk-size 16384] [timeout 30000]]))))
  _ -> (error "usage: shen-jit script tools/curl-fetch.shen URL FILE"))

(main (value *argv*))

)

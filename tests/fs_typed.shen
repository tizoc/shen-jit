(define fs-typed.size
  {(io.result fs.info) --> fixnum}
  (:result.ok Info) -> (let Modified (fs.modified Info)
                   Accessed (fs.accessed Info)
                 (fs.size Info))
  (:result.err _) -> -1)

(define fs-typed.count
  {(io.result (number * boolean)) --> number}
  (:result.ok (@p Count _)) -> Count
  (:result.err _) -> -1)

(define fs-typed.present?
  {(io.result A) --> boolean}
  (:result.ok _) -> true
  (:result.err _) -> false)

(define fs-typed.write-result
  {(io.result fixnum) --> (io.result fixnum)}
  (:result.ok N) -> (result.ok N)
  (:result.err Error) -> (result.err Error))

(define fs-typed.temp-failure
  {string --> io.error --> (io.result string)}
  Root Error -> (fs.with-temp-file Root "typed-" (/. Path E (:result.err (io.progress Error 7)))))

(define fs-typed.replacement-failure
  {string --> io.error --> (io.result string)}
  Path Error -> (fs.with-replacement Path (/. E (:result.err (io.progress Error 11)))))

(define fs-typed.progress
  {(io.result string) --> fixnum}
  (:result.err Error) -> (io.error-progress Error)
  (:result.ok _) -> -1)

(define fs-typed.run
  {string --> boolean}
  Root ->
    (let Path (fs.join Root "typed-output")
         Written (fs.with-replacement Path
                   (/. E (fs-typed.write-result (io.write-all E (buffer.from-string "typed") []))))
         Temporary (fs.with-temp-file Root "typed-"
                     (/. P E (:result.ok (fs.name P))))
         Error (io.error write Path "transfer failed")
         Walked (fs.walk (fs.join Root "tree") [[entry-limit 100] [depth-limit 8]]
                  (/. Info Depth continue))
      (and (= Written (:result.ok 5))
           (fs-typed.present? Temporary)
           (= (fs-typed.progress (fs-typed.temp-failure Root Error)) 7)
           (= (fs-typed.progress (fs-typed.replacement-failure Path Error)) 11)
           (> (fs-typed.count Walked) 0)
           (= (fs-typed.size (fs.stat Path)) 5))))

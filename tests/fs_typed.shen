(define fs-typed.size
  {(io.result fs.info) --> number}
  [ok Info] -> (let Modified (fs.modified Info)
                   Accessed (fs.accessed Info)
                 (fs.size Info))
  [error _] -> -1)

(define fs-typed.count
  {(io.result (number * boolean)) --> number}
  [ok (@p Count _)] -> Count
  [error _] -> -1)

(define fs-typed.present?
  {(io.result A) --> boolean}
  [ok _] -> true
  [error _] -> false)

(define fs-typed.write-result
  {io.transfer-result --> (io.result number)}
  [ok N] -> [ok N]
  [error Error _] -> [error Error]
  [eof _] -> [error (io.error write "typed file" "unexpected EOF")])

(define fs-typed.run
  {string --> boolean}
  Root ->
    (let Path (fs.join Root "typed-output")
         Written (fs.with-replacement Path
                   (/. E (fs-typed.write-result (io.write-all E (buffer.from-string "typed") []))))
         Temporary (fs.with-temp-file Root "typed-"
                     (/. P E [ok (fs.name P)]))
         Walked (fs.walk (fs.join Root "tree") [[entry-limit 100] [depth-limit 8]]
                  (/. Info Depth continue))
      (and (= Written [ok 5])
           (fs-typed.present? Temporary)
           (> (fs-typed.count Walked) 0)
           (= (fs-typed.size (fs.stat Path)) 5))))

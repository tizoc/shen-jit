\\ Platform and byte checks shared by file and filesystem paths.
(shen.x.namespace io
  (use buffer)
  (use shen-jit)
  (export file-absolute? file-no-nul file-windows?)

(define file-windows?
  {--> boolean}
  -> (= (os) "Windows"))

(define file-no-nul
  {buffer.storage --> fixnum --> fixnum --> boolean}
  _ I I -> true
  B I End ->
    (if (= (shen-jit.u8 B I) 0)
        (error "io: path contains NUL")
        (file-no-nul B (fx+ I 1) End)))

(define file-absolute?
  {buffer.storage --> fixnum --> boolean}
  B N ->
    (and (fx> N 0)
         (or (= (shen-jit.u8 B 0) 47)
             (and (file-windows?)
                  (or (= (shen-jit.u8 B 0) 92)
                      (and (fx> N 1) (= (shen-jit.u8 B 1) 58)))))))

)

\\ The example of docs/refine.md, loaded under (tc +) by tests/smt.sh, which breaks it too.

(refine.type octet N where (and (fx<= 0 N) (fx<= N 255)))

(define-checked byte-at
  {B : buffer.storage --> I : fixnum --> octet}
  {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
  B I -> (shen-jit.u8 B I))

\\ How long the record at I is: a tag, a byte that says how many follow, and those. -1 if it is cut short.
(define-checked record-length
  {B : buffer.storage --> I : fixnum --> R : fixnum}
  {requires (fx<= 0 I)}
  {ensures (or (fx= R -1) (and (fx<= 2 R) (fx<= (fx+ I R) (shen-jit.bytes-length B))))}
  B I -> (if (fx> (fx+ I 2) (shen-jit.bytes-length B))
             -1
             (let N (fx+ 2 (byte-at B (fx+ I 1)))
               (if (fx> (fx+ I N) (shen-jit.bytes-length B)) -1 N))))

(define-checked count-records
  {B : buffer.storage --> I : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= I (shen-jit.bytes-length B))}
  B I Count -> (if (fx= I (shen-jit.bytes-length B))
                   Count
                   (let N (record-length B I)
                     (if (fx= N -1)
                         (error "the record at ~A is cut short" I)
                         (count-records B (fx+ I N) (fx+ Count 1))))))

(define records
  {buffer.storage --> fixnum}
  B -> (count-records B 0 0))

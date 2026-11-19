(shen.x.namespace buffer
  (use shen-jit)
  (shadow index length)
  (export from-string slice bytes buffer.string => string copy! equal?)

(define from-string
  {string --> view}
  Text -> (wrap (shen-jit.string->bytes Text)))

(define slice
  {view --> fixnum --> fixnum --> view}
  V Start Count ->
    (let Checked (check V)
         Begin (view.start Checked)
         I (range (fx- (view.end Checked) Begin) Start Count)
         At (fx+ Begin I)
      (view.make (view.owner Checked) At (fx+ At Count))))

(define bytes
  {view --> storage}
  V -> (let Checked (check V) Start (view.start Checked)
            N (fx- (view.end Checked) Start) Out (shen-jit.bytes N)
         (shen-jit.copy-bytes Out 0 (view.owner Checked) Start N)))

(define buffer.string
  {view --> string}
  V -> (let Checked (check V) Start (view.start Checked)
         (shen-jit.bytes->string (view.owner Checked) Start (fx- (view.end Checked) Start))))

(define copy!
  {view --> fixnum --> view --> fixnum --> fixnum --> view}
  To I From J Count ->
    (let T (check To) F (check From)
         TStart (view.start T) FStart (view.start F)
         TI (range (fx- (view.end T) TStart) I Count)
         FJ (range (fx- (view.end F) FStart) J Count)
      (do (shen-jit.copy-bytes (view.owner T) (fx+ TStart TI)
                              (view.owner F) (fx+ FStart FJ) Count)
          To)))

\\ Flat inner loop: do not reload view records for every byte.
(define equal-range?
  {storage --> fixnum --> storage --> fixnum --> fixnum --> boolean}
  _ _ _ _ 0 -> true
  A I B J N -> (and (= (shen-jit.u8 A I) (shen-jit.u8 B J))
                    (equal-range? A (fx+ I 1) B (fx+ J 1) (fx- N 1))))

(define equal?
  {view --> view --> boolean}
  A B -> (let X (check A) Y (check B)
              I (view.start X) J (view.start Y)
              N (fx- (view.end X) I)
           (and (= N (fx- (view.end Y) J))
                (equal-range? (view.owner X) I (view.owner Y) J N))))

)

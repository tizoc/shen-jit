\\ The checks every access to a view makes, and the accessors over them, typed: read under (tc +),
\\ after buffer-view.shen, which declares the view struct, and before buffer.shen, which calls them. A
\\ typed program inlines them and keeps a view's offsets in registers, as it reads the struct's fixnum
\\ fields into them; untyped code calls them as before, with the same checks and the same errors.

(shen.x.namespace buffer
  (use shen-jit)
  (shadow index length)
  (export check end index length new offset owner range u8 u8-> u16-be u16-be-> u32-be u32-be-> wrap)

\\ An index: a fixnum that is not negative. The bit operation raises for a number that is not one.
(define index
  {fixnum --> fixnum}
  N -> (let I (shen-jit.bit-or N 0)
         (if (fx>= I 0) I (error "buffer: ~S is not a nonnegative index" N))))

(define range
  {fixnum --> fixnum --> fixnum --> fixnum}
  Length Start Count ->
    (let I (index Start) N (index Count)
      (if (and (fx<= I Length) (fx<= N (fx- Length I)))
          I
          (error "buffer: range ~A + ~A exceeds ~A bytes" I N Length))))

\\ The byte primitives read strings too, but a buffer's storage is bytes it may write, or a pointer.
(define storage-length
  {storage --> fixnum}
  Storage -> (if (string? Storage)
                 (error "bytes: ~S is not a byte buffer" Storage)
                 (if (and (shen-jit.pointer? Storage) (= (shen-jit.pointer-address Storage) 0))
                     (error "buffer: storage is closed")
                     (shen-jit.bytes-length Storage))))

\\ storage-length's tests, made here rather than called: a typed program inlines check into the loop
\\ that reads a view, and a call there whose value the loop uses would take its registers away. An
\\ error, which leaves, does not.
(define check
  {view --> view}
  V -> (if (view? V)
           (let Storage (view.owner V)
             (if (string? Storage)
                 (error "bytes: ~S is not a byte buffer" Storage)
                 (if (and (shen-jit.pointer? Storage) (= (shen-jit.pointer-address Storage) 0))
                     (error "buffer: storage is closed")
                     (if (fx<= (view.end V) (shen-jit.bytes-length Storage))
                         V
                         (error "buffer: backing storage is shorter than the view")))))
           (error "buffer: ~S is not a view" V)))

(define owner
  {view --> storage}
  V -> (view.owner (check V)))

(define offset
  {view --> fixnum}
  V -> (view.start (check V)))

(define end
  {view --> fixnum}
  V -> (view.end (check V)))

(define length
  {view --> fixnum}
  V -> (let Checked (check V) (fx- (view.end Checked) (view.start Checked))))

\\ A byte read or written at I: range's tests for one byte, made here for the same reason.
(define u8
  {view --> fixnum --> fixnum}
  V I -> (let Checked (check V)
              Start (view.start Checked)
              Length (fx- (view.end Checked) Start)
              At (index I)
           (if (fx< At Length)
               (shen-jit.u8 (view.owner Checked) (fx+ Start At))
               (error "buffer: range ~A + ~A exceeds ~A bytes" At 1 Length))))

(define u8->
  {view --> fixnum --> fixnum --> view}
  V I Byte -> (let Checked (check V)
                   Start (view.start Checked)
                   Length (fx- (view.end Checked) Start)
                   At (index I)
                (if (fx< At Length)
                    (do (shen-jit.u8! (view.owner Checked) (fx+ Start At) Byte) V)
                    (error "buffer: range ~A + ~A exceeds ~A bytes" At 1 Length))))

(define field-offset
  {view --> fixnum --> fixnum --> fixnum}
  Checked I Width ->
    (let Start (view.start Checked)
      (fx+ Start (range (fx- (view.end Checked) Start) I Width))))

(define swap16
  {fixnum --> fixnum}
  N -> (shen-jit.bit-or (shen-jit.shift-left (shen-jit.bit-and N 255) 8)
                      (shen-jit.shift-right N 8)))

(define u16-be
  {view --> fixnum --> fixnum}
  V I -> (let Checked (check V)
           (swap16 (shen-jit.u16 (view.owner Checked) (field-offset Checked I 2)))))

(define u32-be
  {view --> fixnum --> fixnum}
  V I -> (let Checked (check V)
           (shen-jit.bswap32 (shen-jit.u32 (view.owner Checked) (field-offset Checked I 4)))))

(define u16-be->
  {view --> fixnum --> fixnum --> view}
  V I Value ->
    (let Checked (check V)
         At (field-offset Checked I 2)
         N (shen-jit.bit-or Value 0)
      (if (and (fx>= N 0) (fx<= N 65535))
          (do (shen-jit.u16! (view.owner Checked) At (swap16 N)) V)
          (error "buffer: ~S does not fit in an unsigned 16-bit field" Value))))

(define u32-be->
  {view --> fixnum --> fixnum --> view}
  V I Value ->
    (let Checked (check V)
         At (field-offset Checked I 4)
      (do (shen-jit.u32! (view.owner Checked) At (shen-jit.bswap32 Value)) V)))

(define wrap
  {storage --> view}
  Storage -> (view.make Storage 0 (storage-length Storage)))

(define new
  {fixnum --> view}
  N -> (wrap (shen-jit.bytes (index N))))

)

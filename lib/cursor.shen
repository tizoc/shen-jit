\\ A mutable position over a fixed byte view. Load after lib/buffer.shen, under (tc -).
\\ One task owns a cursor; fork shares bytes but has an independent position.
\\ A local byte boundary returns -1, without making any claim about transport EOF.

(shen.x.namespace cursor
  (use buffer)
  (use shen-jit)
  (shadow fork read)
  (export buffer bytes cursor? fork new offset peek position read remaining seek skip
    cursor.string => string view)

(define cursor?
  C -> (trap-error (and (absvector? C) (= (<-address C 0) buffer.cursor))
                   (/. E false)))

(define make
  View Position -> (address-> (address-> (address-> (absvector 3)
                             0 buffer.cursor) 1 View) 2 Position))

(define check
  C -> (if (cursor? C)
           (do (buffer.check (<-address C 1)) C)
           (error "cursor: ~S is not a cursor" C)))

(define new
  View -> (make (buffer.check View) 0))

(define buffer
  C -> (<-address (check C) 1))

(define position
  C -> (<-address (check C) 2))

(define offset
  C -> (let Checked (check C)
         (+ (<-address (<-address Checked 1) 2) (<-address Checked 2))))

(define remaining
  C -> (let Checked (check C) View (<-address Checked 1)
         (- (- (<-address View 3) (<-address View 2)) (<-address Checked 2))))

(define peek
  C -> (let Checked (check C) View (<-address Checked 1)
            I (<-address Checked 2) Start (<-address View 2)
         (if (= (+ Start I) (<-address View 3))
             -1
             (shen-jit.u8 (<-address View 1) (+ Start I)))))

(define read
  C -> (let Byte (peek C)
         (if (= Byte -1) -1
             (do (address-> C 2 (+ (<-address C 2) 1)) Byte))))

(define seek
  C Position -> (let Checked (check C) View (<-address Checked 1)
                     I (buffer.range (- (<-address View 3) (<-address View 2)) Position 0)
                  (do (address-> Checked 2 I) C)))

(define skip
  C Count -> (let Checked (check C) View (<-address Checked 1)
                 I (<-address Checked 2)
                 _ (buffer.range (- (<-address View 3) (<-address View 2)) I Count)
              (do (address-> Checked 2 (+ I Count)) C)))

(define fork
  C -> (let Checked (check C)
         (make (<-address Checked 1) (<-address Checked 2))))

\\ Construct/copy first, then publish progress, so failed captures never advance.
(define view
  C Count -> (let Checked (check C) I (<-address Checked 2)
                 Out (buffer.slice (<-address Checked 1) I Count)
              (do (address-> Checked 2 (+ I Count)) Out)))

(define bytes
  C Count -> (let Checked (check C) I (<-address Checked 2)
                 Out (buffer.bytes (buffer.slice (<-address Checked 1) I Count))
              (do (address-> Checked 2 (+ I Count)) Out)))

(define cursor.string
  C Count -> (let Checked (check C) I (<-address Checked 2)
                 Out (buffer.string (buffer.slice (<-address Checked 1) I Count))
              (do (address-> Checked 2 (+ I Count)) Out)))

(declare cursor? [A --> boolean])
(declare new [buffer.view --> buffer.cursor])
(declare buffer [buffer.cursor --> buffer.view])
(declare position [buffer.cursor --> number])
(declare offset [buffer.cursor --> number])
(declare remaining [buffer.cursor --> number])
(declare peek [buffer.cursor --> number])
(declare read [buffer.cursor --> number])
(declare seek [buffer.cursor --> [number --> buffer.cursor]])
(declare skip [buffer.cursor --> [number --> buffer.cursor]])
(declare fork [buffer.cursor --> buffer.cursor])
(declare view [buffer.cursor --> [number --> buffer.view]])
(declare bytes [buffer.cursor --> [number --> buffer.storage]])
(declare cursor.string [buffer.cursor --> [number --> string]])

)

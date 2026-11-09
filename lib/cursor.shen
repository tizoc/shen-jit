\\ A mutable position over a fixed byte view. Load after lib/buffer.shen, under (tc -).
\\ One task owns a cursor; fork shares bytes but has an independent position.
\\ A local byte boundary returns -1, without making any claim about transport EOF.

(shen.x.namespace cursor
  (use buffer)
  (use shen-jit)
  (import struct defstruct)
  (shadow fork read)
  (export buffer bytes cursor? fork new offset peek position read remaining seek skip
    cursor.string => string view)

(define show
  C -> (make-string "#<cursor at ~A>" (state.position C)))

(defstruct state
  (printer show)
  view
  (mutable position))

(define cursor?
  C -> (state? C))

(define check
  C -> (if (state? C)
           (do (buffer.check (state.view C)) C)
           (error "cursor: ~S is not a cursor" C)))

(define new
  View -> (state.make (buffer.check View) 0))

(define buffer
  C -> (state.view (check C)))

(define position
  C -> (state.position (check C)))

(define offset
  C -> (let Checked (check C)
         (+ (buffer.view.start (state.view Checked)) (state.position Checked))))

(define remaining
  C -> (let Checked (check C) View (state.view Checked)
         (- (- (buffer.view.end View) (buffer.view.start View)) (state.position Checked))))

(define peek
  C -> (let Checked (check C) View (state.view Checked)
            I (state.position Checked) Start (buffer.view.start View)
         (if (= (+ Start I) (buffer.view.end View))
             -1
             (shen-jit.u8 (buffer.view.owner View) (+ Start I)))))

(define read
  C -> (let Byte (peek C)
         (if (= Byte -1) -1
             (do (state.position-> C (+ (state.position C) 1)) Byte))))

(define seek
  C Position -> (let Checked (check C) View (state.view Checked)
                     I (buffer.range (- (buffer.view.end View) (buffer.view.start View)) Position 0)
                  (do (state.position-> Checked I) C)))

(define skip
  C Count -> (let Checked (check C) View (state.view Checked)
                 I (state.position Checked)
                 _ (buffer.range (- (buffer.view.end View) (buffer.view.start View)) I Count)
              (do (state.position-> Checked (+ I Count)) C)))

(define fork
  C -> (let Checked (check C)
         (state.make (state.view Checked) (state.position Checked))))

\\ Construct/copy first, then publish progress, so failed captures never advance.
(define view
  C Count -> (let Checked (check C) I (state.position Checked)
                 Out (buffer.slice (state.view Checked) I Count)
              (do (state.position-> Checked (+ I Count)) Out)))

(define bytes
  C Count -> (let Checked (check C) I (state.position Checked)
                 Out (buffer.bytes (buffer.slice (state.view Checked) I Count))
              (do (state.position-> Checked (+ I Count)) Out)))

(define cursor.string
  C Count -> (let Checked (check C) I (state.position Checked)
                 Out (buffer.string (buffer.slice (state.view Checked) I Count))
              (do (state.position-> Checked (+ I Count)) Out)))

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

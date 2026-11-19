(shen.x.namespace cursor
  (use buffer)
  (use shen-jit)
  (externals [buffer.cursor buffer.cursor? buffer.cursor.make buffer.cursor.position
    buffer.cursor.position-> buffer.cursor.view])
  (shadow fork read)
  (export buffer bytes cursor? fork new offset peek position read remaining seek skip
    cursor.string => string view)

(define cursor?
  {A --> boolean}
  C -> (buffer.cursor? C))

(define check
  {buffer.cursor --> buffer.cursor}
  C -> (if (buffer.cursor? C)
           (do (buffer.check (buffer.cursor.view C)) C)
           (error "cursor: ~S is not a cursor" C)))

(define new
  {buffer.view --> buffer.cursor}
  View -> (buffer.cursor.make (buffer.check View) 0))

(define buffer
  {buffer.cursor --> buffer.view}
  C -> (buffer.cursor.view (check C)))

(define position
  {buffer.cursor --> fixnum}
  C -> (buffer.cursor.position (check C)))

(define offset
  {buffer.cursor --> fixnum}
  C -> (let Checked (check C)
         (fx+ (buffer.view.start (buffer.cursor.view Checked)) (buffer.cursor.position Checked))))

(define remaining
  {buffer.cursor --> fixnum}
  C -> (let Checked (check C) View (buffer.cursor.view Checked)
         (fx- (fx- (buffer.view.end View) (buffer.view.start View)) (buffer.cursor.position Checked))))

(define peek
  {buffer.cursor --> fixnum}
  C -> (let Checked (check C) View (buffer.cursor.view Checked)
            I (buffer.cursor.position Checked) Start (buffer.view.start View)
         (if (= (fx+ Start I) (buffer.view.end View))
             -1
             (shen-jit.u8 (buffer.view.owner View) (fx+ Start I)))))

(define read
  {buffer.cursor --> fixnum}
  C -> (let Byte (peek C)
         (if (= Byte -1) -1
             (do (buffer.cursor.position-> C (fx+ (buffer.cursor.position C) 1)) Byte))))

(define seek
  {buffer.cursor --> fixnum --> buffer.cursor}
  C Position -> (let Checked (check C) View (buffer.cursor.view Checked)
                     I (buffer.range (fx- (buffer.view.end View) (buffer.view.start View)) Position 0)
                  (do (buffer.cursor.position-> Checked I) C)))

(define skip
  {buffer.cursor --> fixnum --> buffer.cursor}
  C Count -> (let Checked (check C) View (buffer.cursor.view Checked)
                 I (buffer.cursor.position Checked)
                 _ (buffer.range (fx- (buffer.view.end View) (buffer.view.start View)) I Count)
              (do (buffer.cursor.position-> Checked (fx+ I Count)) C)))

(define fork
  {buffer.cursor --> buffer.cursor}
  C -> (let Checked (check C)
         (buffer.cursor.make (buffer.cursor.view Checked) (buffer.cursor.position Checked))))

\\ Construct/copy first, then publish progress, so failed captures never advance.
(define view
  {buffer.cursor --> fixnum --> buffer.view}
  C Count -> (let Checked (check C) I (buffer.cursor.position Checked)
                 Out (buffer.slice (buffer.cursor.view Checked) I Count)
              (do (buffer.cursor.position-> Checked (fx+ I Count)) Out)))

(define bytes
  {buffer.cursor --> fixnum --> buffer.storage}
  C Count -> (let Checked (check C) I (buffer.cursor.position Checked)
                 Out (buffer.bytes (buffer.slice (buffer.cursor.view Checked) I Count))
              (do (buffer.cursor.position-> Checked (fx+ I Count)) Out)))

(define cursor.string
  {buffer.cursor --> fixnum --> string}
  C Count -> (let Checked (check C) I (buffer.cursor.position Checked)
                 Out (buffer.string (buffer.slice (buffer.cursor.view Checked) I Count))
              (do (buffer.cursor.position-> Checked (fx+ I Count)) Out)))

)

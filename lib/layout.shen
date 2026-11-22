\\ Binary layouts, declared as the RFCs draw their headers: fields in order, most significant bit
\\ first, each a name and a width in bits, usually one 32-bit row to a line.
\\
\\   (deflayout tcp
\\     (source-port 16) (destination-port 16)
\\     (sequence 32)
\\     (acknowledgement 32)
\\     (data-offset 4) (_ 4) (flags 8) (window 16)
\\     (checksum 16) (urgent 16))
\\
\\ defines, for the layout at offset I of a byte view B:
\\
\\   (tcp.sequence B I)       the field, a fixnum, for a field of up to 56 bits
\\   (tcp.sequence-> B I X)   stores X there and gives B; X must fit the field
\\   (tcp.sequence-at I)      the field's offset, for a field that starts on a byte
\\   (tcp.size)               the layout's length in bytes
\\
\\ A field of 64 bits or more, such as an IPv6 address, has only its offset, and _ is padding.
\\ Fields are big-endian. A field that is not whole bytes must lie within one byte, 16-bit or 32-bit
\\ word at its own alignment. Offsets, shifts and masks are computed as the definitions are made,
\\ so these are the definitions one would write by hand, typed, and they inline where called.
\\ Inside a namespace, (import layout deflayout); the layout's name is then the namespace's.

(defmacro layout.macro
  [deflayout Name | Fields] -> (let Layout (layout.literal Name)
                                    Checked (map (fn layout.check-field) (map (fn layout.literal) Fields))
                                    _ (layout.check-names Layout Checked)
                                    _ (put Layout layout.fields Checked)
                                 [package null [] | (layout.fields Layout Checked 0)]))

(define layout.literal
  [protect X] -> X
  X -> X)

(define layout.check-field
  [Field Bits] -> [Field Bits] where (and (symbol? Field) (integer? Bits) (> Bits 0))
  Field -> (error "deflayout: ~S is not (Name Bits)" Field))

\\ A field's definitions must not replace another field's, nor the layout's size.
(define layout.check-names
  _ [] -> true
  Name [[Field _] | _] -> (error "deflayout: ~A.size is the layout's length, and cannot name a field" Name)
    where (= Field size)
  Name [[Field _] | Fields] -> (error "deflayout: ~A has two fields named ~A" Name Field)
    where (and (not (layout.padding? Field)) (element? Field (map (fn head) Fields)))
  Name [_ | Fields] -> (layout.check-names Name Fields))

(define layout.fields
  Name [] Bit -> [(layout.size Name Bit)]
  Name [[Field Bits] | Fields] Bit -> (append (layout.field Name Field Bits Bit)
                                              (layout.fields Name Fields (+ Bit Bits))))

(define layout.size
  Name Bit -> [define (layout.name Name size "") { --> fixnum } -> (shen-jit.quotient Bit 8)]
    where (= (shen-jit.remainder Bit 8) 0)
  Name Bit -> (error "deflayout: ~A is ~A bits, not whole bytes" Name Bit))

(define layout.padding?
  Field -> (= Field (intern "_")))

(define layout.name
  Name Field Suffix -> (intern (cn (str Name) (cn "." (cn (str Field) Suffix)))))

(define layout.field
  _ Field _ _ -> [] where (layout.padding? Field)
  Name Field Bits Bit -> (append (layout.offset Name Field Bit)
                                 (layout.access Name Field Bits Bit)))

\\ The offset, for a field that starts on a byte.
(define layout.offset
  Name Field Bit -> [[define (layout.name Name Field "-at") {fixnum --> fixnum}
                       (protect I) -> (layout.at (shen-jit.quotient Bit 8))]]
    where (= (shen-jit.remainder Bit 8) 0)
  _ _ _ -> [])

(define layout.access
  Name Field Bits Bit -> [] where (and (>= Bits 64) (layout.whole? Bits Bit))
  Name Field Bits Bit -> (error "deflayout: ~A.~A is too wide for a fixnum and not whole bytes" Name Field)
    where (>= Bits 64)
  Name Field Bits Bit -> (layout.bytes Name Field Bits Bit) where (layout.whole? Bits Bit)
  Name Field Bits Bit -> (layout.bits Name Field Bits Bit))

(define layout.whole?
  Bits Bit -> (and (= (shen-jit.remainder Bits 8) 0) (= (shen-jit.remainder Bit 8) 0)))

(define layout.at
  0 -> (protect I)
  N -> [fx+ (protect I) N])

(define layout.reader
  8 -> buffer.u8
  16 -> buffer.u16-be
  32 -> buffer.u32-be)

(define layout.writer
  8 -> buffer.u8->
  16 -> buffer.u16-be->
  32 -> buffer.u32-be->)

(define layout.reader-def
  Name Field Body -> [define (layout.name Name Field "") {buffer.view --> fixnum --> fixnum}
                        (protect B) (protect I) -> Body])

(define layout.writer-def
  Name Field Body -> [define (layout.name Name Field "->") {buffer.view --> fixnum --> fixnum --> buffer.view}
                        (protect B) (protect I) (protect X) -> Body])

\\ Whole bytes: one read of 8, 16 or 32 bits, or a few, most significant first, for 24, 40, 48 or 56.
(define layout.bytes
  Name Field Bits Bit -> (let Pieces (layout.pieces Bits)
                              At (shen-jit.quotient Bit 8)
                           [(layout.reader-def Name Field (layout.read-pieces Pieces At))
                            (layout.writer-def Name Field (layout.write-pieces Pieces At Bits))]))

(define layout.pieces
  0 -> []
  Bits -> [32 | (layout.pieces (- Bits 32))] where (>= Bits 32)
  Bits -> [16 | (layout.pieces (- Bits 16))] where (>= Bits 16)
  Bits -> [8 | (layout.pieces (- Bits 8))])

(define layout.read-pieces
  [W | Ws] At -> (layout.read-more Ws (+ At (shen-jit.quotient W 8)) [(layout.reader W) (protect B) (layout.at At)]))

(define layout.read-more
  [] _ Acc -> Acc
  [W | Ws] At Acc -> (layout.read-more Ws (+ At (shen-jit.quotient W 8))
                                       [fx+ [shen-jit.shift-left Acc W]
                                            [(layout.reader W) (protect B) (layout.at At)]]))

\\ The first piece's store checks what is left of X; the others take their bits of it.
(define layout.write-pieces
  [W] At _ -> [(layout.writer W) (protect B) (layout.at At) (protect X)]
  [W | Ws] At Bits -> [do [(layout.writer W) (protect B) (layout.at At)
                              [shen-jit.shift-right (protect X) (- Bits W)]]
                          (layout.write-rest Ws (+ At (shen-jit.quotient W 8)) (- Bits W))])

(define layout.write-rest
  [W] At _ -> [(layout.writer W) (protect B) (layout.at At) [shen-jit.bit-and (protect X) (layout.mask W)]]
  [W | Ws] At Bits -> [do [(layout.writer W) (protect B) (layout.at At)
                              [shen-jit.bit-and [shen-jit.shift-right (protect X) (- Bits W)] (layout.mask W)]]
                          (layout.write-rest Ws (+ At (shen-jit.quotient W 8)) (- Bits W))])

(define layout.mask
  Bits -> (- (shen-jit.shift-left 1 Bits) 1))

\\ Part of a byte or a word: shifted and masked out of the smallest that holds it, at its own alignment.
(define layout.bits
  Name Field Bits Bit -> (let W (layout.container Name Field Bits Bit [8 16 32])
                              At (layout.at (* (shen-jit.quotient Bit W) (shen-jit.quotient W 8)))
                              Shift (- (- W (shen-jit.remainder Bit W)) Bits)
                              Mask (layout.mask Bits)
                              Read [(layout.reader W) (protect B) At]
                              Rest (- (layout.mask W) (shen-jit.shift-left Mask Shift))
                           [(layout.reader-def Name Field (layout.extract Read Shift Mask))
                            (layout.writer-def Name Field
                              [if [and [fx>= (protect X) 0] [fx<= (protect X) Mask]]
                                  [(layout.writer W) (protect B) At
                                   [shen-jit.bit-or [shen-jit.bit-and Read Rest]
                                                    (layout.place (protect X) Shift)]]
                                  [error (cn (str (layout.name Name Field "->"))
                                             (cn ": ~A does not fit " (cn (str Bits) " bits")))
                                         (protect X)]])]))

(define layout.container
  Name Field Bits _ [] -> (error "deflayout: ~A.~A crosses a 32-bit word" Name Field)
  _ _ Bits Bit [W | _] -> W where (= (shen-jit.quotient Bit W) (shen-jit.quotient (+ Bit (- Bits 1)) W))
  Name Field Bits Bit [_ | Ws] -> (layout.container Name Field Bits Bit Ws))

(define layout.extract
  Read 0 Mask -> [shen-jit.bit-and Read Mask]
  Read Shift Mask -> [shen-jit.bit-and [shen-jit.shift-right Read Shift] Mask])

(define layout.place
  X 0 -> X
  X Shift -> [shen-jit.shift-left X Shift])

\\ In a namespace, field names are literal, while the layout's name becomes the namespace's, and
\\ the values written are expressions in the caller's scope.
(define layout.namespace-syntax
  [deflayout Name | Fields] -> [deflayout Name | (map (/. F [protect F]) Fields)]
  [write-layout Name B I | Values] -> [write-layout Name B I | (map (fn layout.protect-value) Values)]
  [defflags Name | Bits] -> [defflags Name | (map (/. B [protect B]) Bits)]
  [flag-bits Name | Bits] -> [flag-bits Name | (map (/. B [protect B]) Bits)]
  Form -> Form)

(define layout.protect-value
  [Field Value] -> [[protect Field] Value]
  Other -> Other)

(define layout.introduced-names
  [deflayout Name | Fields] -> (layout.names Name (map (fn layout.literal) Fields) 0)
  Form -> (error "deflayout: invalid declaration ~S" Form))

(define layout.names
  Name [] _ -> [(layout.name Name size "")]
  Name [[Field Bits] | Fields] Bit -> (append (layout.field-names Name Field Bits Bit)
                                              (layout.names Name Fields (+ Bit Bits))))

(define layout.field-names
  _ Field _ _ -> [] where (layout.padding? Field)
  Name Field Bits Bit -> (append (if (= (shen-jit.remainder Bit 8) 0) [(layout.name Name Field "-at")] [])
                                 (if (>= Bits 64)
                                     []
                                     [(layout.name Name Field "") (layout.name Name Field "->")])))

(shen.x.namespaces.register-syntax deflayout (fn layout.namespace-syntax))
(shen.x.namespaces.register-syntax write-layout (fn layout.namespace-syntax))
(shen.x.namespaces.register-syntax defflags (fn layout.namespace-syntax))
(shen.x.namespaces.register-syntax flag-bits (fn layout.namespace-syntax))
(shen.x.namespaces.register-definitions deflayout (fn layout.introduced-names))
(shen.x.namespaces.publish layout [[deflayout | deflayout] [write-layout | write-layout]
                                   [defflags | defflags] [flag-bits | flag-bits]])

\\ (write-layout Layout B I (Field Value) ...) writes a whole layout at offset I of B, in as few
\\ stores as its bytes allow: 32 bits at a time, then 16 and 8, each the given fields' values shifted
\\ into place, so constants fold into one number. Fields not given are 0. A field of 64 bits or more
\\ is left as it is, for the caller to write. Each value is checked against its field's width, and
\\ the bytes the stores cover against B, once, before any is stored; the stores then go to B's
\\ storage. It gives B.
(defmacro layout.write-macro
  [write-layout Name B I | Values] -> (layout.write (layout.literal Name) B I (map (fn layout.value) Values)))

(define layout.value
  [[protect Field] Value] -> [Field Value]
  [Field Value] -> [Field Value] where (symbol? Field)
  Other -> (error "write-layout: ~S is not (Field Value)" Other))

(define layout.write
  Name B I Values ->
    (let Fields (trap-error (get Name layout.fields) (/. E (error "write-layout: ~A is not a layout" Name)))
         Spans (layout.spans Fields 0)
         _ (map (/. V (layout.known Name Spans V)) Values)
         _ (layout.once Name (map (fn hd) Values))
         Chunks (layout.chunks (layout.runs Spans 0 (layout.bits-of Fields)))
         Bound (map (/. V (layout.bind Name Spans V)) Values)
         Vars (gensym (protect V))
         Ip (if (or (number? I) (variable? I)) I (gensym (protect At)))
         Body (layout.lets Bound (layout.stores Vars Ip Spans Bound Chunks))
      [let Vars B (if (= Ip I) Body [let Ip I Body])]))

\\ The stores, once the bytes from the first's to the end of the last's are checked against B.
(define layout.stores
  B _ _ _ [] -> B
  B I Spans Bound Chunks ->
    (let Lo (shen-jit.quotient (hd (hd Chunks)) 8)
         Last (hd (reverse Chunks))
         Hi (shen-jit.quotient (+ (hd Last) (hd (tl Last))) 8)
         Base (gensym (protect Base))
         Storage (gensym (protect Storage))
      [let Base [buffer.offset-at B (layout.at-of I Lo) (- Hi Lo)]
        [let Storage [buffer.owner B]
          [do | (append (map (/. C (layout.store Storage Base Lo Spans Bound C)) Chunks) [B])]]]))

(define layout.bits-of
  [] -> 0
  [[_ Bits] | Fields] -> (+ Bits (layout.bits-of Fields)))

\\ Each field as [Field Start Bits], Start in bits from the layout's start.
(define layout.spans
  [] _ -> []
  [[Field Bits] | Fields] Bit -> [[Field Bit Bits] | (layout.spans Fields (+ Bit Bits))])

(define layout.known
  Name Spans [Field _] -> (let Span (layout.span Field Spans)
                            (cases (= Span []) (error "write-layout: ~A has no field ~A" Name Field)
                                   (>= (nth 3 Span) 64) (error "write-layout: ~A.~A is written by the caller" Name Field)
                                   true Span)))

\\ A field given twice would have its values added or or-ed together.
(define layout.once
  _ [] -> true
  Name [Field | Fields] -> (if (element? Field Fields)
                               (error "write-layout: ~A.~A is given twice" Name Field)
                               (layout.once Name Fields)))

(define layout.span
  _ [] -> []
  Field [[Field Start Bits] | _] -> [Field Start Bits]
  Field [_ | Spans] -> (layout.span Field Spans))

\\ The runs of bits to store: everything but fields of 64 bits or more, as [Start End].
(define layout.runs
  [] Start End -> (if (< Start End) [[Start End]] [])
  [[_ S N] | Spans] Start End -> (append (if (< Start S) [[Start S]] []) (layout.runs Spans (+ S N) End))
    where (>= N 64)
  [_ | Spans] Start End -> (layout.runs Spans Start End))

\\ Each run as stores of 32 bits, then 16, then 8, as [Start Width].
(define layout.chunks
  [] -> []
  [[S E] | Runs] -> (append (layout.chunk S E) (layout.chunks Runs)))

(define layout.chunk
  S E -> [] where (>= S E)
  S E -> [[S 32] | (layout.chunk (+ S 32) E)] where (>= (- E S) 32)
  S E -> [[S 16] | (layout.chunk (+ S 16) E)] where (>= (- E S) 16)
  S E -> [[S 8] | (layout.chunk (+ S 8) E)])

\\ A value as [Field Atom Binding]: a number is itself, and anything else is bound once and checked
\\ against its field's width. A binding is typed fixnum, as a literal bound by let, such as one branch of
\\ (if Ack 4 20), would otherwise be a number.
(define layout.bind
  Name Spans [Field Value] ->
    (let Bits (nth 3 (layout.span Field Spans))
      (cases (and (number? Value) (>= Value 0) (< Value (shen-jit.shift-left 1 Bits))) [Field Value []]
             (number? Value) (error "write-layout: ~A does not fit ~A.~A, of ~A bits" Value Name Field Bits)
             true (let R (gensym (protect R))
                       V (gensym (protect V))
                    [Field V [[R [type Value fixnum]]
                              [V [if [and [fx>= R 0] [fx<= R (layout.mask Bits)]]
                                     R
                                     [error (cn (str Name) (cn "." (cn (str Field) (cn ": ~A does not fit " (cn (str Bits) " bits")))))
                                            R]]]]]))))

(define layout.lets
  [] Body -> Body
  [[_ _ Pairs] | Bound] Body -> (layout.let-pairs Pairs (layout.lets Bound Body)))

(define layout.let-pairs
  [] Body -> Body
  [[V Value] | Pairs] Body -> [let V Value (layout.let-pairs Pairs Body)])

\\ One store into Storage, whose byte Base is the layout's byte Lo: the parts of the given fields
\\ that fall in it, shifted into place, in the order that makes them big-endian there.
(define layout.store
  Storage Base Lo Spans Bound [Start Width] ->
    (let Parts (mapcan (/. Given (layout.part Spans Start Width Given)) Bound)
         Constant (layout.sum (mapcan (/. P (if (number? P) [P] [])) Parts))
         Exprs (mapcan (/. P (if (number? P) [] [P])) Parts)
         Value (layout.combine Constant Exprs)
      [(layout.raw-writer Width) Storage (layout.at-of Base (- (shen-jit.quotient Start 8) Lo))
                                 (layout.big-endian Width Value)]))

(define layout.raw-writer
  8 -> shen-jit.u8!
  16 -> shen-jit.u16!
  32 -> shen-jit.u32!)

\\ A value's bytes reversed, as the machine's order, little-endian on every platform this runs on,
\\ stores them, so that they are big-endian in the storage: a constant's as the code is read.
(define layout.big-endian
  8 X -> X
  16 X -> (+ (* 256 (shen-jit.bit-and X 255)) (shen-jit.shift-right X 8)) where (number? X)
  16 X -> [shen-jit.shift-right [shen-jit.bswap32 X] 16]
  32 X -> (shen-jit.bswap32 X) where (number? X)
  32 X -> [shen-jit.bswap32 X])

(define layout.at-of
  I 0 -> I
  I N -> [fx+ I N])

(define layout.part
  Spans Start Width [Field Atom _] ->
    (let Span (layout.span Field Spans)
         F (nth 2 Span)
         N (nth 3 Span)
         Lo (if (> Start F) Start F)
         Hi (if (< (+ Start Width) (+ F N)) (+ Start Width) (+ F N))
      (if (>= Lo Hi)
          []
          [(layout.shifted Atom (- (+ F N) Hi) (- Hi Lo) N (- (+ Start Width) Hi))])))

\\ Bits Count of X that end Below bits above its last, moved Up bits left.
(define layout.shifted
  X Below Count N Up -> (shen-jit.shift-left (shen-jit.bit-and (shen-jit.shift-right X Below) (layout.mask Count)) Up)
    where (number? X)
  X Below Count N Up -> (layout.place (layout.low (layout.down X Below) Count N Below) Up))

(define layout.down
  X 0 -> X
  X Below -> [shen-jit.shift-right X Below])

(define layout.low
  X Count N Below -> X where (= (+ Count Below) N)
  X Count _ _ -> [shen-jit.bit-and X (layout.mask Count)])

(define layout.sum
  [] -> 0
  [X | Xs] -> (+ X (layout.sum Xs)))

(define layout.combine
  C [] -> C
  0 [E] -> E
  0 [E | Es] -> [shen-jit.bit-or E (layout.combine 0 Es)]
  C Es -> [shen-jit.bit-or C (layout.combine 0 Es)])

\\ (defflags Name Bit ...) names the bits of a flags field, the most significant first, as the RFCs
\\ draw them, and (flag-bits Name Bit ...) is the number with those bits set, made as the code is
\\ read: after (defflags control cwr ece urg ack psh rst syn fin), (flag-bits control syn ack) is 18.
(defmacro layout.flags-macro
  [defflags Name | Bits] -> (let Set (layout.literal Name)
                                 Names (map (fn layout.literal) Bits)
                                 _ (put Set layout.flags (layout.bit-table Names (- (length Names) 1)))
                              [package null []])
  [flag-bits Name | Bits] -> (layout.flag-value (layout.literal Name) (map (fn layout.literal) Bits)))

(define layout.bit-table
  [] _ -> []
  [Bit | Bits] N -> [[Bit | (shen-jit.shift-left 1 N)] | (layout.bit-table Bits (- N 1))])

(define layout.flag-value
  Set Bits -> (let Table (trap-error (get Set layout.flags) (/. E (error "flag-bits: ~A is not a set of flags" Set)))
                (layout.or-bits Set Table Bits 0)))

(define layout.or-bits
  _ _ [] Value -> Value
  Set Table [Bit | Bits] Value -> (let Entry (assoc Bit Table)
                                    (if (= Entry [])
                                        (error "flag-bits: ~A has no bit ~A" Set Bit)
                                        (layout.or-bits Set Table Bits (shen-jit.bit-or Value (tl Entry))))))

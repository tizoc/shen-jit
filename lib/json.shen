\\ Complete UTF-8 JSON over byte views. Load buffer.shen and grammar.shen first, under (tc -).
\\ Numbers decode to lossless [number Token] values; native numbers can also be encoded.

(shen.x.namespace json
  (use buffer)
  (use grammar)
  (use io)
  (use shen-jit)
  (externals [? at byte-limit defgrammar depth-limit eof json-options json-values object ok require
    span text])
  (shadow <e> read value)
  (export array decode encode integer json.number => number json.string => string option parse read
    stringify value object null)

(define scan-fail
  I What -> (error "json: byte ~A: ~A" I What))

(define scan-byte
  Data I End -> (if (< I End) (shen-jit.u8 Data I) (scan-fail I "unexpected end")))

(define scan-continuation?
  B -> (and (>= B 128) (<= B 191)))

(define scan-utf8-width
  Data I End ->
    (let B (scan-byte Data I End)
      (cond ((< B 128) 1)
            ((and (>= B 194) (<= B 223)
                  (scan-continuation? (scan-byte Data (+ I 1) End))) 2)
            ((and (>= B 224) (<= B 239)
                  (let C (scan-byte Data (+ I 1) End)
                    (and (scan-continuation? C)
                         (or (not (= B 224)) (>= C 160))
                         (or (not (= B 237)) (< C 160))))
                  (scan-continuation? (scan-byte Data (+ I 2) End))) 3)
            ((and (>= B 240) (<= B 244)
                  (let C (scan-byte Data (+ I 1) End)
                    (and (scan-continuation? C)
                         (or (not (= B 240)) (>= C 144))
                         (or (not (= B 244)) (< C 144))))
                  (scan-continuation? (scan-byte Data (+ I 2) End))
                  (scan-continuation? (scan-byte Data (+ I 3) End))) 4)
            (true (scan-fail I "invalid UTF-8")))))

(define scan-hex
  B I -> (cond ((and (>= B 48) (<= B 57)) (- B 48))
               ((and (>= B 65) (<= B 70)) (- B 55))
               ((and (>= B 97) (<= B 102)) (- B 87))
               (true (scan-fail I "invalid Unicode escape"))))

(define scan-hex4
  _ I _ 0 Acc -> Acc
  Data I End N Acc -> (scan-hex4 Data (+ I 1) End (- N 1)
                       (+ (* Acc 16) (scan-hex (scan-byte Data I End) I))))

\\ A JSON scalar always uses UTF-8, including scalars below 256.
(define scan-scalar
  Out K N ->
    (cond ((< N 128) (do (shen-jit.u8! Out K N) (+ K 1)))
          ((< N 2048)
            (do (shen-jit.u8! Out K (+ 192 (shen-jit.shift-right N 6)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and N 63))) (+ K 2)))
          ((< N 65536)
            (do (shen-jit.u8! Out K (+ 224 (shen-jit.shift-right N 12)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and N 63))) (+ K 3)))
          (true
            (do (shen-jit.u8! Out K (+ 240 (shen-jit.shift-right N 18)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 12) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 3) (+ 128 (shen-jit.bit-and N 63))) (+ K 4)))))

(define scan-unicode
  Data I Stop Out K Shift ->
    (let N (scan-hex4 Data (+ I 2) Stop 4 0)
      (cond ((and (>= N 55296) (<= N 56319))
              (if (and (< (+ I 7) Stop) (= (shen-jit.u8 Data (+ I 6)) 92)
                       (= (shen-jit.u8 Data (+ I 7)) 117))
                  (let Low (scan-hex4 Data (+ I 8) Stop 4 0)
                    (if (and (>= Low 56320) (<= Low 57343))
                        (scan-decode Data (+ I 12) Stop Out
                          (scan-scalar Out K (+ 65536 (+ (* (- N 55296) 1024) (- Low 56320)))) Shift)
                        (scan-fail (+ I Shift) "invalid low surrogate")))
                  (scan-fail (+ I Shift) "missing low surrogate")))
            ((and (>= N 56320) (<= N 57343)) (scan-fail (+ I Shift) "unpaired low surrogate"))
            (true (scan-decode Data (+ I 6) Stop Out (scan-scalar Out K N) Shift)))))

(define scan-decode
  _ I I _ K _ -> K
  Data I Stop Out K Shift ->
    (let B (shen-jit.u8 Data I)
      (if (= B 92)
          (let E (scan-byte Data (+ I 1) Stop)
            (if (= E 117)
                (scan-unicode Data I Stop Out K Shift)
                (let Byte (cond ((element? E [34 47 92]) E)
                                 ((= E 98) 8) ((= E 102) 12) ((= E 110) 10)
                                 ((= E 114) 13) ((= E 116) 9)
                                 (true (scan-fail (+ I Shift) "invalid escape")))
                  (do (shen-jit.u8! Out K Byte)
                      (scan-decode Data (+ I 2) Stop Out (+ K 1) Shift)))))
          (let Run (- (scan-run Data I Stop) I)
            (do (shen-jit.copy-bytes Out K Data I Run)
                (scan-decode Data (+ I Run) Stop Out (+ K Run) Shift))))))

\\ The grammar has checked the text, so what runs to the next escape is copied as it is.
(define scan-run
  _ I I -> I
  Data I Stop -> (if (= (shen-jit.u8 Data I) 92) I (scan-run Data (+ I 1) Stop)))

\\ V is the span the grammar made, and At its position, which errors count from: read from a
\\ reader, the span is a copy, and At is its position in the stream.
(define unescape
  V At -> (let Start (buffer.view.start V) Stop (buffer.view.end V) Out (shen-jit.bytes (- Stop Start))
            (shen-jit.bytes->string Out 0
              (scan-decode (buffer.view.owner V) Start Stop Out 0 (- At Start)))))

(define new-key?
  Seen Key -> (if (trap-error (shen.<-dict Seen Key) (/. E false))
                  false
                  (do (shen.dict-> Seen Key true) true)))

(defgrammar <ws-byte> B where (or (= B 32) (= B 10) (= B 13) (= B 9));)
(defgrammar <ws> (* <ws-byte>);)

(defgrammar <digit> B where (and (>= B 48) (<= B 57));)
(defgrammar <nonzero> B where (and (>= B 49) (<= B 57));)
(defgrammar <e> B where (or (= B 69) (= B 101));)
(defgrammar <sign> B where (or (= B 43) (= B 45));)
(defgrammar <int> 48; <nonzero> (* <digit>);)
(defgrammar <fraction> 46 (require (+ <digit>) "expected digits");)
(defgrammar <exponent> <e> (? <sign>) (require (+ <digit>) "expected digits");)
(defgrammar <integer> 45 (require <int> "expected integer"); <int>;)
(defgrammar <number> <integer> (? <fraction>) (? <exponent>);)

\\ A string's bytes are its text unless it has escapes, which the decoder above turns into bytes.
(defgrammar <plain> B where (and (>= B 32) (< B 128) (not (= B 34)) (not (= B 92)));)
(defgrammar <tail> B where (scan-continuation? B);)
\\ The first byte is checked before any byte after it is read, so that the closing quote ends a
\\ string read from a reader without waiting for more input.
(defgrammar <utf8> B (where (and (>= B 194) (<= B 244))) (<sequence> B);)
(defgrammar (<sequence> B)
  <tail> where (<= B 223);
  C <tail> where (and (>= B 224) (<= B 239) (scan-continuation? C)
                      (or (not (= B 224)) (>= C 160)) (or (not (= B 237)) (< C 160)));
  C <tail> <tail> where (and (>= B 240) (scan-continuation? C)
                             (or (not (= B 240)) (>= C 144)) (or (not (= B 244)) (< C 144)));)
(defgrammar <char> (+ <plain>); <utf8>;)
(defgrammar <raw> (* <char>);)
(defgrammar <hex> B where (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 70)) (and (>= B 97) (<= B 102)));)
(defgrammar <escape>
  B where (element? B [34 47 92 98 102 110 114 116]);
  117 (require <hex> <hex> <hex> <hex> "invalid Unicode escape");)
(defgrammar <part> <char>; 92 (require <escape> "invalid escape");)
(defgrammar <escaped> (* <part>);)
(defgrammar <string>
  34 (text <raw>) 34 := <raw>;
  34 (at P) (span <escaped>) (require 34 "unterminated string") := (unescape <escaped> P);)

\\ Depth counts the containers around a value; a container at the limit is refused.
(defgrammar (<value> Depth Limit)
  <string> := <string>;
  "n" (require "ull" "invalid literal") := null;
  "t" (require "rue" "invalid literal") := true;
  "f" (require "alse" "invalid literal") := false;
  "[" (require (where (< Depth Limit)) "nesting limit") <ws> (<elements> (+ Depth 1) Limit)
    := <elements>;
  "{" (require (where (< Depth Limit)) "nesting limit") <ws> (<members> (+ Depth 1) Limit (shen.dict 8))
    := [object | <members>];
  (text <number>) := [number <number>];)

(defgrammar (<elements> Depth Limit)
  "]" := [];
  (require (<value> Depth Limit) "expected value") <ws> (<more> Depth Limit)
    := [<value> | <more>];)

(defgrammar (<more> Depth Limit)
  "]" := [];
  "," <ws> (require (<value> Depth Limit) "expected value") <ws> (<more> Depth Limit)
    := [<value> | <more>];
  (require (where false) "expected comma or closing bracket") := [];)

(defgrammar (<members> Depth Limit Seen)
  "}" := [];
  (require (<member> Depth Limit Seen) "expected object key") <ws> (<more-members> Depth Limit Seen)
    := [<member> | <more-members>];)

(defgrammar (<more-members> Depth Limit Seen)
  "}" := [];
  "," <ws> (require (<member> Depth Limit Seen) "expected object key") <ws>
    (<more-members> Depth Limit Seen) := [<member> | <more-members>];
  (require (where false) "expected comma or closing brace") := [];)

(defgrammar (<member> Depth Limit Seen)
  <string> (require (where (new-key? Seen <string>)) "duplicate object key")
  <ws> (require ":" "expected colon") <ws> (require (<value> Depth Limit) "expected value")
    := [<string> <value>];)

(defgrammar (<document> Limit)
  <ws> (require (<value> 0 Limit) "expected value") <ws> := <value>;)

(defgrammar <token> (text <number>) := [number <number>];)

\\ From a reader: the whitespace before a value, and the value; what follows stays unread, as
\\ reading on would wait for the next value. Whitespace and then the end is the end.
(defgrammar (<next> Limit)
  <ws> <end> := end;
  <ws> (require (<value> 0 Limit) "expected value") := <value>;)

(define read
  R Options -> (read-result (grammar.read (<next> (snd (options Options))) R (function scan-fail))))

(define read-result
  [ok end] -> [eof]
  Result -> Result)

(define decode-view
  View DepthLimit -> (grammar.parse (<document> DepthLimit) View (/. At Message (syntax View At Message))))

\\ At the end of the input, whatever was expected, the input ended. A string that stopped short
\\ did so at a control byte or at bytes that are not UTF-8.
(define syntax
  View At _ -> (scan-fail At "unexpected end") where (>= At (buffer.end View))
  View At "unterminated string" ->
    (scan-fail At (if (< (shen-jit.u8 (buffer.owner View) At) 32) "unescaped control byte" "invalid UTF-8"))
  _ At Message -> (scan-fail At Message))

(define options
  Options -> (configure Options 1048576 128 []))

(define configure
  [] Bytes Depth _ -> (@p Bytes Depth)
  [[Name Value] | Rest] Bytes Depth Seen ->
    (let _ (if (element? Name Seen) (error "json: duplicate option") true)
         N (buffer.index Value)
      (cases (= Name byte-limit) (configure Rest N Depth [Name | Seen])
             (= Name depth-limit)
               (if (<= N 256) (configure Rest Bytes N [Name | Seen])
                   (error "json: depth limit must be 0..256"))
             true (error "json: unknown option")))
  _ _ _ _ -> (error "json: options must be [Name Number] pairs"))

(define decode
  View Options ->
    (let Limits (options Options)
         _ (if (<= (buffer.length View) (fst Limits)) true (error "json: input exceeds byte limit"))
      (decode-view View (snd Limits))))

(define parse
  Text Options -> (decode (buffer.from-string Text) Options))

\\ A string value, or an array's values; any other value raises.
(define json.string
  S -> S where (string? S)
  _ -> (error "json: not a string"))

(define array
  [number | _] -> (error "json: not an array")
  [object | _] -> (error "json: not an array")
  Values -> Values where (or (= Values []) (cons? Values))
  _ -> (error "json: not an array"))

(define json.number
  Token -> (grammar.parse <token> (buffer.from-string Token) (/. At Message (error "json: invalid number token"))))

(define integer
  [number Token] ->
    (let _ (json.number Token)
         B (shen-jit.string->bytes Token)
         N (shen-jit.bytes-length B)
         Negative (= (shen-jit.u8 B 0) 45)
         Value (integer-digits B (if Negative 1 0) N 0 (if Negative 2 1))
      (if Negative Value (- 0 Value)))
  N -> (shen-jit.bit-or N 0) where (number? N)
  _ -> (error "json: expected an integer"))

(define integer-digits
  _ At At N _ -> N
  B At End N Last ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9)
               (>= N -230584300921369395)
               (or (> N -230584300921369395) (<= Digit Last)))
          (integer-digits B (+ At 1) End (- (* N 10) Digit) Last)
          (error "json: number is not a decimal integer in the fixnum range"))))

(define put-text
  Out Text -> (buffer.append! Out (buffer.from-string Text)))

(define hex-digit
  N -> (pos "0123456789abcdef" N))

(define escape
  34 -> "c#92;c#34;"
  92 -> "c#92;c#92;"
  8 -> "c#92;b"
  9 -> "c#92;t"
  10 -> "c#92;n"
  12 -> "c#92;f"
  13 -> "c#92;r"
  N -> (cn "c#92;u00" (cn (hex-digit (shen-jit.shift-right N 4))
                          (hex-digit (shen-jit.bit-and N 15)))))

(define emit-string
  Out Text ->
    (let B (shen-jit.string->bytes Text)
         _ (buffer.append-byte! Out 34)
      (emit-string-run Out B 0 0 (shen-jit.bytes-length B))))

(define emit-string-run
  Out B Start End End ->
    (do (buffer.append! Out (buffer.make B Start End)) (buffer.append-byte! Out 34))
  Out B Start At End ->
    (let Byte (shen-jit.u8 B At)
      (if (or (< Byte 32) (= Byte 34) (= Byte 92))
          (do (buffer.append! Out (buffer.make B Start At))
              (put-text Out (escape Byte))
              (emit-string-run Out B (+ At 1) (+ At 1) End))
          (emit-string-run Out B Start (+ At (scan-utf8-width B At End)) End))))

(define container-depth
  Depth Limit -> (if (< Depth Limit) (+ Depth 1) (error "json: nesting limit")))

(define emit
  Out null _ _ -> (put-text Out "null")
  Out true _ _ -> (put-text Out "true")
  Out false _ _ -> (put-text Out "false")
  Out Text _ _ -> (emit-string Out Text) where (string? Text)
  Out N _ _ -> (emit-number Out (str N)) where (number? N)
  Out [number Token] _ _ -> (emit-number Out Token)
  Out [object | Members] Depth Limit ->
    (let Next (container-depth Depth Limit)
         _ (buffer.append-byte! Out 123)
      (emit-members Out Members Next Limit (shen.dict 8) false))
  Out Values Depth Limit ->
    (let Next (container-depth Depth Limit)
         _ (buffer.append-byte! Out 91)
      (emit-elements Out Values Next Limit false)) where (or (empty? Values) (cons? Values))
  _ _ _ _ -> (error "json: not a JSON value"))

(define emit-number
  Out Token -> (do (json.number Token) (put-text Out Token)))

(define emit-elements
  Out [] _ _ _ -> (buffer.append-byte! Out 93)
  Out [Value | Rest] Depth Limit Comma ->
    (do (if Comma (buffer.append-byte! Out 44) Out)
        (emit Out Value Depth Limit)
        (emit-elements Out Rest Depth Limit true))
  _ _ _ _ _ -> (error "json: array must be a proper list"))

(define emit-members
  Out [] _ _ _ _ -> (buffer.append-byte! Out 125)
  Out [[Key Value] | Rest] Depth Limit Seen Comma ->
    (let _ (if (string? Key) true (error "json: object keys must be strings"))
         _ (if (trap-error (shen.<-dict Seen Key) (/. X false))
               (error "json: duplicate object key") true)
         _ (shen.dict-> Seen Key true)
      (do (if Comma (buffer.append-byte! Out 44) Out)
          (emit-string Out Key)
          (buffer.append-byte! Out 58)
          (emit Out Value Depth Limit)
          (emit-members Out Rest Depth Limit Seen true)))
  _ _ _ _ _ _ -> (error "json: object members must be [Key Value] pairs"))

(define encode
  Value Options ->
    (let Limits (options Options)
         Out (buffer.builder (fst Limits))
         _ (emit Out Value 0 (snd Limits))
      (buffer.finish Out)))

(define stringify
  Value Options -> (buffer.string (encode Value Options)))

\\ A string, a number or a list is a value, but a value is not one of them without a check, as
\\ json.string and json.array make: those rules go one way.
(datatype json-values
  S : string;
  ___________________________
  S : value;

  N : number;
  ___________________________
  N : value;

  ___________________________
  null : value;

  ___________________________
  true : value;

  ___________________________
  false : value;

  Token : string;
  ===========================
  [number Token] : value;

  Values : (list value);
  ___________________________
  Values : value;

  Key : string; Value : value;
  ===========================
  [Key Value] : member;

  Members : (list member);
  ===========================
  [object | Members] : value;)

(datatype json-options
  N : number;
  ===========================
  [byte-limit N] : option;

  N : number;
  ===========================
  [depth-limit N] : option;)

(declare decode [buffer.view --> [[list option] --> value]])
(declare parse [string --> [[list option] --> value]])
(declare read [io.reader --> [[list option] --> [grammar.read-result value]]])
(declare json.number [string --> value])
(declare json.string [value --> string])
(declare array [value --> [list value]])
(declare integer [value --> number])
(declare encode [value --> [[list option] --> buffer.view]])
(declare stringify [value --> [[list option] --> string]])

)

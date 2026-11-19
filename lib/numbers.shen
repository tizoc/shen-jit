\\ Numbers by kind, for typed code: fixnum and float, types of their own beside number, their
\\ operators, and conversions between the three. Module numbers (docs/numbers.md).
\\
\\ Neither kind is a number, so an arithmetic expression has one type, and code that uses only
\\ number never tries these rules. Every operator and conversion is a small definition over the
\\ primitives, which inlines where it is sealed, and a conversion that changes nothing at run time
\\ inlines to nothing.

(shen.x.namespace numbers
  (use shen-jit)
  (externals [fixnum float fl+ fl- fl* fl/ fl< fl> fl<= fl>= flsqrt fx+ fx- fx* fx< fx> fx<= fx>=
              fxquotient fxremainder fx->fl fl->fx fl->number fx->number fx<-vector fxvector-> fxlimit
              buffer.storage])

\\ Check a literal against the expected kind. A literal with an open type
\\ gets the kernel's number type. The readers give an integer for 2.0.
(datatype t
  if (shen-jit.fixnum? X)
  _______________________
  X : (- fixnum);

  if (and (number? X) (not (shen-jit.fixnum? X)))
  _______________________________________________
  X : (- float);)

\\ Floats. Each operand goes through shen-jit.float, so that from untyped code an integer is
\\ converted and anything else raises: the result is always a float, as the type says.
(define fl+ X Y -> (+ (shen-jit.float X) (shen-jit.float Y)))
(define fl- X Y -> (- (shen-jit.float X) (shen-jit.float Y)))
(define fl* X Y -> (* (shen-jit.float X) (shen-jit.float Y)))
(define fl/ X Y -> (/ (shen-jit.float X) (shen-jit.float Y)))
(define fl< X Y -> (< (shen-jit.float X) (shen-jit.float Y)))
(define fl> X Y -> (> (shen-jit.float X) (shen-jit.float Y)))
(define fl<= X Y -> (<= (shen-jit.float X) (shen-jit.float Y)))
(define fl>= X Y -> (>= (shen-jit.float X) (shen-jit.float Y)))
(define flsqrt X -> (shen-jit.sqrt X))

\\ Fixnums: the operators on numbers, so overflow raises. A quotient truncates towards zero and a
\\ remainder has the dividend's sign; dividing by zero raises.
(define fx+ X Y -> (+ X Y))
(define fx- X Y -> (- X Y))
(define fx* X Y -> (* X Y))
(define fx< X Y -> (< X Y))
(define fx> X Y -> (> X Y))
(define fx<= X Y -> (<= X Y))
(define fx>= X Y -> (>= X Y))
(define fxquotient X Y -> (shen-jit.quotient X Y))
(define fxremainder X Y -> (shen-jit.remainder X Y))

\\ Vectors at fixnum indices, and their length as one.
(define fx<-vector V I -> (<-vector V I))
(define fxvector-> V I X -> (vector-> V I X))
(define fxlimit V -> (limit V))

\\ Conversions: float and fx->fl make a float of an integer, fl->fx truncates a float towards zero,
\\ raising for one outside the fixnums, fixnum checks, and the others change nothing at run time.
(define float N -> (shen-jit.float N))
(define fx->fl N -> (shen-jit.float N))
(define fl->fx X -> (shen-jit.truncate X))
(define fl->number X -> X)
(define fx->number X -> X)
(define fixnum
  N -> N where (shen-jit.fixnum? N)
  N -> (error "~S is not a fixnum" N))

(map (/. F (declare F [float --> [float --> float]]))
     [fl+ fl- fl* fl/])
(map (/. F (declare F [float --> [float --> boolean]]))
     [fl< fl> fl<= fl>=])
(declare flsqrt [float --> float])
(map (/. F (declare F [fixnum --> [fixnum --> fixnum]]))
     [fx+ fx- fx*])
(map (/. F (declare F [fixnum --> [fixnum --> boolean]]))
     [fx< fx> fx<= fx>=])
(declare fxquotient [fixnum --> [fixnum --> fixnum]])
(declare fxremainder [fixnum --> [fixnum --> fixnum]])
(declare fx<-vector [[vector (protect A)] --> [fixnum --> (protect A)]])
(declare fxvector-> [[vector (protect A)] --> [fixnum --> [(protect A) --> [vector (protect A)]]]])
(declare fxlimit [[vector (protect A)] --> fixnum])
(declare float [number --> float])
(declare fx->fl [fixnum --> float])
(declare fl->fx [float --> fixnum])
(declare fl->number [float --> number])
(declare fx->number [fixnum --> number])
(declare fixnum [number --> fixnum])

\\ Bytes, as buffer.storage, the type lib/buffer.shen gives a byte buffer or memory a pointer reaches,
\\ read and written at fixnum offsets: integers as fixnum, doubles as float.
(declare shen-jit.bytes [fixnum --> buffer.storage])
(declare shen-jit.bytes-length [buffer.storage --> fixnum])
(map (/. F (declare F [buffer.storage --> [fixnum --> fixnum]]))
     [shen-jit.u8 shen-jit.u16 shen-jit.u32 shen-jit.s32 shen-jit.s64])
(declare shen-jit.f32 [buffer.storage --> [fixnum --> float]])
(declare shen-jit.f64 [buffer.storage --> [fixnum --> float]])
(map (/. F (declare F [buffer.storage --> [fixnum --> [fixnum --> buffer.storage]]]))
     [shen-jit.u8! shen-jit.u16! shen-jit.u32! shen-jit.s32! shen-jit.s64!])
(declare shen-jit.f32! [buffer.storage --> [fixnum --> [float --> buffer.storage]]])
(declare shen-jit.f64! [buffer.storage --> [fixnum --> [float --> buffer.storage]]])

\\ The bit operations work on fixnums.
(map (/. F (declare F [fixnum --> [fixnum --> fixnum]]))
     [shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.shift-left shen-jit.shift-right shen-jit.rotate32])
(map (/. F (declare F [fixnum --> fixnum]))
     [shen-jit.bit-not shen-jit.bswap32 shen-jit.popcount shen-jit.clz shen-jit.ctz])

(map (fn systemf) [fl+ fl- fl* fl/ fl< fl> fl<= fl>= flsqrt fx+ fx- fx* fx< fx> fx<= fx>=
                   fxquotient fxremainder float fx->fl fl->fx fl->number fx->number fixnum fx<-vector fxvector->
                   fxlimit])

)

\\ Calling C from Shen. It stays out of the image until asked for; load this file under
\\ (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l program.shen
\\
\\ A library is named once, with the file names to try in order. [] means the executable
\\ and what it links, which on Windows reaches nothing, as the executable is static.
\\
\\ (shen-jit.library libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
\\ (define-foreign c-cos libm "cos" (double) --> double)
\\ (define-foreign c-fcntl sockets "fcntl" (int32 int32 int32) --> int32 (varargs 2))
\\ (define-foreign c-recv sockets "recv" (int32 bytes int64 int32) --> int64 blocking)
\\
\\ Each type, as an argument and as a result:
\\
\\   int64           a fixnum; a result must fit one
\\   int32, uint32   a fixnum in range; C's int is int32
\\   double          a number; a new real
\\   string          copied for the call, and a NUL in it raises; copied, and NULL is []
\\   pointer         a pointer of any kind, or [] for NULL; a pointer of kind pointer, or []
\\   bytes           the address of a byte buffer; no result
\\   bool            true or false; the result's low byte
\\   void            no argument; []
\\
\\ At most 6 arguments that are not doubles, and 8 that are. blocking marks a call that may wait,
\\ and changes nothing now: nothing else uses an isolate's heap while it waits.
\\ (varargs N) marks a variadic function with N fixed arguments, 1 to 3, and integers only.
\\
\\ A function is found at its first call, so an image saved with some finds them again, and a
\\ system can declare what it never calls without harm. A pointer saved in an image loads dead,
\\ and raises when given to C, as one does after shen-jit.pointer-kill. A pointer with a length
\\ can be read and written in place: shen-jit.pointer-sized, lib/memory.shen and lib/mmap.shen.
\\ See docs/ffi.md.
\\
\\ The C name, the result and each argument type are expressions, evaluated when the definition
\\ is, which lets one definition suit each system: lib/socket.shen shows how.
\\
\\ C written for Shen is declared with its arity alone, up to 8, and takes and returns values as
\\ they are, with include/shen.h:
\\
\\ (define-foreign-procedure sum-list mine "sum_list" 1)

(shen.x.namespace shen-jit
  \\ This extends the runtime namespace, which stays open for its primitives and other libraries.
  (externals [blocking bool bytes define-foreign define-foreign-procedure double int32 int64
    pointer skip uint32 unknown varargs void])
  (shadow foreign)

(define library
  Name Files -> (do (put Name ffi.files Files) Name))

(define ffi.files
  Library -> (trap-error (get Library ffi.files)
                         (/. E (error "foreign: ~A is not a library: see shen-jit.library" Library))))

\\ A later call in the same file compiles directly if the name's arity is known when it is
\\ read, as for define.
(defmacro ffi-macro
  [define-foreign Name Library CName Types --> Result | Flags]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name (length Types))
             skip)
         (ffi.check-flags Flags)
         [ffi.define Name Library CName (ffi.list Types) Result
                              (element? blocking Flags) (ffi.varargs Flags)])
  [define-foreign | Form]
  -> (error "define-foreign: expected Name Library CName (Types) --> Result Flags, in ~R" Form)
  [define-foreign-procedure Name Library CName Arity]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name Arity)
             skip)
         [ffi.define-procedure Name Library CName Arity])
  [define-foreign-procedure | Form]
  -> (error "define-foreign-procedure: expected Name Library CName Arity, in ~R" Form))

(define ffi.list
  [] -> []
  [X | Xs] -> [cons X (ffi.list Xs)])

(define ffi.check-flags
  [] -> true
  [blocking | Flags] -> (ffi.check-flags Flags)
  [[varargs N] | Flags] -> (ffi.check-flags Flags) where (integer? N)
  [Flag | _] -> (error "define-foreign: ~R is not a flag" Flag))

(define ffi.varargs
  [] -> 0
  [[varargs N] | _] -> N
  [_ | Flags] -> (ffi.varargs Flags))

\\ As ffi.c numbers them.
(define ffi.code
  void -> 0
  int64 -> 1
  int32 -> 2
  uint32 -> 3
  double -> 4
  string -> 5
  pointer -> 6
  bytes -> 7
  bool -> 8
  Type -> (error "foreign: ~R is not a type" Type))

(define ffi.argument
  void -> (error "foreign: void is not an argument type")
  Type -> (ffi.code Type))

(define ffi.result
  bytes -> (error "foreign: bytes is not a result type")
  Type -> (ffi.code Type))

(define ffi.fill
  V _ [] -> V
  V I [X | Xs] -> (ffi.fill (address-> V I X) (+ I 1) Xs))

\\ The description that ffi.c reads, in its order: the name, the library's name and files, the
\\ name in C, the result, the flags, the kind of a pointer returned, and the arguments.
(define ffi.define
  Name _ _ _ _ _ _ -> (error "foreign: ~A is a system function" Name) where (shen.sysfunc? Name)
  Name Library CName Types Result Blocking Varargs
  -> (let N (length Types)
          Flags (+ (if Blocking 1 0) (* 2 Varargs))
          Fields [Name Library (ffi.files Library) CName (ffi.result Result) Flags pointer
                  | (map (/. T (ffi.argument T)) Types)]
          Desc (ffi.fill (absvector (length Fields)) 0 Fields)
       (do (foreign Name Desc)
           (shen.store-arity Name N)
           (ffi.declare Name Types Result)
           Name)))

\\ A procedure has one type of its own, in place of every other.
(define ffi.define-procedure
  Name _ _ _ -> (error "foreign: ~A is a system function" Name) where (shen.sysfunc? Name)
  Name Library CName Arity
  -> (let Fields [Name Library (ffi.files Library) CName 9 0 pointer | (ffi.repeat Arity 9)]
          Desc (ffi.fill (absvector (length Fields)) 0 Fields)
       (do (foreign Name Desc)
           (shen.store-arity Name Arity)
           (destroy Name)
           Name)))

(define ffi.repeat
  0 _ -> []
  N X -> [X | (ffi.repeat (- N 1) X)])

\\ Typed code can use a function at once if each of its types is a plain Shen type. A result
\\ that may be [] is not, nor is a pointer: those are for the program to declare. A type from a
\\ definition before goes either way, as destroy removes only the type.
(define ffi.declare
  Name Types Result -> (let Plain (map (/. T (ffi.plain T)) [string | Types])
                            Out (ffi.plain Result)
                         (if (and (not (element? unknown [Out | Plain])) (not (= Out string)))
                             (declare Name (ffi.type (tl Plain) Out))
                             (destroy Name))))

(define ffi.plain
  int64 -> number
  int32 -> number
  uint32 -> number
  double -> number
  bool -> boolean
  string -> string
  _ -> unknown)

(define ffi.type
  [] Out -> [--> Out]
  [T] Out -> [T --> Out]
  [T | Ts] Out -> [T --> (ffi.type Ts Out)])

(declare library [symbol --> [[list string] --> symbol]])
(declare ffi.define
         [symbol --> [symbol --> [string --> [[list symbol] --> [symbol --> [boolean --> [number --> symbol]]]]]]])
(declare ffi.define-procedure [symbol --> [symbol --> [string --> [number --> symbol]]]])
(declare errno [--> number])
(declare c-errno [--> number])

)

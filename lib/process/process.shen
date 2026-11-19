\\ Subprocesses over our own byte I/O. Module process.
\\ Native code owns OS layouts/handles. Shen owns arguments, environment, pumping and policy.

(shen.x.namespace process
  (use buffer)
  (use clock)
  (use deadline)
  (use io)
  (use option)
  (use result)
  (import result let-ok ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [bool bytes cancel cancelled chunk-size cleanup-timeout clear-environment cwd deadline
    define-foreign define-foreign-procedure environment group inherit int32 library
    pipe posix search-path setup spawn stderr stderr-limit stdin stdout
    stdout-limit terminate terminate-grace timeout transfer wait win32 write])
  (shadow limit stream unit)
  (export running running? exited exited? signalled signalled?
    *adapter-files* child process.close => close kill option pid pipe-until poll result
    process.spawn => spawn status process.stderr => stderr process.stdin => stdin
    process.stdout => stdout process.terminate => terminate process.wait => wait)

(defstruct running)
(defstruct exited (_ : number))
(defstruct signalled (_ : number))

(shen-jit.library adapter
  (trap-error (value *adapter-files*)
    (/. X ["./build/shen-process.so" "./lib/shen-process.so" "./shen-process.so"
           "./build/shen-process.dll" "./lib/shen-process.dll" "./shen-process.dll"])))
(define-foreign c-abi adapter "shen_process_abi" () --> int32)
(define-foreign-procedure c-environment adapter "shen_process_environment" 0)
(define-foreign-procedure c-spawn adapter "shen_process_spawn" 2)
(define-foreign-procedure c-poll adapter "shen_process_poll" 1)
(define-foreign-procedure c-signal adapter "shen_process_signal" 2)
(define-foreign-procedure c-close adapter "shen_process_close" 2)
(define-foreign-procedure c-pipe-close adapter "shen_process_pipe_close" 2)
(define-foreign-procedure c-read adapter "shen_process_read" 2)
(define-foreign-procedure c-write adapter "shen_process_write" 2)
(define-foreign-procedure c-pause adapter "shen_process_pause" 2)
(define-foreign c-compare io.file-win "CompareStringOrdinal" (bytes int32 bytes int32 bool) --> int32)

(define domain
  1 -> posix
  2 -> win32
  _ -> library)

(define reply
  Op Resource Raw ->
    (if (and (absvector? Raw) (= (<-address Raw 0) -1))
        (:err (io.native-error Op (domain (<-address Raw 1))
                               (<-address Raw 2) Resource (<-address Raw 3)))
        (:ok Raw)))

(define native
  Op Resource F ->
    (trap-error (reply Op Resource (thaw F))
      (/. X (:err (io.native-error Op foreign 0 Resource (error-to-string X))))))

(define abi
  -> (if (= (c-abi) 1) true (error "process: incompatible adapter ABI; rebuild with make process")))

(define text
  Text Empty ->
    (let _ (if (string? Text) true (error "process: expected a string"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
         _ (io.file-no-nul Bytes 0 N)
      (if (and (<= N 1048576) (or Empty (> N 0)))
          Text
          (error "process: string is empty or exceeds 1 MiB"))))

(define strings
  [] Count Bytes -> true
  [Text | Rest] Count Bytes ->
    (let _ (text Text true)
         N (+ 1 (shen-jit.bytes-length (shen-jit.string->bytes Text)))
      (if (and (< Count 65536) (<= N Bytes))
          (strings Rest (+ Count 1) (- Bytes N))
          (error "process: argument/environment limit exceeded")))
  _ _ _ -> (error "process: expected a proper list of strings"))

(define process.boolean
  true -> true
  false -> false
  _ -> (error "process: expected a boolean option"))

(define env-name
  Name ->
    (let _ (text Name false)
      (if (element? "=" (explode Name))
          (error "process: environment names cannot contain =")
          Name)))

(define env-options
  [] -> true
  [[Name Value] | Rest] ->
    (do (env-name Name)
        (if (= Value []) true (text Value true))
        (env-options Rest))
  _ -> (error "process: environment overrides must be [Name Value] pairs"))

(define stream-option
  _ inherit -> (io.record [0 ""])
  _ null -> (io.record [1 ""])
  _ pipe -> (io.record [2 ""])
  0 [file Path] -> (io.record [3 (text Path false)])
  _ [file Path] -> (io.record [4 (text Path false)])
  I [append Path] -> (io.record [5 (text Path false)]) where (> I 0)
  _ _ -> (error "process: invalid standard stream option"))

\\ Validated options. The streams vector and its entries are read by the adapter, so they stay
\\ absvectors: one [Kind Path] pair for each of stdin, stdout and stderr.
(define show-config
  C -> (make-string "#<process options ~S>" (config.cwd C)))

(defstruct config
  (printer show-config)
  (mutable cwd)
  (mutable environment)
  (mutable clear-environment)
  streams
  (mutable group)
  (mutable search-path)
  (mutable timeout)
  (mutable cleanup-timeout)
  (mutable stdout-limit)
  (mutable stderr-limit)
  (mutable chunk-size)
  (mutable cancel)
  (mutable terminate-grace))

(define options
  Options Run ->
    (let Mode (if Run pipe inherit)
         Streams (io.record [(stream-option 0 Mode)
                             (stream-option 1 Mode)
                             (stream-option 2 Mode)])
         Config (:config
                  cwd <- "."
                  environment <- []
                  clear-environment <- false
                  streams <- Streams
                  group <- Run
                  search-path <- true
                  timeout <- 30000
                  cleanup-timeout <- 1000
                  stdout-limit <- 1048576
                  stderr-limit <- 1048576
                  chunk-size <- 16384
                  cancel <- (freeze false)
                  terminate-grace <- 100)
      (configure Config Options [] Run)))

(define configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Run ->
    (let _ (if (element? Name Seen) (error "process: duplicate option") true)
         _ (cond ((= Name cwd) (config.cwd-> Config (text Value false)))
                 ((= Name environment) (do (env-options Value) (config.environment-> Config Value)))
                 ((= Name clear-environment)
                   (config.clear-environment-> Config (process.boolean Value)))
                 ((and (not Run) (= Name stdin))
                   (address-> (config.streams Config) 0 (stream-option 0 Value)))
                 ((and (not Run) (= Name stdout))
                   (address-> (config.streams Config) 1 (stream-option 1 Value)))
                 ((and (not Run) (= Name stderr))
                   (address-> (config.streams Config) 2 (stream-option 2 Value)))
                 ((= Name group) (config.group-> Config (process.boolean Value)))
                 ((= Name search-path) (config.search-path-> Config (process.boolean Value)))
                 ((and Run (= Name timeout))
                   (config.timeout-> Config (limit Value 2147483647 false)))
                 ((and Run (= Name cleanup-timeout))
                   (config.cleanup-timeout-> Config (limit Value 60000 true)))
                 ((and Run (= Name stdout-limit))
                   (config.stdout-limit-> Config (limit Value 2305843009213693951 false)))
                 ((and Run (= Name stderr-limit))
                   (config.stderr-limit-> Config (limit Value 2305843009213693951 false)))
                 ((and Run (= Name chunk-size))
                   (config.chunk-size-> Config (limit Value 65536 true)))
                 ((and Run (= Name cancel)) (config.cancel-> Config Value))
                 ((and Run (= Name terminate-grace))
                   (config.terminate-grace-> Config (limit Value 60000 false)))
                 (true (error "process: unknown option ~A" Name)))
      (configure Config Rest [Name | Seen] Run))
  _ _ _ _ -> (error "process: options must be [Name Value] pairs"))

(define find-equals
  Bytes At End ->
    (if (= At End)
        (error "process: invalid inherited environment entry")
        (if (= (shen-jit.u8 Bytes At) 61) At (find-equals Bytes (+ At 1) End))))

(define env-key
  Entry ->
    (let B (shen-jit.string->bytes Entry)
      (shen-jit.bytes->string B 0 (find-equals B 0 (shen-jit.bytes-length B)))))

(define env-same?
  A B ->
    (if (io.file-windows?)
        (let WA (native-name-value (io.file-native-name A))
             WB (native-name-value (io.file-native-name B))
          (= (c-compare WA -1 WB -1 true) 2))
        (= A B)))

(define native-name-value
  (:ok Name) -> Name)

(define env-remove
  _ [] -> []
  Name [Entry | Rest] ->
    (if (env-same? Name (env-key Entry))
        (env-remove Name Rest)
        [Entry | (env-remove Name Rest)]))

(define env-apply
  Entries [] -> Entries
  Entries [[Name Value] | Rest] ->
    (let Kept (env-remove Name Entries)
         Next (if (= Value []) Kept [(cn Name (cn "=" Value)) | Kept])
      (env-apply Next Rest)))

(define process.environment
  Config ->
    (let-ok Entries (if (config.clear-environment Config) (:ok [])
                          (native environment "environment" (freeze (c-environment))))
      (let Result (env-apply Entries (config.environment Config))
           _ (strings Result 0 8388608)
        (:ok Result))))

(define invalidate
  Pointer -> (shen-jit.pointer-kill Pointer))

(define unit
  (:ok _) -> (:ok [])
  (:err Error) -> (:err Error))

\\ A pipe endpoint's context: its native pipe, and the budget and cancellation that pipe-until sets.
(define show-pipe-context
  _ -> "#<process pipe>")

(defstruct pipe-context
  (printer show-pipe-context)
  pointer
  (mutable budget)
  (mutable cancel))

(define pipe-stop
  Context ->
    (cond ((thaw (pipe-context.cancel Context)) (:err (io.native-error transfer cancelled 0
                                               "process pipe" "pipe operation cancelled")))
          ((and (not (= (pipe-context.budget Context) []))
                (deadline.expired? (pipe-context.budget Context)))
            (:err (io.native-error transfer timeout 0 "process pipe" "pipe deadline expired")))
          (true (:ok []))))

(define pipe-read
  Context Bytes ->
    (let-ok _ (pipe-stop Context)
               N (native read "process stdout/stderr"
                   (freeze (c-read (pipe-context.pointer Context) Bytes)))
      (cond ((> N 0) (:ok [N]))
            ((= N 0) (:ok []))
            (true (do (c-pause [(pipe-context.pointer Context)] 20)
                      (pipe-read Context Bytes))))))

(define pipe-write
  Context Bytes ->
    (let-ok _ (pipe-stop Context)
               N (native write "process stdin"
                   (freeze (c-write (pipe-context.pointer Context) Bytes)))
      (if (> N 0)
          (:ok N)
          (do (c-pause [(pipe-context.pointer Context)] 20)
              (pipe-write Context Bytes)))))

(define pipe-close
  Pointer ->
    (unit (native close "process pipe"
                    (freeze (c-pipe-close Pointer (function invalidate))))))

(define pipe-new
  [] _ -> []
  Pointer Direction ->
    (let Context (pipe-context.make Pointer [] (freeze false))
         E (io.endpoint "process pipe" Direction 65536
             (/. B (pipe-read Context B))
             (/. B (pipe-write Context B))
             (freeze (pipe-close Pointer)))
         _ (io.endpoint.guard-> E Pointer)
         _ (io.endpoint.context-> E Context)
      E))

\\ The adapter owns [Token Stdin Stdout Stderr Pid]. The child stores each
\\ Shen endpoint separately because a standard stream need not be piped.
(define status-text
  (:running) -> "running"
  (:exited N) -> (make-string "exited ~A" N)
  (:signalled N) -> (make-string "signalled ~A" N)
  S -> (make-string "~S" S))

(define show-child
  C -> (make-string "#<child ~A ~A>" (native-pid (child.raw C))
                    (if (child.closed C) "closed" (status-text (child.status C)))))

(defstruct child
  (printer show-child)
  (raw : native-child)
  (program : string)
  (input : (option.t io.endpoint))
  (output : (option.t io.endpoint))
  (diagnostics : (option.t io.endpoint))
  (mutable closed : boolean)
  (mutable close-result : (option.t (result.t (io.error * result.empty))))
  (mutable busy : boolean)
  (mutable status : status)
  (group : boolean))

(preclude [child.%match])

(define pipe-option
  [] -> []
  E -> [E])

\\ The native spawn constructs this record before starting the child, so allocation failure is safe.
(define child-new
  Program Group Raw ->
    (:child
      raw <- Raw
      program <- Program
      input <- (pipe-option (pipe-new (<-address Raw 1) write))
      output <- (pipe-option (pipe-new (<-address Raw 2) read))
      diagnostics <- (pipe-option (pipe-new (<-address Raw 3) read))
      closed <- false
      close-result <- []
      busy <- false
      status <- (:running)
      group <- Group))

(define optional-pipe
  Child 0 -> (pipe-value (child.input Child))
  Child 1 -> (pipe-value (child.output Child))
  Child 2 -> (pipe-value (child.diagnostics Child)))

(define pipe-value
  [E] -> E
  [] -> [])

(define pipe-until
  E Budget Cancel ->
    (let _ (io.check E (io.endpoint.mode E) [])
         Context (io.endpoint.context E)
         _ (if (pipe-context? Context) true (error "process: not a process pipe"))
         _ (deadline.check Budget)
         _ (pipe-context.budget-> Context Budget)
         _ (pipe-context.cancel-> Context Cancel)
      E))

(define spawn-config
  Program Args Config ->
    (let _ (text Program false)
         _ (strings Args 1 8388608)
         Home (value *home-directory*)
      (trap-error
        (do (abi)
            (let-ok Env (process.environment Config)
              (spawn-native Program Args Config Home Env)))
        (/. X (:err (io.native-error spawn foreign 0 Program (error-to-string X)))))))

(define spawn-native
  Program Args Config Home Env ->
    (spawn-with Program Args Config Home Env
      (/. Raw (:ok (child-new Program (config.group Config) Raw)))))

(define spawn-with
  Program Args Config Home Env Constructor ->
    (let Cwd (io.file-path-at (config.cwd Config) Home)
      (trap-error
        (let Raw (c-spawn
                   (io.record [Program Args Env Cwd (config.streams Config)
                               (config.group Config) (config.search-path Config)]) Constructor)
          (if (result.ok? Raw) Raw (reply spawn Program Raw)))
        (/. X (:err (io.native-error spawn foreign 0 Program (error-to-string X)))))))

(define ready
  -> (unit (native setup "process adapter" (freeze (abi)))))

(define process.spawn
  Program Args Options -> (spawn-config Program Args (options Options false)))

(define status-native
  Raw -> (cond ((= (<-address Raw 0) 0) (:running))
               ((= (<-address Raw 0) 1) (:exited (<-address Raw 1)))
               (true (:signalled (<-address Raw 1)))))

(define poll
  Child ->
    (let Token (live Child)
      (let-ok Raw (native wait (child.program Child) (freeze (c-poll Token)))
        (let Status (status-native Raw)
             _ (child.status-> Child Status)
          (:ok Status)))))

(define signal
  Child Force ->
    (let Token (live Child)
      (unit (native terminate (child.program Child)
                      (freeze (c-signal Token Force))))))

(define process.terminate
  Child -> (signal Child false))

(define kill
  Child -> (signal Child true))

(define process.close
  Child ->
    (let _ (check Child)
      (if (child.closed Child)
          (hd (child.close-result Child))
          (let Token (live Child)
               _ (if (child.busy Child) (error "process: communication is in progress") true)
            (let-ok Status (poll Child)
              (if (running? Status)
                  (:err (io.error close (child.program Child)
                                   "wait for the child before closing it"))
                  (let Pipes (close-pipes [(child.input Child)
                                            (child.output Child)
                                            (child.diagnostics Child)]
                                           (:ok []))
                       Closed (unit
                                (native close (child.program Child)
                                  (freeze (c-close Token (function invalidate)))))
                       Result (io.finish Pipes Closed)
                       _ (child.closed-> Child true)
                       _ (child.close-result-> Child [Result])
                    Result)))))))

(datatype status
  X : running;
  _______________
  X : (- status);

  X : exited;
  _______________
  X : (- status);

  Code : number >> Goal;
  ____________________
  (:exited Code) : status >> Goal;

  X : signalled;
  _______________
  X : (- status);

  Signal : number >> Goal;
  ____________________
  (:signalled Signal) : status >> Goal;)

(datatype t
  ____________________________
  inherit : (- stream);

  ____________________________
  null : (- stream);

  ____________________________
  pipe : (- stream);

  Path : string;
  ____________________________
  [file Path] : (- stream);

  Path : string >> Goal;
  ____________________________
  [file Path] : stream >> Goal;

  Path : string;
  ____________________________
  [append Path] : (- stream);

  Path : string >> Goal;
  ____________________________
  [append Path] : stream >> Goal;

  Name : string; Value : string;
  ____________________________
  [Name Value] : env-setting;

  Name : string;
  ____________________________
  [Name []] : env-setting;

  Path : string;
  ____________________________
  [cwd Path] : option;

  Settings : (list env-setting);
  ____________________________
  [environment Settings] : option;

  B : boolean;
  ____________________________
  [clear-environment B] : option;

  B : boolean;
  ____________________________
  [group B] : option;

  B : boolean;
  ____________________________
  [search-path B] : option;

  S : stream;
  ____________________________
  [stdin S] : option;

  S : stream;
  ____________________________
  [stdout S] : option;

  S : stream;
  ____________________________
  [stderr S] : option;)

\\ (process.result A) is (result.t ((io.error * (list report)) * A)): an (:ok V), or an (:err (@p E Reports))
\\ with the reports of what had started, [] if nothing had. The library declares the long form, as
\\ declare keeps a type as it is written.
(synonyms (result A) (result.t ((io.error * (list report)) * A)))

(define native-pid
  Raw -> (<-address Raw 4))

(define native-token
  Raw -> (<-address Raw 0))

(declare native-pid [native-child --> number])
(declare native-token [native-child --> buffer.storage])
(declare c-pause [[list buffer.storage] --> [number --> boolean]])

(declare process.spawn [string --> [[list string] --> [[list option] --> [result.t [io.error * child]]]]])
(declare poll [child --> [result.t [io.error * status]]])
(declare process.terminate [child --> [result.t [io.error * result.empty]]])
(declare kill [child --> [result.t [io.error * result.empty]]])
(declare process.close [child --> [result.t [io.error * result.empty]]])
(declare pipe-until [io.endpoint --> [deadline --> [[lazy boolean] --> io.endpoint]]])

)

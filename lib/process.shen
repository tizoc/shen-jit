\\ Subprocesses over our own byte I/O. Load ffi, buffer, io, io-file, deadline and clock first.
\\ Native code owns OS layouts/handles. Shen owns arguments, environment, pumping and policy.

(shen.x.namespace process
  (use buffer)
  (use clock)
  (use deadline)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [bool bytes cancel cancelled chunk-size cleanup-timeout clear-environment cwd
    deadline define-foreign define-foreign-procedure environment eof exited group inherit int32
    library ok pending pipe posix process-environment-settings process-options process-results
    process-statuses process-streams process-wait-results running search-path setup signalled
    spawn stderr stderr-limit stdin stdout stdout-limit terminate terminate-grace timeout transfer
    wait win32 write written])
  (shadow limit stream unit)
  (export *adapter-files* child process.close => close kill option pid pipe-until poll result
    process.spawn => spawn status process.stderr => stderr process.stdin => stdin
    process.stdout => stdout process.terminate => terminate process.wait => wait wait-result)

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
        [error (io.native-error Op (domain (<-address Raw 1))
                               (<-address Raw 2) Resource (<-address Raw 3))]
        [ok Raw]))

(define native
  Op Resource F ->
    (trap-error (reply Op Resource (thaw F))
      (/. X [error (io.native-error Op foreign 0 Resource (error-to-string X))])))

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

(define limit
  Value Maximum Positive ->
    (let N (buffer.index Value)
      (if (and (<= N Maximum) (or (not Positive) (> N 0)))
          N
          (error "process: option is outside its supported range"))))

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
        (let WA (hd (tl (io.file-native-name A)))
             WB (hd (tl (io.file-native-name B)))
          (= (c-compare WA -1 WB -1 true) 2))
        (= A B)))

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
    (io.let-ok Entries (if (config.clear-environment Config) [ok []]
                          (native environment "environment" (freeze (c-environment))))
      (let Result (env-apply Entries (config.environment Config))
           _ (strings Result 0 8388608)
        [ok Result])))

(define invalidate
  Pointer -> (shen-jit.pointer-kill Pointer))

(define unit
  [ok _] -> [ok]
  [error Error] -> [error Error])

(define finish-unit
  [ok] Result -> Result
  [error Error] [ok] -> [error Error]
  [error Error] [error Other] -> [error (io.secondary Error Other)])

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
    (cond ((thaw (pipe-context.cancel Context)) [error (io.native-error transfer cancelled 0
                                               "process pipe" "pipe operation cancelled")])
          ((and (not (= (pipe-context.budget Context) []))
                (deadline.expired? (pipe-context.budget Context)))
            [error (io.native-error transfer timeout 0 "process pipe" "pipe deadline expired")])
          (true [ok])))

(define pipe-read
  Context Bytes ->
    (io.let-ok _ (pipe-stop Context)
               N (native read "process stdout/stderr"
                   (freeze (c-read (pipe-context.pointer Context) Bytes)))
      (cond ((> N 0) [read N])
            ((= N 0) [eof])
            (true (do (c-pause [(pipe-context.pointer Context)] 20)
                      (pipe-read Context Bytes))))))

(define pipe-write
  Context Bytes ->
    (io.let-ok _ (pipe-stop Context)
               N (native write "process stdin"
                   (freeze (c-write (pipe-context.pointer Context) Bytes)))
      (if (> N 0)
          [written N]
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

\\ A child handle. Raw is the adapter's [Token Stdin Stdout Stderr Pid]; Pipes holds the stdin,
\\ stdout and stderr endpoints, or [], indexed by stream number.
(define status-text
  [running] -> "running"
  [exited N] -> (make-string "exited ~A" N)
  [signalled N] -> (make-string "signalled ~A" N)
  S -> (make-string "~S" S))

(define show-child
  C -> (make-string "#<child ~A ~A>" (<-address (subprocess.raw C) 4)
                    (if (subprocess.closed C) "closed" (status-text (subprocess.status C)))))

(defstruct subprocess
  (printer show-child)
  raw
  program
  pipes
  (mutable closed)
  (mutable close-result)
  (mutable busy)
  (mutable status)
  group)

\\ The native spawn constructs this record before starting the child, so allocation failure is safe.
(define child-new
  Program Group Raw ->
    (let Pipes (io.record [(pipe-new (<-address Raw 1) write)
                          (pipe-new (<-address Raw 2) read)
                          (pipe-new (<-address Raw 3) read)])
      (:subprocess
        raw <- Raw
        program <- Program
        pipes <- Pipes
        closed <- false
        close-result <- []
        busy <- false
        status <- [running]
        group <- Group)))

(define check
  Child -> (if (subprocess? Child) Child (error "process: not a child handle")))

(define live
  Child ->
    (let _ (check Child)
         Token (<-address (subprocess.raw Child) 0)
      (if (or (subprocess.closed Child) (= (shen-jit.pointer-address Token) 0))
          (error "process: child is closed or stale")
          Token)))

(define pid
  Child -> (<-address (subprocess.raw (check Child)) 4))

(define stream
  Child Index ->
    (let _ (live Child)
         E (<-address (subprocess.pipes Child) Index)
      (if (= E []) (error "process: standard stream was not piped") E)))

(define process.stdin
  Child -> (stream Child 0))

(define process.stdout
  Child -> (stream Child 1))

(define process.stderr
  Child -> (stream Child 2))

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
            (io.let-ok Env (process.environment Config)
              (spawn-native Program Args Config Home Env)))
        (/. X [error (io.native-error spawn foreign 0 Program (error-to-string X))]))))

(define spawn-native
  Program Args Config Home Env ->
    (spawn-with Program Args Config Home Env
      (/. Raw [ok (child-new Program (config.group Config) Raw)])))

(define spawn-with
  Program Args Config Home Env Constructor ->
    (let Cwd (io.file-path-at (config.cwd Config) Home)
      (trap-error
        (let Raw (c-spawn
                   (io.record [Program Args Env Cwd (config.streams Config)
                               (config.group Config) (config.search-path Config)]) Constructor)
          (if (absvector? Raw) (reply spawn Program Raw) Raw))
        (/. X [error (io.native-error spawn foreign 0 Program (error-to-string X))]))))

(define ready
  -> (unit (native setup "process adapter" (freeze (abi)))))

(define process.spawn
  Program Args Options -> (spawn-config Program Args (options Options false)))

(define status-native
  Raw -> (cond ((= (<-address Raw 0) 0) [running])
               ((= (<-address Raw 0) 1) [exited (<-address Raw 1)])
               (true [signalled (<-address Raw 1)])))

(define poll
  Child ->
    (let Token (live Child)
      (io.let-ok Raw (native wait (subprocess.program Child) (freeze (c-poll Token)))
        (let Status (status-native Raw)
             _ (subprocess.status-> Child Status)
          [ok Status]))))

(define wait-loop
  Child Budget ->
    (io.let-ok Status (poll Child)
      (cond ((not (= Status [running])) [ok Status])
            ((deadline.expired? Budget) [pending])
            (true (do (c-pause [] (deadline.slice Budget 20))
                      (wait-loop Child Budget))))))

(define process.wait
  Child Milliseconds ->
    (do (live Child)
        (limit Milliseconds 2147483647 false)
        (wait-loop Child (clock.deadline Milliseconds))))

(define signal
  Child Force ->
    (let Token (live Child)
      (unit (native terminate (subprocess.program Child)
                      (freeze (c-signal Token Force))))))

(define process.terminate
  Child -> (signal Child false))

(define kill
  Child -> (signal Child true))

(define close-pipes
  Pipes At At Result -> Result
  Pipes At End Result ->
    (let E (<-address Pipes At)
         Closed (if (= E []) [ok] (io.close E))
      (close-pipes Pipes (+ At 1) End (finish-unit Result Closed))))

(define process.close
  Child ->
    (let _ (check Child)
      (if (subprocess.closed Child)
          (subprocess.close-result Child)
          (let Token (live Child)
               _ (if (subprocess.busy Child) (error "process: communication is in progress") true)
            (io.let-ok Status (poll Child)
              (if (= Status [running])
                  [error (io.error close (subprocess.program Child)
                                   "wait for the child before closing it")]
                  (let Pipes (close-pipes (subprocess.pipes Child) 0 3 [ok])
                       Closed (unit
                                (native close (subprocess.program Child)
                                  (freeze (c-close Token (function invalidate)))))
                       Result (finish-unit Pipes Closed)
                       _ (subprocess.closed-> Child true)
                       _ (subprocess.close-result-> Child Result)
                    Result)))))))

(datatype process-streams
  ____________________________
  inherit : stream;

  ____________________________
  null : stream;

  ____________________________
  pipe : stream;

  Path : string;
  ============================
  [file Path] : stream;

  Path : string;
  ============================
  [append Path] : stream;)

(datatype process-environment-settings
  Name : string; Value : string;
  ============================
  [Name Value] : env-setting;

  Name : string;
  ============================
  [Name []] : env-setting;)

(datatype process-options
  Path : string;
  ============================
  [cwd Path] : option;

  Settings : (list env-setting);
  ============================
  [environment Settings] : option;

  B : boolean;
  ============================
  [clear-environment B] : option;

  B : boolean;
  ============================
  [group B] : option;

  B : boolean;
  ============================
  [search-path B] : option;

  S : stream;
  ============================
  [stdin S] : option;

  S : stream;
  ============================
  [stdout S] : option;

  S : stream;
  ============================
  [stderr S] : option;

  N : number;
  ============================
  [timeout N] : option;

  N : number;
  ============================
  [cleanup-timeout N] : option;

  N : number;
  ============================
  [terminate-grace N] : option;

  N : number;
  ============================
  [stdout-limit N] : option;

  N : number;
  ============================
  [stderr-limit N] : option;

  N : number;
  ============================
  [chunk-size N] : option;

  F : (lazy boolean);
  ============================
  [cancel F] : option;)

(datatype process-statuses
  ____________________________
  [running] : status;

  N : number;
  ============================
  [exited N] : status;

  N : number;
  ============================
  [signalled N] : status;)

(datatype process-wait-results
  S : status;
  ============================
  [ok S] : wait-result;

  ____________________________
  [pending] : wait-result;

  E : io.error;
  ============================
  [error E] : wait-result;)

(datatype process-results
  Value : A;
  ============================
  [ok Value] : (result A);

  E : io.error;
  ============================
  [error E] : (result A);

  E : io.error; Partial : A;
  ============================
  [error E Partial] : (result A);)

(declare process.spawn [string --> [[list string] --> [[list option] --> [io.result child]]]])
(declare pid [child --> number])
(declare process.stdin [child --> io.endpoint])
(declare process.stdout [child --> io.endpoint])
(declare process.stderr [child --> io.endpoint])
(declare poll [child --> [io.result status]])
(declare process.wait [child --> [number --> wait-result]])
(declare process.terminate [child --> io.close-result])
(declare kill [child --> io.close-result])
(declare process.close [child --> io.close-result])
(declare pipe-until [io.endpoint --> [deadline --> [[lazy boolean] --> io.endpoint]]])

)

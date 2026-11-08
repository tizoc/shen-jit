\\ Subprocesses over our own byte I/O. Load ffi, buffer, io, io-file, deadline and clock first.
\\ Native code owns OS layouts/handles. Shen owns arguments, environment, pumping and policy.

(shen-jit.library process.adapter
  (trap-error (value process.*adapter-files*)
    (/. X ["./build/shen-process.so" "./lib/shen-process.so" "./shen-process.so"
           "./build/shen-process.dll" "./lib/shen-process.dll" "./shen-process.dll"])))
(define-foreign process.c-abi process.adapter "shen_process_abi" () --> int32)
(define-foreign-procedure process.c-environment process.adapter "shen_process_environment" 0)
(define-foreign-procedure process.c-spawn process.adapter "shen_process_spawn" 2)
(define-foreign-procedure process.c-poll process.adapter "shen_process_poll" 1)
(define-foreign-procedure process.c-signal process.adapter "shen_process_signal" 2)
(define-foreign-procedure process.c-close process.adapter "shen_process_close" 2)
(define-foreign-procedure process.c-pipe-close process.adapter "shen_process_pipe_close" 2)
(define-foreign-procedure process.c-read process.adapter "shen_process_read" 2)
(define-foreign-procedure process.c-write process.adapter "shen_process_write" 2)
(define-foreign-procedure process.c-pause process.adapter "shen_process_pause" 2)
(define-foreign process.c-compare io.file-win "CompareStringOrdinal" (bytes int32 bytes int32 bool) --> int32)

(define process.domain
  1 -> posix
  2 -> win32
  _ -> library)

(define process.reply
  Op Resource Raw ->
    (if (and (absvector? Raw) (= (<-address Raw 0) -1))
        [error (io.native-error Op (process.domain (<-address Raw 1))
                               (<-address Raw 2) Resource (<-address Raw 3))]
        [ok Raw]))

(define process.native
  Op Resource F ->
    (trap-error (process.reply Op Resource (thaw F))
      (/. X [error (io.native-error Op foreign 0 Resource (error-to-string X))])))

(define process.abi
  -> (if (= (process.c-abi) 1) true (error "process: incompatible adapter ABI; rebuild with make process")))

(define process.text
  Text Empty ->
    (let _ (if (string? Text) true (error "process: expected a string"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
         _ (io.file-no-nul Bytes 0 N)
      (if (and (<= N 1048576) (or Empty (> N 0)))
          Text
          (error "process: string is empty or exceeds 1 MiB"))))

(define process.strings
  [] Count Bytes -> true
  [Text | Rest] Count Bytes ->
    (let _ (process.text Text true)
         N (+ 1 (shen-jit.bytes-length (shen-jit.string->bytes Text)))
      (if (and (< Count 65536) (<= N Bytes))
          (process.strings Rest (+ Count 1) (- Bytes N))
          (error "process: argument/environment limit exceeded")))
  _ _ _ -> (error "process: expected a proper list of strings"))

(define process.boolean
  true -> true
  false -> false
  _ -> (error "process: expected a boolean option"))

(define process.limit
  Value Maximum Positive ->
    (let N (buffer.index Value)
      (if (and (<= N Maximum) (or (not Positive) (> N 0)))
          N
          (error "process: option is outside its supported range"))))

(define process.env-name
  Name ->
    (let _ (process.text Name false)
      (if (element? "=" (explode Name))
          (error "process: environment names cannot contain =")
          Name)))

(define process.env-options
  [] -> true
  [[Name Value] | Rest] ->
    (do (process.env-name Name)
        (if (= Value []) true (process.text Value true))
        (process.env-options Rest))
  _ -> (error "process: environment overrides must be [Name Value] pairs"))

(define process.stream-option
  _ inherit -> (io.record [0 ""])
  _ null -> (io.record [1 ""])
  _ pipe -> (io.record [2 ""])
  0 [file Path] -> (io.record [3 (process.text Path false)])
  _ [file Path] -> (io.record [4 (process.text Path false)])
  I [append Path] -> (io.record [5 (process.text Path false)]) where (> I 0)
  _ _ -> (error "process: invalid standard stream option"))

\\ cwd, overrides, clear environment, streams, group, search, timeout, cleanup timeout,
\\ stdout limit, stderr limit, chunk size, cancellation predicate, termination grace.
(define process.options
  Options Run ->
    (let Mode (if Run pipe inherit)
         Streams (io.record [(process.stream-option 0 Mode)
                             (process.stream-option 1 Mode)
                             (process.stream-option 2 Mode)])
         Config (io.record ["." [] false Streams Run true 30000 1000 1048576 1048576 16384
                            (freeze false) 100])
      (process.configure Config Options [] Run)))

(define process.configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Run ->
    (let _ (if (element? Name Seen) (error "process: duplicate option") true)
         _ (cond ((= Name cwd) (address-> Config 0 (process.text Value false)))
                 ((= Name environment) (do (process.env-options Value) (address-> Config 1 Value)))
                 ((= Name clear-environment) (address-> Config 2 (process.boolean Value)))
                 ((and (not Run) (= Name stdin))
                   (address-> (<-address Config 3) 0 (process.stream-option 0 Value)))
                 ((and (not Run) (= Name stdout))
                   (address-> (<-address Config 3) 1 (process.stream-option 1 Value)))
                 ((and (not Run) (= Name stderr))
                   (address-> (<-address Config 3) 2 (process.stream-option 2 Value)))
                 ((= Name group) (address-> Config 4 (process.boolean Value)))
                 ((= Name search-path) (address-> Config 5 (process.boolean Value)))
                 ((and Run (= Name timeout))
                   (address-> Config 6 (process.limit Value 2147483647 false)))
                 ((and Run (= Name cleanup-timeout))
                   (address-> Config 7 (process.limit Value 60000 true)))
                 ((and Run (= Name stdout-limit))
                   (address-> Config 8 (process.limit Value 2305843009213693951 false)))
                 ((and Run (= Name stderr-limit))
                   (address-> Config 9 (process.limit Value 2305843009213693951 false)))
                 ((and Run (= Name chunk-size))
                   (address-> Config 10 (process.limit Value 65536 true)))
                 ((and Run (= Name cancel)) (address-> Config 11 Value))
                 ((and Run (= Name terminate-grace))
                   (address-> Config 12 (process.limit Value 60000 false)))
                 (true (error "process: unknown option ~A" Name)))
      (process.configure Config Rest [Name | Seen] Run))
  _ _ _ _ -> (error "process: options must be [Name Value] pairs"))

(define process.find-equals
  Bytes At End ->
    (if (= At End)
        (error "process: invalid inherited environment entry")
        (if (= (shen-jit.u8 Bytes At) 61) At (process.find-equals Bytes (+ At 1) End))))

(define process.env-key
  Entry ->
    (let B (shen-jit.string->bytes Entry)
      (shen-jit.bytes->string B 0 (process.find-equals B 0 (shen-jit.bytes-length B)))))

(define process.env-same?
  A B ->
    (if (io.file-windows?)
        (let WA (hd (tl (io.file-native-name A)))
             WB (hd (tl (io.file-native-name B)))
          (= (process.c-compare WA -1 WB -1 true) 2))
        (= A B)))

(define process.env-remove
  _ [] -> []
  Name [Entry | Rest] ->
    (if (process.env-same? Name (process.env-key Entry))
        (process.env-remove Name Rest)
        [Entry | (process.env-remove Name Rest)]))

(define process.env-apply
  Entries [] -> Entries
  Entries [[Name Value] | Rest] ->
    (let Kept (process.env-remove Name Entries)
         Next (if (= Value []) Kept [(cn Name (cn "=" Value)) | Kept])
      (process.env-apply Next Rest)))

(define process.environment
  Config ->
    (io.let-ok Entries (if (<-address Config 2) [ok []]
                          (process.native environment "environment" (freeze (process.c-environment))))
      (let Result (process.env-apply Entries (<-address Config 1))
           _ (process.strings Result 0 8388608)
        [ok Result])))

(define process.invalidate
  Pointer -> (shen-jit.pointer-kill Pointer))

(define process.unit
  [ok _] -> [ok]
  [error Error] -> [error Error])

(define process.finish-unit
  [ok] Result -> Result
  [error Error] [ok] -> [error Error]
  [error Error] [error Other] -> [error (io.secondary Error Other)])

(define process.pipe-stop
  Context ->
    (cond ((thaw (<-address Context 3)) [error (io.native-error transfer cancelled 0
                                               "process pipe" "pipe operation cancelled")])
          ((and (not (= (<-address Context 2) [])) (deadline.expired? (<-address Context 2)))
            [error (io.native-error transfer timeout 0 "process pipe" "pipe deadline expired")])
          (true [ok])))

(define process.pipe-read
  Context Bytes ->
    (io.let-ok _ (process.pipe-stop Context)
               N (process.native read "process stdout/stderr"
                   (freeze (process.c-read (<-address Context 1) Bytes)))
      (cond ((> N 0) [read N])
            ((= N 0) [eof])
            (true (do (process.c-pause [(<-address Context 1)] 20)
                      (process.pipe-read Context Bytes))))))

(define process.pipe-write
  Context Bytes ->
    (io.let-ok _ (process.pipe-stop Context)
               N (process.native write "process stdin"
                   (freeze (process.c-write (<-address Context 1) Bytes)))
      (if (> N 0)
          [written N]
          (do (process.c-pause [(<-address Context 1)] 20)
              (process.pipe-write Context Bytes)))))

(define process.pipe-close
  Pointer ->
    (process.unit (process.native close "process pipe"
                    (freeze (process.c-pipe-close Pointer (function process.invalidate))))))

(define process.pipe-new
  [] _ -> []
  Pointer Direction ->
    (let Context (io.record [process.pipe-context Pointer [] (freeze false)])
         E (io.endpoint "process pipe" Direction 65536
             (/. B (process.pipe-read Context B))
             (/. B (process.pipe-write Context B))
             (freeze (process.pipe-close Pointer)))
         _ (address-> E 12 Pointer)
         _ (address-> E 13 Context)
      E))

\\ The native spawn constructs this record before starting the child, so allocation failure is safe.
(define process.child-new
  Program Group Raw ->
    (let Pipes (io.record [(process.pipe-new (<-address Raw 1) write)
                          (process.pipe-new (<-address Raw 2) read)
                          (process.pipe-new (<-address Raw 3) read)])
      (io.record [process.child Raw Program Pipes false [] false [running] Group])))

(define process.check
  Child -> (if (io.tag? Child process.child) Child (error "process: not a child handle")))

(define process.live
  Child ->
    (let _ (process.check Child)
         Token (<-address (<-address Child 1) 0)
      (if (or (<-address Child 4) (= (shen-jit.pointer-address Token) 0))
          (error "process: child is closed or stale")
          Token)))

(define process.pid
  Child -> (<-address (<-address (process.check Child) 1) 4))

(define process.stream
  Child Index ->
    (let _ (process.live Child)
         E (<-address (<-address Child 3) Index)
      (if (= E []) (error "process: standard stream was not piped") E)))

(define process.stdin
  Child -> (process.stream Child 0))

(define process.stdout
  Child -> (process.stream Child 1))

(define process.stderr
  Child -> (process.stream Child 2))

(define process.pipe-until
  E Budget Cancel ->
    (let _ (io.check E (<-address E 2) [])
         Context (<-address E 13)
         _ (if (io.tag? Context process.pipe-context) true (error "process: not a process pipe"))
         _ (deadline.check Budget)
         _ (address-> Context 2 Budget)
         _ (address-> Context 3 Cancel)
      E))

(define process.spawn-config
  Program Args Config ->
    (let _ (process.text Program false)
         _ (process.strings Args 1 8388608)
         Home (value *home-directory*)
      (trap-error
        (do (process.abi)
            (io.let-ok Env (process.environment Config)
              (process.spawn-native Program Args Config Home Env)))
        (/. X [error (io.native-error spawn foreign 0 Program (error-to-string X))]))))

(define process.spawn-native
  Program Args Config Home Env ->
    (process.spawn-with Program Args Config Home Env
      (/. Raw [ok (process.child-new Program (<-address Config 4) Raw)])))

(define process.spawn-with
  Program Args Config Home Env Constructor ->
    (let Cwd (io.file-path-at (<-address Config 0) Home)
      (trap-error
        (let Raw (process.c-spawn
                   (io.record [Program Args Env Cwd (<-address Config 3)
                               (<-address Config 4) (<-address Config 5)]) Constructor)
          (if (absvector? Raw) (process.reply spawn Program Raw) Raw))
        (/. X [error (io.native-error spawn foreign 0 Program (error-to-string X))]))))

(define process.ready
  -> (process.unit (process.native setup "process adapter" (freeze (process.abi)))))

(define process.spawn
  Program Args Options -> (process.spawn-config Program Args (process.options Options false)))

(define process.status-native
  Raw -> (cond ((= (<-address Raw 0) 0) [running])
               ((= (<-address Raw 0) 1) [exited (<-address Raw 1)])
               (true [signalled (<-address Raw 1)])))

(define process.poll
  Child ->
    (let Token (process.live Child)
      (io.let-ok Raw (process.native wait (<-address Child 2) (freeze (process.c-poll Token)))
        (let Status (process.status-native Raw)
             _ (address-> Child 7 Status)
          [ok Status]))))

(define process.wait-loop
  Child Budget ->
    (io.let-ok Status (process.poll Child)
      (cond ((not (= Status [running])) [ok Status])
            ((deadline.expired? Budget) [pending])
            (true (do (process.c-pause [] (deadline.slice Budget 20))
                      (process.wait-loop Child Budget))))))

(define process.wait
  Child Milliseconds ->
    (do (process.live Child)
        (process.limit Milliseconds 2147483647 false)
        (process.wait-loop Child (clock.deadline Milliseconds))))

(define process.signal
  Child Force ->
    (let Token (process.live Child)
      (process.unit (process.native terminate (<-address Child 2)
                      (freeze (process.c-signal Token Force))))))

(define process.terminate
  Child -> (process.signal Child false))

(define process.kill
  Child -> (process.signal Child true))

(define process.close-pipes
  Pipes At At Result -> Result
  Pipes At End Result ->
    (let E (<-address Pipes At)
         Closed (if (= E []) [ok] (io.close E))
      (process.close-pipes Pipes (+ At 1) End (process.finish-unit Result Closed))))

(define process.close
  Child ->
    (let _ (process.check Child)
      (if (<-address Child 4)
          (<-address Child 5)
          (let Token (process.live Child)
               _ (if (<-address Child 6) (error "process: communication is in progress") true)
            (io.let-ok Status (process.poll Child)
              (if (= Status [running])
                  [error (io.error close (<-address Child 2) "wait for the child before closing it")]
                  (let Pipes (process.close-pipes (<-address Child 3) 0 3 [ok])
                       Closed (process.unit
                                (process.native close (<-address Child 2)
                                  (freeze (process.c-close Token (function process.invalidate)))))
                       Result (process.finish-unit Pipes Closed)
                       _ (address-> Child 4 true)
                       _ (address-> Child 5 Result)
                    Result)))))))

(datatype process-streams
  ____________________________
  inherit : process.stream;

  ____________________________
  null : process.stream;

  ____________________________
  pipe : process.stream;

  Path : string;
  ============================
  [file Path] : process.stream;

  Path : string;
  ============================
  [append Path] : process.stream;)

(datatype process-environment-settings
  Name : string; Value : string;
  ============================
  [Name Value] : process.env-setting;

  Name : string;
  ============================
  [Name []] : process.env-setting;)

(datatype process-options
  Path : string;
  ============================
  [cwd Path] : process.option;

  Settings : (list process.env-setting);
  ============================
  [environment Settings] : process.option;

  B : boolean;
  ============================
  [clear-environment B] : process.option;

  B : boolean;
  ============================
  [group B] : process.option;

  B : boolean;
  ============================
  [search-path B] : process.option;

  S : process.stream;
  ============================
  [stdin S] : process.option;

  S : process.stream;
  ============================
  [stdout S] : process.option;

  S : process.stream;
  ============================
  [stderr S] : process.option;

  N : number;
  ============================
  [timeout N] : process.option;

  N : number;
  ============================
  [cleanup-timeout N] : process.option;

  N : number;
  ============================
  [terminate-grace N] : process.option;

  N : number;
  ============================
  [stdout-limit N] : process.option;

  N : number;
  ============================
  [stderr-limit N] : process.option;

  N : number;
  ============================
  [chunk-size N] : process.option;

  F : (lazy boolean);
  ============================
  [cancel F] : process.option;)

(datatype process-statuses
  ____________________________
  [running] : process.status;

  N : number;
  ============================
  [exited N] : process.status;

  N : number;
  ============================
  [signalled N] : process.status;)

(datatype process-wait-results
  S : process.status;
  ============================
  [ok S] : process.wait-result;

  ____________________________
  [pending] : process.wait-result;

  E : io.error;
  ============================
  [error E] : process.wait-result;)

(datatype process-results
  Value : A;
  ============================
  [ok Value] : (process.result A);

  E : io.error;
  ============================
  [error E] : (process.result A);

  E : io.error; Partial : A;
  ============================
  [error E Partial] : (process.result A);)

(declare process.spawn [string --> [[list string] --> [[list process.option] --> [io.result process.child]]]])
(declare process.pid [process.child --> number])
(declare process.stdin [process.child --> io.endpoint])
(declare process.stdout [process.child --> io.endpoint])
(declare process.stderr [process.child --> io.endpoint])
(declare process.poll [process.child --> [io.result process.status]])
(declare process.wait [process.child --> [number --> process.wait-result]])
(declare process.terminate [process.child --> io.close-result])
(declare process.kill [process.child --> io.close-result])
(declare process.close [process.child --> io.close-result])
(declare process.pipe-until [io.endpoint --> [deadline --> [[lazy boolean] --> io.endpoint]]])

\\ GCC/Clang compilation databases: argv only, one selected command per translation unit.

(shen.x.namespace source-build
  (use buffer)
  (use clock)
  (use deadline)
  (use fs)
  (use io)
  (use json)
  (use process)
  (use shen-jit)
  (use source-build)
  (use source-facts)
  (use source-syntax)
  (use treesitter)
  (externals [byte-limit child chunk-size cwd depth-limit done node-limit object ok preprocess result-limit
    stderr-limit stdout-limit timeout])

(define member
  [[Key Value] | _] Key -> Value
  [_ | Rest] Key -> (member Rest Key)
  [] Key -> (error "compilation database: missing ~A (arguments arrays are required)" Key))

(define text
  Text ->
    (let _ (if (string? Text) true (error "compilation database: expected text"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
         _ (if (<= N 4096) true (error "compilation database: argument exceeds 4096 bytes"))
         _ (io.file-no-nul Bytes 0 N)
      Text))

(define prefix?
  Prefix Text ->
    (let P (shen-jit.string->bytes Prefix)
         T (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length P)
      (and (>= (shen-jit.bytes-length T) N) (= Prefix (shen-jit.bytes->string T 0 N)))))

(define strings
  [] -> []
  [Text | Rest] -> [(text Text) | (strings Rest)]
  _ -> (error "compilation database: arguments must be an array of strings"))

\\ Strip compilation/dependency outputs; preserve preprocessing order and target flags.
\\ Reject response files and driver escapes, which cannot be rewritten faithfully here.
(define flags
  [] _ _ Seen -> (if (= Seen 1) [] (error "compilation database: expected exactly one source operand"))
  [Flag Value | Rest] Directory File Seen ->
    (flags Rest Directory File Seen)
      where (element? Flag ["-o" "-MF" "-MT" "-MQ" "-MJ"])
  ["-x" Language | Rest] Directory File Seen ->
    (if (element? Language ["c" "c-header"])
        (flags Rest Directory File Seen)
        (error "compilation database: only C inputs are supported"))
  [Flag Value | Rest] Directory File Seen ->
    [Flag Value | (flags Rest Directory File Seen)]
      where (element? Flag ["-I" "-D" "-U" "-isystem" "-iquote" "-idirafter" "-include" "-imacros"
                           "-isysroot" "--sysroot" "-target" "--target" "-arch"])
  [Arg | Rest] Directory File Seen ->
    (cond ((element? Arg ["-c" "-S" "-E" "-P" "-MD" "-MMD" "-MP" "-MG" "-M" "-MM" "-fsyntax-only"
                         "-xc" "-xc-header" "--language=c" "--language=c-header"])
            (flags Rest Directory File Seen))
          ((or (prefix? "@" Arg) (prefix? "-Wp," Arg)
               (prefix? "-fplugin" Arg) (prefix? "-save-temps" Arg)
               (prefix? "-x" Arg) (prefix? "--language=" Arg)
               (element? Arg ["-Xclang" "-Xpreprocessor" "--analyze" "--" "-o" "-MF" "-MT" "-MQ" "-MJ" "-x"]))
            (error "compilation database: unsupported driver option ~A" Arg))
          ((or (prefix? "-o" Arg) (prefix? "-MF" Arg)
               (prefix? "-MT" Arg) (prefix? "-MQ" Arg) (prefix? "-MJ" Arg))
            (flags Rest Directory File Seen))
          ((prefix? "-" Arg) [Arg | (flags Rest Directory File Seen)])
          ((= (fs.join Directory Arg) File) [Arg | (flags Rest Directory File (+ Seen 1))])
          (true (error "compilation database: unexpected operand ~A" Arg))))

(define command
  Base Seen [object | Fields] ->
    (let Directory (fs.join Base (fs.checked (member Fields "directory")))
         File (fs.join Directory (fs.checked (member Fields "file")))
         Args (strings (member Fields "arguments"))
         _ (if (and (> (length Args) 1) (<= (length Args) 256)) true
               (error "compilation database: expected 2..256 arguments"))
         _ (fs.checked (hd Args))
         _ (if (element? (fs.extension File) [".c" ".h"]) true (error "compilation database: only C inputs are supported"))
         _ (if (trap-error (shen.<-dict Seen File) (/. E false))
               (error "compilation database: duplicate source; select one configuration per file") true)
         Flags (flags (tl Args) Directory File 0)
         Effective [(hd Args) "-E" "-P" "-x" "c" | (append Flags ["-o" "-"])]
         _ (if (<= (buffer.length (json.encode Effective [[byte-limit 32768]])) 32768) true
               (error "compilation database: command is too large"))
         _ (shen.dict-> Seen File true)
      [File Directory Effective])
  _ _ _ -> (error "compilation database: expected command objects"))

(define commands
  Database Records ->
    (let _ (if (and (cons? Records) (<= (length Records) 1000)) true
               (error "compilation database: expected 1..1000 commands"))
         Base (fs.parent Database)
         Seen (shen.dict 64)
      (map (/. Record (command Base Seen Record)) Records)))

(define process-result
  [ok Report] ->
    (if (process.success? Report) [ok (process.output-bytes Report)]
        [error (io.native-error preprocess child 0 "compiler"
                 (make-string "preprocessor failed (~A): ~A" (process.status Report)
                   (buffer.string (process.error-bytes Report))))])
  [error Error] -> [error Error]
  [error Error _] -> [error Error])

(define units
  _ _ _ _ [] -> [ok done]
  Language Writer State Budget [[File Directory [Compiler | Args]] | Rest] ->
    (let Left (deadline.slice Budget 30000)
         _ (if (> Left 0) true (error "source-facts: total preprocessing budget expired"))
      (io.let-ok Input (process-result
                        (process.run Compiler Args (buffer.new 0)
                          [[cwd Directory] [timeout Left] [stdout-limit 8388608] [stderr-limit 65536]]))
        (do (address-> State 4 Directory)
            (address-> State 5 [Compiler | Args])
            (address-> State 6 Input)
            (let Profile (source-syntax.profile Input)
                 _ (address-> State 7 Profile)
              (io.let-ok _ (source-facts.parsed Writer State File
                            (treesitter.query Language (buffer.wrap (<-address Profile 0))
                              (value source-facts.configured-query)
                              [[node-limit 1048576] [result-limit 134217728]]))
                (units Language Writer State Budget Rest)))))))

(define extract
  Language Commands Configuration Out ->
    (let State (io.record [0 0 0 Configuration "" [] [] []])
         Writer (io.writer Out [[chunk-size 4096]])
      (io.let-ok _ (units Language Writer State (clock.deadline 300000) Commands)
        [ok (@p (<-address State 2) (<-address State 0))])))

(define start
  Grammar Database Configuration Output ->
    (let Configuration (fs.checked (text Configuration))
      (io.let-ok Path (fs.resolve Database)
                 Bytes (io.read-file Path 8388608)
        (let Commands (commands Path (json.decode Bytes [[byte-limit 8388608] [depth-limit 16]]))
          (source-build.language Commands Configuration Output
            (treesitter.load-language "C" [Grammar] "tree_sitter_c"))))))

(define source-build.language
  Commands Configuration Output [ok Language] ->
    (fs.with-replacement Output (/. Out (extract Language Commands Configuration Out)))
  _ _ _ [error E] ->
    [error (io.native-error language (treesitter.error-domain E) 0 "C" (treesitter.error-message E))])

)

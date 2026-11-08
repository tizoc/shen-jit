\\ GCC/Clang compilation databases: argv only, one selected command per translation unit.
(define source-build.member
  [[Key Value] | _] Key -> Value
  [_ | Rest] Key -> (source-build.member Rest Key)
  [] Key -> (error "compilation database: missing ~A (arguments arrays are required)" Key))

(define source-build.text
  Text ->
    (let _ (if (string? Text) true (error "compilation database: expected text"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
         _ (if (<= N 4096) true (error "compilation database: argument exceeds 4096 bytes"))
         _ (io.file-no-nul Bytes 0 N)
      Text))

(define source-build.prefix?
  Prefix Text ->
    (let P (shen-jit.string->bytes Prefix)
         T (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length P)
      (and (>= (shen-jit.bytes-length T) N) (= Prefix (shen-jit.bytes->string T 0 N)))))

(define source-build.strings
  [] -> []
  [Text | Rest] -> [(source-build.text Text) | (source-build.strings Rest)]
  _ -> (error "compilation database: arguments must be an array of strings"))

\\ Strip compilation/dependency outputs; preserve preprocessing order and target flags.
\\ Reject response files and driver escapes, which cannot be rewritten faithfully here.
(define source-build.flags
  [] _ _ Seen -> (if (= Seen 1) [] (error "compilation database: expected exactly one source operand"))
  [Flag Value | Rest] Directory File Seen ->
    (source-build.flags Rest Directory File Seen)
      where (element? Flag ["-o" "-MF" "-MT" "-MQ" "-MJ"])
  ["-x" Language | Rest] Directory File Seen ->
    (if (element? Language ["c" "c-header"])
        (source-build.flags Rest Directory File Seen)
        (error "compilation database: only C inputs are supported"))
  [Flag Value | Rest] Directory File Seen ->
    [Flag Value | (source-build.flags Rest Directory File Seen)]
      where (element? Flag ["-I" "-D" "-U" "-isystem" "-iquote" "-idirafter" "-include" "-imacros"
                           "-isysroot" "--sysroot" "-target" "--target" "-arch"])
  [Arg | Rest] Directory File Seen ->
    (cond ((element? Arg ["-c" "-S" "-E" "-P" "-MD" "-MMD" "-MP" "-MG" "-M" "-MM" "-fsyntax-only"
                         "-xc" "-xc-header" "--language=c" "--language=c-header"])
            (source-build.flags Rest Directory File Seen))
          ((or (source-build.prefix? "@" Arg) (source-build.prefix? "-Wp," Arg)
               (source-build.prefix? "-fplugin" Arg) (source-build.prefix? "-save-temps" Arg)
               (source-build.prefix? "-x" Arg) (source-build.prefix? "--language=" Arg)
               (element? Arg ["-Xclang" "-Xpreprocessor" "--analyze" "--" "-o" "-MF" "-MT" "-MQ" "-MJ" "-x"]))
            (error "compilation database: unsupported driver option ~A" Arg))
          ((or (source-build.prefix? "-o" Arg) (source-build.prefix? "-MF" Arg)
               (source-build.prefix? "-MT" Arg) (source-build.prefix? "-MQ" Arg) (source-build.prefix? "-MJ" Arg))
            (source-build.flags Rest Directory File Seen))
          ((source-build.prefix? "-" Arg) [Arg | (source-build.flags Rest Directory File Seen)])
          ((= (fs.join Directory Arg) File) [Arg | (source-build.flags Rest Directory File (+ Seen 1))])
          (true (error "compilation database: unexpected operand ~A" Arg))))

(define source-build.command
  Base Seen [object | Fields] ->
    (let Directory (fs.join Base (fs.checked (source-build.member Fields "directory")))
         File (fs.join Directory (fs.checked (source-build.member Fields "file")))
         Args (source-build.strings (source-build.member Fields "arguments"))
         _ (if (and (> (length Args) 1) (<= (length Args) 256)) true
               (error "compilation database: expected 2..256 arguments"))
         _ (fs.checked (hd Args))
         _ (if (element? (fs.extension File) [".c" ".h"]) true (error "compilation database: only C inputs are supported"))
         _ (if (trap-error (shen.<-dict Seen File) (/. E false))
               (error "compilation database: duplicate source; select one configuration per file") true)
         Flags (source-build.flags (tl Args) Directory File 0)
         Effective [(hd Args) "-E" "-P" "-x" "c" | (append Flags ["-o" "-"])]
         _ (if (<= (buffer.length (json.encode Effective [[byte-limit 32768]])) 32768) true
               (error "compilation database: command is too large"))
         _ (shen.dict-> Seen File true)
      [File Directory Effective])
  _ _ _ -> (error "compilation database: expected command objects"))

(define source-build.commands
  Database Records ->
    (let _ (if (and (cons? Records) (<= (length Records) 1000)) true
               (error "compilation database: expected 1..1000 commands"))
         Base (fs.parent Database)
         Seen (shen.dict 64)
      (map (/. Record (source-build.command Base Seen Record)) Records)))

(define source-build.process-result
  [ok Report] ->
    (if (process.success? Report) [ok (process.output-bytes Report)]
        [error (io.native-error preprocess child 0 "compiler"
                 (make-string "preprocessor failed (~A): ~A" (process.status Report)
                   (buffer.string (process.error-bytes Report))))])
  [error Error] -> [error Error]
  [error Error _] -> [error Error])

(define source-build.units
  _ _ _ _ [] -> [ok done]
  Language Writer State Budget [[File Directory [Compiler | Args]] | Rest] ->
    (let Left (deadline.slice Budget 30000)
         _ (if (> Left 0) true (error "source-facts: total preprocessing budget expired"))
      (io.let-ok Input (source-build.process-result
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
                (source-build.units Language Writer State Budget Rest)))))))

(define source-build.extract
  Language Commands Configuration Out ->
    (let State (io.record [0 0 0 Configuration "" [] [] []])
         Writer (io.writer Out [[chunk-size 4096]])
      (io.let-ok _ (source-build.units Language Writer State (clock.deadline 300000) Commands)
        [ok (@p (<-address State 2) (<-address State 0))])))

(define source-build.start
  Grammar Database Configuration Output ->
    (let Configuration (fs.checked (source-build.text Configuration))
      (io.let-ok Path (fs.resolve Database)
                 Bytes (io.read-file Path 8388608)
        (let Commands (source-build.commands Path (json.decode Bytes [[byte-limit 8388608] [depth-limit 16]]))
          (source-build.language Commands Configuration Output
            (treesitter.load-language "C" [Grammar] "tree_sitter_c"))))))

(define source-build.language
  Commands Configuration Output [ok Language] ->
    (fs.with-replacement Output (/. Out (source-build.extract Language Commands Configuration Out)))
  _ _ _ [error E] ->
    [error (io.native-error language (treesitter.error-domain E) 0 "C" (treesitter.error-message E))])

(set process-test.passed 0)
(set process-test.failed 0)

(shen-jit.library process-test.win ["kernel32.dll"])
(define-foreign process-test.event process-test.win "CreateEventW" (bytes bool bool pointer) --> int64)
(define-foreign process-test.close-handle process-test.win "CloseHandle" (int64) --> bool)

(let Program (process-test.path (if (io.file-windows?) "process-λ.exe" "process-λ"))
     Result (process.run Program ["echo"] (buffer.from-string "unicode program") [])
  (process-test.check "Unicode executable path" "unicode program"
    (freeze (process-test.output Result))))

(if (io.file-windows?)
    (let Security (shen-jit.bytes 24)
         _ (shen-jit.u32! Security 0 24)
         _ (shen-jit.u32! Security 16 1)
         Event (process-test.event Security true false [])
         _ (if (> Event 0) true (error "cannot create inheritance fixture"))
         Result (process-test.run ["handle" (str Event)] (buffer.new 0) [])
         _ (process-test.close-handle Event)
      (process-test.check "inheritable non-stdio handles are excluded" 0
        (freeze (process-test.u32 (process.output-bytes (process-test.ok Result)) 0))))
    skip)

(if (io.file-windows?)
    (process-test.check "invalid UTF-8 argument is rejected before execution" 1113
      (freeze (io.error-code (process-test.error
                (process-test.run ["args" "c#255;"] (buffer.new 0) [])))))
    (let Report (process-test.ok (process-test.run ["args" "c#255;"] (buffer.new 0) []))
         _ (io.write-file (process-test.path "raw-argument.bin") (process.output-bytes Report))
      (process-test.check "POSIX argument bytes need not be UTF-8" 9
        (freeze (process.output-count Report)))))

(let Result (process-test.run ["descendant-ignore-term"] (buffer.new 0)
               [[timeout 100] [terminate-grace 40]])
     Partial (process-test.partial Result)
     _ (io.write-file (process-test.path "descendant.pid") (process.output-bytes Partial))
  (do (process-test.check "descendant-held pipes reach the deadline" timeout
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "leader status survives forced descendant termination" [exited 0]
        (freeze (process.status Partial)))))

(let C (process-test.ok (process.spawn (value process-test.helper) ["echo"]
                         [[stdin pipe] [stdout pipe] [stderr pipe]]))
     Report (process-test.ok (process.communicate C (buffer.from-string "borrowed") []))
     Status (process.poll C)
     Closed (process.close C)
  (do (process-test.check "communicate leaves child ownership with caller" [ok [exited 0]]
        (freeze Status))
      (process-test.check "communicate returns captured output" "borrowed"
        (freeze (buffer.string (process.output-bytes Report))))
      (process-test.check "caller closes communicated child" [ok] (freeze Closed))))

(output "~A passed, ~A failed~%" (value process-test.passed) (value process-test.failed))

\\ Monotonic milliseconds over the FFI. Load ffi.shen, buffer.shen, io.shen and deadline.shen.
\\ POSIX timespec uses two 64-bit fields on the supported platforms. Windows supplies milliseconds.

(shen.x.namespace clock
  (use buffer)
  (use deadline)
  (use shen-jit)
  (externals [bytes deadline define-foreign int32 int64])
  (export clock.deadline => deadline monotonic)

(shen-jit.library lib ["libc.so.6" "libSystem.dylib"])
(shen-jit.library win ["kernel32.dll"])

(define-foreign c-monotonic lib "clock_gettime" (int32 bytes) --> int32)
(define-foreign c-ticks win "GetTickCount64" () --> int64)

(define monotonic
  ->
    (if (= (value *os*) "Windows")
        (buffer.index (c-ticks))
        (let B (shen-jit.bytes 16)
             OS (value *os*)
             Kind (cond ((= OS "Linux") 1)
                        ((= OS "macOS") 6)
                        (true (error "clock: unsupported OS ~A" OS)))
             Result (c-monotonic Kind B)
             Code (shen-jit.c-errno)
             _ (if (= Result 0) true (error "clock: clock_gettime failed: ~A" Code))
             Seconds (buffer.index (shen-jit.s64 B 0))
             Nanos (buffer.index (shen-jit.s64 B 8))
             Millis (/ (- Nanos (shen.mod Nanos 1000000)) 1000000)
          (+ (* Seconds 1000) Millis))))

(define clock.deadline
  Milliseconds -> (deadline.after (freeze (monotonic)) Milliseconds))

(declare monotonic [--> number])
(declare clock.deadline [number --> deadline])

)

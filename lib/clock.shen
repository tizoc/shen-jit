\\ Monotonic milliseconds over the FFI. Module clock.
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

\\ The FFI does not derive signatures for byte-buffer arguments.
(declare c-monotonic [number --> [buffer.storage --> number]])

)

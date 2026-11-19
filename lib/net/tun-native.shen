(shen.x.namespace net-tun
  (use buffer)
  (use shen-jit)
  (externals [blocking bool bytes define-foreign int32 int64])
  (export c-open c-close c-read c-write c-wait c-clock make-guard kill-guard)

(shen-jit.library tun-library ["shen-tun.so" "build/shen-tun.so"])
(define-foreign c-open tun-library "shen_tun_open" (string) --> int32)
(define-foreign c-close tun-library "shen_tun_close" (int32) --> int32)
(define-foreign c-read tun-library "shen_tun_read" (int32 bytes int32) --> int32)
(define-foreign c-write tun-library "shen_tun_write" (int32 bytes int64 int32) --> int32)
(define-foreign c-wait tun-library "shen_tun_wait" (int32 bool bool int32) --> int32 blocking)
(define-foreign c-clock tun-library "shen_tun_clock" (int64) --> int64)

(declare c-read [fixnum --> [buffer.storage --> [fixnum --> fixnum]]])
(declare c-write [fixnum --> [buffer.storage --> [fixnum --> [fixnum --> fixnum]]]])

\\ A process-local token. Images clear its address before the saved fd can be used.
(define make-guard
  _ -> (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 net-tun))

(declare make-guard [fixnum --> buffer.storage])

(define kill-guard
  P -> (do (shen-jit.pointer-kill P) true))

(declare kill-guard [buffer.storage --> boolean])
)

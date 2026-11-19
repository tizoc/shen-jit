\\ A reusable application stream over one leased TCP connection.
(shen.x.namespace net-stream
  (use buffer)
  (use net-interface)
  (use net-ipv6)
  (use tcp)
  (import struct defstruct)
  (shadow abort release)
  (export stream-handle make connect connect6 accept state readable? writable? read-into write-from
          shutdown-write abort release)

(defstruct stream-handle
  (interface : net-interface.interface)
  (mutable token : fixnum))

(define make
  {net-interface.interface --> stream-handle}
  F ->
    (:stream-handle
      interface <- F
      token <- 0))

(define table
  {stream-handle --> tcp.listener}
  S -> (net-interface.interface.listener (stream-handle.interface S)))

(define connect
  {stream-handle --> fixnum --> fixnum --> boolean}
  S IP Port ->
    (and (= (stream-handle.token S) 0)
         (let T (net-interface.connect (stream-handle.interface S) IP Port)
           (and (fx> T 0) (do (stream-handle.token-> S T) true)))))

(define connect6
  {stream-handle --> net-ipv6.address --> fixnum --> boolean}
  S IP Port ->
    (and (= (stream-handle.token S) 0)
         (let T (net-interface.connect6 (stream-handle.interface S) IP Port)
           (and (fx> T 0) (do (stream-handle.token-> S T) true)))))

(define accept
  {stream-handle --> fixnum --> boolean}
  S Port ->
    (and (= (stream-handle.token S) 0)
         (let T (tcp.accept-on (table S) Port)
           (and (fx> T 0) (do (stream-handle.token-> S T) true)))))

(define state
  {stream-handle --> tcp.phase}
  S -> (if (= (stream-handle.token S) 0) tcp.closed (tcp.connection-state (table S) (stream-handle.token S))))

(define readable?
  {stream-handle --> boolean}
  S -> (and (fx> (stream-handle.token S) 0) (tcp.connection-readable? (table S) (stream-handle.token S))))

(define writable?
  {stream-handle --> boolean}
  S -> (and (fx> (stream-handle.token S) 0) (tcp.connection-writable? (table S) (stream-handle.token S))))

(define read-into
  {stream-handle --> buffer.view --> fixnum --> fixnum --> fixnum}
  S B At N ->
    (if (= (stream-handle.token S) 0) -1 (tcp.connection-recv-at (table S) (stream-handle.token S) B At N)))

(define write-from
  {stream-handle --> buffer.view --> fixnum --> fixnum --> fixnum}
  S B At N ->
    (if (= (stream-handle.token S) 0) 0 (tcp.connection-send-from (table S) (stream-handle.token S) B At N)))

(define shutdown-write
  {stream-handle --> boolean}
  S -> (and (fx> (stream-handle.token S) 0) (tcp.connection-shutdown-write (table S) (stream-handle.token S))))

(define abort
  {stream-handle --> boolean}
  S -> (and (fx> (stream-handle.token S) 0) (tcp.connection-abort (table S) (stream-handle.token S))))

(define release
  {stream-handle --> boolean}
  S -> (and (fx> (stream-handle.token S) 0)
            (tcp.release (table S) (stream-handle.token S))
            (do (stream-handle.token-> S 0) true)))

(preclude [stream-handle.%match])
)

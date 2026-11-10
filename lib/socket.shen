\\ TCP sockets, over the FFI and with no C of their own. It stays out of the image until asked
\\ for; load it after lib/ffi.shen, under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l program.shen
\\
\\ (let S (socket.connect "example.com" 80)
\\   (do (socket.send S "GET / HTTP/1.0c#13;c#10;c#13;c#10;")
\\       (output "~A~%" (socket.recv-string S 4096))
\\       (socket.close S)))
\\
\\ socket.connect         (socket.connect Host Port), trying each address the name has
\\ socket.listen          (socket.listen Host Port), with port 0 for any free one
\\ socket.port            the port a socket is bound to
\\ socket.accept          (socket.accept Listener) waits for a client, and gives its socket
\\ socket.send            (socket.send S Data) sends all of a string or byte buffer
\\ socket.recv            (socket.recv S N) waits for data, and gives a buffer of at most N bytes;
\\                        an empty one means the other end has finished
\\ socket.recv-into       (socket.recv-into S Buffer) fills what it can, and gives how much
\\ socket.recv-string     (socket.recv-string S N), as a string
\\ socket.readable?       (socket.readable? S Milliseconds), waiting that long at most
\\ socket.shutdown        tells the other end that nothing more will be sent
\\ socket.no-delay        sends small writes at once
\\ socket.close           (socket.close S)
\\
\\ A socket is an integer. Errors raise, with the system's message or, on Windows, its number.
\\
\\ Sockets never block in C: a call that would have to wait waits in Shen, in poll slices of
\\ 100 ms with the lock given up. So other threads run meanwhile, and a Ctrl-C at the REPL ends
\\ the wait. A send to a closed connection raises instead of ending the process.
\\
\\ C differs by system in numbers and in a few names, which socket.by-os and the definitions
\\ below hold, for Linux, macOS and Windows. Functions are found at their first call, so a system
\\ declares what it never calls without harm. Results are int32 even for a byte count: Windows
\\ returns an int, and more than a chunk at a time is never asked for.

(shen.x.namespace socket
  (use shen-jit)
  (externals [addrinfo blocking bool bytes define-foreign int32 int64 pointer skip sockaddr
    uint32 varargs void])
  (shadow close fail min port type)
  (export accept by-os c-accept c-close c-poll c-recv c-send c-shutdown c-strerror close
    closing-on-error connect lib listen no-delay pollfd port readable-event readable? recv
    recv-into recv-string send send-flags set-up shutdown type windows? writable-event)

(shen-jit.library lib ["libc.so.6" "libSystem.dylib" "ws2_32.dll"])

(define windows?
  -> (= (value *os*) "Windows"))

(define by-os
  Linux MacOS Windows -> (let Os (value *os*)
                           (cases (= Os "Linux") Linux
                                  (= Os "macOS") MacOS
                                  (= Os "Windows") Windows
                                  true (error "socket: not written for ~A" Os))))

\\ A socket is a descriptor, or on Windows a SOCKET, whose invalid value is all ones.
(define type
  -> (if (windows?) int64 int32))

(define-foreign c-startup lib "WSAStartup" (int32 bytes) --> int32)
(define-foreign c-getaddrinfo lib "getaddrinfo" (string string bytes bytes) --> int32 blocking)
(define-foreign c-freeaddrinfo lib "freeaddrinfo" (pointer) --> void)
(define-foreign c-socket-plain lib "socket" (int32 int32 int32) --> (type))
(define-foreign c-wsocket lib "WSASocketW"
  (int32 int32 int32 pointer uint32 uint32) --> int64)
(define-foreign c-close lib (if (windows?) "closesocket" "close") ((type)) --> int32)
(define-foreign c-connect lib "connect" ((type) bytes int32) --> int32)
(define-foreign c-bind lib "bind" ((type) bytes int32) --> int32)
(define-foreign c-listen lib "listen" ((type) int32) --> int32)
(define-foreign c-accept-plain lib "accept" ((type) pointer pointer) --> (type))
(define-foreign c-accept4 lib "accept4" (int32 pointer pointer int32) --> int32)
(define-foreign c-send lib "send" ((type) bytes int64 int32) --> int32)
(define-foreign c-recv lib "recv" ((type) bytes int64 int32) --> int32)
(define-foreign c-shutdown lib "shutdown" ((type) int32) --> int32)
(define-foreign c-getsockname lib "getsockname" ((type) bytes bytes) --> int32)
(define-foreign c-getsockopt lib "getsockopt" ((type) int32 int32 bytes bytes) --> int32)
(define-foreign c-setsockopt lib "setsockopt" ((type) int32 int32 bytes int32) --> int32)
(define-foreign c-fcntl lib "fcntl" (int32 int32 int32) --> int32 (varargs 2))
(define-foreign c-ioctlsocket lib "ioctlsocket" (int64 int32 bytes) --> int32)
(define-foreign c-poll lib (if (windows?) "WSAPoll" "poll") (bytes int64 int32) --> int32 blocking)
(define-foreign c-strerror lib "strerror" (int32) --> string)

(shen-jit.library handles ["kernel32.dll"])
(define-foreign c-inheritance handles "SetHandleInformation" (int64 uint32 uint32) --> bool)

\\ Linux creates sockets close-on-exec atomically. Windows uses WSA_FLAG_NO_HANDLE_INHERIT.
(define c-socket
  Family Type Protocol ->
    (if (windows?)
        (c-wsocket Family Type Protocol [] 0 128)
        (c-socket-plain Family (+ Type (if (= (value *os*) "Linux") 524288 0)) Protocol)))

(define c-accept
  S Address Length ->
    (if (= (value *os*) "Linux")
        (c-accept4 S Address Length 524288)
        (c-accept-plain S Address Length)))

(define no-inherit
  S ->
    (if (windows?)
        (if (c-inheritance S 1 0) S (fail "SetHandleInformation"))
        (if (< (c-fcntl S 2 1) 0) (fail "fcntl close-on-exec") S)))

\\ ---------------------------------------------------------------------------
\\ Errors.

(define fail
  What -> (raise What (shen-jit.errno)))

\\ Windows has no strerror for its socket errors.
(define raise
  What Code -> (if (windows?)
                   (error "socket: ~A: error ~A" What Code)
                   (error "socket: ~A: ~A" What (c-strerror Code))))

\\ EAGAIN, and EINTR, which only means to try again.
(define again?
  -> (let Code (shen-jit.errno)
       (or (= Code (by-os 11 35 10035)) (= Code (by-os 4 4 10004)))))

\\ EINPROGRESS: Windows says it as it says EAGAIN.
(define in-progress?
  -> (= (shen-jit.errno) (by-os 115 36 10035)))

\\ Runs a frozen expression, closing S if it raises.
(define closing-on-error
  S F -> (shen-jit.on-error F (freeze (c-close S))))

\\ ---------------------------------------------------------------------------
\\ Waiting.

(define readable-event
  -> (by-os 1 1 256))

(define writable-event
  -> (by-os 4 4 16))

\\ struct pollfd, or on Windows WSAPOLLFD, whose descriptor is 8 bytes.
(define pollfd
  S Event -> (let B (shen-jit.bytes 16)
               (if (windows?)
                   (do (shen-jit.u32! B 0 (shen-jit.bit-and S 4294967295))
                       (shen-jit.u32! B 4 (shen-jit.shift-right S 32))
                       (shen-jit.u16! B 8 Event))
                   (shen-jit.u16! (shen-jit.u32! B 0 S) 4 Event))))

\\ Whether S is ready within Milliseconds. An error on it counts as ready, for the next call to
\\ report. A signal ends the wait early, which is how a Ctrl-C gets through.
(define poll
  S Event Milliseconds -> (let Ready (c-poll (pollfd S Event) 1 Milliseconds)
                            (cases (> Ready 0) true
                                   (= Ready 0) false
                                   (again?) false
                                   true (fail "poll"))))

\\ Code runs between the slices, which is where an interrupt is noticed.
(define wait
  S Event -> (if (poll S Event 100) true (wait S Event)))

(define wait-for
  S Event Left -> (let Slice (min 100 Left)
                    (cases (poll S Event Slice) true
                           (<= Left Slice) false
                           true (wait-for S Event (- Left Slice)))))

\\ A wait that poll would take as forever, or one it cannot take, is refused before polling.
(define readable?
  S Milliseconds -> (if (milliseconds? Milliseconds)
                        (wait-for S (readable-event) Milliseconds)
                        (error "socket: a wait must be a whole number of milliseconds, 0 or more")))

(define milliseconds?
  X -> (and (number? X) (>= X 0) (trap-error (= X (shen-jit.bit-or X 0)) (/. E false))))

(define min
  X Y -> (if (< X Y) X Y))

\\ ---------------------------------------------------------------------------
\\ Making a socket.

(define set-option
  S Level Name Value
  -> (if (< (c-setsockopt S Level Name (shen-jit.u32! (shen-jit.bytes 4) 0 Value) 4) 0)
         (fail "setsockopt")
         S))

(define non-blocking
  S -> (if (windows?)
           \\ FIONBIO, as a C long
           (if (< (c-ioctlsocket S -2147195266 (shen-jit.u32! (shen-jit.bytes 4) 0 1)) 0)
               (fail "ioctlsocket")
               S)
           \\ F_SETFL and O_NONBLOCK
           (if (< (c-fcntl S 4 (by-os 2048 4 0)) 0)
               (fail "fcntl")
               S)))

\\ Linux says this for each send instead. Windows has no SIGPIPE.
(define no-sigpipe
  S -> (if (= (value *os*) "macOS") (set-option S 65535 4130 1) S))

\\ What every socket needs, and an accepted one does not always inherit.
(define set-up
  S -> (closing-on-error S
         (freeze (no-inherit (no-sigpipe (non-blocking S))))))

(define make
  Family Type Protocol -> (let S (c-socket Family Type Protocol)
                            (if (< S 0) (fail "socket") (set-up S))))

\\ MSG_NOSIGNAL
(define send-flags
  -> (by-os 16384 0 0))

\\ ---------------------------------------------------------------------------
\\ Addresses.

\\ Winsock counts its users, so saying this again does no harm, and a saved program needs no
\\ memory of having said it in another process.
(define start
  -> (if (windows?)
         (let Rc (c-startup 514 (shen-jit.bytes 512))
           (if (= Rc 0) true (raise "WSAStartup" Rc)))
         true))

\\ Each address as [Family Type Protocol Address], the last a buffer holding its sockaddr. Flags
\\ is 1 for an address to listen on. Hints and results are struct addrinfo, which Linux lays out
\\ with the address before the name, and the others after it.
(define addresses
  Host Port Flags
  -> (let Started (start)
          Out (shen-jit.bytes 8)
          Hints (shen-jit.u32! (shen-jit.u32! (shen-jit.bytes 48) 0 Flags) 8 1)
          Rc (c-getaddrinfo Host (str Port) Hints Out)
       (if (= Rc 0)
           (let List (shen-jit.bytes->pointer Out 0 addrinfo)
                Addresses (read-addresses List)
             (do (c-freeaddrinfo List) Addresses))
           (error "socket: cannot find ~A" Host))))

(define read-addresses
  [] -> []
  P -> (let Info (shen-jit.pointer->bytes P 0 48)
            Address (shen-jit.bytes->pointer Info (by-os 24 32 32) sockaddr)
         [[(shen-jit.u32 Info 4) (shen-jit.u32 Info 8) (shen-jit.u32 Info 12)
           (shen-jit.pointer->bytes Address 0 (shen-jit.u32 Info 16))]
          | (read-addresses (shen-jit.bytes->pointer Info 40 addrinfo))]))

\\ The first address on which F works, or the last error.
(define first-working
  F [] Last -> (simple-error Last)
  F [Address | Addresses] _
  -> (trap-error (F Address) (/. E (first-working F Addresses (error-to-string E)))))

(define port
  S -> (let Address (shen-jit.bytes 128)
            Length (shen-jit.u32! (shen-jit.bytes 4) 0 128)
         (if (< (c-getsockname S Address Length) 0)
             (fail "getsockname")
             (+ (* 256 (shen-jit.u8 Address 2)) (shen-jit.u8 Address 3)))))

\\ ---------------------------------------------------------------------------
\\ Clients.

(define connect
  Host Port -> (first-working (/. A (connect-to A)) (addresses Host Port 0)
                                     (make-string "socket: no address for ~A" Host)))

(define connect-to
  [Family Type Protocol Address]
  -> (let S (make Family Type Protocol)
       (closing-on-error S (freeze (connect-socket S Address)))))

(define connect-socket
  S Address -> (cases (= (c-connect S Address (shen-jit.bytes-length Address)) 0) S
                      (in-progress?) (finish-connecting S)
                      true (fail "connect")))

\\ The socket's own error each time round, since on old versions of Windows a failure to connect
\\ never shows in WSAPoll.
(define finish-connecting
  S -> (let Ready (poll S (writable-event) 100)
            Error (pending-error S)
         (cases (not (= Error 0)) (raise "connect" Error)
                Ready S
                true (finish-connecting S))))

\\ SOL_SOCKET and SO_ERROR
(define pending-error
  S -> (let Value (shen-jit.bytes 4)
            Length (shen-jit.u32! (shen-jit.bytes 4) 0 4)
         (if (< (c-getsockopt S (by-os 1 65535 65535) (by-os 4 4103 4103) Value Length) 0)
             (fail "getsockopt")
             (shen-jit.u32 Value 0))))

\\ ---------------------------------------------------------------------------
\\ Servers.

(define listen
  Host Port -> (first-working (/. A (listen-on A)) (addresses Host Port 1)
                                     (make-string "socket: no address for ~A" Host)))

(define listen-on
  [Family Type Protocol Address]
  -> (let S (make Family Type Protocol)
       (closing-on-error S (freeze (bind-and-listen S Address)))))

\\ SO_REUSEADDR lets a server restart at once. On Windows it would let another take its port.
(define bind-and-listen
  S Address -> (do (if (windows?) skip (set-option S (by-os 1 65535 0) (by-os 2 4 0) 1))
                   (cases (< (c-bind S Address (shen-jit.bytes-length Address)) 0) (fail "bind")
                          (< (c-listen S 128) 0) (fail "listen")
                          true S)))

(define accept
  Listener -> (let S (c-accept Listener [] [])
                (cases (>= S 0) (set-up S)
                       (again?) (do (wait Listener (readable-event))
                                           (accept Listener))
                       true (fail "accept"))))

\\ ---------------------------------------------------------------------------
\\ Data.

(define send
  S Data -> (send-bytes S (if (string? Data) (shen-jit.string->bytes Data) Data)))

(define send-bytes
  S B -> (let Length (shen-jit.bytes-length B)
              Chunk (shen-jit.bytes (min Length 65536))
           (do (send-from S B 0 Length Chunk) Length)))

\\ A call takes a buffer's start and not a place in it, so what is sent goes through Chunk, and
\\ what a short send leaves is copied again.
(define send-from
  _ _ Length Length _ -> true
  S B At Length Chunk -> (let N (min (- Length At) (shen-jit.bytes-length Chunk))
                              Copied (shen-jit.copy-bytes Chunk 0 B At N)
                            (send-from S B (+ At (send-some S Chunk N)) Length Chunk)))

(define send-some
  S Chunk N -> (let Sent (c-send S Chunk N (send-flags))
                 (cases (>= Sent 0) Sent
                        (again?) (do (wait S (writable-event))
                                            (send-some S Chunk N))
                        true (fail "send"))))

(define recv-into
  S Buffer -> (let Got (c-recv S Buffer (min (shen-jit.bytes-length Buffer) 1073741824) 0)
                (cases (>= Got 0) Got
                       (again?) (do (wait S (readable-event))
                                           (recv-into S Buffer))
                       true (fail "recv"))))

(define recv
  S N -> (let Buffer (shen-jit.bytes N)
              Got (recv-into S Buffer)
           (if (= Got N)
               Buffer
               (shen-jit.copy-bytes (shen-jit.bytes Got) 0 Buffer 0 Got))))

(define recv-string
  S N -> (let B (recv S N)
           (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

\\ ---------------------------------------------------------------------------

\\ SHUT_WR, which Windows calls SD_SEND
(define shutdown
  S -> (if (< (c-shutdown S 1) 0) (fail "shutdown") true))

\\ IPPROTO_TCP and TCP_NODELAY
(define no-delay
  S -> (do (set-option S 6 1 1) true))

(define close
  S -> (if (< (c-close S) 0) (fail "close") true))

\\ Types for the calls whose arguments and results have plain ones. A byte buffer has none, so
\\ typed code sends strings here, and bytes through io.socket.
(declare connect [string --> [number --> number]])
(declare listen [string --> [number --> number]])
(declare accept [number --> number])
(declare port [number --> number])
(declare close [number --> boolean])
(declare shutdown [number --> boolean])
(declare no-delay [number --> boolean])
(declare readable? [number --> [number --> boolean]])
(declare recv-string [number --> [number --> string]])
(declare send [number --> [string --> number]])

)

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

(shen-jit.library socket.lib ["libc.so.6" "libSystem.dylib" "ws2_32.dll"])

(define socket.windows?
  -> (= (value *os*) "Windows"))

(define socket.by-os
  Linux MacOS Windows -> (let Os (value *os*)
                           (cases (= Os "Linux") Linux
                                  (= Os "macOS") MacOS
                                  (= Os "Windows") Windows
                                  true (error "socket: not written for ~A" Os))))

\\ A socket is a descriptor, or on Windows a SOCKET, whose invalid value is all ones.
(define socket.type
  -> (if (socket.windows?) int64 int32))

(define-foreign socket.c-startup socket.lib "WSAStartup" (int32 bytes) --> int32)
(define-foreign socket.c-getaddrinfo socket.lib "getaddrinfo" (string string bytes bytes) --> int32 blocking)
(define-foreign socket.c-freeaddrinfo socket.lib "freeaddrinfo" (pointer) --> void)
(define-foreign socket.c-socket-plain socket.lib "socket" (int32 int32 int32) --> (socket.type))
(define-foreign socket.c-wsocket socket.lib "WSASocketW"
  (int32 int32 int32 pointer uint32 uint32) --> int64)
(define-foreign socket.c-close socket.lib (if (socket.windows?) "closesocket" "close") ((socket.type)) --> int32)
(define-foreign socket.c-connect socket.lib "connect" ((socket.type) bytes int32) --> int32)
(define-foreign socket.c-bind socket.lib "bind" ((socket.type) bytes int32) --> int32)
(define-foreign socket.c-listen socket.lib "listen" ((socket.type) int32) --> int32)
(define-foreign socket.c-accept-plain socket.lib "accept" ((socket.type) pointer pointer) --> (socket.type))
(define-foreign socket.c-accept4 socket.lib "accept4" (int32 pointer pointer int32) --> int32)
(define-foreign socket.c-send socket.lib "send" ((socket.type) bytes int64 int32) --> int32)
(define-foreign socket.c-recv socket.lib "recv" ((socket.type) bytes int64 int32) --> int32)
(define-foreign socket.c-shutdown socket.lib "shutdown" ((socket.type) int32) --> int32)
(define-foreign socket.c-getsockname socket.lib "getsockname" ((socket.type) bytes bytes) --> int32)
(define-foreign socket.c-getsockopt socket.lib "getsockopt" ((socket.type) int32 int32 bytes bytes) --> int32)
(define-foreign socket.c-setsockopt socket.lib "setsockopt" ((socket.type) int32 int32 bytes int32) --> int32)
(define-foreign socket.c-fcntl socket.lib "fcntl" (int32 int32 int32) --> int32 (varargs 2))
(define-foreign socket.c-ioctlsocket socket.lib "ioctlsocket" (int64 int32 bytes) --> int32)
(define-foreign socket.c-poll socket.lib (if (socket.windows?) "WSAPoll" "poll") (bytes int64 int32) --> int32 blocking)
(define-foreign socket.c-strerror socket.lib "strerror" (int32) --> string)

(shen-jit.library socket.handles ["kernel32.dll"])
(define-foreign socket.c-inheritance socket.handles "SetHandleInformation" (int64 uint32 uint32) --> bool)

\\ Linux creates sockets close-on-exec atomically. Windows uses WSA_FLAG_NO_HANDLE_INHERIT.
(define socket.c-socket
  Family Type Protocol ->
    (if (socket.windows?)
        (socket.c-wsocket Family Type Protocol [] 0 128)
        (socket.c-socket-plain Family (+ Type (if (= (value *os*) "Linux") 524288 0)) Protocol)))

(define socket.c-accept
  S Address Length ->
    (if (= (value *os*) "Linux")
        (socket.c-accept4 S Address Length 524288)
        (socket.c-accept-plain S Address Length)))

(define socket.no-inherit
  S ->
    (if (socket.windows?)
        (if (socket.c-inheritance S 1 0) S (socket.fail "SetHandleInformation"))
        (if (< (socket.c-fcntl S 2 1) 0) (socket.fail "fcntl close-on-exec") S)))

\\ ---------------------------------------------------------------------------
\\ Errors.

(define socket.fail
  What -> (socket.raise What (shen-jit.errno)))

\\ Windows has no strerror for its socket errors.
(define socket.raise
  What Code -> (if (socket.windows?)
                   (error "socket: ~A: error ~A" What Code)
                   (error "socket: ~A: ~A" What (socket.c-strerror Code))))

\\ EAGAIN, and EINTR, which only means to try again.
(define socket.again?
  -> (let Code (shen-jit.errno)
       (or (= Code (socket.by-os 11 35 10035)) (= Code (socket.by-os 4 4 10004)))))

\\ EINPROGRESS: Windows says it as it says EAGAIN.
(define socket.in-progress?
  -> (= (shen-jit.errno) (socket.by-os 115 36 10035)))

\\ Runs a frozen expression, closing S if it raises.
(define socket.closing-on-error
  S F -> (trap-error (thaw F)
                     (/. E (do (socket.c-close S) (simple-error (error-to-string E))))))

\\ ---------------------------------------------------------------------------
\\ Waiting.

(define socket.readable-event
  -> (socket.by-os 1 1 256))

(define socket.writable-event
  -> (socket.by-os 4 4 16))

\\ struct pollfd, or on Windows WSAPOLLFD, whose descriptor is 8 bytes.
(define socket.pollfd
  S Event -> (let B (shen-jit.bytes 16)
               (if (socket.windows?)
                   (do (shen-jit.u32! B 0 (shen-jit.bit-and S 4294967295))
                       (shen-jit.u32! B 4 (shen-jit.shift-right S 32))
                       (shen-jit.u16! B 8 Event))
                   (shen-jit.u16! (shen-jit.u32! B 0 S) 4 Event))))

\\ Whether S is ready within Milliseconds. An error on it counts as ready, for the next call to
\\ report. A signal ends the wait early, which is how a Ctrl-C gets through.
(define socket.poll
  S Event Milliseconds -> (let Ready (socket.c-poll (socket.pollfd S Event) 1 Milliseconds)
                            (cases (> Ready 0) true
                                   (= Ready 0) false
                                   (socket.again?) false
                                   true (socket.fail "poll"))))

\\ Code runs between the slices, which is where an interrupt is noticed.
(define socket.wait
  S Event -> (if (socket.poll S Event 100) true (socket.wait S Event)))

(define socket.wait-for
  S Event Left -> (let Slice (socket.min 100 Left)
                    (cases (socket.poll S Event Slice) true
                           (<= Left Slice) false
                           true (socket.wait-for S Event (- Left Slice)))))

(define socket.readable?
  S Milliseconds -> (socket.wait-for S (socket.readable-event) Milliseconds))

(define socket.min
  X Y -> (if (< X Y) X Y))

\\ ---------------------------------------------------------------------------
\\ Making a socket.

(define socket.set-option
  S Level Name Value
  -> (if (< (socket.c-setsockopt S Level Name (shen-jit.u32! (shen-jit.bytes 4) 0 Value) 4) 0)
         (socket.fail "setsockopt")
         S))

(define socket.non-blocking
  S -> (if (socket.windows?)
           \\ FIONBIO, as a C long
           (if (< (socket.c-ioctlsocket S -2147195266 (shen-jit.u32! (shen-jit.bytes 4) 0 1)) 0)
               (socket.fail "ioctlsocket")
               S)
           \\ F_SETFL and O_NONBLOCK
           (if (< (socket.c-fcntl S 4 (socket.by-os 2048 4 0)) 0)
               (socket.fail "fcntl")
               S)))

\\ Linux says this for each send instead. Windows has no SIGPIPE.
(define socket.no-sigpipe
  S -> (if (= (value *os*) "macOS") (socket.set-option S 65535 4130 1) S))

\\ What every socket needs, and an accepted one does not always inherit.
(define socket.set-up
  S -> (socket.closing-on-error S
         (freeze (socket.no-inherit (socket.no-sigpipe (socket.non-blocking S))))))

(define socket.make
  Family Type Protocol -> (let S (socket.c-socket Family Type Protocol)
                            (if (< S 0) (socket.fail "socket") (socket.set-up S))))

\\ MSG_NOSIGNAL
(define socket.send-flags
  -> (socket.by-os 16384 0 0))

\\ ---------------------------------------------------------------------------
\\ Addresses.

\\ Winsock counts its users, so saying this again does no harm, and a saved program needs no
\\ memory of having said it in another process.
(define socket.start
  -> (if (socket.windows?)
         (let Rc (socket.c-startup 514 (shen-jit.bytes 512))
           (if (= Rc 0) true (socket.raise "WSAStartup" Rc)))
         true))

\\ Each address as [Family Type Protocol Address], the last a buffer holding its sockaddr. Flags
\\ is 1 for an address to listen on. Hints and results are struct addrinfo, which Linux lays out
\\ with the address before the name, and the others after it.
(define socket.addresses
  Host Port Flags
  -> (let Started (socket.start)
          Out (shen-jit.bytes 8)
          Hints (shen-jit.u32! (shen-jit.u32! (shen-jit.bytes 48) 0 Flags) 8 1)
          Rc (socket.c-getaddrinfo Host (str Port) Hints Out)
       (if (= Rc 0)
           (let List (shen-jit.bytes->pointer Out 0 addrinfo)
                Addresses (socket.read-addresses List)
             (do (socket.c-freeaddrinfo List) Addresses))
           (error "socket: cannot find ~A" Host))))

(define socket.read-addresses
  [] -> []
  P -> (let Info (shen-jit.pointer->bytes P 0 48)
            Address (shen-jit.bytes->pointer Info (socket.by-os 24 32 32) sockaddr)
         [[(shen-jit.u32 Info 4) (shen-jit.u32 Info 8) (shen-jit.u32 Info 12)
           (shen-jit.pointer->bytes Address 0 (shen-jit.u32 Info 16))]
          | (socket.read-addresses (shen-jit.bytes->pointer Info 40 addrinfo))]))

\\ The first address on which F works, or the last error.
(define socket.first-working
  F [] Last -> (simple-error Last)
  F [Address | Addresses] _
  -> (trap-error (F Address) (/. E (socket.first-working F Addresses (error-to-string E)))))

(define socket.port
  S -> (let Address (shen-jit.bytes 128)
            Length (shen-jit.u32! (shen-jit.bytes 4) 0 128)
         (if (< (socket.c-getsockname S Address Length) 0)
             (socket.fail "getsockname")
             (+ (* 256 (shen-jit.u8 Address 2)) (shen-jit.u8 Address 3)))))

\\ ---------------------------------------------------------------------------
\\ Clients.

(define socket.connect
  Host Port -> (socket.first-working (/. A (socket.connect-to A)) (socket.addresses Host Port 0)
                                     (make-string "socket: no address for ~A" Host)))

(define socket.connect-to
  [Family Type Protocol Address]
  -> (let S (socket.make Family Type Protocol)
       (socket.closing-on-error S (freeze (socket.connect-socket S Address)))))

(define socket.connect-socket
  S Address -> (cases (= (socket.c-connect S Address (shen-jit.bytes-length Address)) 0) S
                      (socket.in-progress?) (socket.finish-connecting S)
                      true (socket.fail "connect")))

\\ The socket's own error each time round, since on old versions of Windows a failure to connect
\\ never shows in WSAPoll.
(define socket.finish-connecting
  S -> (let Ready (socket.poll S (socket.writable-event) 100)
            Error (socket.pending-error S)
         (cases (not (= Error 0)) (socket.raise "connect" Error)
                Ready S
                true (socket.finish-connecting S))))

\\ SOL_SOCKET and SO_ERROR
(define socket.pending-error
  S -> (let Value (shen-jit.bytes 4)
            Length (shen-jit.u32! (shen-jit.bytes 4) 0 4)
         (if (< (socket.c-getsockopt S (socket.by-os 1 65535 65535) (socket.by-os 4 4103 4103) Value Length) 0)
             (socket.fail "getsockopt")
             (shen-jit.u32 Value 0))))

\\ ---------------------------------------------------------------------------
\\ Servers.

(define socket.listen
  Host Port -> (socket.first-working (/. A (socket.listen-on A)) (socket.addresses Host Port 1)
                                     (make-string "socket: no address for ~A" Host)))

(define socket.listen-on
  [Family Type Protocol Address]
  -> (let S (socket.make Family Type Protocol)
       (socket.closing-on-error S (freeze (socket.bind-and-listen S Address)))))

\\ SO_REUSEADDR lets a server restart at once. On Windows it would let another take its port.
(define socket.bind-and-listen
  S Address -> (do (if (socket.windows?) skip (socket.set-option S (socket.by-os 1 65535 0) (socket.by-os 2 4 0) 1))
                   (cases (< (socket.c-bind S Address (shen-jit.bytes-length Address)) 0) (socket.fail "bind")
                          (< (socket.c-listen S 128) 0) (socket.fail "listen")
                          true S)))

(define socket.accept
  Listener -> (let S (socket.c-accept Listener [] [])
                (cases (>= S 0) (socket.set-up S)
                       (socket.again?) (do (socket.wait Listener (socket.readable-event))
                                           (socket.accept Listener))
                       true (socket.fail "accept"))))

\\ ---------------------------------------------------------------------------
\\ Data.

(define socket.send
  S Data -> (socket.send-bytes S (if (string? Data) (shen-jit.string->bytes Data) Data)))

(define socket.send-bytes
  S B -> (let Length (shen-jit.bytes-length B)
              Chunk (shen-jit.bytes (socket.min Length 65536))
           (do (socket.send-from S B 0 Length Chunk) Length)))

\\ A call takes a buffer's start and not a place in it, so what is sent goes through Chunk, and
\\ what a short send leaves is copied again.
(define socket.send-from
  _ _ Length Length _ -> true
  S B At Length Chunk -> (let N (socket.min (- Length At) (shen-jit.bytes-length Chunk))
                              Copied (shen-jit.copy-bytes Chunk 0 B At N)
                            (socket.send-from S B (+ At (socket.send-some S Chunk N)) Length Chunk)))

(define socket.send-some
  S Chunk N -> (let Sent (socket.c-send S Chunk N (socket.send-flags))
                 (cases (>= Sent 0) Sent
                        (socket.again?) (do (socket.wait S (socket.writable-event))
                                            (socket.send-some S Chunk N))
                        true (socket.fail "send"))))

(define socket.recv-into
  S Buffer -> (let Got (socket.c-recv S Buffer (socket.min (shen-jit.bytes-length Buffer) 1073741824) 0)
                (cases (>= Got 0) Got
                       (socket.again?) (do (socket.wait S (socket.readable-event))
                                           (socket.recv-into S Buffer))
                       true (socket.fail "recv"))))

(define socket.recv
  S N -> (let Buffer (shen-jit.bytes N)
              Got (socket.recv-into S Buffer)
           (if (= Got N)
               Buffer
               (shen-jit.copy-bytes (shen-jit.bytes Got) 0 Buffer 0 Got))))

(define socket.recv-string
  S N -> (let B (socket.recv S N)
           (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

\\ ---------------------------------------------------------------------------

\\ SHUT_WR, which Windows calls SD_SEND
(define socket.shutdown
  S -> (if (< (socket.c-shutdown S 1) 0) (socket.fail "shutdown") true))

\\ IPPROTO_TCP and TCP_NODELAY
(define socket.no-delay
  S -> (do (socket.set-option S 6 1 1) true))

(define socket.close
  S -> (if (< (socket.c-close S) 0) (socket.fail "close") true))

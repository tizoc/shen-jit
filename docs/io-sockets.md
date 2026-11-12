# Socket I/O endpoints

[lib/io-socket.shen](../lib/io-socket.shen) adapts existing TCP connections to [chunk I/O](io.md).
Connection setup remains in `lib/socket.shen`: its integer API, DNS handling, listen/connect/accept and
nonblocking configuration stay available. The adapter owns connected sockets, supplies partial transfers
with structured errors, and works with the same readers/writers as memory and files. It uses no kernel
streams or new runtime code.

Load libraries with type checking off, in this order:

```sh
shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen \
  -l lib/io.shen -l lib/io-socket.shen -l lib/frame.shen \
  -l tools/frame-echo.shen -l program.shen
```

The native backend needs dynamically loadable system libraries. Fully static builds still support managed
I/O and framing, but cannot load the existing socket FFI backend.

## Ownership

`io.socket Socket Name` consumes ownership of one connected socket returned by `socket.connect` or
`socket.accept`, and returns an `io.endpoint` with a 65536-byte capacity. Name is an application-supplied
string used in errors. Perform any raw socket configuration before wrapping it.

```shen
(define connect-owned
  Host Port -> (io.socket (socket.connect Host Port) "client"))
```

Connection setup can raise using the existing socket API; the adapter does not change those errors or
promise native codes for setup. `io.socket` validates its arguments before adopting the integer. After
valid arguments transfer ownership, construction failure closes it. It assumes an already connected,
nonblocking socket with the setup performed by `socket.shen`; it does not inspect or configure arbitrary
external descriptors.

After wrapping, use only the endpoint for that connection. Do not close, shut down, transfer, or wrap the
raw integer again. The adapter cannot invalidate separately copied integers or prevent duplicate wrapping.
Endpoint aliases share closed state and one native identity. Explicit close happens once, including when
native close fails. Image loading invalidates the identity before its old numeric descriptor can affect a
new connection. The guard stores the full supported 64-bit socket value on Windows.

A listener remains a raw integer owned by the application; close it with `socket.close`. The adapter does
not add a listener registry, event loop, process inheritance policy or task synchronization. Existing
socket inheritance behavior is unchanged. One task owns each connected endpoint and its lifetime; sending
or closing it from another task while an operation is active is unsupported.

## Transfers and waiting

Use `io.read-some`, `io.write-some`, `io.read-exact`, `io.write-all`, `io.reader` and `io.writer` with their
usual contracts. The adapter uses nonblocking native `recv` and `send` directly on bounded managed chunks.
An isolate's heap does not move during the call, so neither do those buffers. A positive result is acknowledged
immediately; a short send is reported to the I/O core, whose writer retains the unsent suffix.

Readiness shortage and EINTR wait/retry in Shen. Polling waits use 100 ms slices, between which the
runtime's interruption checks run.
[Absolute deadlines](deadlines.md) can bound a complete operation across retries and partial progress.
Install one with `io.socket-deadline E D`, or remove it with `io.socket-unlimited E`. Transfer options
remain `[]`; cancellation is not implemented. Slices alone are not operation timeouts. Unexpected
exceptions, including interruption, follow the core's raising/scope cleanup behavior.

Transfer, poll, shutdown and close failures preserve operation, Name and the native domain/code in the I/O
error record. POSIX errors use domain `posix`; Windows uses `winsock` and
[WSAGetLastError](https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-wsagetlasterror).
The code is captured before another socket call or cleanup. On POSIX the message uses `strerror`; Windows
messages include the Winsock number. A zero nonempty native send becomes the I/O core's no-progress error.

The adapter reuses the existing socket setup/send flags that suppress SIGPIPE. EOF ends the read direction
without closing the write direction. A reset or another failed read is an error rather than clean EOF.

## Graceful write shutdown

`io.shutdown-write Endpoint` returns `[ok]` or `[error Error]`. It first flushes an attached writer, then
sends native write shutdown. If flushing fails, pending bytes remain and shutdown is not attempted; retry
the flush or close explicitly. Native shutdown failure also leaves the endpoint's write state unchanged.

After success, repeated shutdown returns `[ok]`, reads still work, and new writes through either the
endpoint or its old writer raise, including empty writes. Full `io.close` remains separate and returns its
remembered result. Close after successful shutdown does not flush the detached, already drained writer.
This supports request EOF followed by a server response without prematurely closing the whole connection.

`io.socket-cancel Endpoint` permanently cancels nonempty backend I/O on an endpoint. It preserves
acknowledged progress and leaves close to the endpoint's owner. See [cancellation](http-listener.md#cancellation-and-kills).

## A bounded session handler

Load [tools/frame-echo.shen](../tools/frame-echo.shen) with the libraries above. A one-connection program
can accept a peer, close its listener, then run the [binary framing](framing.md) handler:

```shen
(let Listener (socket.listen "127.0.0.1" 9000)
     Peer (socket.closing-on-error Listener (freeze (socket.accept Listener)))
     _ (socket.close Listener)
  (frame-echo.serve (io.socket Peer "echo peer") 1048576))
```

The handler owns the connected endpoint, echoes each complete frame and flushes before accepting the
next message. It returns after peer EOF or failure. A real server still needs a connection cap and an
accept loop. [HTTP head framing](http-head.md) and deadlines support the
[complete requests, bounded bodies and responses](http.md) provided by the one-request HTTP driver.

`make test-io` tests loopback transfer, large framed echo, half-close, failed-flush retention, native error
capture, repeated close, image invalidation and targeted every-allocation GC. No external network service
is needed. Typed clients use the core's `io.endpoint` and result types; load the libraries with `(tc -)`
before enabling `(tc +)` for the client.

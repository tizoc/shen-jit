# HTTP servers

[lib/http-listener.shen](../lib/http-listener.shen) runs the [HTTP request/response handler](http.md)
on the connections a listening socket accepts, one at a time, in the program that calls it. It uses our own
socket I/O and native waits; it adds no runtime primitives or C adapter. Load it after the libraries needed
by `http-server.shen`. Native libraries are required, so this module is unavailable in static builds.

Connections are served in turn: while one is served, the others wait in the operating system's listen
backlog. A later version will serve each connection in an [isolate](guide.md#isolates) of its own.

## Starting and stopping

```shen
(set example.server [])

(define example.handler
  Request -> (do (http.stop (value example.server))
                 (http.response 200 [["Content-Type" "text/plain"]] (buffer.from-string "hello"))))

(let S (http.listen "127.0.0.1" 0 (function example.handler) [[body-limit 65536]])
     _ (set example.server S)
     C (socket.connect "127.0.0.1" (http.port S))
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     Result (http.run S)
  [Result (socket.recv-string C 4096)])
```

The client connects and sends its request before `http.run`: on loopback, both wait in the backlog.

`http.listen Host Port Handler Options` binds and returns an opaque `http.server`, serving nothing yet. Port
zero selects a free port; `http.port S` returns the actual port. Invalid options raise before opening the
listener. A bind failure raises and closes any acquired socket.

`http.run S` serves connections until the server is stopped, then closes the listener and returns
the result. It accepts one connection and runs `http.serve-connection` on it, with its body, head and output
limits, deadlines and cleanup, until that connection ends: requests are handled in order under the
request-count, idle and total-connection bounds. Then it accepts the next. A client that keeps a connection
open, or stalls in a request, holds the others back until its own idle, head or body timeout ends it.

`http.stop S` requests shutdown and returns true. It is idempotent, and a handler calls it, as nothing else
runs during `http.run`. The connection being served closes after its active response is written, without
dispatching requests queued behind it; connections waiting in the backlog are not served.

| Result of `http.run` | Meaning |
| --- | --- |
| `[ok]` | The server was stopped and the listener is closed |
| `[error Error]` | The listener failed; it is closed, and Error retains cleanup failures |

Running a server that has finished gives its result again. `http.wait S Milliseconds` gives that result
once `http.run` has returned, and `[pending]` before. Ordinary malformed requests, handler exceptions and peer
failures count as failed connections; they do not stop the server or make its result an error.

Native servers saved in an image reload stale; recreate them rather than trying to run or stop a saved one.

## Limits and observations

Options are `[Name Number]` pairs. They accept all the [request/response options](http.md#one-request-per-connection) and
[persistence options](http.md#persistent-connections), plus `max-connections` (1..1024, default 16) and
`shutdown-grace` (0..600000 ms, default 1000), which are checked and kept for the version that serves
connections in isolates; serving in turn uses neither.

Unknown, malformed and duplicate options raise. Fixed responses and request metadata occupy memory up to
the configured body and response limits. [Streaming responses](http-streaming.md) retain a bounded
head/chunk instead of copying the whole response. Producer-owned resources need their own bounds.

`http.state S` reports `listening`, `draining` (stopped while a connection is served) or `stopped`.
`http.stats S` returns, in this order:

```text
[Active Accepted Completed Failed Cancelled Peak]
```

Active is 1 while a connection is served, Completed includes failures, Cancelled is 0 and Peak at most 1.
Statistics retain counters, not a history of requests or exception messages. Use application logging when
the details of individual failures are needed.

## Cancellation

`io.socket-cancel Endpoint` sets a permanent cancellation flag on an endpoint. It does not close the
descriptor, discard acknowledged bytes or clear a deadline. Subsequent nonempty backend I/O returns an error
with domain `cancelled`; partial transfer progress is preserved. Repeated cancellation, including after
close, is harmless. Installing a new deadline or removing a deadline does not undo cancellation. Do not use
saved native endpoints after loading an image.

## A complete application

[example-apps/sqlite-http](../example-apps/sqlite-http/README.md) contains a persistent counter API with
JSON requests/responses, parameterized SQL, per-request database ownership and explicit local shutdown. Its
README gives launch commands, routes and the independent Python HTTP/SQLite test.

`make test-http` includes serving in turn, stopping from a handler, handler and listener failure,
typed-option, image and every-allocation GC cases, plus the counter application's database tests and
persistent pipelines. Native cases skip explicitly on static builds. Streaming request delivery, TLS and
signal handling remain separate work.

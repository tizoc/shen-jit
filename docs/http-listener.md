# HTTP servers

[lib/http-listener.shen](../lib/http-listener.shen) runs the [HTTP request/response handler](http.md)
on the connections a listening socket accepts, each in an [isolate](guide.md#isolates) of its own, at most
a configured number at once, so that one connection that waits holds no other back and handlers run in
parallel. The program that calls `http.run` supervises them. Load it after the libraries needed by
`http-server.shen`. Native libraries are required, so this module is unavailable in static builds.

## Starting and stopping

```shen
(define example.handler
  Request -> (do (http.stop (http.current-server))
                 (http.response 200 [["Content-Type" "text/plain"]] (buffer.from-string "hello"))))

(let S (http.listen "127.0.0.1" 0 example.handler [[max-connections 8] [body-limit 65536]])
     C (socket.connect "127.0.0.1" (http.port S))
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     Result (http.run S)
  [Result (socket.recv-string C 4096)])
```

The client connects and sends its request before `http.run`: on loopback, both wait in the backlog. A
client that runs while the server does belongs in an isolate of its own.

`http.listen Host Port Handler Options` binds and returns an opaque `http.server`, serving nothing yet. Port
zero selects a free port; `http.port S` returns the actual port. Invalid options and handlers raise before
opening the listener. A bind failure raises and closes any acquired socket.

A handler runs in its connection's isolate, which inherits nothing from the program that defined it, so it
goes by name: `F`, a function of the request, or `[F | Args]`, called with `Args` and then the request,
which are copied to each connection as a spawn argument is. A closure cannot cross, and the globals a handler
reads start unbound: what it needs comes in `Args`. Typed code gives the name, or the name and a list.

`http.run S` serves connections until the server is stopped, then closes the listener and returns the
result. It admits a connection only when fewer than `max-connections` are open; the others wait in the
operating system's listen backlog, and the server allocates nothing for them. Each admitted connection
gets an isolate that serves it as `http.serve-connection` does, with a check between requests for whether the server
is stopping, and its body, head and output limits, deadlines and cleanup,
which owns the socket from then on: requests are handled in order under the request-count, idle and
total-connection bounds. Request deadlines start on admission.

`http.stop S` requests shutdown and returns true, and is idempotent. Called before `http.run`, it makes the
run stop at once. A handler stops the server it serves with `(http.stop (http.current-server))`:
`http.current-server` gives, in a handler, a copy of the server that gives its port and stops it, and
raises elsewhere. Then the supervisor closes the listener and gives the open connections `shutdown-grace`
to finish: a connection closes after its active response is written, without dispatching requests queued
behind it, and an idle persistent one closes within 50 ms. Once the grace has passed, it kills the
connections left, and waits for them to end.

| Result of `http.run` | Meaning |
| --- | --- |
| `[ok]` | The server was stopped, the listener is closed and every connection has ended |
| `[error Error]` | The listener failed; it is closed, the connections were killed, and Error retains cleanup failures |

Running a server that has finished gives its result again. `http.wait S Milliseconds` gives that result
once `http.run` has returned, and `[pending]` before, at once: as `http.run` returns only when the server has
ended, there is nothing to wait for, and Milliseconds stays for the code written for it. Ordinary malformed requests, handler exceptions and peer
failures count as failed connections; they do not stop the server or make its result an error.

Ctrl-C in a REPL that runs a server returns to the prompt, as a program's handlers cannot hold it back, and
leaves the server as it was, listening, its open connections served: `http.run` goes on serving, and
`http.stop`, then `http.run`, closes it.

While a server runs, the program is fixed, as it is while any isolate runs: define everything first.
Native servers saved in an image reload stale; recreate them rather than trying to run or stop a saved one.

## Limits and observations

Options are `[Name Number]` pairs. They accept all the [request/response options](http.md#one-request-per-connection) and
[persistence options](http.md#persistent-connections), plus:

| Option | Default | Range |
| --- | --- | --- |
| `max-connections` | 16 | 1..1024 connections, each an isolate |
| `shutdown-grace` | 1000 ms | 0..600000 ms |

Unknown, malformed and duplicate options raise. The connection cap bounds the number of isolates; multiply
the configured body and response limits by that cap when choosing a memory budget. Fixed responses and
request metadata occupy memory up to those limits. [Streaming responses](http-streaming.md) retain a bounded
head/chunk instead of copying the whole response. Producer-owned resources need their own bounds.

`http.state S` reports `listening`, `draining` (stopped, while connections finish), `cancelling` (killed,
while they end) or `stopped`. `http.stats S` returns, in this order:

```text
[Active Accepted Completed Failed Cancelled Peak]
```

Completed includes failures, and Cancelled counts the connections killed when the grace had passed, which
are counted as failed too. Active can include a connection that has ended until the supervisor next looks,
within 50 ms. Statistics retain counters, not a history of requests or exception messages. Use application
logging when the details of individual failures are needed. In a handler, `http.state`, `http.stats`,
`http.wait` and `http.run` raise: the copy knows only its port.

## Cancellation and kills

A kill reaches a connection at its next socket wait, whose poll slices last at most 100 ms, or at its next
check for a stop. It does not interrupt a handler that computes or waits in a foreign call, such as a
database query: once that returns, the connection's next socket operation ends it. Until then the run waits.
A peer whose unfinished request is cut off sees the connection close; no HTTP rejection is fabricated.

`io.socket-cancel Endpoint` sets a permanent cancellation flag on an endpoint. It does not close the
descriptor, discard acknowledged bytes or clear a deadline. Subsequent nonempty backend I/O returns an error
with domain `cancelled`; partial transfer progress is preserved. Repeated cancellation, including after
close, is harmless. Installing a new deadline or removing a deadline does not undo cancellation. Do not use
saved native endpoints after loading an image.

## A complete application

[example-apps/sqlite-http](../example-apps/sqlite-http/README.md) contains a persistent counter API with
JSON requests/responses, parameterized SQL, per-request database ownership and explicit local shutdown. Its
README gives launch commands, routes and the independent Python HTTP/SQLite test.

`make test-http` includes concurrent and capped connections, stalled connections killed after the grace,
graceful responses, handler arguments, handler and listener failure, typed-option, image and
every-allocation GC cases, plus the counter application's database tests and persistent pipelines. Native
cases skip explicitly on static builds. Streaming request delivery, TLS and signal handling remain separate
work.

# SQLite HTTP counter service

A complete small application over the public HTTP and SQLite libraries. It keeps named counters in a
database file and returns JSON. Each admitted request owns its database connection and prepared
statements; an increment runs in a transaction, so simultaneous requests do not lose updates.

Run from the repository root with a shared-capable Shen/JIT build and SQLite installed:

```sh
build/shen-jit script example-apps/sqlite-http/run.shen counters.db 9000
```

From a release archive, which carries this directory, run it from the archive's root with `./shen-jit` in
place of `build/shen-jit`. The static Linux builds cannot load SQLite.

The service binds to `127.0.0.1`. Its defaults are 16 active connections, a 4096-byte request-body bound,
a 65536-byte response-body bound and a 1000 ms shutdown grace period. HTTP parsing, buffering,
deadlines and connection management use our own I/O libraries. Kernel loading is used only to load code.
The port argument is decimal 0..65535; zero selects a free port printed at startup. The database must be
a dedicated file, rather than `:memory:`, because requests use separate connections.

## Requests

```sh
curl -X POST http://127.0.0.1:9000/counters/hits
curl http://127.0.0.1:9000/counters/hits
curl -X PUT -H 'Content-Type: application/json' --data-binary '{"value":42}' http://127.0.0.1:9000/counters/hits
curl http://127.0.0.1:9000/counters
curl http://127.0.0.1:9000/counters.ndjson
curl -I http://127.0.0.1:9000/counters/hits
curl -X DELETE http://127.0.0.1:9000/counters/hits
curl -X POST http://127.0.0.1:9000/shutdown
```

| Route | Behavior |
| --- | --- |
| `GET /health` | `{"status":"ok"}` |
| `GET /counters` | Up to 100 counters ordered by name, such as `[{"name":"hits","value":1}]` |
| `GET /counters.ndjson` | Stream up to 100 ordered counters as newline-delimited JSON using chunked framing |
| `GET /counters/NAME` | `{"value":1}`, or 404 when absent |
| `POST /counters/NAME` | Create at zero if absent, then increment atomically and return the value |
| `PUT /counters/NAME` | Set/create from `{"value":42}` with Content-Type application/json |
| `DELETE /counters/NAME` | Delete and return 204, or 404 when absent |
| `POST /shutdown` | Return 202 with `{"stopping":true}`, close that connection, then stop accepting and drain the server |

HEAD follows GET routes without response bytes. Fixed responses advertise representation length;
NDJSON advertises chunked framing and closes its source without stepping the query. Other methods on known
routes return 405 and Allow. PUT accepts a bounded JSON object with exactly one `value` member. Other request bodies must be empty.
Responses and PUT input use the public [JSON library](../../docs/json.md). Content-Length and chunked
request bodies both work, with the same decoded-size bound and total deadline. Duplicate JSON keys,
invalid UTF-8, unknown members and invalid values return 400; an unsupported/missing media type returns 415.
The media type accepts ASCII case variations of application/json, with optional `charset=utf-8` in the
shown conventional form. The value must be a decimal integer token in 0..1000000000000; exponent and
fraction forms are rejected by the application schema even when mathematically integral.
Names are 1..64 ASCII letters, digits, underscores or hyphens. Targets are not percent-decoded and query
parameters are unsupported. Values are integers bounded by the database constraint at 1000000000000;
a constraint or other database failure produces the HTTP driver's empty 500 response and rolls back.
The list limit is fixed; this example does not implement pagination.

HTTP/1.1 connections can serve up to 100 sequential requests, with a 5-second idle limit and a
60-second total lifetime. Each connection runs in an isolate of its own, up to the listener's
`max-connections`, and each request still opens its own database connection; concurrent writes wait for
each other under SQLite's 5-second busy timeout. The NDJSON source owns
its prepared SELECT and database until completion/disconnect. It batches rows under both a 16 KiB cap
and the sender's chunk bound, holding one encoded row and one output batch. It checks the total 5-second
write budget while assembling batches; even a one-byte chunk bound preserves every row and newline. A slow export can hold a
SQLite read lock until that budget is observed; this small example does not enable WAL or implement
pagination. Streaming storage and database lifetimes remain bounded by the row/output/time limits.

## Shutdown

Use `POST /shutdown` for controlled shutdown of the runnable example. Its handler calls
`(http.stop (http.current-server))`, the response is written, and the listener closes. Active work gets the
listener's grace period, after which the connections left are killed at their next socket wait, and
`http.run` returns. SQLite calls already in progress finish under SQLite's busy timeout.

Scripts currently receive Ctrl-C as process termination. It does not invoke this application's graceful
stop path. Catchable interruption at the REPL has different semantics. Signal-driven service shutdown
would need separate runtime/library support; this example uses an explicit application command.

## Files and tests

`main.shen` holds the routes, database scopes, startup and shutdown. `run.shen` loads their public
dependencies and passes the command-line arguments. Applications can instead load `main.shen` and call
`counter-app.start Path Host Port Options`, which returns an `http.server` that its caller serves with
`http.run` until it is stopped. Its handler is `[counter-app.handle Path]`, as a handler runs in an isolate of
its connection's, which inherits no globals. The `/shutdown` control route is supplied by `counter-app.run`.

```sh
python3 example-apps/sqlite-http/test.py build/shen-jit
make test-http
```

The independent Python test uses temporary files, HTTP clients and SQLite to check routes, HEAD,
malformed input, parameter handling, JSON PUT bodies, 32 concurrent increments, persistence across restart,
streaming NDJSON, repeated requests on the same socket, and shutdown with stalled fixed-body and
chunk-extension input. It also launches `run.shen` and exercises its shutdown command with a stalled
connection open. `make test-http`
runs the Shen regression tests on supported platforms, including static-build skips for native parts.

The [HTTP servers reference](../../docs/http-listener.md) documents the reusable API and ownership
rules. The application has no C code, private runtime calls, external web framework or kernel-stream I/O.

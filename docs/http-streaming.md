# Streaming HTTP responses

[lib/http/response.shen](../lib/http/response.shen) sends bounded response chunks over our own
[I/O endpoints](io.md). It supports explicit lengths and HTTP/1.1 chunked output, without collecting the
whole body. The [connection driver](http.md#persistent-connections) and [listener](http-listener.md)
accept both fixed and streaming descriptions. No runtime changes or C HTTP library are needed.

Load the module `http/response`, which loads the others first. Managed endpoints and injected clocks work in static builds;
native socket servers also need the libraries listed in the [HTTP reference](http.md).

## Response sources

`http.source Next FrozenClose` creates a single-use `http.source`. Its next callback takes
`Maximum Deadline` and returns one of:

| Result | Meaning |
| --- | --- |
| `(:result.ok [View])` | 1..Maximum bytes, stable until the next callback or cleanup |
| `(:result.ok [])` | Successful completion |
| `(:result.err Error)` | Producer failure, with an `io.error` |

The close callback takes no arguments and returns `(:result.ok [])` or `(:result.err Error)`. It runs exactly once on
successful completion, HEAD/bodyless suppression, invalid metadata, producer error, timeout,
cancellation or write failure. It must release all resources it owns, even after an expired deadline.
Exceptions and malformed callback results become structured errors. Cleanup failures are preserved as
secondary errors when another failure already exists.

```shen
(shen.x.namespace example
  (use http)
  (use buffer)
  (import result ok)
  (externals [chunked])
  (shadow stream)
  (export stream)

  (define stream
    -> (let State (address-> (absvector 1) 0 false)
         (http.stream-response 200 [["Content-Type" "text/plain"]] [chunked]
           (http.source
             (/. Maximum D
               (if (<-address State 0)
                   (:ok [])
                   (do (address-> State 0 true)
                       (:ok [(buffer.from-string "hello")]))))
             (freeze (:ok [])))))))

(let Head (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;")
     Out (buffer.new 256)
  (result.let-ok Q (http.parse-request Head 0)
    (io.with-endpoint (io.output-buffer Out)
      (/. E (http.send-response E Q (example.stream) (deadline.after (freeze 0) 1000)
              [[response-chunk-size 16]])))))
```

This produces `(:result.ok 107)`: a head, `5\r\nhello\r\n`, and the final `0\r\n\r\n`. The example's producer
emits one five-byte chunk under the configured bound. General producers must split pending data when
Maximum is smaller, and check/use D when doing their own I/O. The sender checks the deadline before and
after each callback, but cannot interrupt arbitrary computation or a blocking foreign call.
A server handler can return `(example.stream)` directly; the connection driver supplies Date and
chooses connection lifetime.

`http.stream-response Status Fields Framing Source` returns an `http.response`. Framing is:

- `[length N]`: advertise Content-Length N and require exactly N producer bytes, followed by EOF.
  Early EOF and extra bytes fail. The sender probes for EOF with Maximum 1 after reaching N.
- `[chunked]`: emit Transfer-Encoding: chunked and a final zero chunk only after successful EOF.
  Empty data chunks are invalid; use `(:result.ok [])` for an empty stream.

Status and field rules match [fixed responses](http.md#response-encoding). HEAD sends representation
framing without pulling the source or emitting chunk delimiters; it still closes the source. Statuses
204, 205 and 304 require `[length 0]`, never pull, and retain the fixed encoder's length rules.
The pure `http.encode-response` remains fixed-body only: passing it a stream raises without consuming
or closing its source.

## Ownership and backpressure

A source belongs to its creator until its valid response is returned to the connection driver or passed
to `http.send-response`. That transfers responsibility for cleanup to the sender. A handler that creates
a source and then raises before returning it must close its own resource. `http.source-close Source`
allows explicit, idempotent cleanup before transfer. A source cannot be reused for another response,
closed during a callback, or operated on from another task. Saved sources reload stale; recreate them
without replaying captured callbacks or native resources.

The sender validates headers and primes at most one chunk before committing any output. It writes
that whole frame, including all short writes, before asking for another chunk. There is no producer
queue or unbounded read-ahead. Additional output storage is bounded by the head and one chunk plus
its framing; producer-retained data has its own application budget. Fixed responses keep their owned
wire snapshot.

A metadata or first-pull failure lets the server send one empty closing error response before any
application output. Once output starts, any failure closes the connection, leaving a truncated response.
It never appends an error response or a successful chunk terminator after a producer failure. Even if
cleanup fails after all bytes were sent, that connection is not reused. A source error retains its
original details as a secondary error; application exception text is not sent to the peer.

## Direct sending and bounds

`http.send-response Endpoint Request Response Deadline Options` borrows a writable endpoint and
returns `(:result.ok WireBytes)` or `(:result.err Error)`. It sends `Connection: close`; its caller owns endpoint
cleanup and socket deadline installation. The supplied absolute deadline covers preparation, every
producer callback, short write and terminal framing. For native sockets, install that same value with
`io.socket-deadline` so native waiting is bounded too. Managed output is checked between short writes.

| Option | Default | Range / meaning |
| --- | --- | --- |
| `response-head-limit` | 16384 | 4..1048576 encoded head bytes; the server requires at least 128 |
| `response-body-limit` | 1048576 | Nonnegative payload byte bound, excluding wire framing |
| `response-chunk-size` | 16384 | 1..1048576 bytes per producer chunk |
| `response-chunk-count-limit` | 4096 | 1..1048576 nonempty producer chunks |

Known lengths are checked against the body bound before pulling. Unknown lengths and chunk counts are
checked incrementally; one bounded EOF probe distinguishes completion from overflow at either limit.
Options must be unique, known numeric pairs. These options also work with `http.serve-one`,
`http.serve-connection` and `http.listen`. Fixed responses use the same head/body bounds.

Successful counts include headers and chunk framing. Output failures report acknowledged wire bytes
for this response in `io.error-progress`, including short writes. Input failures retain their decoded
input progress; connection totals do not overwrite a failing operation's count. Cleanup after successful
output retains that output count if cleanup itself fails.

## Example and validation

The [SQLite counter application](../example-apps/sqlite-http/README.md) streams up to 100 rows from a
prepared statement as NDJSON at `/counters.ndjson`. Its source batches rows into at most 16 KiB and the sender's Maximum, retaining only the current encoded
row and one output batch. Rows/newlines can cross chunk boundaries. It checks the deadline while building
each batch and finalizes its statement and database connection on every exit, including HEAD/disconnect.

`make test-http` covers managed short writes, exact/unknown lengths, output limits, deadline expiry,
cleanup errors, typed APIs, stale images, every-allocation GC and native persistent connections.
`python3 tests/http_persistent.py build/shen-jit` checks pipelined fixed/chunked responses and HEAD
boundaries with an independent client, plus truncation on producer failure and deadline expiry.

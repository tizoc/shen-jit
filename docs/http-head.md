# HTTP head framing

[lib/http/head.shen](../lib/http/head.shen) captures one bounded HTTP header block through its final
CRLFCRLF, using our [chunk I/O](io.md) reader. It scans each incoming span once, retains delimiter state
across splits, and leaves body or subsequent bytes in the reader. It uses no kernel stream or C parser.

This is byte framing for the [complete request parser](http.md). It does not validate request-line syntax, field names,
Host, Content-Length, Transfer-Encoding or other HTTP semantics, and does not decide message body length.
An accepted block is not by itself a validated HTTP request. The protocol boundary follows the message
structure in [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html#section-2.1); the initial framing policy
requires CRLF and rejects bare LF, CR followed by another byte, NUL, DEL and controls other than HTAB.
Bytes above ASCII are retained; text decoding is separate.

Load the module `http`, which loads `buffer` and `io` first:

```sh
shen-jit eval -m http \
  -e '(define head-length (:result.ok [V]) -> (buffer.length V))' \
  -e '(let E (io.input-buffer (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;body")) R (io.reader E [[chunk-size 2]]) F (http.head-reader R 4096) Head (http.read-head F) Body (io.read-all R 4) _ (io.close E) (result.let-ok B Body [(head-length Head) (buffer.string B)]))'
```

This returns `[35 body]`. A program must match error/EOF alternatives before extracting a successful view.
Managed framing works on static builds and does not need the FFI.

## Operations and limits

| Operation | Meaning |
| --- | --- |
| `http.head-reader Reader Limit` | A framer borrowing one existing I/O reader |
| `http.read-head F` | `(:result.ok [OwnedView])`, `(:result.ok [])` or `(:result.err Error)` |
| `http.read-head-until F Deadline` | The same capture, checking a total budget between spans and before completion |

The explicit byte limit includes the final four delimiter bytes. It must be a fixnum from 4 through
1048576. Invalid arguments raise before reading. A complete block exactly at the limit succeeds; reaching
the limit without a complete delimiter fails immediately without consuming the next byte. The four-byte
empty delimiter can be framed, but requires rejection by a complete request parser.

The accumulator is allocated once at the limit; bytes are appended without rebuilding a growing string.
The delimiter scan starts where the previous span ended. The I/O reader's bounded queue is the only
read-ahead queue. It may prefetch beyond the header, but framing consumes only the selected prefix.
`io.peek-some` waits for at least one byte and exposes the currently available span, so capture does not
wait for a full reader buffer or for the peer to close.

Returned bytes include CRLFCRLF and own their storage. They survive later reader use, refill and endpoint
close. On completion the framer drops its accumulator. Peak storage is bounded by the head limit, its
final copy, and reader/endpoint chunk capacities; retaining many returned views remains the caller's choice.
A framer captures one head. It remembers its first successful result, EOF or error; repeated calls return
that result without consuming another message. Use a complete body-framing policy before reusing input
for another request. One task owns the framer and its reader, with no independent reader consumption while
capture is active. The framer does not close its endpoint.

## Failure and deadlines

EOF before any byte returns `(:result.ok [])`; EOF within a partial head is `"incomplete head"`. Framing errors use
operation `http-head`, domain `library` and resource `"HTTP head"`. Transport errors retain native details.
Progress counts bytes consumed by this capture; for a transport failure it includes all earlier spans.
An invalid byte is included in that consumed count. Unprocessed suffix bytes stay in the I/O reader.

Errors, including timeouts, are terminal for this capture. An unexpected backend exception raises and
poisons the framer. Operations on a closed/stale underlying endpoint raise. A saved managed framer can
resume with its reader; saved native resources and deadlines must be recreated as described on their pages.

`http.read-head-until` needs [deadline.shen](deadlines.md). It checks the same absolute budget before each
span and again before publishing a completed block, including when all bytes were already queued. It
cannot interrupt an arbitrary backend that ignores deadlines while waiting. On sockets, install that same
budget on the endpoint before reading:

```shen
(define read-timed-head
  E Limit Milliseconds ->
    (let D (clock.deadline Milliseconds)
         _ (io.socket-deadline E D)
         F (http.head-reader (io.reader E []) Limit)
      (http.read-head-until F D)))
```

Load the modules `clock`, `io/socket` and `http` for that function. A new response phase can install a fresh budget;
reads that return short prefixes do not create new header budgets. Cancellation, connect/accept/DNS
budgets, [request parsing, bounded bodies and response encoding](http.md) are available above this layer;
a listener loop remains separate work.

## Types and capture example

The reader has type `http.head-reader`. Both read functions return `(io.result (option.t buffer.view))`.

```shen
(shen.x.namespace example
  (use option)
  (use buffer)
  (use http)
  (use io)
  (import result ok err)
  (export head-size)

  (define head-size
    {(io.result (option.t buffer.view)) --> fixnum}
    (:ok [V]) -> (buffer.length V)
    (:ok []) -> 0
    (:err Error) -> (io.error-progress Error)))
```

[tools/http-head-capture.shen](../tools/http-head-capture.shen) combines the socket policy and framer in
an owned connection scope. `http-head.capture Endpoint Limit Milliseconds` returns `(:result.ok OwnedView)` or
`(:result.err Error)` and closes the endpoint on success or failure. This debugging example sends no HTTP
response; it is not yet an HTTP server. It demonstrates that framing can finish before peer EOF under
one total deadline.

`make test-io` covers every small-header split and truncated prefix, byte limits, invalid controls, body
preservation, fake-clock expiry, native timeouts, typed clients and saved-image/GC behavior. The optional
independent TCP check is `python3 tests/http_head_wire.py build/shen-jit`; it verifies captured wire bytes,
oversized rejection and a peer that keeps sending slowly beyond its original budget.

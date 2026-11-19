# Binary framing

[lib/frame.shen](../lib/frame.shen) reads bounded messages from our [chunk I/O](io.md) readers. It is a
small concrete binary format, independent of kernel streams and a general parser compiler. Its wire format
matches the complete-input packet example on the [buffers page](buffers.md):

| Bytes | Field |
| --- | --- |
| 0–1 | Unsigned 16-bit tag, big-endian |
| 2–5 | Unsigned 32-bit payload length, big-endian |
| 6 onward | Exactly that many payload bytes |

Load the module `frame`, which loads `buffer` and `io` first. Memory framing needs no FFI and
works on static builds. File input additionally uses the module `io/file`, and TCP
[`io/socket`](io-sockets.md).

```sh
shen-jit eval -m frame \
  -e '(define describe-frame (:result.ok [(:frame.frame Tag Payload)]) End -> [Tag (buffer.string Payload) End])' \
  -e '(let E (io.input-buffer (frame.encode 42 (buffer.from-string "hello") 1024)) F (frame.reader (io.reader E [[chunk-size 2]]) 1024) Result (frame.next F) End (frame.next F) _ (io.close E) (describe-frame Result End))'
```

This returns `[42 hello #<result.ok []>]`, even though the header and payload cross several reader chunks.
Programs should match the error alternative before extracting a successful frame.

## Operations

| Operation | Meaning |
| --- | --- |
| `frame.encode Tag Payload Limit` | An owned wire-format view, including the six-byte header |
| `frame.reader Reader Limit` | A framer borrowing an existing I/O reader |
| `frame.next F` | `(:result.ok [(:frame.frame Tag OwnedPayload)])`, `(:result.ok [])` or `(:result.err Error)` |
| `frame.position F` | The underlying reader's consumed position |

Tag must be a nonnegative fixnum at most 65535. Limit is a nonnegative fixnum at most 4294967295. An
integral boxed float is refused. The payload limit is mandatory for encoding and decoding; a payload whose
advertised length exceeds it is rejected after the header, before allocation or payload consumption.
Encoding validates arguments before allocating output and copies only Payload's logical range. A zero
limit allows empty frames. No integer conversion through a floating-point value is involved.

Each successful `next` consumes one header and payload. The reader may prefetch subsequent frames into its
bounded queue, and that queue is preserved. The framer adds no read-ahead queue of its own and does not
restart parsing a growing prefix. Payload filling advances through short reads into one allocated result;
the header is decoded once. Reader capacity can be smaller than the header or payload.

Returned payloads own their bytes, independent of refill, later frames or endpoint close. Encoding also
returns an independent copy. A framer retains its reader and limit, not previously returned messages.
Memory used by a call is bounded by the payload limit plus the underlying reader/endpoint chunk capacities;
callers control how many completed messages they retain. `encode` temporarily holds the source and its
wire-format copy, so use a practical application limit.

## Errors and finality

Clean EOF is allowed only before any byte of a new header. EOF inside a header or payload is an error;
an empty payload is a successful frame. Framing errors use the I/O error record with operation `frame`,
domain `library` and resource `"binary frame"`. Transport failures keep their original operation, native
domain/code, resource and message.

`io.error-progress Error` counts bytes consumed in the current frame, including the header. For absolute
stream position, use `frame.position F`. Thus a header failure after two bytes reports progress 2; a payload
failure after two body bytes reports 8. Reader prefetch is not counted as consumption.

EOF and errors are terminal and remembered. Later `next` calls return the same result without consuming
more input. An oversized or truncated frame is never treated as the start of another message. Unexpected
backend exceptions raise and also poison the framer against further parsing. Programming errors such as
an invalid limit raise. Operations on a closed/stale underlying endpoint raise, including after terminal EOF.

One task owns the framer and reader. Do not attach another framer or consume the reader separately while
using it. The framer does not close the endpoint; use an I/O scope for ownership. Reentry during a read is
rejected. Managed framer state and unread input survive saved images; native endpoint identities reload
stale, as described on the I/O pages.

## Typed clients and complete parsing

Declarations expose opaque `frame.reader` and the return type `(io.result (option.t frame.frame))` for `frame.next`. Load libraries with `(tc -)`,
then check clients with `(tc +)`:

```shen
(shen.x.namespace example
  (use option)
  (import frame frame)
  (use buffer)
  (use frame)
  (use io)
  (import result ok err)
  (export frame-text)

  (define frame-text
    {(io.result (option.t frame.frame)) --> (io.result string)}
    (:ok [(:frame Tag Payload)]) -> (ok (buffer.string Payload))
    (:ok []) -> (ok "end")
    (:err Error) -> (err Error)))
```

The payload is just bytes: validate the selected text encoding or parse a complete payload separately.
For example, load `tools/buffer-parsers.shenmod` to pass a successful payload to
`buffer-example.json`. Protocol framing and JSON recognition then happen once each; neither needs Shen's
default I/O. A future grammar compiler can use this boundary without implementing resumable parsing first.

## Framed echo application

[tools/frame-echo.shen](../tools/frame-echo.shen) demonstrates a complete connected-session handler.
`frame-echo.serve Endpoint Limit` owns and closes the endpoint, reads frames, writes an identical response
and flushes each response before reading the next request. It returns `(:result.ok MessageCount)` or `(:result.err Error)`.
Malformed input closes the connection; payloads and queued I/O stay bounded. It is a sequential session
handler, with no listener loop, thread cap, timeouts, authentication or HTTP semantics.

The [socket endpoint page](io-sockets.md) shows accepting a connection for it. `make test-io` exercises
all header/payload split and truncation boundaries, coalesced messages, limits, native errors, typed clients,
image/GC behavior and loopback echo with a 1 MiB payload. An optional independent Python wire oracle is
`python3 tests/frame_wire.py build/shen-jit`.

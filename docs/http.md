# HTTP requests and responses

The optional HTTP libraries implement a bounded HTTP/1.1 subset over our [I/O readers](io.md),
[head framer](http-head.md) and [socket deadlines](deadlines.md). Parsing, body ownership and encoding
are written in Shen, using byte views and the existing socket FFI. No kernel streams or C HTTP parser
are involved.

- [lib/http-request.shen](../lib/http-request.shen) parses complete request heads and reads bounded bodies.
- [lib/http-response.shen](../lib/http-response.shen) encodes owned final-response bytes.
- [lib/http-server.shen](../lib/http-server.shen) serves sequential requests on an owned connection under explicit bounds.

Pure parsing, memory bodies and encoding need `buffer.shen`, `io.shen`, [`grammar.shen`](grammar.md),
`http-head.shen`, `http-request.shen` and `http-response.shen`; they also work in static builds. Load libraries with
`(tc -)` before checking clients with `(tc +)`. Native serving additionally needs `ffi.shen`,
`socket.shen`, `deadline.shen`, `clock.shen`, `io-socket.shen` and `http-server.shen`.

## Parsing a complete head

```shen
(let Head (buffer.from-string
            "POST /echo?q=%20 HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;")
     Result (http.parse-request Head 1024)
     Request (hd (tl Result))
  [(http.method Request) (http.target Request) (http.content-length Request)])
```

This returns `[POST /echo?q=%20 3]`. Normal programs must match `[ok Request]` / `[error Error]`
before extracting a successful value. The input must contain exactly one complete head, including its
final CRLFCRLF, with no body/trailing bytes. A logical subview works; metadata owns its strings and does
not retain a mutable caller alias.

`http.parse-request View BodyLimit` validates a nonnegative fixnum body limit before parsing. Outcomes
use `(io.result http.request)`. Expected protocol failures have domain `http`, an HTTP status in
`io.error-code`, operation `http-request` and a diagnostic message. Pure parsing consumes no I/O, so its
progress is zero. Invalid view/limit arguments and unexpected failures raise.

| Operation | Value |
| --- | --- |
| `http.method Request`, `http.target Request`, `http.version Request` | Owned strings |
| `http.headers Request` | Ordered `[Name Value]` pairs, with ASCII-lowercased names and outer OWS removed |
| `http.header-values Request Name` | All matching values in wire order, without merging |
| `http.content-length Request` | Fixed body length immediately, or decoded chunked length after reading; raises while chunked length is unknown |
| `http.chunked? Request` | Whether the request used chunked transfer coding |
| `http.trailers Request` | Ordered, separate trailer fields after reading the body |
| `http.body Request` | Owned body view after a successful body read; raises before that |

`http.read-request Reader HeadLimit BodyLimit` reads a head from a reader as it arrives, without framing it
first: the request line, the fields and the blank line are parsed in place, in the reader's buffer, with
[a grammar](grammar.md#reading-as-input-arrives), and the body's bytes stay in the reader. It gives what
`http.parse-request` gives for the same head, `[eof]` when the input ended before a head, and 431 for a head
past HeadLimit, which must fit the reader's capacity.

The request type is opaque. Reading a body returns a new complete request; it does not mutate a parsed
request or its metadata. Method and target remain case-sensitive. Targets are retained without percent
decoding, path normalization or routing interpretation.

## Supported syntax and framing policy

This first subset uses the message/framing rules in [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)
and response semantics in [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html). Its deliberate limits are:

- HTTP/1.1, an ASCII token method, exactly one SP between request-line components, origin-form targets
  beginning with `/`, and `OPTIONS *`. URI bytes and percent escapes are checked; fragments, raw spaces,
  backslashes, proxy absolute-form targets and unsupported target forms are rejected. CONNECT is rejected
  with 501; a nonempty TRACE body is rejected.
- Exactly one valid nonempty Host. The authority subset accepts ASCII DNS-style labels up to 63 bytes
  each and 253 total, an optional trailing dot, or bracketed hexadecimal IPv6 with optional compression.
  Optional decimal ports are 0..65535. Userinfo, whitespace, empty ports, IPvFuture, zone IDs and IPv4-embedded
  IPv6 are unsupported. Host is syntax metadata; this parser does not resolve it or perform virtual hosting.
- At most 100 fields, an 8192-byte request line and 8192-byte individual field lines, under the head
  framer's configurable aggregate byte limit and a 1 MiB pure-parser cap. Invalid names, whitespace before
  a colon, obs-fold and inappropriate controls are rejected. Field values retain raw bytes, including
  obs-text; text decoding is separate.
- Content-Length is one nonempty decimal value, with optional outer OWS. Duplicate fields are rejected
  even if equal; comma lists, signs and exponents are rejected. Leading zeros are allowed. Values beyond
  BodyLimit return 413 without body allocation or consumption, and decimal conversion checks its bound
  before multiplication, including near the largest fixnum.
- Transfer-Encoding accepts a single field containing `chunked`, with case-insensitive token matching.
  Its combination with Content-Length, repeated chunked coding, coding parameters or a final coding other
  than chunked is rejected (400). Bare coding lists ending in chunked with an additional unsupported
  coding return 501. All Expect fields return 417 before waiting for a body. Upgrades/tunnels return 501.
  Trailer declarations require chunked framing and cannot name protected fields.
  Connection values are validated token lists and cannot nominate Host or body-framing fields. A peer's
  close token ends a persistent connection after the current response; `http.serve-one` always closes.

Ordinary syntax errors return 400, line/field limits use 414/431, unsupported versions use 505, and body
limits use 413. These policies are a documented subset, not a claim of complete HTTP/1.1 conformance.
No close-delimited request body is inferred, and malformed framing is never repaired by guessing.

## Bounded bodies

`http.body-reader Reader Request` borrows the same reader that produced the head.
`http.read-body B` returns `[ok CompleteRequest]` or `[error Error]`. For fixed framing it allocates the
already bounded Content-Length once and fills it through short reads; zero length needs no transport probe.
For chunked framing it checks each hexadecimal size against the remaining decoded-body bound before
allocating that chunk, and appends payloads to bounded geometric storage. The next
request or other following bytes remain unread. Returned body bytes are owned and can contain NUL or 255.

```shen
(let Request (hd (tl (http.parse-request
                (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;") 3)))
     E (io.input-buffer (buffer.from-string "abcNEXT"))
     R (io.reader E [[chunk-size 1]])
     B (http.body-reader R Request)
     Complete (hd (tl (http.read-body B)))
     Remaining (hd (tl (io.read-all R 4)))
     _ (io.close E)
  [(buffer.string (http.body Complete)) (buffer.string Remaining)])
```

This returns `[abc NEXT]`. A body reader remembers its first result, including failure, so repeated calls
do not consume another body. Creating a body reader from an already completed request raises. One task
owns it and the underlying reader; do not create competing body readers or consume that reader separately.

EOF before the promised length returns a 400 incomplete-body error, with consumed body bytes in Progress.
Transport failures preserve their native details; protocol-body failure is terminal. `http.read-body-until B D`
checks a total budget before starting and before completion. Install that same D on a socket to bound waits
inside `io.reader-exact`. As with heads, changing a transport budget does not resume a failed protocol body.
Saved managed state can be read again in a new execution; native resources and deadlines reload stale.
Allocation failures raise, and native storage must remain alive while it is used.

## Chunked request bodies

Chunked bodies use the same reader and one-shot body API. Their Content-Length becomes available as
an accessor only on the completed request; original wire headers are retained, without inventing a
Content-Length field. `http.chunked?` remains true on that completed request.

```shen
(let Q (hd (tl (http.parse-request
                 (buffer.from-string "PUT / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 16)))
     E (io.input-buffer (buffer.from-string "3;note=yesc#13;c#10;abcc#13;c#10;0c#13;c#10;X-Check: okc#13;c#10;c#13;c#10;NEXT"))
     R (io.reader E [])
     Full (hd (tl (http.read-body (http.body-reader R Q))))
     Tail (hd (tl (io.read-all R 4)))
     _ (io.close E)
  [(buffer.string (http.body Full)) (http.trailers Full) (buffer.string Tail)])
```

This yields body `abc`, trailer `[["x-check" "ok"]]` and remainder `NEXT`. Sizes use overflow-checked hex;
multiple zero digits are accepted for the final chunk. Chunk data and metadata lines require exact CRLF.
Unknown extensions are syntax-checked then ignored, including token/quoted values and quoted-pair escapes,
as described in [RFC 9112 section 7.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1).

Trailer fields are checked like header fields, copied, and kept separately. They are never merged into
headers and need not have been announced. Framing, routing, connection, authentication, content-processing,
cache/conditional control fields and fields nominated by Connection are forbidden in trailers. See
`http.forbidden-trailer?` in the source for the conservative list. Applications interpret any retained
custom metadata explicitly. TRACE with a positive chunk is rejected before consuming its payload.

`http.body-reader-with Reader Request Options` allows additional bounds; `http.body-reader` uses their
defaults. The server and listener accept the same five options:

| Option | Default | Bound |
| --- | --- | --- |
| `chunk-line-limit` | 8192 | Size/extension or trailer line bytes, excluding CRLF |
| `chunk-metadata-limit` | 65536 | All chunk framing, extensions, delimiters and trailers, excluding payload |
| `trailer-limit` | 16384 | Trailer section bytes, including its final CRLF |
| `trailer-fields-limit` | 100 | Number of trailer fields |
| `chunk-count-limit` | 4096 | Number of size lines, including the final zero-size line |

Limits are exact nonnegative fixnums up to 1048576; line/count limits must be positive. A trailer byte
limit below two cannot accommodate even the final empty line; use `trailer-fields-limit 0` to allow no
fields. The decoded `body-limit` and these metadata bounds are independent, so many tiny chunks or large
extensions cannot bypass the resource policy. Resource excess returns 413; malformed syntax, delimiters,
forbidden trailers and truncation return 400, with field syntax limits also able to return 431.

Progress counts decoded payload bytes, including a consumed partial chunk, rather than wire delimiters.
Transport errors retain their native details. Chunk scanning checks the same deadline between bounded
metadata spans and data chunks and before completion; native waits use that same installed budget.
No deadline is renewed by a new chunk. Any failure remains terminal and releases accumulated payload
storage. Complete bodies remain owned in memory; streaming body delivery is a separate API.

## Response encoding

`http.response Status Fields Body` makes a response description. Body is a borrowed view that must stay
alive and stable until encoding. `http.encode-response Request Response HeadLimit BodyLimit` validates
the description and returns independent wire bytes. All validation happens before any network write.

```shen
(let Request (hd (tl (http.parse-request
                (buffer.from-string "HEAD / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;") 0)))
     Response (http.response 200 [["Content-Type" "text/plain"]] (buffer.from-string "hello"))
  (buffer.string (http.encode-response Request Response 4096 1024)))
```

This encodes a five-byte representation's Content-Length and sends no body bytes because the method is
HEAD. Normal responses include exact Content-Length and `Connection: close`. 204 and 304 omit Content-Length;
205 uses Content-Length 0. These three statuses require an empty provided body. The encoder accepts final
statuses 200..599, supplies a conventional reason phrase when known, and rejects informational responses.
304 representation-length metadata and CONNECT tunnels are outside this API.

Application fields preserve order/repeats. Names and values are validated against control/CRLF injection;
framing fields are reserved: Content-Length, Transfer-Encoding, Connection, Trailer, Upgrade, Keep-Alive,
Proxy-Connection and TE must not be supplied by the application. Up to 100 application fields are accepted,
with 8192-byte field-line and aggregate HeadLimit bounds. HeadLimit is 4..1048576; body size is checked
against the explicit BodyLimit before copying. Invalid response descriptions raise.

The pure encoder serializes supplied metadata; it does not invent representation headers, dates, cookies
or method-specific application behavior. The connection driver supplies a current English UTC Date when
absent, through a native seconds clock and a Shen formatter, without depending on locale or a C tm layout.
An application-provided Date is preserved. The generated Date counts toward the field and head limits.
If a usable clock is unavailable the driver omits it.

## One request per connection

`http.serve-one Endpoint Handler Options` adopts a valid owned socket endpoint. Handler receives one
complete request and returns an `http.response`. It can perform application work but must not write
response bytes itself. The driver reads the full bounded body before calling it, writes one final response,
and closes on every exit. Clean EOF before a head returns `[ok 0]`; a successful response returns `[ok WireBytes]`.
Rejections remain `[error Error]` even when an error response was sent successfully.

| Option | Default |
| --- | --- |
| `head-limit` | 16384 bytes |
| `body-limit` | 1048576 bytes |
| `read-buffer-size` | 16384 bytes; configurable in 1..65536 |
| `response-head-limit` | 16384 bytes, minimum 128 so an empty error response fits |
| `response-body-limit` | 1048576 bytes |
| `head-timeout`, `body-timeout`, `write-timeout` | 5000 ms each |

Options are `[Name Number]` pairs, for example `[[body-limit 65536] [body-timeout 2000]]`. When the head limit fits
the read buffer, as by default, a head is read in place as it arrives; a larger one is framed first, then parsed.
Unknown, duplicate and invalid options raise before ownership transfers. Each phase gets an absolute
deadline spanning short progress, capped by the total connection budget. Handler execution cannot be
interrupted; its elapsed time is charged to that total and checked before output. This convenience
does not accept a second request or add an accept loop. The [bounded listener](http-listener.md) uses
the persistent variant below with a connection cap and controlled shutdown.
The [streaming response reference](http-streaming.md) covers source ownership and output chunk limits.

`read-buffer-size` bounds the connection's input reader and each read scratch allocation. It is independent
of head/body limits: larger heads and bodies span refills, and pipelined bytes remain in the same reader.
Small values trade more reads/copies for less live input memory. It applies to both connection drivers
and `http.listen`; the general I/O reader defaults are unchanged.

Malformed/unsupported requests get an empty 400/413/414/417/431/501/505 response as appropriate; budget
expiry gets 408. Application exceptions or invalid responses get an empty 500 before any application
output is committed. Details stay in the local error record. After response output begins, a write failure
preserves its acknowledged count and closes; it never appends a second error response. Failure while
sending a rejection is secondary to the original error, as is failed cleanup. A peer can observe a reset
when rejection closes with unread native input; error-response delivery is best effort in that case.

## Running the example

[tools/http-echo.shen](../tools/http-echo.shen) serves `/health` as `ok`, echoes bounded bodies for common
methods, and lets the encoder implement HEAD. Load the native libraries and run one connection:

```sh
shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l lib/grammar.shen \
  -l lib/http-head.shen -l lib/http-request.shen -l lib/http-response.shen -l lib/http-server.shen \
  -l tools/http-echo.shen -l one-request.shen
```

`one-request.shen` can contain:

```shen
(let Listener (socket.listen "127.0.0.1" 9000)
     Peer (socket.closing-on-error Listener (freeze (socket.accept Listener)))
     _ (socket.close Listener)
  (http-echo.serve (io.socket Peer "HTTP peer") [[body-limit 65536]]))
```

Send a request from another terminal, for example `curl --http1.1 --data-binary 'hello' http://127.0.0.1:9000/`.
The process handles that connection and exits. TLS, proxy requests, streaming request bodies, routing
policy and authentication are separate work. Persistent connections and streaming responses are described below. The bounded listener supplies
connection limits and shutdown.

## Persistent connections

`http.serve-connection Endpoint Handler Options` adopts an owned socket and serves requests in order.
It retains one bounded reader across messages, so pipelined bytes survive without losing or guessing
message boundaries. The full bounded request body is decoded before each handler call; there is no
unread-body drain policy or concurrent dispatch within a connection. Fixed and
[streaming responses](http-streaming.md) are both accepted. Clean EOF and successful connection completion
return `[ok TotalWireBytes]`; any failure ends the connection and returns `[error Error]`.

| Additional option | Default | Meaning |
| --- | --- | --- |
| `request-limit` | 100 | 1..1048576 completed requests per connection |
| `idle-timeout` | 5000 ms | Wait for the first byte of the next request |
| `connection-timeout` | 60000 ms | Total connection budget, starting on admission |

Every head, body, idle and write deadline is capped by the original connection deadline using
`deadline.within`. Progress and new requests never renew it. Once the next request starts, its complete
head gets the head-timeout budget within that cap. Unused idle expiry/EOF closes cleanly without sending
a speculative 408. Expiry within an active message is terminal; error delivery remains best effort.
Application work is cooperative and can delay observing a budget.

HTTP/1.1 connections stay open unless the peer sends a case-insensitive Connection close token, the
request cap is reached, shutdown is requested, or the handler wraps its response in
`http.close-after Response`. These decisions send Connection: close when known before the head is
written. Other successful responses omit Connection and remain reusable. Every parse/body/producer/
output/cleanup failure ends the connection and stops queued requests. No bytes are interpreted as a new
request after a framing failure. `http.serve-one` remains a one-request, always-closing convenience.

The [bounded listener](http-listener.md) uses this persistent driver and adds admission/shutdown.
Its statistics count connections, including all requests handled on each connection.

Public declarations cover `http.request`, `http.body-reader`, `http.response`, server options and I/O result
families. `make test-http` checks syntax/smuggling cases, every small transport split, body ownership, exact
response bytes, partial failures, Date formatting, typed clients and image/GC behavior. CI runs it on each
platform, skipping native cases explicitly on static builds. `python3 tests/http_wire.py build/shen-jit` adds
an independent standard-library client for fixed/chunked binary bodies, trailers, HEAD/bodyless statuses,
rejections and slow input.

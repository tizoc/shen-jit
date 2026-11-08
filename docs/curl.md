# HTTP clients with libcurl

`lib/curl.shen` provides synchronous HTTP and HTTPS requests with reusable clients, binary request
and response bodies, ordered response fields, timeouts, collection limits and streamed downloads with
backpressure. It uses `buffer.view`
and the error/result types from our own [I/O library](io.md). It does not use Shen's kernel streams.

## Building and loading

The optional `lib/curl.c` adapter needs a C compiler and libcurl 7.68.0 or newer, including its
development headers. The runtime and its default image have no libcurl dependency.

```sh
# Debian/Ubuntu
sudo apt-get install libcurl4-openssl-dev pkg-config
make curl
```

macOS has the headers in its command line tools and a system libcurl. On Windows, use MSYS2's UCRT64
compiler, `mingw-w64-ucrt-x86_64-curl` and `mingw-w64-ucrt-x86_64-pkgconf`. The adapter and libcurl
must match the executable's architecture; the libcurl DLL and its dependencies must be discoverable
by Windows. Fully static Shen/JIT builds cannot load the adapter.

`make curl` writes `build/shen-curl.so` (`.dll` on Windows). A binary release carries the adapter's
source and build script, rather than a prebuilt adapter or bundled TLS libraries. From its root:

```sh
sh lib/build-curl.sh lib/shen-curl.so
# On Windows: sh lib/build-curl.sh lib/shen-curl.dll
```

The script uses `pkg-config libcurl`, then `curl-config`, then the compiler's default headers and
`-lcurl`. `CC`, `CFLAGS`, `CURL_CFLAGS` and `CURL_LIBS` override those choices. Loading Shen code never
invokes a compiler. Run from the installation or checkout root:

```sh
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/curl.shen \
  -e '(curl.version)'
```

The facade searches `./build/`, `./lib/` and the current directory for `shen-curl.so` and
`shen-curl.dll`. For another location, set `curl.*adapter-files*` to a list of absolute file names
before loading `lib/curl.shen`. Saved executables retain that declaration and need the adapter and
libcurl at runtime too. The adapter checks its own ABI and uses only the public `include/shen.h` API.
It refuses an adapter built for another ABI: rebuild it with `make curl` after updating Shen/JIT.

## Requests

`curl.get` opens and closes a client for one GET. `curl.fetch` does the same for another method.
`curl.with-client` scopes a reusable client; repeated `curl.request` calls on that client can reuse
connections, TLS state and DNS information. Request options, headers and body are reset each time.
[libcurl's reset contract](https://curl.se/libcurl/c/curl_easy_reset.html) preserves those caches.

```shen
(define web.get
  URL ->
    (curl.with-client
      (/. Client
        (curl.request Client "GET" URL [["Accept" "application/json"]] (buffer.new 0)
          [[body-limit 65536] [header-limit 16384] [timeout 5000] [connect-timeout 1000]]))))

(define web.status
  [ok Response] -> (curl.status Response)
  [error Error] -> (error "HTTP transfer: ~A" (io.error-message Error)))
```

Load these libraries before an application. JSON is optional:

```sh
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/curl.shen \
  -l lib/grammar.shen -l lib/json.shen -l client.shen
```

Methods are case-sensitive ASCII tokens of at most 32 bytes. GET and HEAD require an empty body.
Other methods send the supplied bytes, including NUL and bytes above 127. A view's selected range is
copied, whether its storage is managed or foreign; it must be live during the call. Headers are
ordered `[Name Value]` pairs. Repeated fields remain repeated; an empty value sends an explicitly
empty field. CR, LF, other control bytes and invalid names are rejected. libcurl owns request
framing: caller-supplied Content-Length and Transfer-Encoding are rejected.

Non-GET/HEAD requests get `Content-Type: application/octet-stream` unless a Content-Type is supplied.
For JSON, load `lib/grammar.shen` and `lib/json.shen`, and encode explicitly:

```shen
(define web.post-json
  URL Value ->
    (curl.fetch "POST" URL [["Content-Type" "application/json"]] (json.encode Value [])
      [[request-limit 65536] [body-limit 65536] [timeout 5000]]))

(define web.decode-json
  [ok Response] -> (json.decode (curl.body Response) [])
  [error Error] -> (error "HTTP transfer: ~A" (io.error-message Error)))
```

HTTP statuses such as 404 and 500 return `[ok Response]`. Check `curl.status` for application policy.
DNS, connection, TLS, timeout and incomplete-body failures return `[error Error]`. Invalid arguments,
closed-client misuse, a missing adapter or failure to create a client raise. JSON decoding has its
own validation and limits; it is not implied by the Content-Type.

## Streaming into I/O sinks

`curl.request-to` writes a response into a caller-owned `io.endpoint`. `curl.get-to` opens and closes
a client for one streamed GET. They leave the sink open, and do not flush or close it. The sink
must be writable and have no attached buffered writer; our file, socket and memory endpoints work
directly. The request body is still a bounded complete view, rather than a streaming upload.

```shen
(define web.stream
  URL Sink ->
    (curl.get-to URL Sink [[body-limit 1073741824] [chunk-size 16384] [timeout 30000]]))
```

| Function | Ownership |
| --- | --- |
| `(curl.request-to Client Method URL Fields Body Sink Options)` | Borrows client and sink |
| `(curl.get-to URL Sink Options)` | Scopes a client and borrows the sink |
| `(curl.request-with-sink Client Method URL Fields Body OpenSink Options)` | Borrows client; opens and closes a sink for the transfer |

All return `[ok Response]` or `[error Error]`. A streamed response retains status, fields, trailers
and transfer metadata. `curl.streamed?` is true and `curl.body-length` is the number of bytes
accepted by the sink. `curl.body` raises because the response has no collected body.

`OpenSink` receives the final response head and must return `[ok Endpoint]` or `[error Error]`.
It runs once, before the first payload write, or after a successful transfer with no body. This
allows checking status or fields before opening a destination. Its head has no trailers yet,
`curl.streamed?` is true and `curl.body-length` is zero; use response fields for an advertised length.
The completed response contains the final trailers and actual written count. The library closes
an opened sink after success, transport failure, a sink error or an exception. Transport failures
before body delivery leave the opener uncalled.

For example, load `lib/io-file.shen` and accept only 2xx before opening a file:

```shen
(define web.open-download
  Path Head ->
    (if (and (>= (curl.status Head) 200) (< (curl.status Head) 300))
        (io.open-file Path write)
        [error (io.native-error download http (curl.status Head) (curl.url Head) "expected a 2xx response")]))

(define web.save
  URL Path ->
    (curl.with-client
      (/. Client
        (curl.request-with-sink Client "GET" URL [] (buffer.new 0)
          (/. Head (web.open-download Path Head))
          [[body-limit 1073741824] [chunk-size 16384] [timeout 30000]]))))
```

The sink's short writes are retried before taking another chunk. A zero-progress write, malformed
backend result, I/O error or exception aborts the transfer. Sink errors retain their operation,
domain, code and resource. All streaming failures report the total bytes accepted by the sink in
`io.error-progress`, including short writes before a later exception; this is not a durability
guarantee. Cleanup failures accompany a primary error as secondary errors. If only close fails,
its error still reports the total accepted body bytes. The client remains reusable after failure.

Backpressure is synchronous: the native write callback reacquires the VM lock, copies at most
`chunk-size` bytes into an owned managed chunk, and fully writes it through our I/O API before
returning to libcurl. There is no background producer, body queue or native whole-response buffer.
Other Shen threads can run during network waits and blocking sink operations. The callback always
runs on the thread that initiated the request and releases its temporary roots before returning.

Live payload storage depends on the bounded request copy, header budget, one delivery chunk and I/O
scratch, rather than the response's total size. Unreachable scratch awaits collection; allocator,
libcurl/TLS and OS socket buffers also use memory. A sink that deliberately retains chunks adds its
own storage. The body limit is a total transfer quota, independent of this memory bound.

`timeout` cannot interrupt arbitrary Shen code or a blocked sink backend. libcurl observes its
network timer as control returns to it. Configure the sink's own deadlines, such as a socket I/O
deadline, when its writes can block. Slow sinks can therefore outlast a network timeout before
returning an error; no worker thread is left downloading in the background.

## Options and limits

Options are `[Name Value]` pairs. Unknown names, duplicates and malformed pairs raise. Numeric
values must be nonnegative fixnums in the ranges below; timeouts must be positive.

| Option | Default | Range and meaning |
| --- | --- | --- |
| `request-limit` | 1048576 | 0–268435456 bytes copied from the request body |
| `body-limit` | 1048576 | 0–268435456 buffered response bytes; streaming allows up to the maximum fixnum, 2305843009213693951, as a transfer quota |
| `header-limit` | 65536 | 0–1048576 bytes accepted by header callbacks, including status lines, separators and trailers |
| `timeout` | 30000 | 1–2147483647 ms for the entire transfer, including redirects |
| `connect-timeout` | 5000 | 1–2147483647 ms for connection setup, within the total timeout |
| `redirect-limit` | 0 | 0 disables automatic redirects; 1–20 follows at most that many, for GET/HEAD only |
| `ca-file` | libcurl's default | Nonempty CA file path, at most 4096 bytes |
| `proxy` | libcurl's environment/defaults | Proxy URL, at most 8192 bytes; `""` disables proxies |
| `chunk-size` | 16384 | Streaming only: 1–65536 bytes per managed delivery chunk; libcurl may deliver smaller pieces |

URLs must use HTTP or HTTPS, contain no NUL, and fit 8192 bytes. Outgoing headers have limits of
100 fields, 8192 bytes per encoded field and 65536 bytes in total, including the default Content-Type.
The response budgets count cumulatively across callbacks for the transfer, including intermediate
header blocks. A new response block does not renew a budget. The retained response contains the
final block and its body, with trailers separate.

These are payload collection limits, rather than a cap on process memory. The implementation copies
the request into native storage before transferring, grows native response buffers geometrically,
and copies the completed result into managed bytes. During conversion both copies exist. Raw fields
and parsed field strings also occupy memory, and libcurl maintains its own connection/TLS/DNS caches.

`CURLOPT_NOSIGNAL` is enabled. With a libcurl built around a synchronous resolver, DNS resolution
may outlast the configured timeout; a threaded resolver or c-ares avoids that limitation. See
[libcurl's threading guidance](https://curl.se/libcurl/c/threadsafe.html).

## Response values and errors

Collected response bytes are owned managed buffers. They survive later requests, client closure, collection
and image saving. Header names are ASCII lowercase; values are trimmed and repeated fields preserve
their order. Interim responses and redirect heads are excluded from the final field list. Trailers
have their own list and raw view.

| Function | Result |
| --- | --- |
| `(curl.status Response)` | Numeric HTTP status |
| `(curl.url Response)` | Effective URL after redirects |
| `(curl.body Response)` | Owned `buffer.view`; raises for streamed responses |
| `(curl.streamed? Response)` | Whether the body went to a sink |
| `(curl.body-length Response)` | Collected body length or streamed bytes accepted by the sink |
| `(curl.headers Response)` | Ordered list of `[Name Value]` fields |
| `(curl.header-values Response Name)` | All matching ordinary field values, case-insensitively |
| `(curl.trailers Response)` | Ordered trailer fields, separate from ordinary fields |
| `(curl.raw-headers Response)` | Final raw header block, including status line and separator |
| `(curl.raw-trailers Response)` | Raw trailer bytes delivered by libcurl |
| `(curl.elapsed Response)` | libcurl's total elapsed time, truncated to milliseconds |
| `(curl.redirects Response)` | Number of followed redirects |

libcurl removes transfer framing such as chunk boundaries. Automatic content decompression is
disabled: the facade does not add Accept-Encoding, and an explicitly requested compressed
representation remains compressed in `curl.body`. The body limit therefore does not hide an
unbounded content-decoding step.

`io.error-operation` is `request`; `io.error-resource` is the original URL. Native transfer errors
retain the numeric CURLcode and libcurl's message. `io.error-domain` is `timeout` for CURLcode 28,
`limit` for a collection budget failure, otherwise `curl`. `io.error-progress` counts body bytes
accepted by callbacks before failure, across the transfer. It is not bytes durably saved and does
not include a rejected callback chunk. Streaming errors instead count actual sink progress, including
partial chunks. Failed transfers return no partial response body; a sink retains bytes already written.

## TLS and redirects

Certificate and hostname verification are always enabled. `ca-file` adds an explicit trust file for
that request; it does not disable verification. No insecure option is exposed. Available TLS
backends, default trust stores, proxies and HTTP versions depend on the installed libcurl;
`curl.version` reports that installation.

Redirects are off by default. An opted-in GET or HEAD may follow HTTP/HTTPS, but an HTTPS starting
URL may redirect only to HTTPS. Non-GET/HEAD methods require the caller to inspect Location and make
another explicit request, so this API does not silently replay uploads or choose POST conversion
rules. Custom headers can be forwarded to redirect targets: enable redirects only with an
appropriate header policy. See [libcurl's header forwarding rules](https://curl.se/libcurl/c/CURLOPT_HTTPHEADER.html).

## Ownership and threads

`curl.open` returns a `curl.client`. `curl.close` returns `[ok]` or `[error Error]` and remembers its
completed result, making repeated closure safe. `curl.with-client` requires a callback returning
`[ok Value]` or `[error Error]`, closes after completion or an exception, and combines cleanup failures
using the I/O library's error convention. A manually opened client must be explicitly closed;
discarding it does not install a GC finalizer. Saved clients are stale and must be reopened on startup.

Use one client per simultaneous transfer. An overlapping request or close returns an error without
freeing or invalidating the active client. A completed transfer leaves it reusable after success or
failure. The VM lock is released during the network operation and native cleanup, allowing other
Shen threads to run. Buffered callbacks touch native storage. Streaming body callbacks reacquire the
VM lock before calling the sink and do not resume network reads until the write completes.

The adapter initializes libcurl once and leaves global cleanup to process exit. With libcurl older
than 7.84.0, or a build without thread-safe global initialization, call `curl.version` or `curl.open`
before creating application threads. Its [global initialization contract](https://curl.se/libcurl/c/threadsafe.html)
applies to other native threads in an embedding host too.

## Downloader and tests

```sh
build/shen-jit script tools/curl-fetch.shen https://example.com/ page.html
make test-curl
```

The downloader streams at most 1 GiB in 16 KiB chunks. It accepts only 2xx responses before opening
the destination through `io.open-file`, and owns its closure. A rejected status or failure before
opening leaves an existing destination untouched. Once writing begins, a network or file error can
leave a partial destination; writing is not atomic. The error retains total accepted progress.

Tests use an independent Python HTTP/TLS server on loopback and a temporary test CA generated with
the `openssl` command. They check binary bodies, connection reuse and option reset, redirects,
interim fields, trailers, partial responses, budgets, TLS rejection/trust, concurrent ownership,
typed clients, saved images, GC inside streaming callbacks and the downloader. A blocked sink holds
back a 64 MiB source; 8 and 64 MiB streams finish with a 16 MiB Shen heap cap and 4 KiB delivery
chunks. Static builds run the pure
validation checks and explicitly skip native transfers. `make test-san` also instruments the adapter
with AddressSanitizer and UBSan on shared-capable builds.

Streaming uploads, the multi interface, transfer cancellation, authentication helpers,
cookie persistence and multipart construction remain future work.

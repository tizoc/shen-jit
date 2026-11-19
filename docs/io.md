# Chunk I/O

[lib/io/io.shen](../lib/io/io.shen), the module `io`, provides bounded byte readers and writers, over the
[buffer views](buffers.md). [lib/io/file.shen](../lib/io/file.shen), the module `io/file`, adds native binary files.
These optional Shen libraries have their own endpoints, buffering and errors. They use byte primitives and
FFI calls directly; kernel streams, `open`, `read-byte` and kernel file helpers are not dependencies.

Load libraries with type checking off, then enable it for a typed client if wanted:

```sh
shen-jit eval -m io/file \
  -e '(io.write-file "example.bin" (buffer.from-string "hello"))' \
  -e '(result.let-ok Bytes (io.read-file "example.bin" 1024) (buffer.string Bytes))'
```

This writes five bytes and returns `(:result.ok 5)`, then reads them with an explicit 1024-byte limit and prints
`hello`. A program must handle the error alternative before extracting the value. No native assembly or
new runtime support is required. The core, including memory endpoints, works without the FFI and on static
builds; the file backend needs dynamically loadable system libraries.

## Files and memory endpoints

| Operation | Result and meaning |
| --- | --- |
| `io.open-file Path Mode` | `(:result.ok Endpoint)` or `(:result.err Error)`; caller owns closing it |
| `io.read-file Path Limit` | `(:result.ok OwnedView)` or `(:result.err Error)`; closes the file on every exit |
| `io.write-file Path View` | `(:result.ok Count)` or `(:result.err Error)`; truncates/replaces, writes, then closes |
| `io.with-input-file Path F`, `io.with-output-file Path F` | Open, call F with the endpoint, then close |
| `io.input-buffer View` | Read endpoint owning an independent snapshot of View |
| `io.output-buffer View` | Write endpoint borrowing a fixed writable range; full capacity is an error |
| `io.with-endpoint Endpoint F` | Call F then close Endpoint, preserving callback and cleanup failures |
| `io.close Endpoint` | Flush attached output and close once; `(:result.ok [])` or `(:result.err Error)` |

File modes are `read` (existing), `write` (create/truncate), `append` (create/append) and `read-write`
(existing, shared position, no truncation). Opening with `write` is destructive immediately; replacement is
not atomic. Paths are nonempty NUL-free strings. Relative paths use a snapshot of `*home-directory*` at
open time; the library resolves this itself without kernel file helpers. POSIX paths use their string's
bytes; Windows converts UTF-8 to UTF-16 for `_wopen`, opens in binary mode and prevents inheritance.
Windows drive-relative paths such as `C:name` are rejected. POSIX descriptors use close-on-exec. Creation permissions are 0666 subject to the POSIX umask.

File reads/writes are blocking foreign calls. They retry EINTR, but do not promise
cancellation or deadlines: a blocking file operation can wait indefinitely. Close is never blindly retried.
This backend supplies files; [socket endpoints](io-sockets.md) and [subprocess pipes](processes.md) use
separate adapters. Seeking and durability sync remain separate work. [Filesystem operations](fs.md) add metadata,
bounded traversal, temporary files and replacement over these endpoints. `flush` delivers buffered
output to the endpoint, not to stable storage. An error from `write-file` may leave a partial file and does not roll back output.

## Direct transfers

Each View is already a logical range. Slice it to choose an offset/count; operations never access owner
margins. Managed buffers and sized foreign owners both work. Writes accept read-only sources; reads require
writable destinations, including empty requests.

| Operation | Outcomes |
| --- | --- |
| `io.read-some E View []` | `(:result.ok [N])`, `(:result.ok [])`, `(:result.err Error)` |
| `io.write-some E View []` | `(:result.ok N)`, `(:result.err Error)` |
| `io.read-exact E View []` | `(:result.ok (:io.transfer true Length))`, `(:result.ok (:io.transfer false Total))`, `(:result.err Error)` |
| `io.write-all E View []` | `(:result.ok Length)`, `(:result.err Error)` |

An exact read that reaches EOF before its first byte returns `(:result.ok (:io.transfer false 0))`. Single reads signal EOF with `(:result.ok [])`.

For a nonempty request, successful N is positive and may be shorter than View. A short read is not EOF. Socket operations can use an installed [absolute deadline](deadlines.md).
An error from a single transfer means no bytes delivered by that call; accumulated operations report the
acknowledged total. Resume from that total, not the start. Bytes already read remain in the destination;
undelivered bytes remain untouched. An unexpected backend exception or malformed result raises.

A valid empty request returns `(:result.ok [0])` or `(:result.ok 0)` without probing the backend. It supplies no EOF
information. Invalid storage, direction, closed state or options still raise before I/O. Transfer options
currently must be `[]`; unsupported options are rejected. Indices, counts and limits must be nonnegative
fixnums, and integral boxed floats are refused.

## Bounded readers

`io.reader E Options` borrows E's read direction. Options are `[]` for the endpoint capacity or
`[[chunk-size N]]` for a smaller capacity. File/memory endpoints default to 65536 bytes. Capacities are
positive fixnums, at most 1048576 bytes, and cannot exceed the endpoint's own bound.

In typed code, supply options where their type is expected, as in `(io.reader E [])`,
`(io.writer E [])` or `(io.reader E [[chunk-size 8]])`. An unannotated `(let Options [] ...)`
infers a plain list. To bind options before passing them to an endpoint, use
`(type [] io.buffer-options)`, `(type [[chunk-size 8]] io.buffer-options)` or a
function returning `io.buffer-options`.

| Operation | Meaning |
| --- | --- |
| `io.read-chunk R` | `(:result.ok [OwnedView])`, `(:result.ok [])` or `(:result.err Error)`; consumes available input |
| `io.peek R Count` | `(:result.ok [OwnedView])`, `(:result.ok [])` or `(:result.err Error)`; fill up to Count without consuming |
| `io.peek-up-to R Count` | Wait for some input and return at most Count owned bytes without consuming |
| `io.peek-some R` | `(:result.ok [OwnedView])`, EOF or error; wait only for some input, preserving it in the queue |
| `io.consume R Count` | Consume only already available bytes, returning R |
| `io.available R`, `io.position R` | Queued bytes and total bytes consumed since reader creation |
| `io.read-into R View` | `(:result.ok [N])`, `(:result.ok [])` or `(:result.err Error)`; consume into a caller's range |
| `io.reader-exact R View` | Same transfer result as `io.read-exact` |
| `io.read-all R Limit` | `(:result.ok OwnedView)` or `(:result.err Error)`; aggregate up to the explicit limit |

`io.window R`, `io.window-fill R Need` and `io.window-size R` let a parser read the queue in place, as
[`grammar.read`](grammar.md) does: the queue moves to the start of the reader's buffer and fills append to it
until something is consumed, so positions stay valid while the parser waits for more.
`io.reader-status R` inspects the cached state and returns `ready`, `eof`, or `failed`. A peek at the
status leaves a pending timeout for the next read to report.

`io.peek` Count cannot exceed reader capacity. `io.peek-up-to` accepts any nonnegative maximum and
copies at most that many available bytes; it waits for one byte, without waiting to fill the maximum. Peek can return a shorter view at EOF/error; queued bytes
are delivered before the pending terminal condition. EOF and hard errors are remembered; timeouts are
transient after they have been reported, and a later reader operation can retry under a new budget.
Consuming a queued prefix does not discard its pending timeout. A zero peek returns an
empty owned view without probing. Returned views own their bytes and survive consumption, refill and
endpoint close; they do not alias the refill buffer. A retained caller view is never a hidden mutable feed.

`read-all` consumes its successful prefix. At the limit it checks for EOF using a one-byte peek. If input
continues, it reports an error with consumed progress and leaves that next byte unread. Even limit zero
must probe to establish that the source is empty. Aggregation keeps chunks plus one final contiguous
result, so peak payload storage is about twice the limit plus bounded scratch space. Use `read-chunk` for
input whose total size should not be held in memory.

This complete program counts a file in bounded chunks:

```shen
(shen.x.namespace example
  (use option)
  (use io)
  (use buffer)
  (import result ok err)
  (externals [chunk-size])

  (define count-chunks
    R Total -> (count-chunk R Total (io.read-chunk R)))

  (define count-chunk
    R Total (:ok [V]) -> (count-chunks R (+ Total (buffer.length V)))
    _ Total (:ok []) -> (:ok Total)
    _ _ (:err E) -> (:err E))

  (io.with-input-file "example.bin"
    (/. E (count-chunks (io.reader E [[chunk-size 4096]]) 0))))
```

[Binary framing](framing.md) already uses this reader to consume bounded messages across chunks.
A future general streaming parser should share its unread input and consume only accepted bytes.
It must not add an unrelated read-ahead queue or wrap a kernel stream. The current complete-input format
examples on the buffers page can already parse a successful `read-file` result.

## Buffered writers

`io.writer E Options` borrows E's write direction with the same capacity options as a reader.
`io.write W View` returns `(:result.ok N)` or `(:result.err Error)`. Acceptance counts input copied into
library buffering or already delivered during this call; it does not promise that pending bytes reached
the endpoint. `io.pending W` reports the unsent count.

`io.flush W` returns `(:result.ok Written)` or `(:result.err Error)`, counting bytes delivered during this flush.
Each short write advances the pending offset immediately. Failure keeps the unsent suffix; a later flush
retries only that suffix. A backend that raises fails the flush the same way: what it had taken counts, and
the raise goes on to the caller. New nonempty writes are refused until an explicit successful flush clears the
failure. When a write fails during an implicit flush, resume its input at the error's `io.error-progress` after clearing that failure; the buffered prefix must not be replayed. Empty writes accept zero.

Closing E attempts to flush its writer, then closes even if flushing fails. Unsent output is lost on close;
the close result reports the failure. Garbage collection is not a successful flush or a descriptor close.

## Errors, scopes and ownership

Errors are immutable `io.error` structs with fields `operation`, `domain`, `code`, `resource`, `message`, `progress` and `secondary`.
Use `io.error-operation`, `io.error-domain`, `io.error-code`, `io.error-resource`, `io.error-message`,
`io.error-progress` and `io.error-secondary`. Domains include `library`, `posix`, Windows `crt` / `win32`,
`foreign` for an unavailable backend, and `shen` for a caught scope callback exception. Native codes are
captured immediately after the failing call. `io.error Op Resource Message` constructs a library error;
`io.native-error Op Domain Code Resource Message` constructs one with native details.

Accumulated errors include progress in their result and error record. For `write`, progress is accepted
input; for `flush`, it is delivered output. `read-all` records the consumed prefix. Secondary is a list of
cleanup errors. Programming errors raise; expected transport failures return structured errors.

`(result.let-ok X Result ... Body)`, from the module [`result`](result.md), which `io` requires, chains results: it
binds each X to the value of an ok result, in order, and gives Body, or the first result that is not ok, unchanged;
`_` takes `(:result.ok [])` or `(:result.ok X)` and binds nothing. It is a macro, so it applies to files read after the module loads:

```shen
(shen.x.namespace example
  (use io)
  (use buffer)
  (import result let-ok ok)

  (io.with-input-file "notes.txt"
    (/. E (let-ok Text (io.read-all (io.reader E []) 4096)
            (:ok (buffer.string Text))))))
```

A scope callback returns an `(io.result A)`, either `(:result.ok Value)` or
`(:result.err Error)`. Transfer operations record progress on the returned `io.error`.
The scope catches exceptions and closes on every exit. A callback failure stays primary,
with close or flush failures appended as secondary errors. Cleanup failure after success
becomes the returned error. Repeated close returns its first result.

One task owns an endpoint, its buffers and its lifetime. At most one reader and one writer may borrow it;
direct transfers in a borrowed direction and duplicate wrappers raise. Wrappers do not close independently
or detach. Read EOF does not close the write direction. Operations reject callback reentry while a transfer
is in flight. Cross-task mutation/close and concurrent mutation/freeing of foreign storage are unsupported.
Managed endpoint state persists in images. Native file endpoints reload stale and reject access before
using a descriptor, so old descriptor numbers cannot alias a new process's files.

## Custom backends and types

`io.endpoint Name Mode Capacity Read Write Close` creates an endpoint; modes are `read`, `write` and
`read-write`. Read and Write each receive managed raw bytes starting at zero, with length at most
Capacity. Write's are fresh. Read's are a chunk the endpoint keeps and lends to later reads, so Read
copies into it and returns, and keeps no reference to it. Read returns `(:result.ok [N])`, `(:result.ok [])` or `(:result.err Error)`; Write returns `(:result.ok N)` or `(:result.err Error)`.
N must be positive and no larger than the supplied chunk. A zero write becomes a no-progress error;
a zero nonempty read is an invalid backend result. Deliver progress first, then report a later terminal
condition on the next call. Expected failures must use these results rather than throwing after a transfer.
Close is a frozen zero-argument operation returning `(:result.ok [])` or `(:result.err Error)`. Unused directions can use
`(function io.no-read)` / `(function io.no-write)`.

Public arbitrary views are copied through these bounded chunks; nothing else moves an isolate's heap during a
blocking call. This first implementation favors safe bounded copies; it does not promise zero-copy I/O.

Endpoints, readers and writers are opaque. `io.error` is an immutable named-field struct.
The `io.t` datatype holds the transfer and buffer setting rules.
`(io.result A)` expands to `(result.t (io.error * A))` and `io.close-result` to
`(io.result result.empty)`. Reads and peeks use [optional values](option.md) for EOF.
Exact reads use `(io.result io.transfer)`. The transfer carries a completion flag and a byte
count, with `false` indicating that EOF prevented the read from filling the destination.
See [Results](result.md).
Typed clients can construct and match results:

```shen
(shen.x.namespace example
  (use option)
  (use buffer)
  (use io)
  (import result ok err)
  (export next-text)

  (define next-text
    {(io.result (option.t buffer.view)) --> (io.result string)}
    (:ok [V]) -> (:ok (buffer.string V))
    (:ok []) -> (:ok "")
    (:err E) -> (:err E)))
```

Load the libraries with `(tc -)` before checking clients with `(tc +)`. `make test-io` runs scripted short
transfers/failures, typed clients, native binary files, foreign views, saved images and targeted GC stress.
File cases explicitly skip the unavailable FFI on fully static builds; the managed core still runs.

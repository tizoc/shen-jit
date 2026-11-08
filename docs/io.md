# Chunk I/O

[lib/io.shen](../lib/io.shen) provides bounded byte readers and writers, over the
[buffer views](buffers.md). [lib/io-file.shen](../lib/io-file.shen) adds native binary files.
These optional Shen libraries have their own endpoints, buffering and errors. They use byte primitives and
FFI calls directly; kernel streams, `open`, `read-byte` and kernel file helpers are not dependencies.

Load libraries with type checking off, then enable it for a typed client if wanted:

```sh
shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen \
  -e '(io.write-file "example.bin" (buffer.from-string "hello"))' \
  -e '(let Result (io.read-file "example.bin" 1024) (buffer.string (hd (tl Result))))'
```

This writes five bytes and returns `[ok 5]`, then reads them with an explicit 1024-byte limit and prints
`hello`. A program must handle the error alternative before extracting the value. No native assembly or
new runtime support is required. The core, including memory endpoints, works without the FFI and on static
builds; the file backend needs dynamically loadable system libraries.

## Files and memory endpoints

| Operation | Result and meaning |
| --- | --- |
| `io.open-file Path Mode` | `[ok Endpoint]` or `[error Error]`; caller owns closing it |
| `io.read-file Path Limit` | `[ok OwnedView]` or `[error Error]`; closes the file on every exit |
| `io.write-file Path View` | `[ok Count]` or `[error Error Total]`; truncates/replaces, writes, then closes |
| `io.with-input-file Path F`, `io.with-output-file Path F` | Open, call F with the endpoint, then close |
| `io.input-buffer View` | Read endpoint owning an independent snapshot of View |
| `io.output-buffer View` | Write endpoint borrowing a fixed writable range; full capacity is an error |
| `io.with-endpoint Endpoint F` | Call F then close Endpoint, preserving callback and cleanup failures |
| `io.close Endpoint` | Flush attached output and close once; `[ok]` or `[error Error]` |

File modes are `read` (existing), `write` (create/truncate), `append` (create/append) and `read-write`
(existing, shared position, no truncation). Opening with `write` is destructive immediately; replacement is
not atomic. Paths are nonempty NUL-free strings. Relative paths use a snapshot of `*home-directory*` at
open time; the library resolves this itself without kernel file helpers. POSIX paths use their string's
bytes; Windows converts UTF-8 to UTF-16 for `_wopen`, opens in binary mode and prevents inheritance.
Windows drive-relative paths such as `C:name` are rejected. POSIX descriptors use close-on-exec. Creation permissions are 0666 subject to the POSIX umask.

File reads/writes release the VM lock when other Shen threads exist. They retry EINTR, but do not promise
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
| `io.read-some E View []` | `[read N]`, `[eof]`, `[error Error]` |
| `io.write-some E View []` | `[written N]`, `[error Error]` |
| `io.read-exact E View []` | `[ok Length]`, `[eof Total]`, `[error Error Total]` |
| `io.write-all E View []` | `[ok Length]`, `[error Error Total]` |

For a nonempty request, successful N is positive and may be shorter than View. A short read is not EOF. Socket operations can use an installed [absolute deadline](deadlines.md).
An error from a single transfer means no bytes delivered by that call; accumulated operations report the
acknowledged total. Resume from that total, not the start. Bytes already read remain in the destination;
undelivered bytes remain untouched. An unexpected backend exception or malformed result raises.

A valid empty request returns `[read 0]` or `[written 0]` without probing the backend. It supplies no EOF
information. Invalid storage, direction, closed state or options still raise before I/O. Transfer options
currently must be `[]`; unsupported options are rejected. Indices, counts and limits must be nonnegative
fixnums, and integral boxed reals are refused.

## Bounded readers

`io.reader E Options` borrows E's read direction. Options are `[]` for the endpoint capacity or
`[[chunk-size N]]` for a smaller capacity. File/memory endpoints default to 65536 bytes. Capacities are
positive fixnums, at most 1048576 bytes, and cannot exceed the endpoint's own bound.

| Operation | Meaning |
| --- | --- |
| `io.read-chunk R` | `[chunk OwnedView]`, `[eof]` or `[error Error]`; consumes available input |
| `io.peek R Count` | `[ok OwnedView]`, `[eof]` or `[error Error]`; fill up to Count without consuming |
| `io.peek-up-to R Count` | Wait for some input and return at most Count owned bytes without consuming |
| `io.peek-some R` | `[ok OwnedView]`, EOF or error; wait only for some input, preserving it in the queue |
| `io.consume R Count` | Consume only already available bytes, returning R |
| `io.available R`, `io.position R` | Queued bytes and total bytes consumed since reader creation |
| `io.read-into R View` | `[read N]`, `[eof]` or `[error Error]`; consume into a caller's range |
| `io.reader-exact R View` | Fill View, or `[eof Total]` / `[error Error Total]` |
| `io.read-all R Limit` | `[ok OwnedView]` or `[error Error]`; aggregate up to the explicit limit |

`io.window R`, `io.window-fill R Need` and `io.window-size R` let a parser read the queue in place, as
[`grammar.read`](grammar.md) does: the queue moves to the start of the reader's buffer and fills append to it
until something is consumed, so positions stay valid while the parser waits for more.

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
(define count-chunks
  R Total -> (count-chunk R Total (io.read-chunk R)))

(define count-chunk
  R Total [chunk V] -> (count-chunks R (+ Total (buffer.length V)))
  _ Total [eof] -> [ok Total]
  _ _ [error E] -> [error E])

(io.with-input-file "example.bin"
  (/. E (count-chunks (io.reader E [[chunk-size 4096]]) 0)))
```

[Binary framing](framing.md) already uses this reader to consume bounded messages across chunks.
A future general streaming parser should share its unread input and consume only accepted bytes.
It must not add an unrelated read-ahead queue or wrap a kernel stream. The current complete-input format
examples on the buffers page can already parse a successful `read-file` result.

## Buffered writers

`io.writer E Options` borrows E's write direction with the same capacity options as a reader.
`io.write W View` returns `[accepted N]` or `[error Error Accepted]`. Acceptance counts input copied into
library buffering or already delivered during this call; it does not promise that pending bytes reached
the endpoint. `io.pending W` reports the unsent count.

`io.flush W` returns `[ok Written]` or `[error Error Written]`, counting bytes delivered during this flush.
Each short write advances the pending offset immediately. Failure keeps the unsent suffix; a later flush
retries only that suffix. New nonempty writes are refused until an explicit successful flush clears the
failure. When a write fails during an implicit flush, resume its input at Accepted after clearing that
failure; the buffered prefix must not be replayed. Empty writes accept zero.

Closing E attempts to flush its writer, then closes even if flushing fails. Unsent output is lost on close;
the close result reports the failure. Garbage collection is not a successful flush or a descriptor close.

## Errors, scopes and ownership

Errors have the shape `[io-error Operation Domain Code Resource Message Progress Secondary]`.
Use `io.error-operation`, `io.error-domain`, `io.error-code`, `io.error-resource`, `io.error-message`,
`io.error-progress` and `io.error-secondary`. Domains include `library`, `posix`, Windows `crt` / `win32`,
`foreign` for an unavailable backend, and `shen` for a caught scope callback exception. Native codes are
captured immediately after the failing call. `io.error Op Resource Message` constructs a library error;
`io.native-error Op Domain Code Resource Message` constructs one with native details.

Accumulated errors include progress in their result and error record. For `write`, progress is accepted
input; for `flush`, it is delivered output. `read-all` records the consumed prefix. Secondary is a list of
cleanup errors. Programming errors raise; expected transport failures return structured errors.

`(io.let-ok X Result ... Body)` chains results: it binds each X to the value of an `[ok X]` result, in order, and
gives Body, or the first result that is not ok, unchanged; `_` takes `[ok]` or `[ok X]` and binds nothing. It is a
macro, so it applies to files read after `io.shen`:

```shen
(io.with-input-file "notes.txt"
  (/. E (io.let-ok Text (io.read-all (io.reader E []) 4096)
          [ok (buffer.string Text)])))
```

A scope callback must return `[ok Value]` or `[error Error]`. The scope catches exceptions, closes on
every exit and returns the same result family. Callback failure stays primary; close/flush failure is
appended to Secondary. A cleanup failure after callback success becomes the returned error. Repeated
close returns its first result and never closes a reused descriptor.

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
copies into it and returns, and keeps no reference to it. Read returns `[read N]`, `[eof]` or `[error Error]`; Write returns `[written N]` or `[error Error]`.
N must be positive and no larger than the supplied chunk. A zero write becomes a no-progress error;
a zero nonempty read is an invalid backend result. Deliver progress first, then report a later terminal
condition on the next call. Expected failures must use these results rather than throwing after a transfer.
Close is a frozen zero-argument operation returning `[ok]` or `[error Error]`. Unused directions can use
`(function io.no-read)` / `(function io.no-write)`.

Public arbitrary views are copied through these bounded chunks. Blocking FFI byte arguments may be
copied by the runtime too when other threads exist; no unrooted moving-heap address crosses a blocking
call. This first implementation favors safe bounded copies; it does not promise zero-copy I/O.

Declarations expose opaque `io.endpoint`, `io.reader`, `io.writer`, `io.error`, and datatype rules for
`io.read-result`, `io.write-result`, `io.transfer-result`, `io.peek-result`, `io.chunk-result`,
`io.accept-result`, `io.close-result` and `(io.result A)`. Typed clients can construct and match results:

```shen
(define next-text
  {io.chunk-result --> (io.result string)}
  [chunk V] -> [ok (buffer.string V)]
  [eof] -> [ok ""]
  [error E] -> [error E])
```

Load the libraries with `(tc -)` before checking clients with `(tc +)`. `make test-io` runs scripted short
transfers/failures, typed clients, native binary files, foreign views, saved images and targeted GC stress.
File cases explicitly skip the unavailable FFI on fully static builds; the managed core still runs.

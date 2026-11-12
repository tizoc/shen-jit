# Operation deadlines

[lib/deadline.shen](../lib/deadline.shen) supplies absolute operation budgets with an injectable clock.
[lib/clock.shen](../lib/clock.shen) supplies a system monotonic clock through the existing FFI. Load
`buffer.shen` and `io.shen` before `deadline.shen`; load `ffi.shen` before `clock.shen`.

```sh
shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen \
  -l lib/deadline.shen -l lib/clock.shen \
  -e '(let D (clock.deadline 5000) [(> (deadline.remaining D) 0) (<= (deadline.slice D 100) 100)])'
```

This creates a five-second budget and returns `[true true]`. A deadline is an absolute endpoint in time,
not a duration renewed after each successful read or write. Reuse the same value across all short transfers
and retries in one operation. Create a fresh deadline for a new phase, such as reading a head versus
writing a response.

## Clocks and budgets

| Operation | Meaning |
| --- | --- |
| `clock.monotonic` | Nondecreasing integer milliseconds with an unspecified system origin |
| `clock.deadline Milliseconds` | A budget starting now, using that system clock |
| `deadline.after FrozenClock Milliseconds` | The same policy over an injected clock returning milliseconds |
| `deadline.within Parent Milliseconds` | A fresh phase budget using Parent's clock, capped by its remaining time |
| `deadline.remaining D` | Milliseconds remaining, clamped to zero |
| `deadline.expired? D` | True at or after the absolute endpoint |
| `deadline.slice D Maximum` | The smaller of remaining time and a positive integer Maximum |

Durations and clock results must be nonnegative fixnums; integral boxed reals are refused. Zero duration is
immediately expired. Arithmetic overflow raises. Injected clocks must be nondecreasing; backwards movement
raises. One task owns a deadline and its clock state, as it owns the I/O operation using them. The deadline
can derive a shorter phase without extending a total operation/connection budget. An expired parent
produces an immediately expired phase. Each value contains the initial absolute endpoint and the last observed clock value, not a decrementing slice count.

The managed policy works without the FFI, including static builds:

```shen
(let Time (address-> (absvector 1) 0 100)
     D (deadline.after (freeze (<-address Time 0)) 50)
     _ (address-> Time 0 140)
  (deadline.remaining D))
```

This returns 10. Clock injection also makes boundary and progress tests independent of scheduling.
`clock.monotonic` uses POSIX `clock_gettime(CLOCK_MONOTONIC)` on supported 64-bit Linux/macOS platforms,
converting the timespec to integer milliseconds. Windows uses
[GetTickCount64](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64),
whose timer resolution is normally 10–16 ms. Millisecond units do not promise millisecond resolution.
Suspend accounting follows the selected host clock. Wall-clock adjustments do not define these budgets. OS scheduling can delay
observation of expiry; a deadline is not a hard real-time completion guarantee.

The system clock needs dynamically loadable libraries. It does not add a clock primitive or kernel I/O
dependency. Saved deadlines reload stale and raise when checked, even with an injected clock; recreate
budgets for the new execution rather than reusing an old absolute time or clock state.

## Socket I/O

Load `deadline.shen`, and optionally `clock.shen`, along with the [socket endpoint libraries](io-sockets.md).
`io.socket-deadline E D` installs a budget for both directions of a connected endpoint and returns E.
`io.socket-unlimited E` removes it and returns E. A new endpoint has no deadline. Transfer options remain
`[]`; this policy is attached to the owned endpoint rather than passed to every reader/writer call.

The adapter checks the budget before each native send/receive attempt and before write shutdown. A wait
uses at most the smaller of 100 ms and the current remaining time, then recalculates from the clock.
Readiness, EINTR, partial progress and successful short transfers never renew the budget. Close always
attempts native cleanup, including when the budget has expired.

Expiry returns the existing I/O error family with domain `timeout`, code 0 and message `"deadline expired"`.
Its operation/resource identify the failing transfer. Accumulated reads/writes retain their total in both
the result and `io.error-progress`. A failed buffered flush keeps the unsent suffix. Changing the budget
permits an explicit flush retry; new nonempty writes remain blocked until that flush succeeds. Write
shutdown does not send FIN after a failed flush or expired budget, and reports already flushed progress
if expiry happens before the shutdown call.

Reader timeouts are retryable after being reported. Queued bytes are delivered first; consuming them
does not discard the pending timeout. After that timeout is returned, a later reader operation can retry
the backend under a new budget. EOF and other transport failures stay remembered. Protocol framers such as
[binary framing](framing.md) and [HTTP head framing](http-head.md) treat a timeout as a terminal failure
of that message; do not restart them in the middle of a partially consumed message.

A valid empty transfer still returns zero without probing or consulting the transport budget. Buffered
bytes can be consumed and output can be accepted into library buffering without a native call; the socket
policy governs native progress and waiting. For a total header-capture budget that also checks queued
input and completion, use `http.read-head-until` with the same deadline installed on its socket.

File operations, DNS, connect/accept and arbitrary blocking native calls do not gain deadlines from this
adapter. Cancellation and synchronization remain separate facilities. Unsupported transfer options still
raise. Budget values must not be changed or replaced concurrently with an active endpoint operation.

## Types and checks

Declarations expose opaque `deadline`, clock functions and the socket setters to typed clients. Load the
libraries with `(tc -)` before enabling `(tc +)`. Timeout results use the existing typed I/O variants.
`make test-io` covers fake-clock boundaries, native waits, progress across short reads/writes, retry after
timeout, failed-flush retention, close/shutdown, stale images and every-allocation GC. Native cases skip
explicitly when static builds cannot load the FFI; managed policy tests still run.

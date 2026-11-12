# Subprocesses and pipelines

`lib/process.shen` launches programs with explicit arguments and owned child handles.
`lib/process-io.shen` adds bounded capture, streaming through our [I/O endpoints](io.md), cancellation
and pipelines. Neither library uses kernel streams for file or pipe contents.

## Build and load

```sh
make process
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen \
  -l lib/deadline.shen -l lib/clock.shen -l lib/process.shen -l lib/process-io.shen -l program.shen
```

The adapter depends only on the public `include/shen.h` API and system libraries. Linux needs glibc
2.29 or later; macOS needs 10.15 or later; Windows uses Windows 10 APIs. Fully static Linux executables
cannot load it. Ordinary builds do not need the adapter or a third-party subprocess library.

Binary archives include its sources and build script. From an installation root:

```sh
sh lib/build-process.sh lib/shen-process.so
# MSYS2 UCRT64: sh lib/build-process.sh lib/shen-process.dll
```

`CC` and `CFLAGS` are supported. Loading never invokes a compiler. The facade searches `./build/`,
`./lib/` and the current directory for `shen-process.so` and `shen-process.dll`. Set
`process.*adapter-files*` before loading to use absolute names elsewhere. The adapter ABI is 1.

## Start a child

`(process.spawn Program Arguments Options)` returns `[ok Child]` or `[error Error]`. Arguments is a
list of strings, excluding argv[0]; Program supplies argv[0]. There is no implicit shell expansion,
globbing, interpolation or batch-file execution. Invalid option shapes, NUL bytes and invalid argument
values raise before starting a child. OS launch failures remain structured native errors.

| Spawn option | Default | Meaning |
| --- | --- | --- |
| `[cwd Path]` | `"."` | Child working directory, resolved against one home-directory snapshot |
| `[environment Settings]` | `[]` | `[Name Value]` overrides; `[Name []]` removes an entry; `""` is a valid value |
| `[clear-environment Boolean]` | `false` | Construct a replacement environment instead of inheriting |
| `[search-path Boolean]` | `true` | Search the child's PATH when Program has no path separator |
| `[stdin Stream]` | `inherit` | Child input configuration |
| `[stdout Stream]` | `inherit` | Child output configuration |
| `[stderr Stream]` | `inherit` | Child error configuration |
| `[group Boolean]` | `false` | Create a separate process group or Windows job for termination |

Stream is `inherit`, `null`, `pipe` or `[file Path]`. For stdout/stderr, `[file Path]` truncates and
`[append Path]` appends. File redirects and relative program paths are interpreted against the child
working directory. Creating an output redirect can truncate a file even if a later launch step fails;
use the filter example's replacement scope when preserving an old destination matters.

Home and environment are snapshotted once for a pipeline. No operation changes the parent's native
cwd or environment. PATH overrides affect executable lookup too. POSIX falls back to `/usr/bin:/bin`
when PATH is absent; Windows falls back to its system directory. Empty PATH components mean the child
cwd. Windows appends `.exe` when an executable has no extension and rejects direct `.bat`/`.cmd` files.
Drive-relative Windows paths such as `C:name` are unsupported.

POSIX argv/path strings preserve bytes. Windows converts strict UTF-8 to UTF-16 and encodes the
command line by Microsoft CRT argument rules, including empty arguments, quotes and trailing
backslashes. Programs using another command-line parser may interpret that string differently.
No shell convenience operation is provided; invoke an interpreter explicitly when its syntax is wanted.

Each string is limited to 1 MiB; argument/environment lists have at most 65536 entries and an 8 MiB
native copy budget each. OS limits can be smaller. Windows command lines are limited to 32766 UTF-16
units before the terminator. Environment names cannot be empty or contain `=`; Windows names compare
case-insensitively. Hidden Windows drive-directory variables are not part of the public environment.

## Ownership, status and waiting

| Function | Result |
| --- | --- |
| `(process.pid Child)` | PID metadata; never a substitute for the owned handle |
| `(process.poll Child)` | `[ok [running]]`, `[ok [exited Code]]`, `[ok [signalled Signal]]`, or an error |
| `(process.wait Child Milliseconds)` | `[ok Status]`, `[pending]`, or `[error Error]` |
| `(process.terminate Child)` | Request termination of the child, or its configured group/job |
| `(process.kill Child)` | Force termination of the child, or its configured group/job |
| `(process.close Child)` | Release pipes/native ownership after observing exit; idempotent |

A timed wait does not terminate the child. Closing a running child is an error and leaves it owned.
Nonzero exit codes are data, not launch failures. POSIX signal exits are distinct; Windows retains
its full exit code, including 259 after the process handle is signalled.
On POSIX, terminate sends SIGTERM and kill sends SIGKILL. Windows uses forced process/job termination
for both operations; graceful application shutdown needs its own protocol or stdin EOF.

POSIX observes exit without reaping until close, reserving the leader's PID while group operations
remain possible. Closing then reaps it. Do not independently reap these children or configure
SIGCHLD to discard them. The adapter rejects `SIG_IGN`/`SA_NOCLDWAIT`. Windows retains its process/job
handles. Saved live children and pipe endpoints reload stale and must be recreated; owned report
bytes and status snapshots survive images and GC.

Closing does not implicitly terminate background descendants. A group/job controls the target of
termination requests; release it only when that control is no longer needed. POSIX descendants can
escape by changing their group/session, so grouping is not process-tree confinement. Main-program
exit is not a substitute for explicit cleanup. One task owns a child's communication/wait/close;
other tasks can request cooperative cancellation through the predicate below.

## Pipe endpoints

`process.stdin`, `process.stdout` and `process.stderr` return their corresponding `io.endpoint` when
configured as `pipe`, and raise otherwise. Parent stdin is writable; stdout/stderr are readable.
Closing stdin delivers EOF to the child. Endpoint capacities are 64 KiB.

`(process.pipe-until Endpoint Deadline Cancel)` sets an existing monotonic deadline and frozen boolean
cancellation predicate for direct pipe I/O. Native reads/writes are nonblocking; waits return to Shen
in slices of at most 20 ms (10 ms on Windows). No thread remains stuck in an indefinitely blocking pipe
read/write. A pipe deadline does not terminate the child; its owner still decides how to finish it.

Low-level callers must service input and both outputs concurrently. Writing all input before reading
output, or waiting for exit before draining full output pipes, can deadlock the child. The operations
below provide that pumping and keep each direction exclusively owned while active.

## Capture and streaming

`(process.run Program Arguments Input Options)` starts a child with three pipes and returns a report.
Input is a byte view. Run defaults to a separate group/job, a 30 s deadline and 1 MiB capture limit
for each output. Spawn options apply except standard-stream redirects: use low-level spawn for those.

```shen
(define example.filter
  Program Arguments ->
    (process.run Program Arguments (buffer.from-string "hello")
      [[timeout 2000] [stdout-limit 4096] [stderr-limit 4096]]))

(define example.success?
  [ok Report] -> (process.success? Report)
  [error _] -> false
  [error _ _] -> false)
```

`process.communicate Child Input Options` does the same pumping for an already spawned child, but
leaves the child handle owned by its caller. It closes the child's pipe endpoints on completion.
The child must have an open stdin pipe; output streams that were not piped are marked unobserved.
Only communication options apply; cwd/environment/group cannot be changed after spawning.

`(process.run-to Program Arguments Source OutputSink ErrorSink Options)` streams through borrowed
I/O endpoints. `process.communicate-to` accepts an existing Child and the same Source/sinks. These
operations do not flush or close caller-owned endpoints. They retain no output body; sinks apply
backpressure before another output chunk is delivered. Short writes retry only their unacknowledged
suffix. Each acknowledged write contributes to the report immediately, even before a later error or
callback exception. Source and output sinks must differ; the two output sinks may be shared.

The same Shen loop feeds stdin and drains both outputs, fairly, without worker threads or unbounded
queues. The adapter uses nonblocking POSIX pipes or Windows byte pipes in nonblocking wait mode;
child pipe ends stay blocking. Windows uses short idle sleeps rather than a general readiness driver.
Callbacks and ordinary file endpoints have their own blocking policy: a deadline cannot preempt an
arbitrary source/sink callback or an OS process-creation call. It is checked before the next pump turn.

| Communication option | Default | Range/meaning |
| --- | --- | --- |
| `[timeout N]` | 30000 | 0..2147483647 ms, starting before process creation for run/pipeline |
| `[cleanup-timeout N]` | 1000 | 1..60000 ms additional cleanup budget after failure |
| `[terminate-grace N]` | 100 | 0..60000 ms before forced termination; capped by cleanup budget |
| `[stdout-limit N]` | 1048576 | Total acknowledged stdout bytes |
| `[stderr-limit N]` | 1048576 | Total acknowledged stderr bytes, per pipeline stage |
| `[chunk-size N]` | 16384 | 1..65536 bytes |
| `[cancel FrozenBoolean]` | false predicate | Cooperative cancellation, also during idle waits |

Capture limits cannot exceed 256 MiB per output; streaming quotas may reach the maximum fixnum and
do not allocate a corresponding buffer. Capturing retains chunks and joins them at completion, so
allow space for both the chunks and the final view. Streaming keeps bounded transfer chunks, plus
caller-owned source/sink storage and bounded native argument/environment copies.

A normal exit returns `[ok Report]`, including a nonzero exit. Launch/setup failures can return
`[error Error]`. Transfer failures, limits, cancellation and timeouts return `[error Error Partial]`.
Run and pipelines call the cancellation predicate once before starting anything: a value that is not
a frozen boolean raises there, and a cancellation already requested returns `[error Error]`.
If a child exits before consuming stdin, a pipe-write failure can be primary, with its exit status in
the partial report.
Already received output is retained within its cap. Failure requests termination, closes pipes,
escalates to forced termination after the grace, and waits within the cleanup budget. Both process
completion and pipe draining count toward the deadline; a leader's exit alone is not completion.
Primary errors keep secondary cleanup errors. If cleanup cannot observe exit in time, the partial
report's child remains owned: retain it, wait/terminate as appropriate, then close it.

| Report accessor | Meaning |
| --- | --- |
| `process.child` | Child handle; run closes it after successful cleanup, communicate leaves it owned |
| `process.status` | Last observed status |
| `process.success?` | Status is `[exited 0]` |
| `process.input-count` | Bytes acknowledged by the child's stdin pipe |
| `process.input-read-count` | Source bytes consumed, including the retained pending suffix |
| `process.pending-input` | Bounded prefetched input not acknowledged by the child |
| `process.output-count`, `process.error-count` | Bytes captured or acknowledged by the respective sink |
| `process.output-bytes`, `process.error-bytes` | Owned captured views; empty for streamed outputs |
| `process.output-observed?`, `process.error-observed?` | Whether this pump observed that stream |

## Pipelines

`(process.pipeline Commands Input Options)` accepts 1..32 `[Program Arguments]` commands. It connects
intermediate stdout directly to the next child's stdin, feeds the first stage and concurrently drains
every stage's stderr and the last stage's stdout. All stages share a home/environment snapshot and a
single operation deadline. Each stage has its own group/job when grouping is enabled.

```shen
(define example.pipeline
  Program Arguments ->
    (process.pipeline [[Program Arguments] [Program Arguments]]
      (buffer.from-string "pipeline bytes") [[timeout 2000]]))
```

Results contain reports in command order: `[ok Reports]` or `[error Error PartialReports]`. Inspect
all statuses; a nonzero stage does not become an I/O error. Intermediate stdout is not copied or
counted by Shen: its report marks that stream unobserved and has an empty captured view/count zero.
The last report holds captured stdout. Input counts refer to the parent's first-stage writes.

`process.pipeline-to Commands Source OutputSink ErrorSink Options` streams instead of capturing.
Its shared error sink receives stages in pump order, without claiming an ordering between independent
streams. Captured stderr remains separate per stage. If a later stage cannot start, previously started
stages are terminated/reaped within the same cleanup policy and returned as partial reports.

## Inheritance and native boundary

POSIX uses `posix_spawn`, never guest-language work in a post-fork child. It unblocks the child's signal
mask, including SIGINT when called from an isolate, whose thread blocks it, and restores SIGINT/SIGPIPE defaults. Runtime
file opens and newly created/accepted Linux sockets use atomic close-on-exec. Our file I/O already
prevents inheritance. macOS spawn closes everything except explicitly established standard streams.

Newer glibcs use the native close-from spawn action. With glibc before 2.34, the adapter snapshots
`/proc/self/fd` and closes unrelated descriptors in the child; atomic close-on-exec protects project-owned
files/sockets created concurrently. Foreign code must likewise create descriptors close-on-exec to
avoid opening an inheritable descriptor after that snapshot. This is not a sandbox for arbitrary FFI.

Windows uses `CreateProcessW` with an explicit inherited-handle list. Grouped children are assigned to
a job atomically through the startup attribute list, before they execute. File/pipe handles never cross
CRT descriptor tables: native handles stay in the adapter, while our file endpoints retain their own CRT
ownership. Inputs are copied to native storage before the native work, and managed results are rooted across GC.

## File-filter application

```sh
make process fs
build/shen-jit script tools/process-filter.shen INPUT OUTPUT PROGRAM ARG ...
```

The example streams INPUT through a program, captures at most 64 KiB of stderr, and limits stdout to
1 GiB. It publishes a temporary sibling as OUTPUT only after exit 0 and successful I/O closure.
A failed command, failed output, timeout or nonzero exit preserves an existing destination. It does
not add crash durability or metadata preservation beyond the [filesystem replacement contract](fs.md).

`make test-process` uses a separately compiled child and independent Python byte oracles. It covers
argument fidelity, binary transfers larger than pipe buffers, simultaneous stdin/stdout/stderr,
Unicode, environment/cwd, inheritance, partial sinks, descendant-held pipes, cancellation/escalation,
pipeline failures, typing, images/GC, backpressure and 8/64 MiB streams under a 16 MiB heap cap.
The native suites and adapters also run under ASan/UBSan with `make test-san`. Static Linux runs the
pure argument/option checks and skips native compilation/fixtures explicitly.

# Structured workers

`lib/parallel.shen` provides structured workers with isolated runtimes.
Load `lib/buffer.shen`, then this library, under `(tc -)`. It uses native OS
threads: each child has a private heap, collector, globals and JIT. Guest
execution proceeds concurrently. The existing `thread` function keeps its
current behavior.

Worker primitive metadata is installed by the normal runtime-image bootstrap.
Loading this library defines its buffer wrappers and types.

The parent waits
for every child to join before the scope returns or propagates an ordinary
Shen error. A scope can run
several batches; use that to amortize image loading and compilation.

## Byte messages

Use `parallel.with-workers` for an explicit byte protocol. Save this as `echo-worker.shen`:

```shen
(load "lib/buffer.shen")
(load "lib/parallel.shen")
(define echo.entry
  Request -> (parallel.reply (buffer.wrap Request)))
```

Build its image, then send one request to each of two children:

```sh
build/shen-jit eval -q -l echo-worker.shen \
  -e '(shen-jit.save-executable "echo-worker" [])'
build/shen-jit eval -l lib/buffer.shen -l lib/parallel.shen \
  -e '(parallel.with-workers "echo-worker" (intern "echo.entry") 2
         (parallel.config 16777216 67108864 (buffer.new 0))
         (/. Scope (map (function buffer.string)
                     (parallel.batch Scope [(buffer.from-string "first")
                                            (buffer.from-string "second")]))))'
```

`eval` prints `[first second]`, Shen's display of the two strings. An entry
receives one managed bytes object
and returns `parallel.reply` or `parallel.replies`. It runs in the saved image,
without invoking that executable's main function. Use an image compatible with
the current runtime and architecture. `intern` supplies the function's **name**;
the parent callback is an ordinary local closure, but no closure crosses heaps.

## Parent API

| Function | Meaning |
| --- | --- |
| `parallel.config Initial Maximum Input` | Per-child initial semispace and heap cap, in bytes, plus a `buffer.view` to snapshot. |
| `parallel.with-workers Image Entry Count Config Body` | Start an integer count of 1 to 64 children; call `Body` with an opaque scope; always join on exit. |
| `parallel.count Scope` | Configured child count. |
| `parallel.batch Scope Requests` | Exactly one `buffer.view` per child; return owned views in child order. |

Pack several jobs into one request when needed. An application defines its
own empty-shard message. The batch call waits for all replies, so there is no
unbounded submission queue. Multiple reply slices from a child are flattened
in child order. A request is copied before dispatch; a reply is copied into
the parent's heap before the child can process another batch. Returned views
remain usable after the scope has joined and its snapshot has been released.

Whole managed views avoid an intermediate library copy. Partial or foreign
views are first materialized as managed bytes. This does not make it safe for
unrelated native code to mutate a foreign source while it is being copied.

Choose the worker count for the available CPUs and memory. The limit of 64
bounds scope resources; it is not an automatic choice of how many CPUs to use.

Limits are checked at the runtime boundary: 64 MiB for the immutable snapshot,
1 MiB for each request, at most 16 reply slices per child and 64 MiB for the
aggregate reply bytes in a batch. Initial heaps are at least 64 KiB; each
child's maximum is at least its initial size and at most 512 MiB. These are
configured heap limits, **not** process RSS limits: code, stacks, both
semispaces, native allocations and the parent's heap also consume memory.

## Child API and shared-data safety

| Function | Meaning |
| --- | --- |
| `parallel.reply View` / `parallel.replies Views` | Describe owned managed reply slices. Shared and foreign storage cannot be returned directly. |
| `parallel.shared` | Borrow the scope's immutable snapshot. Also available to the parent inside the scope. |
| `parallel.shared-length Input` | Snapshot byte length. |
| `parallel.shared-u8 Input Offset` / `parallel.shared-u32 Input Offset` | Checked, read-only reads. |
| `parallel.shared-copy Input Offset Count` | Make an owned `buffer.view` that can outlive the scope or become a reply. |
| `parallel.index` | Zero-based child index. |
| `parallel.cancelled?` | Cooperatively check whether a sibling failed or the scope is closing. |

The source is copied once into scope-owned native storage. Later mutation of
the parent's source cannot affect children. The shared descriptor has no
writable address, resize or foreign-pointer conversion. Checked byte reads
and copy operations accept it; writes reject it. The host joins the children
before releasing the storage and revokes escaped parent aliases on exit.
An escaped descriptor has length zero; reads fail rather than accessing freed
memory. The runtime checks scope identity and lifetime even in untyped code.

The optional type checker gives this descriptor the opaque type
`parallel.shared`, separate from writable `buffer.storage` and `buffer.view`.
Typed clients can read it or explicitly copy from it. This reduces accidental
mutation and conversion; it is **not** a static lifetime/borrow proof, an
affine type system, or a guarantee that a named entry obeys its protocol.
Runtime validation remains necessary. No general Shen object graph or shared
mutable collection crosses this boundary.

## Failure and deployment limits

An ordinary parent or child error closes the scope and joins all children
before it propagates. Long computations should poll `parallel.cancelled?` at
a coarse interval. Cancellation is cooperative: a child that never returns
and never checks cancellation can keep the parent waiting indefinitely.
There is no forced termination, native-fault isolation or task retry.

Children reject nested scopes, legacy threads, streams and saved stream
aliases, executable/image writing, process exit, REPL installation, and C API
procedures/callbacks. Plain foreign functions are trusted: an entry must only
call ones safe to invoke concurrently. Process-wide profiling and legacy
threads cannot overlap a scope. Independent heaps do not isolate arbitrary
native library globals. Whole-file reads remain available: they return a private
value and close the file within the call, without creating an escaping Shen stream.

`make test-parallel` checks the interface, typed readers, repeated batches,
result ownership, alias revocation and cleanup, and `make test-workers` the
runtime beneath it.

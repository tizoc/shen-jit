# Structured workers

`lib/parallel.shen` provides structured workers with isolated runtimes.
Load `lib/buffer.shen`, then this library, under `(tc -)`. It uses native OS
threads: each child has a private heap, collector, globals and JIT. Guest
execution proceeds concurrently. The existing `thread` function keeps its
current behavior.

Worker primitive metadata is installed by the normal runtime-image bootstrap.
Loading this library defines its buffer wrappers and types.

For ordinary application jobs, start with `parallel.with-map` and
`parallel.map` from `lib/parallel-map.shen`. The byte API gives explicit
control of copied messages and one immutable byte snapshot. The parent waits
for every child to join before the scope returns or propagates an ordinary
Shen error. A scope can run
several batches; use that to amortize image loading and compilation.

## Mapping ordinary Shen values

Load optional `lib/parallel-map.shen` after `buffer.shen` and `parallel.shen`.
It adds copied values and a named unary worker function:

```shen
(parallel.with-map "worker-image" (intern "my-job") 4
  (parallel.config 16777216 67108864 (buffer.new 0))
  (/. Scope
    (parallel.map Scope [["first" 100] ["second" 200]])))
```

For small jobs, use this starting heap configuration: 16 MiB initially and
a 64 MiB maximum per child, with `(buffer.new 0)` when there is no shared
input. The same `parallel.config` works with either API. Keep the worker
count explicit, and increase the heap limits for larger images or working
sets. These limits apply per child; see the resource limits below.

`my-job` must be defined with arity one in the saved image, which must also
contain the three libraries. Each invocation receives one value and returns
one value. Results keep input order. The callback can call `parallel.map`
several times; each worker's private globals and compiled code persist until
scope exit. Input lists are partitioned into contiguous shards, one per worker.
There is no automatic sequential fallback: private worker state and effects
can differ from evaluating the same function in the parent.

Supported values are numbers, booleans, symbols, strings, `[]` and proper lists
of supported values, recursively. Signed integers retain their full precision;
reals retain their binary representation, including negative zero and NaN
payloads. Strings retain their bytes; symbols are re-interned by name in the
receiving runtime. Mutable vectors/bytes, closures, streams, foreign/native
handles, shared descriptors and improper lists are rejected. Arguments and
results are copied, with no preservation of object identity or shared list
tails. No managed pointer crosses heaps.

All requests are encoded and checked before dispatch. A failure there runs no
jobs. A worker failure or unsupported result follows the ordinary scope error
and join rules; earlier worker effects are not rolled back. Cancellation is
checked between jobs, and a long job can poll `parallel.cancelled?`. Large
read-only input stays separate: a job may read `parallel.shared` and return
ordinary values derived from it.

| Function | Meaning |
| --- | --- |
| `parallel.with-map Image Name Count Config Body` | A structured scope using the saved image's named unary function. |
| `parallel.map Scope Values` | Return one owned result per input, in order. Empty inputs and empty shards are valid. |
| `parallel.encode Value ByteLimit` | Encode a supported value as a bounded `buffer.view`. |
| `parallel.decode View` | Decode exactly one value, rejecting malformed or trailing data. |

Each map accepts at most 4096 jobs. Each encoded packet has at most 262144
value nodes and 64 nested nonempty lists, including the protocol envelope.
Requests are at most 1 MiB per worker; each worker gets an equal share of the
64 MiB aggregate reply limit. A large shard fails when it exceeds its own
budget. Bounds cover the encoded packets; they do not bound the computation,
allocation or running time of the user function. Existing heap caps apply.
The binary codec is a versioned transport for compatible local workers, not
a general object/image serializer or a persistent storage format.

The optional checker describes this recursive subset as `parallel.value`;
`parallel.map` returns `(list parallel.value)`. It cannot infer an arbitrary
named function's result type, prove the contents of a saved image or enforce
size/depth limits. Untyped callers and worker replies receive the same runtime
validation. The opaque `parallel.map-scope` type is separate from a byte scope.

The value type has one-way introduction rules. Extract a member with the checked
accessors `parallel.number`, `parallel.boolean`, `parallel.string`, `parallel.symbol`
or `parallel.list`; each raises if the value is not of that kind. `parallel.list`
returns `(list parallel.value)` and checks its supported contents. A copied value
cannot implicitly claim any of these member types.

The complete example in [tools/parallel-map.shen](../tools/parallel-map.shen)
maps named range-sum jobs and uses its own executable as the worker image:

```sh
build/shen-jit eval -q -l lib/buffer.shen -l lib/parallel.shen \
  -l lib/parallel-map.shen -l tools/parallel-map.shen \
  -e '(shen-jit.save-executable "parallel-map-demo" parallel-demo.main)'
./parallel-map-demo --sequential
./parallel-map-demo --workers 4
```

Both print the same ordered labels and totals. `make test-parallel` includes
copied-value round trips, bounds, typed clients, state reuse, ownership and
failure cleanup. When Python 3 is available it also runs independent binary
fixtures, including exact integer/floating-point bits and malformed packets.

The [source-deps value adapter](../example-apps/source-deps/README.md#optional-ordinary-value-batches)
combines ordinary query/result lists with a separate shared immutable graph.

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

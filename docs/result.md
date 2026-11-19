# Results

The functions `(result.ok Value)` and `(result.err Error)` construct immutable one-field structs
and return their union, `(result.t (E * A))`. Here `E` is the error type and `A` the success type.
Match the structs with `(:result.ok Value)` and `(:result.err Error)`. For example, `(io.result A)` uses `io.error` and
`(treesitter.result A)` uses `treesitter.error`. A subprocess failure also carries the reports
collected before failure, so its error type is `(io.error * (list process.report))`.

```sh
shen-jit eval -m result -l program.shen
```

`(result.let-ok X1 R1 X2 R2 ... Body)` chains results, as `let` binds values: it binds each X to the value of
its result when that is ok, in order, and gives Body, or returns the first error payload in an err result. `_`
ignores the success payload, including `[]` for an empty success. A namespace uses `result` to name its type, and
imports `let-ok`, `ok` and `err` for the short forms below.

```shen
(shen.x.namespace example
  (use result)
  (import result let-ok ok err)
  (export total describe-total)

  (define positive
    {number --> (result.t (string * number))}
    N -> (if (> N 0) (ok N) (err "not positive")))

  (define total
    {number --> number --> (result.t (string * number))}
    A B -> (let-ok X (positive A)
                   Y (positive B)
             (ok (+ X Y))))

  (define describe-total
    {(result.t (string * number)) --> string}
    (:ok N) -> (str N)
    (:err Message) -> Message))
```

Outside that namespace, call `(result.ok V)` or `(result.err E)`.
`(example.total 1 2)` prints `#<result.ok 3>`, and `(example.describe-total (example.total 1 -2))`
returns `"not positive"`.

The typed contract has exactly two outcomes. `bind` can change the success type from A to B
because only `ok` carries A. Use a success payload to distinguish additional successful outcomes, such as clean EOF.
The `result.t` datatype supplies the constructor, pattern and widening rules for these two outcomes.

`channel.next` returns lists with the literal tags `ok` and `closed`. Namespaces qualify symbols
in patterns too, even when they have no `result` import. Use `with-externals` around each channel
pattern. A namespace that imports `ok` and `err` from `result` can then use both short constructors
in the same definition.

```shen
(define next-result
  (with-externals [ok] [ok X]) -> (ok X)
  (with-externals [closed] [closed]) -> (err "channel closed"))
```

## Functions

| Name | Type | |
| --- | --- | --- |
| `result.ok`, `result.err` | `A --> (result.t (E * A))`, `E --> (result.t (E * A))` | Construct a value of the result union |
| `result.ok.make`, `result.err.make` | `A --> (result.ok A)`, `E --> (result.err E)` | First-class positional constructors |
| `result.ok?`, `result.err?` | `A --> boolean` | Test the struct tag |
| `result.bind` | `(result.t (E * A)) --> (A --> (result.t (E * B))) --> (result.t (E * B))` | F given the value of an ok result, or an err result with the original error payload |
| `result.let-ok` | a macro | `result.bind` for each pair, each lambda over the rest |

## Typed code

Use `(ok V)` or `(err E)` in an expression that returns the union. Their signatures give the
checker the result type directly, which is particularly helpful after matching several `(:ok X)`
patterns. The expressions `(:ok V)` and `(:err E)` construct the individual member types.
A stored member or a call returning a member can also be used where the signature asks for the
outcome family. For example, a function returning `(result.ok number)` can supply a
`(result.t (string * number))`. With an unconstrained common type, two calls returning different
concrete members need a result type from their context. Give producers that return the union a
`result.t` signature, as `positive` does above.

Each step of `let-ok` is a
`bind`, so a chain gives a value of another type than the results it reads, and an error passes through it at
whatever type the chain gives.

A standalone declaration uses the type list `[result.t [E * A]]`.
A library's declarations name the long form, `(result.t (io.error * A))`: `declare` keeps a type as it is written, so
`(io.result A)` there would not match a client's `(io.result A)`, which the typechecker reads as the long form.
A client writes either, and the long form is what types print.

## Streaming results

Reads that can end cleanly use `(io.result (option.t A))`. Match `(:ok [X])` for an item
and `(:ok [])` for EOF. Both are successes, so `let-ok` passes their payload to the continuation.
A transfer failure carries its progress in the returned `io.error`. The process pipeline error
type still pairs its I/O error with partial reports.

Each step makes a closure for the rest of the chain and calls it. In a sealed program, as `shen-jit build` makes,
`bind` is inlined and the closure is applied where it is written, so a chain costs what the tests written out do.
In an open one, as `shen-jit eval` loads libraries, the closure is made and called.

## Migrating list-based clients

| Previous form | Constructor and pattern |
| --- | --- |
| `[ok V]` | `(:ok V)` |
| `[ok]` | `(:ok [])`, with `[]` of type `result.empty` |
| `[error E]` | `(:err E)` |
| `[error E N]` for a transfer failure | `(:err (io.progress E N))` |

A result's type is `(result.t (E * A))`: the product groups the error and value types.
Each constructor takes just its own payload.

Replace list projections with positional patterns. For a tag check use `result.ok?` or `result.err?`.
A success containing `3` prints as `#<result.ok 3>`. Update both sides of callbacks and rebuild
saved images and executables with the migrated code.

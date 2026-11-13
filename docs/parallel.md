# Parallel map

[lib/parallel.shen](../lib/parallel.shen) maps a function over a list in [isolates](guide.md#isolates), which run
on several cores at once. It needs no other library and works in static builds.

```shen
(define fib N -> (if (< N 2) N (+ (fib (- N 1)) (fib (- N 2)))))

(parallel.map 4 fib [25 26 27 28 29 30])
\\ [75025 121393 196418 317811 514229 832040]
```

`(parallel.map N F Xs)` applies `F` to each element of `Xs` with at most `N` isolates, each taking a run of
consecutive elements, and returns the results in the order of `Xs`. An empty list starts no isolate.

- **The function goes by name:** `F` is a function's name, or `[F | Args]`, called with `Args` and then the
  element. An isolate inherits nothing from its caller, not its globals and not its closures, so what `F` needs comes
  in `Args`.
- **What crosses is copied:** each run of `Xs`, the arguments and the results, as messages are. A large value that
  every isolate reads is better shared once with `shen-jit.share` and passed in `Args`: it then crosses by pointer.
- **Errors:** an error that `F` raises, or a result that cannot be sent, such as a closure, makes `parallel.map`
  raise once every isolate has ended, with the first such error in the order of `Xs`.
- **It returns once every isolate has ended,** so the program can change again: defining is refused while
  isolates run.

The work in each isolate should outweigh copying its run there and back and starting the isolate, about 50 µs:
mapping a function that takes a fraction of a microsecond is faster with `map`.

`make test-parallel` runs its tests.

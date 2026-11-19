# Optional values

The `option` module provides the type `(option.t A)`. Write `[]` for an absent value
and `[X]` for a present value of type `A` where the expected type is `(option.t A)`.
Use the same patterns to take an option apart. `(option.none)` and `(option.some X)` return
`(option.t A)` directly. Use them when binding an option before its expected type is known,
such as in a `let` binding.

```shen
(define value-or
  {(option.t A) --> A --> A}
  []  Default -> Default
  [X] _       -> X)
```

`[[]]` holds an empty list. A list of two or more items cannot have type `(option.t A)`.
A module can use `(requires option)` to bring these rules into scope.

Streaming grammar, JSON, and HTTP request reads return `(io.result (option.t A))`.
Match `(:result.ok [X])` for one item, `(:result.ok [])` for clean EOF, and
`(:result.err E)` for an I/O error. A parsed empty list is `(:result.ok [[]])`.

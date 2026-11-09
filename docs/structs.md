# Managed structs

`defstruct` declares a fixed layout over one managed `absvector`. It is available in the default image;
no library needs loading. Put declarations in a source file and load that file with `load` or `-l`:

```shen
(defstruct entry
  key
  (mutable value))

(let E (entry.make "answer" 41)
  (do (entry.value-> E 42)
      [(entry? E) (entry.key E) (entry.value E)]))
```

The result is `[true "answer" 42]`. Bare fields are read-only through the generated API; `(mutable Field)`
also generates a setter. A setter takes the record followed by its new value and returns the same record.
Other references to that record see the update.

This first version supports declarations in source files. A declaration expands to several top-level
definitions, so entering one through the REPL or `eval -e`, which takes only the first expanded form,
does not install the complete API. Load the file under `(tc -)`; automatic type declarations, pattern
matching, defaults, inheritance and native/unboxed layouts are outside this version.

## Generated operations

For the declaration above:

| Operation | Meaning |
| --- | --- |
| `(entry.make Key Value)` | Construct a record; arguments follow declaration order |
| `(entry? X)` | Test the record's nominal tag; other ordinary values return false |
| `(entry.key E)` | Read `key` |
| `(entry.value E)` | Read `value` |
| `(entry.value-> E Value)` | Update `value`, returning E |

These are ordinary functions, including the positional constructor, so they can be passed with `fn`.
There is no `entry.key->`. Field names must be literal symbols and unique; `make` and names beginning with
`%` are reserved. A declaration that would generate colliding operation names, or replace an existing
function on its first definition, raises.

The predicate distinguishes records from different declarations even when their fields agree. Readers
and setters assume a record of the declared type; they do not validate its tag on each operation. Use
the predicate at boundaries. The representation is private: manually forging an absvector or changing
its tag/slots with `address->` bypasses these contracts and read-only fields.

## Labelled construction

The shared `struct.make` macro accepts a literal struct type followed by labelled fields, in any order:

```shen
(struct.make entry
  value <- 42;
  key <- "answer";)
```

Every field must appear exactly once, with `;` after each expression. Unknown, duplicate and missing
fields raise while reading. Each expression is evaluated once, in the order written, before the
constructor is called with the values in declaration order. The declaration must precede construction
in source order. Unknown types and positional arguments to `struct.make` raise while reading.
The generated `entry.make` remains an ordinary positional function, including when passed with `fn`.

## Namespaces and images

A namespace qualifies the type and its generated operations. Field labels remain literal even when
they have the same spelling as a system function or imported alias; initializer expressions resolve
in the caller's scope normally. Generated bodies cannot capture the caller's shadowed primitives.
Import the declaration keyword from `struct` and use its prefix for labelled construction.
Export the type name as well as the operations clients need: `struct.make` resolves its type through
the same imports and export checks as ordinary references.

```shen
(shen.x.namespace catalog
  (import struct defstruct)
  (export entry entry.make entry? entry.key entry.value entry.value->)

  (defstruct entry key (mutable value)))

(shen.x.namespace application
  (use struct)
  (use catalog => c)
  (export answer)

  (define answer
    -> (let E (struct.make c.entry
                value <- 42;
                key <- "answer";)
         (c.entry.value E))))

(application.answer)    \\ 42
```

Identical declarations can be reloaded. They reuse the original private tag, so existing records remain
valid. Changing field order, field names or mutability raises before any generated function is replaced;
start a fresh process to experiment with a different layout. Schemas, syntax registrations and
records survive saved images. A tag is a fresh, unbound symbol, separate from every public operation,
so printing a record does not accidentally call its constructor or a function with the type's name.

The kernel's namespace annotator protects field descriptors and construction labels before name
resolution. A separate declaration callback checks generated names against imports. Both are registered
once for the syntax, independently of individual schemas; Shen/JIT does not replace the namespace walker.
The struct expander consumes protection only in literal field positions, preserving initializer expressions.
`<-` and `;` are system punctuation and need no protection.

With the older `package` form, include `defstruct` and `struct.make` in its external-symbol list when used.

## Cost and the buffer pilot

A constructor allocates one vector with one tag slot plus one slot per field. Its values are ordinary
managed Shen values, and construction can trigger GC. Readers and setters use constant slot indices;
they allocate nothing on success and consult no schema or field-name table. The predicate uses the
runtime's existing safe tagged-vector primitive. Ordinary JIT inlining applies to these functions.
Labelled syntax adds local bindings to preserve evaluation order and builds no runtime field list.

This is useful for compiler state, builders, cursors and other fixed records currently written as
numbered `absvector` accesses. It does not have the allocation/GC contract of the native authoring DSL.

The first migration is the private state of `buffer.builder`:

```shen
(defstruct builder-state
  limit
  (mutable storage)
  (mutable length)
  (mutable sealed))
```

The implementation uses `builder-state.length`, `builder-state.storage->` and the other named operations.
Its five-slot storage, byte limit, geometric growth, finish/seal behavior and public `buffer.*` API are
preserved. The compiler and other manually laid out records have not been migrated.

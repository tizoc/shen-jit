# Kernel overrides

Every kernel function that Shen/JIT replaces, in `src/port/shen-jit.kl`, and why. Stage 0 leaves out a kernel `defun` that the port also defines. Nothing
is overridden just because another port does it: each entry was measured, and [development-log.md](development-log.md) has the numbers. Keep this current with each change.

`make test-overrides` runs each of them beside the kernel's definition, from the KLambda, over generated values, except for `shen.read-evaluate-print`, `shen.toplevel-display-exception` and `shen.x.launcher.main`, which `tests/cli.sh` covers. Where they differ on purpose, `o.known` in `tests/overrides.shen` says how and why.

## Also overridden by Shen/Scheme

The functions that Shen/Scheme 0.54 replaces in its `src/overrides.shen`, with what Shen/JIT does.

| Function | Shen/Scheme | Shen/JIT | Decision |
| --- | --- | --- | --- |
| `hash` | Chez `equal-hash` | C (`shen-jit.hash`) | Done |
| `shen.dict`, `shen.dict?`, `shen.dict-count`, `shen.<-dict`, `shen.dict->`, `shen.dict-rm`, `shen.dict-fold` | Chez hashtables | C dictionaries, with the kernel's tag at index 0, so the kernel's `shen.dict?` still works | Done |
| `shen.dict-keys`, `shen.dict-values` | native | the kernel's, over the port's `shen.dict-fold` | Fine as is |
| `vector` | native | the port's: `absvector` already fills with `(fail)` | Done |
| `@p` | native | `shen-jit.absvector3`, inline | Done |
| `variable?`, `symbol?` | native name analysis | C, by the kernel's rules for names | Done |
| `shen.analyse-symbol?` | native | the kernel's | Not needed: its only caller is `symbol?` |
| `shen.pvar?` | native | `shen-jit.pvar?`, inline: a mask and a compare | Done |
| `integer?` | Chez `integer?` | a primitive, inline for fixnums | Done |
| `not`, `boolean?` | native | the kernel's, small enough to inline | Not needed |
| `shen.numbyte?`, `shen.byte->digit` | native | the kernel's `shen.digit?` and `shen.byte->digit`, small enough to inline | Not needed |
| `pr` | writes the string at once | the port's: the string's bytes copied to a buffer and written by one `shen-jit.write-bytes`, where the kernel's takes a `write-byte` and a `pos` under a handler for each byte | Done |
| `read-file-as-bytelist`, `read-file-as-string` | native | C (`shen-jit.read-file`) | Done |
| `char-stream?`, `read-unit-string`, `write-string` | no character streams | the same | Done |
| `input+` | `shen.input-h+` | the port's | Done |
| `shen.push-factorised-branch`, `shen.eval-factorised-branch` | its own factorised compilation | none | Not applicable: Shen/JIT factorises with the kernel's `shen.factor` |
| `unwind-types`, `toplevel-display-exception`, `show-exceptions?`, `interactive-error?` | error display with Chez conditions | the port's `shen.toplevel-display-exception` prints backtraces | Done where it applies |

`shen.prolog-vector` needed no override: the kernel's makes an absvector of `(prolog-memory N)` words per query, which the collector handles by skipping repeated pointers and keeping vectors of 32K words or more apart, uncopied.

## Overridden by Shen/JIT only

| Function | Why |
| --- | --- |
| `shen.lazyderef` | `shen-jit.deref`, inline along a chain of variables, of which nearly every one is a single step |
| `shen.lzy=`, `shen.lzy=!` | A unifier that keeps a trail of the variables it bound, with no closures, and no `=` on two lists in `shen.lzy=!`. `tests/prolog-unify.shen` checks them against the kernel's |
| `<-vector` | The kernel's body is over the inliner's limit of 15 nodes. Split into `<-vector` and `shen-jit.vector-element`, both inline, so a failing `<-address` happens in the caller, where a quiet handler catches it with a jump. Same checks, order and messages |
| `shen.misc?` | The reader asks it about every byte of a symbol that is not a lowercase letter; the kernel's is an `element?` over 19 codes. The same codes as ranges, with non-numbers false as before |
| `get` | Looks the dictionary up once, and builds no message under a handler that ignores it |
| `tuple?`, `vector?`, `shen.+vector?` | One inline test each, without the kernel's `trap-error`. `shen.+vector?` is split so that it inlines into vector patterns, a value that is not a vector failing without a call |
| `shen.+string?` | Behind string patterns: tests the type before comparing with `""`, where the kernel's compares first; the same answer for every value |
| `fn` | One lookup, and it makes lambda forms when first asked for them |
| `read-file` | Skips a `#!` line |
| `shen.str->bytes` | Copies the string into one byte buffer and reads it backwards to build the list, avoiding repeated copies of the remaining string in `read-from-string` |
| `shen.make-prolog-variable`, `shen.deref`, `shen.bindv`, `shen.unwind` | A variable is an immediate value holding its binding's offset, so these use `shen-jit.pvar` and `shen-jit.pvar-offset` |
| `shen.newpv` | One function of inline primitives where the kernel's calls `shen.ticket-number`, `shen.make-prolog-variable` and `shen.nextticket`, with the same stores in the same order. Every clause variable is made through it |
| `shen.<-out`, `shen.hds=?` | Small enough to inline into their callers across the kernel, 59 and 35 functions, and into user `defcc` code |
| `shen.<shortnatters>`, `shen.<whitespaces>`, `shen.<digits>`, `shen.<alphanums>` | Loops over a run of bytes, where the kernel's rules call a rule and build a parse result per byte. Same results, including where a comment ends at a tab |
| `append` | `shen-jit.append` copies the first list in C, in one pass straight into the free space, and keeps the copy by moving the heap pointer once the list proves proper; the empty list stays inline. Same error for a list that does not end in `[]` |
| `shen.update-lambdatable` | Reading a definition made its lambda form at once, one compilation per definition. The port stores a placeholder holding the arity, and `fn` makes the form when first asked, so most are never made. `shen.*gensym*` still moves by the arity, so later gensyms are as before. `shen.lambda-entry` still makes them at once; it is rare. Reading the property directly shows the placeholder ([semantics.md](semantics.md), section 11) |
| `shen-jit.eval-kl` | Returns anything but a list as itself, without lowering it: `load` evaluates what each `define` returns, `(fn F)`'s printer, which compiled a throwaway expression per definition |
| `shen.<atom>` | Tries the number rules only when the first byte is a digit, `-`, `+` or `.`, the only bytes any of them can start with |
| `shen.record-kl` | Puts a name without a `shen.source` property straight on `shen.*userdefs*`, instead of an `adjoin` over every definition |
| `shen.shendef->kldef-h`, `shen.record-and-evaluate` | Evaluate what `define` produced factorised, keeping `ps` as written |
| `shen.compute-integer`, `shen.compute-fraction-h`, `shen.compute-E` | Number reading as Shen/Scheme reads numbers: `8.0` reads as the integer 8, and literals beyond the fixnum range become the nearest real instead of overflowing ([semantics.md](semantics.md), section 3) |
| `shen.read-evaluate-print`, `shen-jit.repl-read` | Backtraces, and ending the process at end of input |
| `shen.x.launcher.main` | Exit status 1 after an error or an unknown argument |

## Candidates found by profiling

Neither is overridden, and each would need its own measurement before any change.

| Function | Where it shows | Assessment |
| --- | --- | --- |
| `shen.sysfunc?`, `shen.undefined-f?` | 60% of reading code in a package: each symbol is looked for in the shen package's 278 external symbols with `element?` | A dictionary of that list would need a way to tell that the list changed (`systemf` and `shen.record-external` replace it), which Shen/JIT does not expose. `element?` itself takes 1.1 ns per element, against 2.4 in Shen/Scheme, which reads these files 3.2 times slower |
| `element?` | 10% of n-queens | Already a loop in registers: nothing to gain from an override |

# Dependency analyser

A whole program over the [Datalog library](../../docs/datalog.md): it reads Shen and KL source files, works out what
calls what, and answers questions about it, shipped as one executable. Each `define` of a `.shen` file and each `defun`
of a `.kl` file defines a function; a symbol at the head of a form in its body, or named by `(function F)` or `(fn F)`,
is a call. Forms the language gives meaning to, such as `let` and `if`, are not calls, and a function no file defines
is external. Files are read as Shen reads them, so a macro in them is applied first.

Build it from the repository root:

```sh
build/shen-jit eval -q -l lib/native.shen -l lib/datalog.shen -l lib/ffi.shen -l lib/buffer.shen \
  -l lib/io.shen -l lib/io-file.shen -l example-apps/depends/main.shen \
  -e '(shen-jit.save-executable "depends" depends.main)'
```

From a release archive, run the same from the archive's root with `./shen-jit`.

## Questions

```sh
./depends --root main a.shen b.shen c.kl     # a report
./depends --reach run a.shen b.shen c.kl     # what run reaches
./depends --why main b.stop a.shen b.shen c.kl
./depends --root main --out results a.shen b.shen c.kl
```

The report gives the files, functions and calls, which files depend on which and which are in a cycle with others, the
recursive functions, the most called, and with `--root`, given once for each root, what is live from the roots, what
is dead, and how deep the calls go. Over the files in `fixture/`:

```text
3 files, 8 functions, 16 calls, 7 to 6 external functions
3 file dependencies, 2 files in cycles
  cycle: b.shen, c.kl
4 recursive functions
most called: b.step (2), b.stop (2), helper (2), c.alone (1), c.back (1)
from main: 6 live, 2 dead, 1 deepest at 3 calls
  dead: c.alone
  dead: unused
```

`--reach F` asks by demand, and computes only what bears on `F`. `--why F G` explains why `F` reaches `G`, call by
call, or says that it does not. `--out DIR` writes each relation to `DIR` as a tab-separated file, `dead.tsv` and the
rest.

## What it uses

The rules are in `main.shen`, as one `defdatalog`: a record for where a function is defined, `[at File Index]`, taken
apart to find its file; recursion for what reaches what and which files depend on which; an equivalence for the files
that are in one cycle; negation for what is dead and external; a count for the most called; and a relation of one tuple
a key, `min`, for the depth of each function from the roots, which needs no bound to end, though calls go round in
cycles. `datalog.solve` and `datalog.explain` answer the questions, and `--out` writes each relation's bytes, from
`datalog.relation->bytes`, with the [I/O library](../../docs/io.md), which a static build cannot use for files.

## Test

```sh
sh example-apps/depends/test.sh build/shen-jit .deps/kernel/klambda
```

It builds the executable, checks its answers over `fixture/`, written by hand, and checks that it finds every function
the kernel's KL defines. `make test-datalog` runs it.

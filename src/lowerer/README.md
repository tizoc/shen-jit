# Lowerer

The KLambda-to-instruction lowerer of [docs/bytecode.md](../../docs/bytecode.md), written in
Shen, and its stage 0 driver.

| File | Contents |
| --- | --- |
| `lower.shen` | Entry points, and what comes before normalization: type forms dropped, pattern-matching chains shared. |
| `inline.shen` | Inlining. |
| `normalise.shen` | The fixed names, and normalization. |
| `builders.shen` | Builders, each accumulating a code object. |
| `emit.shen` | Emission: tail positions, closure conversion, slots and windows. |
| `registers.shen` | Floats and fixnums in registers in typed code, and loops inlined into loops. |
| `stage0.shen` | Driver: lowers the kernel KLambda files and the port to `build/stage0/<file>.sbc`. |
| `tokl.shen` | Compiles the lowerer and the port's Shen sources to KLambda for stage 0. |
| `host.shen` | What the lowerer takes from Shen/JIT, defined for running under a host. |
| `check.shen` | Test code: reads the output back and checks it against the rules in `lib/native.shen`, checks normalization's output, unit cases. |

The lowerer is the first six, which the Makefile lists as `LOWERER` and joins, in that order,
into `build/port/lower.shen`. The tools read that one file: the kernel's reader finds the arities
of a file's definitions before it compiles its calls, so a call to a function that another of the
files defines is a direct call only when both are read together.

Each of the six is the namespace `shen-jit.lower`, which the pinned kernel's extension expands
as the tools read it, so a name written `emit` is `shen-jit.lower.emit`. Others call the lowerer
by those full names. The namespace qualifies every symbol that is not a system symbol of the host,
so its rules are about symbols:

- A symbol used as data, such as a node kind (`const`), an instruction (`float-move`) or a kind
  (`float`), goes in the file's `externals`, or it becomes `shen-jit.lower.const`.
- A lowerer name that is also data, or a system symbol of either host, keeps its full name:
  `shen-jit.lower.float`, beside the data `float`, and `shen-jit.lower.value`, as `value` is the
  kernel's. Shen/Scheme has more system symbols than Shen/JIT, as it carries the standard
  library: `index` and `insert` are among them, so `shen-jit.lower.index` keeps its name too, or
  the two hosts would make different files.
- `(use shen-jit)` keeps the primitives, such as `shen-jit.float`, as they are.

Entry points, with `Sealed` the list of names defined in the stage 0 input:

- `(shen-jit.lower.defun [defun F Params Body] Sealed)` returns `[defun F Code]`.
- `(shen-jit.lower.expression X Sealed)` returns a code object of arity 0,
  named `eval-kl`.
- `(shen-jit.lower.toplevel X Sealed)` picks one of the two.

## Running

`make stage0` builds the stage 0 output, `make check-lowerer` runs the checker
and `make test-kl` runs the lowerer inside Shen/JIT (see below). The host, `BOOTSTRAP`,
is the earlier release of Shen/JIT that `tools/ci-deps.sh` names, or Shen/Scheme, which
makes the same files. The steps, from the repository's root, once `make` has written
`build/tools/`:

```sh
HOST script src/lowerer/tokl.shen build/port/lower.kl build/port/lower.shen
HOST script src/lowerer/tokl.shen build/port/struct.kl src/port/struct.shen
HOST script src/lowerer/tokl.shen build/port/module.kl src/port/module.shen
HOST script src/lowerer/stage0.shen   # [KLAMBDA-DIR [OUT-DIR [FILE ...]]]
HOST script src/lowerer/check.shen    # [KLAMBDA-DIR [SBC-DIR]]
```

Stage 0 lowers the 22 kernel files other than stlib, which is built apart (`make stlib`),
then the port: `build/port/shen-jit.kl`, assembled from `src/port/shen-jit.kl`,
`src/port/struct.shen` and `src/port/module.shen`, the latter two compiled to KLambda by `tokl.shen`, and the lowerer itself,
also compiled by `tokl.shen`, so it can run inside Shen/JIT for
`eval-kl`. It reads KLambda with `read-from-string-unprocessed`,
because `read-file` macroexpands (it turns `(input+ X Y)` into a
`shen.input-h+` call), and the kernel's definitions are the raw forms. Besides
`<file>.sbc` it writes `<file>.forms`, the defuns exactly as read, which the
self-hosting check in `tests/test_kl.c` lowers inside Shen/JIT and compares
with the `.sbc` files. `host.shen` defines what the lowerer takes from Shen/JIT
when it runs under a host: `shen-jit.symbol?` where the host has none, and the
tables of sealed names and inline bodies that stage 0 and the checker fill from
the definitions they lower.

A host that is Shen/JIT has its own lowerer sealed in its image, so the tools load
the one being built under other names. The Makefile writes `build/tools/lower.shen`,
from `build/port/lower.shen`, and `build/tools/native.shen`, with `shen-jit.lower.` changed to `stage0.lower.`, and
calls to the primitives `shen-jit.sealed?` and `shen-jit.inline-body` changed to
`stage0.sealed?` and `stage0.inline-body`, which `host.shen` defines. In `build/tools/lower.shen`
the namespace becomes `stage0.lower`, and each file also uses `stage0`, so that those two calls
keep their names.

The tools load the pinned kernel's namespace extension under `stage0.namespaces` before the
lowerer, so a host reads the lowerer's namespaces, and the checker the migrated `native.shen`,
even when its own namespace extension predates exports and shadowing.

With FILE arguments, stage 0 lowers only those files from KLAMBDA-DIR (the
test programs use this), without the port.

The defaults are `.deps/kernel/klambda/` and `build/stage0/`. `check.shen`
ends with `0 failures` when everything holds; it re-lowers the kernel in
memory and compares it with the files, then checks every code object:

- slots are below FrameSize; writes never touch slots 0 and 1; every
  window has A above the parameters and A+1+N < FrameSize;
- constant, code and capture indices exist; each nested code is created by
  exactly one `closure`; top-level code has no captures;
- labels are defined once and jump targets exist; `prim` arities match;
  sealed calls name a stage 0 definition with that arity, open calls do not;
- `exception` appears exactly at handler labels;
- a forward dataflow: every slot read was written on all paths, where a call
  clobbers every slot from its window up (so nothing live sits in a window);
  handler stacks agree at joins and are empty at `return` and tail calls; a
  raise reaches the handler with the slots set at that point; all jumps go
  forward; no code falls off the end or is unreachable.

It also runs 17 unit cases with expected instruction lists, 14 malformed
inputs that must raise, and 16 broken code objects the checker must reject.

## Output syntax

One `(defun Name Code)` per line. Lists are parenthesized and separated by
single spaces; `()` is the empty list; `true` and `false` are the Booleans;
integers are decimal; floats contain `.` or `e` (shortest round-trip digits);
strings are in double quotes, with `\"`, `\\` and `\xHH` for every other byte
outside 32 to 126; any other token is a symbol. Symbols never start like a
number (a digit, or `-`, `+` or `.` followed by a digit) and contain no
space, parenthesis, quote or backslash; the printer raises an error
otherwise. The files are ASCII. Do not read them with the Shen reader: it
curries applications of known functions such as `code` and `return`.

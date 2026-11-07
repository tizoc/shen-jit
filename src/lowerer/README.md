# Lowerer

The KLambda-to-instruction lowerer of [docs/bytecode.md](../../docs/bytecode.md), written in
Shen, and its stage 0 driver.

| File | Lines | Contents |
| --- | --- | --- |
| `lower.shen` | 1184 | The lowerer: normalization, then emission (tail positions, closure conversion, slots and windows). |
| `stage0.shen` | 224 | Driver: lowers the kernel KLambda files and the port to `build/stage0/<file>.sbc`. |
| `tokl.shen` | 39 | Compiles `lower.shen` to KLambda for stage 0. |
| `host.shen` | 43 | What the lowerer takes from Shen/JIT, defined for running under a host. |
| `check.shen` | 402 | Test code: reads the output back and checks it against the rules in `lib/native.shen`, unit cases. |

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
HOST script src/lowerer/tokl.shen     # src/lowerer/lower.shen -> build/port/lower.kl
HOST script src/lowerer/stage0.shen   # [KLAMBDA-DIR [OUT-DIR [FILE ...]]]
HOST script src/lowerer/check.shen    # [KLAMBDA-DIR [SBC-DIR]]
```

Stage 0 lowers the 22 kernel files other than stlib, which is built apart (`make stlib`),
then the port: `src/port/shen-jit.kl` and the lowerer itself,
compiled to KLambda by `tokl.shen`, so it can run inside Shen/JIT for
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
the one being built under other names. The Makefile writes `build/tools/lower.shen`
and `build/tools/native.shen`, with `shen-jit.lower.` changed to `stage0.lower.`, and
calls to the primitives `shen-jit.sealed?` and `shen-jit.inline-body` changed to
`stage0.sealed?` and `stage0.inline-body`, which `host.shen` defines.

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
integers are decimal; reals contain `.` or `e` (shortest round-trip digits);
strings are in double quotes, with `\"`, `\\` and `\xHH` for every other byte
outside 32 to 126; any other token is a symbol. Symbols never start like a
number (a digit, or `-`, `+` or `.` followed by a digit) and contain no
space, parenthesis, quote or backslash; the printer raises an error
otherwise. The files are ASCII. Do not read them with the Shen reader: it
curries applications of known functions such as `code` and `return`.

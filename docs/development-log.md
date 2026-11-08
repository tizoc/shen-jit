# Development log

What was done or rejected, why, and the numbers, by topic, with dates inside. The question it must answer quickly is "did anyone try X?", so rejected ideas are here on purpose:
search for "Rejected" before proposing something again without new evidence. How things work now is in the other documents in this directory.

Every figure belongs to its date and machine, and later changes moved many of them, so none is a current claim. Some compare against an earlier prototype, or come from harnesses and data that are not published.
That is history, and those figures are not meant to be reproduced: `make bench` and `make bench-independent` are what a reader can run.

Terms used throughout:

- **M3 Max:** an Apple M3 Max MacBook Pro, macOS, arm64. **Ryzen VM:** a Hyper-V virtual machine with 4 cores of an AMD Ryzen 5 5600X, Ubuntu 20.04, gcc 9.4 and glibc 2.31, x86-64.
- **Campaign:** an earlier prototype's benchmark set, 156 timed rows recorded on 2026-10-27 on the M3 Max with Shen/Scheme 0.50 and that prototype: 122 canonical rows in one process, and 34 "other drivers" for calls, Prolog and applications, among them a compile pipeline and a bytecode VM ("realistic" rows).
- **A/B:** interleaved runs of a change against the build just before it. A bare ratio is new time over old time, so below 1 is faster.
- **Open** is the default, with only kernel functions sealed. **Sealed** is `--seal`, with user definitions sealed too.
- **Kernel suite:** the Shen kernel's own test suite, which mostly loads and typechecks code.
- **CACHE** is the saved register holding the last result. **Stage 0** and **stage 1** are the build's stages.

Topics: [the JIT](#the-jit-and-native-code-generation), [the collector](#the-collector-memory-the-guest-stack-and-images), [the lowerer and the port](#the-lowerer-the-bytecode-the-kernel-port-and-prolog),
[the runtime and platforms](#runtime-threads-platforms-and-usability), [the C FFI](#c-ffi), [benchmark results](#benchmark-results).

## The JIT and native code generation

Lowering rules, the collector and the kernel port have their own sections.

### Engine decisions

- **Whole-function baseline JIT on SLJIT, no interpreter** (2026-11-01, design). Every function compiles at first
  entry and `eval-kl` takes the same path. No mixed execution, since mixed calls are what limited the baseline
  tier of an earlier bytecode VM.
- **Left out of the design** (2026-11-01): tracing, LLVM or Cranelift, a C compiler at run time, on-stack
  replacement, speculative inlining, general deoptimisation, cross-block SSA, global register allocation. Lazy
  basic block versioning only if a workload shows repeated checks dominating. Copy-and-patch and an operation
  generator stay open only if a complete implementation proves simpler than SLJIT with handwritten emitters.
- **Canonical frame slots** (2026-11-01, design). They let the collector scan the stack with no root maps, so
  registers below only cache slots or are written back before anything that may collect.
- **Rejected: a register allocator** (2026-11-01, estimate). Matching the earlier prototype on every row was
  estimated to need one, outside the size goal. That prototype's registers rest on thousands of lines of CFG,
  liveness and root maps; its own trials rejected registers across calls (code grew 18.9%) and promoting every
  local (one loop 0.016 to 0.014 s, another 0.025 to 0.033 s). On 2026-11-04 the campaign read 0.70 of its time
  open (M3 Max).

### Calls

- **Convention gates** (2026-11-01, M3 Max, generated `fib`). Sealed call site 12 instructions, open 15, entry 6,
  return 3, within the design's limit of about 15 for a caller. Before any optimisation, against Shen/Scheme 0.52:
  `fib` 30 6 against 4.4 ms, `nrev` 166 against 72 ms.
- **Where the time was** (2026-11-01, M3 Max). A call cost 1.1-1.4 ns against 0.8-1.0 in Chez, while four chained
  additions cost 1.3 ns each against 0.44, each value going to its slot and back.
- **Tail-call arguments computed in place** (2026-11-01, M3 Max, campaign). An unchanged one costs nothing. Open
  0.93 to 0.85 times Shen/Scheme, sealed 0.89 to 0.77.
- **First argument in CACHE as well as its slot** (2026-11-02, M3 Max, A/B). The callee read back what the caller
  had just stored. List rebuild 11.3 to 5.9 ms (Shen/Scheme 5.3), `append` 11.1 to 6.2 ms (4.3), realistic
  pipelines and VMs 11-13% faster, canonical 0.984.
- **Dynamic calls with all their arguments at once** (2026-11-02, M3 Max). A lambda returning lambdas, lowered at
  run time, got a second entry taking all parameters: `lambda with many arguments` 14.9 to 2.5 ms (Shen/Scheme 6.5,
  earlier prototype 7.8). Image +6.8 KB; entries in stage 0 code would have cost 35 KB more.
- **Calls through `fn`** (M3 Max). Sealed F is a direct call (2026-11-01, campaign: 3.1 ms against 23.8 open). A
  cache per call site for open F was deferred, as `put` would have to invalidate it. An inline arity test replaced
  it (2026-11-03): `cross-unit-global-unary-ordinary` 18.1 to 2.7 ms (earlier prototype 1.7).
- **Leaf code skips the stack check** (2026-11-03, M3 Max, A/B). A frame of at most 64 words runs inside what its
  caller reserved; code calling only in tail position skips it too, unless compiled once the REPL catches Ctrl-C.
  With results only the next instruction reads left unstored: returning calls 0.80-0.92 of their time, canonical
  0.998 open, 0.962 sealed.
- **Rejected: calls and returns through `blr`/`ret`** (2026-11-03, M3 Max). A callee reached from one of two random
  sites cost the same as from one: 69 and 70 ns at 16 random branches, 188 and 188 at 64, as C with `bl` and `ret`
  (67 and 69, 168 and 168). Other CPUs may differ.
- **Rejected: entering past the arity check; open calls patched to jump straight to the callee** (2026-11-03, M3
  Max). A build with no arity check timed `fib` and call-heavy loops the same, and a call too large to inline costs
  1.5 ns open against 1.6 sealed. What sealing gains is inlining.
- **Rejected: a second argument in a register** (2026-11-03, M3 Max). An accumulator passed second took 1.89-2.03
  ns per call open against 1.80 as the first argument, and sealed 1.70 against 1.88. Entry loads of later arguments
  hold 2 of 3,262 samples of the realistic VM.

### Sealing and inlining

- **Sealing** (2026-11-01, decision). Kernel functions are always sealed for user code; user code only with
  `--seal`. Redefining a sealed name raises. A sealed call to an undefined name binds on first call, so no file
  grouping is needed. Programs that redefine their own functions cannot run sealed.
- **Inlining small sealed callees** (2026-11-01, M3 Max, campaign, with sealing). At most 15 nodes, depth 2. Open
  1.00 to 0.93 times Shen/Scheme, sealed 0.89; `realistic-call-heavy` 0.119 s open against 0.073 s sealed
  (Shen/Scheme 0.068). Preparation up to 1.7 times slower sealed.
- **Rejected: an inline limit of 40 nodes** (2026-11-01, M3 Max). Image 1.24 to 1.72 MB, kernel suite 0.40 to 0.47
  s. `<-vector`, at 18 nodes, was split to fit instead (2026-11-02: 6.7 to 2.1 ns under a quiet handler).
- **Slot sharing for `let` of a variable** (2026-11-01, M3 Max). Each inlined level added two dependent moves per
  argument: sealed `realistic-call-heavy` 0.29 s against 0.12 open, then 0.073 s with sharing.
- **Open self tail calls, three steps.**
  - 2026-11-02, M3 Max, A/B: compare the cell with the running closure before testing its tag. Control loops 0.80
    to 0.67 ns, canonical 0.966. **Rejected:** taking the compare's own branch back, which saved 0.1 ns in
    allocating loops (canonical 0.948) but made a loop whose `=` called C take 5.4-6.6 ns instead of 3.9 at most of
    24 code addresses.
  - 2026-11-03, M3 Max: no check on arm64. The loop jumps straight back, and a redefinition rewrites that branch to
    the call through the name. Control loop 0.63 to 0.52 ns. **Rejected:** SLJIT's rewritable jump, four moves and
    an indirect branch, slower than the check.
  - 2026-11-03, Ryzen VM, A/B: the same on x86-64, with open inlining's guards. Open 0.931, sealed 0.999,
    `realistic-call-heavy` 0.45.
- **Open code inlines small callees** (2026-11-03, M3 Max, A/B). Behind a nop that a redefinition patches into a
  branch to the call. A small call 1.4 to 0.76 ns, a mutual tail call 1.05 to 0.54 ns, as sealed;
  `realistic-call-heavy` 0.48, other drivers 0.845. Bodies that make closures inline too: `closure allocation` 3.1
  to 2.1 ns (Shen/Scheme 2.39, earlier prototype 2.49).

### Registers and caching

- **Last result in a register** (2026-11-01, M3 Max, campaign). Results are still stored. Open 0.79 to 0.77 times
  Shen/Scheme; the realistic VM 1.63 to 1.27 open and 1.25 to 1.03 sealed; four chained additions 2.8 times faster.
- **Heap pointer in a register** (2026-11-01, M3 Max). Each `cons` waited on the one before through memory.
  `reverse` 7.0 to 4.6 ms (2.70 to 1.79 times Shen/Scheme).
- **Known pairs** (2026-11-01, M3 Max). A bit per slot, set where `cons?` falls through, so `hd` and `tl` skip the
  tag check. List patterns 7-20% faster. Kept across labels from 2026-11-02.
- **Loop registers, modelled first** (2026-11-02, M3 Max). Hand-written arm64, slots against registers: control
  loop 0.554 to 0.50 ns, `absvector-read` 1.07 to 1.05 ns, `reverse` 1.17 to 0.79 ns only with no frame stores in
  the loop. Counting loops gain 2-10%, not worth the 200-300 lines first estimated.
- **Loop registers, narrow version** (2026-11-02, M3 Max, A/B). Code looping through a self tail call, with no
  handlers and no calls but tail calls, keeps slots from 2 up in registers (frames up to 8 slots on arm64, 4 on
  x86-64), written back before C may collect or raise. About 70 lines. Canonical 0.981 open and 0.978 sealed, other
  drivers 0.991 and 0.973. Slower: `shen.sysfunc?` 11-15%.
- **What the model missed** (2026-11-02, M3 Max). `reverse` of 1,000 elements got slower run directly (1.6 to 1.8
  ns), though the same machine code ran at 0.82 ns in the model. A list surviving a copy was scattered: a scattered
  model list took 1.64 ns in registers and 1.63 in slots. The fix went in the collector.
- **Store-to-load layout** (2026-11-02, M3 Max). With values in slots, the control loop takes 0.55, 0.67 or 1.48 ns
  depending only on where a parameter's load sits after its store. Loops in registers do not vary.
- **Rejected: fewer instructions in `reverse`** (2026-11-02, M3 Max). Operands straight from CACHE (4 fewer) and
  `cons` moving the heap pointer first (2 fewer) read 1.001 and 1.013 overall. Keeping the next call's value in
  CACHE instead of the last result made `reverse` 12% slower.
- **Rejected: `(tl X)` computed after `(cons (hd X) Acc)`** (2026-11-08, M3 Max). In a self tail call
  `(rev (tl X) (cons (hd X) Acc))`, `tl X` goes to a temporary and is moved into X's slot after the `cons`, which
  still reads X. Computed last, it could go straight there, legal where X is known to be a pair. Modelled first
  with `lib/native.shen`, the lowerer's own code for a 1,000-element reverse against the same code with `tl` last and
  no move, 200,000 runs, three alternating rounds: 4.13-4.14 to 3.93-3.94 G instructions, but 0.97-0.99 to
  1.04-1.07 G cycles, 0.23 to 0.25 s. Taken early, the load of the next cell overlaps the `cons`; taken last, it
  delays the next round's tests. The JIT's order is the better one, so the lowerer was not changed. Other CPUs may
  differ, and a loop whose arguments make a call between them was not measured.
- **Dead stores in pattern tests** (2026-11-02, M3 Max). A general "dead after one read" was deferred on
  2026-11-01: slow paths would have to store first, and the collector would not see the value. The narrow form
  skips a store only before a fused test with no slow path after which the slot dies. A/B: list pattern rows 38-46%
  faster, canonical 0.99 open and 0.984 sealed.
- **List walking** (2026-11-03, M3 Max, A/B). In register loops, moves, constants, `hd` and `tl` write straight to
  the slot's register, and `cons` tags into its destination. `reverse` of 32 items 33.0 to 25.2 ns (Shen/Scheme
  25.9, earlier prototype 29.3); canonical 0.97 open, 0.973 sealed.
- **Rejected: registers for all tail-calling code** (2026-11-03, M3 Max). Five eval cases failed, and the 12-clause
  list pattern took 1.25 times as long, as such code keeps nothing in CACHE.
- **Rejected: spare registers as copies of slots read** (2026-11-03, M3 Max, A/B). About 70 lines of state. A
  nested pattern's late mismatch 0.92-0.99, 12-clause pattern 1.00, canonical 1.007 open and 0.996 sealed.
- **Rejected: new closures and `symbol-kind` results in CACHE** (2026-11-03, M3 Max). Closure creation 3.0 against
  3.0 ns, `variable?` 1.04 against 1.05 ns.
- **Loop registers past fused tests' slots** (2026-11-03, Ryzen VM, A/B). A top slot holding only a fused test's
  unstored result no longer counts. x86-64 has two loop registers and the control loops were one over: 0.67 of
  their time (0.065 to 0.043 s), canonical 0.984.
- **Type tests leave the value in CACHE** (2026-11-03, A/B). Five lines. Ryzen VM 0.98, `nested list pattern
  (matching)` 0.56 (12.6 to 7.1 ms, Shen/Scheme 0.52 there 8.0); M3 Max 0.993, the same row 0.93.
- **Rejected: `hd` and `tl` loading straight into CACHE** (2026-11-04). No gain on the Ryzen VM, and on the M3 Max
  patterns of 16 and 24 elements took 1.2 and 1.5 times as long.
- **List walks are not bound by dependent loads** (2026-11-04). Corrects an earlier conclusion: walking a pattern
  takes 0.20 ns per element on the Ryzen VM and 0.14 on the M3 Max up to 12 elements, about one cycle.
- **Four loop registers on x86-64 outside Windows** (2026-11-05, Ryzen VM, in alternation with the build before, best of 3 to 5). `r11` and `r10`, which only
  code written by hand used, hold slots too, as Windows already had four, and wait in the frame around a call to C that keeps them live. About 15 lines net. Kernel rows 0.940, from 0.402 to 0.377
  of Shen/Scheme 0.53, others 0.930. `reverse (32 items)` 0.77, level with Shen/Scheme, `list traversal` 0.74, `list membership` 0.67 to 0.71, many literal and type tests 0.75, `compile pipeline` 0.978,
  `bytecode VM` 1.00, as `exec` makes real calls. Workloads never used for tuning 0.94 to 1.00. The slower rows checked were placement. Alone, with the code shifted by 0 to 8 definitions: `match list (single
  clause, not matching)` 1.00 (1.33 in the suite), `allocating recursive call` 0.93 to 0.96 (1.06), `recursive list rebuild` 0.92 to 1.13 (1.10), and `reverse` 0.74 to 0.76. `literal float equality (false)`, 1.24, was not timed alone.
- **Rejected: registers for only some of a loop's slots** (2026-11-05, Ryzen VM, one binary switching policy, in alternation, against all or nothing, best of 3 to 5). Of the kernel suite's 30 loops that call nothing, 18 miss the four registers,
  13 of them by one slot; of the benchmarks' 55, 18 miss. Any slot could take a register, about 50 lines. Slots used most, by count of instructions: kernel rows 1.000, others 1.002, `match list (single clause, matching)` 1.55, as such code keeps nothing in CACHE. The first
  slots: 1.011 and 1.010, `match list (multiple clauses, matching)` 2.02. Those used most, only in frames of up to 6 slots, to leave big patterns alone: 0.995 and 0.996, `bytecode VM` 0.95, its `env-lookup`, but `compile pipeline` 1.04. Up to 5 slots: 0.999 and 0.999, `bytecode VM` 1.00, `compile pipeline` 1.04. Workloads
  never used for tuning 0.97 to 1.00. No net gain for the code.
- **Slots are not slow on Zen 3** (2026-11-05, Ryzen VM, hand-written chains). A store and a reload of the same slot add nothing to
  a chain of additions at any base register, 0.216 ns a link with or without them, and about one cycle when the frame pointer
  moves between them, as across a call, 0.432 ns. So `rbx` as the frame pointer costs nothing against `rbp`.

- **Two more registers for results read again soon** (2026-11-06, Apple M3 Max and Ryzen 5 5600X VM, A/B against the build before, alternating). S4 and S5 hold slots read within 8 instructions, or what CACHE held when it changes, in code with no homes and no raw values; every slot is still written. Found chasing `--seal` on `bytecode VM`, where `exec` stores a part of a pattern and reloads it a few instructions on.
  - **Alone, 10^6 runs at depth 9, best of 7.** M3 open 0.551 to 0.535 s, sealed 0.587 to 0.535, so sealing no longer costs anything there; Ryzen open 0.863 to 0.777, sealed 0.838 to 0.755. A 10% gain on the Ryzen was not expected, as a slot's store and reload alone cost it nothing at any base register, and what gives it there is not known without counters.
  - **Suite.** M3, 3 rounds at 10 times the run counts: open 0.99 over 85 rows, VM 0.96, pipeline 1.00, no group slower; sealed 1.00, VM 0.91. Ryzen, 2 rounds: 1.00 over 87 rows, VM 0.90, pipeline 0.98, control flow 1.02, patterns 1.03. Results match on every row.
  - **Independent.** M3 0.95 to 1.01, the kernel suite 1.00 and THORN 0.98 to 1.00; Ryzen 0.97 to 1.00. No compile-time cost shows.
  - **Slower rows, on the Ryzen.** `match list (single clause, not matching)` 1.33 is placement: its hot path is the same instructions, and with the code moved by nops that run only on entry it reads 64.8 or 86.4 ms by offset, 64.8 before. `shen.<-dict` with a missing key 12.5 to about 13.4 ms, 12.7 to 13.9 by offset, may be a small real cost on a path that raises.
  - **Two bugs on the way, which the eval cases caught at once.** A result loaded through a kept register that CACHE was about to move into, and a call's result moving CACHE, which by then is the callee's. Passed after: fast tier, `make test-differential` also under `SHEN_JIT_GC_STRESS=1000`, the stress suites, `make test-x86`.

- **Kept registers across labels** (2026-11-06, Apple M3 Max and Ryzen 5 5600X VM, A/B against the commit before, alternating). A label keeps what all the ways into it agree on, as CACHE does, instead of dropping them.
  - **Alone.** `bytecode VM` depth 9: M3 open 0.536 to 0.516 s, sealed 0.532 to 0.494, so sealed now leads open as it should; Ryzen open 0.777 to 0.739, sealed 0.766 to 0.722. `compile pipeline` depth 7, M3: open 0.1307 to 0.1293, sealed 0.1288 to 0.1256.
  - **Suite.** M3, 3 rounds: 1.00 open and sealed, VM 0.98 and 0.95, pipeline 1.00, results the same. Ryzen, 2 rounds: 0.99, VM 0.96, pipeline 0.96. Independent: M3 0.93 to 1.02, the kernel suite 1.00; Ryzen 0.96 to 1.02, the kernel suite 1.00, THORN 1.01 to 1.02.
  - **Rejected: reading past labels and jumps too, when deciding what to keep.** More to choose from, but no better alone (VM sealed 0.500 against 0.494, pipeline sealed 0.1273 against 0.1256), and in the suite on the M3 `compile pipeline` read 1.04 open and 1.06 sealed, which alone it did not.
  - **Against Shen/Scheme 0.54, normal mode, after this.** Ryzen: `bytecode VM` 0.91, from 1.05 before these two changes, and `compile pipeline` 1.05. M3, before this one: `bytecode VM` 0.88 and `compile pipeline` 1.06.

### Branch shapes and code placement

- **Comparisons fused with branches** (2026-11-01, M3 Max). With other changes, `fib` 30 6.0 to 5.2 ms. Fused only
  where the slot is written before read on both paths, as 2 of the kernel's 2,643 pairs reuse the result.
- **Aligned loop heads** (2026-11-02, M3 Max). One instruction added on a cold path made `match list (single
  clause, not matching)` 24% slower. 16 bytes fixed that row, but a 32-item list walk still took 12 or 17 ms by
  what compiled before it, and canonical rows moved up to 40% between builds. Now loop heads take 32 bytes, and a
  body only when it loops, so calls run no padding, with one local patch to SLJIT. A/B: canonical 0.988.
- **Rejected: aligning the fill's paired stores** (2026-11-02, M3 Max). `vector create (big)` takes 22 or 30 ms by
  the heap pointer's parity, flipped by a file name five characters longer. The fix made other sizes up to 17%
  slower.
- **Rows that move with layout** (2026-11-02, M3 Max; 2026-11-03, Ryzen VM). `list traversal (32 items)`, `match
  vector` and `symbol? (true)` moved 15-40% between canonical runs of builds that do not touch them, and not at all
  alone. On the Ryzen VM, `literal integer equality (false)` and its identical float twin take 0.098 or 0.151 s.
- **Rejected: testing a shared clause test once before the chain** (2026-11-03, M3 Max). The 12-element pattern
  went from 22 compares to 12, and `match list (multiple clauses, matching)` stayed at 5.1 ns: the compares are
  predicted.
- **Exit tests out of line in loops** (2026-11-03, A/B). `=` with a constant whose true branch is only a return
  jumps to it from a stub, so a turn takes one jump instead of two. Ryzen VM 0.982 open and 0.975 sealed; M3 Max
  0.954 and 0.972. Slower: realistic pipelines 2-5%, whose short-list loops exit on their first test. **Rejected:**
  the same in all code, which also turned pattern clauses into jumps (pipelines 1.03-1.07).
- **`-falign-functions=32`** (2026-11-04, A/B, six rounds). An unrelated C edit moved `sj_equal` off a 32-byte
  boundary, and 32-item vector equality read 1.32 on the Ryzen VM. Ryzen VM 0.993 open and 0.990 sealed; M3 Max
  1.000 and 1.007. Not a general gain; kept for stability.
- **Rejected: a fact that a slot holds no object** (2026-11-04), to spare chains of fixnum compares the tag test.
  An unsound timing build: 0.40 to 0.24 ns per compare at 16 on the Ryzen VM, 0.25 to 0.22 on the M3 Max, and
  `match list` did not move. A correct version needs a lane for objects, and only 30 of 2,207 `=` tests have this
  shape.
- **Rejected: long NOPs in loop padding** (2026-11-05, Ryzen VM, best of 5, against the build before). A loop head's padding runs on
  entry, up to 31 one-byte NOPs. Filled with few long ones: kernel rows 0.998, others 0.998, `list membership (first item)` 0.74,
  `string get tail (short)` 0.87, the realistic programs within noise. A second patch to SLJIT for no gain on real programs.
- **Rejected: cells and constants below 2 GB on x86-64** (2026-11-05, Ryzen VM, best of 5, against the build before). With
  `MAP_32BIT`, SLJIT writes `cmp rax,[abs32]` where a 10-byte move and a load were, with no change in the JIT. Kernel rows 0.997,
  others 0.994, the realistic programs 1.00, workloads never used for tuning 0.94 to 1.03. `literal symbol equality` 0.88, but `literal
  float equality (false)` 1.50 and `match list (multiple clauses, not matching)` 1.33: such rows move by whole cycles either way.

### Constants and arithmetic

- **Constant operands** (2026-11-01, M3 Max, campaign). A literal is no longer copied to a slot and read back.
  Timed rows 12% faster on average, control loops 30-50%; 1.14 to 1.00 times Shen/Scheme.
- **Fixnum immediates** (2026-11-02, M3 Max, A/B). In `+`, `-`, `*`, comparisons, and constant indices below 4096
  in `<-address` and `address->`. About 50 lines. Canonical 0.977.
- **Mixed arithmetic before the dispatcher** (2026-11-02, M3 Max). Native code allocates the real and calls a
  helper that only computes. 4.9-5.3 to 2.8-3.1 ns (earlier prototype 1.96). **Not done:** inline floats, which
  would need floating-point registers in every prologue.

### Equality

- **Inline `=` by tag pair** (2026-11-01, M3 Max). `=` calling C was 54% of samples in the realistic benchmarks. A
  64-bit mask indexed by the two tags leaves only two pairs, two objects, or a fixnum and an object for C.
- **Structural `=`** (2026-11-01, M3 Max, campaign). Identical heads and same-header strings settle inline by
  words. `list equality (true)` 1.10 to 0.39 s, literal string equality 0.87 to 0.32 s, both 0.35 times
  Shen/Scheme.
- **`=` with a fixnum constant** (2026-11-02, 2026-11-03, M3 Max). Tests only the other value's tag, 4 instructions
  instead of 11. Objects other than reals are unequal before C, and a value result comes from the flags: failing
  1.61 to 1.34 to 1.08 ns (earlier prototype 1.08). **Rejected:** testing the header inline, which took the fixnum
  cases 0.75 to 1.00 and 0.88 to 1.25 ns.
- **`=` with a short constant string** (2026-11-03, M3 Max, A/B). Up to 32 bytes, against immediates. True 3.2 to
  1.05 ns (earlier prototype 1.64), canonical 0.971. **Rejected:** the same for constant reals, which helps only
  non-integral literals, as integral reals from 2^53 on equal more than one fixnum.
- **`=` on two variables** (2026-11-03, M3 Max). A fused test settles two values with tag bit 0 clear (fixnums,
  specials, symbols) with one test. **Rejected:** that test in every `=`, where differing took an extra jump
  (membership 1.06-1.10 times as slow).
- **Integers against reals, exactly** (2026-11-05, Apple M5, load about 25, against the build before). `=` and the
  comparisons turned the fixnum into a double, so from 2^53 up `=` was not transitive: `(= 2^53+1 r)` held for the real
  2^53, unification of `[X X X]` with `[2^53 r 2^53+1]` depended on the order, and keys that were `=` hashed apart. Now
  the real is truncated and the integers compared, in C, and the inline comparison of a real with a fixnum leaves for
  that when the fixnum is past 2^53. `(< fixnum real)` in a loop 0.18 s to about 0.20 s per 10^8 in the runs it moved, in
  noise; only a real with a fixnum takes the new test. THORN's steamroller, thm13 and rcc10: 3.69, 27.9 and 20.4 G
  instructions before and after, and the same inferences.
- **A fixnum constant loaded as a double** (2026-11-06, Apple M3 Max, load 3 to 5, best of 7, 2x10^8 iterations, against
  the build before the entry above and the one after it). That test was not noise with a fixnum in a variable: 0.337 to
  0.386 s, 1.16 times the cycles. With a constant it cost 1.12 times the instructions and no cycles. Reals meet constants
  often, as `4.0` reads as 4, so a constant a double holds exactly is now loaded as one, with no tests: `(> X 4.0)` 0.369 to 0.312 s,
  a boxed Mandelbrot of 1000 by 200 0.506 to 0.498 s and 14.57 to 13.85 G instructions, and `bench-numeric`'s boxed programs 4.34 to
  4.28 G cycles, where they took 4.23 before the entry above. The variable case keeps its cost. Independent workloads:
  the same. **Rejected:** only leaving out the range test for such a constant, which saved the instructions and no cycles.
  On x86-64 (a Ryzen 5 5600X VM, gcc 9.4, idle, best of 11, wall time): `(> X 4.0)` 0.475 to 0.346 s, the Mandelbrot 0.642 to
  0.617 s, the variable case 0.362 to 0.421 s from that test, and `bench-numeric`'s boxed programs and independent workloads
  the same. The variable case also read 0.421 to 0.448 s with this change, which leaves its code alone: with up to 5 more constant
  additions ahead of it in the function, which move its slow path, this change's ratio ran from 0.87 to 1.06, so that is where the code lies.
- **`=` on deep terms** (2026-11-05, Apple M5, load about 20, against the build before). `=` recursed on heads and
  elements, so a 300000-deep term overflowed the C stack past `trap-error`. It cannot raise, so past 256 levels of
  recursion it continues in `equal_deep`, with a list of its own on the heap. **Rejected:** deferring through one such list
  from the first level, 0.19 to 0.30 s on 20-element lists of 3-element lists, and a depth passed as an argument, 0.24 s.
  The depth in a static, as threads take turns: 3.87 to 4.55 G instructions on those lists, about 6 per recursion;
  kernel suite 3.17 G within 0.3%, THORN's thm13, rcc10 and yql within 0.5%, the same inferences. A cycle overflowed the C stack
  before, and still ends the process, now by a message once the list would pass 2 GiB, which its doubling reaches at about 1.1 GB, or past 2^31 steps (a self-containing absvector of 2 elements about 1 s and 1.1 GB, of 1 about
  12 s). Shen/Scheme runs on and grows. Testing values before queuing them, as `sj_equal` does (2026-11-06, Apple M3 Max): a term nested
  5M levels through its heads left a tail waiting at each level, 238 to 302 MB of maximum resident memory, and now takes 157 MB, about the terms alone.
- **`=` against the stack limit** (2026-11-06, 10^7 compares of 20-element lists of 3-element lists, best of 9 to 11: Apple M3 Max,
  clang, load 3 to 5; a Ryzen 5 5600X VM, idle, gcc 9.4 and clang). **Rejected:** comparing the frame address with `c_stack_limit` in
  place of the depth, through a static pointer as `=` has no vm. It is no simpler, and its time against the depth's has no direction: 1.01 on the M3, and on the Ryzen 0.99 with gcc,
  0.83 with gcc aligning functions to 64 and 1.11 with clang. A first reading promised 0.83 with gcc too, on a build of the same comparison code that read 1.009 s where this
  one reads 1.201 s, so on x86-64 this row says little below 20%. What the depth itself costs is as unclear, from before `equal_deep` to after it: 1.19 to 0.86 s
  on the M3, with 1.12 times the instructions, and on the Ryzen 1.05 to 1.22 s with gcc, 1.13 to 1.20 s at 64 and 0.91 to 0.95 s with clang. Independent workloads did not move on either.

### Allocation, lists, vectors and strings

- **Inline fast paths** (2026-11-01, M3 Max, against Shen/Scheme 0.52). Type tests, `<-address`, `*`, `absvector`,
  closures and handlers, with the `=` work and label lowering: overall 2.38 to 1.35 times Shen/Scheme.
- **Allocation primitives** (M3 Max). `@p` as one allocation (2026-11-01): `tuple create` 51 to 20 ms. `absvector`
  filling two words at a time (2026-11-02): 10^7 objects of 100 elements 0.32 to 0.19 s. A run of `cons` checking
  the heap once (2026-11-03): `[a b c d e f | X]` 5.6 to 5.1 ns, with the leaf change.
- **Constant-length `absvector`** (2026-11-02, M3 Max, A/B). Up to 15 elements, no loop, no length tests.
  `absvector create (small)` 2.25 to 1.5 ns open (earlier prototype 0.91), canonical 0.981. **Rejected:** dropping
  its fill value's test (2026-11-03), 1.41 against 1.43 ns.
- **Strings** (M3 Max). `tlstr` inline (2026-11-01): `string get tail` 0.75 to 0.23 s. `cn` inline (2026-11-02):
  prepending a character 10.2 to 4.3 ns; its copy in whole words (2026-11-03): 4.8 to 2.9 ns (earlier prototype
  4.1). **Rejected:** unaligned stores for the second string, 1.43 times as slow when the first's length is not a
  multiple of 8.
- **Rejected: `reverse` in C** (2026-11-03, M3 Max). 32 against 37 ns for 32 elements, but 3.3 against 2.4 for one
  and 320 against 233 for 256. `append` in C did pay (2026-11-02): 32 elements 61 to 32 ns.
- **Not done: touching the heap at startup** (2026-11-03, M3 Max). `absvector create (small)` takes 1.35 ns in the
  campaign and 0.92 alone, as the first row to fault in the semispaces, about 4 ms. Every process would pay that
  and 32 MB resident.
- **x86-64 allocation is bound by memory** (2026-11-03, Ryzen VM). `tuple create` 2.2 ns for 32 bytes and a `cons`
  1.1 for 16, about 14 GB/s against about 28 on the M3 Max. The cause, and what lifted it, are under "One allocation area".
- **Rejected: prefetching ahead of the heap pointer** (2026-11-05, Ryzen VM, a model in C of bump allocation over 32 MB twice). `prefetcht0`
  or `prefetchw` at +2048 bytes: 32 bytes 1.79 to 1.50 ns, 16 bytes 1.04 to 0.93, at nearer distances less, for one more instruction at each
  allocation. One area does better with none.
- **Rejected: clearing chunks ahead of the heap pointer** (2026-11-05, the same model). `memset` or `rep stosq` over 4 KB to 1 MB: 32 bytes
  1.79 to 2.24 ns at best, as the lines are still read. `clzero`, which would not read them, is hidden in the VM.

### Errors and handlers

- **Lazy messages, quiet handlers** (2026-11-01, M3 Max). C errors build their message on request: from `value` 67
  to 11 ms. A handler ignoring its error gets no exception: `<-address` 10.4 to 5.5 ms.
- **`value` and `set` inline; errors as jumps** (2026-11-02, M3 Max, A/B). Under a quiet handler in the same code,
  failing `hd`, `tl`, `<-address`, `address->`, `value` and `set` jump to it. `value` under `trap-error` 6.1 to 1.8
  ns, failing `<-address` 5.5 to 1.85 ns, canonical 0.95 open and 0.946 sealed.
- **No handler stack at all** (2026-11-02, M3 Max, A/B). When only those jumps can reach the handler. `<-address`
  1.87 to 1.37 ns (earlier prototype 1.21), canonical 0.993.

### Compile time and code memory

- **SLJIT without debug checks** (2026-11-02, M3 Max). Runtime 307 to 225 KB, JIT compilation about 13% faster
  (9,000 lambda forms 34 to 30 ms).
- **Freeing dead native code** (2026-11-02, M3 Max). A weak list frees the code of uncopied objects after a
  collection: 20,000 definitions through `eval` free 40,003 of 40,206 code objects, peak 122 to 114 MB, time
  unchanged. The profiler's 23% for SLJIT's allocator was its bias toward returns from the kernel: all compilation
  took 23 ms of 645. **Rejected:** bigger allocator chunks (1 MB), no change.
- **Compile-time cost of open inlining** (2026-11-03, M3 Max). Re-evaluating eight realistic definitions: 253 to
  310 µs a round, 269 without open inlining, 308 at depth 1, so most of it is the inlined code. Workloads outside
  the benchmarks lost 3 to 5%: open inlining 1%, the rest most likely backtrace bookkeeping.
- **A long literal list's constants** (2026-11-06, Apple M5, load 5 to 10, instructions retired, one run each, against the build before). A list past the 64 nodes that make one constant takes a slot per element, and adding each took a search that called `str` on both numbers of every pair, a `length` and an `append`. The search now tests `=` before `str`, and the pool is kept reversed with a count. `(length [0 1 2 ...])` by script, numbers: 1000 elements 0.93 to 0.14 G, 2000 3.75 to 0.39 G, 4000 15.35 to 1.34 G, 8000 62.72 to 5.11 G. Symbols, which never called `str`: 8000 7.97 to 6.72 G. Lowering the standard library, 3 runs each: 1.15-1.17 to 1.12-1.15 G. Only the lowerer's own generated files changed, so its output for the rest of the kernel, the bench programs and the ops tests is the same. Two NaN objects no longer share a slot, as `=` is false for them. **Rejected: `=` before everything,** in the search: 8000 numbers 5.11 to 4.03 G and symbols 6.72 to 4.02 G, but it would compare a closure or an absvector passed to `eval-kl` by structure, where nothing compares them now. **Still quadratic, not fixed here:** with `consumed_next` not calling `dead_after`, which allocates and clears a byte per bytecode word and scans for each cons of a run, 8000 numbers read 2.35 G and 16000 8.97 G, against 5.11 and 19.98. An index over the pool is not tried.
- **A cons chain with constant heads in one slot** (2026-11-06, Apple M5, load about 27, instructions retired, against the build before). Each cons of a run took a new slot, and `consumed_next` then walked the rest of the code for each, to prove the slot before it dead. The walk is the cost, not the byte per bytecode word it clears: reusing that array made no difference. A cons whose head is a constant, computed into a slot that is not a parameter's, now computes its tail in the same slot, which the next cons overwrites, so nothing needs proving. Long literals by script, one run each: 4000 numbers 1.34 to 0.67 G, 8000 5.07 to 2.38 G, 16000 19.96 to 9.09 G, 8000 symbols 6.64 to 3.98 G. What is left grows about 3.8 times per doubling, not profiled. A run with variable heads still walks: 4000 elements 0.83 G before and after. Kernel frames: 21,545 to 20,996 slots in all, and `shen.initialise-environment` 355 to 19; the largest is now 57. 3 rounds each: a 1000-element literal rebuilt 200,000 times 1.60 to 1.56 G, kernel suite 3.113-3.117 to 3.096-3.115 G, standard library lowering 1.12-1.15 to 1.11-1.14 G. proof-bench, same inference counts, steam 3.52-3.56 to 3.54-3.56 G, yql 4.48-4.49 to 4.45-4.46, thm13 25.70-25.91 to 25.75-25.94, rcc10 19.10-19.16 to 18.98-19.15. `make bench`'s suite read 1.03 overall and the independent workloads 0.74 to 1.22, but the suite's own control loops moved 1.01 to 1.23 under that load, so these say little. **Rejected: guarding on the top slot,** `D = Top - 1`, from a first version. It passed the kernel's check, but a chain in the last parameter wrote that slot and read it again, against what `docs/bytecode.md` guarantees, and the kernel has no such case. Leaving parameters out makes the top-slot test unnecessary. **Rejected: not walking in code past 4096 words,** sound and about as fast on these literals, as it cost every cons run in large functions a store, about one instruction a cons, including a kernel function of 4737 words.
- **An index over a code object's constants** (2026-11-06, Apple M5, load about 40, instructions retired, one run each, against the build before). Adding a constant still searched every constant before it, and the loader took each from the list by `nth`. Each builder now keeps a dictionary from a key to the constant's slot: a symbol, string or Boolean is its own key, a number `[n S]` with S what it prints, so 8 and 8.0 and 0.0 and -0.0 differ, and a list `[l ...]` of its elements' keys. A NaN and a value with no literal syntax get no key, so are never shared, as before. The loader walks the list once. It is `shen.dict`, portable to Shen/Scheme as a host; native `shen-jit.dict-find` is not. Against main with `dead_after`'s scan gone (#11), `(length [0 1 2 ...])` by script, numbers: 8000 elements 2.39 to 0.25 G, 16000 8.98 to 0.47 G, 32000 35.17 to 1.02 G; 8000 symbols 3.92 to 0.23 G; 8000 mixed 2.55 to 1.62 G; lowering the standard library, 3 runs each, 1.14 to 1.04 G. Against the build before #11, where that scan still dominated, 32000 numbers went 79.09 to 44.46 G. Only the lowerer's own generated files changed. The standard library's executable came out 64 KB bigger, but the same with the same semispace size: the symbols' cell array keeps the holes of symbols freed below the last one in use, and which those are depends on when collections fall.

- **Liveness buffers per compilation** (2026-11-07, Apple M3 Max, against the build before,
  five interleaved rounds). Reported by @pyrex41 in #17. Each `dead_after` walk allocated a visited-byte
  array and a work stack for the whole code object. They now belong to the compilation, with the visited
  bytes cleared before each walk, and are freed together at the end. Allocation failure keeps the store.
  Instructions retired: startup 31.94 to 30.93 M, kernel suite 3.121 to 3.094 G, stlib build 1.005 to 1.000 G.
  Two interleaved rounds of the benchmark suite gave the same 98 results and a time ratio of 0.977 over
  its 66 timed rows. The independent kernel, extension, contract and THORN workloads read 0.94 to 1.01
  of the earlier times; startup, about 4 ms, read 0.82.
  **Rejected: last-read pruning and generation marks.** On the same real workloads, the full #17 analysis
  added no benefit over buffer reuse, and generation marks matched clearing the bytes. A separate trial
  with a 4096-step work limit and no visited array made the kernel suite about 7.5% worse.
- **Long definitions in linear time** (2026-11-07, Apple M5, load 25 to 45, instructions retired, the table against the build before the constants' index; for the lowerer alone, main's lowerer and this one loaded into the same host). Five costs grew with the square of a definition's size. Fixing them: `mark` took the `length` of all instructions before and after each inlined call, and the builder now counts them. `add-code` appended each closure's code to the list, and now pushes it and keeps a count. In a named tail call, the test of whether a later argument reads a parameter's slot built a `union` of the variables of all later arguments at every argument. It now walks them once and stops at the first, and only when some variable of the code is in that slot, which in a frozen continuation none is. That nesting is what a Prolog clause body makes. `prim-arity` and `fixed?` scanned the 132 fixed names on every named call, and now look in a `shen.dict`, made on first use. The loader's `build_code` took each nested code with `nth` from the start. Each script below evaluates each definition, reading and installing included, and the figure after "read" is reading alone:

  | Definition | Main | This build | Read |
  | --- | --- | --- | --- |
  | A list of 6,400 inlined calls | 11.01 G | 5.01 G | 0.43 G |
  | 4,000 nested inlined calls | 2.28 | 0.36 | 0.27 |
  | A 400-clause `defprolog` | 2.37 | 1.62 | 1.40 |
  | A Prolog clause with 400 goals | 1.15 | 0.25 | 0.25 |
  | 3,200 lambdas | 0.76 | 0.49 | 0.44 |
  | 6,400 lambdas | 1.95 | 0.80 | 0.65 |
  | 12,800 lambdas | 5.95 | 1.39 | 1.16 |

  What the 6,400 calls still cost there was the search of the constant pool, which the index above now removes. The loader alone, this build with main's `loader.c`: 12,800 lambdas 1.73 to 1.39 G, 6,400 0.87 to 0.80. With the index and the reused liveness buffers, and the fixed names in a `shen.dict`, three alternating runs each: kernel suite 3.106-3.174 to 2.951-2.961 G, building the standard library's executable 0.823-0.839 to 0.760-0.765 G. Before those two, three runs each: lowering the standard library 1.147-1.150 to 1.046-1.051 G, kernel suite 3.153-3.174 to 2.975-2.988 G. proof-bench, 3 runs, same inference counts: steam 3.57-3.59 to 3.47-3.62 G, yql 4.49-4.61 to 4.44-4.61, thm13 25.83-26.33 to 26.14-26.35, rcc10 19.18-19.27 to 18.87-19.12, which is noise either way. The lowered output is the same: the generated files changed only for the lowerer itself, and with `Sealed` empty, where inlined code is marked, 15 shapes and the standard library's 326 definitions lower the same under both lowerers. **Rejected: walking the later arguments without the slot test first.** The Prolog clause stayed at 0.69 G, as each level walks all the goals after it. **Rejected: arities in the property list,** as `get` raises on a miss and formats a message. A table of 64 buckets by `hash`, from a first version, was about 0.3% faster on the kernel suite than the `shen.dict`, but the dictionary is code the kernel already has. **Not fixed:** `capture-index` appends each captured variable and takes a `length`, quadratic in a closure's captures, which are few.

  **Taken back, the same day, as they move no real work** (Apple M3 Max, instructions retired, median of 7, load about 3, against the merge). `add-code`'s count, the loader's cursor, and the test of whether `Env` has a variable in the slot before walking. The kernel suite reads 1.002, the stlib build 1.001, THORN set 1.003 and L 1.001, a list of 2,000 goals in one Prolog clause and 4,000 inlined calls 1.000. 4,000 lambdas in one definition read 1.91, and stay quadratic: that case works, and a pathological one gets no code.

### Prolog and byte-buffer primitives

- **Inline `shen.lazyderef`** (2026-11-04, M3 Max). Variables are 1.00-1.04 steps from their value, so the cost was
  the call. `hamilton` 0.63, Einstein 0.76, kernel suite 0.96, executable 14 KB smaller. **Rejected:** fewer checks
  in it, through facts for slots known to hold absvectors (best of 15): `hamilton` 0.97, kernel suite 1.01, stlib
  install 1.02, for about 30 lines.
- **Byte buffers stay checked and in C** (2026-11-03, M3 Max). Checks cost 0.52 ns of a read: 1.36 ns against 0.84
  with none. No unchecked mode, or check per loop, until a real program shows the need. Written in Shen, only
  `bit-not`, `rotate32` and `bswap32` could move, freeing about 21 of 230 lines of C.

### Not tried yet

- **A bump-allocated code region, and a flag per cell for `redefine`'s scan** (2026-11-03, M3 Max). SLJIT's
  first-fit allocator held 28-36% of samples when re-evaluating definitions and the scan 8%, in a loop that
  redefines the same names. Either adds code without simplifying anything.
- **Rotating loops, with the exit test repeated at the back edge** (2026-11-03). Its backward jump must meet the
  body label's state, and in open loops it would pass by the patched jump. No estimate.
- **Stores of pattern parts used further on** (2026-11-03, M3 Max). What remains of the pattern rows (a nested late
  mismatch 5.5 ns, Shen/Scheme 4.0) was judged to need a register allocator.
- **First-argument clause indexing** (2026-11-04, M3 Max). Sound. `hamilton` 0.66 with `edge` split by hand;
  estimated 6% on `subset`, 4% on `queens-8`, under 1% on the kernel suite. A lookup in 1,000 clauses takes 2.784
  µs against 0.043 for SWI-Prolog with -O.

## The collector, memory, the guest stack and images

Cheney semispace copying with inline bump allocation and no write barrier; a guest stack scanned linearly with no root
maps; an image is the live heap after a collection, with relative pointers. Ratios are new time over old. "Kernel suite"
is the Shen kernel's own test suite, which mostly loads and typechecks code, and "`tak`" is Prolog `tak`.

### Design choices (2026-11-01)

- **Semispace copying.** The earlier prototype's generational collector had a `heap.c` of about 2,900 lines, with
  non-moving old spaces, remembered sets and root maps. The first collector and image code here took 439 lines.
- **Rejected: precise root maps and values in registers across calls.** They need root analysis in the compiler, the
  largest source of complexity in the earlier prototype, whose own trials rejected those registers (18.9% more code).
- **Rejected: a non-moving mark-sweep old space** (page types, free lists, an estimated 400–600 lines). Reconsider only
  if long-running programs with large live heaps become a real workload, or C needs stable addresses.
- **Pairs stay two words with no header.** Rejected: a header on every pair (half as much memory again per pair) and
  separate pair storage with its own scan cursor.

### What collections copy (2026-11-01, Apple M3 Max)

Gate: stop if collection stays under about 10%. Share of time and longest pause: kernel suite 13.4%, 2.2 ms; the suite
four times in one process 23.3%, 10.3 ms; `tak` 46.5%, 12.8 ms; realistic applications 2%, 0.4 ms. The image, assumed to
be the main cost, is 141K words (1.2 MB), while a suite run copies 77K–700K words per collection besides it. Over four
runs global cells grow from 4.4K to 145K, with about 72K interned symbols, mostly `gensym` names, and constant slots from
7.9K to 45K.

**`tak` is not evidence** (decided 2026-11-04). It needlessly allocates big vectors, which a kernel hook could improve,
and its time moves with where collections land: allocating 4% less took it from 0.130 to 0.165 s (2026-11-01, M3 Max).
Nothing in the runtime changes for it alone.

### Non-moving image region: built twice, dropped twice

- **2026-11-01, with a write barrier** (M3 Max, against the plain collector), about 100 lines. Every suite passed, under
  stress too. Kernel suite: 25% less copied, collection 46 to 44–45 ms, longest pause slightly up. Applications:
  collection about three times less, on 2% of their run. `tak`: no better. The tightest vector-write loop got 5–12%
  slower. Reverted.
- **2026-11-04, without a barrier,** scanning the whole image at each collection, about 80 changed lines, to see whether
  it made smaller semispaces pay. Ryzen 5 5600X virtual machine, against the code before at 32 MB, at 16 MB with and
  without it: kernel suite 1.06, 1.07; short lists 0.96, 1.01; deep recursion 0.95, 0.99; `tuple create` 0.74, 0.80. A
  collection on short lists at 4 MB took about 217 µs instead of 330, where a fifth was hoped for: reading 700 KB through
  cold caches is bound by memory as well. Reverted.

### Copying (2026-11-02, M3 Max, against the build before)

- **No `memcpy` per object,** about 10 lines. `memmove` was 61% of a run that spent 63.5% collecting. Kernel suite
  collection 0.052 to 0.039 s, longest pause 2.65 to 2.1 ms; `tak` 0.136 to 0.107 s.
- **List spines copied at once,** about 15 lines. Breadth-first copying scattered a surviving list's pairs among the live
  heap. `reverse` of such a list 1.67 to 0.90–1.11 ns per element at 1,000 elements, 1.85 to 1.15 at 10,000; the benchmark
  campaign 1.006 open and 0.997 sealed; `shen.sysfunc?` 14–22% faster.
- **Repeated pointers in a scan,** about 5 lines. `absvector` fills every slot with `shen.fail!`, and a Prolog query's
  vector holds a million. `tak`'s 26 collections 0.193 to 0.147 s.
- **Large objects apart,** about 170 lines. Vectors and strings of 32K words (256 KB) or more get their own block, marked
  and scanned in place. A dead block is kept until the next collection for an object of the same size, so a query does not
  touch 8 MB of new pages each time. `tak` collection 0.120 to 0.046 s and the run 0.247 to 0.179 s; short-lived pairs
  beside a live 2M-element vector 0.075 to 0.040 s. First try: leaving them out of the semispace sizing kept 32 MB, doubled
  the collections and lost the gain.

### Symbols and dead code (2026-11-02, M3 Max)

- **Weak intern table,** about 60 lines, after a 14-line lowerer fix that stopped a `gensym` per inlined argument. After four
  kernel-suite runs in one process, before, with the fix and with the table: symbols 86.4K, 61.1K, 16.5K; live heap 12.1, 9.3,
  6.7 MB; time collecting 22.8%, 19.2%, 15.7%; longest pause 10.2, 4.5, 3.2 ms. It keeps symbols with a value or function, or
  called by name from compiled code, which holds only a cell index.
- **Free cells leave the array that collections walk** (2026-11-05, M3 Max, load 2 to 3, against the build before). After 10M `gensym`s, 1,544 symbols were alive and the array had 511,952 cells, walked by every
  collection for the rest of the process: 150 to 1,400 us each, about 2.4 ns a cell, up to what one 32 MB cycle can make. Every cell in use has a symbol in the table, so those above the last one kept now leave it. 12 lines. Back to 150 us, and `gensym` itself no slower.
  A name made during a burst, before its collection, keeps the array that long while it lives: at 101,550 cells 430 to 510 us, against 1,400 to 1,500. Real workloads do not reach this: cells are 1.1 to 1.3 times live symbols on the kernel suite, extension tests, stlib install and
  realistic programs, and workloads never used for tuning read 0.92 to 1.01. So it removes a trap and gains nothing on them.
  - **A bug on the way:** `intern_name` took a cell and then allocated, and a collection there trimmed the array below a cell whose symbol was not yet in the table, so the next new symbol got the same one. `save-exe-stress` caught it. The cell is now taken after the allocation.
  - **Rejected: the lowest free cell first,** a bitmap in place of the list, about 30 lines. The same on every row tried, as a trim leaves few holes, and a name made during a burst keeps the array either way.
- **A bug this allows** (2026-11-04). `save-executable` interned a symbol and kept only its cell across more allocation. A
  collection freed both, and the saved binary ran as the launcher. It showed at stress 1 and 10, and at 1000 on a release
  build.
- **Constants of dead code,** about 110 lines. After four runs, 26.9K of 45.3K constant slots (59%) were dead code's, and kept
  5,027 code objects alive. A code object now owns its slots, and one pass after collection frees the unreached. Live heap
  6.67 to 5.62 MB, code objects 13.5K to 8.4K. Rejected: a weak list of code objects for that pass, as reading each header
  added 20–30 µs per collection.
- **Native code of dead code,** about 60 lines, through a weak list, at 7 µs per collection in the kernel suite. Defining
  20,000 functions through `eval` frees 40,003 of 40,206 code objects, peak memory 122 to 114 MB, time unchanged. The 23% a
  profiler gave the allocator was its bias toward returns from the kernel, and 1 MB chunks for SLJIT's allocator changed
  nothing.
- **What else grows, left as it is.** After four runs, `*property-vector*` reaches 4,043 KB from 70 KB, 75% of the live heap,
  almost all `shen.source`. Each `(datatype ...)` defines new `gensym`-named helpers, about 0.5 MB of source per run here. It
  is the kernel's behaviour in every port.

### Semispace size and growth

- **2026-11-01.** 32 MB each at the start, doubling when live data passes 40%, never shrinking. At `SHEN_JIT_MAX_HEAP`
  (2026-11-02) the last tenth is a reserve, so that raising a catchable "out of memory" has room.
- **The limit counts what the heap holds (2026-11-07, Apple M3 Max).** A large object was refused when twice the semispace, plus
  large objects, passed the limit. Semispaces never shrink, so once one had grown past half the limit every `(absvector 65539)`
  raised "out of memory", with the heap nearly empty. The override test met it at 256M, and a dropped list of 3 million
  does it. Large objects now compare what a collection kept, what was allocated since and the large objects with the limit less its
  reserve, and small allocations at the limit count live large objects too, which they did not, so together they
  stop at one limit. At 64M a program can now hold 113 vectors of 512 KB, where it held none after a large list. The cost is that memory is no
  longer capped by the old sum: that run peaked at 212 MB against 103 MB. Shrinking the semispaces was not tried, as a limit is a safety valve,
  and programs that do not set one take neither path.
- **A smaller default: rejected** (2026-11-04). Ryzen virtual machine, best of 3 to 7, at 32, 16, 8 and 4 MB: `tuple create`
  2.05, 1.63, 2.11, 3.64 ns; short lists 1.00, 1.01, 1.20, 1.72; kernel suite 1.00, 1.07, 1.14, 1.15. Each collection copies
  the kernel's data, about 330 µs. `SHEN_JIT_SEMISPACE` makes it a choice: on the M3 Max, `hamilton` at the same sizes takes
  62.8, 63.7, 66.3, 73.6 µs and peaks at 72, 37, 21, 12 MB, against SWI-Prolog's 8 MB.
- **Starting at 64 MB: rejected** (2026-11-04). Ryzen, then M3 Max: stlib install 0.83, 0.84; kernel suite 0.99, 0.97; short
  lists 1.02, 1.12; a long list kept 1.43, 1.52. Not measured since growth got cheaper.
- **Growing in place** (2026-11-04). Growing copied live data a second time into a new block. Both semispaces now lie in one
  reserved block, and growing commits more. Best of 15, against the code before, Ryzen then M3 Max: stlib install 0.86, 0.91,
  longest pause 25.7 to 12.3 and 18.4 to 10.2 ms; a long list kept 0.75, 0.78; non-tail recursion over it 0.80, 0.92; short
  lists 1.00, 1.00; kernel suite 1.03, 1.00. The 1.03 is unexplained, as that run never grows. Ruled out: code placement, the
  reservation's size, the heap's start alignment, the field's place in the VM struct, `PROT_NONE` against a writable mapping.
  Rejected on paper: swapping in a larger block at the next collection, no help when the space is full after the first copy.
- **Reservation size** (2026-11-04, macOS, M3 Max). Startup 2.74 ms before; 4.51 at 1 TiB each, 3.18 at 256 GiB, 2.85 at 64
  GiB, 2.78 at 16 GiB. Linux shows none. Kept 64 GiB.
- **Staggered spaces** (2026-11-04, Ryzen). A reservation apart, low address bits match and collections take longer: 0.033 s
  against 0.028 on short lists, 0.126 against 0.085 on recursion. Probably the L1 way predictor, not measured. 33 MiB and 64
  KiB more cures it. A shift of 4 KiB works there and is less than a whole page on the Mac.
- **Huge pages on Linux** (2026-11-04, Ryzen, against in-place growth), one `madvise`: a long list kept 0.76, stlib install
  0.93, kernel suite 0.98, short lists 0.99. A bare start takes 5 MB instead of 4.
- **First writes: not done.** The first row to touch the semispaces pays about 4 ms of page faults (2026-11-03, M3 Max), and
  Windows 10 about 13 ms against Linux's 3 on the same Ryzen (2026-11-04). Touching the heap at startup would put 32 MB
  resident in every process. A smaller start means more collections. Large pages on Windows need a privilege.
- **One allocation area** (2026-11-05, Ryzen VM at load about 0, in alternation with the build before, best of 2 to 4 rounds; M3 Max at load
  about 3, best of 3). Two semispaces taking turns write to 64 MB, past that machine's 32 MB L3. Modelled in C, 32 bytes took 1.79 ns at 32 MB
  each and 0.95 at 16 MB each, and 16 bytes 1.04 and 0.89, and each smaller semispace also means more collections. So new objects now always
  go in one area, and what a collection keeps goes back and forth between two spaces: the same collections, and half the memory written to. No
  barrier and no generations, and the copier does not change, as the area lies between the spaces and one range still holds what may move.
  About 35 lines net.
  - **Ryzen VM:** `vector create (big)` 0.62, `tuple create` 0.69, `dict create` 0.82, `absvector create (small)` 0.89, `reverse (32 items)` 0.94,
    `closure allocation` 0.97. All kernel rows 0.980, their data rows 0.942. `compile pipeline` 0.999, `bytecode VM` 1.004. Workloads never used
    for tuning: startup 0.99, kernel suite 1.00, extensions 0.98, stlib install 1.00, contract 0.96.
  - **Peak memory, Ryzen VM:** kernel suite 74 to 49 MB, 1.6 GB of short lists 69 to 37 MB. A bare start 3.7 to 5.4 MB, as the area takes a huge page.
  - **M3 Max:** kernel rows 1.000, others 0.999, `vector create (big)` 0.94.
  - **`list equality (late mismatch)` read 1.32 and later 0.84, which is placement.** Timed alone at shifted heap positions, both builds take 31 or
    43 ns by where the two lists land.
- **The heap's size follows what is live** (2026-11-05, Ryzen VM at load about 0, against the build before and Shen/Scheme 0.53, mean of 30 rounds of 640 MB; M3 Max at load 2 to 2.5). Doubling when live data
  passed 40% of a semispace made its cost a sawtooth, in ns per `cons` with pairs alive: 5.25 at 1.5M, 3.18 at 1.8M, 5.12 at 3M, 2.98 at 3.4M, 5.52 at 6.4M, 2.98 at 6.8M. With its own area the heap needs no steps, so a
  semispace is now five times what is live, and a collection copies at most a word per four allocated. About 10 lines net.
  - **Ryzen VM:** about 2.9 ns at every size from 1M to 20M. Peak memory is that of a tooth's top, and 1.4 to 1.7 times at its bad points: 3.4M 314 to 321 MB, 3M 196 to 284, 6.4M 360 to 597, 20M 1335 to 1841.
  - **M3 Max:** 1M 2.21 to 1.84 ns, 83 to 99 MB; 3M 3.26 to 1.84, 193 to 282 MB; 6.4M 3.52 to 1.93, 357 to 593 MB.
  - **Below the threshold nothing changes.** Workloads never used for tuning 0.95 to 1.01 on the VM and 0.90 to 1.00 on the M3, and peak memory on the kernel suite and stlib install within 3%.
  - **Rejected: doubling at 20%,** the one-constant change. 2.0 to 2.83 ns, as the teeth stay, at 1.7 to 1.8 times the memory at every size: 14M 1246 to 2268 MB.
  - **Rejected: following live data at 30%.** About today's memory for 3.1 to 4.7 ns (best of 12 rounds, with less room than a round where it matters).
  - **Not taken: more room.** Seven times what is live, 2.4 ns at about 1.3 times this memory, and ten times, 2.0 ns at about 1.8. It is the one number.
  - **A bigger heap has a floor.** At 3M alive, `SHEN_JIT_SEMISPACE` of 256M, 512M, 1G, 2G and 4G: 2.73, 1.90, 1.56, 1.45 and 1.46 ns, as past the L3 every write misses however rarely collections come.
  - **Chez stays ahead on live data.** Sealed 0.86 to 1.17 ns at 62 to 667 MB up to 20M, against 2.0 at best here at five times its memory. No growth policy closes that.
  - **A best of a few rounds misled here.** Once the room passes what a round allocates, it picks a round with no collection: rows read 1.34 to 1.5 ns, and a first reading had Shen/JIT passing Chez from 14M, where the mean is 3.09 against 1.12. Hence the means.

### The guest stack

- **2026-11-01, dirty mark.** Slots above the top are kept cleared for the linear scan, and clearing to the end of the stack
  meant 64 MB per collection after a 10⁶-deep recursion. Entry checks now compare against a mark above which all is clear, and
  collections clear only to it.
- **Rejected 2026-11-02: scanning only frames pushed since the last collection.** Every collection moves every object, so
  every slot needs updating. It needs a nursery whose older objects stay put.
- **2026-11-04, a missing reservation.** A nested call from C near the end of the stack wrote past its block, as leaves skip
  the stack check: one bus error in about 6,000 runs. Guard Malloc named the writer, and the CLI tests now sweep those
  alignments under it on macOS.

### GC stress and poisoning

- **2026-11-01.** Stress collects after every N words. At N=1 the kernel suite would take hours, so suites use 1,000. Loops
  under N=1 must stay short: two cases of 3,000,000 iterations took about 15 minutes, and 20,000 test the same path in 12 s
  (2026-11-03).
- **2026-11-03.** gcc on x86-64 evaluates arguments in another order than clang, which exposed two test programs reading a
  value before another argument's allocation moved it.
- **2026-11-04, old space poisoned under stress.** Before, a stale pointer read what was still there. The suites found no
  stale read beyond the one its first test was written to show: C roots shared by threads, which crashed 3 runs of 3 and pass
  3 of 3 per thread. Its limit: the semispaces take turns, so after an even number of collections a stale pointer is back
  inside the heap.
- **2026-11-05, one allocation area hid stale pointers, and passed.** Its first build passed all of GC stress, while the next allocation landed on the
  words just overwritten, so a stale pointer found a new object instead of failing. Noticed reading what this section promises, and a unit test now
  shows it. Under stress, new objects go past those words for as long as they fit, and those words no longer count as the heap. So a stale pointer to a
  young object now stays caught at any number of collections, until the area wraps. One to what a collection had kept still comes back every second one.
- **2026-11-05, scratch registers scrambled under stress.** With a loop's slots in scratch registers, a missing reload after C passed the suites, as `h_equal` need not touch `r10` or `r11`. So under stress they
  are overwritten after such a call. With the reload removed, an `=` case now fails under stress every time, and a `cn` case fails in a plain run here. The first cases proved nothing: large frames did not get those registers, and two equal literal lists are one
  constant, so `=` never reached C.

### Images and executables

- **2026-11-01.** An image loads only into the build that wrote it, and holds no native code: code compiles at first entry.
  First kernel image, Apple silicon: 1.26 MB, startup 3.4 ms against Shen/Scheme 0.52's 188 ms, resident memory 3.6 MB
  against 57.
- **Byte-identical round trip.** An image written from a loaded image must match it. This found 28 words from transient roots
  (2026-11-01), and made the weak table rebuild the same way from any layout of the same symbols (2026-11-02). Large objects
  are copied into the heap first, so the format stayed.
- **Size.** Dictionaries ignore the requested size, so the property vector has 256 buckets instead of 20,000: image 1.27 to
  1.12 MB (2026-11-01). Bytecode as variable-length integers: 699 to 181 KB, image 1.22 to 0.70 MB, live heap at startup 1.1
  to 0.6 MB, with startup and collections unchanged (2026-11-02, M3 Max). 16-bit operands, considered first, would have
  roughly halved it.
- **Executables.** A trailer gives an image's length, so one appended to the runtime is found from the end of the file
  (2026-11-02). `save-executable` (2026-11-03) is about 90 lines of C and gives 1.0 MB on macOS. It ends the process, as an
  image holds no frames, and writes beside the path and renames, so a binary can replace itself.

### What a future collector should know

- **Costs** (2026-11-04, M3 Max). A root pass is about 0.7 ns per word, 7 µs with the kernel loaded and 25 µs during the
  kernel suite. A copied word is 2–4 ns. Live kernel data is about 660 KB. x86-64 allocation is bound by memory: about 14 GB/s
  on the Ryzen virtual machine against about 28 on the M3 (2026-11-03).
- **The C API leaves room for a collector like OCaml's** (2026-11-05). C stores values only through `shen_vector_set` and
  `shen_root_set`, where `caml_modify` would go, and holds nothing across an allocation outside roots. The header names no
  layout beyond the fixnum encoding and a few constants. One assumption is left: the heap does not move while a thread holds
  the lock and makes no API call, which `bytes_data` and `string_bytes` need.
- **Each step lands alone,** with stress tests, the image round trip, the benchmark comparison and a line count, and deletes
  what it replaces. The set of barrier sites stays closed and documented.

### Not tried yet

**A generational nursery:** sized and deliberately left out for now (2026-11-04), with a collector revision wanted someday.
Real programs would gain 6–15% and allocation loops on x86-64 15–27%, against about twice the time where data lives and a
barrier every C store must honour for good. About 200 lines by estimate: today's semispaces as the old space, survivors
promoted at once, remembered slots in a fixed buffer, no barrier on cells and constants. Nothing below ran with a real one.
One allocation area (2026-11-05) has since given part of this, staying in the cache, with no barrier, so these figures overstate what is left.

- **Survivors at 4 and 16 MB** (M3 Max, throwaway build): kernel suite 2.9%, 1.5%; stlib install 23%, 24%; short lists 1.0%,
  0.3%; a long list kept 100%; an old vector filled with new pairs 38%, 10%.
- **1 MB does not work** (M3 Max). Short lists fill it every 77 µs, root passes take 9% of their time, and projected collection
  is three times today's (0.05 s against 0.017).
- **The gate,** set before measuring: x86-64 time outside collection down 15% or more on the kernel suite and short lists. Ryzen
  virtual machine, best of 9, collecting every 16, 4 and 1 MB: kernel suite 0.99, 0.98, 0.98; short lists 0.92, 0.85, 0.84;
  tuples 0.86, 0.77, 0.76. Short lists reach it and the kernel suite does not.
- **Projected whole time at 4 and 16 MB.** Ryzen: kernel suite 0.94, 0.94; stlib install 0.85, 0.89; short lists 0.84, 0.85;
  tuples 0.73, 0.78. M3 Max, where data lives: a long list kept 1.9, 1.9; non-tail recursion over it 2.3, 2.0; an old vector
  filled with new pairs 1.9–2.3, 1.5–1.9. Every survivor is copied once more.
- **Risks.** C may store into an object it allocated before a later allocation, as `grow` in `dict.c` does, and with promotion
  that object can be old by then. Stress finds a missed barrier only if a minor collection falls in that window. A failed
  `address->` check under a quiet handler jumps straight to the handler, so a barrier leaving by that path loses stores under
  `trap-error`, as a forced store did in the throwaway build. So keep the barrier inline.

**Smaller ideas:**

- A port override of `shen.record-kl` that skips the source of the kernel's `shen.consume*` helpers: about 5 lines, about 0.5 MB
  per run in the workload above.
- A kernel hook for Prolog's big vector. Lazy Prolog state was measured and left out (2026-11-04, M3 Max): queries use a mean of
  53 of 10,000 slots in the kernel suite, yet lowering `prolog-memory` to 1000 reads 1.00, as a dead vector is never copied.
- Shrinking the semispaces or the guest stack, and walking frames instead of scanning the stack linearly.

## The lowerer, the bytecode, the kernel port and Prolog

Terms used below. Before → after numbers and bare ratios compare a change with the build just before it, unless the
entry says otherwise, and a ratio is new time over old, so 0.76 is faster. The campaign is an earlier prototype's
benchmark set of 156 timed rows: canonical micro-benchmarks, and "other drivers" for calls, applications and Prolog.
"× Shen/Scheme" is a multiple of the campaign's recorded Shen/Scheme time. Open code can be redefined; sealed code
cannot. The kernel suite is the kernel's `tests/runme.shen`; the stlib install loads the standard library.

### Bytecode and lowering rules

- **Register bytecode, lowerer in Shen** (design, 2026-11-01). An earlier bytecode VM's profiles had constant, stack and global traffic
  dominating retired instructions, so the JIT's only input is register bytecode with resolved slots and literal
  operands, with no interpreter. The lowerer emits symbolic Shen lists that C encodes by name, so no encoder is
  generated. Semantic decisions stay in Shen: that VM had removed a C pass that found match plans in bytecode.
- **Constant operands** (2026-11-01, Apple M3 Max, campaign). A literal used to be copied to a slot and read back.
  Overall 1.14 → 1.00 × Shen/Scheme.
- **Tail-call arguments in place** (2026-11-01, Apple M3 Max, campaign). A named tail call uses window 0, so each
  argument goes straight to its parameter slot. 0.93 → 0.85 × Shen/Scheme open, 0.89 → 0.77 sealed.
- **Closures removed by rule** (2026-11-01, Apple M3 Max, campaign). `((lambda X Body) A)` is a `let`: a call to
  another package's function 23 → 2.2 ns. A freeze thawed once becomes its body: `lexical-known thunk` 8.5 → 2.7 ms
  (Shen/Scheme 1.1). The factoriser's `GoTo` freezes become labels when every thaw is in tail position.
- **Calls with all arguments at once.** Rejected on 2026-11-01: closures linking to parents, or multi-argument calls,
  looked like a large change for one row at 2.6 × Shen/Scheme. Done on 2026-11-02 in a smaller way (Apple M3 Max): a
  lambda returning lambdas, lowered at runtime, gets a second copy of its innermost body, at most 400 nodes. `lambda
  with many arguments` 14.9 → 2.5 ms (Shen/Scheme 6.5, earlier prototype 7.8), image +6.8 KB. Stage 0 code gets none:
  the kernel does not apply its own chains that way, and it would have added 35 KB.
- **List literals as constants** (2026-11-02, Apple M3 Max). `list equality (true)` 0.326 → 0.107 s (earlier prototype
  0.108). Lists of 64 nodes or more stay code, or the kernel's start-up tables would be kept alive by their code.
- **Packed bytecode** (2026-11-02, Apple M3 Max). Variable-length integers, where 16-bit operands had been the earlier
  idea. Kernel bytecode 3.9 times smaller, image 1.22 → 0.70 MB, startup and benchmarks unchanged.
- **Calls through `fn`.** Sealed F became a direct call (2026-11-01, Apple M3 Max, campaign: 3.1 ms sealed against
  23.8 open). For open F a cache per call site was rejected, as it needs a hook in `put`. An inline arity test did it
  instead (2026-11-03, Apple M3 Max): `cross-unit-global-unary-ordinary` 18.1 → 2.7 ms (earlier prototype 1.7).
- **Checking normalization's output** (2026-11-07, Apple M3 Max). `check-lowerer` checked only the code objects, so a
  bug in normalization showed only if it made bad bytecode. It now also checks, for every definition it lowers and every
  unit case, that `norm` gives the emitter's language: only its nodes, of their shapes, `apply` with at most one argument,
  each variable bound where used, a bound name never a constant, primitive arities. 35 lines in `check.shen`, on 954
  definitions; the run's 0.9 s of user time did not move. Planted bugs, with the stage 0 output made again by the same
  mutant so that only the checks judge: a binder left out of `bound-now`'s scope, which turns its uses into symbol
  constants, passed every old check and failed 6 definitions here; a two-argument `apply` and a `trap` handler outside
  its variable's scope passed the structural and dataflow checks and failed only a unit's expected output, and here; an
  unbound variable and a wrong primitive arity were already failing as a stray `capture` and a bad `prim`. A misshapen
  node makes the emitter loop, so the check cannot report it before stage 0 hangs.

### Sealing and inlining

- **What is sealed** (2026-11-01). First decided as in Shen/Scheme: a later `defun` of a kernel name changes open
  calls only. Revised the same day: redefining a kernel, port or lowerer name raises, also through `eval-kl`, so that
  user code can inline them. Extensions stay open, as their tests reload them. Sealing user code is an option, off by
  default; a sealed call to an undefined name binds at its first call, so no file grouping is needed. With inlining
  and slot sharing (Apple M3 Max, campaign): open 1.00 → 0.93 × Shen/Scheme, sealed 0.89.
- **Limit of 15 nodes, two levels deep** (2026-11-01, Apple M3 Max, against 15). A limit of 40 grew the image 1.24 →
  1.72 MB and slowed the kernel suite 0.40 → 0.47 s. Bodies with real literals are refused, since stage 0's host and
  Shen/JIT may read their last bits differently.
- **Slot sharing** (2026-11-01, Apple M3 Max, campaign). A `let` of one variable to another shares its slot. Without
  it, sealed `realistic-call-heavy` took 0.29 s against 0.12 s open; with it, 0.073 s.
- **Open callees inlined too** (2026-11-03, Apple M3 Max). Measured first: a build with no arity check timed the same,
  and a call too large to inline costs the same open or sealed (1.5 against 1.6 ns), so entering past the arity check
  and patching open call entries were rejected. Open calls inline behind a guard that a redefinition patches: a small
  callee 1.4 → 0.76 ns, `realistic-call-heavy` 0.48, other drivers 0.845.
- **Compile time, accepted** (2026-11-03, Apple M3 Max, re-evaluating eight definitions, against a build from earlier
  that day). 253 → 310 µs a round, 269 without open inlining and 308 with one level of it, so taking it back means
  inlining less. Compile-heavy workloads lost 3-5%; switching open inlining off takes 1% back.

### Factorisation

- **No factoriser in the lowerer** (design, 2026-11-01). That VM's bytecode compiler took about 3.4k lines with
  factorisation and pattern work. The lowerer uses the kernel's `shen.factor`, as Shen/Scheme does.
- **`define`'s output factorised** (2026-11-02, Apple M3 Max, without `(factorise +)`). Only that output, since
  `shen.factor` raises on a `cond` with no final `true` clause; `ps` still shows it as written. A 12-element list
  pattern 17.4 → 3.6 ns, twelve clauses 263 → 5.9 ns.
- **Bodies reuse what tests bound** (2026-11-03, Apple M3 Max). The factoriser binds parts of the argument inside the
  `and` chain, out of the body's reach, so the lowerer makes the chain nested ifs failing to a label: `nested list
  pattern (matching)` 9.2 → 6.4 ns. This first made the kernel's failure continuation a closure on every call:
  `realistic-pipeline` 1.15-1.22 times as slow, caught by a campaign rerun and fixed that day.
- **That rule made clause chains cubic** (2026-11-04, Apple M3 Max). One `defprolog` of 400 facts loaded in 23.3 s,
  now 0.23 s (Shen/Scheme 0.30). 5000 facts take 43 s against 24; the rest is the kernel's compiler, left alone.
- **Rejected: testing shared clause tests once before the chain** (2026-11-03, Apple M3 Max, trial build). A
  12-element pattern went from 22 compares to 12, and `match list (multiple clauses, matching)` stayed at 5.1 ns
  (earlier prototype 4), as the compares are predicted.

### Kernel overrides

Each override needs its own measurement; none is applied because another port has it. Reviewed on 2026-11-02 against
all that Shen/Scheme and the earlier prototype replace.

- **Left as the kernel's** (2026-11-02, Apple M3 Max, against Shen/Scheme 0.52). `not`, `boolean?` and
  `shen.byte->digit` inline as they are. `pr`: 2 MB of output in 40 ms against 41; writing a string at once waits for
  an output-heavy program (done later: `pr` at once, below). `element?`: 1.1 ns per element against 2.4.
- **`symbol?`** (2026-11-01). The kernel's relies on `str` raising on non-atoms, which `str` here never does, as in
  Shen/Scheme, so closures and Prolog variables read as symbols: all 12 first failures of the kernel suite.
- **Numbers** (2026-11-01). Integers are fixnums and overflow raises, where Shen/Scheme has bignums. Literals beyond
  that range become reals, and `8.0` reads as 8, as in Shen/Scheme, so KLambda source cannot write the real `0.0`.
- **Small functions split or replaced** (2026-11-02, Apple M3 Max). The kernel's `integer?` took 21 ns for 7 and 1 µs
  for 1.0e15, now 0.86-2.6 ns (Shen/Scheme about 1). `<-vector`, at 18 nodes, missed the limit of 15, so its failure
  could not reach a caller's quiet handler by a jump: under one 6.7 → 2.1 ns. `shen.+vector?` split and
  `shen.+string?` testing the type first: failing patterns 0.57-0.62.
- **Reader rules** (2026-11-02, Apple M3 Max). Loops over runs of bytes where the kernel's rules build a parse result
  per byte. Reading 1,000 definitions 10.6 → 5.8 ms; 13 packaged kernel sources 26 → 22 ms (Shen/Scheme 86).
- **Strings to byte lists** (2026-11-07, Apple M3 Max, against the build before, three interleaved rounds).
  Reported by @pyrex41 in #16. The kernel's `shen.str->bytes` takes `tlstr` at every byte, copying the rest
  of the string each time. The port now reads one byte buffer backwards into a list. Five passes of
  `read-from-string` over eight existing sources (core, macros, reader, sys, prolog, types, writer and the
  lowerer; 150410 bytes together) retired 21.04 to 1.54 G instructions, with the same number of forms.
  The kernel suite and reading those files from disk were within 0.2%. Empty strings, UTF-8, embedded NUL
  and the non-string error are checked in the eval cases.
- **`pr` at once** (2026-11-08, Apple M3 Max, against the build before, two alternating rounds of five). The kernel's
  writes a byte at a time, each a `write-byte` and a `pos` under a handler, and finds the end by the error the last
  `pos` raises. The port's copies the string to a byte buffer and writes it by one `shen-jit.write-bytes`. 2 MB in
  40,000 calls to a file 40 → 4.0 ms; 40,000 lines of `output`, formatting included, to a pipe 41.5 → 5.6 ms. The same
  bytes are written. `make test-overrides` runs both into files of their own over every one-byte string and some
  others, non-strings, a closed stream and non-streams, each with and without `*hush*`; planted, `*hush*` ignored fails
  5,140 checks, the empty string written to what is not a stream 4, the last byte dropped and the count returned
  1,028 each. Not tried: a primitive that writes a string with no copy.
- **`append` in C, `reverse` not** (Apple M3 Max, against the kernel's). `append` copies in one pass into the free
  space (2026-11-02): 32 elements 61 → 32 ns (Shen/Scheme 43), one element 0.5 ns slower. The same for `reverse`
  (2026-11-03) was rejected: 37 → 32 ns at 32 elements, but 2.4 → 3.3 ns at one and 233 → 320 ns at 256.
- **Loading** (2026-11-02, Apple M3 Max). `shen.record-kl`'s `adjoin` made loading quadratic: a name with no
  `shen.source` property now goes straight on the list. Files read in C were first judged not worth it, at most 8% of
  `load`, then done, as the kernel's `read-file-as-string` is quadratic too. Both: 9,000 definitions 636 → 245 ms.
- **Lazy lambda forms** (2026-11-02, Apple M3 Max). Reading a definition compiled a curried lambda that `fn` rarely
  needs. A placeholder holding the arity now waits for `fn`, and `shen.*gensym*` still moves by the arity, so later
  gensyms are unchanged. Reading the property directly shows the placeholder. With `eval-kl` returning a non-list
  uncompiled, 3,000 definitions compile 208 code objects, not 6,217.

### Prolog

- **`shen-jit.deref` follows a chain inline** (2026-11-07, A/B against the build before). Past one step it called C, which THORN `ec` did 1.08 million times a run. Three lines more. Ryzen 5 5600X cycles, median of 9: `ec` 0.970, L 0.989, schubert 1.004, set 1.003, kernel suite 1.000, where each run's spread is 1% to 3%. Apple M3 Max, 11 rounds: `ec` 0.98, L 0.993 to 0.997, schubert and set about 1.00.

Prolog `tak` is not evidence for runtime changes: it needlessly allocates big vectors, and a kernel hook could fix
that. Its readings decided nothing below.

- **Head patterns as `let`s** (2026-11-02, Apple M3 Max). The Prolog compiler binds a curried lambda per head pattern.
  Each use becomes `let`s, copies adding 1,500 nodes at most: `subset` 0.74, `nreverse` 0.75, Einstein 0.75. A split
  `shen.deref` was rejected then: `queens-8` level, Einstein 6% faster, `subset` 12% slower.
- **Immediate variables** (2026-11-04, Apple M3 Max, interleaved, best of 15, and then Ryzen 5 5600X VM). The kernel's
  absvector per variable was 12.4% of the kernel suite's bytes. Einstein 0.77 and 0.86, `nreverse` 0.91 and 0.84,
  kernel suite 0.97 and 0.96. The one reader of an offset outside the kernel's Prolog was fixed in kernel 43.2.
- **Rejected: lazy Prolog state** (2026-11-04, Apple M3 Max, trial runs). Queries use a mean of 53 of 10,000 slots in
  the kernel suite, but `prolog-memory` at 1000 reads 1.00 on it and on the stlib install: a dead vector is never
  copied, and only its fill costs. It would add a load to every binding access.
- **Closures, in three steps** (2026-11-04, Apple M3 Max and then Ryzen 5 5600X VM, against the build before them).
  Einstein's closures were 92% of its allocation, 69% of those from unifying lists. A unifier with no closure per
  element; `shen.bind!` with its continuation in place; a let-bound freeze reaching only `thaw` and `shen.bind!`, and
  an inlined body thawing a literal freeze once. Einstein 0.66 and 0.64, `subset` 0.84 and 0.83, kernel suite 1.00 and
  0.99, stlib install 1.03 and 1.02. Tried: copying from the outside in was exponential, `subset` taking 10 s to load;
  a limit of 1,500 nodes read 1.05 on the kernel suite and 1.06 on the stlib install, so freezes copy within 100.
  Later that day, against the build before it, a closure too large to copy waited for an atom pattern's tests:
  `hamilton` 0.85, stlib install 1.02.
- **Trail with `is` in place** (2026-11-04, Apple M3 Max). The unifier returns the variables it bound, or undoes them
  and returns false, so nested lists make no closure either. `nreverse` 0.91, Einstein 0.98, stlib install 1.02. The
  trail without the lowering rule read 1.02-1.07, so they go together, and the continuation is then never a tail call.
  With the occurs check off the unifier kept the kernel's `=` on two lists for terms that hold themselves, which made
  Einstein slower off than on (1141 against 825 µs); an identity test ends those terms too.
- **`shen.lazyderef` as an inline primitive** (2026-11-04, Apple M3 Max). Nearly every variable is one step from its
  value (mean 1.00 to 1.04 on seven programs), so the cost was the call, about 2.7 ns. Binding the younger variable to
  the older, as a WAM does, would not help for the same reason. `hamilton` 0.63, Einstein 0.76, kernel suite 0.96.
  `shen.deref` followed, inline for all but pairs: `queens-8` 0.87.
- **Rejected: a unifier shaped for loop registers** (2026-11-04, Apple M3 Max). Its frame has 10 slots where 8 fit, so
  it never got them, and its helper cost the kernel suite 1.01 and the stlib install 1.03, for the same Einstein 0.92
  as the change kept: heads that are not pairs unified with no recursive call.
- **Rejected: fewer checks in `shen-jit.deref`** (2026-11-04, Apple M3 Max, best of 15). Slots known to hold
  absvectors, about 30 lines: Einstein 0.99, `hamilton` 0.97, but the kernel suite 1.01 and stlib install 1.02.
- **Rejected: first-argument clause indexing** (2026-11-04, Apple M3 Max, estimated from counts and a hand-split
  `edge`). Sound, and left out. At about 2 ns per failed clause `subset` would gain about 6%, the kernel suite under
  1%; `hamilton` by hand 0.66. Only large fact tables fall behind: a lookup in 1000 clauses takes 2.784 µs against
  0.043 for SWI-Prolog -O, and a real index needs a hash or jump table.
- **Standing** (2026-11-04, Apple M3 Max, CPU time per iteration, seven programs, geometric means). 0.85 of SWI-Prolog
  10.0.2 -O and 0.50 of Shen/Scheme 0.52 when first compared, 0.65 and 0.38 after the changes above.
- **`get-time` without interning** (2026-11-05, Apple M5, load about 25, against the build before). THORN asks for the
  time at every predicate call, and each call interned `run` and `unix`, about 2% of samples on RCC problems. Comparing
  the name instead: 10^7 calls 0.28 to 0.155 s, THORN's thm13 28.05 to 26.42 G instructions and rcc10 20.48 to 19.40 G.
- **Cut then `(when false)` folded** (2026-11-07, Apple M5 under load 15-40, instructions retired, three alternating
  rounds against 3a474bf). THORN's generated depth, complexity and loop clauses end in `! (when false)`, and the
  closure, `shen.cut` and its thaw ran about 3.5 million times in rcc10's 47 million inferences, 6% to 15% of
  inferences on set, L, schubert and `ec`; `shen.cut`, `shen.unlocked?` and `shen.lock` were 3.7% of rcc11's samples.
  A lowering rule of seven lines makes it the lock test alone. rcc10 18.88-19.07 to 18.46-18.54 G (-3.0%),
  rcc-dreammachine at depth 8 without its time limit 55.6-56.0 to 54.4-54.8 G (-2.2%), L -1.8%, `ec` -1.5%, schubert
  -1.4%, set 0.0%, each including loading THORN; kernel suite and stlib install within noise (eight rounds of the
  install: 0.917-0.940 against 0.919-0.948 G). Same inference counts; no kernel definition has the shape.
- **THORN's inference counts as a test** (2026-11-05, Apple M5). Nothing checked what a prover computes, and a wrong
  answer from a prover looks like any other. THORN's search is deterministic once its wall-clock limit is gone: seven of
  its problem files gave the same 35 counts and unproved goals on Shen/JIT and Shen/Scheme 0.52, in about a second each.
  Under that limit the counts change with load, so they say nothing. `tests/prolog-unify.shen` also compared the reader's
  1.0, which is the integer 1, so a unifier comparing numbers by identity passed 1495 of 1495; with a computed real it fails 6.
- **`(when (= X Y))` compares without copying** (2026-11-07, Apple M5, load 15-40, instructions retired, 3 alternating
  rounds against 3a474bf). The Prolog compiler makes it `(= (shen.deref X B) (shen.deref Y B))`, which copies both terms
  first; THORN's `loop?` runs it at every predicate call whose hypotheses hold the negated literal, 705,000 times copying
  9.8 million pairs on thm13. A lowering rule calls `shen-jit.deref=`, which dereferences as it compares, 8 lines in the
  port: thm13 25.85-25.96 to 24.92-25.02 G, rcc10 18.86-18.97 to 18.30-18.44 G, THORN `meaning` (rewriting on) 55.04-55.33
  to 52.05-52.20 G, steam 0.5-1% fewer, and the kernel suite, stlib build, yql, L and `ec` level (yql, L and `ec` never reach
  it). The kernel's own Prolog compares a dereferenced term only with a constant, which the rule leaves alone.

### Native code written by hand

- **Level** (plan, 2026-11-02). Of KLambda through `eval-kl`, bytecode, and SLJIT operations, we chose bytecode:
  portable, checked, and the result is an ordinary procedure. SLJIT stays an option at about 400-700 lines.
- **`define-native`** (2026-11-03, Apple M3 Max, against a `define` that also tests for `[]`). A macro over forms,
  since brackets in Shen mean lists; `shen-jit.assemble` and `shen-jit.install-code` take lists, for generated code.
  The checker's rules moved to `lib/native.shen`, so one set holds the lowerer's output and hand-written code. Two
  rules are new, as the JIT relied on them unchecked: handlers nest in code order, and a handler reads no slot written
  since its push. Summing a list takes 0.83 of the `define`'s time. Fuzzing: 3,500 mutated code objects, about 390
  accepted and run, no crash.
- **Byte buffers in place of raw slots** (2026-11-03, Apple M3 Max). Lifetime, images and bounds do not arise for a
  heap object with its length in its header. No unchecked mode until a real program shows it matters: the checks are
  0.52 ns of a 1.36 ns `u8`, in a loop that sums bytes (no checks 0.84, C not vectorised 0.32).
- **Rejected: buffers and bit operations in Shen** (2026-11-03, Apple M3 Max, against the C primitives). Only three
  could move, freeing about 21 of 230 lines of C. `copy-bytes` is 34 times slower at 64 B.
- **Structured control** (2026-11-07, Apple M3 Max, against the same code written with labels). `if`, `when`, `unless`,
  `while`, `for`, `block`, `exit` and `next`, made into labels, loops and jumps before anything else, so that nothing
  in the checker or the JIT changed. About 190 lines with their comments. The path tracer, rewritten with them, lost all 48 of its labels,
  jumps, loops and agains and 43 of its 261 lines, gave the same check as C's, and took 0.330 to 0.334 s against 0.332
  to 0.333 s, in alternation. A loop written both ways assembles to the same code object. Whether a comparison is of
  reals or words is told from its operands, as a real register or something only reals give; writing it would have
  doubled the forms. A join nothing reaches has to be left out, as the checker refuses unreachable code: an `if` whose
  arms both return showed it. Done ahead of Datalog's native joins, whose generator would otherwise have been written
  against labels. Not done: typed parameters, which would repeat checks every access already makes; a definer of its own;
  source mapping, until errors in an expansion are hard to read.

### Kernel pins and reproducible stage 0

- **Self-hosting check** (2026-11-01, Apple M3 Max). The lowerer inside Shen/JIT must give stage 0's output exactly:
  1,162 defuns in 0.29 s, against 0.36 s under Shen/Scheme. It found: `read-file` macroexpands, so stage 0 reads
  KLambda unprocessed; `symbol?` differs between hosts, so the lowerer has an exact primitive, also making it 13 times
  faster inside Shen/JIT; `strtod` and Shen's reader can differ in a real's last bit, so stage 0 writes what it read.
- **Manifest and host independence** (2026-11-03). `generated.sha256` holds the hashes of the 51 generated files, and
  a tarball builds from them with a C compiler alone. Stage 0 on Linux x86-64 with Shen/Scheme's v0.52 release binary
  gives them byte for byte as on macOS arm64 with the pinned checkout.
- **Released kernels only** (2026-11-03). A pin check does not cover `klambda/`, git-ignored in the kernel, and the
  copy in use predated commits the pin included. We keep the latest release and do not rebuild from main; an
  unreleased type-checker optimisation stayed out, though it read 0.91 on the kernel suite (271 → 247 ms, Apple M3
  Max). Since 2026-11-04 CI takes the kernel's and Shen/Scheme's release archives, checked by hash.
- **Kernel 43.2** (2026-11-04, against 43.1). The type checker dereferences a term once per call: kernel suite 0.89 on
  Apple M3 Max (215 → 191 ms) and 0.93 on Ryzen 5 5600X VM (301 → 279 ms), stlib install 1.00 on both.

- **A previous `shen-jit` as the stage 0 host** (2026-11-05, Apple M3 Max, tried and not yet the default). Stage 0 ran in about 1 s against about 6
  under Shen/Scheme, 48 of the 52 generated files came out byte for byte, and the system built from that output passed the eval cases, the self-hosting
  check with 0 differences, the kernel's tests, the CLI tests and the FFI suites. It needs no hook in the host's runtime, only in the build tools: the lowerer's own names are sealed in the host's image, so a new lowerer loads
  under other names; the host's `define` must know the arity of `shen-jit.inline-body`; and `filter` is Shen/Scheme's, so the tools define it. Of the four files that differ, `port/lower.kl` and the two made from it differ as the host compiles
  and numbers things its own way, and `kl/ops.sbc` as `-2305843009213693952`, the smallest fixnum, reads as a real under `shen-jit`, its digits overflowing before the sign applies. So the manifest would have to follow one host, or those be normalised.
- **The smallest fixnum as a literal: a reader fix rejected** (2026-11-05). `-2305843009213693952` reads as a real, because `shen.compute-integer` gets only the digits, which are past the range, and the kernel's `shen.<number>` applies the sign
  afterwards. A fix would override `shen.<number>`, 1.4 KB of generated code to keep in step with the kernel, for one value in 2^62. `docs/semantics.md` records the limit, and `tests/kl/ops.kl` computes the value instead, which takes
  `kl/ops.sbc` out of the files that differ by host: lowered under `shen-jit` and under Shen/Scheme it is now the same byte for byte, where one line differed before.
- **Literals past the fixnum range are the nearest real** (2026-11-05). `shen.compute-integer` and `shen.compute-E` fell back to arithmetic on doubles, whose errors build up: `1e100` read as `1.0000000000000006e100`, and `1e308` as `9.999999999999998e307`. They now hand a decimal string and an exponent to `strtod`, through
  `shen-jit.decimal`. Against Python's reading of the same text, integers of 20 to 300 digits went from 26% on the nearest double, the worst 17 units in the last place off, to all of them, and an integer with a large exponent from 11%, the worst 5 off, to all of them, on macOS, with the same results checked on Windows. The digits before an exponent may
  already be rounded, as in `0.3e300`, or `123456789012345678901234567890e5`, whose exact digits `shen.<number>` has lost by then, so those can land next to it. As a real, `-2305843009213693952` now equals the smallest fixnum by value, where before it was 512 off.
- **A previous release is the default host** (2026-11-05, Apple M3 Max). `v0.1` makes the generated files, in 1.4 s against 5.5 under Shen/Scheme 0.53, which stays as the way in that does not start from Shen/JIT. All 52 files are now the same byte for byte under both, so one manifest
  serves them and CI's `shen-scheme-host` job checks it: `port/lower.kl`, and the two files made from it, differed only in how the compiler numbered variables, from a gensym count that depends on the host, and `tokl.shen` now starts it from zero in each definition. That also stops a change to one
  function renaming the rest. The rename the experiment above needed is a build step, so both hosts take one path: `build/tools/lower.shen` has the lowerer under `stage0.lower.`, as its real names are sealed in a host that is Shen/JIT.

- **Kernel 43.4** (2026-11-06, against 43.2 at the same runtime). Only 7 of its functions differ beyond generated names, and the port overrides none: `declare`, `shen.factor-recognisors`, and five initialisers. Its factoriser takes a `cond` with no true clause, so `define`, which factorises everything here, no longer fails on one. On a Ryzen 5 5600X VM, idle, best of 5: kernel rows 1.001, port rows 0.999, the realistic programs 0.993 and 0.994, THORN and the standard library install the same, startup 3 ms on both. An Apple M3 Max at load 2 to 4, best of 3: kernel rows 1.006, port rows 1.001. **Not taken:** the hook its expansion offers ports, `shen.precompiled-function?`, as the image holds the kernel already initialised. One of its new extension tests writes where it runs and calls `delete-file`, which only stlib defines, so `make test-kernel` runs those tests from a copy through `tests/kernel-extensions.shen`. `gensym` now starts at 7, not 32, so `lazy-gensym` counts from where it starts.

- **Shen/Scheme 0.54** (2026-11-06, Apple M3 Max, against 0.53). It compares with numeric literals soundly and raises when a `cond` has no true clause, so `eq-int-real-literal` and `ctl-cond-no-match` are no longer deviations, and its `hash` still gives 8 and 8.0 different values. All 157 contract examples pass, it makes the same generated files as a host, and it gives THORN's 35 counts. Its timings are under "x86-64 Linux" below.

### Not tried yet

- **Correctly rounded fractions and negative exponents.** They do not overflow, so they read as the kernel reads them, as under Shen/Scheme: `0.3` as `0.30000000000000004`, and `1e-300` as `1.0000000000000022e-300`. Measured on 2026-11-05, 59% of random fractions land on the nearest double, the worst 1 unit
  in the last place off. `shen-jit.decimal` could read them too, at the cost of differing from the kernel and Shen/Scheme.
- A dictionary behind `shen.sysfunc?`, 60% of reading code in a package (2026-11-02). It needs a way to tell that the
  278-symbol list changed.
- The lowerer lowering itself as a gate on every change, after Wirth and Gutknecht's rule that an optimisation must
  speed up the compiler compiling itself; and an audit of special cases against workloads outside the benchmarks.
- Raw slots for 64-bit integers and unboxed doubles, SIMD, and SLJIT operations written from Shen. Declared
  signatures, so typed code can call installed procedures.

## Runtime, threads, platforms and usability

Times are from an Apple M3 Max under macOS unless an entry names another machine. "The Ryzen VM" is a Hyper-V virtual
machine on a Ryzen 5 5600X with Ubuntu 20.04, gcc 9.4 and glibc 2.31. A bare ratio is new time over old time.

### Threads

- **Real threads under one global lock (2026-11-04).** Programs written for Shen/Scheme call `thread`, which is Chez's
  `fork-thread`, as in `(thread (freeze (tk.event-loop)))`, and failed here with an undefined function. We started with
  the simple case: one thread runs at a time, which gives concurrency for work that waits and no speed-up from more
  cores. Join, mutexes and channels are left out, as in Shen/Scheme. `thread` is defined after sealing ends, so that
  programs may define their own.
- **No measurable cost until the first thread.** Each thread's guest stack and handlers are swapped into the VM's fields
  at a switch, so emitted code and hot paths do not change. Against the build before: benchmark campaign 0.997, workloads
  outside the benchmarks 1.00. About 355 lines in all, against an estimate of 120 to 200.
- **Loop checks are needed once threads exist.** A 10 ms ticker asks the way Ctrl-C does, and a thread gives way at a
  frame or loop check, or while it waits on stdin. Without loop checks a spin-wait on a global would hold the lock for
  ever, so the first thread has all code compile again with them. On the Ryzen VM an empty loop then takes 0.54 ns
  against 0.43, and building short lists 1.08 times as long.
- **`exit` could hang:** it flushes every stream, and waits on one that another thread is blocked reading. With threads
  the process flushes what was written and calls `_exit`, so `SHEN_JIT_STATS` prints nothing then.
- **A release woke the whole queue (2026-11-07, Apple M3 Max, against the build before).** Waiters sleep on one of 16
  condition variables, by ticket, in place of one that every release broadcast to. Threads waiting on a socket take the
  lock 10 times a second, so this grew much faster than their number. CPU seconds during a 6 s wait, old then new:
  100 threads 0.56, 0.29; 300 threads 2.25, 1.60; 1000 threads 595, killed at 40 s without finishing, then 21, finishing
  in 6.2 s. Handoffs did not change: 4 threads polling 50000 times each 0.57 to 0.60 s, 0.58 to 0.59 s; 4 busy threads
  under the ticker 0.51 s, 0.52 to 0.53 s. 1024 variables did no better than 16 (1024 then 16: 300 threads 1.25, 1.39;
  1000 threads 23.4, 21.5), so collisions are not what is left at 1000. What is left there is 10000 lock round trips a
  second, which we did not take further, as 1000 idle threads is not the frequent case. Longer poll slices would cut it,
  and would slow the response to Ctrl-C.
- **A closed pipe ended the process (2026-11-07).** SIGPIPE was at its default, so `write-byte` to a pipe nobody read
  died with status 141, and only sockets avoided it, with their own flags. A review of an I/O library found this, as its
  contract promises an error. It now has a handler that does nothing, set at startup, and the write fails and raises.
  `SIG_IGN` was rejected: an ignored signal stays ignored across exec, so a child such as `yes | head` would see EPIPE, and
  every spawn would have to reset it. A handler is reset by exec, as a test checks. Dying quietly when the uncaught error
  is a broken stdout was left out: `| head` now prints one error and exits with status 1, as Python does, and that
  would take a special case at the top level. The flags in `lib/socket.shen` are now redundant, and stay until someone
  changes that file.

### x86-64 and Linux (2026-11-03)

Every suite ran in Docker (arm64 with gcc 15, x86-64 through Rosetta with gcc 14, from the release tarball), then natively on
the Ryzen VM, in 214 s. macOS had hidden everything below. Timing is in the JIT and benchmark sections.

- **Found in Docker:**
  - glibc hides `clock_gettime` under `-std=c11`; x86-64 needs `-lm` for `floor`, which arm64 inlines.
  - Two test programs read a value as an argument before another argument's allocation moved it, an order gcc on x86-64
    evaluates in and clang does not. The runtime itself had no such order.
  - `jit_destroy` left the call-site table and perf map allocated, which Linux's AddressSanitizer reports.
- **Found only on the real machine:**
  - The JIT could not start. glibc also hides `MAP_ANON` under `-std=c11`, so SLJIT mapped `/dev/zero` for its code, which
    fails where `/dev` is mounted noexec, as on Ubuntu. Docker's `/dev` is not, so every container had passed. SLJIT is
    now compiled with `_DEFAULT_SOURCE`.
  - The profiler's `dladdr` needs `-ldl` before glibc 2.34.
  - The kernel checks used `tee /dev/stderr`, which on Linux reopens a redirected log and truncates it.
  - `check-generated` depended on a glob's order, which follows the locale where `/bin/sh` is bash, and reported drift
    in unchanged files. It now uses C order.

### Native Windows (2026-11-04)

- **Toolchain:** gcc in MSYS2's UCRT64, which keeps one Makefile and the GNU tools, linked statically to need nothing installed.
- **Rejected: MSVC.** The JIT's code does not depend on the C compiler, so users would see nothing, at the cost of a second
  build system, replacements for GCC builtins and a second compiler to test. Worth reconsidering only to embed Shen/JIT in
  a Visual Studio project.
- **Rejected: WSL as the answer for users.** It means enabling a Windows feature and installing a distribution.
- **No JIT change was needed:** the Win64 convention worked at the first run, and its eight saved registers give loops four
  registers against Linux's two. Threads stay on pthreads through winpthreads.
- **What it found:**
  - `select` works only on sockets, so the read of stdin waits by itself, without the lock.
  - Ctrl-C runs on a thread of its own and ends the main thread's read with `CancelSynchronousIo`, only during a read:
    cancelling a write would lose what was being written.
  - `clock()` and `gettimeofday` tick once a millisecond, too coarse for rows of a few ms. `get-time` uses
    `QueryPerformanceCounter` and `GetSystemTimePreciseAsFileTime`, 0.1 us between two reads. `get-time run` is elapsed
    time there, as `clock()` is: the processor-time counter ticks only every 15.6 ms.
  - `*os*` said "Unix" there until 2026-11-05.
- **Tests:** every suite passes on Windows 10 from the tarball, GC stress included, but MSYS2's `kill` ends a native program, so CLI
  tests that send a signal do not run. A driver through a real console (2026-11-05) saw Ctrl-C end `accept` and `recv` in 92 ms. It became `tests/ctrlc_windows.py`, 8 checks in 3.3 s on the Windows 10 machine, which CI runs too.
- **Timing:** Windows 10 Pro with gcc 16 on a Ryzen 5 5600X, against the Linux VM it hosts: all rows 0.961 open and 0.939 sealed,
  applications 1.10; the kernel test suite 309 ms against 277, startup 7 against 2.
- **Its slower rows are a fixed cost per process.** Long application rows read 0.86 to 1.00; short ones at 1.2 to 1.7 lose 6 to
  10 ms each. Allocating 39 MB per pass takes 10.2, 7.2, then 2.4 ms there and 4.3, 3.8, then 2.4 on Linux: first writes to the
  semispaces, 16,000 small page faults where Linux has huge pages. A process that does nothing takes 2.3 ms against 0.26.
- **Rejected for that cost:** a smaller starting semispace on Windows, which trades one payment for more collections; large
  pages, which need a privilege a user must be granted.

### Release builds, static linking, CI and the standard library

- **Generated files ship only in tarballs (2026-11-03).** The repository stays free of 1.6 MB that changes with every lowerer
  edit. `make dist` writes a 0.95 MB tarball that builds with a C compiler and `make`; `SHEN_SCHEME=false` shows nothing runs
  Shen/Scheme. A manifest of the 51 generated files' hashes makes any other difference drift.
- **SLJIT without its debug checks (2026-11-02):** runtime 307 to 225 KB, executable 1,030 to 948 KB, JIT compilation about 13%
  faster (9,000 lambda forms, 34 to 30 ms). A first try compiled only `sljitLir.c` without them, so `jit.c` read the code size
  at the wrong offset, as the compiler struct changes with those options. The profiler's test caught it.
- **`make release` (2026-11-03)** strips the runtime before appending the image, which `strip` would drop: 0.96 MB against 1.0
  on macOS and 2.07 on Linux, where gcc's debug information takes 1.1 MB. The code is the same.
- **Static Linux, then both kinds (2026-11-04, 2026-11-05).** Linux release jobs were static at first. Static glibc `dlopen` works
  but loads a second libc (`/proc/self/maps` shows it), and a library calling into a static executable gets `undefined symbol`.
  So a static build refuses to load libraries, and says so. Release jobs became dynamic, built on an old glibc to run on newer
  ones, with static ones beside them until they cost more than they give.
- **CI (2026-11-04).** One job makes the tarball, the only one to run Shen/Scheme, and each platform builds it with a C compiler
  alone and runs every suite and GC stress. CI runners are not used for timing.
- **CI was rehearsed** with actionlint, in containers and on the Mac, before any run on GitHub. That found the
  `save-executable` bug below, and stray `\r` in five extensions' strings in the KLambda in use, unlike the 43.2 release and a
  fresh build of its tag.
- **Found later (2026-11-05):** release archives left out `lib/` and `include/`, so a binary could not have loaded `lib/ffi.shen`.
- **A flaky test, not a lost Ctrl-C (2026-11-05).** `thread-survives-interrupt` failed under GC stress on two runners of one CI run, with one `interrupted` in `spin` and another in the expression after it, which could have been the runtime delivering one signal twice. It
  was not: on Linux arm64 in a container of 1 to 3 CPUs, with up to 32 copies at once, all 287 rounds that sent more than one signal failed, and 472 of the 481 that sent one passed. The test's loop sent a second signal when the first had not shown in the output yet, and it reached the next expression. The
  failures with one signal whose output was kept had it land early, once, as the wait for the REPL ran out under that load. The next expression now waits in a FIFO until the interrupt has been seen.
- **Release notes come from the changelog, and releases start as drafts (2026-11-05).** `v0.1` went out at once, with GitHub's generated
  notes, which with one commit are only a link to the tag. A release is now a draft that someone makes public by hand, and carries its
  section of `CHANGELOG.md`, as Shen/Scheme's and the kernel's do. A tag with an empty section makes no release: those two fall back to
  a line pointing at the file.
- **A release job that checks `main`: rejected (2026-11-05).** One version failed at once if `main`'s run on the commit had not passed yet, which `v0.2` met when `main` and the tag were pushed together, and another waited for that run. Neither is needed: a tag only makes a draft, and whoever
  makes it public can see `main`'s run.
- **Tag runs leave out the heavy suites (2026-11-05).** In a run on `main`, GC stress took 176 to 312 s per job, the sanitizers 43 to
  59 s and the mutated code objects 69 s, and a tag repeated them on the same commit. A tag's run now builds and runs the fast suites,
  10 to 19 s, on what it publishes. `v0.2`'s tag took 2.2 minutes against about 8.
- **bullseye moved to Debian's archive (2026-11-05).** The first run on GitHub failed both dynamic Linux jobs at `apt-get install`:
  `deb.debian.org` still lists bullseye's security updates but answers 404 for their files, which `archive.debian.org` has. The jobs
  use the archive rather than a newer Debian, to keep the executables needing only glibc 2.17, on both architectures.
- **Two faults behind that, found by replaying the job in Docker (2026-11-05).** Without perl there is no `shasum`, so the build id
  compiled in empty and the check that an image matches its build compared nothing: it now uses `sha256sum` where there is one. And
  the test of `[]` looked up `cos`, but Debian's gcc drops an unused `libm`, and the runtime uses nothing from it on either
  architecture: it looks up `strlen` now. The pinned images of `make test-linux` hid both, having perl and keeping `libm`.
- **The guide became Markdown (2026-11-05).** A hand-written page beside a 550-line README said most things twice, each with details
  the other lacked. `docs/guide.md` now holds them, pandoc renders it, and the README only points to it. It is read as GitHub's
  Markdown, so that it reads the same in the repository and its anchors match. The tarball carries the page, so that every release
  archive has it without each platform needing pandoc.
- **The standard library is left out of the default image (2026-11-01), optional since 2026-11-03.** The names it exports become
  system functions, so a program on it cannot define its own `take`. It also defines `min` twice, so it cannot be loaded sealed.
- **`make stlib`** loads the kernel's precompiled `stlib.kl` and saves a binary: a 1.7 MB image, starting in 3.4 ms against 2.8.
- **Found in its tests:** the first "typed code" test checked nothing. `load` decides whether to type check when it starts, so
  `(tc +)` inside a file does not apply to the rest of it.

### Differential testing of the primitives (2026-11-06, Apple M3 Max)

Nobody had tried it, and an outside report had just found bugs past 1,062 eval cases. `tests/differential.shen` runs 81
primitives over 114 values, with up to 18 ways to compile a call: constants, captures, a function value, a loop, handlers, as a
branch's test, after a type test. `SHEN_JIT_SLOW_PRIMS` sends every primitive to `sj_primitive`, a few lines in the JIT,
and the results must match; under it the 1,062 eval cases, the 154 of the kernel and the 157 contract examples pass.
Then properties: `=` an equivalence that `hash` respects, the comparisons agreeing, and so on. 20.6 million checks, about a minute. `copy-bytes` has its own arguments, as five positions of every value would be too many, and copies within and between buffers are checked byte by byte against a model; a forward loop in place of `memmove` and an unchecked source range, both planted, failed.

- **Found, in the first full run:** `absvector` at the heap limit gave handlers `[]`, as the C case returned without
  raising, which `cons` also did there. A length from 2^56 lost its top bits in the header, a crash, in `absvector` and
  `filled-vector`. `pvar` and `pvar-offset` count as allowed under a handler that is never pushed, and their errors went past it.
  All three in paths the eval cases never took. Compiled code and C otherwise agreed on every check, on arm64 and
  on x86-64 under Rosetta, whose results differ only in NaN's sign, and under `SHEN_JIT_GC_STRESS=1000`.
- **Does it notice?** Planted: inline `<=` as `<`, `hd` without its jump to a quiet handler, and the 2^53 bug in `=`
  (compared as doubles). All three failed, the last as "`=` is not transitive" and a differing hash, with nobody having
  chosen those values.
- **Against Shen/Scheme 0.54** (`make differential-scheme`, a report, as either may be wrong). The comparisons, `pos`, `<-address`,
  `address->`, `cn` and the type tests match. Left: bignums against `integer overflow`, how numbers and opaque values print, `hash`.
  Also `(/ 1 r)` with a real zero, an infinity there and an error here, which the semantics wrongly gave as the same,
  now a contract deviation; `(* 0 r)` is an exact 0 there, as in Chez, even for an infinity or NaN, and a real here; and `(+ 0 -0.0)` is
  -0.0 there. Its reader makes `1e200` an exact integer, so a value meant to be NaN or an infinity must be built from a real, or the differences are in the test: `(= 0 nan)` looked true there at first for that reason.
- **Left as it is: integer division past 2^53.** Both operands round to doubles first, so `(/ 9007199254740992 9007199254740993)` gives
  1.0, where Shen/Scheme gives the nearest double, 0.9999999999999999. Comparisons are exact because `=` broke without it; a
  quotient 1 unit in the last place off breaks nothing that was found, and exact division needs 128-bit arithmetic.
- **Pointers.** From `lib/memory.shen`, two blocks filled again for each value, so a call sees what the last one saw; a static build, which cannot load libraries, leaves them out. Each width at each offset of each length is checked against a model of the whole block, stores through read-only and killed pointers raise and change nothing, and copies go within and between blocks. `pointer->string` and `pointer->bytes` are unchecked by nature and `pointer-guard` holds what it is given, so those get a few checks in range and not the sweep. No bugs. An inline bound off by one, a dropped read-only check and `pointer-kill` leaving the address, all planted, failed.
- **Not covered:** what needs a whole program around a call, as generated calls don't reach register allocation across a long function.

### Differential testing of the overrides (2026-11-07, Apple M3 Max)

The port replaces 50 kernel functions, and nothing compared them with what they replace, beyond what the kernel's suite happens to run and `tests/prolog-unify.shen` for the unifiers. `tests/overrides.shen` reads each definition from the kernel's KLambda, loads it renamed beside the override, and runs both over generated values: the 100 of the primitives' test, every byte in a name, 2,000 lists of bytes for the reader's rules, digits and exponents, files, random Prolog terms, random operations on dictionaries. 70,304 checks in 0.16 s, and 0.72 s for all of `make test-overrides`, which runs them again with `SHEN_JIT_SLOW_PRIMS`. Under `SHEN_JIT_GC_STRESS=1000` they pass in 81 s, which the target leaves out.

A renamed definition calls the port's everything else, so a difference belongs to that function. Prolog variables and dictionaries are represented differently, so those functions are loaded whole with their helpers, each side builds its own terms from one description, and results print alike. A difference on purpose is a clause of `o.known`, with its reason, narrow enough to check the value where it can: a literal past the fixnum range must be within rounding of the real it should read as.

- **Found and fixed:** `shen.record-and-evaluate`, copied into the port, lost the newline that ends the kernel's message "hd is not a legitimate function name". It is the one place the text differs, on a look at every pair of messages; the test itself does not compare them.
- **Listed, as they cannot be reached or are as meant.** `integer?` raises "integer overflow" at 2^60 or more and on an infinity or NaN in the kernel's, which doubles a fixnum up to the number. `symbol?` is true in the kernel's of anything that `str` describes, as `#<procedure>` reads as a name, and `variable?` of a Prolog variable, as `Var3` does. `shen.misc?` is true of 35.5, between two codes, and takes bytes. `read-file` skips `#!`. `hash` refuses a real bound, as Shen/Scheme does, where the kernel's gives a real; and it takes a one-element absvector tagged as a tuple, which the kernel's cannot print to hash. `shen.dict` takes sizes and reals that the kernel's cannot allocate. `shen.compute-integer` and `shen.compute-E` give a real past the fixnum range, and 0.0 for what is not a number, which the reader never passes. `shen.compute-fraction-h` gives an exact number for a zero digit. `shen.make-prolog-variable` refuses what is no offset. `shen.bindv` and `shen.unwind` refuse a tuple, whose element 1 the kernel's takes for an offset. `shen.record-kl` lists a name twice if `shen.source` was removed by hand.
- **In the kernel's own code:** a dictionary of size 1 has one bucket at index 3 and `hash` never gives 0, so the first access looks at index 4: `(shen.dict-> (shen.dict 1) a 1)` raises `<-address: 4 is not a valid index`. The port's has no such size, so the test starts at 2.
- **The same in both, not an override's doing:** `(let F zero (fn F))` for a function of no arguments raises "zero is not a function", since `(F)` applies a symbol, as on Shen/Scheme. `(fn zero)` works, as the lowerer calls it by name.
- **Does it notice?** Sixteen bugs planted in the port, one at a time, each failed: no undo in the unifier, no occurs check, a binding order swapped, `shen.deref` stopping at a pair, the gensym count, `shen.record-kl` always adding, a wrong exponent past the fixnum range in `shen.compute-integer` and in `shen.compute-E`, a zero digit's place lost in `shen.compute-fraction-h`, a missed code in `shen.misc?`, a missed `+` in `shen.<atom>`, the dictionary's count, `read-file-as-string` giving bytes, `fn`'s error as a value, what `shen.record-and-evaluate` returns, a dropped free-variable check. Three more broke the reader the test itself is read with: that fails too. A new override that the test does not name fails, as does a listed difference that no longer shows.
- **Left out:** `shen.read-evaluate-print`, `shen.toplevel-display-exception` and `shen.x.launcher.main`, which read the REPL's input, display what reaches the top and end the process, as `tests/cli.sh` checks. `hash` at a bound below 1, where the kernel's never ends. Values of `hash`, which differ by design, so only its range. Running the rules together: `shen.<atom>` runs on the port's number functions, each checked alone.

### The REPL and small decisions

- **End of input ends the process, status 0 (2026-11-01).** The kernel's REPL, and so Shen/Scheme, prints "empty stream" at every
  prompt for ever, so piped input never finished. A read in user code still raises the error.
- **Line editing (2026-11-01):** documented `rlwrap`. `isocline` and `replxx` were rejected as more than this needs.
- **`(shen-jit.exit N)`, no plain `exit` (2026-11-02):** a sealed `exit` would refuse programs that define their own.
- **`track`, `spy` and `step` checked (2026-11-02), nothing to change.** `track` is refused on sealed definitions.

### Ctrl-C and standard input

- **Design (2026-11-02).** The handler only sets a flag and clears `check_limit`, the limit compiled code checks at function entry.
  Lowering `stack_limit` itself was rejected: it is also the dirty mark above which slots are clear.
- **Loops pay only under the REPL.** Self tail calls jump past the entry check, so loops test the flag at the back edge. That cost
  6 to 16% on the tightest loops and 2.6% over the canonical benchmarks, so only code compiled once the REPL catches Ctrl-C has it.
  Under `script` and `eval` SIGINT keeps its default and ends the process.
- **A program's `trap-error` cannot swallow it:** "interrupted" is raised again at every check until the REPL's handler is innermost.
- **Three bugs, each found by a real Ctrl-C through a pty (2026-11-04),** which earlier tests had missed:
  - At the prompt, or in a program reading stdin, it was dropped, so a half-typed expression could not be abandoned.
  - A loop compiled before the REPL started, as `eval -l FILE -r` allows, had no check, and with SIGINT caught nothing could stop
    it. The REPL now has all code compile again: 2.35 to 2.68 ms to start it, nothing for `script` or `eval`.
  - One landing while the REPL printed its prompt or an error, outside its handler, ended the REPL with "uncaught error:
    interrupted". It is now dropped: about 680,000 signals in 2 s, three runs, where before it died within 966.
- **stdin has its own buffer and read (2026-11-04),** which fixes the first bug. stdio's read would restart after a signal under
  `SA_RESTART`, which writes need, and does not say when it is about to wait. The wait is in `select`, which a signal always ends,
  and only the wait is without the lock. Threads block SIGINT, so that it reaches the main thread.

### Backtraces (2026-11-02)

Built from a table of call sites the JIT records when it compiles, so nothing is paid until an error asks.

- **When to capture took two tries.** "No handler is active" cannot work, as the kernel's REPL wraps every evaluation in `trap-error`.
  "The REPL's handler is innermost" is not enough either: with typechecking on, the kernel raises again from its own frames. A trace
  is kept when the innermost handler, if any, belongs to a frame at or below the REPL's, only if the walk reached the expression being
  evaluated, and only the first in each evaluation.
- **Rejected: breakpoints, stepping and inspecting locals.** They need an interpreter or deoptimisation back to bytecode, the machinery
  that made the earlier prototype large.
- **Inlined bodies (2026-11-03)** stay in backtraces, at a cost in the first version: `h_prim` noted its own return address, so it kept
  a frame, about 1 ns on every primitive called through C (`append` 1.21, `trap-error` raising 1.22 to 1.33). Slow paths in inlined
  bodies now store the site themselves.

### Profiler and heap statistics

- **`SHEN_JIT_PROFILE=1` (2026-11-02)** prints a flat profile from a SIGPROF timer, in about 180 lines of C. Not on Windows.
- **Its bias misled us once.** Samples land where system calls return, so it over-counts C. Loading 9,000 definitions it gave 23% to
  SLJIT's executable allocator; timed directly, all JIT compilation took 23 ms of 645. Time a profile's claim before acting on it.
- **`SHEN_JIT_STATS`** prints collections and pauses (2026-11-01), then the live heap by type after a final collection (2026-11-02).
  That showed two thirds of the live heap at startup was kernel bytecode (707 of 1,113 KB); packed bytecode followed the same day,
  699 to 181 KB, and the image 1.22 to 0.70 MB.

### Saving programs

- **`--save IMAGE` and the single-file executable (2026-11-02).** An image saved with `-q` kept its `*hush*` and printed nothing. On
  macOS `codesign --verify` rejects an appended image, which matters only for notarized distribution.
- **`(shen-jit.save-executable Path Entry)` (2026-11-03)** writes a binary from inside Shen with no build directory, about 1.0 MB and 90
  lines of C. It never returns, as an image holds no frames, so it works from any depth.
- **Bug (2026-11-04):** it interned its entry-point symbol and kept only the cell. Nothing else reached that symbol, so a collection
  could free it, and the saved binary ran as the launcher. It reproduced at GC stress 1 and 10, and at 1000 on a release build.
- **Shebang scripts (2026-11-02):** the port's `read-file` drops a first line starting with `#!`; `read-file-as-bytelist` does not.

### Errors and messages (2026-11-02)

- **Errors name their values:** `"A" is not a number` where the message began with nothing, `undefined function foo`, `foo: expected 2
  arguments, got 3`. The printer stops after 60 bytes, which also ends a circular value.
- **Cost:** raising is unchanged, and quiet handlers build nothing. A handler reading the text of a failed `<-address` took 44 ns per
  raise, where the old message without a value took 17. The printer avoids `snprintf`, at 145 ns at first.
- **`SHEN_JIT_MAX_HEAP`** raises a catchable "out of memory". At the limit the last tenth of the heap is a reserve: without one, a heap
  full of live data left no room for the error, and the handler received `[]`.

### String escape CLI check (2026-11-07)

- Windows x86-64 CI failed only `escape-source`: its non-ASCII grep check rejected output that displayed
  the expected lambda and emoji. The same run passed all 1,088 eval-kl cases, including the UTF-8 byte
  values. The fixture also printed a standalone byte 233, which is deliberately preserved by `n->string`
  and is not valid UTF-8 by itself. A text search over that output is not a portable byte assertion.
- The fixture now prints byte lists as ASCII and checks exact lines for both source escapes and
  `read-from-string`, including preservation of byte 233. No runtime behavior changes. The fast tier
  passes on macOS arm64, including all 198 CLI checks; shell syntax and whitespace checks pass too.

### File read errors (2026-11-07, macOS arm64)

- Reading a directory returned an empty string or byte list, or -1 through `read-byte`, although stdio set
  its error indicator. `read_file` now checks that indicator after each `fread`, saves the error before
  closing, and frees its buffer before raising rather than returning partial data. The ordinary file
  path of `read-byte` checks it when `fgetc` returns EOF too. Actual EOF and empty files keep their results.
- Against the previous binary, four CLI regressions failed and the runtime test reported two failed checks.
  The CLI reads a directory through both whole-file helpers and twice through a stream on POSIX; a
  write-only stdio file exercises a failed read in the C runtime test without relying on directory opening.
  Empty-file tests check both whole-file results and repeated EOF. The fixed runtime passes its tests and all
  196 CLI checks. This changes error handling, with no performance claim.

### Bounded NDJSON batches and HTTP reader sizes (2026-11-07, M3 Max, macOS arm64)

Compared the existing one-row NDJSON source with a bounded batch producer, using the same executable,
100 SQLite counters, own-I/O connection path and 64 KiB reader for both arms. Three three-second rounds,
reversing case order in alternate rounds, after application warm-up; clients checked every completed
export. Production now retains one encoded row plus at most 16 KiB of output, additionally capped by
the sender's Maximum. It fills across row/newline boundaries, checks the deadline during construction,
remembers query exhaustion and never steps the statement again after EOF. HEAD and all cleanup paths
keep their existing rules. Invalid later rows or expiry can fail the first batch before output.

| Persistent export clients | One-row requests/s | Batched requests/s | p95 before / after, ms |
| --- | ---: | ---: | ---: |
| 1 | 1547 | 2168 | 0.672 / 0.487 |
| 8 | 900 | 1636 | 9.972 / 5.918 |

That is 40% and 82% more completed exports. The ordinary 100 short rows now fit in one data chunk,
instead of 100. Long rows still cross batch boundaries without losing UTF-8 bytes or newlines. No whole
query result list is collected. The prepared statement and database stay owned by the response source.

Separately compared 4/8/16/64 KiB readers through the new numeric `read-buffer-size` option, again three
alternating rounds. Eight clients measured 1 KiB GETs and 128 KiB binary POST/echo bodies with a 6 KiB
header, verifying every byte. Payload throughput below counts the body once per echo transaction.

| Reader, KiB | Fixed GET requests/s | Binary echo, MiB/s | Idle live input per connection, KiB |
| --- | ---: | ---: | ---: |
| 4 | 39502 | 702.6 | 9.2 |
| 8 | 39329 | 763.7 | 17.2 |
| 16 | 38528 | 792.5 | 33.2 |
| 64 | 35660 | 794.1 | 129.2 |

Selected 16 KiB: about 74% less idle input memory and 8% more fixed GET throughput, with binary echo
within 0.2% of 64 KiB here. The smaller capacities save more memory but cost bulk throughput. General
I/O reader defaults and HTTP head/body limits are unchanged. Larger messages span refills; one reader
still preserves pipelined input. Valid capacities are 1..65536, checked before socket adoption/bind.

Each size's 64-idle-peer hold returned exactly to its own live-heap baseline after drain/GC; every export
and body-throughput trial did too. The same runtime binary served all arms. Earlier attempts refused
host load above the guard; this recording began at one-minute load 2.99 and ended at 4.75, including its
own client/server work. No test suite ran during timing. These short macOS loopback comparisons do not
establish cross-platform or deployment capacity. Baseline source snapshots and hashes pin the comparison.

The required fast tier passes, including 634 HTTP checks. New cases cover one-byte and larger input
readers, coalesced chunked/persistent requests, invalid options, typed clients, export bounds down to one
byte, empty/limited queries, HEAD, invalid rows, deadlines, cleanup and every-allocation GC. Independent
HTTP/SQLite clients also check full 16 KiB batches split through long UTF-8 names, persistent reuse,
concurrent updates and shutdown. An intentional close with unread pipelined native input can reset the
peer and lose a queued response; small-reader fixtures separate that documented best-effort rejection
case from complete-input pipeline delivery. No runtime change or native adapter was needed.

### Persistent HTTP throughput and slow-client retention (2026-11-07, M3 Max, macOS arm64)

Measured the existing HTTP libraries without changing their implementation. Same-host Python asyncio
clients, three rounds of three-second intervals after warm-up, reversing case order in alternate rounds.
Every completed response was checked. The fixed route serves 1 KiB; the SQLite example has 100 seeded
counters and retains its per-request database/statement work. Medians below; p95 is the median of each
round's p95, including connection setup when closing each request. No request pipelining in these timings.

| Response / connection policy | Clients | Requests/s | p95, ms |
| --- | ---: | ---: | ---: |
| 1 KiB fixed, persistent | 1 | 15721 | 0.069 |
| 1 KiB fixed, close each | 1 | 4923 | 0.172 |
| 1 KiB fixed, persistent | 8 | 35626 | 0.224 |
| 1 KiB fixed, close each | 8 | 11912 | 0.734 |
| SQLite one counter, persistent | 1 / 8 | 7526 / 9210 | 0.148 / 1.009 |
| SQLite 100-row JSON list, persistent | 1 / 8 | 3324 / 2022 | 0.326 / 4.924 |
| SQLite 100-row NDJSON, persistent | 1 / 8 | 1548 / 894 | 0.665 / 10.118 |

Reuse gives 3.19 and 2.99 times the fixed-response throughput. The eight-client persistent trials range
35163..35669 requests/s, using about 1.12 server CPU cores and 0.67 client cores. List/export throughput
falls at eight clients; NDJSON performs one JSON/source/framing/write path per row. These measurements
do not isolate a single cause. Bounded row batching is a better next experiment than replacing readiness
or the scheduler. The unchanged executable was used throughout. Load began at 2.44 and ended at 3.89 on
this 16-core host, including the benchmark's own work. These short loopback results are not network or
production capacity claims; longer runs and Linux/Windows remain unmeasured.

A separate listener provided measurement control. A benchmark-only C procedure invoked the runtime's
post-collection census; RSS and CPU came from macOS libproc, with Mach CPU ticks converted through the
host timebase. Census/control work stayed outside throughput timing. All limits were explicit: 64 admitted
connections, 1000000 requests each, 30 s idle/write budgets, 300 s connection lifetime, 16 KiB producer
chunks and 128 MiB output-body bound. This raised the ordinary budgets for measurement, rather than
measuring accidental idle expiry. Slow readers used 8 KiB receive buffers and consumed 256 wire bytes per
50 ms, pausing client transport read-ahead. Each hold lasted three seconds before disconnect and drain.

| Held workload | Connections | Post-GC live heap, MiB | After drain, MiB |
| --- | ---: | ---: | ---: |
| No peers | 0 | 2.915 | 2.915 |
| Idle persistent | 16 / 64 | 4.934 / 10.989 | 2.915 |
| Slow streaming, 8 MiB source each | 16 / 64 | 4.759 / 10.239 | 2.915 |
| Slow streaming, 64 MiB source each | 64 | 10.158 | 2.915 |
| Slow fixed, 8 MiB body each | 16 | 132.939 | 2.915 |

All throughput and held workloads returned exactly to their own live-heap baseline after drain and GC.
Five repeated 64-peer idle/stream holds accumulated no reachable request/source state. Streaming memory
stayed near 10.2 MiB for 64 clients when configured total payload rose from 8 to 64 MiB each. Production
stopped at roughly 0.5..0.6 MiB per client in these socket/window conditions, so the full source was not
prefetched. Kernel socket queues are outside these heap/RSS figures. Idle input costs about 129.2 KiB per
connection: a 64 KiB reader and its pending 64 KiB scratch, plus state. The 64 idle peers consumed median
0.178 s CPU per three-second hold, against 0.009 s with none, about 6% of one core.

RSS did not return to startup size. A further 20 idle and 20 streamed waves returned to the same heap
baseline every time, with five file descriptors after drain and all 1280 stream sources closed once.
Native malloc in-use stayed around 2.3..2.5 MiB; RSS settled around 81 MiB idle and 102..103 MiB streamed.
The heap keeps its grown capacity, and native allocation/thread caches also contribute to resident size.
Three fixed-body waves left 313 MiB RSS with only 2.917 MiB live heap; after an explicit allocator-pressure
probe and another census, RSS was 56.6 MiB. The pressure API reported zero released bytes, so the evidence
is the observed RSS change, not its byte return. No runtime trimming change follows from this experiment.
The tests found no accumulating reachable HTTP state; they do not exclude every native leak or workload.

Healthy one-client fixed traffic measured 15710 requests/s alone, 15668 with 16 slow streams and 15779
with 48, all with p95 about 0.068 ms while admission slots remained available. At the full 64-peer cap,
a healthy connection stayed queued: releasing one slot after 0.5 s allowed completion at 0.516 s. With a
separate two-second write budget, all 16 slow sources closed after 2.000..2.001 s from source creation;
live heap returned to baseline while clients were still open. This is an observed cleanup bound under the
measured scheduling conditions, not a real-time guarantee.

Next experiments: batch NDJSON rows within the existing chunk bound; compare smaller HTTP reader
capacities before changing defaults; repeat on other platforms and with a separate load generator.
The current required fast tier, raw-record invariants and publication scan pass.

### Streaming responses and persistent HTTP connections (2026-11-07, M3 Max, macOS arm64)

Compared with the preceding complete-body, one-response connection path, responses can now pull bounded
chunks from a single-use Shen source. Explicit lengths require exact completion; unknown lengths use
chunked framing and emit the terminal chunk only on successful EOF. Header validation and one primed
chunk precede output. Short writes drain before another producer call, and one write deadline covers
production and output. Sources close exactly once on every path; cleanup failures retain prior errors.
HEAD/bodyless responses close without pulling, and saved sources never replay captured resources.

The listener retains one input reader per connection and dispatches complete requests sequentially,
including pipelined bytes. Request count, idle time and total lifetime are bounded. `deadline.within`
caps phase budgets without renewing the connection budget. The one-request helper remains available.
Any malformed body or failed output ends reuse; idle expiry sends no speculative response. Shutdown
observes idle workers in bounded waits, lets active responses finish during grace and cancels remaining
socket work. Statistics still count connections. All code stays in optional Shen libraries, over our
own I/O and existing threads/FFI; no runtime or native parser adapter was added.

The counter application streams up to 100 SQLite rows as NDJSON, retaining one encoded row and closing
its statement/database on HEAD, completion and failure. Slow exports can hold a read lock until their
write budget is observed; this example does not introduce WAL or pagination. An independent HTTP/SQLite
run verified streamed exports, repeated fixed/HEAD/chunked replies on one socket, 32 atomic increments,
persistence and shutdown with stalled request bodies. A separate wire client checked pipeline boundaries,
request/idle caps, application close policy, producer failure, timeout truncation and exactly-once cleanup.
These are correctness checks, not throughput or allocation comparisons.

The required fast tier passes, including 596 HTTP checks and injected-clock phase-cap cases. Coverage
includes managed short writes, early/late length errors, byte/chunk limits, cleanup errors, typed clients,
stale images, every-allocation GC, native pipelines and controlled shutdown. The guide, dedicated
streaming reference, server references and runnable examples were rendered and checked. Cross-platform
execution remains CI's responsibility; no new platform ABI or instruction was introduced.

### JSON values and chunked HTTP bodies (2026-11-07, M3 Max, macOS arm64)

- Promoted the complete-input JSON decoder to `lib/json.shen` and made the earlier example delegate to
  it. Added encoding, typed values, strict UTF-8/escape checks, ordered objects, duplicate-key rejection,
  explicit byte/depth bounds and exact integer conversion. Numbers retain their original tokens, including
  large values, negative zero and exponents, with no Shen-reader or implicit real conversion. The encoder
  also validates native-number output and refuses non-finite values and malformed value structures.
- Added a managed buffer builder with geometric capacity growth under a byte limit. Append copies its
  source; finish transfers storage and seals the builder. It serves JSON output and chunked bodies without
  repeated prefix concatenation. An image test exposed a Shen-specific tag mistake: a vector whose first
  field names a bound function uses it as a printer. The builder now uses a separate unbound record tag.
- HTTP accepts a single chunked coding, rejects CL/TE ambiguity, duplicate/reordered chunked coding and
  unsupported combinations, checks hex sizes before multiplication/allocation, validates token/quoted
  extensions and stores trailers separately. Protected or hop-by-hop nominated trailers are rejected.
  Decoded bytes, size lines, metadata and trailers have independent limits; one body deadline spans them.
  Failure remains terminal, preserves decoded progress/native details and releases accumulated payload.
- `io.peek-up-to` waits for availability and bounds the owned span it copies. Short chunk-size lines can
  inspect 64 bytes instead of copying the whole queued body or waiting for a full lookahead buffer.
  Bounded request bodies still finish in memory; streaming request/response APIs remain separate work.
- The SQLite example now uses the public JSON encoder throughout and accepts bounded JSON PUT bodies
  over fixed or chunked framing. It validates the media type, one integer field and its application range,
  uses parameterized transactional writes, and keeps malformed input from changing stored values.
- All 88 JSON checks and 497 HTTP checks pass, including typed builders/options, foreign storage, partial
  native failures, every small transport split, metadata limits, native loopback, images and GC before
  every allocation. The full fast tier passes. Independent checks cover 256 JSON decode/encode cases with
  number/string distinctions, the earlier 256-case example oracle, 32 HTTP wire cases including a chunk
  larger than the reader buffer, and JSON updates, persistence and concurrent SQLite operations.
- JSON has its own rendered reference linked from the guide; the HTTP, buffer and I/O references and
  application instructions describe the new contracts. Twelve documentation examples, the example launch
  and seven curl commands, rendered links and publication checks pass. This adds no runtime or C code
  and makes no comparative performance claim.

### Bounded HTTP admission, shutdown and a SQLite application (2026-11-07, M3 Max, macOS arm64)

- Added `lib/http-listener.shen` above the one-request handler: one supervisor owns the listener and
  registry, a configurable cap bounds workers, and each worker publishes one completion after cleanup.
  Admission waits in the existing OS backlog when full. Immutable snapshots retain aggregate counts,
  without keeping a growing history of completed connections. No runtime primitive or C adapter was added.
- Shutdown closes the listener, drains within one absolute grace budget, then flags remaining socket
  operations for cancellation. The endpoint owner closes its descriptor after returning from poll, so
  another task cannot close and reuse it during a native wait. Partial progress survives cancellation;
  replacing a deadline does not clear the cancellation flag. Supervisor waits use native sleep/poll
  intervals, with no spinning, channel, general task framework or new synchronization ABI.
- `http.wait` has its own bounded budget and reports pending work honestly. A handler or foreign call
  can outlive grace; it finishes cooperatively before worker completion. The runtime's catchable interrupt
  belongs to the REPL, while scripts terminate on SIGINT, so the runnable application uses an explicit
  local shutdown command. Signal-driven graceful shutdown remains separate work.
- `example-apps/sqlite-http/` is a persistent JSON counter API using public libraries, parameterized SQL,
  one SQLite connection per request worker and transactions for atomic increments. It has a quiet source
  loader, bounded lists/bodies, HEAD/method rules, database cleanup and a local POST shutdown endpoint.
  Application routing/schema/lifecycle stay in the example, with reusable admission in the library.
- All 64 new checks pass: 41 listener/cancellation/failure cases, a typed client, 20 application/rollback
  checks and 2 image/GC checks. The expanded test-http has 311 checks and the full fast tier passes.
  The independent Python HTTP/SQLite test verifies routes, 32 concurrent increments without lost updates,
  persistence across restart, a stalled body during stop and the real CLI's shutdown command. This is
  correctness evidence, without a comparative throughput claim. CI inherits these cases through test-http.
- The bounded-server API has its own rendered page linked from the guide; the application has launch,
  route and test instructions beside its source. Documentation examples, links and publication checks pass.

### Complete HTTP requests, bounded bodies and responses (2026-11-07, M3 Max, macOS arm64)

- Added `lib/http-request.shen` for a strict HTTP/1.1 origin-form/OPTIONS-star subset: owned metadata,
  ordered repeated fields, exactly one valid Host, bounded decimal Content-Length and explicit rejection
  of duplicate lengths, transfer coding, expectations, upgrades and ambiguous framing. Header limits
  include line lengths/counts. Body readers fill one bounded allocation and return a new complete request,
  preserving unread suffixes and remembering failure rather than restarting a partial protocol body.
- The largest fixnum exposed overflow in the kernel mod helper used to derive decimal bounds: it doubles
  a divisor past that range. The parser splits the rare large-bound calculation at 2^60, then checks each
  digit before multiplying. Max-length metadata and the immediately larger value now succeed/reject
  predictably without overflow. No arithmetic primitive or runtime change was needed.
- `lib/http-response.shen` validates all application fields before producing owned wire bytes. It supplies
  Content-Length and Connection: close, suppresses HEAD payloads, omits length for 204/304 and uses zero
  for 205. Framing fields and CRLF/control injection are rejected. Descriptions borrow body views until
  encoding; encoded output owns its bytes, including when the original source was read-only foreign memory.
- `lib/http-server.shen` handles one request on an owned socket with fresh absolute head/body/write
  budgets. It reads the bounded body before dispatch, sends an empty rejection or pre-output 500 on
  application failure, and never appends a second response after partial output. Original failure remains
  primary if sending a rejection or closing also fails. A native seconds clock and a Shen UTC formatter
  add Date when absent, with no locale or C tm-layout dependency. `tools/http-echo.shen` is the runnable
  echo/health example. There is no accept loop, task pool, chunked coding or connection reuse yet.
- `make test-http` passes 247 checks: 197 parser/body/response cases including every small transport
  split, 46 native connection/ownership/Date checks, a typed client and 3 image/GC/type checks. Cases
  include malformed/smuggling heads, binary bodies, truncation, HEAD/bodyless statuses, handler failure,
  partial output, foreign ownership and every-allocation GC. The independent standard-library HTTP client
  passes 19 wire cases, including slow input and rejection before a promised body is sent.
- The full fast tier, examples, rendered guide links and publication scan pass. CI and the Linux source
  tarball suites run test-http, with native cases explicitly skipped on static builds. The public API
  reference lives on docs/http.md, linked from the guide; pure parsing and encoding stay FFI-independent.

### HTTP head framing and operation deadlines (2026-11-07, M3 Max, macOS arm64)

- Added `lib/http-head.shen`: capture one CRLFCRLF-terminated block over our I/O reader, with an
  explicit 4..1048576 byte limit, one fixed accumulator and delimiter state carried across chunks.
  It scans incoming bytes once and leaves body/next bytes in the reader's one queue. New
  `io.peek-some` exposes the available span after waiting only for some input, avoiding a wait for
  a full buffer. Captures own their bytes and the accumulator is dropped on completion/failure.
- This is framing, not request syntax or HTTP body-length validation. Bare LF, CR without LF and
  inappropriate controls are rejected, but request lines, field names, Host and CL/TE semantics
  remain a complete parser's job. EOF inside a partial head is an error; failure is terminal for
  the capture. `tools/http-head-capture.shen` owns a connection for one timed capture and closes it;
  it sends no response and is not an HTTP server.
- `lib/deadline.shen` keeps one absolute millisecond endpoint with an injectable frozen clock.
  `lib/clock.shen` uses existing FFI for CLOCK_MONOTONIC (Linux/macOS) or GetTickCount64 (Windows),
  with integer millisecond conversion and no runtime change. Saved budgets reload stale. One task
  owns the budget and clock state. Clock resolution and scheduling do not provide a real-time bound.
- Socket policy checks that same budget before native attempts, on every poll slice and before FIN.
  Partial progress does not renew it. Timeouts keep the existing structured I/O result shapes with
  domain timeout and acknowledged totals. Reader timeouts are transient; a fresh budget permits
  retry. Writers retain their suffix for explicit retry, and full close performs cleanup despite
  expiry. A private backend-context slot holds the policy cell; ordinary endpoints default empty.
  Files, DNS/connect/accept, arbitrary blocking calls and cancellation are outside this deadline API.
- The new suites pass 17 fake-clock checks, 131 HTTP framing checks, 23 native timeout/progress
  checks, a typed client and 3 image/GC/type checks. Four core regressions also verify that a pending
  timeout behind queued input is reported before a later retry; consuming the prefix cannot discard it. HTTP checks cover every small-header split and
  truncation, limit boundaries, body preservation, invalid controls, transport errors and the total
  budget at completion. Native tests cover retries, timeout progress, flush retention and cleanup.
  An independent Python TCP probe passes normal, oversized and continuously slow input cases.
- The full fast tier, guide examples/rendered links and publication scan pass. Existing `test-io`
  includes these suites on every CI platform; managed cases run on static builds and unavailable
  native cases explicitly skip. HTTP framing and deadlines have separate pages linked from the guide.

### Binary framing and socket endpoints (2026-11-07, M3 Max, macOS arm64)

- Added `lib/frame.shen`: a two-byte tag and four-byte payload length, both big-endian, over the
  existing I/O reader. Decode the header once, reject the length before allocating a payload, then
  fill it across short reads. The reader's one bounded queue preserves following frames. Returned
  payloads own their bytes. Clean EOF is allowed only between frames; errors and EOF are terminal,
  and transport errors keep their native details with progress measured within the current frame.
- Added `lib/io-socket.shen` above the existing integer socket API. Adoption transfers ownership of
  an already connected, configured socket; it does not add a new connection/listener framework or
  alter that API. Native send/recv stay nonblocking with the VM lock held, and existing poll FFI
  calls wait in 100 ms slices with the lock released. Native error codes are captured before cleanup,
  through WSAGetLastError on Windows. Existing pointer invalidation protects saved socket identities.
- Write shutdown first drains the writer. Failure retains the pending suffix and leaves the write
  direction open; success detaches the drained writer and still permits reading a response. Explicit
  close remembers its result. Raw integer aliases remain outside this ownership protocol. There is
  no deadline/cancellation option, descriptor-inheritance change or concurrent-close protocol yet.
- `tools/frame-echo.shen` is the first complete connection handler over these pieces: echo each bounded
  frame, flush before accepting another, return a message count at EOF, and close on malformed input.
  Loopback tests send a 1 MiB frame and an empty message without waiting for EOF. This is a concrete
  framing workload, not a general parser compiler or a throughput improvement claim.
- The new checks pass: 51 framing cases, 33 loopback/ownership cases, a typed client, 3 managed
  image/GC/type checks and 2 socket image/GC checks. Framing covers every split and truncation point;
  native tests cover large transfers, half-close, failed flush, native errors and stale identities.
  The independent Python TCP oracle passes 3 binary wire cases using its own struct encoder/decoder.
- The full fast tier, guide rendering, examples, page links and publication scan pass. CI's existing
  `test-io` target includes the new suites, with native socket cases explicitly skipped on static
  builds. API references live on their own framing and socket pages linked from the guide.

### Independent bounded chunk I/O (2026-11-07, M3 Max, macOS arm64)

- Added optional `lib/io.shen` and `lib/io-file.shen`, over existing buffers and FFI only: no runtime
  changes and no kernel stream/file helpers. Memory sources snapshot input; fixed memory sinks borrow
  writable ranges. Native files use POSIX descriptors or Windows binary CRT descriptors with UTF-16
  paths. Opens prevent descriptor inheritance. Static builds keep the managed core and explicitly
  report that the file backend is unavailable.
- Per-endpoint capacities bound scratch copies, including the blocking FFI's copies when other threads
  run. Readers retain unread bytes and defer terminal errors until queued input is consumed. Returned
  chunks own their data. Writers distinguish accepted input from delivered output; failed flushes retain
  an offset into the pending suffix, so retries never replay acknowledged bytes. This is a correctness
  baseline with bounded copies, not a measured throughput improvement or zero-copy claim.
- A reader/writer leases its direction, preventing accidental bypass of queued data. Close flushes,
  invalidates the endpoint, closes once and remembers its result. Scopes preserve callback failure as
  primary and cleanup errors as secondary. File identities use existing non-memory pointers solely as
  descriptor guards: image loading zeros them before any old descriptor can be used. There is no GC
  descriptor cleanup, seek, socket adapter, pipe creation, cancellation or deadline promise yet.
- `make test-io` passes 153 checks: 97 scripted/memory, 1 typed client, 49 native/foreign, 2 independent
  byte comparisons and 4 image/GC/type checks. Native workloads cross multiple 64 KiB chunks and run
  while another thread repeatedly collects. A targeted image-loaded workload collects at every
  allocation. Tests cover partial transfers, no-progress writes, logical margins, read-only and dead
  owners, limits without losing the next byte, close/flush failures, native error capture and stale
  images. Windows uses path-conversion tests instead of bad-fd injection, which can abort in the CRT.
- The full fast tier passes, including 209 CLI checks and 70,304 override comparisons per mode.
  The API has its own `docs/io.md` page linked from the guide. Guide rendering and its examples pass;
  CI and Linux source-tarball suites run `test-io`, including explicit FFI skips on static builds.

### Buffer views and cursors (2026-11-07, macOS arm64)

- The API reference lives on its own `docs/buffers.md` page, linked from the guide and rendered with it.
- Added optional Shen-only buffer/cursor libraries over existing bytes and sized pointers, with logical
  bounds, shared original owners, copies, overlapping moves, content comparison and typed declarations.
  Cursor capture allocates before advancing; scans can use flat owner/start/end instead of per-byte records.
  Closing the original foreign owner raises through a retained view, including at an empty boundary.
- Complete JSON and big-endian packet examples exercise text/binary data without stream dependencies.
  JSON preserves number tokens, validates UTF-8/surrogates and rejects duplicate keys; framing checks the
  payload limit before capture. These are examples, not a general parser compiler or a throughput claim.
- `handle.close` kills its shared pointer before calling Release: a callback that freed storage and then
  raised previously skipped invalidation. The regression checks metadata before attempting another read,
  so it can fail against the old code without dereferencing freed memory.
- `make test-buffer` passes 72 managed checks, 73 format checks, 2 typed checks, 17 foreign/handle checks and
  4 image/type checks, including a targeted run collecting at every allocation after loading an image.
  Managed view/cursor state survives an image; foreign owners reload closed. CI runs this target on every
  platform, with foreign allocation cases skipped explicitly on static builds.
- The optional Python JSON oracle passes 256 generated cases (seed 193), independently decoding expected
  values and preserving numeric tokens. It includes UTF-8 boundary scalars, nested containers and escapes.

### Byte buffers and bit operations (2026-11-03)

- **Decision:** checked primitives on tagged values, with buffers as objects in the Shen heap, which the collector frees and saved
  executables keep. Raw slots in the bytecode, the first design, wait for a concrete need.
- **Numbers, per item:** `u8` in a Shen loop 1.36 ns, the same as `<-address`, against 2.02 for `pos` with `string->n`; FNV-1a 2.26; C,
  not vectorised, 0.32. The executable grew 24 KB, to 1.02 MB.
- **Memory outside the heap is a pointer with a length** (2026-11-05, M3 Max, not a quiet machine, on the same run). A new object type would have needed new cases in the collector, images, printing and the FFI, and pointers already load dead in images, have
  `pointer-kill` and go to C without a copy. A dead pointer has length 0, so the ordinary bounds check refuses it, with no branch of its own. **Inlined from the start:** a `u32` read in a native loop takes 1.47 ns against a buffer's 1.33, `u8` 1.46 against 1.29, `s32` 1.45 against 1.30 and a `u32` store 1.31 against 1.17, in about 20 lines of JIT, and a buffer's path keeps
  the instructions it had. Going through C was a shortcut considered for the first version, and not measured. `f64` calls C for both: 7.1 ns on a pointer and 7.3 on a buffer, in a loop that adds, against C's 0.68 for the same work. **Rejected:** unchecked access, as before, and raw addresses in slots. **Rejected:** freeing by the collector for now, as a weak list and collection pressure belong in a
  library of their own over this, later; `shen-jit.pointer-sized` will then need to keep the pointer it came from alive. **Raw frame slots, the first design, cannot work:** the collector scans the guest stack linearly, reading every word as a value, so a slot it should skip needs frame maps. If raw values come, they live only in code that neither calls nor allocates.
- **`f64` reads inline** (2026-11-05, M3 Max, load 2 to 4, not a quiet machine, against the binary before, in alternation, three rounds each). A read alone went from 5.1 ns to 1.56 on a pointer and from 5.25 to 1.43 on a buffer; in a loop that adds, from 7.0 to 3.4 and from 7.25 to 3.2, against C's 0.68. A real holds the word as it is in memory, so it takes about 10 lines of JIT and no floating point. What is left of the gap is the boxed add, through its C helper. `f32` needs a conversion, `s64` a range check, and `f64!` two cases for what it stores: they stay in C until something measures them.
- **`lib/mmap.shen`** (2026-11-05), in Shen alone, on macOS, Linux and Windows. **Rejected: `CreateFileA`.** It takes 7 arguments, one past what the FFI passes, and the C library's `_open`, `_lseeki64`, `_chsize_s` and `_close` make the flow the same on each system, with its messages too, so that only the mapping differs. They need `_O_BINARY`, or `_open` takes a Ctrl-Z off the end of a file opened to write, which a test now holds. **Rejected: a private writable mapping for `mmap.read`,** so that a store could not crash: its documentation charges all of the file to commit on Windows, and Linux's overcommit counts it too, which would refuse a file larger than memory, the main use. Not measured. What `mmap.read` gives is read only, below. Reading past the end of a file something has made shorter still ends the process, as no check could catch that.
- **Memory that releases itself: guarded pointers, and `lib/handle.shen` over them** (2026-11-05, M3 Max, load 2, not a quiet machine). `(shen-jit.pointer-guard P V)` copies P and holds V strongly; once nothing reaches the copy, a collection puts V on a list that Shen takes. About 60 lines of C, and the library is about 50 of Shen, with no change to any other collection: an empty list costs one loop over nothing, and a pointer is a word larger, for what keeps alive the pointer it was sized from. Made and let go, with 64 bytes behind it, a handle costs 134 ns against 50 for `memory.alloc` and `memory.free` alone, and 84 ns when closed by hand, over a million of them. **Rejected: running C's `free` in the sweep,** the smallest: it fixes one signature, while `munmap` needs the length, and nothing but C could release. **Rejected: bringing the pointer back from the dead, as Chez's guardians do,** which takes another drain, and puts in question a pointer already queued that another's value reaches. V as a root needs neither, as Go's finalizers do it: what one value uses outlasts it, at the price of V not being able to refer to its own pointer. **Rejected: finding V by searching the guards, for `handle.close`:** that same word of the pointer holds it, with no search. **Not built: releasing at a safe point on any allocation.** Only `handle.wrap` and `handle.sweep` release, as running Shen from an allocation would need a hook in every path that can collect. The 64 MB limit that brings a collection is a guess, not tuned. A frame can hold what an earlier frame left in a slot it has not written, which the tests had to work around by making what dies deep in the stack, and which holds for file streams already.
- **Read-only pointers** (2026-11-05). A size of 1 in the pointer's header marks one. A store's path back from `SLOW_POINTER` compares the whole header where a read compares its low byte, so it costs no instruction, on either path. **Rejected: a second length for stores,** which took a word per pointer for the same effect. **Rejected: a private writable mapping,** above. The header does make `=` see the difference, as compiled code compares headers first, so C now does too: a read-only pointer does not equal a writable one to the same address.
- **Reals inline** (2026-11-05, M3 Max, load 2 to 4, not a quiet machine, in alternation). `+`, `-`, `*`, `/` and the comparisons load each operand into a float register on the slow path, after the fixnum test fails, and allocate in line, which replaced three C helpers for arithmetic and the whole dispatcher for `/` and comparisons. A loop adding `f64` reads went from 3.4 ns to 2.65. `f64!` stores inline too. fib, list walks, string building and loading four libraries, timed old against new five rounds each, did not move, and the executable is 18 KB larger with everything in this section.
- **Raw loops, as real registers** (2026-11-05, same conditions). Five programs written for this, in `tests/bench/numeric*`, whose results match C's to the last digit (at first but for relaxation, whose C grouped its sum differently, since corrected), in seconds (`make bench-numeric`, C by clang -O2 -ffp-contract=off):

  | Program | C | Boxed, reals through C | Boxed, reals inline | Real registers | Registers against C |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | Matrix multiplication, 400 | 0.038 | 0.92 | 0.387 | 0.141 | 3.7 |
  | Mandelbrot, 400, 200 iterations | 0.0145 | 0.124 | 0.082 | 0.0166 | 1.1 |
  | Spectral norm, 500 | 0.0072 | 0.243 | 0.127 | 0.0306 | 4.2 |
  | N bodies, 64, 200 steps | 0.0011 | 0.075 | 0.0355 | 0.0087 | 7.9 |
  | Red-black relaxation, 512, 200 sweeps | 0.0225 | 1.70 | 0.62 | 0.262 | 11.6 |

  On the Windows machine (x86-64, gcc -O2): 0.156, 0.0196, 0.0392, 0.0104 and 0.370 against C's 0.0204, 0.0130, 0.0151, 0.0016 and 0.0236. Collections were about 6% of the boxed runs, so boxing costs its load, allocation and store, each read straight back, more than collecting. Mandelbrot, with no memory, comes close to C: what is left elsewhere is the checks on each access, a tag, a header, an index tag and a bound. **Float registers, not slots,** since the collector reads every slot as a value: raw slots would need frame maps. That confines them to code that calls nothing, which keeps the checker's rules short, and a C call that returns saves them to the native frame, so an allocation or a primitive in the loop is fine. About 200 lines of C and 250 of Shen, with no cost to code not using them. **Rejected: unboxing in the JIT, transparently.** A real known from `f64` or a constant could stay unboxed through a block, but `(* X X)` on a parameter is not known to be real, so Mandelbrot would gain nothing without two versions of each loop, and every function would pay for the analysis. **Not built: an instruction for a square root in Shen outside these loops.**
- **Word registers, and memory worked out once in a loop** (2026-11-05, M3 Max, load 2 to 13, not a quiet machine). 64-bit integers that wrap, for what a hash or a random number generator needs, turned out to matter most as indices: a word index has no tag to test and no overflow to check. And a loop's memory checked once, its base and lengths kept, drops the tag and header tests and two taken branches from every access. In seconds, the raw programs against C:

  | Program | C | Slot indices | Word indices | Words, memory kept | Against C |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | Matrix multiplication | 0.039 | 0.141 | 0.104 | 0.052 | 1.3 |
  | Mandelbrot | 0.0157 | 0.0166 | 0.0183 | 0.0185 | 1.2 |
  | Spectral norm | 0.0078 | 0.0306 | 0.0160 | 0.0154 | 2.0 |
  | N bodies | 0.0011 | 0.0087 | 0.0064 | 0.0030 | 2.6 |
  | Red-black relaxation | 0.0239 | 0.262 | 0.199 | 0.098 | 4.1 |

  On the Windows machine (x86-64, gcc -O2), whose word registers are all in the native frame: 0.0905, 0.0198, 0.0362, 0.0054 and 0.158 against 0.0203, 0.0130, 0.0151, 0.0016 and 0.0237. **The registers were there after all:** the earlier worry was that x86-64 has no saved registers to spare, but these need not be saved, as they are saved around C anyway. x86-64 has 2 scratch registers beyond the 5 the JIT uses, arm64 has 11, and Windows has none, since it counts more as saved. Past those a register is a place in the native frame, which SLJIT's operands make no different to write. **Kept: working out memory on the way in, for any loop,** which also takes a plain Shen loop over bytes in a pointer from 1.46 ns to 1.06 with no change to it. About 90 lines of C. It reloads wherever C has run, in `fill`, as a collection moves a buffer and anything may kill a pointer: each return from C that can do either goes through it, audited, and tests hold a buffer moving under a loop and a pointer killed during one. **Rejected: an instruction naming the memory,** which would raise on entry where a loop that never touches it now does not. What is not memory gets length 0 instead, and its first access raises as it did. Up to 4 per function, the first found. **Rejected: 32-bit operations of their own,** as a mask does it. **Real registers went from 12 to 48,** with those past the first 12 in the native frame, since a real program names more than that and the alternative was memory with its checks.
- **A real program: a path tracer** (2026-11-05, same conditions), `tests/bench/trace.shen`, written to use all of this and to find what is missing: a room of spheres, a xorshift64* generator in word registers, an image developed and hashed with FNV-1a, written through `lib/mmap.shen`, with buffers from `lib/handle.shen`. It produced the same image as `trace.c`, to the last bit, on its first run, in 0.585 s against 0.240, and 0.737 against 0.351 on Windows. Keeping memory saved 17% there, as a path is short: without it, 0.642 against 0.535 in the same binary. **What it showed is missing: a nested loop.** There is one `(loop)` per function, so testing spheres, bouncing and drawing a direction share one loop with a word saying which it is doing. That works, and it reads worse than three loops. Sound enough to add if another program asks: a slot's state at a loop head is already handled, and only the checker's rule and the JIT's jump target would change.
- **Loops within loops** (2026-11-05, M3 Max, load 3, not a quiet machine), as the tracer asked. `(loop L)` marks a head and `(again L)` jumps back to it, as many as a function wants, in place of the one `(loop)` that a self tail call came back to, which no release had. **Two forms would have been more to explain and check than one,** and a loop no longer repeats its parameters at each back jump. The JIT needed little: `dead_after` follows the jump back, and nothing else it does looks past a loop's head. So the rule that a slot written after the head counted as unset there went away, and a slot can now go round a loop. **Checked in one pass:** going back must bring everything set at the head, which is what makes one pass enough, and a head is reached only by falling into it or by `again`, so no state arrives there that the pass has not seen. It is what a Mandelbrot row needs, and what lets a whole program be one piece of native code, with no boxing between its loops. In seconds, the same programs, all their loops now in one function, against C: matrix multiplication 0.048 (0.038), Mandelbrot 0.0165 (0.0150), spectral norm 0.0139 (0.0075), N bodies 0.0028 (0.0012), relaxation 0.091 (0.0227), and the tracer 0.515 (0.227), where it was 0.585 with a boxed call per path. Each still matches C to the last digit.
- **A crash in memory kept for a loop** (2026-11-05), in no release, found by reading the code. A call to C that does not collect, which `=` makes on lists and vectors and `cn` on strings, saved and restored word registers and not the base and lengths kept after them, which C is free to overwrite. One buffer was spared, as its registers happened to be ones that C left alone. With four, `=` on two long lists read through a garbage base and segfaulted. They are saved with the rest now.
- **One comparison, and registers by how deep** (2026-11-05, M3 Max, load 3 to 4, not a quiet machine, and the Windows machine, x86-64, gcc -O2; medians of 5). The machine code of the relaxation's inner loop showed about 9 instructions for each access against C's 1 or 2: the base, the length and the index each moved to a work register, and two comparisons. So **memory reached at one width, and only at word indices, keeps limits in place of its lengths**, the first index without room for that width, which makes an access one comparison, with base and index used where they are. **The JIT gives out machine registers**, by use with each loop counting 8 times what is around it, across real registers, word registers and the base and limits of kept memory. That replaced the builder's count of uses, which knew nothing of depth and left kept memory what remained. **Code with loops and more raw integers than fit takes the saved registers its slots would have had,** which is what x86-64 needed: with nothing in a register to use, the first two gave it nothing, and the relaxation got slower. **On arm64 real registers get all 27 float registers,** not 12, as only the one entry from C saves the extra ones, which took the tracer from 0.43 to 0.35. An integer as an index now counts as a word index, or one constant field would keep its block from the single comparison.

  | Program | C | Before | Now | C, Windows | Before | Now |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | Matrix multiplication | 0.0386 | 0.0508 | 0.0438 | 0.0207 | 0.0900 | 0.0430 |
  | Mandelbrot | 0.0147 | 0.0161 | 0.0160 | 0.0130 | 0.0182 | 0.0181 |
  | Spectral norm | 0.0074 | 0.0141 | 0.0138 | 0.0148 | 0.0340 | 0.0323 |
  | N bodies | 0.0012 | 0.0029 | 0.0016 | 0.0016 | 0.0054 | 0.0029 |
  | Red-black relaxation | 0.0236 | 0.0929 | 0.0457 | 0.0237 | 0.1574 | 0.0581 |
  | Path tracer | 0.2247 | 0.5367 | 0.3685 | 0.3515 | 0.6649 | 0.5629 |

  Every result still matches C's. Mandelbrot is timed alone, as it moved up to 8% with what else ran before it, in both directions. Beyond its target: the benchmark suite's geometric mean was 1.00 over 66 rows with no result differing, its worst row, vector equality at 1.11, showed nothing timed alone, and the workloads never used for tuning stayed within 4%, the longest within 1%. **What is left against C is now mostly not the JIT's:** spectral norm with its conversions and literals named by hand takes 0.0079 against C's 0.0074 and 0.0138 as written, and clang merges the relaxation's 5 checks into 2 and vectorises most of its loop. Linux x86-64 was not timed; it has the same four registers as Windows.
- **Rejected: testing a loop's condition at its bottom** (same conditions), by repeating a head's word test at each `again`, as C does. On arm64 3% on the relaxation and nothing elsewhere. On Windows, a build with it took 0.053 on the relaxation against 0.058, and no other program differed. About 30 lines for one row.
- **Rejected: a shift for multiplying by a power of two.** It changed no program's time.
- **Rejected: sorting names by depth in the builder alone.** 7% on the tracer and nothing elsewhere, as kept memory still got no registers.
- **Rejected: removing checks that can be proved unnecessary.** With no check at all on these accesses, measured only as a bound, the relaxation took 0.0297 against 0.0442, N bodies 0.0013 against 0.0016, matrix multiplication 0.0357 against 0.0416 and the tracer 0.420 against 0.436, and the others did not move. An analysis would get part of that, for more machinery than all of the above. **C with a check per access is no measure of a check:** it took 0.0259 on the relaxation against 0.0224 without, which looked as if checks cost nothing, but clang had merged them.
- **Not tried: SIMD.** Without clang's vectorisation, C takes the relaxation from 0.0224 to 0.0265 and N bodies from 0.0011 to 0.0014, and matrix multiplication does not move. SLJIT has no float SIMD arithmetic, so it would mean encodings per architecture and a new kind of register.
- **macOS sanitizers** (2026-11-05): `(memory.alloc -1)`, which tests that an impossible size raises, reached AddressSanitizer's `calloc` on macOS, which aborts rather than returning NULL. `make test-san` now sets `allocator_may_return_null=1` for those suites.
- **Rejected for now: an unchecked mode.** The checks are 0.52 ns of a read in the tightest loop. No real program has shown it matters.
- **Rejected: writing them in Shen.** Only `bit-not`, `rotate32` and `bswap32` could move, freeing about 21 of 230 lines of C. `popcount`,
  `clz` and `ctz` take 9 to 11 ns against 2, and `bytes->string` built with `cn` is quadratic, about 64,000 times slower at 64 KB.

### Not tried yet

- **True parallelism.** `thread` is real threads, one at a time; parallelism is the more advanced case, for later. It needs allocation
  per thread, a stop-the-world handshake and locks around symbols, the JIT and dictionaries.
- **Waiting without the lock on files other than stdin.** A blocking read of a FIFO holds the lock, and Ctrl-C does not end it.
- **Built-in line editing:** vendoring `linenoise` (about 1,200 lines, POSIX only), used only when stdin is a terminal.
- **Backtraces:** a setting that captures at every raise, arguments in the output, and source positions, which means threading locations
  from the reader through the kernel's compiler.
- **A sampling profiler on Windows,** which could attribute about 6% of the kernel test suite that remains unexplained there.
- **Other platforms:** Windows on arm64 (SLJIT supports it; no machine yet), other architectures, and a static musl build.
- **Windows tests:** CLI cases for `\` paths and `PATH`, and non-ASCII text at the console.

## C FFI

Shen calls plain C functions, and C written for Shen takes and returns Shen values and calls back. Built on 2026-11-04 and
2026-11-05. Lines of code: 75 of C for nesting; 460 in `ffi.c`, about 110 elsewhere and 82 of Shen to call C; 333 in `ffi.c`,
about 30 elsewhere and a 140-line header for C written for Shen. Timings are from an Apple M3 Max.

### Who writes the glue (2026-11-04)

- **Both, kept apart.** `define-foreign` declares a plain C function with its conversions, as in Chez, with no C compiler.
  `define-foreign-procedure` declares C written against `shen.h`, as in OCaml, the only form that reaches Shen's values.
  One form joined by a raw `shen` type (Chez's `scheme-object`) was the most to specify.
- **Rejected: parsing C declarations (LuaJIT).** A C parser in Shen, and layouts per platform are still needed.

### The call

- **Chosen, 2026-11-04: one shared SLJIT stub, one C helper, casts.** A foreign function is a procedure type, taking
  the dead `T_PRIM`'s slot, entered through a stub like the arity and compile stubs. It calls `h_foreign`, which
  converts the arguments and calls through a cast that fills every argument register: 6 integers and 8 doubles. No
  code per signature, no new instruction, no dependency. POSIX needs 2 casts, by result type. Win64 fills registers
  by position, so it needs 32: 16 masks of which of the first four arguments are doubles, by 2 result types.
- **Rejected:**
  - An SLJIT stub per signature: `sljit_emit_icall` stops at 4 arguments, and `sqlite3_prepare_v2` takes 5, `mmap` 6.
  - libffi: a dependency to vendor and link statically, and expected to be slower per call. Not measured.
  - Assembly trampolines per platform: three calling conventions to maintain.
  - Only functions shaped `shen_value f(shen_value...)`, as in OCaml: `cos` would need a C wrapper.
  - Building on `prim` instructions: `vm->args` has five slots, so it would stop at four arguments.
- **Casting is not standard C.** GCC turns a call through an incompatible cast into a trap when it can see the
  target, which pointers from `dlsym` and `GetProcAddress` do not show it.
- **Tried before building, 2026-11-04.** 19 checks up to 6 integers and 8 doubles interleaved, plus `cos`, `pow`,
  `strlen`, `htons` and `socket`, on macOS arm64. An earlier form on Linux x86-64 and arm64. The mask table on
  Windows 10 with `ucrtbase` and `ws2_32`. All passed.
- **Variadics need their own casts.** Through the ordinary cast a variadic function returned garbage on Apple arm64.
  `(varargs N)`, integers only, exists for `fcntl`. Doubles and `printf` stay out.
- **No fast paths, by measurement.** A C helper behind `publish` costs about 2 ns a call (2026-11-04), so a foreign call's
  cost is its conversions and the C function: roughly 7 ns with nothing to convert, 10 ns for two integers and an integer
  or a double and a new double, 13 ns with a 16-byte string, at a load of about 3 (2026-11-05). A Shen call costs under 1 ns.

### Types (2026-11-04)

- **Named by width,** with no `int` or `long`. `long` is 32 bits on Windows, and a C `int` result leaves the upper half
  of the register undefined, so it must be declared `int32`. A `bool` result tests the low byte, all C defines.
- **An `int64` result past 62 bits raises.** A real would lose low bits silently, which is worse for handles.
- **NULL is `[]` both ways.** A pointer object with address 0 keeps `pointer?` true, but needs a `null?` of its own.
- **Strings are copied for the call.** A Shen string whose length is a multiple of 8 has no NUL terminator.
- **`T_POINTER` holds a kind and an address.** Rejected: a pointer as a fixnum, unchecked and saved silently in images.

### How C sees values

- **Raw `shen_value`, as in OCaml and Chez,** 2026-11-04. Rejected: JNI's handles (an indirection per access and a
  table), Lua's stack (index juggling in every function), Erlang's environments (Shen has mutable vectors).
- **A function table, tested against exports, 2026-11-04.** Exported symbols work on only one release configuration: static
  glibc gives `undefined symbol` with or without `-rdynamic`, and a stripped macOS executable exports nothing. Rejected:
  extensions linked statically (OCaml's `-custom`), a toolchain and a build per extension.
- **Written for a later collector,** perhaps like OCaml's. The header promises neither that objects move nor that they stay,
  stores go only through `shen_vector_set` and `shen_root_set`, where a barrier would go, and it names no layout beyond the
  fixnum encoding and a few constants. Its one assumption: the heap does not move while a thread holds the lock and makes no API call.
- **Reads never allocate or raise,** 2026-11-04. Raising allocates, so a read that raised could collect and invalidate
  every value in scope. A read of the wrong type gives `SHEN_NONE` or NULL.
- **Misuse ends the process by `_Exit(70)`,** 2026-11-05: `abort` means a crash report on macOS and perhaps a dialog on Windows.
- **Not stable until 1.0,** 2026-11-05. `SHEN_API_VERSION` says when `shen.h` has changed; from 1.0 the table only grows.

### Errors (2026-11-04)

- **By value: `SHEN_ERROR` and `shen_raise`,** as every helper works already. Rejected: `longjmp` (skips C cleanup, hard for
  C++ and Rust) and JNI's pending exception (the same checks, and a call made while one is pending must be defined).
- **A boundary handler, in place of a floor in `h_unwind`.** `shen_call` pushes a handler with no address; `h_unwind` pops
  it and returns NULL unchanged, so an error never jumps across C frames. `jit_call` itself stays without it, as a
  top-level call with no handlers must still count as uncaught.
- **A native stack bound per thread, in place of a depth count.** Nesting without end raises `stack overflow`.

### Roots

- **Locals: `shen_root` over the existing root stack, as `CAMLlocal`.** A procedure's arguments arrive rooted, and
  returning resets the count, so an early `return` is safe. Rejected: Chez's rule alone (nothing checks it) and API
  calls taking rooted references (more verbose).
- **So a rule covers evaluation order:** never nest two allocating calls. `shen_cons(vm, shen_cons(vm, a, b), c)` may
  read `c` before the inner call moves it. The runtime had this bug on 2026-11-04.
- **Long-lived: allocator-owned slots with create, get, set and delete, as in `ocaml-boxroot`,** 2026-11-04. One pointer
  that fits `void *`, in constant time. Rejected: registering a C variable's address (removal searches), generational
  global roots (no gain with this collector, and `shen_root_set` keeps them open), integer references (a lookup per
  access), pinning (a copying collector cannot pin small objects).
- **A root is three words: its table, its value and a link,** 2026-11-05, where a `RootArray` slot was planned.
  `shen_root_delete` takes no `vm`, so its wrapper needs the table from the root. The link cannot share the value's slot,
  as a thread deleting a root may run during another thread's collection, which writes the slot.
- **Why deleting needs no lock.** Delete pushes the root on one process-wide lock-free list by compare-and-swap, through
  its link, and touches nothing else. Whoever holds the lock swaps out the whole list at the next `shen_root_new` or
  collection. Until then the value is scanned as usual and just lives a little longer. So a root can go with no `vm` at
  hand, while the lock is released, from a thread of C's own, and later from a finalizer or a Rust `Drop`.

### Threads and callbacks

- **A foreign call holds the lock by default** (2026-11-04), so buffers stay put; `blocking` and `shen_release`/`shen_acquire`
  give it up. `blocking` copies `bytes` arguments out and back, as another thread's collection may move the buffer. Without
  the copies the test fails under stress on macOS arm64.
- **Callbacks: C trampolines with the closure in a root reached through `userdata`.** Rejected for now: a fixed pool of
  stubs, which LuaJIT limits to 500 to 1000. Generated stubs are under "Not tried yet".

### Images and static builds

- **Resolve lazily by name, at the first call,** 2026-11-04. A saved program finds its functions again, a pointer loads
  dead and raises when passed to C, and `save-executable` refuses nothing new. Rejected: refusing to save.
- **Static glibc `dlopen` works, but loads a second libc** (tried in Docker, 2026-11-04). So nothing `malloc`'d by one
  side is freed by the other, and no `FILE *` crosses, on Linux as on Windows.
- **Linux releases are dynamic on an old glibc; static ones stay beside them without the FFI** while they pay for their
  two archives, 2026-11-05. A call there raises `foreign: this static build cannot load libraries`.

### Bounded libcurl client (2026-11-08, Apple M3 Max, macOS arm64)

- Added optional `lib/curl.shen` and a small adapter, `lib/curl.c`, over the public C API.
  libcurl's write/header callbacks collect bounded native buffers while the VM lock is released;
  the adapter copies request inputs before release and creates rooted managed results after
  reacquisition. A plain FFI call to the default FILE writer would not give portable buffered
  results: Windows libcurl DLLs require a write callback with application-provided WRITEDATA.
- Reusable easy handles retain connections while every request resets its options and pointers.
  The independent Python fixture observed the same peer port across requests, then checked that
  POST data, custom fields and CA-file policy did not leak into subsequent requests. Final headers
  exclude interim/redirect blocks, trailers remain separate, and header budgets span all blocks.
  Binary uploads use explicit lengths; response bytes stay owned across request, close and images.
- A busy guard rejects overlapping request/close without invalidating an active transfer. Close
  invalidates the shared pointer while holding the VM lock, before native cleanup releases it.
  A fixture-controlled blocked response exercises this without depending on a timing race. A
  separate worker collects during a blocked binary POST, with collection on every allocation
  during result conversion. Saved clients are stale; saved responses remain usable.
- System libcurl 8.7.1 passed 109 checks, including pure validation, independent HTTP and HTTPS,
  certificate rejection and explicit trust, hostname checks, forbidden HTTPS downgrade, timeout,
  partial-body progress, collection limits, typing, executed reference examples, concurrent use,
  images/GC and the downloader. The downloader uses the independent file I/O library and does not
  touch an existing destination for transport errors or a non-2xx status. It buffers at most 16 MiB.
- The fast tier and `make test-san` pass. Both the adapter and runtime were instrumented for the
  native fixtures with AddressSanitizer and UBSan. This is macOS evidence; CI now builds and tests
  the adapter on dynamic Linux and Windows too, and explicitly skips it on static builds. The
  source/build script are shipped; a freshly extracted binary archive built the adapter and passed
  its native fixture/downloader checks. There is no automatic compilation when loading Shen code.
  `docs/curl.md` is its own rendered reference page. No throughput or retained-memory comparison
  was made. Streaming sinks, multi transfers and cancellation remain separate work.

### SQLite and sockets (2026-11-05)

First libraries, to test whether declarations cover real use: 128 and 206 lines of Shen with no C.

- **`shen-jit.pointer-kill` was the one addition.** Closing a database twice would have crashed in C.
- **Sockets are always non-blocking,** in place of a blocking `recv`. The wait is in `poll`, in 100 ms slices with the lock
  given up, so no buffer is copied and Ctrl-C ends it: within 100 ms on macOS and Linux, 92 ms through a Windows console.
- **`bytes` passes a buffer's start, so `socket.send` copies through a 64 KB chunk.** 100 MB on loopback ran at about
  3 GB/s, so the copy is not the limit. An offset type waits for a profile.
- **A SQLite connection belongs to one thread.** Apple's build is in multi-thread mode and `sqlite.step` gives up the lock.

### Bugs found while building it

- **2026-11-04, a leaf's frame not reserved.** Leaves skip the stack check, so a nested call near the end of the stack
  wrote past its block: one bus error in about 6,000 runs. Guard Malloc then named the writer at most alignments.
- **2026-11-04, C roots shared by threads.** The new test crashed in 3 runs of 3 under stress, and passes 3 of 3 per thread.
- **2026-11-05, Apple clang merged a `switch` over three variadic casts** into one call with the last's type:
  `var_one(3, 1, 2, 3)` read 3, 0, 0. Each is now a function of its own, not inlined.
- **2026-11-05, a string result pointing into a byte argument** (`fgets`) could move while the string was made.
- **2026-11-05, stale values show only sometimes:** after an even number of collections an old pointer is back inside the heap.
- **2026-11-05, release archives left out `lib/` and `include/`,** so a binary could not have loaded `lib/ffi.shen`.
- **Whether the tests can fail, 2026-11-05.** Not resetting roots on return, not scanning `shen_root_new`'s roots and not
  rooting arguments each end the run under stress.

### Not tried yet

| Left out | Estimated lines of C | What would bring it back |
| --- | ---: | --- |
| Callback stubs from SLJIT, like `foreign-callable` | 120 to 150 | A wanted library without `userdata`, such as `qsort` or some GUI toolkits |
| Finalizers on pointers, over a weak list | 40 | Leaks in a real program, or Rust's `Drop` |
| Structs by value, `float`, variadics with doubles | 100 each | raylib, for instance; a C wrapper costs ten lines meanwhile |
| `peek`/`poke` beyond `pointer->bytes` | 30 | A library that needs writing through pointers |
| Inlined or `noalloc` calls | 150 | A profile with the 2 ns helper call on top |
| Embedding, a `shen_startup` | 100 | Someone asking for it |
| C threads calling in, like `caml_c_thread_register` | 80 | A library calling back from its own threads |
| Interrupt polling from C | 15 | A long C loop that matters |
| Rust bindings: a crate on the table, as in `ocaml-interop` | - | Wanted eventually; reads and root deletion were kept ready for it |
| Shen streams over sockets, buffered line reading | - | Real use; `T_STREAM` holds a `FILE *`, and Winsock has no `fdopen` |

Not run as of 2026-11-05: static musl, upstream clang's function sanitizer on the casts (Apple clang 17 does not check),
the old-glibc container on GitHub's runners, and sockets beyond loopback.

## Datalog

### The first version (2026-11-07, Apple M3 Max, against SWI-Prolog 10.0.2)

`lib/datalog.shen`, about 900 lines of code with its plain evaluator, needing no other library. Chosen as the first application library because it depends on nothing else and has
independent oracles.

- **Shen forms, no textual syntax.** Variables are already Shen's, and a program stays data. Soufflé's notation would have
  needed a parser for no gain yet.
- **Generated KL only, no plan interpreter.** Two execution paths would be more code, and compiling is cheap: for the program behind the kernel call
  graph, 20 functions, 0.008 ms to check and plan and 0.11 ms to generate and install, each over 500 rounds, and its first run takes 0.36 ms more than the next, which is the JIT.
  So a one-shot query pays nothing to speak of, and no interpreter was built to compare.
- **Functions, not closures, for loops.** Each atom's loop is a named function, a self tail call taking what it passes on as parameters. They are named per
  program and layout, so they are bounded and show in a backtrace. Closures were not measured.
- **Packed tuples, kept.** Against vectors, in ms, packed then vector: closure over 3000 random edges (1,388,324 tuples) 287 to 348, 386 to 642;
  dense closure 14, 21.5; nonlinear closure 785, 1465; same generation 26, 40; a skewed join (2,222,705 tuples) 329, 560; the call graph 18, 24. A vector must
  stay for wide relations, so both exist; the cost is a form for each of tuples, columns and keys. Rounding the bits to 12, 20 or 30 lets shifts and masks be immediates
  and bounds the layouts a program meets to four.
- **Retained tuples did not call for a byte-buffer engine.** 177 MB resident at 1,388,324 tuples, with one index. Not needed for anything measured.
- **Not tried:** telling new from old tuples in the atoms around the one read as new. Nonlinear closure makes 41,142,395 derivations for 88,803 tuples, which is where it would help,
  and is the slowest row even so.
- **The bug tests found:** a relation could appear several times in its component, and merging it again wiped its new tuples, losing results. All layouts agreed and the fixtures
  by hand passed; only generated programs against the reference showed it, in about 3% of them.
- **Does it notice?** 13 planted bugs, one at a time, each failed `make test-datalog`, from a missing second round to a dropped filter. It takes 0.23 s, and 62 s under `SHEN_JIT_GC_STRESS=1000`, which passes.
- **Against an engine sharing nothing:** SWI-Prolog's tabling agrees on 300 generated programs (3,787 tuples), and on the larger workloads. Soufflé was not available.
- **Its speed, as a reference.** Evaluation alone, with the same programs and facts, in ms, ours then SWI-Prolog's: skewed join (2,230,489 tuples) 357, 517; mutual recursion (3,032) 0.8, 1.8; sparse closure (1,391,323) 280, 1,002;
  dense closure (90,292) 16, 84; nonlinear closure (90,292) 806, 7,695; same generation (52,332) 28, 262; triangles (1,506) 0.4, 13.6; the call graph (132,214) 20, 701. Ours is `datalog.run` and reading every tuple back, best of 3, by wall clock, with interning the facts included.
  Theirs is every table and every answer enumerated with printing removed, the middle of 3 fresh processes, by CPU time, leaving out 14 to 44 ms of startup and loading. Not like for like: tabling is a general mechanism working top-down inside a full Prolog, the rules ran as written
  there while ours reorders joins, and hand-ordered Prolog was not tried. The call graph's gap may come from one table for each bound first argument, which was not measured. The rows closest together spend their time hashing and allocating tuples.
- **The call graph:** 731 functions and 4,730 calls from the kernel's KL give 125,617 pairs reached in 48 rounds, in 18 ms.

### Choosing join order while running (2026-11-07, Apple M3 Max, against the fixed plans before)

The idea is Carac's (Adaptive Recursive Query Optimization, ICDE 2024): sizes change round by round in a recursive query, so no fixed order stays right, and regenerating code during a run costs little here, at 0.11 ms a program. It needs rules with many atoms, as a transitive closure has nothing to reorder. Tried on Andersen's points-to analysis over generated statements, with the rules' atoms in two orders.

| ms, order a / order b | Small: 75,267 `vpt` | Large: 177,585 `vpt`, 681,172 `hpt` |
| --- | --- | --- |
| Fixed, most columns known next | 853 / 334 | 12,448 / 1,438 |
| Sizes, planned once at the start | 849 / 1,070 | 12,278 / 14,776 |
| Sizes, planned again when one doubles | 281 / 340 | 1,218 / 1,606 |

- **Kept.** Re-planning takes a written order that costs 2.6 to 8.7 times as much down to about what the better one costs: on the large row 15% faster than the better fixed order on one row and 12% slower on the other. Planning once from the sizes at the start does not help, since most tuples do not exist yet: it is what happens as the relations grow that matters.
- **The written orders were a surprise:** the one first written as the good order, by hand, was the bad one, 2.6 and 8.7 times worse. That is the case for not asking.
- **Nothing lost elsewhere.** Closures, same generation, the call graph and the skewed join are within about 5% of before. Mutual recursion makes 15 plans, one each round, in under a millisecond.
- **Rejected:** counting an index not yet built as dearer, which favours indexes already there, took the large row from 136 ms to 275 and 1,460 ms at factors 2 and 4 on an earlier form of this workload. Re-planning only on a factor of 4 or 8 instead of 2 did no better, from 135 to 158 and 179 ms.
- **What is left:** indexes stay once started, so a plan change can leave one maintained and unused. The tuple counts show what storage work remains: 13,391,521 derivations for 177,585 `vpt` tuples.
- **Checked** against a separate evaluator in Python, written from the analysis's definition, on the large row in both orders, and against the reference on 300 generated programs under both kinds of plan. SWI-Prolog's tabling ran out of its default table space on this analysis after 75 s, in order b; a larger space was not tried.

### Flat storage (2026-11-07, Apple M3 Max, against the dictionaries and lists before)

A profile of the first version put 60 to 64% of the time in `sj_dict_put`, 13 to 17% in the insert path around it, 10 to 13% in the collector copying tuples, and 1 to 3% in the generated joins, so that a better code generator could have gained almost nothing. A prototype first: deduplicating in a flat table written as a native kernel cost 10 to 32 ns per derivation, the loop aside, against 17 to 159 ns for the dictionary, with the table sized in advance.

Now a tuple is u32 columns in a byte buffer, new tuples are a range of it, and tables are open addressed with their hash's top half in each entry. Packing tuples into one integer, kept above, is gone with its layouts: every arity is the same code, and a column is read straight from the buffer. Generated kernels need `lib/native.shen`, which adds about 31 ms to a program's load.

| ms | Before | Flat |
| --- | --- | --- |
| Closure, sparse (1,388,324 tuples) | 277 to 333 | 154 to 177 |
| Closure, dense (88,803) | 15.5 | 9.4 |
| Nonlinear closure (88,803) | 820 to 858 | 483 to 491 |
| Same generation (46,678) | 27 | 20.5 |
| Skewed join (2,222,705) | 331 to 566 | 131 to 134 |
| The kernel's call graph (125,617) | 20 | 10 |
| Points-to, small, orders a and b | 281, 340 | 192, 219 |
| Points-to, large, orders a and b | 1,218, 1,606 | 742, 807 |
| Mutual recursion (15), triangles (17) | 0.7, 0.4 | 0.8, 0.4 |

- **The collector has nothing left to do:** 0.3% of CPU on the closure against 7 to 13%. 140 MB resident at 1,388,324 tuples against 177 MB. This reverses the note above that retained tuples did not call for a byte-buffer engine: true if fast enough is the goal.
- **Where the time goes now:** on the closure and the join, the insert kernel 50 to 55% and rehashing 13 to 25%, with allocating and zeroing buffers about 10%. On points-to, insert 50%, find 14%, the generated loops about 20%.
- **Fingerprints hide bugs from small tests.** Values in a run are small and dense, and a multiplicative hash spreads them without collisions, so a kernel that trusted its fingerprint passed everything. It takes 300,000 random tuples, over the kernels directly, and an index on a column of full 32-bit values. Three planted bugs of that kind are what showed this; with those tests, each is caught, as are 8 others planted in growth, chains, merging and starting indexes. A ninth other, a scan reading what its round adds, changes no result, as derivations are monotonic.
- **Not tried:** sorted arrays merged each round, in place of the tables; Free Join; keeping the two columns of a small tuple in the table entry, which would avoid reading the buffer on a repeat; native join loops; growing tables by more than double, which would trade memory for rehashing.
- **Checked** against SWI-Prolog on 300 generated programs and on three larger workloads (51,834 to 132,214 tuples), against the Python evaluator on points-to, and under `SHEN_JIT_GC_STRESS=1000` in 57 s without the kernel test, whose allocation is too much there.

### Kernels with structured control (2026-11-07, Apple M3 Max, against the same kernels with labels)

Insert, find, index and rehash are written with `while`, `for`, `when`, `unless`, `exit` and `and`, from `lib/native.shen`, in place of labels and jumps: 65 lines where there were 99, and no label left. Five runs each, in alternation: closure 115 to 124 ms against 123 to 131, the skewed join 121 to 126 against 120 to 128, small points-to 160 to 163 against 158 to 164, within noise. Fingerprint bugs planted in the structured kernels are caught as before.

### Native joins (2026-11-07, Apple M3 Max, against the same joins as KL)

The first real use of `lib/native.shen`'s structured control from a generator rather than by hand. Each join order is one kernel: a `for` for a scan, a probe and a `while` along the chain for a lookup, the head's insert inline, and a KL function around it that grows the head relation when the kernel says it is full and calls it again. 206 lines of code, beside the KL generator, which stays for what does not fit.

| ms, two runs each, later runs | KL joins | Native |
| --- | --- | --- |
| Closure, sparse (1,388,324 tuples) | 117 to 122 | 82 to 101 |
| Closure, dense | 9.0 to 9.3 | 5.9 to 6.8 |
| Nonlinear closure | 464 to 467 | 207 to 230 |
| Same generation | 19.2 to 19.7 | 11.8 to 12.6 |
| Skewed join (2,222,705) | 121 to 124 | 88 to 100 |
| The kernel's call graph | 9.7 to 10 | 7.3 to 8.1 |
| Mutual recursion, triangles | 0.7, 0.3 | 0.7 to 1.1, 0.3 |
| Points-to small, orders a / b | 177 / 264 | 115 / 171 |
| Points-to large, orders a / b / c | 780 / 1,027 / 1,032 | 506 to 536 / 717 to 720 / 670 to 728 |
| Chain of four joins, orders a / b | 17.4 / 17.4 | 16.7 to 18.4 / 16.9 to 18.4 |

- **Kept.** 1.2 to 2.2 times as fast where joins do the work, and the same where loading facts does. Nonlinear closure gains most, as it is 41 million derivations of which almost all are repeats, each now a probe without a call.
- **Compiling costs more:** a four-rule program run over three facts, compiling every plan each time, took 0.90 ms against 0.25 with KL joins, 200 runs each. A run that makes 46 to 66 plans, points-to, shows no difference in its first run.
- **A variable costs no register,** being read from its column at each use, and nothing showed a cost in that: a column read is one load from a buffer the kernel holds.
- **Restarting.** A kernel cannot call to grow a relation, so it returns where its outermost scan stood, plus one. A first version resumed an inner scan's position when the plan began with a lookup, and so skipped tuples: 1 generated program in 300 found it. Only a scan at the first level resumes now; anything else starts again from the beginning, which repeats derivations and nothing else.
- **Register limits.** Every name is a register, live for the whole kernel, and 16 word registers is the most: a four-atom chain needed 17 and fell back to KL, until the insert's offset temporary went, recomputed instead. Temporaries used only within one step share names across steps, which the generator must know is safe. With that, no plan in the tests or workloads falls back; a wider one would, correctly, and `datalog.*fallbacks*` counts them.
- **What the structured forms did well:** a step's statements nest inside the previous step's loop, so the generator is a fold over the plan with no label bookkeeping; named loops let a probe or an insert exit itself inside any depth; the expander drops joins that cannot be reached, so the checker's refusal of unreachable code never came up.
- **What they lacked:** reuse of registers by liveness, the one limit hit. An empty `and` is true, which let a scan with no checks generate a needless `when` until the generator left it out. Neither called for a change to `lib/native.shen` yet.
- **Checked** against the reference and against the same programs with KL joins on 300 generated programs, against SWI-Prolog on 300, and on a plan that begins with a lookup and grows its head partway through an inner scan. Results on every workload match the KL joins' tuple counts.

### Stratified negation (2026-11-07, Apple M3 Max)

`(not (edge X _))`, with every variable in it bound by a positive atom. A relation cannot depend on the negation of one that depends on it, which the checker refuses, naming the rule; so what is negated is in an earlier component and complete when read.

- **No new machinery for order:** a negated relation is a dependency like any other, so the components already put it first. A negated atom is a condition like a comparison, placed as soon as its variables are bound, and a probe of the relation's table, of an index for some columns, or of its size for none. The probe loop that lookups had became one function that member, chain and negation share.
- **The reference stays apart:** it numbers strata from the rules, by a fixed point of its own, and runs each in turn, where the engine uses its components.
- **Generated programs** sometimes add a negated atom of bound variables, constants and `_`, and drop negations from the last rules until the program is stratified: 59 of 300 keep one, all with two strata or more. They agree with the reference, with KL joins and with SWI-Prolog, which reads it as `\+` since the relation is complete.
- **Planted bugs:** a negation that ignores a match fails 13 checks, and an empty test inverted fails 4. Dropping one key's equality from the probe passes everything, as no fingerprints collide among small interned ids: the blind spot noted for the table kernels, which a test with full 32-bit values would close.
- **Nothing lost:** the workloads, which have no negation, are within noise of before.

### Arithmetic, and integers as themselves (2026-11-07, Apple M3 Max, against the negation commit)

`(+ A B)`, `(- A B)` and `(* A B)` on either side of a comparison, and `(= D (+ D0 W))` binding `D` when nothing else has. A binding is a condition that becomes ready once what it reads is bound, and may make others ready, so the planner looks again until nothing more is; atoms after it can look the variable up. Division was left out, as a kernel would have to check for zero, and nothing asked for it.

- **Integers stopped being interned.** Arithmetic makes values no table holds, and a kernel cannot intern. An integer column now holds its own 32 bits, as Soufflé's does, and only symbols and strings are interned. This removed the table of integers that native comparisons read, and limits integers to 32 bits, signed, which the checker enforces on facts and constants.
- **Overflow raises everywhere alike.** Each operation is checked to be 32 bits, by the reference too, so that a 64-bit intermediate can never wrap unseen. In a kernel each result goes to a word register, the second operand of each in the register after the first's, so a few registers serve any depth; outside 32 bits, it returns a code above any place to start again from, and the KL around it raises. Which of a rule's conditions runs first is the planner's choice, so a rule whose filter would have failed may still raise.
- **Fingerprints, again.** With full 32-bit values, a test of 150,000 random tuples, most keys absent, compares native joins with KL joins on lookups, members and negations. Dropping the key check is now caught in each probe: 11, 14 and 6 wrong tuples. It needs keys of two columns: for one, the fingerprint of a 32-bit value almost determines it, so no collision showed and the check matters little there.
- **Generated programs** sometimes bind `K` to arithmetic on what the body binds, kept between -4 and 4 so that recursion ends, and sometimes compare an expression: of 300, 131 bind and 64 compare. They agree with the reference, KL joins and SWI-Prolog, which reads a binding as `is`.
- **Speed:** facts load faster, with no integers to intern: the four-join chain 12.3 ms against 17, mutual recursion 0.4 against 0.7. Points-to, three alternating pairs on a loaded machine, 546, 544, 579 ms before against 533, 620, 614 after on the large row, which is within the noise there. The other workloads are within noise.
- **The suite** takes 1.5 s with the larger test.

### Aggregates (2026-11-07, Apple M3 Max, against the arithmetic commit)

`(= N (count (edge X _)))`, `(sum W Atom)`, `(min W Atom)` and `(max W Atom)`. The keys are the atom's variables that appear elsewhere in the body, decided by the checker from the rule as written, so that no plan can change what is grouped. Over no tuples, count and sum give 0, and min and max give nothing, so the rule does not hold: Soufflé's choice, and SWI-Prolog's `aggregate_all`.

- **The same shape as negation:** the relation aggregated must be complete, so it is a dependency in an earlier stratum, refused in a cycle. An aggregate is then `=` with a fold for its right side: it binds its variable once its keys are bound, or compares when that is bound already.
- **Native, no fallback:** a kernel folds into a register of its own, over a loop for no keys, a probe of the relation's table for a whole tuple, and an index's probe and chain for some columns; the probe loop is the one lookups and negation share. min and max start just outside 32 bits, where nothing leaves them. A sum is checked once, at the end, as a check of each partial sum would raise or not by the order of the tuples. Six aggregate rules of the tests compile to six kernels.
- **Grouping by free variables was left out:** Soufflé's and SWI-Prolog's `aggregate_all` count every match of the atom, which a relation of sets makes each tuple once; grouping is by what the rest of the body binds.
- **Generated programs** sometimes add an aggregate with keys, constants, `_` and variables of its own, which may repeat; a rule with one is dropped whole when the program would not be stratified. Of 300, 44 keep one, 5 of them comparing. They agree with the reference, KL joins and SWI-Prolog. Planted, a min that keeps the larger fails 5 checks and a chain that skips its update 19.
- **Nothing lost:** the workloads, with no aggregates, are within noise of before.

### An analysis of the kernel's call graph (2026-11-07, Apple M3 Max)

A workload that uses what the last three entries added, on the same 731 functions and 4,730 calls as the call graph: what is dead (negation), what calls nothing and what is called but never defined (negation with `_`), fan-in and fan-out (count), the hubs with 20 callers or more, each function's call depth from a root bounded at 12 (arithmetic), and the shallowest (min). Eleven rules, 27 rounds, 25 plans.

- **Agreed** with the reference on the whole graph, in 1.3 s, with KL joins, and with a version written by hand for SWI-Prolog, on all 4,332 tuples of its nine relations.
- **Its time is loading:** 1.9 ms a run, of which 1.3 ms is interning and storing the facts, which a program with no rules takes alone; the rules take about 0.6 ms. KL joins take 1.9 to 2.0 ms, so native kernels gain little here, where the relations are small. Its first run takes 4.3 ms against 2.9 with KL, which is compiling 25 kernels.
- **So what would help such an analysis** is loading, not joins: interning symbols through a dictionary, one fact at a time. Not tried.
- **Under GC stress,** with negation, arithmetic, aggregates and native joins, `make test-datalog` passes all 3,943 checks under `SHEN_JIT_GC_STRESS=1000` in about six minutes, with the fingerprint test cut to 3,000 tuples. At 150,000 it did not finish in 15 minutes: each collection copies the facts it holds.

### Against Soufflé (2026-11-07, Apple M3 Max, Soufflé 2.5 from Homebrew)

The same rules and facts, written out for Soufflé; every result it finished matches ours. Its compiled programs are built from the C++ it generates with the flags of its own compile script, as that script's include paths fail in Homebrew's bottle. That bottle has no OpenMP, so Soufflé ran on one thread, as we do, and it keeps 64-bit values where we keep 32. Times in ms, best of three: ours is `datalog.run` with facts as a list, and Soufflé's its process less the same with no facts, which is its startup, about 15 ms. Building took it 3.0 to 3.7 s a program.

| ms | Ours | Soufflé compiled | Soufflé interpreted |
| --- | --- | --- | --- |
| Closure, sparse (1,388,324 tuples) | 129 | 429 | 551 |
| Closure, dense | 9.6 | 36 | 49 |
| Nonlinear closure | 501 | 673 | 1,373 |
| Same generation | 21 | 53 | 77 |
| Mutual recursion | 0.8 | 0.2 | 1.1 |
| Triangles | 0.3 | 0.1 | 0.3 |
| Skewed join (2,222,705) | 160 | 104 | 192 |
| The kernel's call graph | 11 | 44 | 57 |
| Points-to small, order a / b / c | 191 / 215 / 189 | 1,394 / over 100 s / 211 | 2,945 / over 100 s / 363 |
| Points-to large, order a / b / c | 704 / 804 / 665 | 16,525 / over 100 s / 860 | 35,200 / over 100 s / 1,403 |

- **Soufflé joins in the order written,** and orders a and b, made up for testing our planner, are bad for it. Order c is how points-to analyses are written. Its profile-guided schedule, statistics taken on the small case and applied to the large one, gave about 1,090 ms from order a and from order c, against 860 for order c as written.
- **So on one thread:** ours is ahead on the closures, same generation, the call graph and points-to, 1.3 times Soufflé's best schedule there, and behind on the skewed join, at 1.5 times its time, and on runs under a millisecond.
- **In parallel,** with Soufflé 2.5 built from its release source with OpenMP from Homebrew's libomp and 32-bit values, as ours. Its parallel code is generated only when `-j` is given then, so programs are generated with `-j auto` and run with each count. Compiled, its startup taken away, ms, on a machine whose load was 3 to 4 from other work:

  | ms | Ours | 1 thread | 4 | 8 | 12 |
  | --- | --- | --- | --- | --- | --- |
  | Closure, sparse | 125 | 389 | 170 | 159 | 157 |
  | Closure, dense | 10.6 | 34.5 | 13.6 | 11.2 | 10.6 |
  | Nonlinear closure | 514 | 585 | 163 | 87 | 62 |
  | Same generation | 21.6 | 47.4 | 15.9 | 11.2 | 9.2 |
  | Skewed join | 132 | 102 | 26.7 | 19.7 | 16.6 |
  | The call graph | 11.9 | 42.9 | 23.4 | 29.9 | 29.2 |
  | Points-to small, order c | 193 | 197 | 63.6 | 45.4 | 40.5 |
  | Points-to large, order a | 691 | 15,238 | 4,045 | 2,126 | 1,491 |
  | Points-to large, order c | 685 | 770 | 257 | 193 | 168 |

  On 12 threads it is 2.3 to 8.3 times our time on nonlinear closure, same generation, the skewed join and points-to as written, about even on the dense closure, and behind us on the sparse closure, the call graph, whose recursion goes deep and narrow, and a badly ordered rule. Its build with 32-bit values is also a little faster on one thread than the bottle's with 64. One thread runs Shen at a time here, so this is the gap that stays.
- **Not measured:** its magic sets.

### Loading facts (2026-11-07, Apple M3 Max, against the commit before)

The call-graph analysis spent 1.3 of its 1.9 ms loading 5,463 facts, and timing the parts showed interning was not most of it. Each fact looked its adder up by a name built from its arity and interned, 482 µs in all; its relation's slot by position in a list, 120 µs; and checked itself apart from encoding, 112 µs. Interning and encoding took about 420 µs.

- **Done:** a dictionary per run gives each relation's record, types and adder, and values are checked as they are encoded, with `datalog.check-fact` called only to say what is wrong. Loading takes 736 µs against 1,310.
- **Measured:** the analysis 1.1 to 1.2 ms against 1.8, and the four-join chain, 60,000 facts, 5.9 to 6.0 ms against 12.3. Points-to is joins, and did not move.
- **Left:** interning, about 40 ns a value through `shen.dict`. A table of its own would take more code than this is worth now.

### Adding facts (2026-11-07, Apple M3 Max, against full runs)

`datalog.add` gives what a run of every fact would, going on from the database it is given, which it changes. Each relation's size before the facts is its mark. A component that reads only relations that grew goes on semi-naively, with one variant of each rule for each atom of such a relation, reading what is past its mark; one that negates or aggregates a relation that changed, or reads one that was evaluated again, is emptied to its facts and evaluated again; the rest stay. The database keeps every fact for this.

| ms, best of five | Full run | Adding 10 | Adding 1 |
| --- | --- | --- | --- |
| Closure, sparse (1,388,324 tuples) | 82 to 84 | 5.0 | 4.0 |
| The kernel's call graph | 7.0 | 1.7 | |
| The kernel analysis | 1.06 | 0.30 | 0.17 |

- **The first add can build an index** the full run never needed: the closure's new edges look `path` up by its second column. A second add of 1 to the same database took 2.4 ms and of 10 1.9 ms, with new paths derived over 33 more rounds.
- **Not done:** removing facts, which would need counting or deleting and rederiving; a new run does it. Recomputing only the part of a component that a change reaches.
- **Checked:** every fixture and generated program also runs with its facts in three parts, a run and two adds, against the reference: 4,943 checks. Planted, a delta of only the last round fails 89, a negated change treated as growth 20, facts not given back to a component evaluated again 102, and growth not passed on 4. A sum that passes 32 bits on the way between adds raises then, as the database it would be does.

### Removing facts (2026-11-07, Apple M3 Max, against full runs)

`datalog.remove` takes facts out of those the database keeps and evaluates again, in order, each component that holds a relation that lost one or reads one evaluated again. Storage never deletes. This was chosen over deleting and rederiving, which would be faster for a small removal from a large recursive relation but needs storage that can delete: tombstones, with a check of each tuple in every native scan and probe even for programs that never remove, or compacting each relation after a removal. Neither is built; compacting would keep the kernels as they are.

| ms, best of five | Full run of what is left | Removing 10 | Removing 1 |
| --- | --- | --- | --- |
| Closure, sparse (1,361,567 tuples left) | 88 | 84 | |
| The kernel's call graph | 6.0 | 6.6 | |
| The kernel analysis | 1.09 | 1.49 | 0.66 |

- **About a full run of what it reaches:** a removal from a relation everything reads costs a run, and up to 1.4 times one on the small analysis, where finding the facts that go, about 250 µs with a dictionary keyed by fact, and loading each component's facts again show. A removal that reaches less costs less.
- **Checked:** every fixture and generated program also removes its middle third and adds it back, against the whole result, and every generated program compares the removal alone with the reference over the facts left: 6,839 checks. Planted, readers not evaluated again fail 10, removed facts given back 609, and no relation counted as losing one 609.

### Against Soufflé again, with native joins (2026-11-07, Apple M3 Max, the same builds of Soufflé 2.5)

The same comparison after native joins and arithmetic, the same builds and settings, so that only our side changed; load 2 to 2.4, and 6 by the end of the parallel run. Every result Soufflé finished matches ours. Ms, best of three.

| ms | Ours | Ours before | Soufflé compiled | Soufflé interpreted |
| --- | --- | --- | --- | --- |
| Closure, sparse (1,388,324 tuples) | 99 | 129 | 429 | 562 |
| Closure, dense | 6.2 | 9.6 | 37.5 | 50 |
| Nonlinear closure | 239 | 501 | 673 | 1,376 |
| Same generation | 11.7 | 21 | 54 | 76 |
| Mutual recursion | 0.5 | 0.8 | 0.2 | 0.3 |
| Triangles | 0.2 | 0.3 | 0.0 | below its startup |
| Skewed join (2,222,705) | 110 | 160 | 103 | 189 |
| The kernel's call graph | 8.3 | 11 | 44 | 56 |
| Points-to small, order a / b / c | 131 / 155 / 136 | 191 / 215 / 189 | 1,398 / over 100 s / 224 | 2,956 / over 100 s / 370 |
| Points-to large, order a / b / c | 475 / 545 / 449 | 704 / 804 / 665 | 16,512 / over 100 s / 946 | 35,618 / over 100 s / 1,487 |

- **On one thread** we are now ahead everywhere but the skewed join, at 1.07 times Soufflé's time where it was 1.5, and the runs under a millisecond. Points-to as analyses write it, order c, is 2.1 times as fast as Soufflé's compiled program.

In parallel, the OpenMP build with 32-bit values:

| ms | Ours | 1 thread | 4 | 8 | 12 |
| --- | --- | --- | --- | --- | --- |
| Closure, sparse | 95 | 403 | 179 | 161 | 156 |
| Closure, dense | 6.3 | 36.5 | 13.1 | 11.2 | 10.3 |
| Nonlinear closure | 243 | 601 | 162 | 86 | 64 |
| Same generation | 11.7 | 48.1 | 15.2 | 11.1 | 9.3 |
| Skewed join | 103 | 100 | 26.7 | 16.5 | 15.6 |
| The call graph | 8.4 | 40.7 | 24.6 | 29.9 | 30.8 |
| Points-to small, order c | 132 | 195 | 65.4 | 45.8 | 40.5 |
| Points-to large, order a | 493 | 15,355 | 4,054 | 2,132 | 1,494 |
| Points-to large, order c | 536 | 792 | 260 | 192 | 165 |

- **On 12 threads** Soufflé is now 1.3 times our time on same generation, 3.3 on points-to as written, 3.8 on nonlinear closure and 6.6 on the skewed join, against 2.3 to 8.3 before. We are ahead on both closures now, the dense one included, on the call graph and on the badly ordered rule. Our points-to large, order c, read 536 ms here and 449 on the one-thread run, as the load rose during this one.
- **What is left is threads:** at one thread each, only the skewed join is behind, and the gap on 12 is what Soufflé's parallel joins give it.

### Old tuples in the other atoms of a rule (2026-11-08, Apple M3 Max, against the commit before)

A rule with several atoms of its own component had a variant for each, reading that atom's new tuples and all tuples of the others, so a combination of tuples that were new together was derived once for each of them. Nonlinear closure, `(path X Z) <-- (path X Y) (path Y Z)`, made 41,142,495 derivations for 88,803 tuples and was the slowest row. Now the variant of the first atom to read a new tuple derives such a combination, and the component's atoms before it read only the old tuples, from before the round's new ones: a scan stops where the new tuples begin, a walk along an index's chain skips them, which is cheap as a chain runs from the newest, and a probe of the table ignores them. About 30 lines of code more.

| ms | Before | After | Derivations before, after |
| --- | --- | --- | --- |
| Nonlinear closure (88,803 tuples) | 221 to 228 | 154 to 157 | 41,142,495, 26,376,080 |
| Points-to small, order a / b | 129 to 131 / 152 to 155 | 107 to 111 / 139 to 145 | `vpt` 5,427,412 / 5,381,929, 3,731,744 / 4,499,143 |
| Points-to large, order a / b / c | 519 to 533 / 634 to 636 / 499 to 521 | 468 to 478 / 600 to 613 / 471 to 475 | `vpt` 15,152,158 / 15,073,805, 11,433,013 / 13,072,769 |

Nonlinear closure is `make bench-datalog`'s later runs; points-to is three runs of each, alternating, at a load of 2.8.

- **Kept.** Nonlinear closure now makes exactly its edges plus, for each node, the paths into it times the paths out of it: each combination once. Against Soufflé's compiled program on one thread, the same build as before: 142 ms against 671, where it was 239 against 673, and points-to large in order c 415 against 916. Points-to gains 5 to 17%, least in order b, which keeps more derivations. Workloads with one recursive atom per rule are as before, as nothing changes for them.
- **The first round halves too:** it reads every tuple as new, so every variant but the first used to make the whole join again; the atoms before now read nothing there.
- **Rejected: estimating an old atom by its old tuples alone,** in the planner. The same derivations on every row and times within the noise, alternating three times, and points-to started one more index.
- **Tests had to count derivations.** Reading too much changes no result, only repeats work: of 7 bugs planted that way, none failed a check, and of 3 that read too little, all did (39 and 11 checks, and a crash). Three programs now check derivation counts, a lookup's chain, a scan and a probe each, with KL joins within one per growth of the exact count and native kernels within what starting again after growing repeats; each of the 7 fails one. Checked against the reference, KL joins, adds and removals on 300 generated programs, and SWI-Prolog's tabling on 300.

### Records and types of several constructors (2026-11-08, Apple M3 Max, against the commit before and Soufflé 2.5)

Soufflé has records and algebraic data types. Here a type is `(type shape [circle point integer] [rect point point] [blank])`, a value a list headed by its constructor, `[rect [pt 1 2] [pt 4 6]]`, and in a rule, brackets are a record, taken apart in a body atom and made in a head or by `=`. About 290 lines of code, of 2,270.

- **Decided: a record is interned, in a table of its type's.** The table is a relation like any other, of u32 columns: the constructor's number and the fields, as many as the widest constructor has, the rest 0. A column of the type holds the record's position there. So tuples stay packed u32 of one stride, an index or a probe needs nothing new, equal records are equal words, and code that uses no records is the same as before. Soufflé interns records too.
- **Rejected before building: records inline,** their fields flattened into the tuple's columns. A fixed width per type allows no recursive type, and a variable width breaks the one stride a relation's kernels assume. **Rejected: Shen values as opaque interned values,** through the dictionary that interns symbols: a kernel cannot intern, so a rule could neither make nor take one apart. **Not tried: taking records apart by a join** with the type's table, keyed by position, which would reuse the planner, but probes an index for each record where a load reads its field.
- **Taking apart reads, making interns.** A body atom reads a field from the record's position, one load, after checking its tag when the type has more than one constructor: a field of another constructor may be an integer, and read as a position it would be outside the table. So a kernel's checks are in column order and short-circuit, and KL takes records apart with a `let` only after the `if` of its tag. A head, `=` or a lookup's key whose variables are all bound makes the record as a head adds a tuple, inline, found or added; with no room it returns to grow, now every table the kernel adds to. A lookup of a record never made adds it, as Soufflé's does: wasted room, never a wrong answer. A negated record cannot hold `_`, as a negation probes by its keys and does not match the rest; that limit kept it small.
- **Speed,** routes as lists along a random graph, 3,000 nodes, 12,000 edges and 100 starts, bounded at 7, giving 536,345 records in `route` and 11,787 tuples of `second`, which takes two apart: 54 to 64 ms, 131 to 138 with KL joins, against 290 to 320 ms for Soufflé's compiled program, its whole process, which agrees on both counts. Every record rule in the tests and that workload compiles to a native kernel.
- **Nothing lost:** the workloads, which have no records, are within noise, three alternating runs. Loading facts, which now dispatches records too, took 4 to 9% longer at first, from passing a failure value back through each column and then from a sixth argument; written as before, with the record clause guarded by `cons?`, it is within about 2%, at 4.11 against 4.04 ms for 60,000 integer facts and 7.44 against 7.31 for symbols, best of four at a load near 3.
- **Tests:** fixtures by hand, and generated programs: every one now has a type of two constructors whose fields are not records, so that its values are finitely many, and of 300, 185 have a column of it, 150 records in rules and 123 records made in heads. They agree with the reference, KL joins, adds and removals, and with SWI-Prolog's tabling, which reads records as compound terms, on all 300. Planted, a missing tag check fails 31 checks natively and 8 in KL, a field read one off 30, a found record's position plus one 16, a wrong tag when loading 36, records read from the tag's column 16, a KL position plus one raises, and tables of made records left ungrown hang. Counting an unpack's bindings as what it uses changes nothing, as KL binds them again.

### Queries by demand (2026-11-08, Apple M3 Max, against whole runs and Soufflé 2.5's magic sets)

`(datalog.query Name Facts (depends a X))` gives what `datalog.ask` would of a run, deriving only what bears on its constants, by magic sets. The program is rewritten for the query's adornment, which columns a constant binds, once, and kept with it; a relation reached positively gets a copy per adornment, guarded by a magic relation of the values asked for, and the magic relations pass bindings along each rule in the order the planner would choose with no sizes. About 130 lines of code.

| ms | Query, first | Query, later | Run and ask |
| --- | --- | --- | --- |
| Closure, sparse: `(path 1774 X)`, 1,174 answers | 1.5 to 3.5 | 0.3 | 115 to 117 |
| Closure, sparse: `(path X 7)`, 1,207 answers | 75 to 82 | 74 to 75 | 116 |
| Call graph: `(reaches X =)`, 626 answers | 1.8 to 2.0 | 0.9 | 11.1 |
| Call graph: `(errors shen.yacc-syntax)` | 3.2 | 1.1 | 8.1 |
| Call graph: `(reaches shen.repl X)`, 511 answers | 8.0 | 6.9 | 10.5 |
| Kernel analysis: `(dead X)`, `(depth F D)` | 1.8 to 2.2 | 0.9 to 1.0 | 1.2 to 1.3 |

- **Kept.** A selective query costs a fraction of a run: 400 times less for one node's paths, 12 times for what reaches `=`. The first query of a pattern rewrites and compiles, 1 to 3 ms. A query loads its facts afresh each time, which bounds the gain on the small analysis, whose run is mostly loading.
- **Where it gains little:** `(path X 7)` demands the paths into every node that reaches 7, which in a graph this connected is most of `path`. That is magic sets, not this code: Soufflé's take 431 ms there, against its 664 without them, and ours 75.
- **Against Soufflé,** the same facts, its compiled programs, startup taken away, best of seven: `(path 1774 X)` 1.3 ms with `--magic-transform=*` against 0.3 here, warm, and 422 ms without the transformation. Its transformation did not apply while the answer fed a count, as the query was first written, so that form showed no gain at all; `--show=transformed-datalog` explained it.
- **Complete relations are whole:** a relation read under a negation or an aggregate keeps its own rules, with all it depends on, and no copy reads it. Copies of it would need demand through the negation, which also risks a cycle through negation in the rewritten program; computing it whole is always stratified and correct, and the analysis rows show it costs little where those relations are small.
- **Not done:** demand for a database that `datalog.add` keeps current. A query is a run of its own.
- **Checked:** fixtures with recursion, mutual recursion, negation, aggregates, records and constants in heads, and on each of the 300 generated programs a query of a random relation, with constants, repeated variables and `_`, against the reference. Planted, copies never read fail 20 checks, copies without their relation's facts 133, negated relations not made complete 2, a magic rule passing its head's values in place of its atom's raises, and an adornment reversed is refused by the checker. Leaving out what a complete relation depends on passed until a fixture negated a relation whose own dependency is derived; it fails that one now.

### More functions in rules (2026-11-08, Apple M3 Max, against the commit before)

Integer `/` and `%`, truncating toward zero as C and Soufflé do, `band`, `bor`, `bxor`, `bshl` and `bshr`; on strings `cat`, `strlen`, `substr`, `to-number` and `to-string`; and the `mean` aggregate, truncated. About 150 lines of code.

- **Division and strings stay KL.** A kernel has no word division, and cannot intern a string it makes. Division natively would be a new instruction in the JIT, which on x86-64 must also keep a zero divisor and the most negative number divided by -1 from trapping, and the checker of hand-written code would have to enforce that; for the rare rule that divides it was left out, by Wirth's rule. So a plan that divides, takes a mean, works on strings or shifts by other than a constant from 0 to 31 is generated as KL from the start, and is not counted as a fallback. Bit operations by constants stay native. Over 200,000 tuples: `(* X 3)` 14.9 ms natively and 17.1 as KL, `(band X 1023)` 13.5 natively, `(/ X 3)` 30.6, about 75 ns a division by long division in Shen, as there is no truncating division to call; most of the rest is loading the facts. 20,000 `cat`s take 5.9 ms and `strlen`s 4.5, loading included.
- **No value, not an error.** Division by zero and `to-number` of what is not an integer first raised, as overflow does. The reference evaluates a rule's bindings before its comparisons, and the planner promises no order either, so `(!= B 0)` could not guard `(= Q (/ A B))`: the first fixture raised. Now they give `[]`, never a value, and a binding or comparison that meets it does not hold. Overflow still raises: there the value exists and 32 bits cannot hold it.
- **Shifts are total:** `(bshl A B)` is A times 2 to the B, rounded down, a negative B shifting the other way, so that no count is undefined; overflow raises as for `*`. `substr` keeps what of its range the string has.
- **Not done:** real numbers, as columns are 32 bits.
- **Checked:** fixtures against tables computed in Python, every evaluator agreeing, and generated programs whose arithmetic now draws from all ten integer operations, a divisor sometimes 0, and whose aggregates include `mean`: of 300, 17 to 25 use each operation and 1 a mean. They agree with the reference, KL joins, adds and removals, and with SWI-Prolog, which reads `/` as `//` behind a guard that the divisor is not 0, `%` as `rem` and mean as a sum over a count. Planted, a quotient rounded down fails 12 checks, `band` as `bor` 16, an unsigned `bshr` raises, an undefined assignment bound to 0 26, `substr` from 0 6, and strings left out of the values vector raise. Division by zero as 0 and a mean rounded down passed until two fixtures were added: a remainder with no guard and a mean of negative numbers; they fail 6 and 5 now. The workloads, which use none of this, are within noise.

### Equivalences by union-find (2026-11-08, Apple M3 Max, against the same closure as rules and Soufflé 2.5's eqrel)

`(relation same [symbol symbol] equivalence)` holds the reflexive, symmetric and transitive closure of what it is given. Its record holds a union-find, each value's root and each root's members; merging a round's tuples joins their classes, the smaller into the larger, and adds the pairs that makes, which the next round reads as new. About 55 lines of code.

| ms, random graphs of 3,000 nodes | 1,500 links | 2,500 links | 3,000 links |
| --- | --- | --- | --- |
| Pairs in `same` | 45,401 | 3,922,045 | 5,727,183 |
| The closure alone, union-find | 8.7 | 728 | 1,134 |
| The same as three rules | 73.7, 3,560,604 derivations | not run | not run |
| Soufflé's eqrel, alone | 1.1 | 1.2 | 1.4 |
| With a join reading it twice, union-find | 10.7 | 1,244 | 2,016 |
| The same, Soufflé | 8.2 | 787 | 1,335 |

- **Kept: the pairs are stored.** Kernels, indexes and deltas need nothing new, and deltas are exact, the pairs a join made. Against the closure written as rules it is 8.5 times as fast on small classes, which derive each triple, and classes of thousands, at billions of derivations, finish at all.
- **Not done: storing classes and not pairs,** as Soufflé does (done later, under "Equivalences as classes"). Its closure costs nothing to speak of at any size, where ours spends about 190 ns a pair adding both directions from Shen: 1.1 s for a class of 2,400. Joins that read the pairs pay for them either way, 1.6 times Soufflé's time here. Storing classes would need new code for every kind of step a kernel takes, scans, lookups, probes, negation and folds, natively and in KL, and deltas of their own. A cheaper step, if large classes come up in real use: a kernel that adds a class's pairs from its members in bytes, which might take a third of the time.
- **Demand** computes an equivalence whole, as it does what is negated: a copy of it would not be closed.
- **Checked:** fixtures with facts, rules into an equivalence, congruence closure through one, adds and removals and demand queries, and generated programs that sometimes declare a relation of two columns of one type an equivalence, 31 of 300, against the reference, which adds the three rules, and SWI-Prolog, given the same rules. Planted, pairs added one way fail 283 checks, no reflexive pair 311, only the first new tuple joined 257, demand copying an equivalence 1, and members or roots of the smaller class left behind raise.

### The order of the gaps, and fact files (2026-11-08, Apple M3 Max, against Soufflé 2.5)

- **Reordered:** choice and subsumption, which keep one tuple per key, lattices, which keep the least upper bound per key, and deleting and rederiving all need a tuple to be replaced or deleted, where storage only grows. They come later and together, so that one decision about storage serves all three; fact files, provenance and index sharing do not depend on it and come first.

`(datalog.read-facts Name Rel Path)` and `(datalog.write-facts Db Rel Path)`: a line a tuple, fields apart by tabs, or by commas with RFC 4180's quotes for a `.csv` path, each field read as its column's type says, records as Shen reads them. About 120 lines of code.

| ms | Ours | Soufflé compiled |
| --- | --- | --- |
| Reading 1,388,324 lines of two integers, 12 MB | 163, and 171 to load | 309, loading included |
| Writing them | 455 | |
| The kernel's 4,730 calls, two symbols, read and written | 1.2, 4.5 | |

- **Fields are byte ranges until their type is known:** integers are parsed from the bytes and only symbols, strings and records make a string. Making a string for each field and parsing integers from it took 457 ms to read the same file.
- **Writing is bounded by the runtime:** `pr` writes a string a byte at a time, finding its end by an error caught at each character, and `write-byte` costs about 19 ns a byte; joining lines into chunks before writing changed nothing. Building the lines takes about a third of the time. A primitive that writes a buffer at once would remove the rest; the I/O library writes through the FFI, which Datalog does not load.
- **A tab-separated file refuses what it cannot hold:** a tab or a line break in a field raises when written, as reading it back would split the line.
- **Checked:** round trips of symbols, strings with commas, quotes and tabs, integers at both ends of 32 bits and records of two constructors, in both formats; carriage returns and blank lines; and errors naming the line for a wrong field count, a bad integer, a record of the wrong shape and an unknown relation.

### Explanations (2026-11-08, Apple M3 Max, against the commit before)

`(datalog.explain Db Tuple)` gives a proof: a rule as written and a proof of each tuple its atoms read, down to the facts given. About 75 lines of code.

- **Nothing recorded per tuple.** Soufflé's provenance stores a rule and a height with each tuple, which here would be two more stores in every insert of every kernel and 8 more bytes a tuple, paid by every run for an occasional question. Instead each merge has a number, larger than any before it, and a relation keeps the numbers of the merges its tuples came in, a list as long as its rounds. A round derives only from tuples merged before it, so for a tuple that is not a fact, a rule instance whose atoms' tuples were all merged strictly earlier exists, the one that derived it; the search finds one and explains its tuples the same way, which ends, as the numbers fall, and never goes round in a circle. Explaining searches the relations it touches: 86 ms for a path among 1,388,324, and 228 ms for a call depth in the kernel analysis, where each step reads the whole of `calls`. An index by bound column would cut that; for a question asked by hand it was not worth the code.
- **Probes read what scans read.** A probe of a relation's table, for a whole tuple, also saw tuples added earlier in the same round, so a derivation could read a tuple merged with it, and no strictly earlier instance need exist. Probes now stop at the merged tuples, as scans and chains do, and a tuple found only that way is derived in the next round instead. Triangles, all probes, took 10.3 to 11.1 ms against 10.0 to 10.7, within the noise; workloads without probes are unchanged. No test could show it was needed: in the shapes tried, eight namings of a rule that probes a relation an earlier rule of the same round adds to, the component's order merges the probed relation first, and explanations hold without it. It is kept so that the order holds by construction, and not by that.
- **The test suite** had grown from 2.1 to 6.8 s with queries by demand, which ran the reference evaluator over a chain of 60 nodes, cubic, once per query, and compiled kernels for a rewritten program on each generated query. With a chain of 25 and the generated queries on KL joins, which compile faster and test the rewriting as well, it takes 3.0 s, explanations included.
- **Checked:** every tuple of nine fixtures, four of each relation of each of 300 generated programs, and a tuple after an add, explained and the proof checked against the reference: each rule instance holds there, conditions included, down to the facts. Planted, allowing an atom's tuple from the same merge overflows the stack in a circular proof, reading a range's merge one place off and not taking facts first find no derivation, and ignoring conditions fails 13 checks.

### Index sharing, rejected (2026-11-08, Apple M3 Max)

Soufflé chooses a few sorted orders so that one serves several searches: an order on columns (a, b) answers a search on a. Here an index is a hash table on a set of columns, with a chain per key; it cannot answer a search on fewer columns, but an index on fewer columns could answer one on more, with a check of the rest on each tuple of the chain. Separately, indexes stay once started, so one that a re-plan stops using is still kept up as its relation grows.

- **What there is to gain:** building and keeping up every index, timed around each merge's indexing, took 8.0 to 8.7 ms of points-to's 480 to 790 ms in its three orders, 1.0 to 1.8%, with 10 or 11 indexes over five relations, two of them on `hpt`, by its first column and by its first two; 0.03 ms of the sparse closure's 90 and 0.5 of the nonlinear closure's 152.
- **Rejected:** sharing could save at most that, and would make every lookup that used a narrower index walk a longer chain, checking the columns it lacks, which is the inner loop. Dropping indexes a re-plan leaves unused saves part of it, at the price of building one again if a later plan wants it. Neither is worth the code while upkeep is under 2%. Memory is where sharing would show: `hpt`'s second index holds 681,172 chain entries and a table of 2 million slots, about 19 MB, which nothing measured has made a problem.

### One tuple a key: min, max and choice (2026-11-08, Apple M3 Max, against Soufflé 2.5's subsumption)

`(relation dist [symbol integer] min)` keeps, for each key, the columns before the last, the tuple whose last column is least; `max` the greatest; `choice` the first derived. About 160 lines of code.

- **Decided: a second table by key, and dead tuples left in place.** Storage only grows, and every kernel reads a relation as a range of tuples. The key table's entry points at the best tuple so far: an insert that is not better is refused, natively, and one that is better is added and the entry moved, leaving the other dead where it was. Nothing that reads a relation changes. Within its own recursion a dead tuple can be read, which only derives what is no better, refused in turn; when the component is done the relation is made again from the live tuples, so later components never see a dead one. The same decision serves lattices, of which min and max are two, and leaves deletion, for deleting and rederiving, to compaction as here.
- **Rejected before building: deleting or overwriting in place.** A tuple overwritten in place would leave the hash table and every index pointing at a different tuple, and one deleted would need tombstones checked in every scan, probe and chain of every kernel, programs that never delete included. Compacting the whole relation at each round would cost its size every round.
- **A finding while testing:** an add that improves a key rebuilds the relation, so the positions an add goes on from no longer hold, and a reader may hold what followed from the value replaced. A component that reads such a relation once it has changed is now evaluated again, as one that negates a changed relation is. The fixtures found it: two of six evaluators, the two that add, missed tuples.
- **Shortest paths from one node,** random graphs, weights 1 to 100, checked against Dijkstra's algorithm, written apart, by count and sum of distances:

  | ms | Ours | Soufflé compiled, subsumption |
  | --- | --- | --- |
  | 2,000 nodes, 10,000 edges | 1.9 | 10.3 |
  | 20,000 nodes, 100,000 edges | 23.5 | 137.9 |

  The large one makes 74,272 derivations for 19,848 distances, in 21 rounds. Soufflé's subsumption deletes in its B-tree; we refuse at the key table and compact once.
- **Semantics:** a relation in the same recursion as a min or max relation may hold what follows from a value later replaced, as in Soufflé, where a subsumed tuple's consequences also stay; relations after it see only the best. `choice` depends on the order of evaluation, so its tests check what holds of any choice: one tuple a key, each derivable.
- **Checked:** fixtures, 30 random weighted graphs through native and KL joins, adds and removals, against the reference, which keeps the best of each key round by round, signed values at both ends of 32 bits, demand queries, explanations, and errors. Planted, a min that keeps the larger and a key entry left behind hang, as nothing stops paths around cycles, no compaction fails 101 checks, an unsigned comparison 5, once negative values were added, readers grown and not evaluated again 2, and a key table not grown raises.

### Lattices (2026-11-08, Apple M3 Max, against the commit before)

`(relation reached-by [integer integer] (lattice F))` keeps for each key the least upper bound of its values, by `F`, a Shen function of two integers. It is the relation of one tuple a key of the entry before, whose better tuple is the bound of the old value and the new: no new storage. About 40 lines of code.

- **Rules that add to a lattice are KL,** as a kernel cannot call `F`; KL calls it inline. Bit sets for which of 30 starts reach each node of a random graph, 20,000 nodes and 60,000 edges: 148 ms, 527,935 derivations for 18,858 tuples, where the same as pairs, one per start and node, natively, takes 53 ms for 527,918 tuples. The first version went through a Shen function for each insert, finding the kernels it called by name, and took 528 ms.
- **Not done: native joins for `bor` and `band`,** which would make bit-set lattices native: 32 bits make small sets, and the KL path is 2.8 times the pairs, with 28 times fewer tuples.
- **The reference stratifies them:** a rule that reads a relation of one tuple a key from outside its recursion is now a stratum after it, as one that negates is, since the reference evaluated such a reader with the relation while its values were still rising, and kept `known(15)` from a constant that later became the top. The engine evaluates readers in later components already. Within one recursion, results of other relations depend on the order of evaluation in both, and the tests do not compare them.
- **Explanations** give `[Tuple lattice]` for a value joined from others, which no single rule instance derives.
- **Checked:** two lattices, the union of bit sets and a flat lattice for constant propagation, by hand and on 20 random graphs, through native and KL joins, adds and removals, against the reference, and explanations and a demand query. Planted, storing the new value instead of the bound fails 117 checks, readers in the same stratum as the lattice in the reference 2. Generating lattice plans natively first only falls back to KL, which changes no result.

### Deleting and rederiving, rejected (2026-11-08, Apple M3 Max)

`datalog.remove` evaluates again each component a removal reaches, which costs about a run of it: 98 ms to remove one edge from the sparse closure, whose run takes about 90. Deleting and rederiving would delete everything with a derivation through the removed facts, rebuild the relations without it, derive again what still holds, and go on semi-naively from that.

- **What it would delete,** for a removed edge from A to B, every tuple from what reaches A to what B reaches: over 20 edges spread across the sparse closure, half of them 1,385,804 of its 1,388,324 tuples, the giant cycle, and the others 1 to 9,208; over 20 calls of the kernel's call graph, most under 400 of 125,617 and two 116,963.
- **The floor is rebuilding:** storage only grows, so deleting means making a relation again from what is left. Copying the closure's 1,388,324 tuples into a new relation from Shen took 89.5 ms, about a run; a kernel might take a third of that.
- **Rejected:** for the half of removals that delete little, the gain is at most about three times, all of it the rebuilding's floor; for the other half, deleting nearly everything and deriving it again costs about two runs, where evaluating again costs one. Deleting without rebuilding needs tombstones, checked in every scan, probe and chain of every kernel, programs that never remove included, which the relations of one tuple a key were designed to avoid. Counting derivations instead, for relations outside recursion, would need a count kept with every tuple. If removals from large relations that reach little turn out to matter, a removal could choose between the two by the size of what it would delete, which it can count first, as here.

### End to end: a dependency analyser (2026-11-08, Apple M3 Max)

`example-apps/depends`, the plan's whole program: it reads Shen and KL files, and one `defdatalog` of 18 relations and 21 rules gives what calls what, which files depend on which, the files in a cycle as an equivalence, recursion, dead and external functions by negation, the most called by a count, and each function's depth from the roots as a `min` relation, which ends with no bound though calls go round in cycles; a record says where each function is defined. `--reach F` asks by demand, `--why F G` explains, and `--out DIR` writes tab-separated files. It is saved as one executable of 3.0 MB, here from a debug build, with `shen-jit.save-executable`. About 130 lines of code.

- **On the kernel's 23 KL files:** 1,126 functions, 6,653 calls, 155 file dependencies, 13 files in one cycle and 438 recursive functions; 294 functions live from `shen.shen` and `eval`, the deepest 13 calls down. A report takes 0.10 s for the whole process, reading the files included; `--reach shen.typecheck`, 421 functions, 0.09 s.
- **What it found:** nothing in the library needed a change. One thing in its use: `datalog.ask` and `datalog.query` read their pattern as written, so `(datalog.query P Facts (reaches F X))` inside a function treats `F` as a Datalog variable and answers for every function; the analyser builds the pattern for `datalog.solve` instead, and the reference now says so. Read through Shen's reader, a file's macros are applied before the analysis sees it: `(input+ number)` is two calls.
- **Tested** by `example-apps/depends/test.sh`, which `make test-datalog` runs: it builds the executable, checks the report, a demand query, two explanations, the files written and a bad option over a fixture whose answers are written by hand, and that it finds every function, by name, the kernel's KL defines. It adds about 0.9 s.

### Against Soufflé after the gaps (2026-11-08, Apple M3 Max, Homebrew's Soufflé 2.5 on one thread)

`make bench-datalog-souffle` on the branch's last commit, its interpreter left out, at a load of 3 to 5 from other work, so that each time is a little high. Every result Soufflé finished matches ours.

| ms | Ours | Soufflé compiled |
| --- | --- | --- |
| Closure, sparse | 103.5 | 448.4 |
| Closure, dense | 6.5 | 39.4 |
| Nonlinear closure | 164.1 | 690.3 |
| Same generation | 11.6 | 56.1 |
| Mutual recursion | 0.2 | 0.9 |
| Skewed join | 109.5 | 107.5 |
| The kernel's call graph | 7.8 | 46.4 |
| Points-to small, order a / b / c | 109.5 / 141.1 / 111.2 | 1,436.6 / over 40 s / 234.6 |
| Points-to large, order a / b / c | 486.9 / 643.9 / 485.3 | 16,820.3 / over 40 s / 974.2 |

On one thread, ahead everywhere but the skewed join, which is even, and the shortest runs, under Soufflé's startup. With the entries above: records, 536,345 routes in 54 to 64 ms against 290 to 320; shortest paths 23.5 against 137.9; one node's paths by demand 0.3 against 1.3 with its magic sets; reading 1.39 million facts 334 against 309.

### Writing a buffer at once (2026-11-08, Apple M3 Max, against the commit before and Soufflé 2.5)

`shen-jit.write-bytes B I N Stream`, a primitive, writes a range of a byte buffer by one `fwrite`. The kernel's `pr` writes a string a byte at a time and finds its end by an error caught at each character, about 27 ns a byte, and `write-byte` takes a call a byte, about 19 ns; joining lines into chunks for `pr` changed nothing. It is the last primitive, so no other's number moves; Shen/Scheme as the host makes the same generated files.

- **Fact files:** `datalog.write-facts` writes each line through it, 275 ms for the sparse closure's 1,388,324 lines against 455. Soufflé 2.5's compiled program writes the same relation in about 276 ms, its run with the output less its read, as without an output it skips the read too. Building the lines, decoding each tuple and its numbers into text, is most of what is left.
- **Not done:** `pr` itself through it. Every program's output would gain, but `pr` is the kernel's, and an override must agree with it under `make test-overrides`; worth its own change (done later, under "Kernel overrides").

### Native bit-set lattices (2026-11-08, Apple M3 Max, against the commit before)

`(lattice bor)` and `(lattice band)` name the bit operations, not a Shen function, and kernels join them: the new value goes in a register, is joined with the key's old one, and the tuple is added only if that changed it. The probe by key is now one function that `min`, `max`, `choice` and these share, given what to do with the old value. About 25 lines of code.

- **Bit sets for which of 30 starts reach each node,** the workload of the lattices' entry: 97.9 ms natively against 148 through a Shen function, for the same 527,935 derivations into 18,858 tuples; the same as pairs, one per start and node, takes 55 ms but keeps 28 times as many tuples. A derivation probes the key table and, when the bound grows, the relation's own table too, and leaves a dead tuple behind, which is what is left of the difference.
- **Checked:** both lattices by hand, against a Python fixpoint, and on 20 random graphs through every evaluator against the reference, and that each of their plans is a kernel. Planted, `band` computed as `bor` raises in the generated programs and the joined value not kept fails 144 checks. Adding a tuple whose bound did not change is harmless, as the relation's own table already holds it, so leaving out that test changes nothing but a probe.

### Equivalences as classes (2026-11-08, Apple M3 Max, against the commit before and Soufflé 2.5)

An equivalence keeps its classes and not their pairs. Rules still add pairs, to the relation's own storage, which each merge empties into the union-find; the classes that changed are then laid out at the end of a buffer of five words a position: a value, its class's range of positions, and the range of the part of it that was one class when last laid out. A class's pairs are its range, the old ones a value's part and the new ones the rest, so semi-naive evaluation reads old and new pairs without storing any; a table by value finds a value's position. Kernels scan and look up classes natively, a member check being two probes and a comparison of the classes' starts; a negation or an aggregate over an equivalence is KL. A class that changes moves to the end, leaving holes with empty ranges, and every class is laid out again when the holes would outnumber the values or the buffer or the table is full. About 350 lines of code, most of them the layout and the kernels' steps over classes.

Best of two runs each, alternating, at a load of about 4 from other work, so that each time is a little high:

| ms, random graphs of 3,000 nodes | 1,500 links | 2,500 links | 3,000 links |
| --- | --- | --- | --- |
| Pairs in `same` | 45,401 | 3,922,045 | 5,727,183 |
| The closure alone, pairs | 9.4 | 752 | 1,146 |
| The closure alone, classes | 1.1 | 2.8 | 4.1 |
| Soufflé's eqrel, alone | 1.1 | 1.2 | 1.4 |
| With a join reading it twice, pairs | 10.8 | 1,248 | 2,088 |
| The same, classes | 2.4 | 173 | 374 |
| The same, Soufflé | 8.2 | 787 | 1,335 |

- **Kept.** The closure costs what Soufflé's does on small classes and 3 times as much on a class of 2,400, where pairs cost 800 times as much; the join is 4.5 to 7.2 times as fast as with pairs, and 3.4 to 4.5 times Soufflé's speed. A class takes room in proportion to its values, up to 112 bytes each in the buffers and three dictionary entries, where its pairs took 8 bytes each, k squared of them: 46 MB for a class of 2,400.
- **The join order changed with the storage.** At first the small join took 16.6 ms against 11.8: the planner estimated a lookup by the mean class size over values, 24, below its guess for `link`'s index, not yet built, of 32, and read `(same W X)` before `(link Y W)`; but X is in Z's class, so it walked the giant class once more for each of its values. Pairs escaped only because their own guess for an index not yet built was 128. A lookup is now estimated at the class size averaged over pairs, the sum of the cubes of the sizes over that of the squares, exact for classes of one size and near the largest when one dominates, as a join's keys do: 2.4 ms.
- **Laying out every class again was a trap.** The first version did so whenever one changed: one class growing by a value a round for 200 rounds, beside 50,000 that never change, took 2,818 ms against 108 with pairs. Only the classes that changed move now: 92 to 129 ms against 103 to 117; beside 5,000, 17 to 21 against 13 to 15; alone, 10 to 11 against 8, as a growing class is laid out whole each round, k squared in all, as its pairs were. The inbox also goes back to its first size when emptied: kept at the size the facts gave it, it was cleared every round, about 0.1 ms a round here. The room this keeps for growth, twice the values and a table for four times, costs the closure alone a little: 1.0, 2.1 and 2.8 ms when laid out exactly.
- **Checked:** the fixtures, generated programs against the reference under every evaluator, and SWI-Prolog. Three planted under-reads of old pairs passed every check until a fixture was added whose classes change early, one in the round after the other, in a component that keeps growing and reads their old pairs later, by a scan and by a member check. Now old ranges not reset when nothing changed fail 1 check, the classes changed in the round before not made old 10, a native old member check that never holds 4, KL old pairs read as none 2, and holes not made, or the table not told where moved values went, raise. Over-reads, old pairs read as all and new ones scanned from the first position, and a full layout every time give the same answers more slowly, and pass.
- **Not done:** negation and aggregates over an equivalence natively, which are rare and KL; and the layout is Shen over dictionaries, which a kernel could place if a workload shows it costs.

### Fact files as bytes (2026-11-08, Apple M3 Max, against the commit before)

`datalog.relation->bytes` makes a relation's whole file as one byte buffer, and `datalog.bytes->facts` parses such bytes, so that a program can write and read its files with the I/O library, which reports a failure as a value and uses no kernel stream. `datalog.read-facts` and `datalog.write-facts` stay, over them, as conveniences with Shen's files. The dependency analyser's `--out` writes through `io.write-file`, and its test skips that on a static build, which cannot load the C library the I/O library's files need. About 20 lines of code.

- **Writing the sparse closure's 1,388,324 lines,** two runs each: 235 ms against 252 to 259, a line at a time. The file is written once every line is made, so a field a tab-separated file cannot hold now raises before the file is opened, and leaves it as it was.
- **Reading is the same code,** but timing it showed how much the collector's moments weigh: passing the bytes before the program's checks, in place of after them, took a second read in one process from 155 to 187 ms, the first going from 169 to 165, the same in three rounds. Making the bytes after the checks, as before, gave 158 to 172.

## Benchmark results

Ratios are geometric means of Shen/JIT's time over the other implementation's, so below 1 means Shen/JIT is faster.
Open is the default, with kernel functions sealed and user definitions not; sealed is `shen-jit --seal`. The campaign
and Prolog comparisons used harnesses and recorded data that are not published: `make bench` and
`make bench-independent` are what a reader can run.

### How the comparisons were done

- **The campaign, from 2026-11-01.** We reran the earlier prototype's last complete campaign, recorded 2026-10-27, on its
  own drivers, beside its recorded medians for Shen/Scheme 0.50 on Chez 10.3.0 and for the prototype, both on kernel 42.2.
- **156 timed rows:** 122 canonical kernel cases in one process, compilation outside the timer; 23 warmed `eval`s including
  their compilation; 11 prepared controls, with preparation out of the means. Each Shen/JIT cell is the median of six fresh processes.
- **Sealed covers 155 rows,** as `kernel-yacc` defines `<as>` twice. The recorded Shen/Scheme ran in its normal mode. Results
  are checked: all match the expected values or Shen/Scheme's, apart from six opaque values printed differently.
- **Machine drift is measured,** since the recording cannot be rerun: a saved binary before and after a campaign, then
  Shen/Scheme 0.52 timed each time. A rerun on a busy machine, every row about 1.05 times as long, was not used (2026-11-03).
- **Single rows move with placement.** `vector create (big)` took 0.24 s to 0.43 s with the heap pointer's parity on an Apple
  M3 Max. Identical code took 0.098 s or 0.151 s on a Ryzen 5 5600X. Slower rows are timed alone before anyone acts on them.
- **Before the campaign, 2026-11-01, Apple M3 Max, against Shen/Scheme 0.52.** `make bench`, 79 benchmarks of 2 ms or more, best of
  3: 1.35 (2.38 for the first build with a kernel image, the same day); the realistic compile pipeline 2.0 (4.4) and bytecode VM
  2.2 (6.4). Startup 3.0 ms (3.4) against 188 ms. Kernel test suite 0.46 s (0.83) against 0.78 s.

### Campaign reruns (Apple M3 Max, against the recording)

"Earlier" is the earlier prototype. Each change is described under its own topic.

| Date | Changes since the row before | Open / Scheme | Open / earlier | Sealed / Scheme | Sealed / earlier |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-11-01 | First full run | 1.24 | 2.33 | - | - |
| 2026-11-01 | Dictionaries, constant operands, sealing, tail-call arguments, registers, quiet handlers | 0.71 | 1.33 | 0.64 | 1.20 |
| 2026-11-02 | First argument and loop slots in registers, collector copies | 0.62 | 1.16 | 0.55 | 1.03 |
| 2026-11-02 | Overrides, Prolog, loading, collector | 0.55 | 1.02 | 0.47 | 0.89 |
| 2026-11-02 | Calls, list literals, patterns, handlers, strings, reals | 0.52 | 0.97 | 0.44 | 0.83 |
| 2026-11-03 | Allocation, open loops, equality, patterns | 0.46 | 0.87 | 0.43 | 0.80 |
| 2026-11-03 | Calls through `fn`, pattern parts, leaves, cons runs | 0.44 | 0.83 | 0.42 | 0.78 |
| 2026-11-03 | Inlining open callees, exact traces, closures, `cn`, `=` | 0.43 | 0.80 | 0.41 | 0.77 |
| 2026-11-03 | List walking; machine about 2% slower | 0.42 | 0.79 | 0.41 | 0.78 |
| 2026-11-03 | Patched branches, loop registers, exit tests; about 3% of it is the machine | 0.39 | 0.74 | 0.38 | 0.72 |
| 2026-11-03 | Type tests leave the value in a register; machine 1.7% slower | 0.40 | 0.75 | 0.39 | 0.73 |
| 2026-11-04 | Prolog variables as immediates, trail unifier, growing in place | 0.38 | 0.70 | 0.37 | 0.69 |
| 2026-11-04 | C function alignment, kernel 43.2, threads, Ctrl-C; machine about 2% faster | 0.37 | 0.70 | 0.37 | 0.69 |

- **Open / Scheme through 2026-11-01, change by change:** 1.24, 1.18, 1.14, 1.00, 0.93, 0.85, 0.79, 0.77, 0.74, 0.72, 0.71.
- **Rows faster than both, open:** 7 on 2026-11-01, 58 and 60 on 2026-11-02, 78, 95, 99 and 105 on 2026-11-03, 127 on 2026-11-04. On
  2026-11-04, 148 against Shen/Scheme and 131 against the earlier prototype open, 147 and 133 sealed.
- **Caught by a rerun, 2026-11-03:** pattern sharing turned a frozen failure continuation into a closure made on every call, so
  the realistic pipelines took 1.15 to 1.22 times as long. Fixed in the lowerer.
- **Threads and Ctrl-C cost nothing the campaign can see, 2026-11-04:** 0.997 open and 1.004 sealed against the rerun before.
- **`kernel-interpreter` is not pinned down, 2026-11-04.** One cold `eval` of about 2 ms read 1.13 and 1.17 on the M3 Max and 1.36
  and 1.38 on a Ryzen 5 5600X VM against the rerun before. Warm, over a million iterations, it reads 1.00 and 1.06.
- **Open / Scheme by group, 2026-11-04:** control flow 0.13, compilation 0.27, Prolog 0.37, equality 0.42, warm calls 0.46, patterns 0.50, data
  0.54, arithmetic 0.61, applications 0.61, prepared applications 0.72.
- **Behind both, open, 2026-11-04:** list patterns with several clauses that match (1.19 and 1.25), a nested list pattern's late mismatch
  (1.21 and 1.08), the recursive list rebuild (1.04 and 1.01), `kernel-interpreter` (1.04 and 1.08).

### Shen/Scheme sealed (2026-11-06, Apple M3 Max, 0.54)

Never run until now: every "Sealed / Scheme" above is against its normal mode. `compile --mode sealed` binds calls within one file, so the 14 files of `tests/bench/suite.shen` were joined into one, with `(factorise +)` set while compiling, and run at 10 times the suite's run counts, 2 rounds of 3 samples, best sample, in alternation, load about 2. Results match on every row. Sealing Shen/Scheme gives 0.92 of its normal time over 95 rows, and it is a compile step with a different program unit, where `--seal` needs neither.

| Group | Rows | Scheme sealed / normal | Shen/JIT open / Scheme sealed | Shen/JIT sealed / Scheme sealed |
| --- | ---: | ---: | ---: | ---: |
| compile pipeline | 3 | 0.93 | 1.16 | 1.08 |
| bytecode VM | 2 | 0.68 | 1.36 | 1.43 |
| data | 22 | 0.92 | 0.47 | 0.47 |
| control flow | 23 | 0.97 | 0.11 | 0.11 |
| Shen compilation | 9 | 0.91 | 0.26 | 0.26 |
| pattern matching | 17 | 0.90 | 0.42 | 0.42 |
| equality | 19 | 0.90 | 0.35 | 0.36 |
| all | 95 | 0.92 | 0.30 | 0.30 |

- **`bytecode VM` is where it gains:** depth 9 610 to 413 ms. It is the only group behind by much once both are sealed.
- **`--seal` made `bytecode VM` slower on the M3, and not on x86-64.** Alone, 10^6 runs at depth 9, best of 7: M3 open 0.552 to 0.566 s and sealed 0.585 to 0.594, at each of 6 shifts by unrelated definitions; Ryzen 5 5600X VM open 0.852 to 0.861 and sealed 0.828 to 0.842. It helps `compile pipeline` on the M3, 68 to 62 ms at depth 5.
  - **What it was not.** The sealed bytecode is the open one less its guards, and in native code the same sequences, with fewer jumps. Self time by function is the same, and sealing `vm.shen` alone gives all of it, so it is in `exec`. 0 to 12 nops before the loop's aligned body, which run only on entry, move neither mode much.
  - **What moved it.** A taken jump added before each `cons` and each `+`, `-` and `*`, the jumps open code has between its inlined bodies, took sealed from about 0.590 to 0.572 and open from about 0.555 to 0.581. That pointed at straight-line code reloading slots it stored a few instructions before, and registers for those removed the gap: see "Two more registers" under Registers and caching.

### Hardware counters on bare metal (2026-11-07, Ryzen 5 5600X, against Shen/Scheme 0.54)

The VM has no counters, so this ran `perf` from a Linux booted from USB, pinned to one core, with Shen/JIT's static build from CI. Per run, median of 3, a nearly empty run subtracted, open:

| | `bytecode VM` depth 9, Shen/JIT | Shen/Scheme | `compile pipeline` depth 7, Shen/JIT | Shen/Scheme |
| --- | ---: | ---: | ---: | ---: |
| Cycles | 3,443 | 4,176 | 67,545 | 66,255 |
| Instructions | 13,034 | 15,263 | 257,341 | 241,063 |
| IPC | 3.79 | 3.66 | 3.81 | 3.64 |
| Loads | 3,611 | 3,812 | 63,426 | 54,027 |
| Stores | 2,144 | 1,086 | 35,962 | 19,542 |
| Branch misses | 6.3 | 8.9 | 150 | 141 |

- **The lower IPC measured in the VM does not hold here:** Shen/JIT's is the higher on both. Mispredicted returns and memory-order flushes, the candidates that reading left, are out: returns almost never mispredict, and store-to-load retries are about 2% of cycles on both. An earlier callgrind count of 334,368 instructions for Shen/Scheme's pipeline run remains unexplained; this count is the one to use.
- **The pipeline's gap, 1.02 where Shen/Scheme's own runs vary by 4.5%, is more work and not stalls:** 7% more instructions, 17% more loads, 84% more stores.
- **Real programs show no such gap.** Cycles over Shen/Scheme's, whole process, median of 5, with test results and inference counts the same: kernel suite 0.25, extension tests 0.14, startup 0.03, THORN set 0.19, L 0.36, schubert 0.30, ec 0.44. These include loading and compiling, so they don't show THORN's search alone.
- **Dead stores: not tried, for that reason.** The stores above are the one lead left on the two rows, but they are synthetic, and removing stores risks the collector. How many are dead was not measured.
- **Where the time goes in those programs,** Shen/JIT with symbols. First-call compilation, by the cycle counter: kernel suite 12.2%, THORN set 7.9%, schubert 6.5%, L 5.4%, ec 3.9%, about 20 microseconds a code object. Installing definitions 0.6% to 3.4%. Loading THORN alone is 24% compilation. The IPC is 2.3 to 2.8, against 3.8 on the two rows, with 1.7 to 4.2 branch misses and 8 to 27 instruction-cache misses per 1,000 instructions and 8% to 17% of cycles in frontend stalls. Samples spread thin: the top function is at most 11% of `ec` (`shen-jit.occurs-in?`) and 19% of L (THORN's `prv`), and samples of cache misses and branch misses follow those of cycles, so they name no hot spot.
- **Not tried: keeping native code in images,** which would remove some of that compilation in short runs. It would make images position-dependent, for at most 4% to 12%.

### x86-64 Linux

A Hyper-V VM with 4 cores of a Ryzen 5 5600X, Ubuntu 20.04, gcc 9.4. Against Shen/Scheme 0.52 run alongside on each machine, six
rounds; on x86-64 both ran in one Debian 13 container, as its Linux binary needs glibc 2.38. Shen/Scheme 0.52 takes 1.05 times
the recorded 0.50's time on the M3 Max. The earlier prototype has no x86-64 numbers.

| Date | M3 Max open, sealed | Ryzen VM open, sealed | Rows ahead on the VM, open, sealed | VM / M3 Max: Shen/Scheme, Shen/JIT |
| --- | ---: | ---: | ---: | ---: |
| 2026-11-03, first | 0.39, - | 0.50, 0.46 | 108, 128 | 1.11, 1.43 |
| 2026-11-03 | 0.38, 0.37 | 0.45, 0.43 | 129, 136 | 1.10, 1.30 |
| 2026-11-03 | 0.38, 0.37 | 0.44, 0.43 | 138, 139 | 1.08, 1.27 |
| 2026-11-04 | 0.36, 0.35 | 0.43, 0.42 | 136, 139 | 1.08, 1.32 |
| 2026-11-04 | 0.36, 0.35 | 0.43, 0.42 | 134, 134 | 1.11, 1.31 |

- **Each change, interleaved on the VM, 2026-11-03, open and sealed:** patched branches 0.931 and 0.999, loop registers 0.988 and
  0.985, exit tests 0.982 and 0.975 (0.954 and 0.972 on the M3 Max, with the realistic pipelines losing 2 to 5%).
- **Behind Shen/Scheme on the VM, open, 2026-11-04:** `tuple create` 1.71, list patterns with several clauses that match 1.48,
  `reverse` 1.41, `closure allocation` 1.31.
- **`trap-error` with an error raised looks 3 to 7 times worse there, from Shen/Scheme's side:** raising takes it 0.65 s on macOS
  against 0.13 s on Linux for the basic row.
- **Those four rows, 2026-11-05, against Shen/Scheme 0.53, the kernel's benchmarks in one process, before and after one allocation area:** `tuple create`
  1.73 to 1.20, `reverse (32 items)` 1.38 to 1.28, `closure allocation` 1.32 to 1.26, `match list (multiple clauses, matching)` 1.47 to 1.47. All rows 0.410 to 0.402.
- **`match list` is measured against an unsound test, 2026-11-05.** Shen/Scheme 0.53 compiles `(= X 5)` to `(eqv? X 5)`, so `(= (* 2.5 2) 5)` through a literal
  is false. Its next commit compiles it to `(kl:= X 5)`. With that emulated by shadowing `eqv?` in user code, `match list` reads 0.26, `literal integer equality (false)` 0.30 and all rows 0.27,
  control loops taking Shen/Scheme about 2.2 ns more a turn; `compile pipeline` 0.85 to 0.89 and `bytecode VM` 0.94 to 0.96. That charges a whole call per test, which an inline sound test would not, so these are bounds.
- **What x86-64 costs, 2026-11-05, Ryzen VM over M3 Max, 103 rows:** Shen/JIT 1.30, Shen/Scheme 1.14. `bytecode VM` 1.48 and 1.12, on Shen/JIT with 78% of its samples in `exec` and 3.1% of its time collecting. Not memory, slots, constant loads
  or padding (each above). `exec` makes real calls, so loop registers would not apply. Counted below.
- **`bytecode VM` counted, 2026-11-05,** per run, by the difference of two run counts: on the M3 Max from `time -l`, and on the Ryzen VM under Valgrind's callgrind in a container, as `perf` is blocked there, with IPC taken at 4.6 GHz.
  | Per run | Instructions, M3 Max | IPC | Instructions, Ryzen VM | Loads, stores | Time | IPC |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | Shen/JIT | 14,284 | 6.6 | 13,981 | 4,230, 2,018 | 859 ns | 3.5 |
  | Shen/Scheme 0.53 | 20,814 | 7.1 | 17,226 | 4,169, 1,659 | 895 ns | 4.2 |
  - **Instructions explain most of the gap between the machines.** Cycles on the VM over the M3 are 1.83 for Shen/JIT and 1.40 for Shen/Scheme, 1.31 relatively. Shen/Scheme takes 17% fewer instructions on x86-64, and Shen/JIT 2% fewer: about 1.18 of that 1.31. The rest is IPC, with 45% of Shen/JIT's instructions touching memory against 34%.
  - **Shen/JIT is still ahead on the count on both,** 0.69 and 0.81 of Shen/Scheme's instructions.
  - **Not allocation.** Time outside collections stays 816 to 854 ns with a semispace from 512 MB down to the image's floor of about 3 MB, past and within the L3, and the M3 Max reads 554 to 568. A size that fits L2 could not be tried.
  - **Not tried:** registers in loops that make real calls, spilling around them, which `exec` is, and which outnumber loops that call nothing about 2.4 to 1 on the kernel suite. x86-64's memory operands: the next entry.
- **Memory operands, and the moves around CACHE, 2026-11-06,** a Ryzen 5 5600X VM with gcc 9.4, idle, and an Apple M3 Max at load 2 to 3, against the build before. Counted by callgrind, per instruction, on `bytecode VM` and `compile pipeline`, a load and a compare of the same value are only 1% to 3% of what runs, as most values are read again or stored. More goes on moves: a load to R0, a store and a move to CACHE, or CACHE to R0 and back. Now a result goes to CACHE first and is stored from it, `=` with a constant compares where the value is, and a Boolean test reads CACHE. 6 fewer lines.
  - **Counted on the VM:** `bytecode VM` 13,731 to 13,054 instructions and `compile pipeline` 277,984 to 262,089, 0.951 and 0.943, with the same loads and stores, and generated code 1.1% smaller.
  - **Time, alone,** with 0 to 8 definitions compiled first, best of 5 at each. On the VM `compile pipeline` at depths 7 and 5 0.928 and 0.931 (0.91 to 0.97), and `bytecode VM` at depths 9 and 7 1.004 and 1.004. On the M3 1.010 and 1.006, and 0.965 and 0.967. In the suites, best of 5: kernel rows 1.006 and 1.009, port rows 0.993 and 0.993. Workloads never used for tuning, best of 7: 0.93 to 1.00 and 0.89 to 1.00. `numeric equality (integer/fractional)` read 1.26 on the M3 from one low sample, and alone 0.993.
  - **The pipeline moved less with placement.** On the VM at depth 7 it read 156 to 167 ms before, by what compiled first, and now 150 to 153. In the suite it read 1.015, so one placement can hide the gain. NOPs after each loop head are no way to try more placements: they run each turn, and took it to 155 to 235 ms.
  - **That corrects the entry above.** 5% fewer instructions left `bytecode VM` alone on the VM, and 5.7% fewer took 7% from `compile pipeline`, while the M3 reads the other way round. So the count does not predict time here, and how much of the gap between the machines it explains is less sure than the 1.18 there says.
  - **Rejected: a load based on CACHE going straight to it,** `ldr x21, [x21, #5]`. On the VM instructions 0.931 and 0.904 and no better in time, kernel rows 1.004 and port rows 1.001. On the M3 `match list` 1.16 and 1.09 at every placement, flat as NOPs were added where the build before grew with them, against 1.00 for a load to another register and a move. A load from any other base straight to CACHE does not do this. Why is not known.
- **Against Shen/Scheme 0.54, 2026-11-06,** both on kernel 43.4 with user code open, on the Ryzen VM, idle, and an Apple M3 Max at load 2 to 4. Rows are the best of 5 in alternation, and the realistic programs alone are the best of 7.
  | Shen/JIT over Shen/Scheme | Ryzen VM | M3 Max |
  | --- | ---: | ---: |
  | Kernel rows (0.53 before) | 0.348 (0.377) | 0.332 (0.366) |
  | Port rows (0.53 before) | 0.359 (0.413) | 0.367 (0.430) |
  | `compile pipeline` alone, depths 7, 5 and 9 | 1.02, 1.06, 1.01 | 1.02, 1.03, 0.96 |
  | `bytecode VM` alone, depths 9 and 7 | 1.05, 1.04 | 0.88, 0.92 |
  - **The rows gained where Shen/Scheme now pays for a sound `=`.** A test against a numeric literal was `eqv?`, and is now guarded. On the VM its control loops take 1.66 times as long, `literal integer equality (false)` 1.80 and `match list (multiple clauses, matching)` 2.10, which now reads 0.70, where it read 1.47. The M3 reads the same: 1.48, 1.72 and 1.91.
  - **The realistic programs lost their lead.** Its Boolean checks and equality paths gave Shen/Scheme, against the same programs under 0.53 in the same suite, `compile pipeline` 0.83 to 0.87 on the VM and 0.88 and 0.90 on the M3, `bytecode VM` 0.94 and 0.98 on the VM and 0.78 and 0.82 on the M3, `symbol equality (true)` 0.66 to 0.71 and `list membership (last item)` 0.43 to 0.51. On the VM it is now ahead of Shen/JIT on both programs, by 1% to 6%. On the M3 `compile pipeline` is level, and Shen/JIT keeps 8% to 12% on `bytecode VM`. In the suite, the same programs read 1.03 to 1.07 on the VM, and 0.91 to 1.02 on the M3.
  - **Rows still behind, on the VM:** `list equality (early mismatch)` 1.27, `list allocation (three live generations)` 1.19, `allocating recursive call` 1.16, `closure allocation` 1.11. On the M3: `numeric equality (integer/fractional)` 1.12, and four rows at 1.08 to 1.10.
  - **Not measured:** Shen/Scheme with user code sealed, and why these programs differ by machine.
- **`bytecode VM` and `compile pipeline` profiled, 2026-11-06,** to find why Shen/Scheme 0.54 leads them on the VM with more instructions. Valgrind on the VM, by the difference of two run counts and over the last 100 M instructions of a trace, and `sample` on the M3 Max. Valgrind's low addresses save Shen/JIT about 4% of its instructions here, in constant loads.
  | Per run on the VM | `bytecode VM` | Shen/Scheme | `compile pipeline` | Shen/Scheme |
  | --- | ---: | ---: | ---: | ---: |
  | Instructions | 13,056 | 15,223 | 262,096 | 334,368 |
  | Loads, stores | 4,220, 2,012 | 3,660, 1,369 | 67,173, 35,345 | 74,723, 38,056 |
  | Taken branches per 1000 instructions | 74 | 106 | 76 | 111 |
  | Instructions in a straight run | 13.5 | 9.4 | 13.2 | 9.0 |
  | Code touched | 2.9 KB | 24 KB | 17 KB | 35 KB |
  | Stores overwritten unread | 16.6% | 21.9% | 29.8% | 21.5% |
  | IPC, at 4.55 GHz | 3.3 | 4.1 | 3.8 | 5.0 |
  - **Where it goes, instructions on the VM and samples on the M3:** in `bytecode VM`, `exec` 75% and 80%, `env-lookup` 22% and 16%. In `compile pipeline`, `free-vars` 30% and 33%, `union-vars` 15% and 12%, `append` in C 9% and 12%, `normalise` 9% and 8%, `simplify` 9% and 7%, `member?` 6% and 7%, the collector about 2.5%. `append` costs about 211 instructions a call, and its loop is already tight.
  - **Frame traffic is large, and not what costs on Zen 3.** 30% of `exec`'s instructions load or store a slot, and `free-vars` reloads a term's head for each clause, up to five times. Yet a chain through a slot takes 0.22 ns a turn, as through a register, for any base register, and 0.44 ns with the base moved between store and load, a longer loop: the store's value reaches the load with no latency. On the M3 the same chain takes 1.82 ns against 0.27. So the M3 pays for slots and the VM does not, and Shen/JIT still does better on the M3. Fewer slots should not be expected to close the gap on x86-64. **Rejected before:** spare registers as copies of slots, above.
  - **Nor is it the front end, as far as a trace can tell.** Shen/JIT has fewer taken branches and longer runs, and touches less code. Two simple predictors, by address alone, miss about as much on both: 2-bit counters 164 and 156 a run, 4,198 and 4,393, and last targets 0 and 26, 1,908 and 1,735.
  - **Not known:** what holds its IPC down. The VM's guest has no hardware counters, as `/sys/bus/event_source/devices` has no `cpu`, so `perf` would not help whatever `perf_event_paranoid` says. Mispredicted returns and memory-order flushes are candidates that only counters can tell apart.

### Native Windows (2026-11-04)

Windows 10 Pro on the VM's Hyper-V host, all 12 threads of the Ryzen 5 5600X, gcc 16 in MSYS2's UCRT64, against the VM's last rows above:
the same processor, though one is a guest and one the host. No Shen/Scheme beside it.

- **All rows:** 0.961 open (median 0.989), 0.939 sealed (median 0.981). Canonical 0.93, applications 1.10, prepared execution 1.03.
- **Small loops gain:** eight saved registers against six, so four loop registers against two. Many control loops take 0.67 to 0.75 of their time.
- **The loss is a fixed cost per process.** Long rows are level or better (`realistic-vm-9` 1.00, `kernel-n-queens` 0.86). First writes to
  the semispaces cost about 13 ms against 3, without huge pages; a process that does nothing takes 2.3 ms against 0.26.
- **Left as it is:** large pages need a privilege a user must be granted, and a smaller start would trade the one payment for more collections.

### Prolog, against SWI-Prolog and Shen/Scheme (2026-11-04, Apple M3 Max)

Microseconds of CPU time per iteration, best of the rounds, timed inside each process after a warm-up, collection included. SWI-Prolog
10.0.2 with -O, Shen/Scheme 0.52 on kernel 43.1. Each program in Prolog and as `defprolog`; `zebra`'s `.shen` file is Prolog syntax and
`qsort` has no Prolog file, so both are left out. Last recording:

| Program | SWI -O | Shen/Scheme | Shen/JIT | JIT / SWI -O | JIT / Scheme | Peak MB: SWI -O, Scheme, JIT |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| coloring | 216.8 | 151.0 | 104.8 | 0.48 | 0.69 | 9, 64, 71 |
| einstein | 1871.1 | 3302.9 | 805.3 | 0.43 | 0.24 | 8, 63, 71 |
| hamilton | 72.3 | 194.5 | 62.5 | 0.86 | 0.32 | 8, 62, 71 |
| nreverse | 12.3 | 32.3 | 12.2 | 1.00 | 0.38 | 8, 62, 71 |
| queens-8 | 79.9 | 133.8 | 66.1 | 0.83 | 0.49 | 8, 60, 71 |
| subset | 30.2 | 48.3 | 19.5 | 0.65 | 0.40 | 9, 60, 71 |
| tak | 3360.8 | 6063.2 | 1787.2 | 0.53 | 0.29 | 26, 136, 124 |
| Geometric mean | | | | 0.65 | 0.38 | |

- **Geometric means through the day, against SWI -O and Shen/Scheme:** first recording 0.85 and 0.50, inline `lazyderef` 0.72 and 0.42,
  walking two lists in the unifiers 0.71 and 0.42, inline `deref` 0.68 and 0.40, a later closure 0.66 and 0.39, last 0.65 and 0.38.
- **With the occurs check off,** as SWI-Prolog does none: 0.65 of SWI -O and 0.40 of Shen/Scheme with its check off too.
- **A recording at a load average of about 7 read about 10% slower on every row, a control binary included.** It was thrown away, and
  the driver now refuses to record above a load of 3.
- **`tak` is not evidence for runtime changes.** It needs `(prolog-memory 1000000)` on both Shen engines and allocates that per query,
  needlessly, and a kernel hook could fix that.
- **The campaign's Prolog rows, against the recorded Shen/Scheme:** 1.79 on 2026-11-01, 0.73 on 2026-11-02, 0.37 on 2026-11-04.

### Workloads never used for tuning

`make bench-independent`, added 2026-11-03: the kernel's test suite (38 programs), its extension tests, the standard library install (22 files),
the contract examples and startup. They mostly load, compile and typecheck, which the campaign hardly measures. Median wall time of nine
rounds, in ms. Shen/Scheme cannot install the standard library, which defines a name its port already has.

| Machine, date, build | Startup | Kernel tests | Extensions | Stdlib | Contract |
| --- | ---: | ---: | ---: | ---: | ---: |
| M3 Max, build of 2026-11-01, timed 2026-11-03 | 4 | 468 | 32 | 142 | 24 |
| M3 Max, 2026-11-03, with exit tests | 3 | 268 | 20 | 76 | 12 |
| M3 Max, 2026-11-04, Prolog and heap work | 4 | 215 | 21 | 69 | 13 |
| M3 Max, 2026-11-04, kernel 43.2 | 4 | 190 | 20 | 67 | 13 |
| Shen/Scheme, M3 Max, 2026-11-03 | 185 | 969 | 256 | - | - |
| Ryzen VM, 2026-11-04 | 2 | 277 | 23 | 84 | 13 |
| Shen/Scheme 0.52, Ryzen VM, 2026-11-04 | 241 | 1305 | 342 | - | - |
| Windows 10 on the Ryzen, 2026-11-04 | 7 | 309 | 37 | 111 | 21 |
| M3 Max, 2026-11-06, kernel 43.4 | 5 | 193 | 27 | 71 | 14 |
| Shen/Scheme 0.54, M3 Max, 2026-11-06 | 58 | 808 | 156 | - | - |
| Ryzen VM, 2026-11-06, kernel 43.4 | 2 | 274 | 30 | 84 | 14 |
| Shen/Scheme 0.54, Ryzen VM, 2026-11-06 | 70 | 1049 | 200 | - | - |

- **The gains hold outside the benchmarks.** On 2026-11-04 the kernel's test suite takes 0.20 of Shen/Scheme's 964 ms on the M3 Max and 0.21
  on the Ryzen VM, against 0.36 and 0.43 for the campaign.
- **It caught what the campaign could not.** Reserving 1 TiB per semispace on macOS read 1.52 at startup and 1.15 to 1.18 on the short
  workloads, 2026-11-04; the campaign times inside the process. The reservation went to 64 GiB.
- **It shows compile costs.** Open inlining and exact traces (2026-11-03) cost these workloads 3 to 5% of compile time while the benchmarks
  gained: open inlining 1%, the rest most likely the bookkeeping for exact backtraces.
- **THORN rows, added 2026-11-06.** Nothing above runs for long, so these time a prover searching, with its wall-clock limit taken away, on the problems of `tests/thorn.expected` that take it long enough: `set`, `L`, `schubert` and `ec`. The other three take little more than loading it, which is 42 ms on the M3 Max and 48 ms on the Ryzen VM. Median of nine rounds, in ms, at the build of that date: M3 Max 268, 217, 212 and 268, Ryzen VM 334, 293, 273 and 347. Each binary makes its own executable with the standard library, and each run is checked against that file. Not quite never used for tuning: profiling THORN is how `get-time`'s interning was found. Against Shen/Scheme 0.54, the same day, median of nine: on the M3 0.22, 0.38, 0.32 and 0.47, and on the VM 0.20, 0.38, 0.32 and 0.47. Loading THORN takes it 190 and 244 ms; less that on both sides, 0.23, 0.46, 0.37 and 0.61, and 0.20, 0.47, 0.37 and 0.60.

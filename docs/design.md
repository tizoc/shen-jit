# How Shen/JIT works

Shen/JIT is a small implementation of Shen in C. KLambda is lowered to a register bytecode by a
lowerer written in Shen, every function is compiled to native code by a whole-function baseline JIT built on
SLJIT, memory is managed by a copying collector, and the system starts from a heap image.

Small and simple come first, and it must still perform well. A mechanism that makes it noticeably
larger or harder to follow needs clear evidence that it is worth the cost.

| Area | Decision |
| --- | --- |
| Execution format | Register bytecode, with resolved lexical slots and explicit control flow |
| Execution engine | A baseline JIT that compiles each function at its first call. There is no interpreter |
| Frontend | A lowerer written in Shen, run by another Shen at stage 0 and as guest code afterwards |
| Boot artifact | A heap image written at build time, holding no native code |
| Collector | A Cheney copying collector with inline bump allocation into one reused area, and no write barriers |
| Native emitters | Handwritten C. Only what dominates execution is inline; the rest calls C helpers |
| Runtime organisation | One contiguous guest stack per thread, and a handler stack |

[bytecode.md](bytecode.md) defines the instructions and the lowering rules, and [semantics.md](semantics.md)
the behaviour the system implements.

## Build stages and startup

Loading Shen source does more than install definitions: it sets globals, registers packages, installs macros
and types, and records arities and lambda forms. Shen/JIT avoids recording those effects by running them in
itself and saving the result.

**Stage 0,** under a host, lowers the kernel's KLambda, leaving out what the port overrides, then the port
(`src/port/shen-jit.kl`) and the lowerer itself, which `tokl.shen` compiles to KLambda first. The output is
files of definitions as text, in `build/stage0`, so no state of the host reaches the target. Release tarballs carry this
output, so they build with a C compiler alone, and `generated.sha256` holds its hashes.

The host is the earlier release of Shen/JIT that `tools/ci-deps.sh` names, or Shen/Scheme, which makes the same files byte for byte. A host that is
Shen/JIT has its own lowerer sealed in its image, so the tools load the one being built under other names: `build/tools/lower.shen`, which the Makefile makes
with `shen-jit.lower.` changed to `stage0.lower.`. `tokl.shen` starts the compiler's variable numbering from zero in each definition, so that it does not depend on the host.

**Stage 1,** under the runtime alone:

1. Install every definition from stage 0. No guest code runs in this step.
2. Set the host's globals: `*os*`, `*language*`, `*release*` and so on.
3. Call `shen.initialise`, which sets the kernel's globals, then the selected extensions' initialisers, then the port's `shen-jit.initialise`.
4. Write the image, in which file streams are recorded as closed.

The build appends the image to the runtime to make `build/shen-jit`, a single file. The standard library
stays out: `make stlib` loads the kernel's precompiled `stlib.kl` into a running image and writes a binary with
`shen-jit.save-executable`.

**Startup** reads the image from the end of the executable's file, relocates its pointers and applies these rules:

- **Procedures:** a closure's native entry is a cache, set on load to the compile-on-first-call stub. A foreign
  function's is set to its stub, and its address is cleared, so it is found again at its first call.
- **Code objects** load with no native code: no emitted code is saved.
- **Root cells** are referred to from the heap by index, so nothing in the heap needs rebinding. Only emitted
  code holds their addresses.
- **Streams:** the standard stream objects are kept and rebound to the process's handles, so every reference stays
  good. File streams load closed.
- **Pointers from C** load with address 0, which is dead.

An image is tied to the exact build that wrote it, by an identifier and a checksum of the primitive names.

## The lowerer and code objects

The lowerer does normalisation, tail positions, closure conversion, slot and call-window assignment, and
emission, and works on plain Shen lists. At runtime `eval-kl` is ordinary guest code: it runs the lowerer, calls the
`install` primitive, which publishes the definition only once it is built, and then runs the result. So the
executable has no KLambda reader or lowerer in C, and the installer and the JIT translate instructions
mechanically.

A code object owns its bytecode, constants, frame size and compiled code. Closures and active frames hold their
code independently of named bindings, so replacing a binding does not disturb an old closure or a running
frame.

## Guest frames and calling convention

### Frames and call windows

A frame's physical header is one raw word, its return address, at `[FP]`. Slot 1 holds the callee's procedure,
which is also its closure environment, and the arguments follow in slots 2 to n+1. Everything else is static or
derivable: the slot span is fixed per function, the caller's frame is recovered by subtracting the window
offset known at the return label, and no frame stores a pointer into the stack, so moving the stack only
requires rebasing the frame pointer.

Calls use overlapping windows, as in Lua. For each call, the lowerer chooses a window offset `A` above every
slot live across the call, and evaluates the arguments directly into the window, so an ordinary call copies no
arguments. A function's frame covers its largest outgoing window, so a caller only ever writes inside its own
frame. Two invariants follow:

- At a call, every caller slot at or above `A` is dead, except the window itself, which becomes the callee's.
- Every slot live across a call lies below `A`.

A tail call puts the new procedure and arguments in slots 1 to n+1, the arguments of a named one computed there in
place where they can be, keeps the frame pointer and return address, and transfers with no host frames accumulating. The protected expression of `trap-error` is compiled
out of tail position, so a tail call never replaces a frame whose handler is active.

Language arity is apart from the physical entry. A named call with the wrong argument count raises an error, and
applying a closure to extra arguments is nested application, except that when they are all variables or constants, a
closure whose code has `(entry N L)` takes all N in one call, as such code accepts two counts. There is no
partial-application object.

### Native calling convention

One SLJIT context is shared by every compiled function and the C entry adapter. Compiled functions have no host
frames: a return is an indirect jump through the frame's return address, and C is called only through
`sljit_emit_icall`. SLJIT's own guest calls would put every non-tail call on the C stack, which rules out moving
the stack and unwinding many frames without `longjmp`.

S0 holds the frame pointer, S1 the VM, S2 CACHE and S3 the heap pointer, which is written back around any call to C
that may allocate. S4 and up hold what the refinements below keep, and the argument count travels in R2.

The callee checks the argument count, passed in a register. So uncompiled functions and foreign functions are just
other entry addresses, and call sites need no checks of that kind.

```text
call f (arguments already in slots A+2..A+n+1):
  load P from f's global cell
  check that P is a procedure, else jump to the not-a-procedure path
  store P at [FP+A+1] and the return label at [FP+A]
  FP += A; COUNT = n
  jump to P's entry
return label:  FP -= A; store the result in its destination slot
entry:         if COUNT != n, jump to the arity stub
               if FP + frame size > limit, jump to the stack-growth path
return:        result to the return register; jump through [FP]
tail call:     load and check P; move P and the arguments into
               slots 1..n+1; COUNT = n; jump to P's entry
```

A sealed call loads P from a constant slot of its own instead, with no test: it was bound at install or, for a
definition not there yet, is bound once at its first call. A stage 0 definition is sealed, and with `--seal` a user's too.

Some refinements are built on that:

- **The first argument also travels in a register,** CACHE, which holds the last result. A callee that reads slot 2 before
  its first branch starts with it cached. The slot, not the register, is the root, so whatever may collect
  reloads CACHE from the slot.
- **A result read only from CACHE is not stored,** when nothing between it and its one reader could collect.
  Liveness walks share a work stack and an array of visited marks for one compilation, clearing the marks
  before each walk. If either buffer could not be allocated, the store is kept.
- **Tests branch directly.** A Boolean primitive followed by a jump on its result branches on the comparison and stores
  nothing, and after a `cons?` that falls through, `hd` and `tl` of that slot need no test. A run of conses, as a chain
  with constant heads lowers to, checks room once and passes each pair on in CACHE.
- **Leaves skip the stack check:** code that makes no call, with a frame of at most 64 words. Every check
  reserves 64 words beyond its own frame, and `jit_call` reserves as much, so a leaf's frame is always in checked space.
  Tail calls do not count against a leaf, except in code compiled once something needs interrupts seen, since
  functions that call each other in tail position loop, and only their entry checks see an interrupt.
- **Loops keep their slots in registers.** Code that loops through a self tail call, makes no call but named tail calls and has no
  handlers keeps slots 2 and up in registers when they fit: six on arm64 and four on x86-64. Those are saved registers, except for two
  of the four on x86-64 outside Windows, which are scratch registers, unless code written by hand uses them, and wait in the frame around any call to C. Code written by hand
  with more raw values than scratch registers gives them the saved ones instead ([bytecode.md](bytecode.md), "Real and word registers"). It stores them back before any call
  into C that may collect or raise, and loads them again after a collection, so the frame's words are always
  valid and the collector never sees a stale pointer.
- **Two more registers hold results read again soon.** Code with no slots in registers and no raw values keeps up to two
  slots besides CACHE's when an instruction a little further on reads them: a result that CACHE need not hold, or what CACHE held when it is about to change. Each is still
  written to its slot, so the collector and the slow paths see nothing new. A label keeps what all the ways into it agree on,
  a call drops them, and a slow path that may have collected loads them again before going back.
- **Loops exit out of line.** A test that ends a loop, an `=` with a constant symbol, number or special whose true branch only returns, jumps
  to a return placed with the slow paths, so a turn of the loop takes one jump, back, instead of two.
- **Small functions are inlined,** by the lowerer, sealed or open. An open one sits behind a test that the name's
  definition still has that body, which on arm64 and x86-64 is a nop that a redefinition patches into a branch to the ordinary
  call, and elsewhere a test each time. Bodies inlined after stage 0 are marked in the bytecode, so a backtrace names them as if
  they were not inlined.
- **Open self tail calls are patched too:** they jump straight back to the body, and a `defun` of the name rewrites
  that branch, so the next turn reaches the new definition.

### Stubs

Shared stubs and one slow path run before a callee's frame exists: compile-on-first-call, arity mismatch, each function's own stack growth and
foreign functions' entry. Any of them may collect. At each one, the frame pointer is already the callee's, and the
published scanned extent ends after the window, so the procedure and arguments are rooted in the window, and nothing
managed is held only in a register.

### Exceptions

There is a handler stack with direct resumption. A handler record holds a frame offset and a catch address, and no
managed values: the handler is code at a label of the same function, and H is evaluated only once something has raised. Raising goes through one shared stub: C
makes the exception, pops the record, sets the frame pointer and returns the catch address, and the stub
jumps there. Helpers that may raise return `V_CLEARED`, checked only at their call sites. Guest calls are never followed
by a status check, and `setjmp` and `longjmp` are not used.

The kernel raises in ordinary control flow, so this stays cheap. A handler that never reads its exception is quiet, and
an error raised while it is innermost builds no exception at all. Under a quiet handler of the same code, a primitive that would
raise jumps to it directly, popping the record, and if nothing else in the protected code can raise, no record is pushed at all.

### Re-entry and stack growth

No helper calls guest code: `eval-kl` is guest code, and dictionary folds iterate in guest code over snapshots
that C produces. C written for Shen does call in, through `jit_call_nested`, which pushes a handler with no catch address, so an
error stops at the boundary and comes back to C by value, and which checks a bound on the native stack.

The limit frames check is the mark of how far the stack has been dirtied (see Collection). Passing it raises the mark, with a
margin, and only past the end of the stack does the stack double, up to 1 GiB, beyond which it raises an error: the used part is copied, the rest filled with the cleared value, and the
frame pointer rebased. Handler records hold offsets and frames hold no stack pointers, so nothing else needs
rebasing. It never shrinks while guest code runs.

## Values

Values are 64-bit words, with the low bits as tags ([semantics.md](semantics.md), section 2): 62-bit fixnums with a zero
tag, header-free pairs, and tags for symbols, procedures and other objects.

Pairs stay at two words, so the collector's linear scan and the image's relocation need another way to tell a pair
from an object: every other object starts with a header word whose low bits no value has. A word at the start of an object is then
either a header, which gives its size and which fields hold values, or the head of a pair.

Symbols are ordinary heap objects, so the image is a single heap. Each stores a hash computed from its name, so
hashing never depends on an address that moves. A symbol refers to its global cell by index. Cells and constant slots
live outside the heap, in root arrays that grow by adding chunks, so none ever moves, and emitted code embeds their addresses and never a
heap address. Native code lives in SLJIT's executable memory, and a collection frees that of code objects it did not reach, except under a profiler, and what was compiled before everything compiled again, which frames may still be running.

## Collection

Allocation bumps a cursor that emitted code checks against a limit, and the slow path collects, after which the
instruction runs again. There are no write barriers or remembered sets.

New objects always go in one area, from its start after every collection, and what a collection keeps goes back and forth
between two spaces. So the memory written to is the same each time and stays in the cache, where two semispaces taking turns
would be twice as much. Every collection still copies all that is live, as there are no generations. The area's room is what the
kept data leaves of a semispace's size, so collections come as often as with two semispaces, and at worst as much memory is
touched. The three lie in one reserved block of address space, with the area between the spaces, so that one range holds what a
collection may move and not where it copies to. They grow in place to keep a semispace's size at least five times what is live, so that a
collection copies at most a word for every four allocated. With its own area the heap need not grow in steps, which would make the cost of what is live a sawtooth.

- **Lists stay contiguous.** Cheney's breadth-first order scatters a list's pairs among everything else live, so when a pair is
  copied, the pairs of its tail are copied right after it.
- **Large objects:** vectors, strings and byte buffers of 32K words or more are allocated apart and copied only into an image. Collections mark
  them, scan them in place and free the dead ones, whose blocks wait one collection for an object of the same size.
- **Weak things:** the intern table holds symbols weakly, and symbols nothing needs are dropped, their global cells reused, and those above the last one kept taken out of the array that collections walk; streams nothing reaches are closed; the
  constant slots of dead code are reused; and a guarded pointer nothing reaches has its value put on a list for Shen. That value is a root until then, so nothing has to come back
  from the dead, and what one value uses outlasts it. The list's pair takes less to-space than the pointer, which is not copied, leaves free.
- **Repeated pointers** are skipped while scanning, which matters for the Prolog engine's big vectors.

Reals are boxed, each a 16-byte object, and native code does their arithmetic and comparisons on its slow path, after the
test for fixnums fails, loading each operand into a float register and allocating the result in line. Code written by hand can keep them unboxed
in real registers, and 64-bit integers in word registers, which the collector never sees ([bytecode.md](bytecode.md), "Real and word registers").

The roots are the scanned extent of each thread's guest stack, the global cells and constants, what C holds, and a few VM
fields. C holds values in explicitly registered locals, per thread, and in the roots that outlive a call (`shen_root_new`), which a
thread with no lock may delete, so a collection first drains the list of those deleted.

The stack is scanned linearly, from its base to the published top, which three rules make sound:

- **Clear above the top.** Each collection clears the slots above the published top, up to a mark of how far the stack has been
  dirtied. Those slots are dead by the call-window invariants, and would hold stale pointers when a larger caller resumes. So every slot always holds
  a current value or the cleared value, and functions need not initialise their slots.
- **The stack never shrinks during guest execution, and new stack starts cleared.**
- **Return addresses scan as fixnums.** Return labels are aligned to 4 bytes, so their low bits match the zero tag.

Under `SHEN_JIT_GC_STRESS` the collector also overwrites where objects were, and new objects go past those words for as long as they
fit, so that a stale pointer fails at once. `SHEN_JIT_SLOW_PRIMS` compiles every primitive as a call to C, so that `make test-differential` can compare what the JIT inlines with the C versions.

## Threads

`thread` makes real threads, of which one runs at a time, holding a global lock. A timer asks for a switch every 10 ms if another
thread is waiting, by the same mechanism as an interrupt: it clears the limit that frames check, so the next function entry or loop check comes to
the runtime. Each thread has its own guest stack, handlers, C roots, native stack bound and saved error codes, swapped as the lock changes hands.
A thread about to wait gives the lock up, and a foreign call can too. Waiters are served in order, each woken by its ticket rather than all at
once, since threads waiting on sockets take the lock often.

`SIGPIPE` has a handler that does nothing, set at startup, so that a write to a closed pipe fails and raises. Being a handler and not `SIG_IGN`,
exec resets it, and a child finds the default.

The first thread has everything compile again on its next call, since loops must then test for a switch, and code compiled before need not have.
The same goes for the REPL, when it starts catching Ctrl-C.

## Calling C

Foreign functions are procedures entered through one shared stub, so a call needs no new instruction and no code per signature. See
[ffi.md](ffi.md).

Memory outside the heap is a pointer with a length, and the byte primitives take one as they take a buffer. Their compiled code tests for a buffer, as it always has, so a buffer's path
is unchanged. A loop that calls nothing and reads through a parameter it never changes works these out once on the way in ([bytecode.md](bytecode.md), "Byte buffers and bit operations"). Otherwise, what is not a buffer leaves through an out-of-line block that tests for a pointer, loads its length and address into the registers the buffer's length and base would be in, and comes back for the
same bounds check and access. A pointer that is dead or has no length has length 0, so nothing else needs to test for that.

## Datalog

`lib/datalog.shen` is Shen, loaded on request, and the JIT knows nothing of it. A program is checked into relations and rules, and planned: relations
by strongly connected components in dependency order, and each rule as an order of joins, the atom with the most columns known going next. In a
recursive component a rule has one variant for each of its atoms in that component, which reads that relation's new tuples and goes first, as a new
derivation must use a new tuple somewhere. So that a derivation from several new tuples is made once, by the variant of the first atom to read one,
the component's atoms before that one read only the old tuples, from before the round's new ones, and those after it read all: a scan stops where
the new tuples begin, a walk along an index's chain, which runs from the newest, skips those, and a probe of the table ignores them. Join order is chosen as a run goes, from the sizes of the relations, and again when one has doubled: the next atom is the one expected to give the fewest tuples for what is known, from
an index's tuples per key if it has one, and otherwise as if the columns were alike and independent. Each order becomes code, described below, kept with the program, as a rule has only so many orders.

A negated atom counts as a dependency too, so its relation's component comes first, and the checker refuses a program where a relation depends
on the negation of one in its own component. A negated atom is then a condition, like a comparison, placed as soon as its variables are bound:
it probes the relation's own table for a whole tuple, an index for some columns, and asks only whether the relation is empty for none.
The reference evaluator does not use the components: it numbers strata from the rules and runs each to a fixed point in turn.

`(= V E)` whose `V` nothing has bound yet, once everything in `E` is, becomes a step that binds `V`, which may make other conditions ready and lets the
atoms after it look `V` up. In a kernel, each operation of an expression goes to a word register and is checked to be 32 bits, the second operand
of each in the register after the first's, so that a few registers serve any depth; a bound variable keeps its register. A result outside 32 bits
returns a code above any place to start again from, and the KL around the kernel raises. Kernels have no division and cannot intern, so a plan that divides, takes a mean, works on strings or shifts by other than a constant from 0 to 31 is KL from the start. There a function with no value, division by zero or `to-number` of what is not a number, gives `[]`, which no value is, and a binding or comparison that meets it does not hold; the reference does the same.

The checker turns an aggregate into a condition that records its keys: the variables of its atom that appear elsewhere in the body. Its relation
is a dependency that must be complete, as a negated one is. Once its keys are bound it is a fold step, which binds its variable, or compares when
that is bound already. A kernel keeps its value in a register: a loop over the relation for no keys, a probe of its table for a whole tuple, and a
probe of an index and a walk along its chain for some columns. `min` and `max` start just outside 32 bits, where they stay over no tuples, and
a sum is checked once at the end, so that the order of the tuples cannot change whether it raises. KL folds in a loop function that returns the
value.

An equivalence keeps its classes, not their pairs. Rules add pairs to its own storage as to any relation's, an inbox that each merge empties into a union-find: each value's root and each root's members, the smaller class joining the larger. The classes that changed are then laid out again at the end of a buffer of five words a position: a value, its class's range of positions, and the range of the part of it that was one class when last laid out, a value new since being a part of its own, whose range is empty. A class's pairs are its range, the old ones a value's part and the new ones the rest, and the new pairs are those of the positions from where the changed classes start, so semi-naive evaluation reads old and new pairs that are never stored. A class's earlier positions become holes, with empty ranges, and a table by value, an index of the buffer's first column, finds a value's latest position; when the holes would outnumber the values, or the buffer or the table is full, every class is laid out again into new ones. Kernels scan an equivalence by position and class, look one value up by the table and walk its class, and check a pair by two probes and a comparison of the classes' starts, or for an old pair whether the second position is in the first's part; a negation or an aggregate over one is KL. A lookup is estimated at the size of a pair's class, averaged over the pairs, which a skewed equivalence's largest class dominates, as a join's keys do. The reference adds the three rules of an equivalence instead. Demand computes an equivalence in full, as it does what is negated.

A relation of one tuple a key has a second table, by the columns before its last, whose entry for each key points at the best tuple so far. An insert that is not better is refused there; one that is better is added, and the key's entry moves to it, leaving the other where it is, dead: storage still never deletes, and kernels read such a relation as any other. Within its own recursion a dead tuple can still be read, which derives only what is no better and so is refused in turn. When its component is done, the relation is made again from the tuples its keys point to, so later components read only those; an add evaluates again what reads one that changed, as a better tuple may have replaced one it read. A lattice is such a relation whose better tuple holds the least upper bound of the old value and the new: for `bor` and `band` a kernel joins them in a register and adds the tuple only if that changed the value, and for a Shen function KL calls it inline, so those rules are KL. The reference puts a rule that reads one of these from outside its recursion a stratum after it, as it does one that negates.

`datalog.add` notes each relation's size, its mark, adds the facts, and goes through the components in order. One that reads only relations that
grew, positively, goes on semi-naively: each relation that grew reads what is past its mark as new, every rule runs once with one variant for each
atom of such a relation, and the component's own rounds follow. One that negates or aggregates a relation that changed, or reads one that was
evaluated again, could lose tuples, so its relations are emptied, given their facts again, kept with the database for this, and the component runs
as in `datalog.run`. Plans and kernels are the same ones, kept with the program.

`datalog.remove` never deletes a tuple from storage, whose buffers, tables and index chains only grow. It takes the facts out of those the
database keeps, and goes through the components in order: one that holds a relation that lost a fact, or reads one evaluated again, is emptied to
its facts and evaluated again, and the rest stay. Deleting and rederiving would be faster for a small removal from a large recursive relation, but
would need storage that can delete, and so a check of each tuple in every kernel, or compacting after each removal.

Symbols and strings are interned, the program's own constants first, so that generated code can hold their numbers, and an integer is its own 32 bits, so that arithmetic and comparisons need no table. A record is interned too, in a table of its type's, after the relations in a run's state: a tuple of u32 columns, its constructor's number and its fields, as many as the type's widest constructor has, so that a column of that type holds the record's position there, and equal records are equal words. A body atom takes a record apart by reading its fields at that position, its tag checked first, as a field of another constructor may not be a record at all; a head, `=` or a lookup's key makes one as a head adds a tuple, found or added, and a kernel with no room in that table starts again as it does for the head. A relation's tuples are u32 columns one after another in a byte buffer, which the collector does not scan, with the
new tuples and those for the next round as ranges of it. A round reads only what was there when it began, so a loop can keep the buffer it started with while growing replaces the relation's. A table of 64-bit entries, open addressed, deduplicates: each holds the top half of its hash, which
also says where it goes when the table grows, and the tuple's position plus one. An index is such a table by key, for the first tuple with that key, and a chain of u32s for the rest, made for each set of columns this run's plans look up, when first needed. Keys that are a whole tuple use
the relation's own table. Inserting, finding, indexing and growing are kernels of word registers from `lib/native.shen`'s assembler, one for each shape of tuple or key.

Each join order is a kernel too, written with that library's structured control: a `for` over a scanned range, a probe and a `while` along an index's chain for a lookup, and the head's insert inline, so that it calls nothing. A variable costs no register,
as it is read from its tuple's column where it is used. When the relation it adds to has no room, the kernel returns where its outermost scan stood, plus one, and a KL function around it grows the relation and calls it again from there, which is sound as deriving a
tuple twice does no harm; below a first step that is not a scan, it starts again from the beginning. A plan that needs more registers than the assembler has, or that it refuses for any other reason, is compiled as KL through `eval-kl` instead, with a function for each atom's loop.
`datalog.query` rewrites a program by magic sets for the query's adornment, its columns bound by a constant or free, and keeps the result with the program, one for each adornment. Each relation the query reaches through positive atoms gets a copy for each adornment it is reached with, whose rules begin with a magic relation of the values asked for in its bound columns, and a rule that takes the relation's own facts. A magic relation's rules pass bindings from a rule's head through the atoms that bind more, in the order the planner would choose with no sizes, with the conditions that are ready, to the next atom of a copy. A relation read under a negation or an aggregate must be complete, so it keeps its own rules, with all it depends on, and no copy reads it, which also keeps the rewritten program stratified. The query's constants are the one fact of its magic relation.
Each merge has a number, larger than any before it, and a relation keeps the numbers of the merges its tuples came in. A round derives only from tuples merged before it: scans and chains read merged tuples, and so does a probe of a relation's table, which could otherwise see a tuple added earlier in the same round. So `datalog.explain` needs nothing recorded per tuple: for a tuple that is not a fact, it finds a rule instance whose atoms' tuples were all merged before it, which the derivation that made it is, and explains those in turn, which ends, as the numbers fall.
`datalog.run-naive` works from the definition, over lists, and shares only the checker.

## Left out on purpose

- **An interpreter.** A target without an SLJIT backend could add one: the slot layout and instructions do not depend on the JIT. It would be
  selected for the whole VM, never mixed with native code.
- **A generational collector.** The C API is written so that one stays possible: see [ffi.md](ffi.md).
- **Bignums.** An integer result outside the 62-bit range raises an error.

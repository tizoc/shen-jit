# Calling C

There are two ways to call C from Shen/JIT, kept apart:

- **Plain C,** any existing library, is declared in Shen with `define-foreign`, and needs no compiler.
- **C written for Shen** takes and returns Shen values and can call Shen, with [`include/shen.h`](../include/shen.h), and is
  declared with `define-foreign-procedure`.

Both are in `lib/ffi.shen`, which stays out of the image and has to be loaded before the code that uses it, under `(tc -)`:

```sh
shen-jit eval -l lib/ffi.shen -l program.shen
```

`lib/sqlite.shen` and `lib/socket.shen` are written over it in Shen alone, and show what it covers. **None of this is stable until 1.0:**
it may change before then, and `SHEN_API_VERSION` says when the C API has.

## Plain C

```shen
(shen-jit.library libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
(define-foreign c-cos libm "cos" (double) --> double)

(c-cos 0)    \\ 1.0
```

A library is named once, by a symbol, with the file names to try in order. `[]` means the executable and what it links, which on Windows
reaches nothing, as the executable is static. A definition's C name and types are expressions, which lets one definition suit each system:
`lib/socket.shen` has `(socket.type)`, which is `int64` on Windows and `int32` elsewhere.

| Type | As an argument | As a result |
| --- | --- | --- |
| `int64` | a fixnum | raises if it does not fit 62 bits |
| `int32`, `uint32` | a fixnum in range | the low 32 bits, sign- or zero-extended |
| `double` | a real or a fixnum | a new real |
| `string` | copied to a NUL-terminated buffer for the call; a NUL inside raises | copied into a new string; NULL is `[]` |
| `pointer` | a pointer of any kind, or `[]` for NULL | a pointer of kind `pointer`; NULL is `[]` |
| `bytes` | the address of a byte buffer, for the call | not allowed |
| `bool` | `true` or `false`, as 1 or 0 | the **low byte** alone, all a C `bool` defines |
| `void` | not allowed | `[]` |

A function returning C's `int` leaves the upper half of the result register undefined, so it must be declared `int32`. There is deliberately no
type called `int` or `long`, since `long` is 32 bits on Windows and 64 elsewhere.

**Flags** follow the result:

- **`blocking`** gives up the lock around the call, so other threads run. A `bytes` argument is then copied to memory of its own and back, since
  another thread's collection may move the buffer, and one buffer given twice is one copy. With no other thread it is an ordinary call.
- **`(varargs N)`** marks a variadic function with N fixed arguments, from 1 to 3, all integers. It is needed: Apple's arm64 passes variable arguments
  differently from fixed ones. `fcntl` is one.

**Limits:** at most 6 arguments that are not doubles, and at most 8 that are. No structs by value, and no `float`. A wrapper in C costs a few lines.

A system function cannot be redefined this way, and a library must be named with `shen-jit.library` before it is used.

**Finding functions:** at the first call, so a saved program finds them again in its own process. A function that cannot be found raises
`foreign: cannot find cos in libm`, and a static Linux build raises `foreign: this static build cannot load libraries`.

**Errors:** `(shen-jit.errno)` is what the last call declared with `define-foreign` on this thread left in `errno`, or on Windows in `GetLastError`, which is also
`WSAGetLastError`, and there `(shen-jit.c-errno)` is the C library's. Both are saved straight after the call.

**Pointers** have a kind, a symbol, for reading and for messages.

| Function | What it does |
| --- | --- |
| `(shen-jit.pointer? X)` | Whether X is a pointer |
| `(shen-jit.pointer-kind P)`, `(shen-jit.pointer-address P)` | Its kind, and its address as a fixnum |
| `(shen-jit.bytes->pointer B I Kind)` | The pointer at offset I in a buffer, for out-parameters; `[]` if NULL |
| `(shen-jit.pointer->string P)` | Copies the NUL-terminated string it points to |
| `(shen-jit.pointer->bytes P I N)` | Copies N bytes from offset I. Unchecked by nature |
| `(shen-jit.pointer-kill P)` | For a library, once C has freed what P points to: P then raises when given to C or read |
| `(shen-jit.pointer-sized P N)` | A new pointer to the same address and of the same kind, whose N bytes can be read and written in place, and which keeps P alive |
| `(shen-jit.pointer! B I P)` | Stores a pointer's address at offset I, or NULL for `[]`, and returns B |
| `(shen-jit.pointer-read-only P)` | A new pointer to the same memory, which keeps P alive, and raises when stored to, as any copy of it does |
| `(shen-jit.pointer-guard P V)` | A new pointer like P, with the same length, whose V is handed back once nothing reaches it: see below |
| `(shen-jit.pointer-owner P)` | The pointer that P was sized or made read only from, the V it was guarded with, or `[]` |
| `(shen-jit.pointers-dead)` | The values of the guarded pointers that have died since it was last called, as a list |
| `(shen-jit.collect)` | Collects now |

`=` compares kind, address and whether it is read only, and a pointer prints as `#<pointer sqlite3 0x...>`. One saved in an image loads dead.

**Memory outside the heap** is a pointer with a length. Pointers come from C with none, which refuses any read. `shen-jit.pointer-sized` states one, and then
what works on a byte buffer works on the pointer, checked against that length: `shen-jit.u8` to `u32`, `s32`, `s64`, `f32`, `f64`, their stores, `bytes-length`,
`copy-bytes`, `bytes->string`, `bytes->pointer` and `pointer!` ([bytecode.md](bytecode.md), "Byte buffers and bit operations").

```shen
\\ struct point { double x, y; int32_t id; };   /* 24 bytes */
(define-foreign make-points mine "make_points" (int32) --> pointer)
(define-foreign free-points mine "free_points" (pointer) --> void)

(let P (make-points 1000)
     M (shen-jit.pointer-sized P 24000)
  (do (shen-jit.f64! M 72 1.5)                                     \\ x of point 3
      (output "~A ~A~%" (shen-jit.f64 M 72) (shen-jit.s32 M 88))   \\ and its id
      (shen-jit.pointer-kill M)
      (free-points P)))
```

- **It stays where it is,** so C may keep the address, and a `blocking` call passes it as a `pointer` with no copy. The collector neither copies nor scans it.
- **The length is trusted.** It is the one thing not checked, and a wrong one, or memory C has freed, can crash. Kill a pointer once its memory is gone: address and length become
  0, so the ordinary bounds check refuses it.
- **Each sized pointer stands alone.** Killing one kills no other, nor the pointer it came from. It does keep that pointer reachable, which matters if that one is guarded.
- **Nothing frees it for you.** `lib/memory.shen` has `(memory.alloc N)`, which gives N zero bytes, and `(memory.free M)`, over `calloc` and `free`. A saved image holds such a pointer dead, and the
  memory itself is not saved: a byte buffer is what lasts in an image.

`lib/mmap.shen` maps files the same way, on each system: `(mmap.read Path)`, `(mmap.read-write Path)`, `(mmap.create Path N)` and `(mmap.close M)`, over `mmap` and `lseek`, or `CreateFileMappingA` and
`MapViewOfFile`. `mmap.create` takes a positive integer size, and refuses anything else before it touches the file; `mmap.close`
raises if the system cannot unmap, and the pointer then stays as it was. What `mmap.read` gives is read only, so a store raises instead of ending the process; an access past the end of a file that something has since made shorter does end it, as no check can catch that. C can still write through a read-only pointer given to it, which ends the process too.

**Guarded pointers** let Shen release such memory once nothing uses it. `(shen-jit.pointer-guard P V)` makes a copy of P, the guarded pointer, and holds V strongly. Once nothing else reaches the guarded pointer, a
collection puts V on the list that `(shen-jit.pointers-dead)` gives, and Shen does the rest: nothing runs during a collection, and whatever releases the memory can be any Shen function.
`lib/handle.shen` does it in Shen alone, as `(handle.wrap M Release)`, `(handle.close H)` and `(handle.sweep)`, and counts what handles hold to bring a collection, since memory outside the heap brings none by itself.

- **V must not refer to the guarded pointer,** or it stays reached. V may refer to another guarded pointer, which then outlives this one, so what uses another is released first.
- **It says nothing of when.** It needs a collection to be seen at all, and a frame can hold, in a slot it has not written yet, what an earlier frame left there, so a pointer may outlast its last use.
- **A call keeps its arguments.** A guarded pointer given to C stays reached until the call returns, even a `blocking` one. C that keeps the address after that must keep the pointer too.
- **A saved image holds it dead,** with no owner and no guard, and its value is never handed back.

**Typed code:** a declaration whose types are all plain Shen types, and whose result cannot be NULL, also emits a `declare`, with `int64`, `int32`,
`uint32` and `double` as `number`, `bool` as `boolean`, and `string` for an argument. Others leave the declaring to the program, under `(tc -)`, since
`declare` does not typecheck under `(tc +)`, and so does `define-foreign-procedure`, which never emits one. A function defined again
loses the type of its earlier definition when the new one does not emit one.

## C written for Shen

A procedure is declared with its arity alone, up to 8, and has one C shape, in which `args` is an array already rooted:

```shen
(shen-jit.library mine ["./libmine.so" "./libmine.dylib" "mine.dll"])
(define-foreign-procedure on-each mine "on_each" 2)

(on-each [1 2 3] (/. X (output "~A~%" X)))
```

```c
#include "shen.h"

/* Calls args[1] on each element of args[0]; an error in the callback propagates. */
shen_value on_each(shen_vm *vm, shen_value *args)
{
    shen_value l = args[0];
    shen_root(vm, &l);                     /* args[] is rooted already; l is not */
    while (shen_is_pair(vm, l)) {
        shen_value x = shen_head(vm, l);
        if (shen_call(vm, args[1], 1, &x) == SHEN_ERROR)
            return SHEN_ERROR;
        l = shen_tail(vm, l);
    }
    return SHEN_TRUE;
}
```

```sh
cc -shared -fPIC -I include -o libmine.so mine.c
```

It links against nothing: `shen_vm` is a pointer to a table of functions, which the wrappers in `shen.h` call through. `shen.h` opens with the rules and lists every function.

- **A value is valid until the next call that may allocate,** unless it is in a root. Reads do not allocate, so a loop over a list needs no root.
- **Never nest two allocating calls in one expression:** `shen_cons(vm, shen_cons(vm, a, b), c)` may read `c` before or after the inner call.
- **Errors are values.** `shen_raise` and `shen_raise_value` give `SHEN_ERROR`, for C to return; so does `shen_call` when nothing in the callee caught the error,
  and C returns it, or reads `shen_exception` and goes on. No `longjmp` crosses C, so a library calling back is safe.
- **Roots:** `shen_root(vm, &local)` for a call, undone when a procedure returns, however it returns. `shen_root_new` gives a `shen_root_box` that outlives the call, for a callback's
  closure, say. Deleting one needs no `shen_vm` and no lock, so it can be done from anywhere.
- **The lock:** `shen_release` and `shen_acquire` let other threads run while C waits. Between them, touch no value.
- **Threads:** a callback must come on the thread that called the library: a thread the runtime did not start cannot call in.
- **Memory:** nothing malloc'd by one side is freed by the other, and no `FILE *` crosses.

**Reads never allocate or raise.** One of the wrong type gives `SHEN_NONE`, or NULL, or as `shen.h` says.

**Mistakes end the process, with a message naming the procedure:** passing `SHEN_NONE` or `SHEN_ERROR` on, returning `SHEN_NONE`, or a value left over
from before a collection, where that can be seen. So test with `SHEN_JIT_GC_STRESS=1`: every allocation then collects, and every read checks its value too, which finds
most of what breaks the first rule. A value that a collection had already kept, and that then lives through an even number more, points back into the heap, as the two spaces take turns, and goes unseen.

A callback from a library that takes userdata needs nothing more. It runs inside the foreign call that started it, so `vm` is still valid:

```c
struct walk { shen_vm *vm; shen_root_box *fn; int failed; };

static int walk_callback(void *data, int i)
{
    struct walk *w = data;
    shen_value x = shen_make_fixnum(i);
    shen_value r = shen_call(w->vm, shen_root_get(w->fn), 1, &x);
    if (r == SHEN_ERROR)
        w->failed = 1;
    return r == SHEN_ERROR;
}
```

## How it works

A foreign function is a `T_FOREIGN` object, `[entry][desc][address][arity]`, with a procedure's tag, and every one enters through the same SLJIT stub, beside
the arity and compile stubs. So no instruction is new and there is no code per signature. `desc` is an absvector that `lib/ffi.shen` builds, of the name, the library, its file names, the C name, the result, the flags, the kind of a
pointer returned, and the argument types.

The stub publishes the window, calls `h_foreign`, jumps to the unwinder on `V_CLEARED`, reloads the frame pointer, since a nested call may have moved the guest stack, and returns through slot 0.

`h_foreign` (`src/runtime/ffi.c`) reads the procedure and the arguments from the window, finds the function if this is its first call, converts into argument words and doubles, and calls through a cast:

- **POSIX:** integers and doubles take their registers independently, so two casts, for an integer and a double result, fill all of them, and a function reads those it has.
- **Win64:** the first four arguments each take a register by position, so there are 16 casts, by which of them are doubles, for each kind of result, with later arguments as raw stack words.
- **Variadic:** a cast for each number of fixed arguments, as functions of their own and not inlined. As cases of one `switch`, Apple clang made one call of the three, with the last's type.

C for Shen is given the address of `vm->api`, whose first word is the table, and the runtime finds its `VM *` by offset. So the extension links against nothing, on any target. Exporting symbols from the executable would have worked on one of the release configurations: a static glibc executable gives
`undefined symbol` to a library calling into it, and a stripped macOS executable exports nothing.

`shen_call` wraps `jit_call_nested`, which pushes a handler with no catch address. `h_unwind` pops it and returns NULL, so the adapter returns `V_CLEARED`, and an error never jumps across C frames. The handler is not quiet, so the message is built for C to read.
Handlers, C roots, the native stack bound and error codes are per thread, swapped with the lock.

A root that outlives a call is four words that never move: its table, its value, a link and the VM that made it. `shen_root_delete` takes no `shen_vm`, so the wrapper finds the table in the root itself. It pushes the root on its VM's lock-free list, which that VM drains at the next
`shen_root_new`, collection or its end. The link is apart from the value because a collection may be writing the value while another thread deletes it.

**A later collector.** C reads through calls, allocates through calls, and writes only through `shen_vector_set` and `shen_root_set`, which is where a write barrier would go, and holds nothing across an allocation except in roots. The header names no tag, header bit or layout but
the fixnum encoding and a few constants. The one assumption left is that the heap does not move while a thread holds the lock and makes no API call, which `shen_bytes_data` and `shen_string_bytes` need and any stop-the-world collector gives.

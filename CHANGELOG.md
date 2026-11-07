# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Compiling and loading a long definition takes far less time when it has many inlined calls, many closures or a
  long Prolog clause body, each of which made the time grow with the square of the definition's size.

## [0.4] - 2026-11-06

### Added

- `make test-differential` runs each primitive over generated values, however it is compiled and through C, and
  `make differential-scheme` lists what differs from Shen/Scheme.

### Changed

- Moved to the Shen kernel 43.4, from 43.2.
- Moved to Shen/Scheme 0.54, from 0.53, as the other host that can build a checkout, and what `make bench` compares
  against.
- Compiled code keeps more values in registers between instructions, which speeds up small interpreters and other code
  that works on values it has just taken apart.
- Compiling a long literal list takes far less, and with constant elements the list uses one frame slot instead of one
  per element.

### Fixed

- `define` no longer fails on a `cond` with no true clause. The definition compiles, and raises an error when no
  clause applies.
- `absvector` too large for `SHEN_JIT_MAX_HEAP` gave a handler `[]`, on which `error-to-string` failed, instead of
  an "out of memory" error.
- `absvector` with a length of 2^56 or more crashed. It now raises an error from 2^48 up, as `shen-jit.bytes` does.
- `shen-jit.pvar` and `shen-jit.pvar-offset` raised past a `trap-error` in the same function whose handler ignores
  the error.
- `write-byte` and `close` raise an error when the write fails, as on a full disk, instead of losing the data silently.

## [0.3] - 2026-11-06

### Added

- Memory outside the heap: `shen-jit.pointer-sized` makes a C pointer readable and writable in place, with
  the same functions as a byte buffer, each access checked against the length stated. `lib/memory.shen`
  allocates and frees such memory.
- `shen-jit.s32`, `s64`, `f32` and `f64` and their stores, on byte buffers too, and `shen-jit.pointer!`.
- `lib/mmap.shen`: all of a file as memory, on each system, with `mmap.read`, `mmap.read-write`, `mmap.create`
  and `mmap.close`.
- `lib/handle.shen`: memory that releases itself once nothing reaches it, with `handle.wrap`, `handle.close` and
  `handle.sweep`, over `shen-jit.pointer-guard`, `shen-jit.pointer-owner` and `shen-jit.pointers-dead`.
- `shen-jit.collect` collects now.
- `shen-jit.pointer-read-only` makes a pointer that raises when stored to, which is what `mmap.read` gives.
- Real registers in native code written by hand: `real`, `f64!`, `jump-unless` and `return-real` keep doubles
  unboxed in loops that call nothing, and `loop` and `again` make those loops, which can nest.
- Word registers there too: `word`, `jump-unless-word`, `return-word`, `word-box`, and `u8!` to `u64!` keep 64-bit
  integers that wrap, for hashes and random numbers, and as indices with no tag to check.
- `make bench-numeric` runs numeric programs and a path tracer in C and in Shen.
- The rendered guide now has how Shen/JIT works, its semantics, its instructions and calling C as pages of
  their own.

### Changed

- Arithmetic and comparisons on reals, and division, compile inline.
- A loop that calls nothing works out the memory it reads and stores through once, on the way in.
- In native code, machine registers go to what the deepest loops use most, whatever the order of the names, and
  an access to memory reached at one width takes one comparison.
- New objects now always go in the same memory, so a program that allocates uses much less of it, and allocates
  faster where two semispaces taking turns outgrew the cache. A process that only starts takes about 2 MB more.
- On x86-64 outside Windows, a loop that calls nothing keeps up to four values in registers, where it was two.
- The heap grows with what is live, not by doubling, so a program holding a lot of data no longer slows down as it
  nears the next doubling. Such a program can use more memory than before, at most about 1.7 times.

### Fixed

- `=`, `<`, `>`, `<=` and `>=` now compare an integer with a real exactly. From 2^53 up the integer was rounded to a
  double first, so `=` was not transitive, unification could depend on the order of its arguments, and two keys that
  were `=` could have different hashes.
- `=` no longer crashes on terms nested deeper than the C stack, in the head of a pair or in an absvector. A cyclic
  term still ends the process, now with a message.
- An integer literal too big for a fixnum, and one with a large exponent such as `1e300`, now reads as the
  nearest real. They could land slightly off it, as `1e100` read as `1.0000000000000006e100`.
- A burst of new symbols, such as from `gensym` in a loop, no longer slows every later collection for as long as
  the process runs.

## [0.2] - 2026-11-05

### Added

- A checkout now builds on Linux arm64, from `make deps`.

### Changed

- A checkout now builds with the previous release of Shen/JIT, which `make deps` fetches. Shen/Scheme can
  still build it, with `make BOOTSTRAP=...`, and makes the same generated files.
- The guide is centered on wide screens.

## [0.1] - 2026-11-05

### Added

- Initial release

[Unreleased]: https://github.com/tizoc/shen-jit/compare/v0.4...HEAD
[0.4]: https://github.com/tizoc/shen-jit/compare/v0.3...v0.4
[0.3]: https://github.com/tizoc/shen-jit/compare/v0.2...v0.3
[0.2]: https://github.com/tizoc/shen-jit/compare/v0.1...v0.2
[0.1]: https://github.com/tizoc/shen-jit/releases/tag/v0.1

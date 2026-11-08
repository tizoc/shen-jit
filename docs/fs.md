# Filesystem operations

`lib/fs.shen` adds paths, metadata, bounded directory listings and traversal, temporary files, copying,
renaming and replacement. File contents use our [I/O endpoints](io.md), independently of kernel streams.

## Building and loading

Build the optional native adapter with a C compiler:

```sh
make fs
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen \
  -l lib/io-file.shen -l lib/fs.shen -e '(fs.list "lib" [])'
```

The adapter uses the public `include/shen.h` API and platform headers for directory entries, metadata,
Unicode conversion and rename operations. It has no third-party dependencies. Paths, traversal,
temporary-file policy, copying and cleanup are written in Shen. The default runtime remains independent
of the adapter.

`make fs` writes `build/shen-fs.so` (`.dll` on Windows). Binary release archives carry its source,
header and build script, so from the installation root:

```sh
sh lib/build-fs.sh lib/shen-fs.so
# Windows, with the MSYS2 UCRT64 compiler: sh lib/build-fs.sh lib/shen-fs.dll
```

The script accepts `CC` and `CFLAGS`. Loading the Shen module never invokes a compiler. The facade
searches `./build/`, `./lib/` and the current directory for `shen-fs.so` and `shen-fs.dll`; set
`fs.*adapter-files*` to absolute library names before loading for another location. The adapter ABI
is 1. Fully static builds can use the lexical helpers but cannot load native filesystem operations.

## Paths

| Function | Result |
| --- | --- |
| `(fs.join Base Path)` | Lexical join; an absolute Path wins, and an empty Base is allowed |
| `(fs.parent Path)` | Parent, or `"."` for a single relative name; roots remain roots |
| `(fs.name Path)` | Last component, ignoring trailing separators; empty for a root |
| `(fs.extension Path)` | Last suffix including its dot, or `""`; `.env` and `name.` have no extension |
| `(fs.resolve Path)` | `[ok AbsolutePath]` or `[error Error]` |
| `(fs.resolve-at Base Path)` | Resolve a lexical join against the same home setting |

Paths must be nonempty NUL-free strings of at most 1 MiB. Joining accepts an empty base. POSIX names
remain bytes: invalid UTF-8 is passed unchanged to the OS, which may reject it. Windows paths use
strict UTF-8/UTF-16 conversion and reject unrepresentable names. Drive-relative forms such as
`C:relative` follow the file module's rejection policy. Windows helpers recognize drive roots,
UNC shares and extended UNC prefixes.

Resolution uses the existing file module's `*home-directory*` convention, snapshots it for the
operation, and produces paths that can be passed back to I/O without applying the home prefix twice.
It never changes the native process cwd. POSIX resolution preserves `.` and `..` components, including
their interaction with symlinks. Windows uses `GetFullPathNameW` semantics. This is not `realpath`,
and lexical path manipulation does not establish confinement to a directory.

## Metadata and errors

`fs.stat` follows the final link; `fs.lstat` reports the link itself. They return `[ok Info]` or
`[error Error]`. Metadata is an owned snapshot and remains usable after GC or image saving.

| Function | Result |
| --- | --- |
| `(fs.path Info)` | Resolved path used for the operation |
| `(fs.kind Info)` | `file`, `directory`, `symlink` or `other` |
| `(fs.size Info)` | Native byte size as an exact fixnum; directory/link sizes are OS-specific |
| `(fs.modified Info)` | `(@p UnixSeconds Nanoseconds)` |
| `(fs.accessed Info)` | `(@p UnixSeconds Nanoseconds)` |

Time pairs preserve native precision without fitting epoch nanoseconds into a single fixnum.
Seconds can be negative; fractional nanoseconds are nonnegative. Windows FILETIME values have
100 ns precision. Values outside the fixnum range produce an error rather than a rounded number.
Windows `lstat` conservatively reports reparse points, including directory junctions, as `symlink`.

```shen
(define project.file-size
  Path ->
    (io.let-ok Info (fs.stat Path)
      [ok (fs.size Info)]))
```

`fs.exists?` returns `[ok true]`, `[ok false]` or `[error Error]`. Only missing paths and a non-directory
prefix count as absent; access and other native failures remain errors. A broken link is absent
when followed, while `fs.lstat` can still describe it. Metadata can become stale immediately after
the call; opening a resource is authoritative.

Errors use `io.error` and retain operation, native domain/code, resource and message. Domains include
`posix`, `win32`, `crt`, `foreign`, `library`, `limit` and `shen`. Invalid path/limit values and option
shapes raise before starting native work. The native adapter copies inputs before releasing the VM lock and
reacquires it before creating managed results. Directory handles close before conversion or callbacks.

## Listings and traversal

`(fs.list Path Options)` returns `[ok Names]` with immediate entry names, sorted by encoded bytes.
It omits `.` and `..`. Listings are bounded and complete: exceeding either budget returns an error,
rather than a truncated success. No live directory iterator escapes the call.

| Option | Listing default | Maximum |
| --- | --- | --- |
| `entry-limit` | 4096 | 1000000 |
| `name-byte-limit` | 1048576 | 67108864 |

Zero permits only an empty listing. Name bytes exclude terminators and parent prefixes. Options
must be nonnegative fixnums; duplicates, unknown names and malformed pairs raise.

`(fs.walk Root Options Visit)` walks depth first, visiting the root at depth zero. The callback
receives `Info` and `Depth` and returns `continue`, `skip`, `stop` or `[error Error]`. `skip` prunes
a directory, and `stop` ends successfully. The result is `[ok (@p Visited Stopped)]`; errors retain
the number of visited entries in `io.error-progress`.

```shen
(define project.count
  Root ->
    (fs.walk Root [[entry-limit 10000] [name-byte-limit 16777216] [depth-limit 32]]
      (/. Info Depth
        (if (= (fs.name (fs.path Info)) ".git") skip continue))))
```

Walk defaults are 10000 entries, 16 MiB of listed names and depth 64. Entry and byte budgets apply
across the entire walk, including siblings already scheduled; they are not renewed per directory.
Entry limits include the root and must be positive. The maximum depth is 256. At the configured
depth, a directory is visited but not descended, so depth zero visits only the root.

The walker uses `lstat` and does not descend entries reported as links/reparse points, including a
linked root. It observes a changing tree, rather than locking it: concurrent edits can fail the walk.
It does not provide directory confinement against concurrent path replacement. Visitor exceptions
become errors, and native directory resources are already closed when a visitor runs. Changing the
home setting in a visitor does not redirect the pending walk.

Storage is bounded by scheduled entries, listed name bytes, traversal depth and path lengths.
Callbacks that retain metadata or source contents add their own storage. Traversal does not load files.

## Directories, removal and rename

These operations return `[ok]` or `[error Error]`:

| Function | Behavior |
| --- | --- |
| `(fs.mkdir Path)` | Create one directory; an existing entry is an error |
| `(fs.mkdirs Path)` | Create parents as needed; an existing directory succeeds |
| `(fs.remove-file Path)` | Unlink a file or file link; missing entries remain errors |
| `(fs.remove-directory Path)` | Remove an empty directory |
| `(fs.rename From To)` | Rename without overwriting an existing destination |
| `(fs.replace From To)` | Rename with replacement allowed |

`mkdirs` allows at most 256 parent levels. POSIX directory modes are 0777 filtered by umask;
Windows uses inherited ACLs. Recursive removal is not provided. Removing a directory link on Windows
uses `fs.remove-directory`, following native directory-link behavior.

No-overwrite rename uses `renameat2(RENAME_NOREPLACE)` on Linux, `renamex_np(RENAME_EXCL)` on macOS
and `MoveFileExW` without replacement on Windows. It does not emulate exclusivity with an existence
check. Linux needs glibc 2.28 or newer and kernel/filesystem support for that operation; unsupported
cases remain errors. Rename and replacement do not fall back to copying across filesystems/volumes.
Replacement of existing directories is OS-dependent; Windows rejects it.

## Temporary files and replacement output

`(fs.temp-file Parent Prefix)` returns `[ok (@p Path Endpoint)]`. The read/write endpoint is already
open from exclusive creation. It is binary and non-inheritable, and the caller owns closure and
removal. `(fs.temp-directory Parent Prefix)` returns `[ok Path]`; the caller removes it when empty.

Names contain 128 bits from the OS random source and retry at most 64 collisions. Prefixes contain
1–64 ASCII letters, digits, dots, hyphens or underscores. POSIX file/directory modes are 0600/0700
filtered by umask. Windows inherits ACLs. Use an appropriate parent directory for the application.

`(fs.with-temp-file Parent Prefix F)` calls `(F Path Endpoint)`, closes afterward, then removes the
file. The callback returns `[ok Value]` or `[error Error]`; exceptions become errors. Cleanup failures
are secondary to a primary error. An already removed temporary name is harmless during cleanup.

`(fs.with-replacement Path F)` creates a temporary sibling, calls `(F Endpoint)`, closes it, and
renames it over Path only after the callback and close both succeed. Failures clean up the temporary
name and preserve the primary error. The callback's value is returned after successful replacement.

```shen
(define project.save
  Path Text ->
    (fs.write-replace Path (buffer.from-string Text)))
```

`fs.write-replace` validates a view before creating output and returns `[ok Bytes]` or `[error Error]`.
`(fs.copy-file From To ByteLimit)` copies regular-file contents in 64 KiB chunks through the same
replacement path. It follows source file links, rejects non-regular sources, and returns `[ok Bytes]`
or an error. A source that exceeds the quota leaves the original destination unchanged. Errors
retain acknowledged temporary-file output in `io.error-progress`, including failures during close
or rename. Bytes processed do not imply that the destination was replaced.

POSIX same-filesystem rename provides atomic name visibility. Windows replacement follows
[MoveFileExW semantics](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
These helpers do not provide crash durability, `fsync` or preservation of the destination's old
ownership/permissions/ACLs. The replacement is the newly created temporary file, with its own
permissions. A successful content copy does not copy source metadata.

## Example and validation

```sh
build/shen-jit script tools/fs-copy.shen source.bin destination.bin
make test-fs
```

The copy application limits output to 1 GiB and replaces the destination only after successful
output/close. Its 20 MiB fixture runs under a 16 MiB heap cap and is compared byte for byte with an
independent Python oracle. Tests also cover metadata and nanosecond timestamps, sparse sizes above
32 bits, Unicode paths, links and loops, access errors, global traversal budgets, exclusive creation,
cleanup failures, preservation of existing files, typed clients, saved metadata/stale endpoints and
moving GC during native operations. Non-UTF-8 filename fixtures run where the filesystem accepts
them, and symlink fixtures report when the platform cannot create them.

`make test-san` also instruments the adapter with AddressSanitizer and UBSan. CI runs the native
suite on shared-capable platforms; fully static builds run the pure path checks and explicitly skip
the native cases. Python 3 and a C compiler are the only additional test tools.

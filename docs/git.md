# Local Git repositories

The [`git` module](../lib/git.shenmod) reads and changes local Git repositories. Shen implements
objects, indexes, refs, packs and deltas, history, diffs and worktree operations. A small native
adapter supplies SHA-1, SHA-256, zlib, CRC32 and the stat data Git's index records, and the
[filesystem library](fs.md) the rest. Programs such as the
[`shen-git` example](../example-apps/shen-git/README.md) use the library without running Git.

## Build and load

Use a dynamic build of Shen/JIT on macOS or Linux. The optional adapter needs a C compiler and zlib's
headers: its build script takes their flags from `pkg-config` when it knows zlib, and links `-lz`
otherwise.

```sh
make git
build/shen-jit eval -m git -e '(git.resolve-revision (git.open-repo ".") "HEAD")'
```

From a binary distribution, build the two adapters with
`sh lib/build-fs.sh lib/shen-fs.so` and
`sh lib/git/build-native.sh lib/shen-git-native.so`. A saved executable finds them beside it or
in its `lib/` directory. The library tries the filenames in `git.*adapter-files*`, which a caller
can set before loading the module.

In a module descriptor, add `git` to `requires`. A namespaced source can use `(use git)`. Every
function below has a type, so typed programs can use the library: a repository handle is a
`git.repo`, an object ID a string, which `git.id` also names, and the records and outcomes are
typed structs. Repository handles keep object data, packs and their indexes for reuse.

## Repository and objects

| Function | Result |
| --- | --- |
| `(git.open-repo Path)` | Find a repository at a directory or one of its parents |
| `(git.init Path Bare Branch Format)` | Create a repository and return its handle. `Format` is `"sha1"` or `"sha256"` |
| `(git.clone! Source Destination Bare)` | Copy a local repository into an empty destination and return the new handle. A failed clone removes what it made |
| `git.repo.root`, `git.repo.dir`, `git.repo.common`, `git.repo.width` | Worktree root as `[Root]`, or `[]` when bare; Git directory, common directory, and the object ID width in bytes. `(git.work-root Repo)` gives the root, or raises |
| `(git.resolve-revision Repo Spec)` | A full object ID from a ref, abbreviation, parent expression, or `REVISION:PATH` |
| `(git.read-object Repo Id)` | `(@p Kind Bytes)`, with the type as a string and the body as a byte view |
| `(git.object-id Repo Kind Bytes)`, `(git.write-object! Repo Kind Bytes)` | Compute or store an object and return its ID. An object already in a pack or an alternate is not written again |
| `(git.hash-file Repo Path Kind Write)` | Hash a file and optionally write it as an object |
| `(git.as-tree Repo Id)`, `(git.tree-entries Repo Id)` | Resolve a tree or read its entries, `git.tree-entry` records read with `git.tree-entry.name`, `git.tree-entry.mode` and `git.tree-entry.id` |
| `(git.commit-parents Repo Id)` | Parent IDs, respecting shallow boundaries |
| `(git.each-commit Repo Id Count FirstParent Visit)` | Call `Visit` in log order with a `git.log-entry` for up to `Count` commits, read with `git.log-entry.time`, `.id`, `.subject` and `.parents` |
| `(git.repack! Repo)` | Pack what refs, HEAD and every worktree's HEAD and index reach, and return the new pack's checksum in a list, or `[]` when there is nothing |

## Outcomes

The operations that can stop for a reason the caller should expect give a value that says which,
rather than raising. Each family is a type of its own:

| Operation | Outcomes | Type |
| --- | --- | --- |
| `git.switch!` | `(:git.switched Id)`, `(:git.would-overwrite Paths)` for local changes, `(:git.untracked Paths)` for untracked files in the way | `git.switch-outcome` |
| `git.merge!`, `git.fast-forward!` | `(:git.merged Id)`, `(:git.fast-forward Id)`, `(:git.conflict Paths)`, `(:git.multiple-bases Ids)`, `(:git.diverged)` when a fast-forward cannot be made, and a switch's `would-overwrite` and `untracked` | `git.merge-outcome` |
| `git.commit!` | `(:git.committed Id)`, `(:git.nothing-to-commit)` | `git.commit-outcome` |
| `git.set-ref!`, `git.delete-ref!`, `git.create-branch!`, `git.delete-branch!` | `(:git.updated Value)`, with `[Id]`, or `[]` once deleted; `(:git.changed-concurrently Found)`, with the value found instead | `git.ref-update` |

A blocked switch or merge lists every path in the way, and a conflicting merge every conflicting
path, and changes nothing. I/O failures, corrupt data and invalid arguments raise errors whose
messages begin with `git:`. In a namespace, `(import git switched would-overwrite untracked)`
lets patterns name the outcomes without the prefix:

```shen
(shen.x.namespace example.switch
  (use git)
  (import git switched would-overwrite untracked)
  (export blocked)

  (define blocked
    {git.switch-outcome --> (list string)}
    (:switched _) -> []
    (:would-overwrite Paths) -> Paths
    (:untracked Paths) -> Paths))
```

## Refs, index, and worktree

- `(git.refs Repo)` gives `(@p Name Id)` pairs in name order, and `git.ref-value` gives `[]` or
  `[Id]` for a named ref. `git.head-ref` gives the ref HEAD ultimately names, or `"HEAD"` if
  detached. `git.create-branch!` takes a branch name and a starting ID. `git.delete-branch!` takes a
  branch name and a boolean force flag.
- `(git.set-ref! Repo Name New Expected)` and `(git.delete-ref! Repo Name Expected)` update a ref
  only if it still has the value `Expected` says: `git.any`, `[]` for an absent ref, or `[OldId]`;
  the type of those is `git.expectation`. `git.null-id` gives the repository format's all-zero ID.
  A ref cannot be set while another is named by a prefix of it, as `refs/heads/a` is of
  `refs/heads/a/b`, or lies below it, and a refused ref leaves nothing behind. Setting a ref
  removes empty directories in its place, and deleting one the directories it leaves empty.
- `git.read-index` gives a list of `git.entry` records, read with `git.entry.path`, `git.entry.mode`,
  `git.entry.id` and `git.entry.stage`. `(git.write-tree! Repo Entries)` writes an index snapshot as a
  tree object.
- `(git.stage! Repo Paths TrackedOnly Force)`, `(git.unstage! Repo Paths Force)` and
  `(git.restore-staged! Repo Paths Source)` change the index. Paths are relative to the worktree
  root, and the empty path selects the whole worktree. Restore takes `[]` to use HEAD or `[Id]` for a
  source tree or commit. `(git.relative-path Repo Cwd Path)` converts a path given from a working
  directory into the form these operations expect.
- `(git.status-records Repo Untracked)` returns `(@p Code Path)` pairs, where the code is the
  two-character short-status code. `Untracked` is `git.no`, `git.normal`, which shows a directory
  that holds no tracked file as `dir/`, as Git's status does, or `git.all`, which lists every file.
- `(git.switch! Repo Spec Detached)` switches to a branch or, with `Detached` true, a revision.
  `(git.fast-forward! Repo Spec)` moves the current branch to a descendant, and
  `(git.merge! Repo Spec Message)` also makes a three-way merge, which combines changes at distinct
  paths; a path that one side puts below a file of the other is a conflict.
  `(git.commit! Repo Message AllowEmpty)` commits the index.
- `(git.config-value Repo Key)` gives `[]` or `[Value]`, `[""]` for a key without a value.
  `(git.set-config! Repo Key Value)` writes a local `section.name` setting.

The index records each staged file's stat data as Git does: ctime, mtime with nanoseconds, device,
inode, mode, owner, group and size. Status, diff, staging and switching read a file again only when
its stat data changed, or when it is as recent as the index file, whose writer could have missed a
later change in the same tick; when a rewritten index carries such an entry whose file did change,
its size is cleared so that Git and the library both look again. New files have Git's permissions,
filtered by the umask: worktree files `0666`, or `0777` when executable, loose objects and packs
`0444`, and the config, index, HEAD and refs `0666`.

## Diffs

`(git.worktree-changes Repo Base)` compares the worktree with the index when `Base` is `[]`,
or with the given tree or commit when it is `[Id]`. `(git.staged-changes Repo Base)` compares
the index with HEAD or the supplied tree or commit. `(git.revision-changes Repo A B)` compares
two trees or commits. Each gives a path-ordered list of `git.change` records. `git.change-code` gives
the one-character change code. The readers `git.change.path`, `git.change.before`, and
`git.change.after` give the path and the optional entries on each side.

`(git.write-patch Repo FromWorktree Change Emit)` passes the unified patch text in chunks to
`Emit`. Pass true for a change from `git.worktree-changes` and false for the other comparisons.
Text changes are diffed with Myers' minimal algorithm, in linear space, with three lines of context,
and changes at most six lines apart share a hunk, as in Git. Paths are quoted as Git quotes them,
for control characters, `"`, `\` and bytes from 127, and a name with a space ends its `---` and `+++`
lines with a tab. Binary differences are identified in the output. `(git.quote-path Path QuoteSpaces)`
quotes a path the same way, and also for spaces, as status does, when `QuoteSpaces` is true.

## Format support

- Reads ordinary, bare, linked, and alternate-object repositories. Reads loose objects, pack versions
  2 and 3 with index version 2, and offset and reference deltas. A pack is read once and kept, and is
  checked against the checksum its index records; delta bases are kept by offset, up to 16 MiB.
- Repack writes one version 2 pack and index of full objects, without delta compression. An object of
  an old pack that the new one leaves out is written loose first, so nothing is lost; then the old
  packs, except those with a `.keep` file, and the loose copies of what the new pack holds are removed.
- Reads index versions 2 through 4, including conflict stages. Writes versions 2 or 3 and
  regenerates the checksum. Required extensions such as split and sparse indexes cause an error.
  Optional index extensions are discarded when rewriting the index.
- Config files follow Git's syntax: comments, quoted values, escapes and continued lines, subsections
  whose names keep their case, and booleans as Git reads them. `core.filemode`, `core.symlinks` and
  `core.ignorecase` are honoured.
- Git-compatible `.lock` files protect ref, config and index writes. A switch checks the paths it
  changes for staged and worktree changes and untracked files in the way, and rolls back on an I/O
  error. A crash during a multi-file operation can require recovery. Commit and checkout require an
  idle worktree. Tree and index paths with `..`, `.git` in any case, or a parent that is a link are
  refused.
- The library stages raw bytes and covers common ignore patterns, executable modes, and symlinks.
  Hooks, signing, attribute filters, reflog updates, reftables, automatic conflict resolution,
  and transport are outside the library's local command set. Pack files are bounded at 512 MiB,
  objects at 128 MiB, and index entries and objects per repack at one million.

The library also exports the text helpers its example uses: `git.prefix?`, `git.after`,
`git.some?`, `git.decimal`, `git.ensure` and `git.git-error`, which raises a `git:` error.

The disk formats are specified in [gitformat-index](https://git-scm.com/docs/gitformat-index)
and [gitformat-pack](https://git-scm.com/docs/gitformat-pack).

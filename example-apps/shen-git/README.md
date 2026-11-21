# Shen Git

A local Git command-line client built on the [Git library](../../docs/git.md), as a typed program
over a small untyped file for the console, its arguments and its exit status. The integration test
uses standard Git to verify the repositories and patches the client produces.

## Build and run

Use a dynamic build of Shen/JIT on macOS or Linux, a C compiler and zlib's headers. The regular
checkout instructions in the guide cover the Shen/JIT bootstrap and kernel dependencies.

```sh
make shen-git
build/shen-git --help
build/shen-git -C /path/to/repository status --short
make test-shen-git
```

From a binary archive, build the adapters and executable from the archive root:

```sh
sh lib/build-fs.sh lib/shen-fs.so
sh lib/git/build-native.sh lib/shen-git-native.so
./shen-jit build example-apps/shen-git/shen-git.shenmod -o ./shen-git
```

When distributing the executable, put both adapters beside it or in a sibling `lib/` directory.

## Local commands

| Area | Commands |
| --- | --- |
| Create or copy | `init`, `init --bare`, `clone SOURCE DIRECTORY`, `clone --bare` |
| Worktree and staging | `status`, `add`, `add -A`, `add -u`, `rm --cached`, `restore --staged`, `commit -m`, `switch`, `switch --detach` |
| History | `log`, `show REVISION[:PATH]`, `rev-parse`, `diff`, `diff --cached`, `diff --name-status`, `merge`, `merge --ff-only` |
| Refs and configuration | `branch`, `branch -d`, `tag`, `show-ref`, `update-ref` with optional expected old ID, `config --local` |
| Objects and index | `cat-file`, `hash-object`, `ls-files`, `ls-tree`, `write-tree`, `repack` |

`make test-shen-git` builds both adapters and the client in a temporary directory and needs Git 2.29 or
newer and Python 3.8 or newer as well; without one of them, or on a static build or Windows, it says what it skipped.

For example, in a test repository:

```sh
shen-git init scratch
cd scratch
shen-git config user.name 'Your Name'
shen-git config user.email 'you@example.org'
printf 'hello\n' > greeting.txt
shen-git add greeting.txt
shen-git commit -m 'Add a greeting'
shen-git show HEAD:greeting.txt
git fsck --strict
```

`status` reports short status; as in Git, an untracked directory shows as `dir/` unless `-uall`
lists its files, and `-uno` leaves untracked files out. `log` defaults to oneline output. `diff`
writes unified text patches, with hunks as Git makes them, and reports binary differences. A
three-way merge combines changes at distinct paths, preserves both parents, and stops on
overlapping changes or multiple merge bases, naming the paths. `repack` packs everything into one
pack of full objects and removes the old packs and the loose copies. Local clone uses the source's
branch and tags. Other source branches become `refs/remotes/origin/*` in a working clone.

See the [Git library reference](../../docs/git.md) for the Shen API, supported formats, and limits.

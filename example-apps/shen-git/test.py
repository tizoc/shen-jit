"""Use native Git as the file-format and interoperability oracle."""
import hashlib
import os
from pathlib import Path
import random
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zlib


APP = Path(sys.argv[1]).resolve()
JIT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else APP.with_name("shen-jit")
ENV = {
    key: value
    for key, value in os.environ.items()
    if not key.startswith("GIT_") and not key.startswith("SHEN_JIT_GC_")
}
ENV.update(
    GIT_CONFIG_GLOBAL=os.devnull,
    GIT_CONFIG_NOSYSTEM="1",
    # No automatic gc or maintenance, which could repack what a test made: Git before 2.31 has
    # neither these variables nor the maintenance that newer versions run after a commit.
    GIT_CONFIG_COUNT="2",
    GIT_CONFIG_KEY_0="gc.auto",
    GIT_CONFIG_VALUE_0="0",
    GIT_CONFIG_KEY_1="maintenance.auto",
    GIT_CONFIG_VALUE_1="false",
    GIT_AUTHOR_NAME="Test Author",
    GIT_AUTHOR_EMAIL="author@example.test",
    GIT_COMMITTER_NAME="Test Committer",
    GIT_COMMITTER_EMAIL="committer@example.test",
    GIT_AUTHOR_DATE="1700000000 +0000",
    GIT_COMMITTER_DATE="1700000000 +0000",
    LC_ALL="C",
)


def run(program, repo, *args, data=None, error=None, stress=False):
    cmd = [str(program), *map(str, args)]
    env = {**ENV, **({"SHEN_JIT_GC_STRESS": "1"} if stress else {})}
    result = subprocess.run(
        cmd, cwd=repo, env=env, input=data, capture_output=True, timeout=35
    )
    if error is None:
        assert result.returncode == 0, (cmd, result.stderr.decode(errors="replace"))
    else:
        assert result.returncode != 0 and error.encode() in result.stderr, (
            cmd,
            result.stdout,
            result.stderr,
        )
    return result.stdout


def git(repo, *args, **kwargs):
    return run("git", repo, *args, **kwargs)


def app(repo, *args, **kwargs):
    return run(APP, repo, *args, **kwargs)


def assert_git_equal(repo, *args):
    assert app(repo, *args) == git(repo, *args), args


def write(repo, filename, data):
    path = repo / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def object_id(repo, spec):
    return git(repo, "rev-parse", spec).strip().decode()


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def assert_modes(repo, files, executables=()):
    """New files follow the umask as Git's: objects and packs read-only, the rest 0666 or 0777."""
    for name in files:
        assert mode(repo / name) == 0o666 & ~UMASK, (name, oct(mode(repo / name)))
    for name in executables:
        assert mode(repo / name) == 0o777 & ~UMASK, (name, oct(mode(repo / name)))
    for name in (".git/config", ".git/index", ".git/HEAD"):
        if (repo / name).exists():
            assert mode(repo / name) == 0o666 & ~UMASK, (name, oct(mode(repo / name)))
    for path in (repo / ".git/objects").rglob("*"):
        if path.is_file() and path.parent.name not in ("info",):
            assert mode(path) == 0o444 & ~UMASK, (path, oct(mode(path)))


def exercise_library(root):
    """A typed client, which matches the outcome of each operation."""
    repo = root / "library"
    note = b"written through the library\n"
    write(repo, "note", note)
    client = root / "git-library-client.shen"
    client.write_text("""
(shen.x.namespace git-library-client
  (use git)
  (use buffer)
  (use io)
  (use option)
  (import git committed nothing-to-commit updated changed-concurrently switched would-overwrite
    untracked merged fast-forward conflict multiple-bases diverged)
  (export exercise)

(define check
  {boolean --> string --> boolean}
  true _ -> true
  false Message -> (error "~A" Message))

(define committed-id
  {git.commit-outcome --> string}
  (:committed Id) -> Id
  (:nothing-to-commit) -> "")

(define updated?
  {git.ref-update --> boolean}
  (:updated _) -> true
  (:changed-concurrently _) -> false)

(define found
  {git.ref-update --> (option.t string)}
  (:updated _) -> (option.none)
  (:changed-concurrently Found) -> Found)

(define blocked
  {git.switch-outcome --> (list string)}
  (:switched _) -> []
  (:would-overwrite Paths) -> Paths
  (:untracked Paths) -> Paths)

(define moved-to
  {git.merge-outcome --> string}
  (:fast-forward Id) -> Id
  (:merged Id) -> Id
  (:conflict _) -> ""
  (:multiple-bases _) -> ""
  (:diverged) -> ""
  (:would-overwrite _) -> ""
  (:untracked _) -> "")

(define patch
  {git.repo --> (list git.change) --> string}
  Repo [Change] -> (let Text (vector-> (vector 1) 1 "")
                        _ (git.write-patch Repo false Change
                            (/. Chunk (vector-> Text 1 (cn (<-vector Text 1) Chunk))))
                     (<-vector Text 1))
  _ _ -> (error "expected one staged change"))

(define rewrite
  {string --> string --> boolean}
  Path Text -> (do (io.write-file Path (buffer.from-string Text)) true))

(define exercise
  {--> string}
  -> (let Repo (git.init "." false "main" "sha1")
          _ (git.set-config! Repo "user.name" "Library Client")
          _ (check (= (git.config-value Repo "user.name") (option.some "Library Client")) "config value")
          _ (git.stage! Repo ["note"] false false)
          _ (check (> (length (explode (patch Repo (git.staged-changes Repo [])))) 0) "staged patch")
          First (committed-id (git.commit! Repo "library commit" false))
          _ (check (= (committed-id (git.commit! Repo "again" false)) "") "nothing to commit")
          _ (check (updated? (git.set-ref! Repo "refs/tags/library" First [])) "new tag")
          _ (check (= (found (git.set-ref! Repo "refs/tags/library" First [])) (option.some First)) "tag exists")
          _ (check (updated? (git.create-branch! Repo "side" First)) "branch")
          _ (rewrite "note" "second version")
          _ (git.stage! Repo [""] true false)
          Second (committed-id (git.commit! Repo "second" false))
          _ (rewrite "note" "dirty")
          _ (check (= (blocked (git.switch! Repo "side" false)) ["note"]) "switch would overwrite")
          _ (rewrite "note" "second version")
          _ (check (= (blocked (git.switch! Repo "side" false)) []) "switched")
          _ (check (= (moved-to (git.fast-forward! Repo "main")) Second) "fast-forward")
          Seen (vector-> (vector 1) 1 [])
          _ (git.each-commit Repo Second 1 false (/. Entry (vector-> Seen 1 [Entry])))
          Object (git.read-object Repo (git.resolve-revision Repo "HEAD~1:note"))
       (do (check (= (map (fn git.log-entry.id) (<-vector Seen 1)) [Second]) "commit history")
           (check (= (fst Object) "blob") "object type")
           (check (= (buffer.string (snd Object)) "written through the libraryc#10;") "object bytes")
           "GIT_LIB_OK")))
)
""")
    adapters = [f'(set {name}.*adapter-files* ["{APP.parent / file}"])'
                for name, file in (("fs", "shen-fs.so"), ("git", "shen-git-native.so"))]
    result = run(JIT, repo, "eval", "-e", adapters[0], "-e", adapters[1], "-m", "git",
                 "-e", "(tc +)", "-l", client, "-e", "(git-library-client.exercise)")
    assert result.rstrip().endswith(b"GIT_LIB_OK"), result[-2000:]
    assert b"(fn git-library-client.exercise) : (--> string)" in result, result[-2000:]
    assert git(repo, "show", "HEAD~1:note") == note
    assert object_id(repo, "library") == object_id(repo, "HEAD~1")
    assert object_id(repo, "side") == object_id(repo, "main")
    git(repo, "fsck", "--strict")
    print("PASS typed client of the git module: outcomes, worktree, diff, config, refs and history")


def exercise_repository(root, object_format):
    repo = root / object_format
    app(root, "init", "-b", "main", f"--object-format={object_format}", repo)
    assert_git_equal(repo, "rev-parse", "--show-object-format")
    app(repo, "config", "user.name", "Local Name")
    app(repo, "config", "user.email", "local@example.test")
    assert_git_equal(repo, "config", "--get", "user.name")

    data = b"binary\x00\xff\n"
    write(repo, "data", data)
    write(repo, "space name", b"line one\nline two\nlast")
    write(repo, "dir/file", b"nested\n")
    write(repo, "script", b"#!/bin/sh\ntrue\n").chmod(0o755)
    (repo / "symlink").symlink_to("data")
    write(repo, ".gitignore", b"*.tmp\n**/omit.txt\ncache/\n!keep.tmp\n")
    write(repo, "ignored.tmp", b"ignore")
    write(repo, "dir/omit.txt", b"ignore")
    write(repo, "cache/file", b"ignore")
    write(repo, "keep.tmp", b"keep\n")
    assert_git_equal(repo, "hash-object", "data")
    assert_git_equal(repo, "status", "--porcelain", "-z", "-uall")
    app(repo, "add", "ignored.tmp", error="ignored path")
    app(repo, "add", "-A")
    assert git(repo, "diff-files", "--name-only") == b""
    assert_git_equal(repo, "ls-files", "-s", "-z")
    assert_git_equal(repo, "status", "--porcelain", "-z", "-uall")
    expected = git(repo, "commit-tree", git(repo, "write-tree").strip().decode(),
                   "-m", "first").strip()
    assert app(repo, "commit", "-m", "first").strip() == expected
    first = expected.decode()
    assert_git_equal(repo, "cat-file", "-p", "HEAD")
    if os.environ.get("TEST_GC_STRESS") == "1":
        assert app(repo, "cat-file", "-p", "HEAD:data", stress=True) == data
    assert_git_equal(repo, "ls-tree", "-r", "-z", "HEAD")
    assert_git_equal(repo, "cat-file", "-p", "HEAD^{tree}")
    app(repo, "branch", "first", first[:10])
    git(repo, "tag", "-a", "original", "-m", "annotation", first)
    assert_git_equal(repo, "rev-parse", "original^{}", "HEAD^0", "HEAD:")
    for spec in ("HEAD~{tree}", "HEAD~{}", "original~{}", "original~{commit}"):
        git(repo, "rev-parse", spec, error="")
        app(repo, "rev-parse", spec, error="invalid decimal field")

    git(repo, "update-index", "--index-version", "4")
    assert_git_equal(repo, "ls-files", "-s", "-z")
    write(repo, "space name", b"line one\nnew middle\nlast\n")
    patch = app(repo, "diff")
    git(repo, "apply", "--reverse", "--check", "-", data=patch)
    app(repo, "add", "space name")
    app(repo, "restore", "--staged", "--", "space name")
    assert app(repo, "diff") == patch
    assert app(repo, "diff", "--cached") == b""
    (repo / "dir/file").unlink()
    (repo / "dir/omit.txt").unlink()
    (repo / "dir").rmdir()
    write(repo, "dir", b"directory becomes a file\n")
    app(repo, "add", "-A")
    staged = app(repo, "diff", "--cached")
    git(repo, "apply", "--cached", "--reverse", "--check", "-", data=staged)
    second = app(repo, "commit", "-m", "second").strip().decode()
    assert object_id(repo, "HEAD^") == first
    git(repo, "fsck", "--strict")

    git(repo, "update-index", "--skip-worktree", "data")
    assert_git_equal(repo, "ls-files", "-s", "-z")
    write(repo, "temp-stage", b"temporary stage")
    app(repo, "add", "temp-stage")
    assert b"S data\n" in git(repo, "ls-files", "-v")
    app(repo, "rm", "--cached", "temp-stage")
    assert (repo / "temp-stage").read_bytes() == b"temporary stage"
    (repo / "temp-stage").unlink()
    git(repo, "update-index", "--no-skip-worktree", "data")
    git(repo, "pack-refs", "--all")
    git(repo, "gc", "--prune=now")
    for path in ("data", "space name", "script", "keep.tmp"):
        os.utime(repo / path, ns=(1600000000000000000, 1600000000000000000))
    app(repo, "add", "-A")
    assert b"count: 0\n" in git(repo, "count-objects", "-v")
    assert git(repo, "diff-files", "--name-only") == b""
    assert_git_equal(repo, "rev-parse", "HEAD", "HEAD~1", "original^{}")
    assert_git_equal(repo, "log", "--oneline", "--first-parent", "-n", "2")
    write(repo, "space name", b"dirty\n")
    idx = (repo / ".git/index").read_bytes()
    app(repo, "switch", "first", error="local changes would be overwritten: space name")
    assert object_id(repo, "HEAD") == second
    assert (repo / ".git/index").read_bytes() == idx
    assert (repo / "space name").read_bytes() == b"dirty\n"
    git(repo, "restore", "space name")
    app(repo, "switch", "first")
    assert (repo / "dir/file").read_bytes() == b"nested\n"
    assert_modes(repo, ["dir/file"])
    assert git(repo, "diff-files", "--name-only") == b""
    assert os.readlink(repo / "symlink") == "data"
    assert git(repo, "status", "--porcelain", "-uno") == b""
    write(repo, "dir/local", b"untracked data")
    app(repo, "switch", "main", error="untracked files would be overwritten: dir")
    assert (repo / "dir/local").read_bytes() == b"untracked data"
    (repo / "dir/local").unlink()
    app(repo, "merge", "--ff-only", "main")
    assert object_id(repo, "HEAD") == second
    assert (repo / "dir").read_bytes() == b"directory becomes a file\n"
    app(repo, "switch", "main")
    app(repo, "branch", "-d", "first")
    assert_git_equal(repo, "show-ref")

    app(repo, "update-ref", "refs/heads/new", first, "0" * len(first))
    app(repo, "update-ref", "refs/heads/new", second, second, error="changed concurrently")
    assert object_id(repo, "new") == first
    app(repo, "update-ref", "-d", "refs/heads/new", first)
    assert_git_equal(repo, "show-ref")

    lock = repo / ".git/index.lock"
    lock.write_bytes(b"owned by another process")
    app(repo, "add", "-A", error="index.lock")
    assert lock.read_bytes() == b"owned by another process"
    lock.unlink()

    idx_path = repo / ".git/index"
    idx = idx_path.read_bytes()
    broken = idx[:-1] + bytes([idx[-1] ^ 1])
    idx_path.write_bytes(broken)
    app(repo, "add", "-A", error="index checksum")
    assert idx_path.read_bytes() == broken and not lock.exists()
    idx_path.write_bytes(idx)

    packed = app(repo, "repack").strip().decode()
    git(repo, "verify-pack", "-v", f".git/objects/pack/pack-{packed}.idx")
    counts = git(repo, "count-objects", "-v")
    assert b"packs: 1\n" in counts and b"prune-packable: 0\n" in counts, counts
    git(repo, "fsck", "--strict")
    clone = root / f"{object_format}-clone"
    app(root, "clone", repo, clone)
    assert git(clone, "status", "--porcelain") == b""
    assert git(clone, "diff-files", "--name-only") == b""
    assert_modes(clone, ["space name", "data"], ["script"])
    assert object_id(clone, "HEAD") == second
    assert_git_equal(clone, "show-ref")
    git(clone, "fsck", "--strict")
    bare = root / f"{object_format}.git"
    app(root, "clone", "--bare", repo, bare)
    assert object_id(bare, "HEAD") == second
    assert_git_equal(bare, "show-ref")
    git(bare, "fsck", "--strict")

    linked = root / f"{object_format}-linked"
    git(repo, "worktree", "add", "-b", "linked", linked)
    app(repo, "switch", "linked", error="checked out in another worktree")
    write(linked, "another", b"linked worktree\n")
    app(root, "-C", linked, "add", "another")
    app(linked, "commit", "-m", "worktree")
    assert git(repo, "show", "linked:another") == b"linked worktree\n"
    git(repo, "fsck", "--strict")
    print(f"PASS {object_format} objects, refs, indexes, patch, worktree, clone and pack")


def exercise_deltas(root):
    for offset_delta in (False, True):
        repo = root / ("ofs-delta" if offset_delta else "ref-delta")
        git(root, "init", "-q", "-b", "main", repo)
        refs = []
        rng = random.Random(42)
        initial = bytes(rng.randrange(1, 256) for _ in range(24000))
        for number in range(8):
            body = initial[: number * 31] + f"changed {number}".encode() + initial[number * 31 :]
            write(repo, "file", body)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", f"delta {number}")
            refs.append((object_id(repo, "HEAD:file"), body))
        args = ["--all", "--window=10", "--depth=10", "--no-reuse-delta"]
        if offset_delta:
            args.append("--delta-base-offset")
        name = git(repo, "pack-objects", *args, ".git/objects/pack/pack", data=b"").strip().decode()
        idx = repo / f".git/objects/pack/pack-{name}.idx"
        packed = idx.with_suffix(".pack").read_bytes()
        listing = git(repo, "verify-pack", "-v", idx)
        types = {
            (packed[int(words[4])] >> 4) & 7
            for line in listing.splitlines()
            if (words := line.split()) and len(words) in (5, 7)
            and len(words[0]) == 40
        }
        assert (6 if offset_delta else 7) in types, types
        git(repo, "prune-packed")
        for reference, body in refs:
            assert app(repo, "cat-file", "-p", reference) == body
        clone = root / f"{repo.name}-shared"
        git(root, "clone", "-q", "--shared", repo, clone)
        assert app(clone, "show", "HEAD:file") == refs[-1][1]
        print(f"PASS Git-generated {repo.name} chains and shared-object lookup")


def exercise_packs(root):
    repo = root / "packs"
    git(root, "init", "-q", "-b", "main", repo)
    for number in range(3):
        write(repo, f"file{number}", f"pack {number}\n".encode() * 50)
        write(repo, "shared", f"version {number}\n".encode() * 200)
        git(repo, "add", ".")
        git(repo, "commit", "-qm", f"pack {number}")
        # A pack of this commit's new objects: git repack, as newer versions do, may combine them.
        new = git(repo, "rev-list", "--objects", "HEAD", *(["^HEAD~1"] if number else []))
        git(repo, "pack-objects", "-q", ".git/objects/pack/pack", data=new)
        git(repo, "prune-packed")
    assert len(list((repo / ".git/objects/pack").glob("*.pack"))) == 3
    assert_git_equal(repo, "log", "--oneline")
    assert_git_equal(repo, "ls-tree", "-r", "HEAD")
    for number in range(3):
        assert_git_equal(repo, "cat-file", "-p", f"HEAD~{number}:shared")
        assert_git_equal(repo, "cat-file", "-p", f"HEAD:file{number}")

    # Repack keeps what only the index reaches, and an unreachable packed object, loose.
    orphan = git(repo, "hash-object", "-w", "--stdin", data=b"unreachable\n").strip().decode()
    git(repo, "pack-objects", "-q", ".git/objects/pack/pack", data=orphan.encode() + b"\n")
    git(repo, "prune-packed")
    write(repo, "staged-only", b"only in the index\n")
    git(repo, "add", "staged-only")
    staged = object_id(repo, ":staged-only")
    app(repo, "repack")
    counts = git(repo, "count-objects", "-v")
    assert b"count: 1\n" in counts and b"packs: 1\n" in counts, counts
    assert b"prune-packable: 0\n" in counts, counts
    assert (repo / ".git/objects" / orphan[:2] / orphan[2:]).exists()
    assert git(repo, "cat-file", "-p", orphan) == b"unreachable\n"
    assert git(repo, "cat-file", "-p", staged) == b"only in the index\n"
    git(repo, "fsck", "--strict")
    assert_git_equal(repo, "log", "--oneline")
    print("PASS objects across several packs, and repack into one")


def exercise_merge(root):
    repo = root / "merge"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "common", b"first\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    base = object_id(repo, "HEAD")
    git(repo, "switch", "-qc", "other")
    write(repo, "one", b"one\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "other")
    other = object_id(repo, "HEAD")
    git(repo, "switch", "-q", "main")
    write(repo, "two", b"two\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "main")
    ours = object_id(repo, "HEAD")
    app(repo, "merge", "other", "-m", "merge")
    assert object_id(repo, "HEAD^1") == ours
    assert object_id(repo, "HEAD^2") == other
    assert (repo / "one").read_bytes() == b"one\n"
    assert (repo / "two").read_bytes() == b"two\n"
    git(repo, "fsck", "--strict")
    git(repo, "switch", "-qc", "conflict", base)
    write(repo, "common", b"their edit\n")
    git(repo, "commit", "-qam", "other edit")
    git(repo, "switch", "-q", "main")
    write(repo, "common", b"our edit\n")
    git(repo, "commit", "-qam", "our edit")
    ours = object_id(repo, "HEAD")
    app(repo, "merge", "conflict", error="merge conflict in: common")
    app(repo, "merge", "--ff-only", "conflict", error="not possible to fast-forward")
    app(repo, "commit", "-m", "nothing", error="nothing to commit")
    assert object_id(repo, "HEAD") == ours
    assert git(repo, "status", "--porcelain") == b""
    assert not (repo / ".git/index.lock").exists()
    # A file on one side where the other has a directory, with foo-x sorted between them.
    git(repo, "switch", "-qc", "file-side")
    write(repo, "foo", b"file\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "foo file")
    git(repo, "switch", "-q", "main")
    write(repo, "foo-x", b"beside\n")
    write(repo, "foo/bar", b"nested\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "foo directory")
    ours = object_id(repo, "HEAD")
    app(repo, "merge", "file-side", error="merge conflict in: foo/bar")
    assert object_id(repo, "HEAD") == ours
    assert git(repo, "status", "--porcelain") == b""
    print("PASS clean three-way merge and conflict refusal")


def exercise_rollback(root):
    if os.geteuid() == 0:
        print("SKIP permission-based checkout rollback as root")
        return
    repo = root / "rollback"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "base", b"first\n").chmod(0o755)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "initial")
    git(repo, "switch", "-qc", "other")
    write(repo, "a-new", b"early write\n")
    write(repo, "base", b"changed\n").chmod(0o644)
    write(repo, "z/late", b"late write\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "changes")
    git(repo, "switch", "-q", "main")
    (repo / "z").mkdir()
    (repo / "z").chmod(0o555)
    initial = object_id(repo, "HEAD")
    before = (repo / ".git/index").read_bytes()
    try:
        app(repo, "switch", "other", error="Permission denied")
        assert object_id(repo, "HEAD") == initial
        assert (repo / ".git/index").read_bytes() == before
        assert (repo / "base").read_bytes() == b"first\n"
        assert_modes(repo, [], ["base"])
        assert not (repo / "a-new").exists()
        assert not (repo / "z/late").exists()
        assert not (repo / ".git/index.lock").exists()
        assert not (repo / ".git/HEAD.lock").exists()
    finally:
        (repo / "z").chmod(0o755)
    print("PASS rollback after a worktree write fails")


def exercise_clones(root):
    source = root / "detached-source"
    git(root, "init", "-q", "-b", "trunk", source)
    write(source, "file", b"one\n")
    git(source, "add", ".")
    git(source, "commit", "-qm", "one")
    git(source, "branch", "main")
    git(source, "switch", "-q", "--detach")
    detached = object_id(source, "HEAD")
    bare = root / "detached.git"
    app(root, "clone", "--bare", source, bare)
    assert (bare / "HEAD").read_bytes() == detached.encode() + b"\n"
    assert_git_equal(bare, "show-ref")
    git(bare, "fsck", "--strict")
    work = root / "detached-work"
    app(root, "clone", source, work)
    assert object_id(work, "HEAD") == detached
    assert git(work, "status", "--porcelain") == b""

    # A symlink whose target has a NUL byte fails the checkout after the clone began.
    broken = root / "broken-source"
    git(root, "init", "-q", "-b", "main", broken)
    blob = git(broken, "hash-object", "-w", "--stdin", data=b"a\0b").strip().decode()
    tree = git(broken, "mktree", data=f"120000 blob {blob}\tlink\n".encode()).strip().decode()
    commit = git(broken, "commit-tree", tree, "-m", "bad link").strip().decode()
    git(broken, "update-ref", "refs/heads/main", commit)
    target = root / "broken-clone"
    app(root, "clone", broken, target, error="invalid symlink target")
    assert not target.exists()
    target.mkdir()
    app(root, "clone", broken, target, error="invalid symlink target")
    assert target.is_dir() and not any(target.iterdir())
    print("PASS bare clone of a detached HEAD and removal after a failed clone")


def exercise_refs(root):
    repo = root / "refs"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "file", b"one\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "one")
    app(repo, "branch", "feature/x")
    app(repo, "branch", "-d", "feature/x")
    assert not (repo / ".git/refs/heads/feature").exists()
    assert (repo / ".git/refs/heads").is_dir()
    app(repo, "branch", "feature")
    assert_git_equal(repo, "show-ref")

    # A ref in the way of another, loose or packed, leaves no directory; an empty directory in the
    # way of a ref, which an earlier version could leave, gives way to it, as in Git.
    git(repo, "branch", "topic")
    git(repo, "pack-refs", "--all")
    app(repo, "update-ref", "refs/heads/topic/x", "HEAD", error="ref conflicts with an existing ref")
    assert not (repo / ".git/refs/heads/topic").exists()
    app(repo, "branch", "loose")
    app(repo, "branch", "loose/y", error="ref conflicts with an existing ref: refs/heads/loose/y")
    (repo / ".git/refs/heads/topic/a").mkdir(parents=True)
    git(repo, "switch", "-q", "topic")
    write(repo, "file", b"two\n")
    app(repo, "add", "file")
    second = app(repo, "commit", "-m", "two").strip().decode()
    assert object_id(repo, "topic") == second
    git(repo, "switch", "-q", "main")
    git(repo, "pack-refs", "--all")
    (repo / ".git/refs/heads/main").mkdir()
    app(repo, "merge", "--ff-only", "topic")
    assert object_id(repo, "main") == second
    assert_git_equal(repo, "show-ref")
    print("PASS deleted refs leave no empty directories, nor do conflicts")


def exercise_diff(root):
    repo = root / "diff"
    git(root, "init", "-q", "-b", "main", repo)
    numbered = [b"%03d\n" % n for n in range(1, 41)]
    write(repo, "multi", b"".join(numbered))
    write(repo, "space name", b"alpha\nbeta\n")
    write(repo, "na\u00efve.txt", b"left\n")
    write(repo, "quote\"d", b"q\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    changed = list(numbered)
    changed[1] = b"two\n"
    changed[19:21] = [b"twenty\n", b"inserted\n", b"twenty-one\n"]
    del changed[25]
    changed[37] = b"thirty-eight\n"
    write(repo, "multi", b"".join(changed))
    write(repo, "space name", b"alpha\ngamma")
    write(repo, "na\u00efve.txt", b"right\n")
    write(repo, "quote\"d", b"r\n")
    wanted = {path: (repo / path).read_bytes() for path in ("multi", "space name", "na\u00efve.txt", 'quote"d')}
    patch = app(repo, "diff")
    assert b"diff --git a/space name b/space name\n" in patch
    assert b"--- a/space name\t\n+++ b/space name\t\n" in patch
    assert b'diff --git "a/na\\303\\257ve.txt" "b/na\\303\\257ve.txt"' in patch
    assert b'"a/quote\\"d"' in patch
    git(repo, "checkout", "--", ".")
    git(repo, "apply", "-", data=patch)
    for path, data in wanted.items():
        assert (repo / path).read_bytes() == data, path
    app(repo, "add", "-A")
    staged = app(repo, "diff", "--cached")
    assert staged == patch
    git(repo, "reset", "-q", "--hard")
    git(repo, "apply", "--index", "-", data=staged)
    for path, data in wanted.items():
        assert (repo / path).read_bytes() == data, path
    single = root / "diff-single"
    git(root, "init", "-q", "-b", "main", single)
    write(single, "multi", b"".join(numbered))
    git(single, "add", ".")
    git(single, "commit", "-qm", "base")
    write(single, "multi", b"".join(changed))
    assert_git_equal(single, "diff")
    print("PASS multi-hunk diffs and quoted paths applied by Git")


def tree_bytes(mode, name, oid):
    return f"{mode} {name}".encode() + b"\0" + bytes.fromhex(oid)


def index_bytes(entries):
    """A version 2 index of regular files, with zero stat data."""
    data = b"DIRC" + struct.pack(">II", 2, len(entries))
    for path, oid in entries:
        name = path.encode()
        entry = struct.pack(">10I", 0, 0, 0, 0, 0, 0, 0o100644, 0, 0, 0)
        entry += bytes.fromhex(oid) + struct.pack(">H", len(name)) + name
        data += entry + b"\0" * (8 - len(entry) % 8)
    return data + hashlib.sha1(data).digest()


def exercise_hostile(root):
    """Trees and indexes that would reach outside the worktree or into .git are refused."""
    repo = root / "hostile"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "file", b"safe\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    blob = object_id(repo, "HEAD:file")
    for name in ("..", ".GIT", ".Git", "git~1"):
        inner = git(repo, "hash-object", "-t", "tree", "-w", "--stdin", "--literally",
                    data=tree_bytes("100644", "config", blob)).strip().decode()
        top = git(repo, "hash-object", "-t", "tree", "-w", "--stdin", "--literally",
                  data=tree_bytes("40000", name, inner)).strip().decode()
        commit = git(repo, "commit-tree", top, "-p", "HEAD", "-m", "hostile").strip().decode()
        git(repo, "update-ref", "refs/heads/hostile", commit)
        app(repo, "switch", "hostile", error="invalid Git pathname component")
        app(repo, "ls-tree", "-r", "hostile", error="invalid Git pathname component")
    assert not (root / "config").exists()
    assert (repo / ".git/config").read_bytes().startswith(b"[core]")
    index = (repo / ".git/index").read_bytes()
    for path in ("a/../escape", ".git/config", "sub/.GIT/hooks"):
        (repo / ".git/index").write_bytes(index_bytes([(path, blob)]))
        app(repo, "status", error="invalid Git pathname component")
        app(repo, "add", "file", error="invalid Git pathname component")
    (repo / ".git/index").write_bytes(index)

    # A directory replaced by a link to elsewhere is not written through.
    outside = root / "hostile-outside"
    outside.mkdir()
    git(repo, "switch", "-qc", "with-dir")
    write(repo, "dir/inner", b"inner\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "dir")
    git(repo, "switch", "-q", "main")
    (repo / "dir").symlink_to(outside)
    app(repo, "switch", "with-dir", error="untracked files would be overwritten: dir/inner")
    assert not (outside / "inner").exists()
    write(outside, "planted", b"planted\n")
    app(repo, "add", "dir/planted", error="does not exist")
    app(repo, "add", "-A")
    staged = git(repo, "ls-files", "-s")
    assert b"dir/planted" not in staged and b"120000 " in staged, staged
    print("PASS hostile trees, indexes and linked parents refused")


def exercise_status(root):
    """Nested and negated ignore rules, and untracked files in each of Git's modes."""
    repo = root / "status"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, ".gitignore", b"*.log\n!keep.log\nbuild/\n")
    write(repo, "sub/.gitignore", b"!debug.log\n*.tmp\n")
    write(repo, "sub/deeper/.gitignore", b"!*.tmp\n")
    write(repo, "tracked/file", b"tracked\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    for name in ("a.log", "keep.log", "sub/debug.log", "sub/x.tmp", "sub/deeper/y.tmp", "build/out",
                 "sub/build/z", "tracked/new", "fresh/one", "fresh/deep/two", "only-ignored/c.log",
                 "sub/fresh/three.tmp"):
        write(repo, name, b"x\n")
    (repo / "empty").mkdir()
    for args in ((), ("-uall",), ("-uno",)):
        assert_git_equal(repo, "status", "--porcelain", *args)
    write(repo, "tracked/file", b"changed\n")
    assert_git_equal(repo, "status", "--porcelain")
    print("PASS nested and negated ignore rules, and status of untracked files")


def exercise_config(root):
    repo = root / "config"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "tool", b"#!/bin/sh\n").chmod(0o755)
    write(repo, "notes.txt", b"notes\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    other = root / "config-other"
    git(root, "init", "-q", "-b", "main", other)
    write(other, "shared", b"from an alternate\n")
    git(other, "add", ".")
    git(other, "commit", "-qm", "alternate")
    shared = object_id(other, "HEAD:shared")
    with (repo / ".git/config").open("a") as config:
        config.write('[core]\n\tfilemode = No ; Git booleans\n\tignorecase\n'
                     '[user]\n\tname = "Quoted ; Name" # comment\n\tnick = a\\tb  c\n'
                     '[remote "Origin"]\n\turl = first \\\n second\n'
                     '[Section.Sub]\n\tkey = old style\r\n\tcrlf = one \\\r\n two\r\n')
    (repo / ".git/objects/info/alternates").write_text(
        f"# objects of another repository\n\n{other / '.git/objects'}\n")
    for key in ("user.name", "user.nick", "remote.Origin.url", "core.filemode", "section.sub.key",
                "section.sub.crlf"):
        assert_git_equal(repo, "config", key)
    app(repo, "config", "remote.origin.url", error="")
    config = (repo / ".git/config").read_bytes()
    (repo / ".git/config").write_bytes(config + b'[s "q\\\nr"]\n\tk = v\n')
    git(repo, "config", "s.q.k", error="bad config line")
    app(repo, "config", "s.q.k", error="invalid config subsection")
    (repo / ".git/config").write_bytes(config)
    assert app(repo, "cat-file", "-p", shared) == b"from an alternate\n"
    (repo / "tool").chmod(0o644)
    write(repo, ".gitignore", b"*.LOG\n")
    write(repo, "debug.log", b"ignored when case is folded\n")
    assert_git_equal(repo, "status", "--porcelain", "-uall")
    print("PASS config syntax, booleans, subsections, alternates and ignorecase")


def exercise_saved_executable(root):
    release = root / "release"
    release.mkdir()
    for name in (APP.name, "shen-fs.so", "shen-git-native.so"):
        shutil.copy2(APP.parent / name, release / name)
    outside = root / "outside"
    outside.mkdir()
    git(root, "init", "-q", "-b", "main", outside)
    write(outside, "external", b"untracked\n")
    result = subprocess.run(
        [str(release / APP.name), "status", "--porcelain", "-z"],
        cwd=outside, env={**ENV, "PATH": ""}, capture_output=True, timeout=35, check=True,
    )
    assert result.stdout == b"?? external\0"
    print("PASS saved executable with adjacent adapters from an unrelated directory")


def exercise_corrupt_object(root):
    repo = root / "corrupt"
    git(root, "init", "-q", "-b", "main", repo)
    write(repo, "file", b"original")
    ref = app(repo, "hash-object", "-w", "file").strip().decode()
    path = repo / ".git" / "objects" / ref[:2] / ref[2:]
    assert mode(path) == 0o444 & ~UMASK
    path.chmod(0o644)
    path.write_bytes(zlib.compress(b"blob 7\0changed"))
    app(repo, "cat-file", "-p", ref, error="object hash does not match")
    print("PASS corrupt loose object refusal")


UMASK = 0o027
os.umask(UMASK)
with tempfile.TemporaryDirectory(prefix="shen-git-") as directory:
    root = Path(directory)
    exercise_library(root)
    for fmt in ("sha1", "sha256"):
        exercise_repository(root, fmt)
    exercise_deltas(root)
    exercise_packs(root)
    exercise_merge(root)
    exercise_rollback(root)
    exercise_clones(root)
    exercise_refs(root)
    exercise_diff(root)
    exercise_hostile(root)
    exercise_status(root)
    exercise_config(root)
    exercise_corrupt_object(root)
    exercise_saved_executable(root)

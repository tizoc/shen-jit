#!/usr/bin/env python3
"""Filesystem fixtures and independent byte/metadata oracles, all in a temporary tree."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BINARY = b"a\0\r\n\x1a\xff"


def string(value):
    # Keep command lines ASCII on Windows, including literal c# sequences in paths.
    encoded = (
        chr(byte) if 32 <= byte < 127 and byte not in [34, 99] else f"c#{byte};"
        for byte in str(value).encode("utf-8")
    )
    return '"' + "".join(encoded) + '"'


def run(args, **kwargs):
    result = subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True,
        errors="backslashreplace", timeout=90, **kwargs,
    )
    assert result.returncode == 0 and "uncaught error" not in result.stderr, (
        result.stdout[-5000:], result.stderr,
    )
    return result


def checks(result):
    lines = [
        line for line in result.stdout.splitlines()
        if re.fullmatch(r"\d+ passed, 0 failed", line)
    ]
    assert lines and "FAIL " not in result.stdout, result.stdout[-5000:]
    for line in lines:
        print(line, flush=True)


def command(executable, adapter):
    return [
        str(executable), "eval", "-l", "lib/ffi.shen", "-l", "lib/buffer.shen",
        "-l", "lib/io.shen", "-l", "lib/io-file.shen",
        "-s", "fs.*adapter-files*", "[" + string(adapter) + "]", "-l", "lib/fs.shen",
    ]


def fixtures(root):
    for name in ["listing", "empty", "raw", "tree/b/deep", "denied"]:
        (root / name).mkdir(parents=True)
    (root / "data").write_bytes(BINARY)
    (root / "listing/a").touch()
    (root / "listing/b").touch()
    (root / "tree/a.txt").write_text("a")
    (root / "tree/b/deep/z.txt").write_text("z")
    (root / "denied/file").touch()
    (root / "unicode-λ.bin").write_bytes(BINARY)
    os.utime(root / "data", ns=(-1234567890123456789, 1600000000123456789))

    block = bytes(range(256)) * 256
    with (root / "large.bin").open("wb") as output:
        for _ in range(320):
            output.write(block)

    links = False
    try:
        (root / "file-link").symlink_to(root / "data")
        (root / "broken-link").symlink_to(root / "missing")
        (root / "tree/loop").symlink_to(root / "tree", target_is_directory=True)
        links = True
    except (OSError, NotImplementedError):
        print("fs: symlink fixture unavailable", flush=True)

    raw = False
    if os.name != "nt":
        try:
            with open(os.fsencode(root / "raw") + b"/\xff", "wb") as output:
                output.write(b"x")
            raw = True
        except OSError:
            print("fs: this filesystem rejects non-UTF-8 names", flush=True)

    sparse = os.name != "nt"
    if sparse:
        with (root / "sparse").open("wb") as output:
            output.truncate(5368709127)
    return links, raw, sparse


def saved_image(executable, base, root):
    image = root / "fs.img"
    save = [str(executable), "--save", str(image)] + base[1:] + [
        "-l", "tests/fs_gc_helpers.shen",
        "-s", "fs-image.root", string(root),
        "-e", '(set fs-image.info (hd (tl (fs.stat (fs.join (value fs-image.root) "data")))))',
        "-e", '(set fs-image.names (hd (tl (fs.list (fs.join (value fs-image.root) "listing") []))))',
        "-e", '(do (set fs-image.endpoint '
              '(snd (hd (tl (fs.temp-file (value fs-image.root) "image-"))))) true)',
    ]
    run(save)
    env = {**os.environ, "SHEN_JIT_IMAGE": str(image)}
    restored = run([
        str(executable), "eval", "-e",
        '(output "restored: ~A ~A ~A~%" (fs.size (value fs-image.info)) '
        '(= (value fs-image.names) ["a" "b"]) '
        '(trap-error (do (io.read-some (value fs-image.endpoint) (buffer.new 0) []) false) '
        '(/. X true)))',
    ], env=env)
    assert "restored: 6 true true" in restored.stdout, restored.stdout[-1000:]
    stressed = run([
        str(executable), "eval", "-e",
        '(do (fs-gc.run (value fs-image.root)) (output "fs gc ok~%") true)',
    ], env={**env, "SHEN_JIT_GC_STRESS": "1"})
    assert "fs gc ok" in stressed.stdout, stressed.stdout[-1000:]
    print("4 passed, 0 failed", flush=True)


def copy_application(base, root):
    target = root / "application-copy.bin"
    argv = "[" + " ".join(map(string, ["tools/fs-copy.shen", root / "large.bin", target])) + "]"
    result = run(
        base + ["-s", "*argv*", argv, "-l", "tools/fs-copy.shen"],
        env={**os.environ, "SHEN_JIT_SEMISPACE": "4M", "SHEN_JIT_MAX_HEAP": "16M"},
    )
    assert "Copied 20971520 bytes" in result.stdout, result.stdout[-1000:]
    with target.open("rb") as copied, (root / "large.bin").open("rb") as original:
        while block := original.read(65536):
            assert copied.read(len(block)) == block, "copied bytes differ"
        assert not copied.read(1), "copy has trailing bytes"
    print("2 passed, 0 failed (20 MiB copy under a 16 MiB heap cap)", flush=True)


def documentation(base, root):
    reference = ROOT / "docs/fs.md"
    if not reference.exists():
        return
    source = root / "examples.shen"
    source.write_text("\n".join(re.findall(r"```shen\n(.*?)```", reference.read_text(), re.S)))
    expression = '(let Size (project.file-size ' + string(root / "data") + ') '
    expression += 'Count (project.count ' + string(root / "tree") + ') '
    expression += 'Saved (project.save ' + string(root / "example-output") + ' "document") '
    expression += '(if (and (= Size [ok 6]) (> (fst (hd (tl Count))) 0) (= Saved [ok 8])) '
    expression += '(do (output "3 passed, 0 failed~%") true) (error "filesystem examples failed")))'
    checks(run(base + ["-l", str(source), "-e", expression]))


def main():
    executable, adapter = (Path(arg).resolve() for arg in sys.argv[1:3])
    # Windows runners can put the checkout and system temporary directory on different drives.
    parent = ROOT if os.name == "nt" else None
    with tempfile.TemporaryDirectory(prefix="shen-fs-", dir=parent) as directory:
        root = Path(directory).resolve()
        links, raw, sparse = fixtures(root)
        info = (root / "data").stat()
        denied = os.name != "nt" and os.geteuid() != 0
        if denied:
            (root / "denied").chmod(0)
        try:
            base = command(executable, adapter)
            modified = "(@p " + " ".join(map(str, divmod(info.st_mtime_ns, 10**9))) + ")"
            accessed = "(@p " + " ".join(map(str, divmod(info.st_atime_ns, 10**9))) + ")"
            args = base + [
                "-s", "fs-test.root", string(root),
                "-s", "fs-test.relative", string(os.path.relpath(root, ROOT)),
                "-s", "fs-test.links", str(links).lower(),
                "-s", "fs-test.sparse", str(sparse).lower(),
                "-s", "fs-test.raw", str(raw).lower(),
                "-s", "fs-test.denied", str(denied).lower(),
                "-s", "fs-test.mtime", modified,
                "-s", "fs-test.atime", accessed,
            ]
            checks(run(args + ["-l", "tests/fs.shen"]))
            assert (root / "destination").read_bytes() == BINARY
            assert (root / "relative-copy").read_bytes() == BINARY
            assert not any(p.name.startswith(".shen-") for p in root.iterdir()), "temporary file leaked"
            print("3 passed, 0 failed", flush=True)

            typed = '(do (output "~A~%" (if (fs-typed.run ' + string(root)
            typed += ') "4 passed, 0 failed" "0 passed, 1 failed")) true)'
            checks(run(base + ["-e", "(tc +)", "-l", "tests/fs_typed.shen", "-e", typed]))
            copy_application(base, root)
            saved_image(executable, base, root)
            documentation(base, root)
        finally:
            if denied:
                (root / "denied").chmod(0o700)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Checked key-partitioned Datalog vs sequential Datalog and compiled Souffle.

Run from the repository root. Results and generated programs go under build/.
Requires a 32-bit OpenMP Souffle build; set SOUFFLE_FLAGS/SOUFFLE_LIBS for its
C++ compiler, e.g. Apple's clang needs -Xpreprocessor -fopenmp and libomp.
No startup subtraction or best-of selection: report all samples and medians.
"""
import argparse
import json
import os
from pathlib import Path
import random
import re
import shlex
import statistics
import subprocess
import time


def run(args, *, env=None, timeout=180):
    p = subprocess.run([str(x) for x in args], text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, env=env, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f"{shlex.join(map(str, args))}\n{p.stdout[-6000:]}")
    return p.stdout


def expr_string(value):
    value = str(value)
    if '"' in value:
        raise ValueError("benchmark paths must not contain double quotes")
    return '"' + value + '"'


def samples(output):
    found = re.findall(r"^(FIRST|SAMPLE) ([0-9.eE+-]+) (.*)$", output, re.M)
    if not found:
        raise RuntimeError(f"no timing samples:\n{output[-2000:]}")
    counts = []
    for _, _, text in found:
        pairs = re.findall(r"\[([\w.-]+) ([0-9]+)\]", text) or re.findall(r"([\w.-]+)=([0-9]+)", text)
        if not pairs:
            raise RuntimeError(f"no result counts: {text}")
        counts.append({name.replace("-", "_"): int(n) for name, n in pairs})
    return {"first": float(found[0][1]),
            "samples": [float(row[1]) for row in found if row[0] == "SAMPLE"],
            "cleanup": [float(x) for x in re.findall(r"^CLEANUP ([0-9.eE+-]+)$", output, re.M)],
            "counts": counts}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--shen", default="build/shen-jit")
    ap.add_argument("--souffle", default=os.environ.get("SOUFFLE", "souffle"))
    ap.add_argument("--output", type=Path, default=Path("build/datalog-workers"))
    ap.add_argument("--cases", nargs="+", default=["closure-sparse", "closure-dense", "skewed-join"])
    ap.add_argument("--campaigns", type=int, default=5)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--counts", type=int, nargs="+", default=[1, 2, 4])
    ap.add_argument("--append", action="store_true", help="keep earlier campaigns in results.json")
    ap.add_argument("--engines", nargs="+", choices=["sequential", "workers", "public", "souffle"],
                    default=["sequential", "public", "souffle"])
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument("--reuse", action="store_true", help="reuse this directory's verified build")
    args = ap.parse_args()
    if args.campaigns < 1 or args.rounds < 1 or any(n < 1 or n > 64 for n in args.counts):
        ap.error("positive campaigns/rounds and worker counts from 1 to 64 required")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    bench = out / "shen-bench"
    libraries = ["lib/native.shen", "lib/datalog.shen", "lib/buffer.shen",
                 "lib/parallel.shen", "lib/parallel-map.shen", "lib/datalog-parallel.shen",
                 "tests/bench/datalog.shen",
                 "tests/bench/datalog-souffle.shen", "tests/bench/datalog-workers-run.shen"]
    version = run([args.souffle, "--version"])
    if "Word size: 32 bits" not in version or "openmp" not in version:
        raise RuntimeError("use a 32-bit Souffle build with OpenMP enabled")
    (out / "souffle-version.txt").write_text(version)
    if not args.reuse:
        cmd = [args.shen, "eval", "-q"]
        for path in libraries:
            cmd += ["-l", path]
        run(cmd + ["-e", f"(shen-jit.save-executable {expr_string(bench)} [])"])
        checks = run([bench, "eval", "-q", "-e", "(set *hush* false)", "-e",
                      f"(set dwt.image {expr_string(bench)})", "-l", "tests/datalog-workers.shen"])
        (out / "checks.txt").write_text(checks)
        if "43 checks, 0 failed" not in checks or "FAIL" in checks:
            raise RuntimeError(checks)
        for case in args.cases:
            d = out / case
            d.mkdir(exist_ok=True)
            run([bench, "eval", "-q", "-e", "(set *hush* false)", "-e",
                 f"(dwb.export {expr_string(case)} {expr_string(d)})"])
            if not (d / "edge.facts").stat().st_size or not (d / "program.dl").stat().st_size:
                raise RuntimeError(f"empty generated benchmark input: {case}")
            run([args.souffle, "-j", "auto", "-g", d / "program.cpp", d / "program.dl"])
            (d / "harness.cpp").write_text(Path("tests/bench/datalog-workers.cpp").read_text())
            flags = shlex.split(os.environ.get("SOUFFLE_FLAGS", ""))
            libs = shlex.split(os.environ.get("SOUFFLE_LIBS", ""))
            command = [os.environ.get("CXX", "c++"), "-std=c++17", "-O3", "-w",
                       "-DUSE_NCURSES", "-DUSE_LIBZ", "-DUSE_SQLITE", *flags,
                       d / "harness.cpp", "-o", d / "souffle-bench",
                       "-lz", "-lsqlite3", "-lncurses", *libs]
            (d / "compile-command.txt").write_text(shlex.join(map(str, command)))
            (d / "compile.log").write_text(run(command))
            env = dict(os.environ, DATALOG_WORKERS_DUMP="1")
            (d / "souffle-check.txt").write_text(run([d / "souffle-bench", 4, 0, d], env=env))
            run([bench, "eval", "-q", "-e", "(set *hush* false)", "-e",
                 f"(dwb.public-output {expr_string(case)} 4 {expr_string(bench)} {expr_string(d)})"])
            outputs = list(d.glob("*.ours"))
            expected_relations = samples((d / "souffle-check.txt").read_text())["counts"][0]
            if {p.stem for p in outputs} != set(expected_relations):
                raise RuntimeError(f"missing or unexpected relation outputs: {case}")
            for ours in outputs:
                theirs = ours.with_suffix(".csv")
                # Sort outside either clock; compare every tuple, not just counts.
                for src in (ours, theirs):
                    with src.with_suffix(src.suffix + ".sorted").open("w") as f:
                        subprocess.run(["sort", str(src)], stdout=f, check=True,
                                       env=dict(os.environ, LC_ALL="C"))
                if ours.with_suffix(".ours.sorted").read_bytes() != theirs.with_suffix(".csv.sorted").read_bytes():
                    raise RuntimeError(f"different full results: {case}/{ours.stem}")
            print(f"{case}: full results agree", flush=True)
    if args.prepare_only:
        return
    rows = json.loads((out / "results.json").read_text()) if args.append else []
    campaign_base = max((r["campaign"] for r in rows), default=-1) + 1
    expected = {case: samples((out / case / "souffle-check.txt").read_text())["counts"][0]
                for case in args.cases}
    rng = random.Random(719)
    for campaign in range(args.campaigns):
        variants = ([("sequential", 0)] if "sequential" in args.engines else []) + [
            (engine, n) for engine in ["workers", "public", "souffle"] if engine in args.engines for n in args.counts]
        jobs = [(case, engine, workers) for case in args.cases for engine, workers in variants]
        rng.shuffle(jobs)
        for case, engine, workers in jobs:
            load = os.getloadavg()
            if engine == "souffle":
                cmd = [out / case / "souffle-bench", workers, args.rounds, out / case]
            else:
                entry = "dwb.public" if engine == "public" else "dwb.parallel"
                expression = (f"(dwb.serial {expr_string(case)} {args.rounds})" if engine == "sequential" else
                              f"({entry} {expr_string(case)} {workers} {expr_string(bench)} {args.rounds})")
                cmd = [bench, "eval", "-q", "-e", "(set *hush* false)", "-e", expression]
            start = time.monotonic()
            output = run(cmd)
            row = dict(campaign=campaign_base+campaign, case=case, engine=engine, workers=workers,
                       load=load, process_seconds=time.monotonic()-start, **samples(output))
            if len(row["samples"]) != args.rounds or any(c != expected[case] for c in row["counts"]):
                raise RuntimeError(f"wrong result or sample count: {row}")
            rows.append(row)
            (out / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
            print(f"{campaign_base+campaign+1} {case:15} {engine:10} {workers} "
                  f"warm={statistics.median(row['samples'])*1000:.2f}ms first={row['first']*1000:.2f}ms", flush=True)
    print("\nMedian ms over warm samples; public includes the complete call and join on every sample. Executable launch excluded.")
    for case in args.cases:
        for engine, workers in sorted(set((r["engine"], r["workers"]) for r in rows)):
            selected = [r for r in rows if (r["case"], r["engine"], r["workers"]) == (case, engine, workers)]
            if not selected:
                continue
            warm = [s for r in selected for s in r["samples"]]
            first = [r["first"] for r in selected]
            print(f"{case:15} {engine:10} {workers} warm {statistics.median(warm)*1000:9.2f} "
                  f"range {min(warm)*1000:9.2f}..{max(warm)*1000:9.2f} first {statistics.median(first)*1000:9.2f}")


if __name__ == "__main__":
    main()

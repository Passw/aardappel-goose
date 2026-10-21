"""Compare committed builtin pool users with their current slot_pool migrations.

Both versions use the same Goose compiler, Clang C O2, inputs and timing order.
Each output must agree; sources, C, build logs and timing samples are retained.
"""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import toolchain as tc

WORKLOADS = {
    "lru_indices": ("bench/goose/lru_indices.goose", []),
    "lru_nonopt": ("bench/goose/lru_nonopt.goose", []),
    "plb_lru_1": ("bench/plb/lru/1.goose", ["1000", "3000000"]),
    "plb_lru_2": ("bench/plb/lru/2.goose", ["1000", "3000000"]),
    "merkletrees": ("bench/plb/merkletrees/1.goose", ["17"]),
}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def execute(binary, args):
    start = time.perf_counter()
    p = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=180)
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return time.perf_counter() - start, p.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "build/slot-pool-users")
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--warmups", type=int, default=2)
    ap.add_argument("--only", nargs="+", choices=WORKLOADS, default=list(WORKLOADS))
    args = ap.parse_args()
    if args.reps < 1 or args.warmups < 1:
        ap.error("positive reps and warmups required")
    exe = tc.find_goose(args.exe)
    compilers = tc.find_ccs()
    compiler = compilers.get("clang")
    if compiler is None:
        raise SystemExit("Clang is required for this comparison")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = dict(platform=platform.platform(), compiler=compiler.desc,
                   baseline=git("rev-parse", args.baseline).decode().strip(),
                   candidate="working-tree", candidate_head=git("rev-parse", "HEAD").decode().strip(),
                   compiler_sha256=digest(exe.read_bytes()),
                   library_sha256=digest((ROOT / "stdlib/slot_pool.goose").read_bytes()),
                   goose_level=2, native_level=2, reps=args.reps, warmups=args.warmups,
                   runs=[])
    for name in args.only:
        path, argv = WORKLOADS[name]
        binaries, hashes, metrics = {}, {}, {}
        for backend in ["reusable", "slot_pool"]:
            folder = out / name / backend
            folder.mkdir(parents=True, exist_ok=True)
            source = git("show", f"{args.baseline}:{path}") if backend == "reusable" else (ROOT / path).read_bytes()
            hashes[backend] = digest(source)
            goose = folder / Path(path).name
            goose.write_bytes(source)
            if path.startswith("bench/goose/"):
                (folder / "rng.goose").write_bytes((ROOT / "bench/goose/rng.goose").read_bytes())
            cfile = goose.with_suffix(".c")
            p = subprocess.run([str(exe), "-O2", "--standalone", "--stacks", "-o", str(cfile), str(goose)],
                               capture_output=True, text=True, timeout=180)
            goose.with_suffix(".log").write_text(p.stdout + p.stderr, encoding="utf-8")
            if p.returncode:
                raise RuntimeError(p.stdout + p.stderr)
            binary = folder / ("run" + tc.EXE_SUFFIX)
            ok, log = compiler.compile(cfile, binary, opt=2)
            (folder / "cc.log").write_text(log, encoding="utf-8")
            if not ok:
                raise RuntimeError(log)
            binaries[backend] = binary
            metrics[backend] = dict(c_bytes=cfile.stat().st_size, exe_bytes=binary.stat().st_size,
                                    stacks=[s for s in (p.stdout + p.stderr).splitlines()
                                            if s.startswith("main program:")])
        timings = {k: [] for k in binaries}
        expected = None
        for rep in range(args.reps + args.warmups):
            order = list(binaries) if rep % 2 == 0 else list(reversed(binaries))
            for backend in order:
                elapsed, output = execute(binaries[backend], argv)
                if expected is None:
                    expected = output
                if output != expected:
                    raise RuntimeError(f"Output mismatch: {name}, {backend}")
                if rep >= args.warmups:
                    timings[backend].append(elapsed)
        medians = {k: statistics.median(v) for k, v in timings.items()}
        ratio = medians["slot_pool"] / medians["reusable"]
        results["runs"].append(dict(workload=name, args=argv, source_hashes=hashes, output=expected,
                                   seconds=timings, median_seconds=medians, ratio=ratio, metrics=metrics))
        (out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(f"{name:16} reusable={medians['reusable'] * 1000:.2f} ms "
              f"slot_pool={medians['slot_pool'] * 1000:.2f} ms ratio={ratio:.3f}", flush=True)


if __name__ == "__main__":
    main()

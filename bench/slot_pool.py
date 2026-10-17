"""Compare slot_pool with reusable using identical workloads and native C builds.

python bench/slot_pool.py --exe build-root/Release/goose.exe
The matrix covers append, sequential/scattered reuse, 8/128-byte elements,
Goose O0/O2, and inline/preserved exercise call boundaries. Artifacts include
generated Goose/C, compiler logs, all timing samples, sizes and stack reports.
Times include process startup, initialization, final checksumming and shutdown.
"""
import argparse
import hashlib
import json
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import toolchain as tc

MODES = {"append": 0, "lifo": 1, "scattered": 2}


def source_for(template, backend, n, live, width, mode, calls, reuse_api="index"):
    for name, value in dict(N=n, LIVE=live, WIDTH=width, MODE=mode).items():
        template, count = re.subn(rf"(?m)^(let {name} = )\d+",
                                  lambda m: m[1] + str(value), template)
        if count != 1:
            raise RuntimeError(f"Missing benchmark constant {name}")
    if calls == "inline":
        template = template.replace("fn exercise(", "inline fn exercise(")
    if reuse_api == "ref":
        old = "let index = p.alloc_index(Item { [(seed + i as u64) as i64; WIDTH] });"
        new = "let index = p.items.index_of(p.alloc_ref(Item { [(seed + i as u64) as i64; WIDTH] }));"
        if template.count(old) != 1:
            raise RuntimeError("Reference reuse conversion no longer matches allocation")
        template = template.replace(old, new)
    if backend == "reusable":
        replacements = {
            "import slot_pool;\n": "",
            "p: slot_pool<Item>&": "p: Item[>..]&",
            "var a = slot_pool<Item> {};": "reusable var a: Item[>..] = [];",
            "var b = slot_pool<Item> {};": "reusable var b: Item[>..] = [];",
        }
        for old, new in replacements.items():
            if template.count(old) != 1:
                raise RuntimeError(f"Workload conversion no longer matches {old}")
            template = template.replace(old, new)
        template = template.replace(".items", "")
    return template


def generate(exe, path, source, level, calls):
    path.write_text(source, encoding="utf-8")
    cfile = path.with_suffix(".c")
    built = subprocess.run([str(exe), f"-O{level}", "--standalone", "--stacks",
                            "-o", str(cfile), str(path)],
                           capture_output=True, text=True, timeout=120)
    report = built.stdout + built.stderr
    path.with_suffix(".log").write_text(report, encoding="utf-8")
    if built.returncode:
        raise RuntimeError(report)
    # Keep identical call policies for both implementations. At O2 an explicit
    # inline Goose function disappears; at O0 request native inlining instead.
    c = cfile.read_text(encoding="utf-8")
    modifier = "GS_NOINLINE" if calls == "boundary" else "GS_INLINE"
    c, count = re.subn(r"(?m)^static uint64_t (exercise_g\w*\()",
                       rf"static {modifier} uint64_t \1", c)
    if calls == "boundary" and count < 2:
        raise RuntimeError("exercise call boundary was removed unexpectedly")
    if calls == "boundary" and len(re.findall(r"\bexercise_g\w*\(", c)) < count + 2:
        raise RuntimeError("expected both owners to cross the exercise call boundary")
    cfile.write_text(c, encoding="utf-8")
    return cfile, dict(c_bytes=cfile.stat().st_size, exercise_declarations=count,
                       stacks=[s for s in report.splitlines() if s.startswith("main program:")])


def run(binary):
    start = time.perf_counter()
    p = subprocess.run([str(binary)], capture_output=True, text=True, timeout=180)
    elapsed = time.perf_counter() - start
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return elapsed, p.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--n", type=int, default=4_000_000, help="reuse allocations, multiple of 256")
    ap.add_argument("--grow-n", type=int, default=1_048_576, help="append allocations, multiple of 256")
    ap.add_argument("--live", type=int, default=4096)
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--warmups", type=int, default=2)
    ap.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    ap.add_argument("--widths", nargs="+", type=int, choices=(1, 16), default=[1, 16])
    ap.add_argument("--levels", nargs="+", type=int, choices=(0, 2), default=[0, 2])
    ap.add_argument("--calls", nargs="+", choices=("inline", "boundary"), default=["inline", "boundary"])
    ap.add_argument("--reuse-api", choices=("index", "ref"), default="index",
                    help="reuse through alloc_index or alloc_ref plus index_of; append always uses alloc_ref")
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "slot-pool-bench")
    args = ap.parse_args()
    if args.n <= 0 or args.grow_n <= 0 or args.n % 256 or args.grow_n % 256:
        ap.error("--n and --grow-n must be positive multiples of 256")
    if args.live < 64 or args.live & (args.live - 1) or args.reps < 1 or args.warmups < 1:
        ap.error("--live must be a power of two >= 64; --reps and --warmups must be positive")
    exe = tc.find_goose(args.exe)
    compilers = tc.find_ccs()
    if not compilers:
        raise SystemExit("No native C toolchain available")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "bench/goose/rng.goose", out / "rng.goose")
    template = (ROOT / "bench/goose/slot_pool.goose").read_text(encoding="utf-8")
    results, checksums = [], {}
    metadata = dict(platform=platform.platform(), n=args.n, grow_n=args.grow_n,
                    live=args.live, reps=args.reps, warmups=args.warmups, executable=str(exe),
                    reuse_api=args.reuse_api,
                    slot_pool_sha256=hashlib.sha256((ROOT / "stdlib/slot_pool.goose").read_bytes()).hexdigest(),
                    workload_sha256=hashlib.sha256(template.encode("utf-8")).hexdigest(), runs=results)
    for mode in args.modes:
        n = args.grow_n if mode == "append" else args.n
        for width in args.widths:
            for level in args.levels:
                for calls in args.calls:
                    case = f"{mode}-{width * 8}B-O{level}-{calls}"
                    generated = {}
                    for backend in ("reusable", "slot_pool"):
                        path = out / f"{case}-{backend}.goose"
                        source = source_for(template, backend, n, args.live, width, MODES[mode], calls,
                                            args.reuse_api)
                        generated[backend] = generate(exe, path, source, level, calls)
                    for compiler in compilers.values():
                        binaries, timings, metrics = {}, {}, {}
                        for backend, (cfile, metric) in generated.items():
                            binary = out / f"{case}-{backend}-{compiler.name}{tc.EXE_SUFFIX}"
                            ok, log = compiler.compile(cfile, binary, opt=2)
                            binary.with_suffix(".cc.log").write_text(log, encoding="utf-8")
                            if not ok:
                                raise RuntimeError(log)
                            binaries[backend], timings[backend] = binary, []
                            metrics[backend] = dict(metric, exe_bytes=binary.stat().st_size)
                        key = (mode, width)
                        # Warm both, then alternate ordering to reduce timing drift.
                        for rep in range(args.reps + args.warmups):
                            order = list(binaries) if rep % 2 == 0 else list(reversed(binaries))
                            for backend in order:
                                elapsed, checksum = run(binaries[backend])
                                expected = checksums.setdefault(key, checksum)
                                if checksum != expected:
                                    raise RuntimeError(f"Checksum mismatch for {case}, {backend}, {compiler.name}")
                                if rep >= args.warmups:
                                    timings[backend].append(elapsed)
                        medians = {k: statistics.median(v) for k, v in timings.items()}
                        row = dict(case=case, compiler=compiler.desc, mode=mode,
                                   item_bytes=width * 8, goose_level=level, calls=calls,
                                   checksum=checksums[key].strip(), seconds=timings,
                                   median_seconds=medians,
                                   ratio=medians["slot_pool"] / medians["reusable"], metrics=metrics)
                        results.append(row)
                        (out / "results.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
                        print(f"{case:32} {compiler.name:8} reusable={medians['reusable'] * 1000:8.2f} ms "
                              f"slot_pool={medians['slot_pool'] * 1000:8.2f} ms ratio={row['ratio']:.3f}", flush=True)


if __name__ == "__main__":
    main()

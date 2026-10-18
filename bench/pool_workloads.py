"""Pair the original and migrated pool users in LangArena and kostya/benchmarks.

Uses local upstream checkouts and the native flags/timing protocol of each suite.
Sources, compiler logs, outputs and individual samples stay under --out.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PATHS = ["bench/kostya/goose/src", "bench/kostya2/matmul",
         "bench/kostya2/primes", "bench/kostya2/common"]
NAMES = ["Matmul::Single", "Matmul::T4", "Matmul::T8", "Matmul::T16",
         "Etc::GameOfLife", "Graph::BFS", "Graph::DFS", "Graph::AStar",
         "Maze::Generator", "Maze::BFS", "Maze::AStar"]
MIGRATE = {f"bench/kostya/goose/src/{name}.goose"
           for name in ["main", "matmul", "game_of_life", "graph_path", "maze"]} | {
               "bench/kostya2/matmul/matmul.goose", "bench/kostya2/primes/primes.goose"}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(out, revision, migrate=False, construct_timer=False):
    names = (git("ls-tree", "-r", "--name-only", revision, "--", *PATHS) if revision
             else git("ls-files", "--", *PATHS)).decode().splitlines()
    hashes = {}
    for name in names:
        data = git("show", f"{revision}:{name}") if revision else (ROOT / name).read_bytes()
        if migrate and name in MIGRATE:
            text = data.decode().replace("import std;", "import std;\nimport slice_pool;")
            text = re.sub(r"reusable\[\] var (\w+): ([\w:]+)\[>\.\.\] = \[\];",
                          r"var \1 = slice_pool<\2> {};", text)
            text = re.sub(r"\b(pool|edges|runs): ([\w:]+)\[>\.\.\]&",
                          r"\1: slice_pool<\2>&", text)
            data = text.encode()
        dst = out / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
        hashes[name] = digest(data)
    # Graph building is outside LangArena's timed window. Observe preparation
    # separately in both copies; constructor/warmup costs also remain in wall time.
    path = out / "bench/kostya/goose/src/bench.goose"
    text = path.read_text()
    needle = "    P(s);\n    W(s, b.warmup);"
    assert text.count(needle) == 1
    text = text.replace(needle, '    let pool_prepare_start = clock();\n    P(s);\n'
                        '    print("pool_prepare_s ", b.name, " ", clock() - pool_prepare_start);\n'
                        '    W(s, b.warmup);')
    path.write_text(text, encoding="utf-8", newline="\n")
    if construct_timer:
        path = out / "bench/kostya/goose/src/main.goose"
        text = path.read_text()
        text = re.sub(r"var s = ((?:matmul|game_of_life|maze)::[^;]+);",
                      r'let pool_construct_start = clock(); var s = \1; '
                      r'print("pool_construct_s ", n, " ", clock() - pool_construct_start);', text)
        path.write_text(text, encoding="utf-8", newline="\n")
    return hashes


def checked(argv, log):
    p = subprocess.run([str(x) for x in argv], cwd=ROOT, capture_output=True, text=True, timeout=600)
    log.write_text(p.stdout + p.stderr, encoding="utf-8")
    if p.returncode:
        raise RuntimeError(f"Command failed: {argv}\n{p.stdout[-2000:]}{p.stderr[-2000:]}")
    return p.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", required=True, type=Path)
    ap.add_argument("--baseline", default="d166ce4c")
    ap.add_argument("--arena", type=Path, required=True)
    ap.add_argument("--kostya", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "build/pool-workloads")
    ap.add_argument("--results", default="results.json", help="result filename within --out")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--copies", type=int, default=3)
    ap.add_argument("--warmups", type=int, default=1)
    ap.add_argument("--cpus", default="16-31")
    ap.add_argument("--only", nargs="+", default=[*NAMES, "kostya2/matmul", "kostya2/primes"])
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("--reuse-builds", action="store_true")
    ap.add_argument("--working-tree", action="store_true",
                    help="compare current benchmark sources instead of mechanically migrating the baseline")
    ap.add_argument("--construct-timer", action="store_true",
                    help="also time grid and matrix constructors in the source snapshots")
    args = ap.parse_args()
    if args.reps < 1 or args.copies < 1 or args.warmups < 0:
        ap.error("positive reps/copies and nonnegative warmups required")
    unknown = set(args.only) - set(NAMES) - {"kostya2/matmul", "kostya2/primes"}
    if unknown:
        ap.error(f"unknown workloads: {sorted(unknown)}")
    os.environ["LANGARENA"] = str(args.arena.resolve())
    os.environ["KOSTYA"] = str(args.kostya.resolve())
    os.environ["GOOSE_STDLIB"] = str(ROOT / "stdlib")
    arena = module("pool_arena", ROOT / "bench/kostya/compare.py")
    kostya = module("pool_kostya", ROOT / "bench/kostya2/compare.py")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    exe = args.exe.resolve()
    meta_path = out / "builds.json"
    ext = ".exe" if os.name == "nt" else ""
    if not args.reuse_builds:
        metadata = dict(baseline=git("rev-parse", args.baseline).decode().strip(),
                        candidate="working-tree" if args.working_tree else "migrated-baseline",
                        construct_timer=args.construct_timer,
                        compiler_sha256=digest(exe.read_bytes()),
                        library_sha256=digest((ROOT / "stdlib/slice_pool.goose").read_bytes()),
                        clang=checked([arena.clang_tools()[0], "--version"], out / "clang.log").strip(),
                        sources={})
        for backend in ["legacy", "library"]:
            folder = out / backend
            revision = None if backend == "library" and args.working_tree else args.baseline
            metadata["sources"][backend] = snapshot(folder, revision, backend == "library" and not args.working_tree,
                                                    args.construct_timer)
            src = folder / "bench/kostya/goose/src/main.goose"
            c = folder / "arena.c"
            checked([exe, "-O2", "--standalone", "--stacks", "-o", c, src], folder / "arena.goose.log")
            checked([arena.clang_tools()[0], *arena.GOOSE_CFLAGS, c, "-o", folder / ("arena" + ext),
                     *([] if os.name == "nt" else ["-lm", "-pthread"])], folder / "arena.cc.log")
            for name in ["matmul", "primes"]:
                c = folder / f"{name}.c"
                checked([exe, "-O2", "--standalone", "--stacks", "--include",
                         folder / "bench/kostya2/common/notify.h", "-o", c,
                         folder / f"bench/kostya2/{name}/{name}.goose"], folder / f"{name}.goose.log")
                extra = []
                if os.name != "nt":
                    kostya.BUILD = folder / "notify-build"
                    extra = kostya.libnotify() + ["-lm", "-pthread"]
                checked([kostya.tool("clang"), *kostya.cflags(), "-std=c23", c, "-o",
                         folder / (name + ext), *extra], folder / f"{name}.cc.log")
            print(f"built {backend}", flush=True)
        meta_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    metadata = json.loads(meta_path.read_text())
    if args.build_only:
        return
    logs = out / Path(args.results).stem
    for backend in ["legacy", "library"]:
        (logs / backend).mkdir(parents=True, exist_ok=True)
    arena.pin_cpus(args.cpus)
    runner = kostya.Runner() if any(n.startswith("kostya2/") for n in args.only) else None
    result = dict(builds=metadata, cpus=args.cpus, reps=args.reps, copies=args.copies,
                  warmups=args.warmups, configurations={}, samples=[], summaries=[])
    for name in ["test.js", "run.js"]:
        config = (args.arena / name).read_bytes()
        (out / name).write_bytes(config)
        result["configurations"][name] = digest(config)
    for backend in ["legacy", "library"]:
        program = out / backend / ("arena" + ext)
        for name in [n for n in args.only if n in NAMES]:
            output = checked([program, out / "test.js", name], logs / backend / (name.replace("::", "-") + ".check.log"))
            matches = [m for line in output.splitlines() if (m := arena.LINE.match(line))]
            assert len(matches) == 1 and matches[0][1] == name and matches[0][2] == "OK", output
    expected = {}
    try:
        for name in args.only:
            kind = name.split("/")[1] if name.startswith("kostya2/") else "arena"
            copies = {}
            for backend in ["legacy", "library"]:
                copies[backend] = []
                for i in range(args.copies):
                    dst = out / backend / f"{kind}-copy{i}{ext}"
                    shutil.copyfile(out / backend / (kind + ext), dst)
                    copies[backend].append(dst)
            for rep in range(args.reps + args.warmups):
                for i in range(args.copies):
                    order = ["legacy", "library"] if (rep + i) % 2 == 0 else ["library", "legacy"]
                    for backend in order:
                        program = copies[backend][i]
                        stem = f"{name.replace('::', '-').replace('/', '-')}-{i}-{rep}"
                        t0 = time.perf_counter()
                        construct = None
                        if kind == "arena":
                            stdout = checked([program, out / "run.js", name], logs / backend / (stem + ".log"))
                            matches = [m for line in stdout.splitlines() if (m := arena.LINE.match(line))]
                            assert len(matches) == 1 and matches[0][1] == name and matches[0][2] == "OK", stdout
                            seconds = float(matches[0][3])
                            prep = re.search(r"pool_prepare_s \S+ ([0-9.eE+-]+)", stdout)
                            assert prep, stdout
                            prepare = float(prep[1])
                            ctor = re.search(r"pool_construct_s \S+ ([0-9.eE+-]+)", stdout)
                            if ctor:
                                construct = float(ctor[1])
                            elif metadata.get("construct_timer") and not name.startswith("Graph::"):
                                raise RuntimeError(f"Missing constructor timer: {name}")
                            checksum = "upstream checksum OK"
                        else:
                            seconds, _, _, _, stdout = runner.run([program, *kostya.group_args(kind)])
                            (logs / backend / (stem + ".log")).write_text(stdout, encoding="utf-8")
                            checksum = digest(stdout.encode())
                            assert checksum == expected.setdefault(name, checksum), (name, stdout)
                            prepare = None
                        wall = time.perf_counter() - t0
                        result["samples"].append(dict(workload=name, backend=backend, copy=i, rep=rep,
                                                      warmup=rep < args.warmups, seconds=seconds,
                                                      prepare_seconds=prepare, construct_seconds=construct,
                                                      wall_seconds=wall, checksum=checksum))
            samples = [s for s in result["samples"] if s["workload"] == name and not s["warmup"]]
            summary = dict(workload=name)
            for metric in ["seconds", "prepare_seconds", "construct_seconds", "wall_seconds"]:
                values = {b: [s[metric] for s in samples if s["backend"] == b and s[metric] is not None]
                          for b in ["legacy", "library"]}
                if values["legacy"]:
                    medians = {b: statistics.median(v) for b, v in values.items()}
                    summary[metric] = dict(median=medians, min={b: min(v) for b, v in values.items()},
                                           max={b: max(v) for b, v in values.items()},
                                           ratio=medians["library"] / medians["legacy"] if medians["legacy"] else None)
            result["summaries"].append(summary)
            (out / args.results).write_text(json.dumps(result, indent=2), encoding="utf-8")
            print(name, json.dumps(summary), flush=True)
    finally:
        if runner:
            runner.srv.close()


if __name__ == "__main__":
    main()

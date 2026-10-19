# Pools in application benchmarks

`reusable` and `reusable[]` are deprecated. Prefer `slot_pool<T>` and
`slice_pool<T>` for new code. The builtins remain comparison baselines here;
their removal is separate from migrating these benchmarks.

## Allocation policy

`slice_pool` uses the same augmented B+ tree as `reusable[]`, not the old
sorted-array freelist. Both have 512-byte nodes, 31 spans per leaf and 20
children per inner node. They use first fit in address order, adjacent-span
coalescing, free-tail reuse, the same split points, empty-node recycling and
root collapse. Growing a non-tail run searches for its neighbors once; it
either consumes the following free span or releases and relocates the run.

The original B+ tree commit, `1e8b36b9`, explains the reason: scanning and
shifting a flat freelist made scattered lists grown one element at a time
quadratic. LangArena's graph construction does exactly that. The commit does
not name a benchmark, so this is a match to its motivating workload, not proof
that Graph was the particular benchmark that prompted it. `97d48286` later
shared the neighbor search when a run cannot grow at the array's end; the
library also includes that refinement.

The remaining differences are implementation costs: typed, checked accesses
to metadata, initialized path scratch space, generic helper code, and typed
relocation/defaulting loops instead of the runtime's bulk memory operations.
No bounds, containment, overflow or initialization checks were disabled for
these measurements.

## Coverage and method

The source inventory covered `bench/kostya`, `kostya2`, `plb`, `plb2`,
`bddicken` and `goose`. All eleven LangArena pool users and both kostya2 pool
users can be mechanically converted without changing their algorithms,
payload layouts, seeds, iteration counts or allocation order. The conversion
changes imports, owner declarations and reference parameter types only.

LangArena excludes `prepare` from its reported time. In particular, its graph
allocator runs during preparation, not during the searches. The harness adds
an identical preparation timer to both generated source snapshots and also
measures whole-process wall time, including constructors, warmup and teardown.
An optional second timer observes grid/matrix constructors. The committed
suite runner is uninstrumented. kostya2 uses its existing TCP
start/stop measurement protocol and unchanged arguments (Matmul 1500; Primes
upper bound 5,000,000).

Measured on Windows x64, Ryzen 9 9950X3D, clang 22.1.3, CPUs 16–31. Both sides
use the same Goose compiler (source `3fd2d4fe`) at O2, with the current stdlib;
baseline benchmark sources are `d166ce4c`. Native flags are the existing suite
flags: O2 and strict aliasing for LangArena; O3, native architecture, LTO and
the suite's branch alignment flags for kostya2. These paired Windows results
are not replacements for the suites' Linux comparisons against other languages.

Each executable has three renamed copies, with one discarded warmup and three
measured runs per copy. Backend order alternates. Tables use the median of all
nine measured samples per side, not the best copy. Renamed copies exercise
Windows code-placement variation; this does not remove all layout or scheduling
effects. Every sample, including warmups, is retained with source, compiler,
library and upstream configuration fingerprints. LangArena checks its upstream
checksum on every run; kostya2 runs its built-in verification and both backends
must print identical results.

## Full candidate comparison, 2026-10-18

All times below are milliseconds in the suites' reported windows. Ratios are
library / builtin, so values above 1 mean the library took longer.

| Workload | Builtin | Library | Ratio | Whole-process ratio |
|---|---:|---:|---:|---:|
| Matmul Single | 2493 | 2485 | 0.997 | 0.997 |
| Matmul T4 | 672 | 674 | 1.003 | 1.005 |
| Matmul T8 | 383 | 386 | 1.008 | 1.009 |
| Matmul T16 | 225 | 226 | 1.004 | 1.004 |
| Game of Life | 269 | 267 | 0.993 | 0.993 |
| Graph BFS | 723 | 695 | 0.961 | 1.046 |
| Graph DFS | 885 | 900 | 1.017 | 1.060 |
| Graph AStar | 183 | 185 | 1.011 | 1.086 |
| Maze Generator | 246 | 248 | 1.008 | 1.029 |
| Maze BFS | 228 | 228 | 1.000 | 0.997 |
| Maze AStar | 554 | 487 | 0.879 | 0.903 |
| kostya2 Matmul | 201.90 | 201.69 | 0.999 | 1.002 |
| kostya2 Primes | 30.83 | 32.93 | 1.068 | 1.046 |

Graph preparation tells a different story from its search timer:

| Graph | Builtin preparation | Library preparation | Ratio |
|---|---:|---:|---:|
| BFS | 1018.36 | 1120.65 | 1.100 |
| DFS | 1015.11 | 1124.20 | 1.107 |
| AStar | 1020.79 | 1127.65 | 1.105 |

The preparation ranges do not overlap: for example, BFS is 1013–1027 ms versus
1117–1126 ms. Primes also separates clearly, at 30.37–31.63 ms versus
32.61–33.79 ms. These are real regressions in allocation-heavy application work,
even though they are modest compared with the former quadratic behavior.

Conversely, the apparent Maze AStar improvement is not evidence of a faster
allocator: its timed search does not allocate from the cell pool, and sample
ranges overlap substantially (471–628 ms versus 460–545 ms). Maze Generator's
2.9% whole-process difference also has overlapping ranges. These are reasons
to repeat the final selection, not claim a speedup from one binary layout.

The [full candidate samples](pool_workloads_results.json) preserve all thirteen
comparisons. The [resize-inlining trial](pool_workloads_inline_results.json)
adds `inline` only to `realloc_slice`, with the same sampling policy. It leaves
Graph AStar preparation 11.0% slower and Primes 4.9% slower than the builtin.
That trial was discarded: it does not close either migration gap, and its
small Primes difference does not justify a general inlining policy change.

## Follow-up measurements

The [repeat samples](pool_workloads_repeats.json) contain two further sessions:
the candidate selection with Graph and Primes restored to the builtin, and
another build with explicit constructor timers. Each uses the same three-copy,
nine-sample policy. Matmul T16's temporary 4% difference returned to 0.4% in
the constructor session, including parity in construction and whole-process
time. Game of Life was 266 / 266 ms, with whole-process time 342.52 / 342.62 ms.
Its construction cost is 4.79 / 5.04 ms: a small real setup overhead, about
0.07% of the full workload.

Maze construction is also slightly slower, with a repeatable cost that its
search timer hides:

| Maze constructor | Builtin, ms | Library, ms | Ratio |
|---|---:|---:|---:|
| Generator | 55.11 | 56.98 | 1.034 |
| BFS | 54.66 | 56.62 | 1.036 |
| AStar | 54.63 | 56.55 | 1.035 |

Maze Generator's whole-process median is 2.3–3.4% higher across the three
sessions, despite broad overlapping ranges and nearly equal timed generation.
The constructor difference explains about 2 ms, not the entire wall-time gap;
the remainder is not isolated. These costs are small, but keeping the Maze
family on the builtin is the conservative choice when requiring migration
costs to stay within measurement noise. No algorithm or safety change is
warranted to chase them here.

## Initial migration decisions, 2026-10-18

The initial migration moved Matmul (including worker-local pools) and Game of
Life to `slice_pool`. Graph, Maze and Primes initially retained `reusable[]`
because their setup/trie-building costs regressed measurably. Their data
structures are unchanged; replacing graph adjacency lists with compressed sparse
rows would measure a different algorithm.

The scalar-pool users in `bench/goose/lru*.goose`, `bench/plb/lru` and
`bench/plb/merkletrees` initially remained on `reusable`. They use compact
pool-relative links, destination-aware self construction, or self-relative values that
cannot pass through `slot_pool`'s value argument. Even `lru_indices` has
self-relative links inside its nodes. Substituting full pointers or a different
node layout would confound the allocator comparison. These are compatibility
gaps, not measured slot-pool slowdowns. `plb2` and `bddicken` contain no builtin
pool users; the dedicated slot/slice microbenchmarks already cover both backends.

The [initial accepted-source run](pool_workloads_accepted_results.json) rebuilds
after restoring Maze as well, and its source fingerprints match that initial
migration's sources. It is noisier than the initial run on both sides. The six
timed ratios are 1.012, 0.990, 1.008 and 1.027 for Matmul Single/T4/T8/T16, 1.000 for
Game of Life, and 0.985 for kostya2 Matmul; their whole-process ratios span
0.983–1.023. Ranges overlap and the small differences are not consistent across
sessions. This supports migration within the observed variation, not a claim
that the costs are identical on every platform.

Validation: all 50 upstream LangArena `test.js` checksums pass in a fresh,
uninstrumented native build. Every one of the 840 recorded A/B samples,
including warmups and discarded candidates, passes the corresponding checksum
or output comparison. kostya2's built-in small-input verifications also run on
every invocation. A direct `lru_indices` conversion confirms the expected
self-relative-copy diagnostic in `slot_pool.alloc_index`. The accepted source
changes keep LangArena's 30 main/global data-stack regions and 23 regions per
worker unchanged. Python compilation and `git diff --check` pass. Compiler and
stdlib sources are unchanged; the compiler regression suite was not rerun for
these benchmark-only edits.

## Remaining slice-pool migrations, 2026-10-19

Graph, Maze and Primes now also use `slice_pool`; their measured overhead is
accepted. The source changes preserve algorithms, allocation order, compact
element layouts and checks. The archived results above describe the comparison
and the initial conservative selection, not a requirement to keep the builtin.

Across the three graph workloads, the measured extra preparation totals 318 ms;
the three maze constructors add about 6 ms. A complete current LangArena run
before this final migration took 30.05 seconds elapsed (22.27 seconds in its
reported benchmark windows). Adding the measured 324 ms predicts 30.37 seconds,
about 1.08% slower overall. This is a component-based estimate, not a full-suite
A/B measurement; the suite excludes the extra setup from its reported score.

Validation: all 50 LangArena workloads pass both the upstream small-input checks
and the full-size suite in a fresh, uninstrumented native build. Primes passes
its small-input checks and produces identical output to the builtin baseline.
The file-tree sample also uses `slice_pool` for directory entries; its expected
output is unchanged at O0/O2 with both native debug checks and TinyCC. The
document-buffer example in `docs/design/owning_dynamic_data.md` compiles and runs
with the library pool. Compiler and stdlib sources remain unchanged.

## Global component paths and scalar migrations, 2026-10-19

Global array-field names now work in compact reference and index types.
`bench/goose/lru.goose` uses `slot_pool`, with its links naming `pool.items`.
The compact node/map layouts and workload algorithms are unchanged.
The file-tree sample and document-buffer example also
use `slot_pool` for their descriptors. The slot microbenchmark template is named
`goose/slot_pool_bench.goose` so that it does not shadow the stdlib import from
neighboring benchmark sources.

The self-relative LRU variants and the sentinel-based PLB LRU variants still
need destination-aware construction. They remain on the builtin.

The [paired scalar results](root_component_pool_results.json) compare the
previous committed source with each migration using the same compiler, Goose
O2 and Clang C O2, on CPUs 16–31. One warmup and five measured runs alternate
the two versions; times cover the complete process. Every output matches.
LRU's full 8,000,000-operation workload measures 299.9 ms builtin versus
257.2 ms library (0.858x). Its 16-byte nodes and 8-byte map slots are unchanged.
This is one local session, not a claim of a portable speedup.

The Merkle-tree migration is now expressible with its existing layout, but at
depth 16 measures 70.6 ms builtin versus 114.4 ms library (1.620x). It remains
on `reusable` pending investigation of this larger gap. Source hashes and all
individual samples are retained in the results file.

## Remaining optimization work

There is no demonstrated simple library change that closes the remaining slice-pool gap.
Useful directions are eliminating redundant path initialization when writes
can be proven complete, improving bounds proofs across tree helpers, and safe
bulk relocation/defaulting code generation. They need care around overlapping
moves, declared defaults with side effects, and self-relative element types.
Field privacy would help encapsulation, but alone would not prove index ranges
or make removing checks sound. The existing checked library is a reasonable
stopping point unless these allocation-heavy cases become a priority.

## Reproduce

```text
python bench/pool_workloads.py --exe build-root/Release/goose.exe --arena C:/W/LangArena --kostya C:/W/kostya-benchmarks --out build-root/pool-workloads-ab
python bench/pool_workloads.py --exe build-root/Release/goose.exe --arena C:/W/LangArena --kostya C:/W/kostya-benchmarks --out build-root/pool-workloads-accepted --working-tree --construct-timer --only Matmul::Single Matmul::T4 Matmul::T8 Matmul::T16 Etc::GameOfLife kostya2/matmul
```

The default mechanically migrates all eligible sources from `--baseline`.
`--working-tree` instead measures the current tracked benchmark sources.
`--build-only` prepares snapshots; `--reuse-builds` measures the saved binaries
without rebuilding them.
Use a new `--out` for a new build and `--results` to retain a repeat's samples.
`--only`, `--reps`, `--copies`, `--warmups` and `--cpus` select work and sampling.
`--construct-timer` adds constructor timing alongside preparation and wall time.
Choose CPU indices appropriate for the local machine. Logs, generated C, source
snapshots and binaries stay under the output directory.

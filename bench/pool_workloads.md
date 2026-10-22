# Pools in application benchmarks

`reusable` and `reusable[]` are deprecated. Prefer `slot_pool<T>` and
`slice_pool<T>` for new code. The builtins remain comparison baselines here;
their removal is separate from migrating these benchmarks.

Current migration status: the scalar workloads use `slot_pool`, and the slice
workloads use `slice_pool` except for LangArena's `Etc::CacheSimulation`.
That migration remains outstanding. Worker snapshots also remain unsupported
by root owners. The dated sections below preserve earlier decisions and
measurements; the latest scalar results are in
[Known global roots implemented](#known-global-roots-implemented-2026-10-22),
and the latest Graph/Primes results are in the
[tree-maintenance follow-up](#tree-maintenance-port-follow-up-2026-10-21).

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

The tree-maintenance changes in `1ab1d26d` are also ported: subtree maxima follow
the changed count, allocation reuses prefix maxima gathered during descent, and
neighbor lookup only constructs another path when the next leaf touches the run.
First-fit placement and coalescing are unchanged. The
[2026-10-21 allocator comparison](slice_pool.md#tree-maintenance-port-2026-10-21)
uses the improved builtin as its baseline. The earlier application timings
below predate this update; a new Graph BFS/Primes subset is recorded at the end.

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

At this stage, the self-relative LRU variants and sentinel-based PLB LRU
variants still needed destination-aware construction and stayed on the builtin.

The [paired scalar results](root_component_pool_results.json) compare the
previous committed source with each migration using the same compiler, Goose
O2 and Clang C O2, on CPUs 16–31. One warmup and five measured runs alternate
the two versions; times cover the complete process. Every output matches.
LRU's full 8,000,000-operation workload measures 299.9 ms builtin versus
257.2 ms library (0.858x). Its 16-byte nodes and 8-byte map slots are unchanged.
This is one local session, not a claim of a portable speedup.

The Merkle-tree migration is now expressible with its existing layout, but at
depth 16 measures 70.6 ms builtin versus 114.4 ms library (1.620x). It stayed
on `reusable` pending investigation of this larger gap. Source hashes and all
individual samples are retained in the results file.

## Tree-maintenance port follow-up, 2026-10-21

The [refreshed application samples](pool_workloads_rescan_results.json) cover
Graph BFS and Primes with `1ab1d26d` in the builtin runtime and its algorithm
ported to the library (`d3eec1b3`). Both source variants use the same compiler
executable and Clang flags. The baseline benchmark sources are still
`d166ce4c`; the candidate is the current migrated source. This uses the existing
three-binary-copy, nine-measurement protocol on CPUs 16–31, with one warmup per
copy. All upstream checksums and paired outputs match.

| Workload | Measurement | Improved builtin, ms | Ported library, ms | Ratio |
|---|---|---:|---:|---:|
| Graph::BFS | preparation | 1092.64 | 1245.80 | 1.140 |
| Graph::BFS | timed work | 1700.00 | 1779.00 | 1.046 |
| Graph::BFS | whole process | 3141.52 | 3398.98 | 1.082 |
| kostya2/primes | timed work | 44.63 | 52.45 | 1.175 |
| kostya2/primes | whole process | 76.26 | 88.51 | 1.161 |

Graph preparation is 14.0% longer and the complete process 8.2% longer in this
session. Its timed search does not allocate from the pool; the 4.6% search-time
difference cannot be assigned to free-span maintenance. Primes' timed work is
17.5% longer. Sample ranges overlap: Graph preparation is 966–1,232 ms builtin
versus 1,141–1,347 ms library, and Primes' timed work is 40.4–52.0 ms versus
43.8–56.1 ms. These are local observations with substantial spread, not precise
predictions or a measurement of the complete LangArena suite.

The interleaved allocator comparison isolates the port from the updated
builtin baseline: the library itself takes 8–30% less time on fragmented reuse
and 13–29% less on resize than its previous implementation. No application
algorithm, layout, allocation order or safety check was changed to obtain this.

Reproduce this application subset with the existing command below, adding
`--working-tree --only Graph::BFS kostya2/primes` and choosing a fresh `--out`.

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

## Builder construction migrations, 2026-10-21

`alloc_with` removes the construction blocker for self-relative nodes and
pool-relative `self`. The memory and linked-list samples now use `slot_pool`;
the linked-list sentinel is constructed by a builder. The two self-relative
LRU variants, both PLB LRU variants and Merkle trees also use the library.
Compact element layouts, allocation/free order, algorithms and output are
preserved. `items.index_of` obtains indices from builder results.

```text
python bench/slot_pool_users.py --exe build-root/Release/goose.exe --baseline f5cf82e0 --out build-root/alloc-with-final-users
```

The harness compares the committed builtin sources with the working tree,
using one compiler executable, Goose O2 and Clang C O2. It retains generated
sources/C, logs, sizes, stack counts and timing samples, checks every output,
and alternates execution order. This run has two warmups and seven measured
runs per version. LRU variants use their full 8,000,000-operation workload;
PLB LRU uses `1000 3000000`, and Merkle trees use depth 17. Times cover the
complete process. [Raw results](slot_pool_builder_users_results.json) include
compiler/library/source fingerprints and the full matching outputs.

| Workload | Reusable, ms | Slot pool, ms | Ratio |
|---|---:|---:|---:|
| lru_indices | 301.53 | 354.16 | 1.175x |
| lru_nonopt | 307.27 | 301.34 | 0.981x |
| plb_lru_1 | 123.98 | 124.43 | 1.004x |
| plb_lru_2 | 57.84 | 57.06 | 0.987x |
| merkletrees | 128.71 | 153.48 | 1.192x |

The nonoptional LRU and PLB variants are close to parity in this session.
This unpinned run measured `lru_indices` about 18% slower and Merkle trees
about 19% slower. The controlled follow-up below reproduces the Merkle gap,
but does **not** reproduce an 18% LRU penalty; that figure should not be used
as an estimate of the migration's cost. The Merkle result improves on the earlier
value-parameter migration, but that older 1.620x result used a different
compiler and depth 16; it is not a controlled before/after optimization claim.
A native-inlining experiment did not materially change the Merkle result
and was not retained. Further optimization remains separate work.

The unchanged sample outputs pass at O0/O2 with runtime checks. Full native
and TinyCC baseline validation also passes. Existing builtin regression
fixtures and differential tests continue testing `reusable` unchanged.

## Explaining the scalar-pool gaps, 2026-10-22

Neither workload uses the slice allocator's free-span tree. `slot_pool` and
scalar `reusable` both use a LIFO stack of free indices, with the same node
layout and allocation/free order here. Builders construct directly in the
selected slot; there is no temporary-node copy to explain these differences.

The [diagnostic harness](slot_pool_diagnose.py) reuses the **original binaries**
for the two controls and builds experimental variants beside them. Every run
must produce exactly the same output. It randomizes execution order with a
fixed seed, uses three warmups and fifteen measured runs per variant, and
sets CPU affinity inherited by the child processes. These experiments change
neither the production library nor the compiler. The raw results retain
individual samples and C/binary fingerprints, plus the original build metadata.

### Merkle: known array identity is lost across helper calls

The native assembly, not just the generated C, shows extra descriptor loads
and metadata reloads in the pool version. A representative access is
`pool.items.hdr->len` or `pool.free_slots.stk->top`, versus a direct global
header/stack access in the builtin. After writing an element or pushing a
free index, the library version reloads descriptor pointers and writes cached
metadata back through them. Direct access gives the native compiler better
knowledge of which storage these operations can affect.

Goose already projects direct root-field accesses onto their independent
array components, including through aliases exposed by Goose inlining.
However, `Optimizer::TryInline` deliberately does not inline into recursive
functions: doing so without adjusting stack assignment would violate its
recursive-local allocation rules. Merkle's `make` and `free_tree` therefore
call helpers whose root parameters still compile as descriptor references.
Clang O2 does inline those helpers in the native code, but the descriptor
indirections survive. There are no native `alloc_with`/`free` calls left to
remove; forcing native inlining again is not the missing optimization.

On CPUs 16–31 of the Ryzen 9 9950X3D, depth 17:

| Variant | Whole process, ms | Relative to builtin |
|---|---:|---:|
| Original `reusable` binary | 124.17 | 1.000x |
| Original `slot_pool` binary | 147.92 | 1.191x |
| C helpers address the known global components directly; all checks retained | 127.95 | 1.030x |
| Checked Goose allocation helper explicitly names the global pool | 131.67 | 1.060x |
| Checked Goose allocation and free helpers explicitly name the global pool | 130.27 | 1.049x |
| Original pool C with only recycled-index bounds checks removed | 146.94 | 1.183x |

[Raw samples](slot_pool_diagnosis_results.json). The C specialization changes
only how the helpers address array headers and stacks. The two Goose variants
independently demonstrate the same opportunity with ordinary safe source: they
duplicate the small checked helper bodies and refer to this program's global
`pool` directly instead of accepting a root reference. They are experiments,
not a suggested library API. Repeated exploratory comparisons also brought
the direct-component variant within roughly 4–5% of the builtin.

Thus most of the observed Merkle gap is recoverable without changing the
algorithm or removing checks. This workload makes roughly 30 million small
nodes at depth 17, so a little extra work per allocation/free has a visible
whole-program cost. The experiment does not attribute every remaining
percentage point: instruction scheduling, register use, checks and code layout
also differ, and the timings are not an additive breakdown of their costs.

**Difficulty:** a focused compiler optimization of moderate complexity, rather
than an allocator redesign. Preserve a proven concrete root identity through
calls, or specialize a helper for its known root, so its component accesses
use the existing direct-array codegen. This does not require assuming there
can be only one instance of `slot_pool<T>` in a program. Unknown or multiple
possible roots must keep the generic path. A correct implementation must
handle multiple callers/instances, recursive calls, captured references and
builders that mutate the pool; stack-top/length caches must still be flushed
and reloaded at the right boundaries. Simply enabling all Goose inlining
inside recursive functions would bypass the reason for the current restriction.

The unchecked row is an **unsafe diagnostic counterfactual**, never a proposed
implementation: public `free_slots` can contain arbitrary indices. Its small
effect suggests field privacy/check elimination is not the first lever for
this workload. Privacy alone also would not supply the compiler with a proof
that every recycled index is in bounds. Both existing implementations already
check the index passed to `free`.

### LRU: the earlier large penalty is not reproducible

`lru_indices` already gets direct component accesses and cached array metadata
in its main loop, so Merkle's descriptor issue does not explain it. There is a
real code-generation difference: the migration uses
`items.index_of(alloc_with(...))`, then indexes `items` again. Native assembly
retains the pointer subtraction, signed division by 16 (shifts/correction,
not a hardware divide), and the subsequent bounds check. The builtin returns
the index directly.

Two safe experiments address that difference: keep the builder's reference
for `link_front`, or use a checked `alloc_index_with` helper which returns the
selected index. Neither establishes a substantial speedup in the controlled
runs. The original LRU binaries themselves are already close to parity under
matched affinity; see the table and samples below. On CPUs 16–31 the sample
ranges are broad (309–471 ms builtin, 309–372 ms pool), so a few percent of
median difference is not evidence that one implementation is faster.

| Variant | CPUs 16–31, ms (ratio) | CPUs 0–15, ms (ratio) |
|---|---:|---:|
| Original `reusable` binary | 339.03 (1.000x) | 143.25 (1.000x) |
| Original `slot_pool` binary | 328.02 (0.968x) | 143.98 (1.005x) |
| Keep the builder's reference | 328.20 (0.968x) | 143.97 (1.005x) |
| Checked index-returning builder | 328.84 (0.970x) | 142.51 (0.995x) |
| Remove only recycled-index checks (unsafe diagnostic) | 334.96 (0.988x) | 144.43 (1.008x) |

Raw samples: [CPUs 16–31](slot_pool_diagnosis_results.json),
[CPUs 0–15](slot_pool_diagnosis_cpus0_results.json).

The machine has two markedly different CPU groups for this workload. The
original run did not record affinity, so its precise cause cannot be recovered.
Scheduling/cache placement and other session variation are confounders; the
historical 18% number does not establish an 18% library overhead. There is no
demonstrated large LRU gap here that needs a difficult optimization to close.

Reproduce the controlled experiments from the saved application comparison:

```text
python bench/slot_pool_diagnose.py --exe build-root/Release/goose.exe --input build-root/alloc-with-final-users --out build-root/pool-diagnose-final --cpus 16-31
python bench/slot_pool_diagnose.py --exe build-root/Release/goose.exe --input build-root/alloc-with-final-users --out build-root/pool-diagnose-final-cpus0 --cpus 0-15 --only lru_indices
```

Use CPU indices available on the test machine. To prepare the input directory,
run `slot_pool_users.py` with the builder-migration command above. The diagnostic
harness requires the same Goose executable, library contents and Clang version
as that saved comparison; it fails if the expected source/C shapes change.

## Known global roots implemented, 2026-10-22

`50bfcb6c` preserves a root parameter's concrete global owner when all incoming
calls agree, including recursive forwarding. `1dfda8ed` lets these aliases use
the existing component caches and call synchronization. Helpers shared by
different owners or passed opaque references keep their descriptors. This
changes codegen, not the library's allocation policy or safety checks; see the
[implementation scope](../docs/design/root_structs.md#known-root-identity-across-function-calls).

The comparison now runs three versions in rotating/reversed order: builtin
and pool sources compiled with the new compiler, plus the saved pool binary
from before these changes. It verifies identical source/library fingerprints
for the two pool versions and checks every output. This run uses CPUs 16–31,
Clang C O2, Goose O2, three warmups and fifteen measured repetitions. Inputs
are the same as the builder migration above.

| Workload | Builtin, ms | Previous pool, ms | New pool, ms | New / builtin |
|---|---:|---:|---:|---:|
| lru_indices | 342.89 | 348.47 | 302.79 | 0.883x |
| lru_nonopt | 419.38 | 437.89 | 454.38 | 1.083x |
| plb_lru_1 | 119.29 | 119.40 | 119.79 | 1.004x |
| plb_lru_2 | 52.18 | 52.30 | 52.39 | 1.004x |
| merkletrees | 125.92 | 149.50 | 131.06 | 1.041x |

[Raw results](slot_pool_known_root_users_results.json) include all samples and
the old/new binary fingerprints. Merkle's pool time falls **12.3%**, reducing
its gap against the builtin from **18.7% to 4.1%**. A separate seven-sample
[repeat](slot_pool_known_root_repeat_results.json) measured 125.80 ms builtin,
149.16 ms previous pool and 130.34 ms new pool: **3.6%** above the builtin and
**12.6%** less time than the previous pool. Its generated allocator/free helpers
now access the global components directly, with ordinary checked indexing and
cached metadata. Its stack count remains five regions.

All four LRU programs generate exactly the same C as before after excluding
the generated-file comment and diagnostic source-path strings. Their timing
differences therefore do not establish compiler improvements or regressions:
run conditions and binary layout are confounders for these timings. PLB LRU
stays near parity. Merkle is the
application in this set whose generated operations change.

```text
python bench/slot_pool_users.py --exe build-root/Release/goose.exe --baseline f5cf82e0 --previous build-root/alloc-with-final-users --out build-root/known-roots-users --cpus 16-31 --reps 15 --warmups 3
python bench/slot_pool_users.py --exe build-root/Release/goose.exe --baseline f5cf82e0 --previous build-root/alloc-with-final-users --out build-root/known-roots-users-repeat --cpus 16-31 --reps 7 --warmups 2 --only merkletrees
```

`--previous` requires saved binaries from the earlier run, compiled with the
same native compiler/settings and unchanged Goose/library sources; only the
Goose compiler executable is expected to differ. `--cpus` is also available
without a previous build. Choose a fresh output directory and suitable CPU
indices for the machine.

The complete Windows baseline passes: 664 native O0/O2 checks, 174 runtime-debug
checks, 803 TinyCC runs and 2,017 expected type errors, plus bootstrap, samples,
reference examples and generated-C cache checks. The four new identity/cache/
builder/corruption fixtures also pass with the assertion-enabled compiler and
Clang C O2, at both Goose O0 and O2 with runtime checks. Optional native modules
and other platforms were not tested here. The
[microbenchmark rerun](slot_pool.md#known-global-root-follow-up-2026-10-22)
covers the generic path with multiple local pool instances.

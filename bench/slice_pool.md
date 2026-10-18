# slice_pool versus reusable[]

`reusable` and `reusable[]` are **deprecated**. Use
[`slot_pool<T>`](../docs/stdlib.md#slot_pool) for slots and
[`slice_pool<T>`](../docs/stdlib.md#slice_pool) for contiguous runs. The builtins
remain available for existing code and the remaining migration gaps; this report
retains `reusable[]` as the comparison baseline.

The library uses the builtin's augmented B+ tree policy: first-fit placement,
neighbor coalescing, tail reuse, emptied-node recycling and overlap-safe
relocation. It does not substitute a linear freelist or change allocation order.

## Reproduce

```text
python bench/slice_pool.py --exe build-root/Release/goose.exe --n 2000000 --grow-n 262144 --reps 9 --warmups 3 --affinity 0x4
python bench/slice_pool.py --exe build-root/Release/goose.exe --n 2000000 --grow-n 4194304 --modes append --widths 1 --reps 9 --warmups 3 --affinity 0x4 --out build/slice-pool-append-long
```

The optional affinity mask pins the harness and its child processes to the same
logical processor; omit it or select an available processor on other machines.
The second command repeats the short 8-byte append workload with sixteen times
more allocations to reduce startup/scheduling noise. It is not needed to run the
ordinary matrix.

The harness discovers native compilers through `scripts/toolchain.py` and saves
generated Goose/C, a snapshot of the library, compiler logs, binary sizes, stack
reports and every timing sample. `--library` selects another library source for
comparison; the default is the current stdlib implementation. Results fingerprint
the compiler executable, library and workload. `--out`, `--modes`, `--widths`,
`--levels` and `--calls` select output and subsets of the matrix. The default
Goose optimization level is O2; native C is always optimized at level 2.

## Workloads and validation

Both implementations come from [one template](goose/slice_pool.goose). The
conversion changes imports, owner declarations, parameter types and `items`
projections. Work, allocation order, values, random seeds and checksums are
identical. Two owners divide the work three quarters / one quarter.

* **append:** allocate runs of 16 elements, write their first and last payload
  words, retain an early slice and checksum returned positions.
* **fragmented:** start with 4,096 live runs per owner, separated by live elements
  to force distinct free spans and tree splits. Repeatedly free a pseudorandomly
  selected run and allocate a replacement of 1–64 elements.
* **resize:** use the same separated runs, repeatedly grow a selected run by one
  element and shrink it to one after reaching 64. Check preservation of its first
  word; this exercises in-place extension, shrinking, coalescing and relocation.

Each scenario uses 8-byte and 128-byte elements. **inline** marks the exercise
function `inline fn`. **boundary** preserves it as `GS_NOINLINE` in the generated
C for both implementations; the harness checks that both owner calls survive.
The API helpers otherwise follow their ordinary inlining rules. All assertions,
slice checks and bounds checks remain enabled.

There are three discarded warmups and nine timed runs per binary, alternating
the order of the two implementations. Reported times are median whole-process
wall times, including initialization, final checksumming of every backing-array
element, printing and teardown. Checksums must agree across implementations,
call policies and compilers for each workload and element size.

The separate regression tests compare every element and allocation position
during a deterministic mixed-operation trace, exercise thousands of spans and
tree levels, and cover overlap, retained views, defaults with side effects,
self-relative default construction, empty slices and worker-local ownership.
Negative cases cover foreign slices, invalid lengths, corrupted free-span
indices, missing defaults, constness and lifetime violations. Double free and
use of a logically freed run remain application errors, as with the builtin.

## Windows x64 results, 2026-10-17

AMD Ryzen 9 9950X3D; MSVC 19.51.36260 (toolset 14.51.36231) and clang-cl 22.1.3,
both using `/O2`; affinity mask `0x4`. Compiler source is `3fd2d4fe`; library
source is `97731a4f`. All **24 matrix comparisons** and **4 longer append
comparisons** matched checksums. The [matrix results](slice_pool_results.json)
and [longer append results](slice_pool_append_results.json) retain every sample
and source fingerprint.

Each time cell is **reusable[] / slice_pool**, in milliseconds. The ratio is
`slice_pool / reusable[]`; above 1 means the library took longer. The two
8-byte append rows use the longer repeat (4,194,304 allocations); 128-byte append
uses 262,144 allocations. Fragmented and resize workloads use 2,000,000 operations.

| Workload | Item bytes | Calls | MSVC times | Ratio | clang times | Ratio |
|---|---:|---|---:|---:|---:|---:|
| append | 8 | inline | 128.61 / 150.26 | 1.168 | 119.61 / 137.27 | 1.148 |
| append | 8 | boundary | 113.00 / 112.19 | 0.993 | 110.05 / 112.19 | 1.019 |
| append | 128 | inline | 102.69 / 119.01 | 1.159 | 96.75 / 98.58 | 1.019 |
| append | 128 | boundary | 98.12 / 113.28 | 1.155 | 97.33 / 111.77 | 1.148 |
| fragmented | 8 | inline | 280.67 / 301.97 | 1.076 | 316.36 / 339.22 | 1.072 |
| fragmented | 8 | boundary | 280.24 / 307.13 | 1.096 | 313.81 / 329.99 | 1.052 |
| fragmented | 128 | inline | 351.61 / 379.14 | 1.078 | 390.45 / 414.84 | 1.062 |
| fragmented | 128 | boundary | 351.40 / 380.89 | 1.084 | 387.66 / 417.42 | 1.077 |
| resize | 8 | inline | 191.40 / 220.08 | 1.150 | 214.24 / 235.96 | 1.101 |
| resize | 8 | boundary | 187.60 / 222.86 | 1.188 | 209.33 / 232.45 | 1.110 |
| resize | 128 | inline | 248.71 / 276.02 | 1.110 | 270.61 / 294.85 | 1.090 |
| resize | 128 | boundary | 245.87 / 277.42 | 1.128 | 275.85 / 303.02 | 1.098 |

Fragmented reuse takes about 5–10% longer, and resize about 9–19% longer.
Append ranges from near parity to about 17% longer. Preserved calls do not
introduce a separate large penalty in this matrix. These are allocation-heavy
workloads; they support accepting the remaining overhead for the library API,
not a universal performance guarantee or a prediction of whole-application cost.

The original short 8-byte append samples were noisy. For example, MSVC inline
measured 34.42 / 53.05 ms (1.541), with library samples ranging from 30.61 to
92.54 ms. The longer repeat above uses the same sources and sampling policy;
the noisy originals remain in the matrix JSON. Treat small differences cautiously.

Both implementations report **five data-stack regions** throughout the matrix.
This counts reservations, not committed bytes or native-stack usage. The library
adds 27,595–201,758 bytes of generated standalone C and 2,560–25,088 bytes of native
executable across the original matrix. Generic checked helper code has a code-size
cost even when runtime overhead is modest; programs with more element types may
instantiate more helpers.

## Implementation choices and remaining limits

The allocation entry point exposes the append path to Goose inlining without
instantiating relocation code. Allocation and free can therefore support
defaultable self-relative elements; resize still requires ordinary copying.
Checked slices let payload loops and maximum scans validate their range once.
Relocation appends the new tail in bulk and copies an overlapping existing prefix
in the appropriate direction. Declared defaults still execute once per newly
initialized element, in order.

Path positions need only -1 through 30. Using `i8[24]` for positions while keeping
full-width node indices reduces a path from 392 to 224 bytes, including its
initialization and copies. Metadata and payload accesses keep ordinary bounds
checks. Public `nodes`/`tree` fields are bookkeeping by convention: arbitrary edits
can break logical invariants, but the library does not trust them as unchecked
addresses. Field privacy is not required for these improvements.

General array operations `range_index` and `check_length` provide checked slice
containment and count validation without exposing raw pointers or duplicating
runtime reservation constants. They do not detect double frees or promise that
an allocation can acquire physical memory. `items.len` remains the high-water
length; freeing does not release storage and relocation does not retarget old
views. Defaults must not mutate or reenter the same pool.

The Windows baseline passed: 1,223 frontend checks, 580 native O0/O2 checks,
160 runtime-debug checks, 717 TinyCC runs, 1,901 expected type errors, compiler
root/cache checks, runnable reference examples and samples. An assertion-enabled
compiler also passed all ten positive slice-pool runs at O0/O2 with runtime debug
checks. Optional audio/gfx/physics/UI modules and Linux/macOS/sanitizer runs were
not exercised locally. O0 correctness is covered; this report measures O2 performance.

Global component paths for index/pool-relative types, destination-aware slot
construction and owner transfer to workers remain migration gaps. Worker-local
owners work. The [migration plan](../docs/design/root_structs.md#separate-follow-up-reusable-pools-in-the-stdlib)
keeps builtin removal separate from documentation deprecation.

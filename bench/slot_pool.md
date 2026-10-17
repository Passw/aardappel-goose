# slot_pool versus reusable

The initial `stdlib/slot_pool.goose` implementation uses the same LIFO free-index
policy as scalar `reusable`: allocation pops a free index or appends an initialized
element, and free records an in-range index without removing the element. This
experiment keeps `reusable` and the compiler unchanged. It does not compare slice
pools or alternative allocation policies.

## Reproducing the comparison

```text
python bench/slot_pool.py --exe build-root/Release/goose.exe --n 64000000 --grow-n 4194304 --reps 9 --warmups 3
```

The script discovers native C compilers through `scripts/toolchain.py`. Its
default output directory is `build/slot-pool-bench`; `--out` selects another.
It saves generated Goose and standalone C, compiler logs, stack reports, binary
sizes, all timing samples and `results.json`. Results include fingerprints of
the library and workload source. Filter the matrix with `--modes`, `--widths`,
`--levels` and `--calls`; the defaults exercise the complete matrix.

Both implementations are derived from `goose/slot_pool.goose`. The conversion
changes the owning declarations, parameter type and `items` projections; the
loops, values, allocation/free order and checksums stay the same. Two owners are
used, with three quarters of the work on one and one quarter on the other.

* **append:** allocate new slots through `alloc_ref`, retaining an early
  reference across growth and checking each returned slot's index.
* **lifo:** initialize 4,096 reusable slots per owner, then repeatedly free
  64 sequential slots and allocate 64 replacements. This exercises a nonempty
  freelist and its complete consumption.
* **scattered:** the same batches, using a pseudorandom starting slot and an odd
  stride over the power-of-two working set. Every batch frees 64 distinct slots;
  slot zero remains live throughout. This is a bounded working-set workload,
  not a claim to model arbitrary application allocation traces.

Each scenario uses 8-byte and 128-byte values, Goose O0 and O2, and two call
policies. **inline** marks the exercise function `inline fn`; at O0, where Goose
inlining is off, the generated C is marked `GS_INLINE`. **boundary** keeps the
exercise function as `GS_NOINLINE` in both implementations. The harness verifies
that this call boundary survives. Native C is optimized at level 2 in all cases;
the slot-pool API functions otherwise use the compilers' normal inlining rules.

There are three discarded warmups per binary, then nine measured runs with the
order of the two implementations alternating. Times are median whole-process
wall times: startup, pool initialization, allocation/free loops, checksum of all
payload words, output and teardown are included. Checksums must agree across
both implementations, both call policies, both Goose levels and every native
compiler. Bounds checks and assertions remain enabled.

## Windows x64 measurements, 2026-10-17

AMD Ryzen 9 9950X3D; MSVC 19.51.36260 and clang-cl 22.1.3, both using `/O2`.
The command above uses 4,194,304 append allocations or 64,000,000 reuse
allocations, split across the two owners. All 48 comparisons matched checksums.
[The complete results](slot_pool_results.json) retain every measured sample,
including the O0 cases, and the source fingerprints. The compiler's last source
commit is `45b01053`; this experiment changes no compiler or reusable code.

These are Goose **O2** results. Each time cell is **reusable / slot_pool**, in
milliseconds. The ratio is `slot_pool / reusable`; above 1 means the library
took longer.

| Workload | Item bytes | Calls | MSVC times | Ratio | clang times | Ratio |
|---|---:|---|---:|---:|---:|---:|
| append | 8 | inline | 21.66 / 22.14 | 1.022 | 20.80 / 21.05 | 1.012 |
| append | 8 | boundary | 24.63 / 25.34 | 1.029 | 23.06 / 23.07 | 1.001 |
| append | 128 | inline | 115.77 / 119.36 | 1.031 | 109.78 / 110.05 | 1.002 |
| append | 128 | boundary | 106.03 / 112.21 | 1.058 | 112.22 / 114.04 | 1.016 |
| lifo | 8 | inline | 75.87 / 85.21 | 1.123 | 65.38 / 69.59 | 1.064 |
| lifo | 8 | boundary | 80.65 / 95.36 | 1.182 | 69.57 / 94.58 | 1.360 |
| lifo | 128 | inline | 96.47 / 111.50 | 1.156 | 135.66 / 136.28 | 1.005 |
| lifo | 128 | boundary | 107.35 / 159.22 | 1.483 | 157.83 / 210.80 | 1.336 |
| scattered | 8 | inline | 81.81 / 88.15 | 1.077 | 75.27 / 75.84 | 1.008 |
| scattered | 8 | boundary | 86.75 / 95.68 | 1.103 | 77.26 / 96.17 | 1.245 |
| scattered | 128 | inline | 100.50 / 114.12 | 1.135 | 140.05 / 140.38 | 1.002 |
| scattered | 128 | boundary | 109.25 / 143.65 | 1.315 | 155.78 / 210.49 | 1.351 |

At O2, append is close in this whole-process measurement. Inline reuse ranges
from near parity to about 16% longer; the preserved-boundary reuse cases take
about 10–48% longer. O0 exposes larger differences, up to 2.70 times the builtin's
elapsed time in this matrix, even with native C optimization. These are workload
measurements, not a universal cost per allocation or a performance-parity claim.

Both implementations report **five data-stack regions**: two per owner and one
for rendering the checksum. This counts reservations, not peak committed memory
or native-stack usage. The library adds 2,553–8,559 bytes of generated standalone
C across the matrix. O2 executables are 512–2,048 bytes larger; sizes include
runtime code and diagnostics, not just the allocation loops.

Some runs have scheduler/startup outliers, particularly in the short 8-byte
append case. Treat single-digit percentage differences cautiously. An earlier
shorter run had substantial variance in several later cases; the table uses the
longer repeat with three warmups, and its full samples remain available above.
The results support retaining `reusable` while improving the library path.

## Findings from generated C

The library necessarily checks an index popped from its public `free_slots`
before accessing `items`. The builtin's freelist is hidden and populated only
by checked frees, so its allocation can use that index without another bounds
check. The corruption regression test confirms the library's check remains
effective even in optimized builds. Removing it without a proof would be unsafe.

The library `alloc_ref` also indexes the result of `alloc_index`; the builtin
already has the element address. Its generic value parameter may introduce
temporary element copies before native optimization. These differences are
visible in generated C, but the timings alone do not isolate their costs.

The standalone library allocator receives the existing component top/length
caches. In the preserved exercise boundary, however, inlined library calls
introduce owner-reference aliases and the generated loops still contain repeated
descriptor/header accesses and memory-top updates. Native optimization can remove
some of them. Better propagation of component identity through inlined aliases
is a concrete compiler follow-up to investigate; scalarizing the root ABI is
not a prerequisite for investigating it.

This comparison is an initial scalar-pool result. Destination-aware construction
for self-relative values, index types naming global components, worker snapshots
and slice pools remain separate work. The complete functional baseline also
tests reference-valued and non-defaultable elements, aliases, global and worker-local
owners, invalid frees, lifetime rejection, and deterministic differential traces
against `reusable`.

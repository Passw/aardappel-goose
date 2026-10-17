# slot_pool versus reusable

The `stdlib/slot_pool.goose` implementation uses the same LIFO free-index
policy as scalar `reusable`: allocation pops a free index or appends an initialized
element, and free records an in-range index without removing the element. This
experiment keeps `reusable` and the library implementation unchanged. The compiler
now forwards stable root-reference aliases so component top/length caches survive
inlined library calls. It does not compare slice pools or alternative allocation
policies.

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

`--reuse-api ref` replaces reuse allocations with `alloc_ref` followed by
`items.index_of` in both implementations. This tests reference-return allocation
under reuse as well as append. It is a separate workload, with the same slots,
values and expected checksums; the original matrix defaults to `--reuse-api index`.

## Windows x64 measurements, 2026-10-17

AMD Ryzen 9 9950X3D; MSVC 19.51.36260 and clang-cl 22.1.3, both using `/O2`.
The command above uses 4,194,304 append allocations or 64,000,000 reuse
allocations, split across the two owners. All 48 comparisons matched checksums.
[The complete results after alias forwarding](slot_pool_alias_results.json) retain
every measured sample, including O0, and the source fingerprints. The compiler's
last source commit is `6320e9fc`. [The original measurements](slot_pool_results.json)
used compiler source `45b01053`; both runs use the same library and workload.

These are Goose **O2** results. Each time cell is **reusable / slot_pool**, in
milliseconds. The ratio is `slot_pool / reusable`; above 1 means the library
took longer.

| Workload | Item bytes | Calls | MSVC times | Ratio | clang times | Ratio |
|---|---:|---|---:|---:|---:|---:|
| append | 8 | inline | 22.84 / 23.59 | 1.033 | 20.26 / 20.53 | 1.013 |
| append | 8 | boundary | 22.13 / 20.37 | 0.921 | 23.88 / 21.56 | 0.903 |
| append | 128 | inline | 117.49 / 116.01 | 0.987 | 110.09 / 112.24 | 1.020 |
| append | 128 | boundary | 106.63 / 114.32 | 1.072 | 112.75 / 111.01 | 0.985 |
| lifo | 8 | inline | 74.27 / 80.29 | 1.081 | 65.08 / 58.88 | 0.905 |
| lifo | 8 | boundary | 79.49 / 70.98 | 0.893 | 69.07 / 59.80 | 0.866 |
| lifo | 128 | inline | 96.08 / 99.71 | 1.038 | 133.22 / 116.74 | 0.876 |
| lifo | 128 | boundary | 104.98 / 105.45 | 1.005 | 154.72 / 133.24 | 0.861 |
| scattered | 8 | inline | 80.56 / 86.29 | 1.071 | 74.15 / 65.03 | 0.877 |
| scattered | 8 | boundary | 85.23 / 76.20 | 0.894 | 73.35 / 64.34 | 0.877 |
| scattered | 128 | inline | 98.19 / 103.69 | 1.056 | 137.76 / 125.03 | 0.908 |
| scattered | 128 | boundary | 107.97 / 107.36 | 0.994 | 152.38 / 135.82 | 0.891 |

The large O2 call-boundary reuse gap is gone in this matrix. Previously these
cases took about 10–48% longer; now they range from about 14% faster to 0.5%
slower. MSVC's inline reuse cases still take about 4–8% longer, while clang's are
about 9–12% faster. Append remains close, with a 7% regression in the MSVC
128-byte boundary case. Small residual differences are acceptable for this
experiment; allocation-only loops amplify costs that may be minor in application
code. These results do not establish a universal cost per allocation.

Goose **O0** still has substantial gaps, up to 2.68 times the builtin's elapsed
time, even with native C optimization. Alias forwarding benefits the library
helpers once Goose inlines them into the hot loop; it does not force that
inlining at O0. This remains a limitation for unoptimized Goose builds.

Both implementations report **five data-stack regions**: two per owner and one
for rendering the checksum. This counts reservations, not peak committed memory
or native-stack usage. The library adds 2,553–8,040 bytes of generated standalone
C across the matrix. O2 executables are 512–2,048 bytes larger; sizes include
runtime code and diagnostics, not just the allocation loops.

Some runs have scheduler/startup outliers, particularly in the short 8-byte
append case. Treat single-digit percentage differences cautiously. An earlier
shorter run had substantial variance in several later cases; the table uses the
longer repeat with three warmups, and its full samples remain available above.
The results support retaining `reusable` while evaluating wider library use.

## Reference-return reuse

The additional O2 matrix uses the same compiler, machine, workload sizes and
sampling policy, with `--modes lifo scattered --levels 2 --reuse-api ref`.
[All 16 comparisons](slot_pool_ref_results.json) matched the original workload's
checksums. Ratios below are again `slot_pool / reusable`.

| Workload | Item bytes | Calls | MSVC ratio | clang ratio |
|---|---:|---|---:|---:|
| lifo | 8 | inline | 0.942 | 0.864 |
| lifo | 8 | boundary | 0.759 | 0.763 |
| lifo | 128 | inline | 1.051 | 0.878 |
| lifo | 128 | boundary | 0.929 | 0.847 |
| scattered | 8 | inline | 0.934 | 0.856 |
| scattered | 8 | boundary | 0.787 | 0.752 |
| scattered | 128 | inline | 1.018 | 0.913 |
| scattered | 128 | boundary | 0.947 | 0.876 |

There is no large optimized gap in this matrix either. The library's existing
`alloc_ref` implementation is retained rather than adding a separate allocation
path to chase the remaining small differences.

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

Previously, inlined library calls introduced owner-reference aliases and disabled
the preserved caller's component caches. Alias forwarding now gives those stable
references one spelling. Generated reuse loops load their component tops and
lengths before the loop and flush them afterward; real calls flush and reload
the caches they can reach. Mutable references, references read from storage,
potentially aliasing parameters and globals retain the conservative fallback.
The root ABI is unchanged, and no singleton-owner assumption is made.

Making `free_slots` private could protect the API invariant from callers, but
privacy alone would not prove that every stored index is in range: module code
could still insert a bad one. Eliminating the bounds check requires a compiler
proof or a separately justified trusted implementation. The measured improvement
needs neither change, and the public-freelist corruption tests still abort.

This comparison is an initial scalar-pool result. Destination-aware construction
for self-relative values, index types naming global components, worker snapshots
and slice pools remain separate work. The complete functional baseline also
tests reference-valued and non-defaultable elements, aliases, global and worker-local
owners, invalid frees, lifetime rejection, and deterministic differential traces
against `reusable`.

## Validation of alias forwarding

The complete Windows baseline passed: 1,193 frontend checks, 565 native O0/O2
program checks, 146 runtime-debug checks, 689 JIT runs and 1,894 expected type
errors, plus root-domain and generated-C checks. The new root-alias regression
covers alias chains, two owner arguments and an array argument naming the same
storage, globals, sampling mutable receivers, and flushing/reloading caches at
a real call. Its C-shape assertion checks that inlined helpers preserve an
out-of-line caller's component caches. The assertion-enabled compiler also
generated all 31 positive root/slot-pool fixtures at O0 and O2.

Optional audio/gfx/physics/UI modules were not built; native worker tests ran,
but TinyCC does not support them. Linux/macOS and sanitizer CI were not run here.

# Root structs: library state with independent storage

Status: root structs v1, stdlib `slot_pool` and stdlib `slice_pool` are implemented.
**`reusable` and `reusable[]` are deprecated** in favor of
[`slot_pool<T>`](../stdlib.md#slot_pool) and [`slice_pool<T>`](../stdlib.md#slice_pool).
The builtins remain available; removal waits for the remaining migration work.
Parsing, declaration validation and independent local/global components work,
including field references passed to ordinary functions, per-component shrink checks,
serialization and stack restoration. Direct field accesses retain the existing
stack-top caching and immutable array-reference aliases. Each component has a
synthetic variable identity sharing its owner's lifetime; ordinary packed fields
inside a component continue to share that component's region.
The backend currently materializes a private descriptor pointing at component
storage; direct projections resolve to the underlying local/global locations.
Whole-owner references use a pointer to this descriptor. Parameter classes keep
component paths in return and mutation summaries, including when a separate
argument names the same component. Local aliases, stored/optional references,
returned references and captures work. Immutable owner parameters with distinct,
exact storage cache component tops and lengths; descriptor accesses share memory
tops where aliases prevent independent caches. Existing loop-view hoisting also
handles root fields.

Workers may construct local roots, but cannot reach a root global through direct
access or calls. Unused root globals do not prevent worker compilation.

Reference-containing fields retain per-component store records, including
writes through calls and reads through aliases of the whole owner. Default
formatting, custom format hooks and compile-time field reflection inspect owners
by reference. Borrowed owner links may form cycles without owning nesting.
Root literals must be immediate declaration initializers;
`State { .. }` supplies field defaults. Root padding is rejected because the owner
has no packed layout; put padding in an ordinary component struct instead.

The following records the v1 contract and the separately identified follow-ups.
The library pools have differential tests and native benchmarks. Existing
reusable syntax and runtime behavior remain unchanged during deprecation.

## Motivation

A library should be able to package its state in one type, initialized by one
declaration. Today a struct may contain only one resizable value, on its tail.
A library needing two independently growing arrays must ask its user to declare
both arrays and assemble a borrowed context. This makes library state awkward
to instantiate and expose, even when its complete storage requirements are
known statically.

Root structs group independently stored values under one owning lifetime. They
do not put several growing arrays into one contiguous byte image, relocate
fields on growth, or introduce a heap allocator. Every simultaneously live
resizable component is still on top of its own data stack.

```goose
root struct ParserState {
    tokens: Token[>..] = [],
    work: i64[>..<] = [],
    position: i64 = 0
}

var parser = ParserState { .. };
parse(parser, input);

fn parse(state: ParserState&, input: u8[:]) {
    // Ordinary field access and UFCS, with independent array storage.
}
```

The illustration assumes a separately declared `Token` type. Root structs are
useful for parser state, parallel arrays, lookup structures with separate
metadata, and pools. They remain worthwhile if reusable pools stay built in.

## Syntax and explicit contract

Use `root struct`, retaining struct fields, type arguments, defaults, namespaces,
and function-based methods. Store the distinction on the existing struct
declaration/instantiation rather than creating a separate family of field-access
AST nodes.

Treat `root` as a contextual modifier immediately before `struct` at a type
declaration. Existing variables, fields, parameters, and functions named `root`
remain legal. Do not reserve the word throughout the language merely to parse
this modifier.

The modifier means that owning instances are storage roots. It does not mean
that the declaration or instance must be at file scope. An explicitly declared
root struct keeps its restrictions even when it has zero or one resizable
field, including in generic specializations. Ordinary structs keep their
current placement and layout rules. Adding a second resizable field to an
ordinary struct remains an error, and the error suggests `root struct`.

If the root modifier were inferred instead, editing a field or specializing a
generic would change a type's placement, copying, and representation contract.
A keyword that replaced `struct` would obscure how much of the existing struct
behavior remains. The name `local` would misdescribe globals, and `stack`
would distinguish little in Goose.

For comparison, Rust infers the restrictions on a dynamically sized struct from
an unsized last field, and such a struct still describes one object. C#
explicitly marks its restricted `ref struct` category. Neither has the same
rules as this proposal.
References: [Rust dynamically sized types](https://doc.rust-lang.org/reference/dynamically-sized-types.html),
[C# ref structs](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/ref-struct).

## V1 ownership and placement

| Use | V1 rule |
|---|---|
| Local or global `var`/`let` | Allowed; construct directly at its declaration using a literal and field defaults. |
| Fields | Ordinary fields and multiple independently stored resizable fields, in any order. Their own existing element, construction, and lifetime restrictions still apply. |
| Root owner inside another struct | Forbidden by value, including inside another root struct. |
| Root owner as an array/slice element or ADT payload | Forbidden, including fixed-length arrays. |
| Reference to an owner | Allowed, including optional references and references stored in fields/arrays when ordinary lifetime rules permit. |
| Function argument | By reference. Untyped parameters bind owning lvalues by reference as for nonfixed values. |
| Function result | References to existing owners may be returned under normal lifetime rules; owning results are deferred. Never return a reference to a local owner. |
| Unannotated binding from an existing owner | Binds by reference, consistent with nonfixed lvalues. Explicit `.=` remains available. |
| `copy`, whole-owner assignment, by-value parameters | Forbidden. No implicit descriptor copying or ownership transfer. |
| Temporary owners | Forbidden; owning construction requires a named local/global declaration. |
| Field assignment and array operations | Use the field's usual rules, including shrink and construction checks. |
| Whole-owner raw serialization or C ABI | Unsupported; explicitly supported component operations remain available. |
| Transfer into a worker | Unsupported, including implicit capture of a root global. See the threading rules below. |

The prohibition on ownership nesting does not prohibit ordinary fields whose
types are existing resizable-tailed structs. Such a field is an independently
stored component with its existing internal layout. A root struct itself is
never such a by-value component in v1. Variable-size ordinary fields likewise
retain their construction rules; the enclosing root has no contiguous image.

```goose
struct Context { parser: ParserState& }   // Borrowing is allowed.
struct Object { parser: ParserState }     // Owning containment is an error.
```

Diagnose the prohibited use with the declaration and field/element/argument
path, and suggest a reference or a local/global owner. For example:

```text
ParserState is a root struct and cannot be stored by value in Object.parser.
Declare it as a local/global variable, or store ParserState&.
```

Enforce the rules through aliases, generic instantiation, inferred types,
defaults, inferred results, and unreachable/standalone checking as applicable.
An apparently fixed-size control record must never escape the owning rules.
`const` and writability follow existing struct and reference rules, including
their existing treatment of reference-valued fields; add no blanket transitive
immutability rule.

## Storage and construction

An instance has a stable control record for ordinary fields and component
metadata. Each resizable component has its own stable element region, length
header, and access to its data stack. Use existing representations for ordinary
components where possible. The control record is an implementation detail, not
a fixed-size Goose value that can be copied or serialized.

The number of component stacks is statically determined by the instantiated
type and owning declarations. Lifetime-disjoint owners can reuse stack indices
as existing locals do. Globals use dedicated component storage. Restore all
owned stack watermarks on scope exit, including `break`, `continue`, ordinary
returns, and `return from`. Partial construction must also restore acquired
storage without publishing an incomplete owner.

Evaluate field initializers once, in declaration order. Preserve checks against
observing under-construction storage. A completed owner can subsequently be
initialized further by functions taking its reference. Do not introduce
destructors, automatic resource cleanup, runtime owner counts, or moves.

A root owner holding data stacks is subject to the existing recursive-cycle
restrictions even though its metadata has constant size. It cannot be live
across a recursive-cycle call that would require another set of stacks for each
activation. Passing an owner declared outside the cycle by reference remains
the intended pattern. Capturing such a reference in a nested function or a
compile-time function value follows existing capture and escape rules.

## Component identity and lifetime analysis

An enclosing variable's lifetime is not sufficient to identify its storage.
Represent independently stored components with identities equivalent to an
owning declaration plus a field path:

```text
(state, .tokens)
(state, .work)
```

These share an enclosing lifetime but are different regions. Preserve this
distinction through field projection, direct and optional owner references,
branches, rebinding, calls, returned references, globals, captures, and stored
references. An unknown reference carries a conservative set of possible
regions; never promote a lifetime bound to an exact component identity.

Implementation: a synthetic variable represents each component. Class roots
can carry the same projection without claiming a concrete owner. A separate
`projected` proof records that a view stays inside that field's region, allowing
the checker to exclude sibling fields even after an owner reference was loaded
from a holder. Ordinary references read out of the field lose this proof;
self-relative links retain it. Joins intersect the proof, weakening drops it,
and return/effect summaries preserve it. This is distinct from exact identity,
which operations such as `index_of` still require.

In particular:

* Growing one field does not interfere with construction in another field.
* Shrinking one field does not invalidate references into another field,
  including when their element types are identical.
* Shrinking a field still rejects any live view or holder that can refer into
  that field, across calls and reference aliases.
* `index_of` must establish the particular array, not merely the owner. Two
  arrays of the same element type in one root remain distinguishable.
* Whole-array references name their headers; element references name the
  element region. A shrink must preserve the existing distinction.
* Self-relative links remain within their permitted contiguous region. A
  common enclosing owner does not permit links between separate stacks or from
  its control record into an array. Use ordinary references for those links.
* Read-back, holder/store records, effect summaries, construction conflicts,
  and recursive specialization must propagate component identities consistently.

Relevant code includes `RootAlt`/`Roots` in `src/ast.h`,
`RootedAtReceiver`/`OneArrayOf` in `src/typecheck_types.h`, and
`SoleResizableIn`, growth logs and shrink summaries in
`src/typecheck_builtins.h`. Root-set joins merge entries by variable identity,
with separate synthetic identities for independent components; domain tests
cover the additional proof's join/equality laws. Existing packed structs still
share one region: a field path is not automatically a new region everywhere.

During investigation, small typecheck probes against the available compiler
showed that a scalar allocator with separate data and freelist arguments accepts
a retained reference across reuse. When those arguments were grouped in a
struct of references instead, the checker conservatively assumed that the
result could point into the freelist and rejected the next allocation. This is
evidence of a current precision limit, not a test of root structs. Include this
pattern, and two same-typed owned arrays, in the implementation's acceptance
cases.

## Code generation and performance

Array access must remain efficient. Grouping arrays in a root struct must not
disable existing array optimizations or add an unexplained load on every
iteration of a hot loop.

The current backend already has relevant machinery:

* `ParamFields` in `src/codegen_frames.h` passes slices, fat references and pool
  references as separate C parameters. This avoids platform ABI costs and
  alias-related reloads of aggregate argument copies.
* Stack tops are cached in C locals, with synchronization around calls and exits
  (`RefTopsOk`, `HandedStacks`, `SyncReach`, `Top`/`TopW`).
* BCE's `hoistrefs` and `hoistfields` let codegen cache array bases and lengths
  when a loop cannot invalidate or rebind them.
* Existing frame objects keep fixed prefixes and a resizable tail's header
  outside the element region.

A stable control-record reference is a reasonable v1 representation, but field
projections must expose their normal header/stack information to those passes.
Track every stack a root argument or captured root can reach. Flush and reload
cached metadata when a call may mutate it, without assuming two parameters are
distinct owners. Rebinding, globals, callbacks and nonlocal returns require the
same care as existing references. Preserve observable left-to-right sampling.

Inspect generated C as well as timings. Compare direct array arguments, an
ordinary one-tail struct, a root with two arrays, a borrowed context, and the
existing reusable pool. Cover reads, growth, freelist churn, same-typed fields,
out-of-line calls, aliasing parameters, callbacks, and branches selecting owners.
Check that base/length reads are hoisted where valid and that unrelated component
mutations do not force unnecessary reloads or lose bounds-check elimination.
Exercise O0/O2 and TinyCC/native C; include Windows x64 and other CI targets for
ABI-sensitive changes. Record reservation count and code size as well as runtime.

Do not promise zero overhead based only on an inlined benchmark. Keep existing
`reusable` until a migration has demonstrated acceptable behavior and performance.
For initial root support, report material regressions explicitly and fix basic
integration with existing optimizations before calling the feature complete.

Two more ambitious optimizations are deferred:

1. **Known-owner specialization.** Where whole-program provenance proves exactly
   one possible instance, compile access directly to that instance's fields.
   A unique type is not proof of a unique live instance: repeated declarations,
   recursion, worker instances, aliases and reentrancy must be considered.
2. **Field-by-field lowering.** Treat an owner as component locals and pass the
   required headers, stack handles and field addresses as separate arguments.
   This may recover today's pool calling convention. Preserve writes and owner
   identity; scalar copies of mutable fields are not a substitute for shared
   locations. Materialize a descriptor when addressability or reference storage
   requires one. Measure register pressure, argument count and code growth.

Keep the v1 language contract independent of either ABI strategy so that these
can be introduced without changing user code.

### Initial native measurement

`python bench/root_structs.py --exe <goose.exe> --n 32000000 --reps 9`
compares `push_ref.goose` with `push_root.goose`: the same RNG, item writes,
retained references, checksums, and two owner instances. The harness marks both
C `fill` helpers `GS_NOINLINE`, preserving the call boundary at Goose O0 and O2
while compiling the C with native optimization. It saves timings, generated C,
executable sizes, and stack reports. Times include process startup.

Windows x64, 2026-10-16, median of nine runs after one warmup:

| Native compiler | Goose level | Separate array arguments | Root argument |
|---|---|---:|---:|
| MSVC 19.51 | O0 | 88.14 ms | 88.88 ms |
| clang-cl 22.1 | O0 | 85.57 ms | 85.64 ms |
| MSVC 19.51 | O2 | 86.78 ms | 87.18 ms |
| clang-cl 22.1 | O2 | 86.48 ms | 85.37 ms |

Both use five data-stack regions (including rendering) and produce identical
checksums and executable sizes per compiler: 148,480 bytes with MSVC and 155,648
with clang-cl. The root version adds 536 bytes of generated standalone C. This
probe shows no material regression for this workload; it is not a claim about
all containers or platforms. Freelist-policy comparisons remain part of the
separate reusable migration experiment.

`root_owner_caches.goose` and the baseline runner also check generated C: top
and length caches for both independent fields, base/length hoisting for indexed
reads, and runtime correctness when owner/owner, owner/array, or owner/global
arguments alias. Such aliases intentionally keep the shared memory top.

## Serialization, workers, and other boundaries

V1 has no root-level `to_bytes`, `bytes_of`, `from_bytes`, raw equality/copying,
or public foreign value layout. A root owner has no single contiguous image,
even when every component is individually flat. Do not accidentally accept it
through existing flatness or fixed-size predicates.

Serializing or viewing an eligible component, such as `pool.items`, remains an
ordinary operation under the existing image-safety and lifetime rules. Such an
image contains the items, not the root's other fields or freelist. Loading it
into an existing component obeys ordinary assignment/shrink rules. Libraries
that need a coordinated snapshot can define an explicit data format later.

There are existing reusable-to-worker cases:
`test/threads/thread_globals.goose` copies both a reusable slot pool and a
reusable slice pool from the spawning instance, preserving freelist state, and
tests a worker spawning another worker. Current codegen explicitly copies the
freelist beside the data. Preserve that behavior for existing `reusable`.

Root v1 rejects passing an owning root to `thread_spawn` or a queue, and
sending a reference to an owning root. It also rejects any direct or
transitive use of a root global by a worker, since that use would require
implicitly copying the owner. Diagnose the reachable global/call path. A root
local constructed within a worker needs no transfer and is allowed. An
unrelated root global unused by the worker must not reject the program.
Existing rules still govern passing eligible components as copied data; never
transfer descriptor pointers or infer transferability from flat contents.

Worker snapshot support can follow later by reconstructing independent storage
for every component, copying the relevant metadata, and handling only reference
forms for which transfer is already legal. This is an explicit compatibility
gap to resolve before claiming that stdlib pools replace every reusable use.

Formatting and reflection must distinguish inspecting a reference from copying
or serializing its owner. Retain field access and UFCS; support inspection by
reference where it does not request a forbidden value operation. Do not add
array operator overloading merely to disguise a container's `items` field.

## Separate follow-up: reusable pools in the stdlib

`import slot_pool;` now provides the initial copyable-element slot allocator:

```goose
root struct slot_pool<T> {
    items: T[>..] = [],
    free_slots: i64[>..<] = []
}

var pool = slot_pool<i64> { .. };
let r .= pool.alloc_ref(42);
pool.free(pool.items.index_of(r));
```

The implementation uses the same LIFO free-index policy as scalar `reusable`,
with allocation, reference-returning allocation and checked free. Tests compare
allocation traces, retained references and slot contents against the builtin.
The [API reference](../stdlib.md#slot_pool) describes the supported element types
and current boundaries; the [benchmark report](../../bench/slot_pool.md) compares
equivalent native workloads. The compiler and existing reusable implementation
are unchanged by this experiment.

`stdlib/slice_pool.goose` packages its `items`, node array and tree state in one
root owner. It implements the same augmented B+ tree as the builtin: first-fit
placement, coalescing, tail reuse and overlap-safe relocation. Differential tests
compare positions, retained views and every backing element under allocation,
free and resize traces. See its [API](../stdlib.md#slice_pool) and
[benchmark report](../../bench/slice_pool.md). Both pool types require fixed-size
elements; not every builtin use can migrate yet.

Preserve the existing safety contract: all published elements remain valid
typed values, a free merely marks storage reusable, and a stale reference may
observe a replacement value. Double frees are logical errors unless a library
adds detection. Freeing does not promise decommit, reservation release, or
destruction. Slice relocation does not retarget existing views; fragmentation,
high-water storage and copying costs remain.

Expose `items` explicitly for indexing, slicing and ordinary array algorithms.
Its length is the high-water length, not a live-slot count. Live-only iteration
requires additional metadata or work. Coordinated reset must update both data
and metadata and satisfy the data array's normal shrink rules. Goose currently
lacks field privacy: internal-field conventions and checked indexing preserve
memory safety, but arbitrary user edits may violate pool invariants. Privacy is
a separate possible improvement, not a prerequisite for root structs.

The migration requires the following capabilities; completed ones are noted:

### Global component paths

Implemented for mutable direct array fields of global `var` root owners:
`Node&<u32 in nodes.items>`, `u32 in nodes.items`, and `u32 upto nodes.items`.
Owner names may be namespace qualified. The target must be a grow-only array;
aliases, reference crossings, indices and nested field paths are rejected.
`in nodes` still means exactly that global, with no implicit `.items` selection.

The component identity is reserved before types are instantiated, so recursive
declarations such as `Node` linking into `slot_pool<Node>.items` keep the same
identity throughout checking. The owner's field resolves to that existing
component when its type becomes known. Owner-reference specializations retain
named component identity through helper calls. Width checks, exact-root rules,
index/bound type identity and the index array's no-shrink rule remain in force.
Bounds analysis identifies a named component with the corresponding field
expression; codegen uses its existing global header and cached base directly.

Types can use array bases and lengths without an identifier expression. These
dependencies participate in call-cache synchronization and worker checks. An
implicit dependency on a root component is rejected in workers, just like an
explicit use of its owner. Image verification flushes cached counts before
checking serialized indices against global array lengths.

Validation includes namespace/alias round-trips, cyclic node/pool declarations,
global field initializers, owner-reference forwarding, compact-width overflow,
index bounds and image validation, cross-field/owner rejections, no-shrink
checks through owner and array parameters, and implicit worker dependencies.
The full native baseline passes at O0/O2 with TinyCC and runtime-debug coverage;
24 focused fixtures also pass with compiler assertions enabled. Optional native
modules and sanitizer configurations were not run for this extension.

### Destination-aware library construction

`EmitAlloc` currently selects a slot first, and then constructs literals that
contain relative references in that slot. An ordinary `value: T` parameter has
already received its value elsewhere. Probes confirmed that a self-relative
node linking to an existing node typechecks with built-in `alloc_ref`, but
fails when passed through an ordinary value parameter or through a current
trailing builder block.

Keep `alloc_ref(value)` for normally copyable values and investigate a builder
API such as `pool.alloc_with() { Node { value: 2, next: first } }`. Extend the
existing construction-destination machinery so a function-value initializer can
construct directly into the selected existing slot or append destination.
The existing trailing block mechanism alone does not supply this capability.

The library's slot-selection algorithm can be ordinary code: assign `F()` into
a recycled slot or `push(F())` for a new one. This requires general result
construction support before adding the pool API; `map` and other higher-order
functions must benefit from the same rules.

The construction audit distinguishes three independent mechanisms:

* Checking follows the call graph: caller, higher-order function, then the
  block when its `F(...)` call is reached. `CheckCall` clears the enclosing
  construction destination to keep arguments separate from the result.
  `CheckFunValCall` checks the block's tail without an expected type, and the
  receiving destination is not restored for it. Named-function bodies also
  start without the caller's result destination. The order is correct; result
  destination information does not flow through these boundaries.
* `TempCopy` gives an expression temporary lifetime/provenance and removes its
  identity as bindable storage. It is checker bookkeeping, not an instruction
  to materialize and copy bytes. `BuiltWhereReceived` separately recognizes
  named-call results as fresh construction, but does not recognize a trailing
  block call, so even a self-contained literal with a `self` link is rejected.
* The specified in-place guarantee applies to nonfixed values (§4.3).
  `EmitFvCall` already builds a nonfixed struct directly on a supplied stack
  destination. Fixed structs use C value temporaries when the destination is
  not an lvalue; ordinary fixed elements of `push` are evaluated before the
  slot is selected. A fixed literal holding relative references takes a
  different, in-place path. Extending that path through calls requires both
  checking and codegen support, independently of C optimizer copy elimination.

Focused probes at Goose O0 and O2, with runtime debug checks for accepted cases,
give the following results. Generated C was inspected for construction paths.

| `map` initializer | Current behavior |
|---|---|
| Trailing block returning `Pair { a: it, b: it * 2 }`, both fields `i64` | Accepted; C struct temporaries followed by the element store. |
| Trailing block returning `Row { id: it, text: str("item", it) }`, with `text: u8[]` | Accepted; the fields and text are built directly in the receiving array. |
| Trailing block returning a fixed or variable-size struct with a self-relative `me: self` field | Rejected as an unsupported self-relative copy. |
| Named function returning the equivalent self-linked struct | Accepted; fixed results use C values (internal offsets survive moving the whole value), variable-size results build directly at the receiver. |
| Trailing block returning a struct with a resizable array field | Rejected by the existing prohibition on resizable array elements, before codegen. |

A direct `items.push(Node { next: first, ... })` also succeeds where `first`
names an existing element of `items`; the equivalent builder block and an
ordinary named function returning that literal both fail the same-root check.
This is distinct from the self-contained `self` case above: a link to an
existing element needs the final destination's array identity.

The implementation sequence is to make fresh block results participate in
general construction checking, then carry result destination provenance
separately from argument destinations through calls and forwarding. Preserve
that destination in assignment and push lowering, including a destination
return channel for fixed aggregates whose links depend on their final location.
Named-call specialization must distinguish or constrain result destinations
where their relationship to arguments affects validity. An unconditional
removal of destination resets or of self-relative copy checks is insufficient:
returning existing storage must retain the existing copy restrictions. Once
these general cases work, implement `alloc_with` using ordinary library code.

Preserve `self`, root checks, evaluation once and in order, construction conflict
checking, lexical/nonlocal returns, and publication of a fresh slot only once it
contains a valid value. Do not expose uninitialized slots or silently require
every slot element to have a default. Use
`test/storage/alloc_half_built.goose` as a compatibility baseline, including
initializer side effects on the freelist. This is a general construction feature,
not a new pool-specific privilege.

### Checked slice position

Builtin `free_slice`/`realloc_slice` can check alignment and complete containment
at runtime when provenance cannot prove their input slice belongs to the pool.
`index_of` currently requires stronger static provenance. Expose a general
checked slice-to-array position operation, now implemented as `range_index`:
elide checks when proven, otherwise check alignment and the full range at runtime.
Every empty slice, including a foreign or default slice, returns zero. Nonempty
foreign storage aborts. No library pointer arithmetic or unchecked index
fabrication is needed.

Preserve all-build checks for invalid frees, negative/overflowing allocation
lengths and element bounds, with validation before metadata changes where the
current contract requires it. Slice allocations initialize every added element;
relocating slices retain the restriction on self-relative element types. Expose
any needed length validation as a general array capability rather than copying
runtime constants into the library. This is implemented as `check_length`, which
validates a proposed total element count without changing storage or promising
that a later allocation will succeed. `slice_pool` validates requested counts and
input slices before changing tree metadata. Allocation and free support
defaultable self-relative elements; resize still requires copying, as it does
for the builtin.

### Policy and compatibility

Library variants may add occupancy checks, generations, different span policies,
or logical freelist counts over grow-only metadata arrays. Generational handles
are an optional API and cannot protect escaped raw references. See
[slotmap's versioned keys](https://docs.rs/slotmap/latest/slotmap/) for a useful
comparison, not a replacement for Goose's existing reuse semantics.

Deprecate `reusable` and `reusable[]` in documentation and recommend the library
types for new code. Keep the syntax, diagnostics and runtime behavior available
for existing code. Removal is a later change, after destination-aware slot
construction and worker transfer have a reviewed migration path. Global
component index/relative types and worker-local library pools already work. Continue
measuring application workloads as well as allocation-heavy microbenchmarks;
small regressions alone do not require retaining a language-level allocator.

## V2 candidates

* **Nested root owners.** Permit a root field inside another root, recursively
  flattening its finite region requirements. Define initialization, projection,
  lifetime identities and diagnostics before relaxing placement. Ordinary
  packed structs still cannot silently acquire this layout.
* **Small constant arrays of root owners.** Explore `slot_pool<T>[N]` for a
  compile-time constant N. The stack requirement is statically multiplied by N;
  runtime indexing selects an owner descriptor/region set. Define permitted
  enclosing positions, whole-array references, dynamic-index alias joins,
  initialization, iteration, N=0, and practical reservation limits. This does
  not imply resizable or runtime-length arrays of owners. Do not choose an
  arbitrary small-N language limit before evaluating costs.
* **Known-owner specialization and field-by-field call lowering.** As above;
  preserve addressability and alias semantics while minimizing indirections.
* **Owning factory results.** Construct directly into several caller-provided
  destinations, without copying a descriptor and presenting it as a move.
  General copying, reassignment and moving need separate semantics.
* **Worker snapshots and coordinated serialization.** Reconstruct independent
  components with an explicit format/lifecycle contract; never memcpy an owner.

## Implementation sequence and acceptance

1. **Frontend foundation.** Parse and round-trip the contextual modifier; carry
   it on struct metadata through generic instantiation and AST cloning. Add
   syntax coverage and precise errors. During incremental development, reject
   semantic uses explicitly until their storage support exists: do not allow a
   root to fall through ordinary fixed/resizable codegen.
2. **Placement, storage classification and provenance.** Introduce an explicit
   owning-layout distinction rather than treating the fixed metadata as a fixed
   Goose value. Audit size/flatness/copy/containment queries. Implement component
   identities and their join, specialization and effect-summary behavior.
3. **Ownership and codegen.** Allocate and restore all component stacks; support
   literals/defaults, locals/globals, references, field projection, aliases,
   captures and calls. Integrate top caches, call reachability and view hoisting.
   Reject unsupported transfers, copies, nested owners and temporaries before
   codegen. Update spec, reference, implementation notes and editor support when
   the feature is usable, without advertising scaffolding as working support.
4. **Library-state acceptance.** Demonstrate one-declaration multi-array state
   used by generic functions, with references retained across unrelated field
   operations. Test actual runtime behavior and generated code, not just parsing.
   This milestone does not depend on a reusable replacement.
5. **Pool migration experiment.** Port copyable-element slot allocation, compare
   code and timings, then address the separate construction/path/slice features
   above and evaluate slice pools and existing worker behavior.

Required focused tests include:

* independent same-typed fields;
* shrink rejection for the correct component and acceptance for unrelated
  components;
* stored, optional, returned and branch-selected owner references;
* const/writability;
* generic placement failures;
* recursion and nonlocal exits;
* partial initialization;
* component serialization;
* forbidden root serialization/FFI/thread use;
* allowed worker-local owners;
* transitive worker-global rejection.

Exercise aliases that refer to the same owner as well as distinct owners.

Run the appropriate focused tests during each implementation slice, then the
repository's baseline compiler/runtime suite for the complete feature. Extend
`test/compiler_roots.cpp` when changing root-set laws. Keep performance probes
repeatable and compare equivalent algorithms; do not conflate a different
freelist policy with root-reference overhead.

### V1 validation record

The Windows x64 baseline passed on 2026-10-16 with MSVC and TinyCC, including
1,175 parse/round-trip/typecheck checks, 556 native O0/O2 program checks, 138
runtime-debug checks, 673 JIT runs, the compiler root-domain tests, generated-C
cache/hoisting assertions, and the runnable reference examples. The focused
assertion-enabled compiler pass also accepted/rejected all 65 root-specific
fixtures as expected, including optimized code generation for positive cases.
The baseline includes native worker-local ownership and transitive worker-global
rejection; TinyCC does not run worker programs. Optional audio/gfx/physics/UI
modules were not built. Linux/macOS and sanitizer CI were not run locally.

The native performance results above cover a preserved call boundary and the
existing array caches. They do not establish a performance guarantee for every
aliasing pattern or a migration result for reusable pools. Implementation steps
1–4 are complete. Step 5 now has both pool implementations, differential tests
and repeatable benchmarks. Checked slice positions and length validation are
implemented, as are global component paths. Destination-aware slot construction
and worker transfer remain, alongside the explicit v2 candidates.

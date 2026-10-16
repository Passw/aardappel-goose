// parse-only: root structs round-trip while semantic support is developed.
namespace root_syntax;

root struct State<T> {
    items: T[>..] = [],
    free: i64[>..<] = [],
    root: i64 = 0
}

// Zero and one resizable fields retain the explicit declaration contract.
root struct Counter { root: i64 = 1 }
root struct Buffer { bytes: u8[>..] = [] }

root struct qualified_root::State<T> {
    values: T[>..],
    offsets: i64[>..]
}

root struct ::GlobalRoot { root: i64 }

type StateRef = State<i64>&;
struct Borrowed { state: StateRef }
var state = State<i64> { .. };

fn root(root: StateRef) -> i64 { root.root }

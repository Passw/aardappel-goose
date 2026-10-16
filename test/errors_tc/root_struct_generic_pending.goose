// error: root struct State is not supported yet: independent component storage and lifetime checking are not implemented
// Generic declarations need the same gate even when never instantiated.
root struct State<T> { first: T[>..], second: T[>..] }
fn main() {}

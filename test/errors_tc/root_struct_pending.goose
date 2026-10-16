// error: root struct State is not supported yet: independent component storage and lifetime checking are not implemented
// An unused root declaration must not silently become an ordinary struct.
root struct State { count: i64 }
fn main() {}

// error: root owner references are not implemented yet
root struct S { a: i64[>..] }
fn main() { var s = S { .. }; let r = s; }

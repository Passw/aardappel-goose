// error: root fields containing references are not implemented yet
root struct S { a: i64& }
fn main() { var n = 1; var s = S { n }; }

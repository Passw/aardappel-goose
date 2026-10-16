// error: root field projection through a parameter, capture or unknown owner is not implemented yet
root struct S { a: i64[>..] }
fn main() { var s = S { .. }; fn f() { s.a.push(1); } f(); }

// error: root struct State is not supported yet: independent component storage and lifetime checking are not implemented
root struct State {
    first: i64[>..],
    count: i64,
    text: u8[],
    second: i64[>..<],
    final: bool
}
fn main() {}

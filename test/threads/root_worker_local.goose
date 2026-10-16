root struct State { first: i64[>..], second: i64[>..] }
thread_fn worker() {
    var s = State { [1], [2] };
    s.first.push(3);
    s.second.push(4);
    print(s.first[1], " ", s.second[1]);
}
fn main() { thread_wait(thread_spawn(worker)); }

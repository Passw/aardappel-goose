// Fixed-size, copyable values with stable slots and a LIFO freelist.
// A free marks a slot reusable; it does not destroy or remove its value.
// References remain valid and observe the replacement when that slot is reused.
// Like reusable, double frees are logical errors, not tracked occupancy checks.
// Treat free_slots as bookkeeping and do not shrink or replace items directly.
root struct slot_pool<T> {
    items: T[>..] = [],
    free_slots: i64[>..<] = []
}

fn alloc_index<T>(pool: slot_pool<T>&, value: T) -> i64 {
    if pool.free_slots.len != 0 {
        let i = pool.free_slots.pop();
        pool.items[i] .= value;
        return i;
    }
    let i = pool.items.len;
    pool.items.push(value);
    return i;
}

fn alloc_ref<T>(pool: slot_pool<T>&, value: T) -> T& {
    let i = alloc_index(pool, value);
    return pool.items[i];
}

fn free<T>(pool: slot_pool<T>&, i: i64) {
    if i < 0 || i >= pool.items.len { abort("slot_pool.free: index out of bounds"); }
    pool.free_slots.push(i);
}

// First-fit runs with coalescing and stable backing storage. Freeing marks a
// run reusable; existing views remain valid and can observe replacement values.
// Elements must be fixed-size and defaultable; resizing also requires copying.
// Treat nodes/tree as bookkeeping and do not shrink or replace items directly.

// A 512-byte B+ node: leaves use 31 keys and 31 counts; inner nodes use
// 20 keys, 20 subtree maxima and 20 child indices in the same typed storage.
struct slice_pool_node { n: i64, link: i64, data: i64[62] }
struct slice_pool_tree { root: i64, height: i64, chain: i64 }
root struct slice_pool<T> {
    items: T[>..] = [],
    nodes: slice_pool_node[>..] = [],
    tree: slice_pool_tree = slice_pool_tree { .. }
}
struct slice_pool_path { h: i64, node: i64[24], pos: i64[24] }
struct slice_pool_near { k: i64, next_node: i64, next_pos: i64, other_path: bool }

fn slice_pool_newnode<T>(p: slice_pool<T>&) -> i64 {
    let i = p.tree.chain;
    if i != 0 { p.tree.chain = p.nodes[i].link; return i; }
    let n = p.nodes.len;
    p.nodes.push(slice_pool_node { .. });
    return n;
}
fn slice_pool_dropnode<T>(p: slice_pool<T>&, i: i64) {
    p.nodes[i].link = p.tree.chain;
    p.tree.chain = i;
}
fn slice_pool_max(node: slice_pool_node&, leaf: bool) -> i64 {
    let n = node.n;
    let offset = if leaf { 31 } else { 20 };
    assert(n >= 0 && n <= offset);
    var m = 0;
    let counts = node.data[offset..offset + n];
    for count in counts { if count > m { m = count; } }
    return m;
}
fn slice_pool_fix<T>(p: slice_pool<T>&, path: slice_pool_path&, from: i64) {
    var l = from - 1;
    while l >= 0 {
        let parent .= p.nodes[path.node[l]];
        let child .= p.nodes[path.node[l + 1]];
        let k = path.pos[l];
        let key = child.data[0];
        let maximum = slice_pool_max(child, l + 1 == path.h);
        if parent.data[k] == key && parent.data[20 + k] == maximum { return; }
        parent.data[k] = key;
        parent.data[20 + k] = maximum;
        l--;
    }
}
// Path to the last span beginning at or before idx; -1 precedes all spans.
fn slice_pool_find<T>(p: slice_pool<T>&, path: slice_pool_path&, idx: i64) -> i64 {
    path.h = p.tree.height;
    var i = p.tree.root;
    for l in path.h {
        let node .= p.nodes[i];
        var k = 1;
        while k < node.n && node.data[k] <= idx { k++; }
        path.node[l] = i;
        path.pos[l] = k - 1;
        i = node.data[40 + k - 1];
    }
    path.node[path.h] = i;
    let leaf .= p.nodes[i];
    var lo = 0;
    var hi = leaf.n;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if leaf.data[mid] <= idx { lo = mid + 1; } else { hi = mid; }
    }
    path.pos[path.h] = lo - 1;
    return lo - 1;
}
fn slice_pool_nextleaf<T>(p: slice_pool<T>&, path: slice_pool_path&) -> bool {
    var l = path.h - 1;
    while l >= 0 && path.pos[l] + 1 >= p.nodes[path.node[l]].n { l--; }
    if l < 0 { return false; }
    path.pos[l]++;
    while l < path.h {
        path.node[l + 1] = p.nodes[path.node[l]].data[40 + path.pos[l]];
        path.pos[l + 1] = 0;
        l++;
    }
    return true;
}
fn slice_pool_newroot<T>(p: slice_pool<T>&, a: i64, b: i64, leaf: bool) {
    let r = slice_pool_newnode(p);
    let node .= p.nodes[r];
    node.n = 2;
    node.data[0] = p.nodes[a].data[0];
    node.data[20] = slice_pool_max(p.nodes[a], leaf);
    node.data[40] = a;
    node.data[1] = p.nodes[b].data[0];
    node.data[21] = slice_pool_max(p.nodes[b], leaf);
    node.data[41] = b;
    p.tree.root = r;
    p.tree.height++;
}
fn slice_pool_addchild<T>(p: slice_pool<T>&, path: slice_pool_path&,
                          level: i64, at: i64, child: i64, leaf: bool) {
    var l = level;
    var k = at;
    var c = child;
    var isleaf = leaf;
    loop {
        let node .= p.nodes[path.node[l]];
        var target .= node;
        let key = p.nodes[c].data[0];
        let maximum = slice_pool_max(p.nodes[c], isleaf);
        var s = k;
        var nn = 0;
        if node.n == 20 {
            nn = slice_pool_newnode(p);
            let right .= p.nodes[nn];
            right.n = 10;
            for j in 10 {
                right.data[j] = node.data[10 + j];
                right.data[20 + j] = node.data[30 + j];
                right.data[40 + j] = node.data[50 + j];
            }
            node.n = 10;
            if k > 10 { target .= right; s = k - 10; }
        }
        var j = target.n;
        while j > s {
            target.data[j] = target.data[j - 1];
            target.data[20 + j] = target.data[20 + j - 1];
            target.data[40 + j] = target.data[40 + j - 1];
            j--;
        }
        target.data[s] = key;
        target.data[20 + s] = maximum;
        target.data[40 + s] = c;
        target.n++;
        if nn == 0 { slice_pool_fix(p, path, l); return; }
        if l == 0 { slice_pool_newroot(p, path.node[0], nn, false); return; }
        slice_pool_fix(p, path, l);
        c = nn;
        isleaf = false;
        k = path.pos[l - 1] + 1;
        l--;
    }
}
fn slice_pool_insert<T>(p: slice_pool<T>&, path: slice_pool_path&, k: i64, idx: i64, cnt: i64) {
    let node .= p.nodes[path.node[path.h]];
    var target .= node;
    var s = k;
    var nn = 0;
    if node.n == 31 {
        nn = slice_pool_newnode(p);
        let right .= p.nodes[nn];
        right.n = 16;
        for j in 16 {
            right.data[j] = node.data[15 + j];
            right.data[31 + j] = node.data[46 + j];
        }
        node.n = 15;
        if k > 15 { target .= right; s = k - 15; }
    }
    var j = target.n;
    while j > s {
        target.data[j] = target.data[j - 1];
        target.data[31 + j] = target.data[31 + j - 1];
        j--;
    }
    target.data[s] = idx;
    target.data[31 + s] = cnt;
    target.n++;
    if nn == 0 { slice_pool_fix(p, path, path.h); }
    else if path.h == 0 { slice_pool_newroot(p, path.node[0], nn, true); }
    else {
        slice_pool_fix(p, path, path.h);
        slice_pool_addchild(p, path, path.h - 1, path.pos[path.h - 1] + 1, nn, true);
    }
}
fn slice_pool_delete<T>(p: slice_pool<T>&, path: slice_pool_path&, k: i64) {
    let node .= p.nodes[path.node[path.h]];
    var j = k;
    while j + 1 < node.n {
        node.data[j] = node.data[j + 1];
        node.data[31 + j] = node.data[31 + j + 1];
        j++;
    }
    node.n--;
    if node.n > 0 || path.h == 0 { slice_pool_fix(p, path, path.h); return; }
    slice_pool_dropnode(p, path.node[path.h]);
    var l = path.h - 1;
    loop {
        let parent .= p.nodes[path.node[l]];
        var e = path.pos[l];
        while e + 1 < parent.n {
            parent.data[e] = parent.data[e + 1];
            parent.data[20 + e] = parent.data[20 + e + 1];
            parent.data[40 + e] = parent.data[40 + e + 1];
            e++;
        }
        parent.n--;
        if parent.n > 0 { slice_pool_fix(p, path, l); break; }
        slice_pool_dropnode(p, path.node[l]);
        l--;
    }
    while p.tree.height > 0 && p.nodes[p.tree.root].n == 1 {
        let r = p.tree.root;
        p.tree.root = p.nodes[r].data[40];
        p.tree.height--;
        slice_pool_dropnode(p, r);
    }
}
fn slice_pool_take<T>(p: slice_pool<T>&, path: slice_pool_path&, k: i64, cnt: i64) {
    let node .= p.nodes[path.node[path.h]];
    if node.data[31 + k] <= cnt { slice_pool_delete(p, path, k); return; }
    node.data[k] += cnt;
    node.data[31 + k] -= cnt;
    slice_pool_fix(p, path, path.h);
}
fn slice_pool_place<T>(p: slice_pool<T>&, cnt: i64) -> i64 {
    if cnt == 0 || p.nodes.len == 0 { return p.items.len; }
    var path = slice_pool_path { .. };
    path.h = p.tree.height;
    var i = p.tree.root;
    let fit = path.h == 0 || slice_pool_max(p.nodes[i], false) >= cnt;
    for l in path.h {
        let node .= p.nodes[i];
        var k = node.n - 1;
        if fit { k = 0; while node.data[20 + k] < cnt { k++; } }
        path.node[l] = i;
        path.pos[l] = k;
        i = node.data[40 + k];
    }
    path.node[path.h] = i;
    let node .= p.nodes[i];
    var k = 0;
    if fit { while k < node.n && node.data[31 + k] < cnt { k++; } }
    if !fit || k == node.n {
        k = node.n - 1;
        if k < 0 || node.data[k] + node.data[31 + k] != p.items.len { return p.items.len; }
    }
    let idx = node.data[k];
    slice_pool_take(p, path, k, cnt);
    return idx;
}
fn slice_pool_neighbors<T>(p: slice_pool<T>&, path: slice_pool_path&,
                           next: slice_pool_path&, idx: i64) -> slice_pool_near {
    let k = slice_pool_find(p, path, idx);
    let i = path.node[path.h];
    if k + 1 < p.nodes[i].n { return slice_pool_near { k, i, k + 1, false }; }
    if path.h != 0 {
        next = path;
        if slice_pool_nextleaf(p, next) {
            return slice_pool_near { k, next.node[next.h], 0, true };
        }
    }
    return slice_pool_near { k, -1, -1, false };
}
fn slice_pool_release<T>(p: slice_pool<T>&, path: slice_pool_path&, next: slice_pool_path&,
                         near: slice_pool_near, idx: i64, cnt: i64) {
    let node .= p.nodes[path.node[path.h]];
    let before = near.k >= 0 && node.data[near.k] + node.data[31 + near.k] == idx;
    let after = near.next_node >= 0 && idx + cnt == p.nodes[near.next_node].data[near.next_pos];
    if before {
        node.data[31 + near.k] += cnt + (if after { p.nodes[near.next_node].data[31 + near.next_pos] } else { 0 });
        slice_pool_fix(p, path, path.h);
        if after {
            if near.other_path { slice_pool_delete(p, next, near.next_pos); }
            else { slice_pool_delete(p, path, near.next_pos); }
        }
    } else if after {
        p.nodes[near.next_node].data[near.next_pos] = idx;
        p.nodes[near.next_node].data[31 + near.next_pos] += cnt;
        if near.other_path { slice_pool_fix(p, next, next.h); }
        else { slice_pool_fix(p, path, path.h); }
    } else { slice_pool_insert(p, path, near.k + 1, idx, cnt); }
}
fn slice_pool_release_run<T>(p: slice_pool<T>&, idx: i64, cnt: i64) {
    if cnt == 0 { return; }
    if p.nodes.len == 0 {
        p.nodes.push(slice_pool_node { .. }); // Index zero terminates the empty-node chain.
        p.tree.root = slice_pool_newnode(p);
    }
    var path = slice_pool_path { .. };
    var next = slice_pool_path { .. };
    let near = slice_pool_neighbors(p, path, next, idx);
    slice_pool_release(p, path, next, near, idx, cnt);
}
fn slice_pool_regrow<T>(p: slice_pool<T>&, idx: i64, old: i64, cnt: i64) -> i64 {
    if p.nodes.len == 0 {
        slice_pool_release_run(p, idx, old);
        return slice_pool_place(p, cnt);
    }
    var path = slice_pool_path { .. };
    var next = slice_pool_path { .. };
    let near = slice_pool_neighbors(p, path, next, idx);
    let end = idx + old;
    if near.next_node >= 0 {
        let node .= p.nodes[near.next_node];
        let k = near.next_pos;
        if node.data[k] == end && (node.data[31 + k] >= cnt - old || end + node.data[31 + k] == p.items.len) {
            if near.other_path { slice_pool_take(p, next, k, cnt - old); }
            else { slice_pool_take(p, path, k, cnt - old); }
            return idx;
        }
    }
    slice_pool_release(p, path, next, near, idx, old);
    return slice_pool_place(p, cnt);
}

inline fn slice_pool_defaults<T>(p: slice_pool<T>&, first: i64, end: i64) {
    let used_end = if end < p.items.len { end } else { p.items.len };
    let reused = p.items[first..used_end];
    for i in reused.len { reused[i] .= default<T>(); }
    for i in p.items.len..end { p.items.push(default<T>()); }
}
inline fn slice_pool_move<T>(dst: T[:], src: T[:], backward: bool) {
    assert(dst.len == src.len);
    if backward {
        var j = dst.len;
        while j > 0 { j--; dst[j] .= src[j]; }
    } else {
        for j in dst.len { dst[j] .= src[j]; }
    }
}

// Copy before defaulting, with memmove ordering even when a freed prefix lets
// the new run overlap the old one. New array elements are always initialized.
fn slice_pool_finish<T>(p: slice_pool<T>&, idx: i64, n: i64, old_idx: i64, old: T[:]) -> T[:] {
    if idx < 0 || idx > p.items.len { abort("slice_pool: invalid free span"); }
    let end = p.items.check_length(idx + n);
    if old.len != 0 && idx != old_idx {
        let available = p.items.len - idx;
        var existing = old.len;
        if existing > available { existing = available; }
        // The destination tail is past all source elements, so it can be
        // appended before moving the overlapping existing prefix backward.
        p.items.append(old[existing..]);
        slice_pool_move(p.items[idx..idx + existing], old[..existing], idx > old_idx);
    }
    slice_pool_defaults(p, idx + old.len, end);
    return p.items[idx..end];
}

inline fn alloc_slice<T>(p: slice_pool<T>&, n: i64) -> T[:] {
    let count = p.items.check_length(n);
    let idx = if count == 0 || p.nodes.len == 0 { p.items.len } else { slice_pool_place(p, count) };
    if idx < 0 || idx > p.items.len { abort("slice_pool: invalid free span"); }
    let end = p.items.check_length(idx + count);
    slice_pool_defaults(p, idx, end);
    return p.items[idx..end];
}
fn free_slice<T>(p: slice_pool<T>&, s: T[:]) {
    let idx = p.items.range_index(s);
    slice_pool_release_run(p, idx, s.len);
}
fn realloc_slice<T>(p: slice_pool<T>&, s: T[:], n: i64) -> T[:] {
    let count = p.items.check_length(n);
    let idx = p.items.range_index(s);
    if count <= s.len {
        slice_pool_release_run(p, idx + count, s.len - count);
        return p.items[idx..idx + count];
    }
    var to = idx;
    if s.len == 0 { to = slice_pool_place(p, count); }
    else if idx + s.len != p.items.len { to = slice_pool_regrow(p, idx, s.len, count); }
    return slice_pool_finish(p, to, count, idx, s);
}

namespace slice_pool_detail;

// A 512-byte B+ node: leaves use 31 keys and 31 counts; inner nodes use
// 20 keys, 20 subtree maxima and 20 child indices in the same typed storage.
struct node { n: i64, link: i64, data: i64[62] }
struct tree { root: i64, height: i64, chain: i64 }
// Entry positions are -1..30; node indices retain the array's full index width.
struct path { h: i64, node: i64[24], pos: i8[24] }
struct near { k: i64, next_node: i64, next_pos: i64, other_path: bool }

fn newnode(nodes: node[>..]&, tree: tree&) -> i64 {
    let i = tree.chain;
    if i != 0 { tree.chain = nodes[i].link; return i; }
    let n = nodes.len;
    nodes.push(node { .. });
    return n;
}
fn dropnode(nodes: node[>..]&, tree: tree&, i: i64) {
    nodes[i].link = tree.chain;
    tree.chain = i;
}
fn max(node: node&, leaf: bool, stop: i64 = 9223372036854775807) -> i64 {
    let n = node.n;
    let offset = if leaf { 31 } else { 20 };
    assert(n >= 0 && n <= offset);
    var m = 0;
    let counts = node.data[offset..offset + n];
    for count in counts {
        if m >= stop { break; }
        if count > m { m = count; }
    }
    return m;
}
// One count changed from was to now; only a shrinking maximum needs a scan.
// A split uses i64.max for was to rescan all entries that remain in the node.
fn fix(nodes: node[>..]&, tree: tree&, path: path&, from: i64,
                     was: i64, now: i64) {
    var l = from;
    var old = was;
    var count = now;
    while l > 0 {
        let parent .= nodes[path.node[l - 1]];
        let child .= nodes[path.node[l]];
        let k = path.pos[l - 1];
        let key = child.data[0];
        let m = parent.data[20 + k];
        let maximum = if count >= m { count } else if old < m { m }
                      else { max(child, l == path.h, old) };
        if parent.data[k] == key && m == maximum { return; }
        parent.data[k] = key;
        parent.data[20 + k] = maximum;
        old = m;
        count = maximum;
        l--;
    }
}
// Path to the last span beginning at or before idx; -1 precedes all spans.
fn find(nodes: node[>..]&, tree: tree&, path: path&, idx: i64) -> i64 {
    path.h = tree.height;
    var i = tree.root;
    for l in path.h {
        let node .= nodes[i];
        var k = 1;
        while k < node.n && node.data[k] <= idx { k++; }
        path.node[l] = i;
        path.pos[l] = (k - 1) as i8;
        i = node.data[40 + k - 1];
    }
    path.node[path.h] = i;
    let leaf .= nodes[i];
    let keys = leaf.data[..leaf.n];
    var k = 0;
    while k < keys.len && keys[k] <= idx { k++; }
    path.pos[path.h] = (k - 1) as i8;
    return k - 1;
}
fn newroot(nodes: node[>..]&, tree: tree&, a: i64, b: i64, leaf: bool) {
    let r = newnode(nodes, tree);
    let node .= nodes[r];
    node.n = 2;
    node.data[0] = nodes[a].data[0];
    node.data[20] = max(nodes[a], leaf);
    node.data[40] = a;
    node.data[1] = nodes[b].data[0];
    node.data[21] = max(nodes[b], leaf);
    node.data[41] = b;
    tree.root = r;
    tree.height++;
}
fn addchild(nodes: node[>..]&, tree: tree&, path: path&,
                          level: i64, at: i64, child: i64, leaf: bool) {
    var l = level;
    var k = at;
    var c = child;
    var isleaf = leaf;
    loop {
        let node .= nodes[path.node[l]];
        var target .= node;
        let key = nodes[c].data[0];
        let maximum = max(nodes[c], isleaf);
        var s = k;
        var nn = 0;
        if node.n == 20 {
            nn = newnode(nodes, tree);
            let right .= nodes[nn];
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
        if nn == 0 { fix(nodes, tree, path, l, 0, maximum); return; }
        if l == 0 { newroot(nodes, tree, path.node[0], nn, false); return; }
        fix(nodes, tree, path, l, 9223372036854775807, 0);
        c = nn;
        isleaf = false;
        k = path.pos[l - 1] + 1;
        l--;
    }
}
fn insert(nodes: node[>..]&, tree: tree&, path: path&, k: i64, idx: i64, cnt: i64) {
    let node .= nodes[path.node[path.h]];
    var target .= node;
    var s = k;
    var nn = 0;
    if node.n == 31 {
        nn = newnode(nodes, tree);
        let right .= nodes[nn];
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
    if nn == 0 { fix(nodes, tree, path, path.h, 0, cnt); }
    else if path.h == 0 { newroot(nodes, tree, path.node[0], nn, true); }
    else {
        fix(nodes, tree, path, path.h, 9223372036854775807, 0);
        addchild(nodes, tree, path, path.h - 1, path.pos[path.h - 1] + 1, nn, true);
    }
}
fn close(node: node&, k: i64) {
    node.n--;
    var j = k;
    while j < node.n {
        node.data[j] = node.data[j + 1];
        node.data[31 + j] = node.data[31 + j + 1];
        j++;
    }
}
fn delete(nodes: node[>..]&, tree: tree&, path: path&, k: i64) {
    let node .= nodes[path.node[path.h]];
    let count = node.data[31 + k];
    close(node, k);
    if node.n > 0 || path.h == 0 { fix(nodes, tree, path, path.h, count, 0); return; }
    dropnode(nodes, tree, path.node[path.h]);
    var l = path.h - 1;
    loop {
        let parent .= nodes[path.node[l]];
        var e = path.pos[l];
        let maximum = parent.data[20 + e];
        while e + 1 < parent.n {
            parent.data[e] = parent.data[e + 1];
            parent.data[20 + e] = parent.data[20 + e + 1];
            parent.data[40 + e] = parent.data[40 + e + 1];
            e++;
        }
        parent.n--;
        if parent.n > 0 { fix(nodes, tree, path, l, maximum, 0); break; }
        dropnode(nodes, tree, path.node[l]);
        l--;
    }
    while tree.height > 0 && nodes[tree.root].n == 1 {
        let r = tree.root;
        tree.root = nodes[r].data[40];
        tree.height--;
        dropnode(nodes, tree, r);
    }
}
fn take(nodes: node[>..]&, tree: tree&, path: path&, k: i64, cnt: i64) {
    let node .= nodes[path.node[path.h]];
    let count = node.data[31 + k];
    if count <= cnt { delete(nodes, tree, path, k); return; }
    node.data[k] += cnt;
    node.data[31 + k] = count - cnt;
    fix(nodes, tree, path, path.h, count, count - cnt);
}
fn place(nodes: node[>..]&, tree: tree&, length: i64, cnt: i64) -> i64 {
    if cnt == 0 || nodes.len == 0 { return length; }
    var path = path { .. };
    var before: i64[24] = [0; 24];
    path.h = tree.height;
    var i = tree.root;
    var l = 0;
    var k = 0;
    // The maxima before the first fit also serve the update on the way back.
    while l < path.h {
        let node .= nodes[i];
        let counts = node.data[20..20 + node.n];
        k = 0;
        var m = 0;
        while k < counts.len && counts[k] < cnt {
            if counts[k] > m { m = counts[k]; }
            k++;
        }
        if k == counts.len { break; }
        path.node[l] = i;
        path.pos[l] = k as i8;
        before[l] = m;
        i = node.data[40 + k];
        l++;
    }
    var fit = false;
    if l == path.h {
        let node .= nodes[i];
        let counts = node.data[31..31 + node.n];
        k = 0;
        var m = 0;
        while k < counts.len && counts[k] < cnt {
            if counts[k] > m { m = counts[k]; }
            k++;
        }
        before[l] = m;
        fit = k < counts.len;
    }
    if !fit {
        i = tree.root;
        for level in path.h {
            let node .= nodes[i];
            path.node[level] = i;
            path.pos[level] = (node.n - 1) as i8;
            i = node.data[40 + node.n - 1];
        }
        path.node[path.h] = i;
        let node .= nodes[i];
        k = node.n - 1;
        if k < 0 || node.data[k] + node.data[31 + k] != length { return length; }
        let idx = node.data[k];
        take(nodes, tree, path, k, cnt);
        return idx;
    }
    path.node[path.h] = i;
    path.pos[path.h] = k as i8;
    let node .= nodes[i];
    let idx = node.data[k];
    var count = node.data[31 + k];
    var now = 0;
    var j = k;
    if count > cnt {
        node.data[k] = idx + cnt;
        now = count - cnt;
        node.data[31 + k] = now;
        j++;
    } else if node.n > 1 || path.h == 0 { close(node, k); }
    else { delete(nodes, tree, path, k); return idx; }
    // Only the suffix after the path needs scanning when its maximum shrank.
    l = path.h;
    while l > 0 {
        let parent .= nodes[path.node[l - 1]];
        let child .= nodes[path.node[l]];
        let e = path.pos[l - 1];
        let maximum = parent.data[20 + e];
        let key = child.data[0];
        var nm = maximum;
        if count == maximum {
            nm = if before[l] > now { before[l] } else { now };
            let offset = if l == path.h { 31 } else { 20 };
            let counts = child.data[offset + j..offset + child.n];
            for c in counts {
                if nm >= count { break; }
                if c > nm { nm = c; }
            }
        }
        if parent.data[e] == key && nm == maximum { break; }
        parent.data[e] = key;
        parent.data[20 + e] = nm;
        count = maximum;
        now = nm;
        j = e + 1;
        l--;
    }
    return idx;
}
fn neighbors(nodes: node[>..]&, tree: tree&, path: path&,
                           next: path&, idx: i64, end: i64) -> near {
    let k = find(nodes, tree, path, idx);
    let i = path.node[path.h];
    if k + 1 < nodes[i].n { return near { k, i, k + 1, false }; }
    var l = path.h - 1;
    while l >= 0 && path.pos[l] + 1 >= nodes[path.node[l]].n { l--; }
    // An inner key is its subtree's first span, so it proves adjacency
    // before a second path is needed. Copy only the shared path prefix.
    if l < 0 || nodes[path.node[l]].data[path.pos[l] + 1] != end {
        return near { k, -1, -1, false };
    }
    next.h = path.h;
    for j in l + 1 { next.node[j] = path.node[j]; next.pos[j] = path.pos[j]; }
    next.pos[l]++;
    while l < next.h {
        next.node[l + 1] = nodes[next.node[l]].data[40 + next.pos[l]];
        next.pos[l + 1] = 0;
        l++;
    }
    return near { k, next.node[next.h], 0, true };
}
fn release(nodes: node[>..]&, tree: tree&, path: path&, next: path&,
                         near: near, idx: i64, cnt: i64) {
    let node .= nodes[path.node[path.h]];
    let before = near.k >= 0 && node.data[near.k] + node.data[31 + near.k] == idx;
    let after = near.next_node >= 0 && idx + cnt == nodes[near.next_node].data[near.next_pos];
    if before {
        let count = node.data[31 + near.k];
        let merged = count + cnt + (if after { nodes[near.next_node].data[31 + near.next_pos] } else { 0 });
        node.data[31 + near.k] = merged;
        // The merged count exceeds both old counts, so one fix covers both.
        if after && !near.other_path { close(node, near.next_pos); }
        fix(nodes, tree, path, path.h, count, merged);
        if after && near.other_path { delete(nodes, tree, next, near.next_pos); }
    } else if after {
        let count = nodes[near.next_node].data[31 + near.next_pos];
        nodes[near.next_node].data[near.next_pos] = idx;
        nodes[near.next_node].data[31 + near.next_pos] = count + cnt;
        if near.other_path { fix(nodes, tree, next, next.h, count, count + cnt); }
        else { fix(nodes, tree, path, path.h, count, count + cnt); }
    } else { insert(nodes, tree, path, near.k + 1, idx, cnt); }
}
fn release_run(nodes: node[>..]&, tree: tree&, idx: i64, cnt: i64) {
    if cnt == 0 { return; }
    if nodes.len == 0 {
        nodes.push(node { .. }); // Index zero terminates the empty-node chain.
        tree.root = newnode(nodes, tree);
    }
    var path = path { .. };
    var next = path { .. };
    let near = neighbors(nodes, tree, path, next, idx, idx + cnt);
    release(nodes, tree, path, next, near, idx, cnt);
}
fn regrow(nodes: node[>..]&, tree: tree&, length: i64, idx: i64, old: i64, cnt: i64) -> i64 {
    if nodes.len == 0 {
        release_run(nodes, tree, idx, old);
        return place(nodes, tree, length, cnt);
    }
    var path = path { .. };
    var next = path { .. };
    let end = idx + old;
    let near = neighbors(nodes, tree, path, next, idx, end);
    if near.next_node >= 0 {
        let node .= nodes[near.next_node];
        let k = near.next_pos;
        if node.data[k] == end && (node.data[31 + k] >= cnt - old || end + node.data[31 + k] == length) {
            if near.other_path { take(nodes, tree, next, k, cnt - old); }
            else { take(nodes, tree, path, k, cnt - old); }
            return idx;
        }
    }
    release(nodes, tree, path, next, near, idx, old);
    return place(nodes, tree, length, cnt);
}

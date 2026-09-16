// SPDX-License-Identifier: LGPL-3.0-or-later
//! GBA 4-bit Huffman encoder.
const std = @import("std");

const Node = struct {
    leaf: bool,
    sym: u8 = 0,
    left: ?*Node = null,
    right: ?*Node = null,
};

const Entry = struct { freq: u64, counter: u64, node: *Node };

fn entryLess(_: void, a: Entry, b: Entry) std.math.Order {
    if (a.freq != b.freq) return std.math.order(a.freq, b.freq);
    return std.math.order(a.counter, b.counter);
}

fn buildTree(a: std.mem.Allocator, order: []const u8, freq: [16]u64) !*Node {
    var counter: u64 = 0;
    if (order.len == 1) {
        const n = try a.create(Node);
        n.* = .{ .leaf = false };
        const l = try a.create(Node);
        l.* = .{ .leaf = true, .sym = order[0] };
        const r = try a.create(Node);
        r.* = .{ .leaf = true, .sym = order[0] };
        n.left = l;
        n.right = r;
        return n;
    }
    var heap: std.PriorityQueue(Entry, void, entryLess) = .empty;
    for (order) |s| {
        const n = try a.create(Node);
        n.* = .{ .leaf = true, .sym = s };
        try heap.push(a, .{ .freq = freq[s], .counter = counter, .node = n });
        counter += 1;
    }
    while (heap.count() > 1) {
        const e1 = heap.pop().?;
        const e2 = heap.pop().?;
        const n = try a.create(Node);
        n.* = .{ .leaf = false, .left = e1.node, .right = e2.node };
        try heap.push(a, .{ .freq = e1.freq + e2.freq, .counter = counter, .node = n });
        counter += 1;
    }
    return heap.pop().?.node;
}

const Code = struct { bits: u32, n: u5 };

fn assignCodes(node: *Node, bits: u32, n: u32, codes: *[16]Code) void {
    if (!node.leaf) {
        assignCodes(node.left.?, bits << 1, n + 1, codes);
        assignCodes(node.right.?, (bits << 1) | 1, n + 1, codes);
    } else {
        codes[node.sym] = .{ .bits = bits, .n = @intCast(@max(n, 1)) };
    }
}

fn nibbleFreq(data: []const u8, order: *std.ArrayList(u8), gpa: std.mem.Allocator, freq: *[16]u64) !void {
    var seen = [_]bool{false} ** 16;
    for (data) |b| {
        for ([_]u8{ b & 0xF, (b >> 4) & 0xF }) |nib| {
            if (!seen[nib]) {
                seen[nib] = true;
                try order.append(gpa, nib);
            }
            freq[nib] += 1;
        }
    }
}

const Tree = struct { size: u8, bytes: []u8 };

fn serializeTree(a: std.mem.Allocator, root: *Node) !Tree {
    var nodes = std.AutoHashMap(usize, *Node).init(a);
    var table = std.AutoHashMap(usize, u8).init(a);
    try nodes.put(0, root);
    var end: usize = 1;
    var queue: std.ArrayList(usize) = .empty;
    try queue.append(a, 0);
    var qi: usize = 0;
    while (qi < queue.items.len) {
        const p = queue.items[qi];
        qi += 1;
        const node = nodes.get(p).?;
        if (!node.leaf) {
            const cp = end;
            end += 2;
            const base = if (p % 2 == 0) p + 1 else p + 2;
            const offset = (cp - base) / 2;
            var b: u8 = @intCast(offset);
            if (node.left.?.leaf) b |= 0x80;
            if (node.right.?.leaf) b |= 0x40;
            try table.put(p, b);
            try nodes.put(cp, node.left.?);
            try nodes.put(cp + 1, node.right.?);
            try queue.append(a, cp);
            try queue.append(a, cp + 1);
        } else {
            try table.put(p, node.sym);
        }
    }
    const arr = try a.alloc(u8, end);
    for (0..end) |i| arr[i] = table.get(i) orelse 0;
    return .{ .size = @intCast((end - 1) / 2), .bytes = arr };
}

pub fn encode(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(gpa);
    var freq = [_]u64{0} ** 16;
    try nibbleFreq(data, &order, gpa, &freq);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try buildTree(a, order.items, freq);
    var codes = [_]Code{.{ .bits = 0, .n = 1 }} ** 16;
    assignCodes(root, 0, 0, &codes);
    const tree = try serializeTree(a, root);

    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    var acc: u32 = 0;
    var nbits: u32 = 0;
    for (data) |byte| {
        for ([_]u8{ byte & 0xF, (byte >> 4) & 0xF }) |sym| {
            const c = codes[sym];
            var i: i32 = @as(i32, c.n) - 1;
            while (i >= 0) : (i -= 1) {
                acc = (acc << 1) | ((c.bits >> @intCast(i)) & 1);
                nbits += 1;
                if (nbits == 32) {
                    try words.append(gpa, acc);
                    acc = 0;
                    nbits = 0;
                }
            }
        }
    }
    if (nbits != 0) {
        acc <<= @intCast(32 - nbits);
        try words.append(gpa, acc);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n: u32 = @intCast(data.len);
    const header: u32 = 0x24 | (n << 8);
    try appendU32(gpa, &out, header);
    try out.append(gpa, tree.size);
    try out.appendSlice(gpa, tree.bytes);
    for (words.items) |w| try appendU32(gpa, &out, w);
    return out.toOwnedSlice(gpa);
}

pub fn codelens(gpa: std.mem.Allocator, stream: []const u8) ![16]i32 {
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(gpa);
    var freq = [_]u64{0} ** 16;
    try nibbleFreq(stream, &order, gpa, &freq);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try buildTree(a, order.items, freq);
    var codes = [_]Code{.{ .bits = 0, .n = 1 }} ** 16;
    assignCodes(root, 0, 0, &codes);
    var out = [_]i32{-1} ** 16;
    for (order.items) |s| out[s] = codes[s].n;
    return out;
}

fn appendU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

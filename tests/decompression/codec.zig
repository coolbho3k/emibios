// SPDX-License-Identifier: MIT
//! Small encoders for decompression test fixtures.
//! Each encoder returns an allocated stream whose length is padded to a multiple of 4.
const std = @import("std");
const List = std.ArrayListUnmanaged(u8);

fn header(out: *List, a: std.mem.Allocator, type_byte: u8, len: usize) !void {
    var h: [4]u8 = undefined;
    std.mem.writeInt(u32, &h, @as(u32, type_byte) | (@as(u32, @intCast(len)) << 8), .little);
    try out.appendSlice(a, &h);
}

fn finish(out: *List, a: std.mem.Allocator) ![]u8 {
    while (out.items.len % 4 != 0) try out.append(a, 0);
    return out.toOwnedSlice(a);
}

/// Type-1 LZ77 fixture stream.
/// `min_disp` is 1 for WRAM and 2 for VRAM's 16-bit write path.
pub fn lz77(a: std.mem.Allocator, data: []const u8, min_disp: usize) ![]u8 {
    var out: List = .empty;
    errdefer out.deinit(a);
    try header(&out, a, 0x10, data.len);
    var i: usize = 0;
    while (i < data.len) {
        const flag_at = out.items.len;
        try out.append(a, 0);
        var flags: u8 = 0;
        for (0..8) |k| {
            if (i >= data.len) break;
            var best_len: usize = 0;
            var best_disp: usize = 0;
            var j = if (i > 0x1000) i - 0x1000 else 0;
            while (j + min_disp <= i) : (j += 1) {
                var l: usize = 0;
                while (l < 18 and i + l < data.len and data[j + l] == data[i + l]) : (l += 1) {}
                if (l >= 3 and l > best_len) {
                    best_len = l;
                    best_disp = i - j;
                }
            }
            if (best_len >= 3) {
                flags |= @as(u8, 0x80) >> @intCast(k);
                const d = best_disp - 1;
                try out.append(a, @intCast(((best_len - 3) << 4) | (d >> 8)));
                try out.append(a, @intCast(d & 0xFF));
                i += best_len;
            } else {
                try out.append(a, data[i]);
                i += 1;
            }
        }
        out.items[flag_at] = flags;
    }
    return finish(&out, a);
}

/// Type-3 run-length fixture stream.
pub fn rl(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: List = .empty;
    errdefer out.deinit(a);
    try header(&out, a, 0x30, data.len);
    var i: usize = 0;
    while (i < data.len) {
        var run: usize = 1;
        while (i + run < data.len and run < 130 and data[i + run] == data[i]) : (run += 1) {}
        if (run >= 3) {
            try out.append(a, 0x80 | @as(u8, @intCast(run - 3)));
            try out.append(a, data[i]);
            i += run;
        } else {
            var lit: usize = 1;
            while (i + lit < data.len and lit < 128) : (lit += 1) {
                if (i + lit + 2 < data.len and data[i + lit] == data[i + lit + 1] and data[i + lit + 1] == data[i + lit + 2]) break;
            }
            try out.append(a, @intCast(lit - 1));
            try out.appendSlice(a, data[i .. i + lit]);
            i += lit;
        }
    }
    return finish(&out, a);
}

/// Type-8 stream for Diff8bitUnFilter.
pub fn diff8(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: List = .empty;
    errdefer out.deinit(a);
    try header(&out, a, 0x81, data.len);
    var prev: u8 = 0;
    for (data) |b| {
        try out.append(a, b -% prev);
        prev = b;
    }
    return finish(&out, a);
}

const HNode = struct { leaf: bool, sym: u8 = 0, c0: u16 = 0, c1: u16 = 0 };

fn hBuild(nodes: *std.ArrayListUnmanaged(HNode), a: std.mem.Allocator, syms: []const u8) !u16 {
    if (syms.len == 1) {
        try nodes.append(a, .{ .leaf = true, .sym = syms[0] });
        return @intCast(nodes.items.len - 1);
    }
    const mid = syms.len / 2; // Keeps BFS child offsets within the 6-bit field.
    const c0 = try hBuild(nodes, a, syms[0..mid]);
    const c1 = try hBuild(nodes, a, syms[mid..]);
    try nodes.append(a, .{ .leaf = false, .c0 = c0, .c1 = c1 });
    return @intCast(nodes.items.len - 1);
}

fn hCodes(nodes: []const HNode, node: u16, bits: u32, len: u5, code: *[256]u32, clen: *[256]u5) void {
    const n = nodes[node];
    if (n.leaf) {
        code[n.sym] = bits;
        clen[n.sym] = len;
    } else {
        hCodes(nodes, n.c0, bits << 1, len + 1, code, clen);
        hCodes(nodes, n.c1, (bits << 1) | 1, len + 1, code, clen);
    }
}

/// Type-2 Huffman fixture stream with 8-bit symbols.
/// `data.len` must be a multiple of 4 and use an alphabet small enough for 6-bit child offsets.
pub fn huffman(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var present = [_]bool{false} ** 256;
    for (data) |b| present[b] = true;
    var syms: std.ArrayListUnmanaged(u8) = .empty;
    defer syms.deinit(a);
    for (0..256) |s| if (present[s]) try syms.append(a, @intCast(s));

    var nodes: std.ArrayListUnmanaged(HNode) = .empty;
    defer nodes.deinit(a);
    const root = try hBuild(&nodes, a, syms.items);

    // The byte at file offset 5 + i is table.items[i].
    var table: std.ArrayListUnmanaged(u8) = .empty;
    defer table.deinit(a);
    try table.append(a, 0);
    const QItem = struct { node: u16, addr: usize };
    var queue: std.ArrayListUnmanaged(QItem) = .empty;
    defer queue.deinit(a);
    try queue.append(a, .{ .node = root, .addr = 5 });
    var next_pair: usize = 6;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const it = queue.items[head];
        const n = nodes.items[it.node];
        const pair = next_pair;
        next_pair += 2;
        const off = (pair - (it.addr & ~@as(usize, 1)) - 2) >> 1;
        std.debug.assert(off <= 63);
        while (table.items.len < pair - 5 + 2) try table.append(a, 0);
        var b: u8 = @intCast(off);
        if (nodes.items[n.c0].leaf) b |= 0x80;
        if (nodes.items[n.c1].leaf) b |= 0x40;
        table.items[it.addr - 5] = b;
        const kids = [_]u16{ n.c0, n.c1 };
        for (kids, 0..) |kid, i| {
            if (nodes.items[kid].leaf) {
                table.items[pair + i - 5] = nodes.items[kid].sym;
            } else {
                try queue.append(a, .{ .node = kid, .addr = pair + i });
            }
        }
    }

    // The bitstream begins at file offset 5 + table.len and is fetched as 32-bit words.
    // Pad the node table itself so the tree-size byte remains exact.
    while ((5 + table.items.len) % 4 != 0) try table.append(a, 0);

    var code = [_]u32{0} ** 256;
    var clen = [_]u5{0} ** 256;
    hCodes(nodes.items, root, 0, 0, &code, &clen);

    var out: List = .empty;
    errdefer out.deinit(a);
    try header(&out, a, 0x28, data.len);
    try out.append(a, @intCast((table.items.len - 1) >> 1));
    try out.appendSlice(a, table.items);
    var acc: u32 = 0;
    var nbits: u6 = 0;
    for (data) |sym| {
        var i: u5 = clen[sym];
        while (i > 0) {
            i -= 1;
            acc = (acc << 1) | ((code[sym] >> i) & 1);
            nbits += 1;
            if (nbits == 32) {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, acc, .little);
                try out.appendSlice(a, &w);
                acc = 0;
                nbits = 0;
            }
        }
    }
    if (nbits > 0) {
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, acc << @intCast(32 - nbits), .little);
        try out.appendSlice(a, &w);
    }
    try out.appendSlice(a, &[_]u8{0} ** 8); // The decoder may consume padding bits before the length check.
    return out.toOwnedSlice(a);
}

///Type-8 stream for Diff16bitUnFilter.
/// `data` is little-endian output bytes and must contain whole 16-bit units.
pub fn diff16(a: std.mem.Allocator, data: []const u8) ![]u8 {
    std.debug.assert(data.len % 2 == 0);
    var out: List = .empty;
    errdefer out.deinit(a);
    try header(&out, a, 0x82, data.len);
    var prev: u16 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const v = std.mem.readInt(u16, data[i..][0..2], .little);
        var d: [2]u8 = undefined;
        std.mem.writeInt(u16, &d, v -% prev, .little);
        try out.appendSlice(a, &d);
        prev = v;
    }
    return finish(&out, a);
}

/// The 8-byte BitUnPack UnPackInfo struct that the SWI reads through r2.
pub fn bitUnpackInfo(src_len: u16, src_width: u8, dst_width: u8, data_offset: u32) [8]u8 {
    var p: [8]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], src_len, .little);
    p[2] = src_width;
    p[3] = dst_width;
    std.mem.writeInt(u32, p[4..8], data_offset, .little);
    return p;
}

/// BitUnPack fixture model.
/// Over-wide destination units intentionally spill into the next packed unit.
pub fn bitunpack(a: std.mem.Allocator, src: []const u8, sw: u8, dw: u8, data_offset: u32) ![]u8 {
    const offset = data_offset & 0x7FFFFFFF;
    const zero = data_offset >> 31;
    const smask = (@as(u32, 1) << @intCast(sw)) - 1;
    var out: List = .empty;
    errdefer out.deinit(a);
    var word: u32 = 0;
    var bp: u6 = 0; // bit position within the current 32-bit word
    for (src) |byte| {
        var k: u8 = 0;
        while (k < 8 / sw) : (k += 1) {
            const v = (@as(u32, byte) >> @intCast(k * sw)) & smask;
            const o: u32 = if (v != 0 or zero != 0) v + offset else 0;
            word |= o << @intCast(bp);
            bp += @intCast(dw);
            if (bp == 32) {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, word, .little);
                try out.appendSlice(a, &w);
                word = 0;
                bp = 0;
            }
        }
    }
    return out.toOwnedSlice(a);
}

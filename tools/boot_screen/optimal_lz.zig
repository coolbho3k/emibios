// SPDX-License-Identifier: GPL-3.0-or-later
//! GBA LZ77 encoder optimized for the final Huffman4 wrapper.
//! A Zopfli-style loop re-parses with the real Huffman code lengths fed back into the LZ cost model, which
//! provides a slightly better compression ratio with Huffman4 than without optimization. This is the most efficient
//! general purpose compression method on GBA I found that still exclusively uses the included SWIs. Without the
//! Huffman4 wrapper, the optimizing LZ77 is less efficient than greedy.
const std = @import("std");
const huffman4 = @import("huffman4.zig");

const WIN: usize = 0x1000;
const MINM: usize = 3;
const MAXM: usize = 18;

pub fn header(decomp_size: usize) [4]u8 {
    const n = decomp_size;
    return .{ (1 << 4), @intCast(n & 0xFF), @intCast((n >> 8) & 0xFF), @intCast((n >> 16) & 0xFF) };
}

const M = struct { L: usize, disp: usize };

fn buildMatchTable(gpa: std.mem.Allocator, data: []const u8) ![]std.ArrayList(M) {
    const n = data.len;
    const tab = try gpa.alloc(std.ArrayList(M), n);
    for (tab) |*t| t.* = .empty;
    for (0..n) |i| {
        var have = [_]bool{false} ** (MAXM + 1);
        var need: usize = MAXM - MINM + 1;
        const lo = if (i > WIN) i - WIN else 0;
        var s: usize = i;
        while (s > lo) {
            s -= 1;
            var l: usize = 0;
            while (l < MAXM and i + l < n and data[s + l] == data[i + l]) l += 1;
            if (l >= MINM) {
                var L: usize = MINM;
                while (L <= l) : (L += 1) {
                    if (!have[L]) {
                        have[L] = true;
                        try tab[i].append(gpa, .{ .L = L, .disp = i - s - 1 });
                        need -= 1;
                    }
                }
                if (need == 0) break;
            }
        }
    }
    return tab;
}

pub fn greedy(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const n = data.len;
    var i: usize = 0;
    while (i < n) {
        const fp = out.items.len;
        try out.append(gpa, 0);
        var flag: u8 = 0;
        var b: u3 = 0;
        while (true) : (b += 1) {
            if (i >= n) break;
            var best_len: usize = 0;
            var best_disp: usize = 0;
            const lo = if (i > WIN) i - WIN else 0;
            var s: usize = i;
            while (s > lo) {
                s -= 1;
                var l: usize = 0;
                while (l < MAXM and i + l < n and data[s + l] == data[i + l]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_disp = i - s - 1;
                }
                if (best_len == MAXM) break;
            }
            if (best_len >= MINM) {
                flag |= (@as(u8, 0x80) >> b);
                const v = ((best_len - 3) << 12) | best_disp;
                try out.append(gpa, @intCast((v >> 8) & 0xFF));
                try out.append(gpa, @intCast(v & 0xFF));
                i += best_len;
            } else {
                try out.append(gpa, data[i]);
                i += 1;
            }
            if (b == 7) break;
        }
        out.items[fp] = flag;
    }
    return out.items;
}

const Cost = struct {
    cl: [16]i32,
    mx: f64,
    flag_amort: f64,
    fn nib(self: Cost, x: u8) f64 {
        return if (self.cl[x] >= 0) @floatFromInt(self.cl[x]) else self.mx;
    }
    fn clByte(self: Cost, b: u8) f64 {
        return self.nib(b & 0xF) + self.nib(b >> 4);
    }
    fn lit(self: Cost, b: u8) f64 {
        return self.clByte(b) + self.flag_amort;
    }
    fn match(self: Cost, L: usize, disp: usize) f64 {
        const v = ((L - 3) << 12) | disp;
        return self.clByte(@intCast((v >> 8) & 0xFF)) + self.clByte(@intCast(v & 0xFF)) + self.flag_amort;
    }
};

fn makeCost(cl: [16]i32, flag_amort: f64) Cost {
    var mx: f64 = 4;
    var any = false;
    var hi: i32 = 0;
    for (cl) |c| if (c >= 0) {
        any = true;
        if (c > hi) hi = c;
    };
    if (any) mx = @floatFromInt(hi + 1);
    return .{ .cl = cl, .mx = mx, .flag_amort = flag_amort };
}

const Choice = struct { is_match: bool, L: usize, disp: usize };
const ParseResult = struct { body: []u8, ntok: usize, flags: []u8 };

fn optimal(gpa: std.mem.Allocator, data: []const u8, tab: []std.ArrayList(M), cost: Cost) !ParseResult {
    const n = data.len;
    const c = try gpa.alloc(f64, n + 1);
    defer gpa.free(c);
    const choice = try gpa.alloc(Choice, n + 1);
    defer gpa.free(choice);
    c[n] = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var best = cost.lit(data[i]) + c[i + 1];
        var bch = Choice{ .is_match = false, .L = 1, .disp = 0 };
        for (tab[i].items) |m| {
            if (i + m.L <= n) {
                const cc = cost.match(m.L, m.disp) + c[i + m.L];
                if (cc < best) {
                    best = cc;
                    bch = .{ .is_match = true, .L = m.L, .disp = m.disp };
                }
            }
        }
        c[i] = best;
        choice[i] = bch;
    }
    var out: std.ArrayList(u8) = .empty;
    var flags: std.ArrayList(u8) = .empty;
    var ntok: usize = 0;
    i = 0;
    while (i < n) {
        const fp = out.items.len;
        try out.append(gpa, 0);
        var flag: u8 = 0;
        var b: u3 = 0;
        while (true) : (b += 1) {
            if (i >= n) break;
            const ch = choice[i];
            ntok += 1;
            if (ch.is_match) {
                const v = ((ch.L - 3) << 12) | ch.disp;
                flag |= (@as(u8, 0x80) >> b);
                try out.append(gpa, @intCast((v >> 8) & 0xFF));
                try out.append(gpa, @intCast(v & 0xFF));
                i += ch.L;
            } else {
                try out.append(gpa, data[i]);
                i += 1;
            }
            if (b == 7) break;
        }
        out.items[fp] = flag;
        try flags.append(gpa, flag);
    }
    return .{ .body = out.items, .ntok = ntok, .flags = flags.items };
}

fn blobLen(gpa: std.mem.Allocator, hdr: [4]u8, body: []const u8) !usize {
    const buf = try gpa.alloc(u8, 4 + body.len);
    defer gpa.free(buf);
    @memcpy(buf[0..4], &hdr);
    @memcpy(buf[4..], body);
    const blob = try huffman4.encode(gpa, buf);
    defer gpa.free(blob);
    return blob.len;
}

fn zopfli(gpa: std.mem.Allocator, data: []const u8, tab: []std.ArrayList(M), iters: usize) ![]u8 {
    const hdr = header(data.len);
    const g = try greedy(gpa, data);
    var best_lz = g;
    var best = try blobLen(gpa, hdr, g);

    var cl = [_]i32{4} ** 16;
    var flag_amort: f64 = 1.0;
    var prev: ?[]u8 = null;
    var it: usize = 0;
    while (it < iters) : (it += 1) {
        const cost = makeCost(cl, flag_amort);
        const pr = try optimal(gpa, data, tab, cost);
        const sz = try blobLen(gpa, hdr, pr.body);
        if (sz < best) {
            best = sz;
            best_lz = pr.body;
        }
        if (prev) |p| if (std.mem.eql(u8, p, pr.body)) break;
        prev = pr.body;
        const buf = try gpa.alloc(u8, 4 + pr.body.len);
        defer gpa.free(buf);
        @memcpy(buf[0..4], &hdr);
        @memcpy(buf[4..], pr.body);
        cl = try huffman4.codelens(gpa, buf);
        var flagbits: f64 = 0;
        for (pr.flags) |f| {
            flagbits += if (cl[f & 0xF] >= 0) @as(f64, @floatFromInt(cl[f & 0xF])) else 4;
            flagbits += if (cl[f >> 4] >= 0) @as(f64, @floatFromInt(cl[f >> 4])) else 4;
        }
        flag_amort = flagbits / @as(f64, @floatFromInt(@max(1, pr.ntok)));
    }
    return best_lz;
}

pub fn lz(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const tab = try buildMatchTable(gpa, data);
    const best_lz = try zopfli(gpa, data, tab, 12);
    const hdr = header(data.len);
    const buf = try gpa.alloc(u8, 4 + best_lz.len);
    @memcpy(buf[0..4], &hdr);
    @memcpy(buf[4..], best_lz);
    return buf;
}

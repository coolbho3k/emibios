// SPDX-License-Identifier: MIT
//! RLUnComp tests for WRAM and VRAM destinations.
//! The VRAM variant differs only in write width because the decoder never rereads output.
const std = @import("std");
const gba = @import("gba");
const codec = @import("codec.zig");
const opts = @import("test_options");
const testing = @import("testing");
const h = @import("test_helpers.zig");

pub const wram = gba.Swi{ .bios_path = opts.bios_path, .target = opts.rl_wram_rom };
pub const vram = gba.Swi{ .bios_path = opts.bios_path, .target = opts.rl_vram_rom };

fn ctRl(comptime data: []const u8) []const u8 {
    const arr align(4) = comptime blk: {
        @setEvalBranchQuota(4_000_000);
        var buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const c = codec.rl(fba.allocator(), data) catch unreachable;
        var out: [c.len]u8 align(4) = undefined;
        @memcpy(&out, c);
        break :blk out;
    };
    return &arr;
}
const comp_timing = ctRl(&[_]u8{0x7E} ** 256); // same stream drives both WRAM and VRAM timing

// Comptime runs of varying length; the trailing case in each sweep is odd (wram) / even (vram) size.
fn runs(comptime n: usize) [n]u8 {
    var b: [n]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = @intCast((i / 5) & 0xFF);
    return b;
}

fn roundWram(t: anytype, a: std.mem.Allocator) !void {
    const cases = .{ "A", "Hi", "AAA", "AAAAAAAABBBBBCCDEFGGGGGG", &([_]u8{0xFF} ** 200), &runs(533) };
    inline for (cases, 0..) |d, i|
        try h.roundtrip(t, a, "wram", i, wram, try codec.rl(a, d), d);
}

fn roundVram(t: anytype, a: std.mem.Allocator) !void {
    const cases = .{ "Hi", "AAAAAAAA", "AAAAAAAABBBBBBBBCCCCDDDD", &([_]u8{0xFF} ** 200), &runs(534) };
    inline for (cases, 0..) |d, i|
        try h.roundtrip(t, a, "vram", i, vram, try codec.rl(a, d), d);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    try h.timing(t, a, "wram cyc", wram, comp_timing, 256, 2490);
    try h.timing(t, a, "vram cyc", vram, comp_timing, 256, 4562);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    try h.guard(t, a, "wram", wram, try codec.rl(a, "would be output if not guarded"), 123);
    try h.guard(t, a, "vram", vram, try codec.rl(a, "would be output if not guarded"), 126);
}

fn malformed(t: anytype, a: std.mem.Allocator) !void {
    const size0 = [_]u8{ 0x30, 0, 0, 0 };
    var d0 = [_]u8{0xAB} ** 8;
    a.free(try wram.runMem(a, &.{.{ .src = &size0, .dest = &d0 }}));
    var n0: u32 = 0;
    for (d0) |b| {
        if (b != 0) n0 += 1;
    }
    try t.checkEqual("size0 nowrite", @as(u32, 0), n0);
    const over = [_]u8{ 0x30, 4, 0, 0, 0x85, 0x42, 0, 0 };
    var dt = [_]u8{0xAB} ** 8;
    a.free(try wram.runMem(a, &.{.{ .src = &over, .dest = &dt }}));
    try t.checkBytes("final run overshoot", "BBBBBBBB", &dt);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try roundWram(t, a);
    try roundVram(t, a);
    try cyc(t, a);
    try guard(t, a);
    try malformed(t, a);
}

test "RLUnComp roundWram" {
    try testing.host(roundWram, std.testing.allocator);
}
test "RLUnComp roundVram" {
    try testing.host(roundVram, std.testing.allocator);
}
test "RLUnComp cyc" {
    try testing.host(cyc, std.testing.allocator);
}
test "RLUnComp malformed" {
    try testing.host(malformed, std.testing.allocator);
}
test "RLUnComp guard" {
    try testing.host(guard, std.testing.allocator);
}

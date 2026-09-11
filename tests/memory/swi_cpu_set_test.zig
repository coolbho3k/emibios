// SPDX-License-Identifier: MIT
//! CpuSet tests for 16- and 32-bit copy/fill.
//! Destination memory is the defined output.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");
const bytes = std.mem.sliceAsBytes;

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.cpu_set_rom };

const FILL: u32 = 1 << 24; // fixed source: repeat one unit
const WORD: u32 = 1 << 26; // 32-bit units (else 16-bit)

// Const so the timing source sits in cart ROM (the region the pinned cycle counts were measured against).
const timing_src = [_]u32{0x5A5A5A5A} ** 64;

fn countNot(comptime T: type, slice: []const T, val: T) u32 {
    var n: u32 = 0;
    for (slice) |x| {
        if (x != val) n += 1;
    }
    return n;
}

fn copy(t: anytype, a: std.mem.Allocator) !void {
    const src32 = [_]u32{ 0x11111111, 0x22222222, 0xDEADBEEF, 0, 0x0FF00FF0, 0xFFFFFFFF, 7, 0x80000000 };
    var dst32 = [_]u32{0} ** src32.len;
    const src16 = [_]u16{ 0x1234, 0xABCD, 0, 0xFFFF, 0x8000, 0x0001, 0x7FFF, 0x4242, 0xF00D };
    var dst16 = [_]u16{0} ** src16.len;
    const fill32 = [_]u32{0xCAFEBABE};
    var fdst32 = [_]u32{0} ** 12;
    const fill16 = [_]u16{0xBEEF};
    var fdst16 = [_]u16{0} ** 20;
    var z = [_]u32{0xABCD} ** 4; // count == 0 must not write (the readback stays the zeroed destination)
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(&src32), .dest = bytes(&dst32), .r2 = src32.len | WORD },
        .{ .src = bytes(&src16), .dest = bytes(&dst16), .r2 = src16.len },
        .{ .src = bytes(&fill32), .dest = bytes(&fdst32), .r2 = fdst32.len | FILL | WORD },
        .{ .src = bytes(&fill16), .dest = bytes(&fdst16), .r2 = fdst16.len | FILL },
        .{ .src = bytes(&fill32), .dest = bytes(&z), .r2 = 0 | WORD },
    };
    a.free(try swi.runMem(a, &cmds));
    try t.checkBytes("copy32", bytes(&src32), bytes(&dst32));
    try t.checkBytes("copy16", bytes(&src16), bytes(&dst16));
    try t.checkEqual("fill32", @as(u32, 0), countNot(u32, &fdst32, 0xCAFEBABE));
    try t.checkEqual("fill16", @as(u32, 0), countNot(u16, &fdst16, 0xBEEF));
    try t.checkEqual("count0", @as(u32, 0), countNot(u32, &z, 0));
}

fn cycles(t: anytype, a: std.mem.Allocator) !void {
    var dz = [_]u32{0} ** 1;
    var d0 = [_]u32{0} ** 64;
    var d1 = [_]u32{0} ** 32;
    var d2 = [_]u32{0} ** 64;
    const want = [_]u32{ 114, 1534, 1216, 902 };
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(timing_src[0..1]), .dest = bytes(&dz), .r2 = 0 | WORD },
        .{ .src = bytes(&timing_src), .dest = bytes(&d0), .r2 = 64 | WORD }, // 32-bit copy, 64 words
        .{ .src = bytes(&timing_src), .dest = bytes(&d1), .r2 = 64 }, // 16-bit copy, 64 halfwords
        .{ .src = bytes(timing_src[0..1]), .dest = bytes(&d2), .r2 = 64 | FILL | WORD }, // 32-bit fill
    };
    const x = try swi.runMem(a, &cmds);
    defer a.free(x);
    inline for (want, 0..) |w, i| try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), w, x[i]);
}

// BIOS-region source: the guard fires (dest untouched) on a calibrated skip-path cycle count.
fn guard(t: anytype, a: std.mem.Allocator) !void {
    var dest = [_]u8{0} ** 64;
    const cyc = try swi.runMem(a, &.{.{ .src = bytes(&timing_src), .dest = &dest, .r2 = 16 | WORD, .src_addr = 0x01000000 }});
    defer a.free(cyc);
    try t.checkEqual("guard nowrite", @as(u32, 0), countNot(u8, &dest, 0));
    try t.checkEqual("guard cyc", @as(u32, 116), cyc[0]);
}

fn degenerate(t: anytype, a: std.mem.Allocator) !void {
    const src = [_]u32{ 0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777, 0x88888888 };
    var dmask = [_]u32{0xABCD} ** 8;
    const fill = [_]u16{0xBEEF};
    var f0 = [_]u16{0xABCD} ** 4;
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(&src), .dest = bytes(&dmask), .r2 = 2 | (1 << 21) | WORD },
        .{ .src = bytes(&fill), .dest = bytes(&f0), .r2 = 0 | FILL },
    };
    a.free(try swi.runMem(a, &cmds));
    try t.checkBytes("countmask", bytes(src[0..2]), bytes(dmask[0..2]));
    try t.checkEqual("countmask tail", @as(u32, 0), countNot(u32, dmask[2..], 0));
    try t.checkEqual("fill16 count0", @as(u32, 0), countNot(u16, &f0, 0));
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try copy(t, a);
    try cycles(t, a);
    try guard(t, a);
    try degenerate(t, a);
}

test "CpuSet copy" {
    try testing.host(copy, std.testing.allocator);
}
test "CpuSet cycles" {
    try testing.host(cycles, std.testing.allocator);
}
test "CpuSet guard" {
    try testing.host(guard, std.testing.allocator);
}
test "CpuSet degenerate" {
    try testing.host(degenerate, std.testing.allocator);
}

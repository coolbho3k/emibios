// SPDX-License-Identifier: MIT
//! ObjAffineSet tests for matrix output and destination stride.
//! The matrix comes from the BIOS sine table, so exact angles are pinned as reference values.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.obj_affine_set_rom };

const Mat = struct { pa: i16, pb: i16, pc: i16, pd: i16 };

fn src(sx: i16, sy: i16, ang: u8) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(i16, b[0..2], sx, .little);
    std.mem.writeInt(i16, b[2..4], sy, .little);
    std.mem.writeInt(u16, b[4..6], @as(u16, ang) << 8, .little); // only the high byte of theta is used
    std.mem.writeInt(u16, b[6..8], 0, .little);
    return b;
}

fn matAt(dest: []const u8, stride: usize) Mat {
    return .{
        .pa = std.mem.readInt(i16, dest[0 * stride ..][0..2], .little),
        .pb = std.mem.readInt(i16, dest[1 * stride ..][0..2], .little),
        .pc = std.mem.readInt(i16, dest[2 * stride ..][0..2], .little),
        .pd = std.mem.readInt(i16, dest[3 * stride ..][0..2], .little),
    };
}

// 4-byte aligned, comptime const so the timing source sits in cart ROM (the measured region).
const src_timing: [8]u8 align(4) = src(0x100, 0x100, 0x30);

const Card = struct { ang: u8, m: Mat };
const cardinal = [_]Card{
    .{ .ang = 0x00, .m = .{ .pa = 0x100, .pb = 0, .pc = 0, .pd = 0x100 } }, // identity
    .{ .ang = 0x20, .m = .{ .pa = 0xb5, .pb = -0xb5, .pc = 0xb5, .pd = 0xb5 } }, // 45 deg
    .{ .ang = 0x40, .m = .{ .pa = 0, .pb = -0x100, .pc = 0x100, .pd = 0 } }, // 90 deg
    .{ .ang = 0x80, .m = .{ .pa = -0x100, .pb = 0, .pc = 0, .pd = -0x100 } }, // 180 deg
    .{ .ang = 0xc0, .m = .{ .pa = 0, .pb = 0x100, .pc = -0x100, .pd = 0 } }, // 270 deg
};

// Equal scales produce a scaled rotation (Pa == Pd, Pb == -Pc) over the whole circle.
fn structure(t: anytype, a: std.mem.Allocator) !void {
    const N = 64;
    var srcs: [N][8]u8 = undefined;
    var dests: [N][8]u8 = undefined;
    var cmds: [N]gba.MemCmd = undefined;
    for (0..N) |i| {
        srcs[i] = src(0x100, 0x100, @intCast(i * 4));
        cmds[i] = .{ .src = &srcs[i], .dest = &dests[i], .r2 = 1, .r3 = 2 };
    }
    a.free(try swi.runMem(a, &cmds));
    var fails: u32 = 0;
    for (0..N) |i| {
        const m = matAt(&dests[i], 2);
        if (m.pa != m.pd or (m.pb +% m.pc) != 0) {
            if (fails == 0) t.info("objaffine ang {d}: pa={d} pb={d} pc={d} pd={d}\n", .{ i * 4, m.pa, m.pb, m.pc, m.pd });
            fails += 1;
        }
    }
    try t.checkEqual("structure", @as(u32, 0), fails);
}

// Cardinal angles.
fn angles(t: anytype, a: std.mem.Allocator) !void {
    var srcs: [cardinal.len][8]u8 = undefined;
    var dests: [cardinal.len][8]u8 = undefined;
    var cmds: [cardinal.len]gba.MemCmd = undefined;
    for (cardinal, 0..) |c, i| {
        srcs[i] = src(0x100, 0x100, c.ang);
        cmds[i] = .{ .src = &srcs[i], .dest = &dests[i], .r2 = 1, .r3 = 2 };
    }
    a.free(try swi.runMem(a, &cmds));
    inline for (cardinal, 0..) |c, i| {
        const m = matAt(&dests[i], 2);
        try t.checkEqual(std.fmt.comptimePrint("ang 0x{X} pa", .{c.ang}), c.m.pa, m.pa);
        try t.checkEqual(std.fmt.comptimePrint("ang 0x{X} pb", .{c.ang}), c.m.pb, m.pb);
        try t.checkEqual(std.fmt.comptimePrint("ang 0x{X} pc", .{c.ang}), c.m.pc, m.pc);
        try t.checkEqual(std.fmt.comptimePrint("ang 0x{X} pd", .{c.ang}), c.m.pd, m.pd);
    }
}

// OAM stride stores the four params at +0, +8, +16, +24: same matrix as stride 2.
fn strides(t: anytype, a: std.mem.Allocator) !void {
    var s2 = src(0x100, 0x80, 0x30);
    var s8 = src(0x100, 0x80, 0x30);
    var d2: [8]u8 = undefined;
    var d8 = [_]u8{0} ** 32;
    var cmds = [_]gba.MemCmd{
        .{ .src = &s2, .dest = &d2, .r2 = 1, .r3 = 2 },
        .{ .src = &s8, .dest = &d8, .r2 = 1, .r3 = 8 },
    };
    a.free(try swi.runMem(a, &cmds));
    const m2 = matAt(&d2, 2);
    const m8 = matAt(&d8, 8);
    try t.checkEqual("stride pa", m2.pa, m8.pa);
    try t.checkEqual("stride pb", m2.pb, m8.pb);
    try t.checkEqual("stride pc", m2.pc, m8.pc);
    try t.checkEqual("stride pd", m2.pd, m8.pd);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var dest: [8]u8 = undefined;
    const x = try swi.runMem(a, &.{.{ .src = &src_timing, .dest = &dest, .r2 = 1, .r3 = 2 }});
    defer a.free(x);
    try t.checkEqual("cyc", @as(u32, 169), x[0]);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try structure(t, a);
    try angles(t, a);
    try strides(t, a);
    try cyc(t, a);
}

test "ObjAffineSet structure" {
    try testing.host(structure, std.testing.allocator);
}
test "ObjAffineSet angles" {
    try testing.host(angles, std.testing.allocator);
}
test "ObjAffineSet strides" {
    try testing.host(strides, std.testing.allocator);
}
test "ObjAffineSet cyc" {
    try testing.host(cyc, std.testing.allocator);
}

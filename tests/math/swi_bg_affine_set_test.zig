// SPDX-License-Identifier: MIT
//! BgAffineSet tests for matrix output and start-coordinate displacement.
//! The matrix comes from the BIOS sine table; displacement is exact math from that matrix.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.bg_affine_set_rom };

const Src = struct { cx: i32, cy: i32, dispx: i16, dispy: i16, sx: i16, sy: i16, ang: u8 };

fn pack(s: Src) [20]u8 {
    var b: [20]u8 = undefined;
    std.mem.writeInt(i32, b[0..4], s.cx, .little);
    std.mem.writeInt(i32, b[4..8], s.cy, .little);
    std.mem.writeInt(i16, b[8..10], s.dispx, .little);
    std.mem.writeInt(i16, b[10..12], s.dispy, .little);
    std.mem.writeInt(i16, b[12..14], s.sx, .little);
    std.mem.writeInt(i16, b[14..16], s.sy, .little);
    std.mem.writeInt(u16, b[16..18], @as(u16, s.ang) << 8, .little);
    std.mem.writeInt(u16, b[18..20], 0, .little);
    return b;
}

const Dest = struct { pa: i16, pb: i16, pc: i16, pd: i16, dx: i32, dy: i32 };

fn unpack(d: []const u8) Dest {
    return .{
        .pa = std.mem.readInt(i16, d[0..2], .little),
        .pb = std.mem.readInt(i16, d[2..4], .little),
        .pc = std.mem.readInt(i16, d[4..6], .little),
        .pd = std.mem.readInt(i16, d[6..8], .little),
        .dx = std.mem.readInt(i32, d[8..12], .little),
        .dy = std.mem.readInt(i32, d[12..16], .little),
    };
}

// 4-byte aligned: BgAffineSrc.cx/cy are i32, so the BIOS reads words from r0. A comptime const so the
// timing source sits in cart ROM (the region the pinned cycle count was measured against).
const src_timing: [20]u8 align(4) = pack(.{ .cx = 0x10000, .cy = 0x10000, .dispx = 120, .dispy = 80, .sx = 0x100, .sy = 0x100, .ang = 0x30 });

const Ref = struct { s: Src, pa: i16, pb: i16, pc: i16, pd: i16 };
const refs = [_]Ref{
    .{ .s = .{ .cx = 0x10000, .cy = 0x10000, .dispx = 120, .dispy = 80, .sx = 0x100, .sy = 0x100, .ang = 0x00 }, .pa = 0x100, .pb = 0, .pc = 0, .pd = 0x100 },
    .{ .s = .{ .cx = 0x10000, .cy = 0x10000, .dispx = 120, .dispy = 80, .sx = 0x100, .sy = 0x100, .ang = 0x40 }, .pa = 0, .pb = -0x100, .pc = 0x100, .pd = 0 },
    .{ .s = .{ .cx = -0x8000, .cy = 0x20000, .dispx = 120, .dispy = 80, .sx = 0x200, .sy = 0x80, .ang = 0x80 }, .pa = -0x200, .pb = 0, .pc = 0, .pd = -0x80 },
};

// Matrix params (reference) plus displacement (exact integer math from the matrix).
fn matrix(t: anytype, a: std.mem.Allocator) !void {
    var srcs: [refs.len][20]u8 = undefined;
    var dests: [refs.len][16]u8 = undefined;
    var cmds: [refs.len]gba.MemCmd = undefined;
    for (refs, 0..) |c, i| {
        srcs[i] = pack(c.s);
        cmds[i] = .{ .src = &srcs[i], .dest = &dests[i], .r2 = 1 };
    }
    a.free(try swi.runMem(a, &cmds));
    var fails: u32 = 0;
    for (refs, 0..) |c, i| {
        const d = unpack(&dests[i]);
        const want_dx = c.s.cx - (@as(i32, d.pa) * c.s.dispx + @as(i32, d.pb) * c.s.dispy);
        const want_dy = c.s.cy - (@as(i32, d.pc) * c.s.dispx + @as(i32, d.pd) * c.s.dispy);
        if (d.pa != c.pa or d.pb != c.pb or d.pc != c.pc or d.pd != c.pd or d.dx != want_dx or d.dy != want_dy) {
            if (fails == 0) t.info("bgaffine ref[{d}]: pa={d} pb={d} pc={d} pd={d} dx={d} dy={d}, want pa={d} pb={d} pc={d} pd={d} dx={d} dy={d}\n", .{
                i, d.pa, d.pb, d.pc, d.pd, d.dx, d.dy, c.pa, c.pb, c.pc, c.pd, want_dx, want_dy,
            });
            fails += 1;
        }
    }
    try t.checkEqual("matrix", @as(u32, 0), fails);
}

// Multiple sources in one call (equal scales -> scaled rotation per slot).
fn slots(t: anytype, a: std.mem.Allocator) !void {
    const srcs = [_]Src{
        .{ .cx = 0x10000, .cy = 0x8000, .dispx = 120, .dispy = 80, .sx = 0x100, .sy = 0x100, .ang = 0x10 },
        .{ .cx = -0x4000, .cy = 0x20000, .dispx = 60, .dispy = 90, .sx = 0x80, .sy = 0x80, .ang = 0x55 },
        .{ .cx = 0x30000, .cy = 0, .dispx = 0, .dispy = 100, .sx = 0x200, .sy = 0x200, .ang = 0xA0 },
    };
    var blob: [3 * 20]u8 = undefined;
    for (srcs, 0..) |s, i| blob[i * 20 ..][0..20].* = pack(s);
    var dest: [3 * 16]u8 = undefined;
    a.free(try swi.runMem(a, &.{.{ .src = &blob, .dest = &dest, .r2 = 3 }}));
    var fails: u32 = 0;
    for (srcs, 0..) |s, i| {
        const d = unpack(dest[i * 16 ..][0..16]);
        const want_dx = s.cx - (@as(i32, d.pa) * s.dispx + @as(i32, d.pb) * s.dispy);
        const want_dy = s.cy - (@as(i32, d.pc) * s.dispx + @as(i32, d.pd) * s.dispy);
        if (d.pa != d.pd or (d.pb +% d.pc) != 0 or d.dx != want_dx or d.dy != want_dy) {
            if (fails == 0) t.info("bgaffine slot {d}: pa={d} pb={d} pc={d} pd={d} dx={d} dy={d}, want dx={d} dy={d}\n", .{
                i, d.pa, d.pb, d.pc, d.pd, d.dx, d.dy, want_dx, want_dy,
            });
            fails += 1;
        }
    }
    try t.checkEqual("slots", @as(u32, 0), fails);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var dest: [16]u8 = undefined;
    const x = try swi.runMem(a, &.{.{ .src = &src_timing, .dest = &dest, .r2 = 1 }});
    defer a.free(x);
    try t.checkEqual("cyc", @as(u32, 232), x[0]);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try matrix(t, a);
    try slots(t, a);
    try cyc(t, a);
}

test "BgAffineSet matrix" {
    try testing.host(matrix, std.testing.allocator);
}
test "BgAffineSet slots" {
    try testing.host(slots, std.testing.allocator);
}
test "BgAffineSet cyc" {
    try testing.host(cyc, std.testing.allocator);
}

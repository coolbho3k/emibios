// SPDX-License-Identifier: MIT
//! GetBiosChecksum tests.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.get_bios_checksum_rom };

fn fingerprint(t: anytype, a: std.mem.Allocator) !void {
    const res = try swi.run(a, &.{.{ .r2 = 0xABCDEF12 }});
    defer a.free(res);
    try t.checkEqual("fingerprint", @as(u32, 0xBAAE187F), res[0].r0);
    try t.checkEqual("r1", @as(u32, 1), res[0].r1);
    try t.checkEqual("r2", @as(u32, 0xABCDEF12), res[0].r2);
    try t.checkEqual("r3", @as(u32, 0x4000), res[0].r3);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    const tm = try swi.run(a, &.{.{}});
    defer a.free(tm);
    try t.checkEqual("cyc", @as(u32, 41042), tm[0].cycles);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try fingerprint(t, a);
    try cyc(t, a);
}

test "GetBiosChecksum fingerprint" {
    try testing.host(fingerprint, std.testing.allocator);
}
test "GetBiosChecksum cyc" {
    try testing.host(cyc, std.testing.allocator);
}

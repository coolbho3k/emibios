// SPDX-License-Identifier: MIT
//! Shared helpers for the decompression SWI tests. Each runs an already-compressed buffer through the
//! platform's testing shim `t` and (for roundtrip/guard) frees `comp`, so each per-codec file only
//! supplies its codec and fixtures. `timing` takes a comptime-const `comp` (in cart ROM, for cycle parity).
const std = @import("std");
const gba = @import("gba");

const GUARD = 4; // trailing destination bytes that must stay zero (overrun check)

fn countNonZero(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |b| {
        if (b != 0) n += 1;
    }
    return n;
}

// Row label: a variant prefix ("wram", "8w", ...) plus the check, or just the check when unprefixed.
fn label(comptime tag: []const u8, comptime check: []const u8) []const u8 {
    return if (tag.len == 0) check else tag ++ " " ++ check;
}

// One indexed row per fixture: decompressing `comp` must yield exactly `data` and write nothing past it
// (the GUARD tail stays zero, so a wrong length or an overrun fails too). `tag` names the SWI variant.
pub fn roundtrip(t: anytype, a: std.mem.Allocator, comptime tag: []const u8, comptime idx: usize, comptime swi: gba.Swi, comp: []const u8, data: []const u8) !void {
    defer a.free(comp);
    const dest = try a.alloc(u8, data.len + GUARD);
    defer a.free(dest);
    a.free(try swi.runMem(a, &.{.{ .src = comp, .dest = dest }}));
    const want = try a.alloc(u8, data.len + GUARD);
    defer a.free(want);
    @memcpy(want[0..data.len], data);
    @memset(want[data.len..], 0);
    try t.checkBytes(label(tag, std.fmt.comptimePrint("roundtrip[{d}]", .{idx})), want, dest);
}

pub fn timing(t: anytype, a: std.mem.Allocator, name: []const u8, comptime swi: gba.Swi, comp: []const u8, dest_len: usize, want: u32) !void {
    const dest = try a.alloc(u8, dest_len);
    defer a.free(dest);
    const cyc = try swi.runMem(a, &.{.{ .src = comp, .dest = dest }});
    defer a.free(cyc);
    try t.checkEqual(name, want, cyc[0]);
}

// Source in the BIOS region: the SWI must skip, leaving the destination untouched, at a fixed skip cost.
pub fn guard(t: anytype, a: std.mem.Allocator, comptime tag: []const u8, comptime swi: gba.Swi, comp: []const u8, want: u32) !void {
    defer a.free(comp);
    var dest = [_]u8{0} ** 64;
    const cyc = try swi.runMem(a, &.{.{ .src = comp, .dest = &dest, .src_addr = 0x01000000 }});
    defer a.free(cyc);
    try t.checkEqual(label(tag, "guard nowrite"), @as(u32, 0), countNonZero(&dest));
    try t.checkEqual(label(tag, "guard cyc"), want, cyc[0]);
}

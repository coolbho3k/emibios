// SPDX-License-Identifier: MIT
//! Minimal std.testing like assertion shim. This is so we can share test logic across the host
//! suite and the test ROM.
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("layout");

const rom = builtin.target.os.tag == .freestanding;

pub const Case = struct { name: []const u8, exp: u32, meas: u32, passed: bool };

const Shim = struct {
    record: ?*const fn (Case) void = null, // the ROM installs this (-> addCase). Unused on the host
    suite: []const u8 = "", // name attributed to the un-named expect* variants
    fails: u32 = 0, // host: failed checks in the current test (the ROM records rows to `record` instead)
    buf: [192]u8 = undefined, // failure-message scratch
};
var host_shim: Shim = .{};
// On the ROM, .data/.bss sit in read-only cart ROM, so mutable state lives at a fixed EWRAM address.
const sh: *Shim = if (rom) @ptrFromInt(layout.shim.base) else &host_shim;

pub fn setSink(r: *const fn (Case) void) void {
    sh.record = r;
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!rom) std.debug.print(fmt, args);
}
pub fn setSuite(name: []const u8) void {
    sh.suite = name;
}

/// Host entry: run a body accumulating every check (never aborting on the first), then fail once at the end
/// if any failed. Real errors (harness/allocator) still propagate. The ROM runs the same bodies via setSink.
pub fn host(comptime run_fn: anytype, a: std.mem.Allocator) !void {
    sh.fails = 0;
    try run_fn(@This(), a);
    if (sh.fails != 0) {
        std.debug.print("=> {d} check(s) failed\n", .{sh.fails});
        return error.TestFailed;
    }
}

// Never aborts on a failure: the ROM records each case as a results-table row; the host prints it and bumps the tally.
fn note(name: []const u8, exp: u32, meas: u32, passed: bool, comptime fmt: []const u8, args: anytype) !void {
    if (rom) {
        if (sh.record) |r| r(.{ .name = name, .exp = exp, .meas = meas, .passed = passed });
        return;
    }
    if (!passed) {
        sh.fails += 1;
        const msg = std.fmt.bufPrint(&sh.buf, fmt, args) catch "(message too long)";
        std.debug.print("FAIL {s}: {s}\n", .{ name, msg });
    }
}

fn scalar(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => @intFromBool(v),
        .@"enum" => @intFromEnum(v),
        .int, .comptime_int => @bitCast(@as(i32, @truncate(@as(i64, v)))),
        else => 0,
    };
}

fn sum(comptime T: type, s: []const T) u32 {
    var acc: u32 = 0;
    for (s) |e| acc +%= scalar(e);
    return acc;
}

fn sliceEql(comptime T: type, name: []const u8, expected: []const T, actual: []const T) !void {
    var ok = expected.len == actual.len;
    if (ok) for (expected, actual) |e, b| {
        if (e != b) {
            ok = false;
            break;
        }
    };
    try note(name, sum(T, expected), sum(T, actual), ok, "slices differ (len {d} vs {d})", .{ expected.len, actual.len });
}

pub fn expect(ok: bool) !void {
    try note(sh.suite, 1, @intFromBool(ok), ok, "expected true, found false", .{});
}
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try note(sh.suite, scalar(expected), scalar(actual), expected == actual, "expected {any}, found {any}", .{ expected, actual });
}
pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    try sliceEql(T, sh.suite, expected, actual);
}
pub fn expectError(expected: anyerror, actual: anytype) !void {
    const ok = if (actual) |_| false else |e| e == expected;
    try note(sh.suite, 0, 0, ok, "expected error.{s}", .{@errorName(expected)});
}

// Named variants of expect/expectEqual: pass an explicit row name instead of the suite name.
pub fn checkEqual(name: []const u8, expected: anytype, actual: anytype) !void {
    try note(name, scalar(expected), scalar(actual), expected == actual, "expected {any}, found {any}", .{ expected, actual });
}
pub fn checkBytes(name: []const u8, expected: []const u8, actual: []const u8) !void {
    try sliceEql(u8, name, expected, actual);
}

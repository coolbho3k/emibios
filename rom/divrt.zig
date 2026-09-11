// SPDX-License-Identifier: MIT
//! Minimal compiler-rt for the test ROM
fn u32div(n: u32, d: u32) struct { q: u32, r: u32 } {
    if (d == 0) return .{ .q = 0, .r = n };
    var q: u32 = 0;
    var r: u32 = 0;
    var i: u6 = 32;
    while (i > 0) {
        i -= 1;
        r = (r << 1) | ((n >> @intCast(i)) & 1);
        if (r >= d) {
            r -= d;
            q |= @as(u32, 1) << @intCast(i);
        }
    }
    return .{ .q = q, .r = r };
}

fn divI32(n: i32, d: i32) i32 {
    const sign: u32 = @bitCast((n ^ d) >> 31);
    const an: u32 = @bitCast((n ^ (n >> 31)) -% (n >> 31));
    const ad: u32 = @bitCast((d ^ (d >> 31)) -% (d >> 31));
    return @bitCast((u32div(an, ad).q ^ sign) -% sign);
}

const aapcs = std.builtin.CallingConvention{ .arm_aapcs = .{} };
const std = @import("std");

export fn __aeabi_uidiv(n: u32, d: u32) callconv(aapcs) u32 {
    return u32div(n, d).q;
}
export fn __aeabi_idiv(n: i32, d: i32) callconv(aapcs) i32 {
    return divI32(n, d);
}
export fn __aeabi_uidivmod(n: u32, d: u32) callconv(aapcs) u64 {
    const x = u32div(n, d);
    return @as(u64, x.q) | (@as(u64, x.r) << 32);
}
export fn __aeabi_idivmod(n: i32, d: i32) callconv(aapcs) u64 {
    const q = divI32(n, d);
    const r = n -% q *% d;
    return @as(u64, @as(u32, @bitCast(q))) | (@as(u64, @as(u32, @bitCast(r))) << 32);
}

export fn __aeabi_memcpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) void {
    for (0..n) |i| dest[i] = src[i];
}
export fn __aeabi_memcpy4(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) void {
    for (0..n) |i| dest[i] = src[i];
}
export fn __aeabi_memset(dest: [*]u8, n: usize, c: i32) callconv(.c) void {
    const b: u8 = @truncate(@as(u32, @bitCast(c)));
    for (0..n) |i| dest[i] = b;
}
export fn __aeabi_memclr(dest: [*]u8, n: usize) callconv(.c) void {
    for (0..n) |i| dest[i] = 0;
}
export fn __aeabi_memclr4(dest: [*]u8, n: usize) callconv(.c) void {
    for (0..n) |i| dest[i] = 0;
}
export fn __aeabi_memclr8(dest: [*]u8, n: usize) callconv(.c) void {
    for (0..n) |i| dest[i] = 0;
}

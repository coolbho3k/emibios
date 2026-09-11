// SPDX-License-Identifier: MIT
//! Native SWI executor and TM0 cycle timing for the test ROM
const std = @import("std");
const protocol = @import("protocol");
const layout = @import("layout");

pub const Cmd = protocol.Cmd;
pub const Result = protocol.Result;
pub const MemCmd = protocol.MemCmd;

pub const Swi = struct {
    bios_path: []const u8 = "",
    target: u8 = 0,

    pub fn run(comptime self: Swi, allocator: std.mem.Allocator, cmds: []const Cmd) ![]Result {
        const out = try allocator.alloc(Result, cmds.len);
        for (cmds, out) |c, *r| {
            var in = c;
            if (c.r0_buf) |b| in.r0 = @intFromPtr(b.ptr);
            r.* = execReg(self.target, in);
        }
        return out;
    }

    pub fn runMem(comptime self: Swi, allocator: std.mem.Allocator, cmds: []const MemCmd) ![]u32 {
        const cycles = try allocator.alloc(u32, cmds.len);
        const d: [*]volatile u8 = @ptrFromInt(MEM_DEST);
        for (cmds, cycles) |cmd, *cyc| {
            const r2v = if (cmd.r2_ptr) |p| @as(u32, @intFromPtr(p.ptr)) else cmd.r2;
            if (cmd.src_addr) |sa| {
                for (0..cmd.dest.len) |j| d[j] = 0;
                cyc.* = execAt(self.target, sa, MEM_DEST, r2v, cmd.r3);
            } else {
                cyc.* = execMem(self.target, cmd.src, cmd.dest.len, r2v, cmd.r3).cycles;
            }
            for (cmd.dest, 0..) |*byte, j| byte.* = d[j];
        }
        return cycles;
    }
};

const TM0_L: *volatile u16 = @ptrFromInt(0x04000100);
const TM0_CNT: *volatile u16 = @ptrFromInt(0x04000102);

pub fn timerInit() void {
    TM0_L.* = 0;
    TM0_CNT.* = 0x0080;
}

// Implements udiv with SWI 0x06
pub fn udiv(num: u32, den: u32) struct { q: u32, r: u32 } {
    var q: u32 = num; // r0 = numerator
    var rem: u32 = den; // r1 = denominator
    asm volatile ("swi %[n]"
        : [q] "+{r0}" (q),
          [rr] "+{r1}" (rem),
        : [n] "i" (@as(u32, 6) << 16),
        : .{ .memory = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
    return .{ .q = q, .r = rem };
}

/// Cycles are measured against ldrh/swi/ldrh timing bracket
pub fn execReg(comptime n: u8, in: Cmd) Result {
    var r0: u32 = in.r0;
    var r1: u32 = in.r1;
    var r2: u32 = in.r2;
    var r3: u32 = in.r3;
    var before: u32 = undefined;
    var after: u32 = undefined;
    asm volatile (
        \\ldrh %[before], [%[tm]]
        \\swi %[num]
        \\ldrh %[after], [%[tm]]
        : [r0] "+{r0}" (r0),
          [r1] "+{r1}" (r1),
          [r2] "+{r2}" (r2),
          [r3] "+{r3}" (r3),
          [before] "=&r" (before),
          [after] "=&r" (after),
        : [num] "i" (@as(u32, n) << 16),
          [tm] "r" (@as(u32, 0x04000100)),
        : .{ .memory = true, .r12 = true, .lr = true, .cpsr = true });
    return .{ .r0 = r0, .r1 = r1, .r2 = r2, .r3 = r3, .cycles = (after -% before) & 0xFFFF };
}

const MEM_DEST: u32 = layout.mem_dest.base;

/// Execute a memory SWI `n` with src/dst addresses
pub fn execAt(comptime n: u8, src: u32, dst: u32, r2: u32, r3: u32) u32 {
    var r0v: u32 = src;
    var r1v: u32 = dst;
    var r2v: u32 = r2;
    var r3v: u32 = r3;
    var before: u32 = undefined;
    var after: u32 = undefined;
    asm volatile (
        \\ldrh %[before], [%[tm]]
        \\swi %[num]
        \\ldrh %[after], [%[tm]]
        : [r0] "+{r0}" (r0v),
          [r1] "+{r1}" (r1v),
          [r2] "+{r2}" (r2v),
          [r3] "+{r3}" (r3v),
          [before] "=&r" (before),
          [after] "=&r" (after),
        : [num] "i" (@as(u32, n) << 16),
          [tm] "r" (@as(u32, 0x04000100)),
        : .{ .memory = true, .r12 = true, .lr = true, .cpsr = true });
    return (after -% before) & 0xFFFF;
}

/// Execute a memory SWI `n` (CpuSet/CpuFastSet/LZ77/Huff/RL/Diff/BitUnPack)
pub fn execMem(comptime n: u8, src: []const u8, dest_len: usize, r2: u32, r3: u32) struct { cycles: u32, dest: [*]volatile u8 } {
    const d: [*]volatile u8 = @ptrFromInt(MEM_DEST);
    var i: usize = 0;
    while (i < dest_len) : (i += 1) d[i] = 0;
    var r0v: u32 = @intFromPtr(src.ptr);
    var r1v: u32 = MEM_DEST;
    var r2v: u32 = r2;
    var r3v: u32 = r3;
    var before: u32 = undefined;
    var after: u32 = undefined;
    asm volatile (
        \\ldrh %[before], [%[tm]]
        \\swi %[num]
        \\ldrh %[after], [%[tm]]
        : [r0] "+{r0}" (r0v),
          [r1] "+{r1}" (r1v),
          [r2] "+{r2}" (r2v),
          [r3] "+{r3}" (r3v),
          [before] "=&r" (before),
          [after] "=&r" (after),
        : [num] "i" (@as(u32, n) << 16),
          [tm] "r" (@as(u32, 0x04000100)),
        : .{ .memory = true, .r12 = true, .lr = true, .cpsr = true });
    return .{ .cycles = (after -% before) & 0xFFFF, .dest = d };
}

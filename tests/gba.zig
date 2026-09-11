// SPDX-License-Identifier: MIT
//! Shared emulator harness for SWI tests.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const protocol = @import("protocol");

const CMD_OFF: usize = protocol.CMD_OFF;
const CMD_STRIDE: usize = protocol.CMD_STRIDE;
const RES_OFF: u32 = protocol.RES_OFF;
const RES_STRIDE: u32 = protocol.RES_STRIDE;
const DONE_MAGIC: u32 = protocol.DONE_MAGIC;
const MAX_FRAMES: usize = 600;
// Padded cart length
const CART_LEN: usize = 0x100000;

pub const Cmd = protocol.Cmd;
pub const Result = protocol.Result;
pub const MemCmd = protocol.MemCmd;

/// A candidate BIOS plus the harness ROM assembled for one SWI number.
pub const Swi = struct {
    bios_path: []const u8,
    target: []const u8,

    /// Boots the BIOS and returns one result per command. Caller owns the slice.
    pub fn run(self: Swi, allocator: std.mem.Allocator, cmds: []const Cmd) ![]Result {
        const bios = try iface.readFile(allocator, self.bios_path);
        defer allocator.free(bios);
        const rom = try iface.readFile(allocator, self.target);
        defer allocator.free(rom);
        return runSwi(allocator, rom, bios, cmds);
    }

    /// Runs memory-style SWIs and copies each EWRAM destination into the command buffer.
    pub fn runMem(self: Swi, allocator: std.mem.Allocator, cmds: []const MemCmd) ![]u32 {
        const bios = try iface.readFile(allocator, self.bios_path);
        defer allocator.free(bios);
        const rom = try iface.readFile(allocator, self.target);
        defer allocator.free(rom);
        return runMemSwi(allocator, rom, bios, cmds);
    }
};

// One reused cart buffer (patched per case) and one reused core (created once, re-booted per case).
var g_cart: ?[]u8 = null;
fn cartBuf(template: []const u8) []u8 {
    const buf = g_cart orelse blk: {
        const b = std.heap.page_allocator.alloc(u8, CART_LEN) catch @panic("test: cart alloc");
        g_cart = b;
        break :blk b;
    };
    @memcpy(buf[0..template.len], template);
    @memset(buf[template.len..], 0);
    return buf;
}

var g_core: ?emu.Core = null;
/// Boots the BIOS and patched cart, then waits for DONE. Returns the process-wide core.
fn boot(cart: []const u8, bios: []const u8) !*emu.Core {
    if (g_core == null) g_core = try emu.Core.create(std.heap.page_allocator);
    const core = &g_core.?;
    try core.boot(bios, cart);
    var f: usize = 0;
    while (f < MAX_FRAMES) : (f += 1) {
        core.frameAdvance(.{}); // no buttons held
        if (iface.readWord(core, .wram, 0) == DONE_MAGIC) return core;
    }
    return error.HarnessTimeout;
}

/// Runs register commands through the harness SWI. Caller owns the returned slice.
pub fn runSwi(allocator: std.mem.Allocator, template: []const u8, bios: []const u8, cmds: []const Cmd) ![]Result {
    const rom = cartBuf(template);
    std.debug.assert(RES_OFF + cmds.len * RES_STRIDE <= MEM_DEST - 0x02000000);
    std.mem.writeInt(u32, rom[CMD_OFF..][0..4], @intCast(cmds.len), .little);
    var off: usize = CMD_OFF + 4;
    var buf_off: usize = CMD_OFF + 4 + cmds.len * CMD_STRIDE; // r0 buffers follow the command table
    for (cmds) |c| {
        var r0 = c.r0;
        if (c.r0_buf) |b| {
            r0 = @intCast(0x08000000 + buf_off);
            @memcpy(rom[buf_off..][0..b.len], b);
            buf_off += std.mem.alignForward(usize, b.len, 4);
        }
        for ([_]u32{ r0, c.r1, c.r2, c.r3 }) |v| {
            std.mem.writeInt(u32, rom[off..][0..4], v, .little);
            off += 4;
        }
    }
    const core = try boot(rom[0..CART_LEN], bios);
    const out = try allocator.alloc(Result, cmds.len);
    for (out, 0..) |*r, i| {
        const b: u32 = @intCast(RES_OFF + i * RES_STRIDE);
        r.* = .{
            .r0 = iface.readWord(core, .wram, b),
            .r1 = iface.readWord(core, .wram, b + 4),
            .r2 = iface.readWord(core, .wram, b + 8),
            .r3 = iface.readWord(core, .wram, b + 12),
            .cycles = iface.readWord(core, .wram, b + 16),
        };
    }
    return out;
}

const MEM_DEST: u32 = 0x02010000; // EWRAM base for destinations (past the result table at 0x02000004)
const MEM_STRIDE: u32 = 0x800; // per-case destination spacing

/// Runs memory-style commands and returns one cycle count per command.
/// Caller owns the returned slice.
pub fn runMemSwi(allocator: std.mem.Allocator, template: []const u8, bios: []const u8, cmds: []const MemCmd) ![]u32 {
    const rom = cartBuf(template);
    const n = cmds.len;
    std.debug.assert(RES_OFF + n * RES_STRIDE <= MEM_DEST - 0x02000000);
    std.mem.writeInt(u32, rom[CMD_OFF..][0..4], @intCast(n), .little);
    var src_off: usize = CMD_OFF + 4 + n * CMD_STRIDE; // source buffers follow the command table
    for (cmds, 0..) |cmd, i| {
        std.debug.assert(cmd.dest.len <= MEM_STRIDE);
        const co = CMD_OFF + 4 + i * CMD_STRIDE;
        const src_ptr = cmd.src_addr orelse @as(u32, @intCast(0x08000000 + src_off));
        @memcpy(rom[src_off..][0..cmd.src.len], cmd.src);
        src_off += std.mem.alignForward(usize, cmd.src.len, 4);
        var r2_val = cmd.r2;
        if (cmd.r2_ptr) |ptr| {
            r2_val = @intCast(0x08000000 + src_off);
            @memcpy(rom[src_off..][0..ptr.len], ptr);
            src_off += std.mem.alignForward(usize, ptr.len, 4);
        }
        std.mem.writeInt(u32, rom[co..][0..4], src_ptr, .little);
        std.mem.writeInt(u32, rom[co + 4 ..][0..4], MEM_DEST + @as(u32, @intCast(i)) * MEM_STRIDE, .little);
        std.mem.writeInt(u32, rom[co + 8 ..][0..4], r2_val, .little);
        std.mem.writeInt(u32, rom[co + 12 ..][0..4], cmd.r3, .little);
    }
    const core = try boot(rom[0..CART_LEN], bios);
    const cycles = try allocator.alloc(u32, n);
    for (cmds, 0..) |cmd, i| {
        cycles[i] = iface.readWord(core, .wram, @intCast(RES_OFF + i * RES_STRIDE + 16));
        const base: u32 = (MEM_DEST - 0x02000000) + @as(u32, @intCast(i)) * MEM_STRIDE;
        for (cmd.dest, 0..) |*byte, j| byte.* = core.read(.wram, base + @as(u32, @intCast(j)));
    }
    return cycles;
}

/// Reads a BIOS or ROM image. Caller owns the bytes.
pub const readFile = iface.readFile;

// SPDX-License-Identifier: MIT
//! Core-agnostic emulator interface
const std = @import("std");

pub const Region = enum { wram, iwram, ioregs, pram, oam, vram };

// GBA KEYINPUT is active-low (0x3FF = nothing held).
pub const Input = struct {
    buttons: u16 = 0x3FF,
    render: bool = true,
    sound: bool = true,
    accx: u16 = 0,
    accy: u16 = 0,
    solar: u8 = 0,
};

pub const Handoff = struct { cycle: u64, pc: u32 };

// The Core contract. Each backend asserts it with `comptime iface.verify(Core)`.
pub fn verify(comptime Core: type) void {
    const req = .{
        .{ "create", "fn(std.mem.Allocator) anyerror!Core" },
        .{ "deinit", "fn(*Core) void" },
        .{ "boot", "fn(*Core, []const u8, []const u8) anyerror!void" },
        .{ "frameAdvance", "fn(*Core, Input) void" },
        .{ "runToHandoff", "fn(*Core, u64) Handoff" },
        .{ "read", "fn(*const Core, Region, u32) u8" },
        .{ "getRegs", "fn(*const Core) [16]u32" },
        .{ "getBiosLatch", "fn(*const Core) u32" },
    };
    inline for (req) |m| {
        if (!@hasDecl(Core, m[0]))
            @compileError("emu backend " ++ @typeName(Core) ++ " missing `" ++ m[0] ++ "` (" ++ m[1] ++ ")");
    }
}

pub fn readWord(core: anytype, region: Region, off: u32) u32 {
    return @as(u32, core.read(region, off)) |
        @as(u32, core.read(region, off + 1)) << 8 |
        @as(u32, core.read(region, off + 2)) << 16 |
        @as(u32, core.read(region, off + 3)) << 24;
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, alloc, .limited(0x6000000));
}

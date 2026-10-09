// SPDX-License-Identifier: MIT
//! mGBA backend for the emu interface
const std = @import("std");
const iface = @import("iface");
const Region = iface.Region;
const Input = iface.Input;
const Handoff = iface.Handoff;

const Raw = opaque {};

// tools/emu/mgba_export.c
extern fn MG_create() ?*Raw;
extern fn MG_destroy(*Raw) void;
extern fn MG_boot(*Raw, [*]const u8, usize, [*]const u8, usize) void; // bios ptr/len, cart ptr/len
extern fn MG_frame(*Raw, u16) void; // buttons
extern fn MG_read(*Raw, u8, u32) u8; // region tag, offset
extern fn MG_run_to_handoff(*Raw, u64, *u32) u64; // stops when PC first enters cart ROM
extern fn MG_get_regs(*Raw, [*]u32) void; // r0-r15
extern fn MG_get_biosread(*Raw) u32; // open bus BIOS read latch

fn regionTag(region: Region) u8 {
    return switch (region) {
        .wram => 0,
        .iwram => 1,
        .ioregs => 2,
        .pram => 3,
        .oam => 4,
        .vram => 5,
    };
}

pub const Core = struct {
    p: *Raw,

    pub fn create(alloc: std.mem.Allocator) !Core {
        _ = alloc; // mGBA owns its buffers
        return .{ .p = MG_create() orelse return error.MgbaCreate };
    }

    pub fn deinit(self: *Core) void {
        MG_destroy(self.p);
    }

    pub fn boot(self: *Core, bios: []const u8, romf: []const u8) !void {
        MG_boot(self.p, bios.ptr, bios.len, romf.ptr, romf.len);
    }

    // mGBA here has no renderer and its audio is not drained, so render and sound are ignored.
    pub fn frameAdvance(self: *Core, in: Input) void {
        MG_frame(self.p, in.buttons);
    }

    pub fn runToHandoff(self: *Core, cap: u64) Handoff {
        var pc: u32 = 0;
        const cyc = MG_run_to_handoff(self.p, cap, &pc);
        return .{ .cycle = cyc, .pc = pc };
    }

    pub fn read(self: *const Core, region: Region, off: u32) u8 {
        return MG_read(self.p, regionTag(region), off);
    }

    pub fn getRegs(self: *const Core) [16]u32 {
        var regs: [16]u32 = undefined;
        MG_get_regs(self.p, &regs);
        return regs;
    }

    pub fn getBiosLatch(self: *const Core) u32 {
        return MG_get_biosread(self.p);
    }
};

comptime {
    iface.verify(Core);
}

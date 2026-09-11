// SPDX-License-Identifier: MIT
//! MesenCE backend for the emu interface
const std = @import("std");
const iface = @import("iface");
const Region = iface.Region;
const Input = iface.Input;
const Handoff = iface.Handoff;

const Raw = opaque {};

extern fn Mesen_create() ?*Raw;
extern fn Mesen_destroy(*Raw) void;
extern fn Mesen_boot(*Raw, [*]const u8, usize, [*]const u8, usize) void; // bios ptr/len, cart ptr/len
extern fn Mesen_frame(*Raw, u16, u8, u8) void; // buttons, render, sound
extern fn Mesen_read(*Raw, u8, u32) u8; // region tag, offset
extern fn Mesen_run_to_handoff(*Raw, u64, *u32) u64;
extern fn Mesen_get_regs(*Raw, [*]u32) void;

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
        _ = alloc; // MesenCE owns its buffers
        return .{ .p = Mesen_create() orelse return error.MesenCreate };
    }

    pub fn deinit(self: *Core) void {
        Mesen_destroy(self.p);
    }

    pub fn boot(self: *Core, bios: []const u8, romf: []const u8) !void {
        Mesen_boot(self.p, bios.ptr, bios.len, romf.ptr, romf.len);
    }

    pub fn frameAdvance(self: *Core, in: Input) void {
        if (in.buttons != 0x3FF) @panic("mesence: controller input is not implemented in the shim");
        Mesen_frame(self.p, in.buttons, @intFromBool(in.render), @intFromBool(in.sound));
    }

    pub fn runToHandoff(self: *Core, cap: u64) Handoff {
        var pc: u32 = 0;
        const cyc = Mesen_run_to_handoff(self.p, cap, &pc);
        return .{ .cycle = cyc, .pc = pc };
    }

    pub fn read(self: *const Core, region: Region, off: u32) u8 {
        if (region == .ioregs) @panic("mesence: MesenCE has no dumpable IO region");
        return Mesen_read(self.p, regionTag(region), off);
    }

    pub fn getRegs(self: *const Core) [16]u32 {
        var regs: [16]u32 = undefined;
        Mesen_get_regs(self.p, &regs);
        return regs;
    }

    pub fn getBiosLatch(self: *const Core) u32 {
        _ = self;
        @panic("mesence: the BIOS open-bus latch is not exposed by the shim");
    }
};

comptime {
    iface.verify(Core);
}

// SPDX-License-Identifier: MIT
//! GBAHawk backend for the emu interface
const std = @import("std");
const iface = @import("iface");
const Region = iface.Region;
const Input = iface.Input;
const Handoff = iface.Handoff;

const Raw = opaque {};

// Stock GBAHawk core ABI.
extern fn GBA_create() ?*Raw;
extern fn GBA_destroy(*Raw) void;
extern fn GBA_Hard_Reset(*Raw) void;
extern fn GBA_load_bios(*Raw, [*]const u8) void;
extern fn GBA_load(*Raw, [*]const u8, u32, u32, u64, u8, i16, u16, u16, i16, i32, i32, u8) void;
extern fn GBA_create_SRAM(*Raw, [*]u8, u32) void;
extern fn GBA_frame_advance(*Raw, u16, u16, u16, u8, u8, u8) bool;
extern fn GBA_getwram(*Raw, u32) u8;
extern fn GBA_getiwram(*Raw, u32) u8;
extern fn GBA_getregisters(*Raw, u32) u8;
extern fn GBA_getpalram(*Raw, u32) u8;
extern fn GBA_getoam(*Raw, u32) u8;
extern fn GBA_getvram(*Raw, u32) u8;
// Our exports
extern fn GBA_run_to_handoff(*Raw, u16, u64, *u32) u64; // stops when PC first enters cart ROM
extern fn GBA_get_regs(*Raw, [*]u32) void; // r0-r15
extern fn GBA_get_biosread(*Raw) u32; // open-bus BIOS-read latch

// GBAHawk's Load_ROM copies a fixed-size image.
const ROM_BYTES: usize = 0x6000000;

pub const Core = struct {
    p: *Raw,
    alloc: std.mem.Allocator,
    image: []u8, // reused 0x6000000 ROM image (cart bytes + GamePak open-bus tail)
    sram: []u8,
    tail_len: usize = std.math.maxInt(usize), // cart length the open-bus tail was last built for

    pub fn create(alloc: std.mem.Allocator) !Core {
        const image = try alloc.alloc(u8, ROM_BYTES);
        errdefer alloc.free(image);
        @memset(image, 0);
        const sram = try alloc.alloc(u8, 0x20000);
        errdefer alloc.free(sram);
        @memset(sram, 0xFF);
        const p = GBA_create() orelse return error.GbaCreate;
        return .{ .p = p, .alloc = alloc, .image = image, .sram = sram };
    }

    pub fn deinit(self: *Core) void {
        GBA_destroy(self.p);
        self.alloc.free(self.image);
        self.alloc.free(self.sram);
    }

    pub fn boot(self: *Core, bios: []const u8, romf: []const u8) !void {
        @memcpy(self.image[0..romf.len], romf);
        if (self.tail_len != romf.len) { // rebuild the open-bus tail only when the cart length changes
            var ofst: usize = romf.len & 0xF000000;
            if (romf.len > ofst) ofst += 0x1000000;
            @memset(self.image[romf.len..ofst], 0); // gap between cart end and the 16 MiB-aligned tail
            var i: usize = 0;
            while (i + ofst < ROM_BYTES) : (i += 2) {
                self.image[i + ofst] = @intCast((i & 0xFF) >> 1);
                self.image[i + ofst + 1] = @intCast(((i >> 8) & 0xFF) >> 1);
            }
            self.tail_len = romf.len;
        }
        GBA_load_bios(self.p, bios.ptr);
        // Mapper/save-type config for a standard cart.
        GBA_load(self.p, self.image.ptr, @intCast(romf.len), 8, 0x10100000000, 1, 0, 0x1B32, 0x1362, 0, 0, 0, 0);
        GBA_Hard_Reset(self.p); // GBA_load does not clear CPU/RAM state.
        GBA_create_SRAM(self.p, self.sram.ptr, @intCast(self.sram.len));
    }

    pub fn frameAdvance(self: *Core, in: Input) void {
        _ = GBA_frame_advance(self.p, in.buttons, in.accx, in.accy, in.solar, @intFromBool(in.render), @intFromBool(in.sound));
    }

    pub fn runToHandoff(self: *Core, cap: u64) Handoff {
        var pc: u32 = 0;
        const cyc = GBA_run_to_handoff(self.p, 0x3FF, cap, &pc);
        return .{ .cycle = cyc, .pc = pc };
    }

    pub fn read(self: *const Core, region: Region, off: u32) u8 {
        return switch (region) {
            .wram => GBA_getwram(self.p, off),
            .iwram => GBA_getiwram(self.p, off),
            .ioregs => GBA_getregisters(self.p, off),
            .pram => GBA_getpalram(self.p, off),
            .oam => GBA_getoam(self.p, off),
            .vram => GBA_getvram(self.p, off),
        };
    }

    pub fn getRegs(self: *const Core) [16]u32 {
        var regs: [16]u32 = undefined;
        GBA_get_regs(self.p, &regs);
        return regs;
    }

    pub fn getBiosLatch(self: *const Core) u32 {
        return GBA_get_biosread(self.p);
    }
};

comptime {
    iface.verify(Core);
}

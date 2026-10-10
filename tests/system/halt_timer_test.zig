// SPDX-License-Identifier: MIT
//! Timer0 boot leftover and the Halt IRQ return address, after alyosha's gba-tests timer_reset and
//! halt_pc. Drives rom/halt_timer_stub.zig with a patched TM0CNT word and header device type.
//! Expected values are hardware reference measurements.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

const Case = struct { tm0cnt: u32, device: u8, tm0_leftover: u32, irq_lr: u32, tm0_low: u32 };

const cases = [_]Case{
    .{ .tm0cnt = 0x00c0ffa0, .device = 0x00, .tm0_leftover = 0xff8a, .irq_lr = 0x174, .tm0_low = 0xd7 },
    .{ .tm0cnt = 0x00c0ffdc, .device = 0x80, .tm0_leftover = 0xff8b, .irq_lr = 0x174, .tm0_low = 0xf0 },
    .{ .tm0cnt = 0x00c0ffdd, .device = 0x80, .tm0_leftover = 0xff8b, .irq_lr = 0x1b8, .tm0_low = 0xf0 },
    .{ .tm0cnt = 0x00c0ffde, .device = 0x00, .tm0_leftover = 0xff8a, .irq_lr = 0x1b8, .tm0_low = 0xf3 },
};

fn rd32(core: *const emu.Core, off: u32) u32 {
    return iface.readWord(core, .wram, off);
}

test "Timer0 leftover and Halt IRQ return address" {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.halt_timer_rom);
    defer alloc.free(romf);

    for (cases) |c| {
        std.mem.writeInt(u32, romf[0xc4..0xc8], c.tm0cnt, .little);
        romf[0xb4] = c.device;
        var sum: u8 = 0;
        for (romf[0xa0..0xbd]) |b| sum +%= b;
        romf[0xbd] = @as(u8, 0xe7) -% sum;

        var core = try emu.Core.create(alloc);
        defer core.deinit();
        try core.boot(bios, romf);
        var frames: u32 = 0;
        while (rd32(&core, 0x10c) != 0xa5 and frames < 400) : (frames += 1) core.frameAdvance(.{});

        try std.testing.expectEqual(@as(u32, 0xa5), rd32(&core, 0x10c));
        try std.testing.expectEqual(c.tm0_leftover, rd32(&core, 0x100));
        try std.testing.expectEqual(c.irq_lr, rd32(&core, 0x104));
        try std.testing.expectEqual(c.tm0_low, rd32(&core, 0x108));
    }
}

// SPDX-License-Identifier: MIT
//! SoundDriverVSyncOff: ident lock value, DMA stop, pcmDmaCounter and mix buffer clear order,
//! unlock and call cost, sampled by a timer IRQ at fixed delays. Drives rom/sound_vsync_off_stub.zig.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

const DELAYS = [_]u16{ 40, 58, 59, 65, 66, 67, 68, 69, 70, 119, 120, 5656, 5657, 5679, 5680 };
const IDENT: u32 = 0x68736D53;

fn expected(d: u16) [5]u32 {
    return .{
        if (d >= 59 and d < 5680) IDENT + 1 else IDENT,
        if (d >= 68) 0 else if (d >= 66) 0xB6000000 else 0xB600B600,
        if (d >= 70) 0 else 0x55,
        if (d >= 120) 0 else 0xFFFFFFFF,
        if (d >= 5657) 0 else 0xFFFFFFFF,
    };
}

test "SoundDriverVSyncOff lock, clear order and cost" {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.sound_vsync_off_rom);
    defer alloc.free(romf);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, romf);

    const done = 0x110 + DELAYS.len * 20;
    var frames: u32 = 0;
    while (rd32(&core, done) != 0xA5A5 and frames < 400) : (frames += 1) core.frameAdvance(.{});

    try std.testing.expectEqual(@as(u32, 0xA5A5), rd32(&core, done));
    try std.testing.expectEqual(IDENT, rd32(&core, 0x100));
    try std.testing.expectEqual(@as(u32, 5731), rd32(&core, 0x104)); // valid ident cost
    try std.testing.expectEqual(@as(u32, 106), rd32(&core, 0x108)); // bad ident cost
    try std.testing.expectEqual(IDENT, rd32(&core, 0x10C));
    for (DELAYS, 0..) |d, i| {
        const want = expected(d);
        for (0..5) |k| {
            const got = rd32(&core, @intCast(0x110 + i * 20 + k * 4));
            if (got != want[k]) std.debug.print("delay {d} field {d}: got {x}, want {x}\n", .{ d, k, got, want[k] });
            try std.testing.expectEqual(want[k], got);
        }
    }
}

fn rd32(core: anytype, off: u32) u32 {
    var v: u32 = 0;
    inline for (0..4) |i| v |= @as(u32, core.read(.wram, off + @as(u32, i))) << (8 * i);
    return v;
}

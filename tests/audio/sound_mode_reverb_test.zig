// SPDX-License-Identifier: MIT
//! SoundDriverMode reverb apply/clear: bit7 applies the (bits 0-6) reverb value, so Mode(0x80)
//! must store reverb=0, not leave the prior value. Drives rom/sound_mode_stub.zig on the BIOS.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

test "SoundDriverMode reverb apply and clear" {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.sound_mode_rom);
    defer alloc.free(romf);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, romf);

    var frames: u32 = 0;
    while (core.read(.wram, 0x104) != 0xA5 and frames < 400) : (frames += 1) core.frameAdvance(.{});

    try std.testing.expectEqual(@as(u8, 0xA5), core.read(.wram, 0x104)); // stub ran to completion
    try std.testing.expectEqual(@as(u8, 5), core.read(.wram, 0x100)); // Mode(0x85): reverb = 5
    try std.testing.expectEqual(@as(u8, 0), core.read(.wram, 0x101)); // Mode(0x80): reverb cleared to 0
    try std.testing.expectEqual(@as(u8, 5), core.read(.wram, 0x102)); // re-set 5, Mode(0x00): unchanged
}

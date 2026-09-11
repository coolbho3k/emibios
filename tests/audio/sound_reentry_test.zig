// SPDX-License-Identifier: MIT
//! SoundDriverMain re-entrancy lock: a nested SWI 0x1C from the sequencer hook must be rejected
//! (ident = "Smsh"+1 during the call), and ident must be restored after. Drives
//! rom/sound_reentry_stub.zig on the BIOS.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

test "SoundDriverMain re-entrancy lock" {
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.sound_reentry_rom);
    defer alloc.free(romf);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, romf);

    var frames: u32 = 0;
    while (rd32(&core, 0x10C) != 0xA5A5 and frames < 400) : (frames += 1) core.frameAdvance(.{});

    try std.testing.expectEqual(@as(u32, 0xA5A5), rd32(&core, 0x10C)); // stub ran to completion
    try std.testing.expectEqual(@as(u32, 1), rd32(&core, 0x100)); // hook ran once: nested call rejected
    try std.testing.expectEqual(@as(u32, 0x68736D54), rd32(&core, 0x104)); // ident locked during the call
    try std.testing.expectEqual(@as(u32, 0x68736D53), rd32(&core, 0x108)); // ident restored after
}

fn rd32(core: anytype, off: u32) u32 {
    var v: u32 = 0;
    inline for (0..4) |i| v |= @as(u32, core.read(.wram, off + @as(u32, i))) << (8 * i);
    return v;
}

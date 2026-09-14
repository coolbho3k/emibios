// SPDX-License-Identifier: MIT
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");
fn readWord(core: anytype, off: u32) u32 {
    var b: [4]u8 = undefined;
    for (&b, 0..) |*v, i| v.* = core.read(.wram, off + @as(u32, @intCast(i)));
    return std.mem.readInt(u32, &b, .little);
}
test "SoundDriverMain fixed and resampled loop boundaries" {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const rom = try iface.readFile(alloc, opts.sound_loop_rom);
    defer alloc.free(rom);
    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, rom);
    var frames: u32 = 0;
    while (core.read(.wram, 0x180) != 0xa5 and frames < 400) : (frames += 1) core.frameAdvance(.{});
    try std.testing.expectEqual(@as(u8, 0xa5), core.read(.wram, 0x180));
    for ([_]u32{ 2, 3, 1 }, [_]u32{ 6, 5, 7 }, 0..) |remaining, position, c| {
        const off: u32 = 0x100 + @as(u32, @intCast(c)) * 32;
        try std.testing.expect(readWord(core, off) & 0x10 != 0);
        try std.testing.expectEqual(remaining, readWord(core, off + 4));
        try std.testing.expectEqual(position, readWord(core, off + 8));
        for (0..16) |i| {
            const advance = if (c == 0) i else i * 2;
            const loop_start: usize = if (c == 2) 7 else 3;
            const sample = if (advance < 8) advance else loop_start + (advance - 8) % (8 - loop_start);
            const expected: u8 = @intCast(sample * 16 * 254 / 256);
            try std.testing.expectEqual(expected, core.read(.wram, off + 12 + @as(u32, @intCast(i))));
        }
    }
    try std.testing.expectEqual(@as(u32, 0), readWord(core, 0x160));
    for (8..16) |i| try std.testing.expectEqual(@as(u8, 0), core.read(.wram, 0x16c + @as(u32, @intCast(i))));
}

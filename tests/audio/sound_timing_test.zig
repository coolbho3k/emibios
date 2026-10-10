// SPDX-License-Identifier: MIT
//! SoundDriverInit / SoundDriverMode cost, Timer0 restart and frame phase, driven by
//! rom/sound_timing_stub.zig. The goldens are hardware reference measurements of that ROM on GBAHawk.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

fn readWord(core: anytype, off: u32) u32 {
    var b: [4]u8 = undefined;
    for (&b, 0..) |*v, i| v.* = core.read(.wram, off + @as(u32, @intCast(i)));
    return std.mem.readInt(u32, &b, .little);
}

test "SoundDriverInit and SoundDriverMode timing" {
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const rom = try iface.readFile(alloc, opts.sound_timing_rom);
    defer alloc.free(rom);
    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, rom);
    var frames: u32 = 0;
    while (readWord(core, 0) != 0x7e57c0de and frames < 600) : (frames += 1) core.frameAdvance(.{ .render = false, .sound = false });
    try std.testing.expectEqual(@as(u32, 0x7e57c0de), readWord(core, 0));
    var want: [211]u32 = undefined;
    var n: usize = 0;
    want[n] = no_driver_cost;
    n += 1;
    for (init_vblank ++ init_edge) |t| {
        want[n..][0..3].* = .{ t.start, t.end, t.tm0 };
        n += 3;
    }
    for (mode_cost) |c| {
        want[n] = c;
        n += 1;
    }
    for (mode_vblank ++ mode_edge) |t| {
        want[n..][0..3].* = .{ t.start, t.end, t.tm0 };
        n += 3;
    }
    for (tail) |v| {
        want[n] = v;
        n += 1;
    }
    try std.testing.expectEqual(want.len, n);
    try std.testing.expectEqual(@as(u32, want.len), readWord(core, 0x100));
    var fails: u32 = 0;
    for (want, 0..) |w, i| {
        const got = readWord(core, 0x104 + @as(u32, @intCast(i)) * 4);
        if (got != w) {
            if (fails == 0) std.debug.print("word {d}: got {d}, want {d}\n", .{ i, got, w });
            fails += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), fails);
}

const Trial = struct { start: u32, end: u32, tm0: u32 };

// Mode with no driver installed.
const no_driver_cost: u32 = 87;
// Init at seven VBlank phases.
const init_vblank = [_]Trial{
    .{ .start = 20, .end = 279718, .tm0 = 0xfb4f },
    .{ .start = 23, .end = 279714, .tm0 = 0xfb4f },
    .{ .start = 27, .end = 279718, .tm0 = 0xfb4f },
    .{ .start = 25, .end = 279716, .tm0 = 0xfb4f },
    .{ .start = 24, .end = 279715, .tm0 = 0xfb4f },
    .{ .start = 24, .end = 279715, .tm0 = 0xfb4f },
    .{ .start = 25, .end = 279716, .tm0 = 0xfb4f },
};
// Init around the start of VCount 159.
const init_edge = [_]Trial{
    .{ .start = 2177, .end = 291031, .tm0 = 0xfb4f },
    .{ .start = 2174, .end = 10132, .tm0 = 0xfb4f },
    .{ .start = 2179, .end = 291026, .tm0 = 0xfb4f },
    .{ .start = 2178, .end = 291025, .tm0 = 0xfb4f },
    .{ .start = 2178, .end = 291025, .tm0 = 0xfb4f },
    .{ .start = 2179, .end = 291026, .tm0 = 0xfb4f },
    .{ .start = 2181, .end = 291028, .tm0 = 0xfb4f },
    .{ .start = 2184, .end = 291031, .tm0 = 0xfb4f },
    .{ .start = 2181, .end = 291028, .tm0 = 0xfb4f },
    .{ .start = 2186, .end = 291026, .tm0 = 0xfb4f },
    .{ .start = 2185, .end = 291025, .tm0 = 0xfb4f },
    .{ .start = 2185, .end = 291025, .tm0 = 0xfb4f },
    .{ .start = 2186, .end = 291026, .tm0 = 0xfb4f },
    .{ .start = 2188, .end = 291028, .tm0 = 0xfb4f },
    .{ .start = 2191, .end = 291031, .tm0 = 0xfb4f },
    .{ .start = 2188, .end = 291028, .tm0 = 0xfb4f },
};
// Mode(0, 0x80, 0x100, 0x1000, 0x800000, 0x900100) without a rate change.
const mode_cost = [_]u32{ 119, 121, 206, 120, 132, 219 };
// Mode rate 1, 4, 9, 12, seven VBlank phases each.
const mode_vblank = [_]Trial{
    .{ .start = 22, .end = 279710, .tm0 = 0xf4c4 },
    .{ .start = 21, .end = 279709, .tm0 = 0xf4c4 },
    .{ .start = 21, .end = 279709, .tm0 = 0xf4c4 },
    .{ .start = 22, .end = 279710, .tm0 = 0xf4c4 },
    .{ .start = 24, .end = 279712, .tm0 = 0xf4c4 },
    .{ .start = 27, .end = 279715, .tm0 = 0xf4c4 },
    .{ .start = 31, .end = 279712, .tm0 = 0xf4c4 },
    .{ .start = 22, .end = 279713, .tm0 = 0xfb4c },
    .{ .start = 24, .end = 279715, .tm0 = 0xfb4c },
    .{ .start = 27, .end = 279711, .tm0 = 0xfb4c },
    .{ .start = 23, .end = 279714, .tm0 = 0xfb4c },
    .{ .start = 28, .end = 279712, .tm0 = 0xfb4c },
    .{ .start = 27, .end = 279711, .tm0 = 0xfb4c },
    .{ .start = 26, .end = 279710, .tm0 = 0xfb4c },
    .{ .start = 20, .end = 279713, .tm0 = 0xfe1e },
    .{ .start = 24, .end = 279710, .tm0 = 0xfe1e },
    .{ .start = 22, .end = 279715, .tm0 = 0xfe1e },
    .{ .start = 28, .end = 279714, .tm0 = 0xfe1e },
    .{ .start = 28, .end = 279714, .tm0 = 0xfe1e },
    .{ .start = 29, .end = 279715, .tm0 = 0xfe1e },
    .{ .start = 31, .end = 279710, .tm0 = 0xfe1e },
    .{ .start = 20, .end = 279714, .tm0 = 0xfea3 },
    .{ .start = 25, .end = 279712, .tm0 = 0xfea3 },
    .{ .start = 24, .end = 279711, .tm0 = 0xfea3 },
    .{ .start = 23, .end = 279710, .tm0 = 0xfea3 },
    .{ .start = 24, .end = 279711, .tm0 = 0xfea3 },
    .{ .start = 25, .end = 279712, .tm0 = 0xfea3 },
    .{ .start = 28, .end = 279715, .tm0 = 0xfea3 },
};
// Mode rate 1 then 12 around the start of VCount 159.
const mode_edge = [_]Trial{
    .{ .start = 1138, .end = 7665, .tm0 = 0xf4c4 },
    .{ .start = 1139, .end = 7666, .tm0 = 0xf4c4 },
    .{ .start = 1141, .end = 288564, .tm0 = 0xf4c4 },
    .{ .start = 1144, .end = 288560, .tm0 = 0xf4c4 },
    .{ .start = 1148, .end = 288564, .tm0 = 0xf4c4 },
    .{ .start = 1146, .end = 288562, .tm0 = 0xf4c4 },
    .{ .start = 1145, .end = 288561, .tm0 = 0xf4c4 },
    .{ .start = 1145, .end = 288561, .tm0 = 0xf4c4 },
    .{ .start = 1213, .end = 7662, .tm0 = 0xfea3 },
    .{ .start = 1215, .end = 7664, .tm0 = 0xfea3 },
    .{ .start = 1218, .end = 288563, .tm0 = 0xfea3 },
    .{ .start = 1215, .end = 7664, .tm0 = 0xfea3 },
    .{ .start = 1220, .end = 288558, .tm0 = 0xfea3 },
    .{ .start = 1219, .end = 288564, .tm0 = 0xfea3 },
    .{ .start = 1219, .end = 288564, .tm0 = 0xfea3 },
    .{ .start = 1220, .end = 288558, .tm0 = 0xfea3 },
};
// Seen by an IRQ during the Init wait: ident, TM0CNT_H. Then the OR of all channel status bytes after Mode(0x800).
const tail = [_]u32{ 0x0, 0x0, 0x0 };

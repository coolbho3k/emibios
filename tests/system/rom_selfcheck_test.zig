// SPDX-License-Identifier: MIT
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");
const layout = @import("layout");
const protocol = @import("protocol");

const SUMMARY_OFF: u32 = layout.summary.base - 0x02000000;
const MAX_FRAMES: usize = 3000;

test "on-GBA test ROM boots and every suite passes" {
    const a = std.testing.allocator;
    const bios = try iface.readFile(a, opts.bios_path);
    defer a.free(bios);
    const rom = try iface.readFile(a, opts.test_rom_path);
    defer a.free(rom);

    var core = try emu.Core.create(a);
    defer core.deinit();
    try core.boot(bios, rom);

    var ready = false;
    var f: usize = 0;
    while (f < MAX_FRAMES) : (f += 1) {
        core.frameAdvance(.{});
        if (iface.readWord(&core, .wram, SUMMARY_OFF) == protocol.UI_MAGIC) {
            ready = true;
            break;
        }
    }
    try std.testing.expect(ready);

    const pass = iface.readWord(&core, .wram, SUMMARY_OFF + 4);
    const total = iface.readWord(&core, .wram, SUMMARY_OFF + 8);
    errdefer std.debug.print("on-GBA suite: {d}/{d} cases passed\n", .{ pass, total });
    try std.testing.expect(total > 0);
    try std.testing.expectEqual(total, pass);

    if (std.mem.eql(u8, opts.emu, "gbahawk")) {
        const dispcnt_lo = core.read(.ioregs, 0);
        const dispcnt_hi = core.read(.ioregs, 1);
        try std.testing.expectEqual(@as(u8, 3), dispcnt_lo & 0x87);
        try std.testing.expect(dispcnt_hi & 0x04 != 0);
    }

    var drawn = false;
    var i: u32 = 0;
    while (i < 0x1000) : (i += 1) {
        if (core.read(.vram, i) != 0) {
            drawn = true;
            break;
        }
    }
    try std.testing.expect(drawn);
}

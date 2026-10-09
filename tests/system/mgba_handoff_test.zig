// SPDX-License-Identifier: MIT
//! Boot to cart handoff cycle on mGBA. Runs next to the GBAHawk handoff test.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

const TIMEOUT_IN_CYCLES = 200_000_000;

test "boot to cart handoff lands on the calibrated mGBA cycle" {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.handoff_rom);
    defer alloc.free(romf);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, romf);

    const h = core.runToHandoff(TIMEOUT_IN_CYCLES);
    try std.testing.expectEqual(@as(u32, 0x08000000), h.pc);
    try std.testing.expectEqual(opts.mgba_handoff_cycle, h.cycle);
}

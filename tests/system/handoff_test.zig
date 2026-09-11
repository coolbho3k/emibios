// SPDX-License-Identifier: MIT
//! Regression test for the BIOS to cart handoff machine state.
//!
//! Runs the BIOS to the instant PC first enters cart ROM and checks: registers, IWRAM, IO, PRAM, OAM,
//! VRAM, and the open-bus BIOS-read latch against the blessed snapshot.
//!
//! After a handoff change, run `zig build test -Dtest-filter=handoff` and paste the "got" hashes below.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");

// Blessed per-region FNV-1a-64 hashes of the handoff state.
const gold = .{
    .regs = 0x4fa66fab804c3609, // r0-r15
    .iwram = 0x8f6955bf94ec2325, // 0x8000 bytes
    .io = 0x09722b3817f654a0, // 0x400 IO registers
    .pram = 0x51d88627df287325, // 0x400 bytes (all zero at handoff)
    .oam = 0x51d88627df287325, // 0x400 bytes (all zero at handoff)
    .vram = 0xf5edab31b6802325, // 0x18000 bytes
    .latch = 0xe129f000, // open-bus BIOS-read latch: the documented value some carts read at handoff
};

const TIMEOUT_IN_CYCLES = 200_000_000;

fn fnv(seed: u64, b: u8) u64 {
    return (seed ^ b) *% 0x100000001b3;
}

fn hashBytes(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = fnv(h, b);
    return h;
}

fn hashRegion(core: *const emu.Core, region: iface.Region, len: u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var a: u32 = 0;
    while (a < len) : (a += 1) h = fnv(h, core.read(region, a));
    return h;
}

// Returns true on mismatch.
fn check(name: []const u8, got: u64, want: u64) bool {
    if (got == want) return false;
    std.debug.print("handoff {s}: got 0x{x:0>16} want 0x{x:0>16}\n", .{ name, got, want });
    return true;
}

test "boot-to-cart handoff state matches the blessed snapshot" {
    // GBAHawk-only. We can't get down to the exact cycle with MesenCE backend.
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.handoff_rom);
    defer alloc.free(romf);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, romf);

    const h = core.runToHandoff(TIMEOUT_IN_CYCLES);

    try std.testing.expectEqual(@as(u32, 0x08000000), h.pc); // did we hand off to cart ROM...
    try std.testing.expectEqual(opts.handoff_cycle, h.cycle); // ...on the calibrated handoff cycle
    const regs = core.getRegs(); // r0-r15
    try std.testing.expectEqual(@as(u32, 0), regs[0]); // ...with r0-r3 zeroed at the handoff
    try std.testing.expectEqual(@as(u32, 0), regs[1]);
    try std.testing.expectEqual(@as(u32, 0), regs[2]);
    try std.testing.expectEqual(@as(u32, 0), regs[3]);
    try std.testing.expectEqual(@as(u32, 0), regs[12]); // and with r12=0?

    var bad = false;
    bad = check("regs", hashBytes(std.mem.sliceAsBytes(regs[0..])), gold.regs) or bad;
    bad = check("iwram", hashRegion(&core, .iwram, 0x8000), gold.iwram) or bad;
    bad = check("io", hashRegion(&core, .ioregs, 0x400), gold.io) or bad;
    bad = check("pram", hashRegion(&core, .pram, 0x400), gold.pram) or bad;
    bad = check("oam", hashRegion(&core, .oam, 0x400), gold.oam) or bad;
    bad = check("vram", hashRegion(&core, .vram, 0x18000), gold.vram) or bad;
    bad = check("latch", core.getBiosLatch(), gold.latch) or bad; // open-bus latch value
    if (bad) return error.HandoffStateDrift;
}

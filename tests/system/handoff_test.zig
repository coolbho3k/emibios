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

// Rewrites word 0 of the handoff ROM from `b target` to `add pc, pc, #imm` with the same target.
fn nonBranchRom(alloc: std.mem.Allocator, romf: []const u8) ![]u8 {
    const rom = try alloc.dupe(u8, romf);
    const w = std.mem.readInt(u32, rom[0..4], .little);
    if (w >> 24 != 0xea) return error.NotABranch;
    const off: i32 = @as(i32, @bitCast(w << 8)) >> 8;
    const imm: u32 = @intCast(off * 4); // add pc, pc, #imm lands at pc + 8 + imm, like the branch
    if (imm > 0xff) return error.ImmTooWide;
    std.mem.writeInt(u32, rom[0..4], 0xe28ff000 | imm, .little);
    return rom;
}

test "a cart whose first word is not a branch boots when its logo is valid" {
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.handoff_rom);
    defer alloc.free(romf);
    const rom = try nonBranchRom(alloc, romf);
    defer alloc.free(rom);

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, rom);
    const h = core.runToHandoff(TIMEOUT_IN_CYCLES);
    try std.testing.expectEqual(@as(u32, 0x08000000), h.pc);
    try std.testing.expectEqual(opts.handoff_cycle, h.cycle);
}

test "a cart whose first word is not a branch and whose logo is bad is treated as no cart" {
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    const romf = try iface.readFile(alloc, opts.handoff_rom);
    defer alloc.free(romf);
    const rom = try nonBranchRom(alloc, romf);
    defer alloc.free(rom);
    rom[0x04] ^= 0xff;

    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, rom);
    const h = core.runToHandoff(TIMEOUT_IN_CYCLES);
    try std.testing.expect(h.pc != 0x08000000);
}

// Boots `rom` holding `buttons` and reports whether SIOCNT ever enters Multiplay mode, i.e. the BIOS listens for multiboot.
fn listensForMultiboot(rom: []const u8, buttons: u16) !bool {
    const alloc = std.testing.allocator;
    const bios = try iface.readFile(alloc, opts.bios_path);
    defer alloc.free(bios);
    var core = try emu.Core.create(alloc);
    defer core.deinit();
    try core.boot(bios, rom);
    var frame: u32 = 0;
    while (frame < 300) : (frame += 1) {
        core.frameAdvance(.{ .buttons = buttons, .render = false, .sound = false });
        const siocnt = @as(u16, core.read(.ioregs, 0x128)) | @as(u16, core.read(.ioregs, 0x129)) << 8;
        if (siocnt & 0x3000 == 0x2000) return true;
    }
    return false;
}

const NO_KEYS: u16 = 0x3ff;
const B_HELD: u16 = 0x3ff & ~@as(u16, 0x2);

test "a cart with a bad header does not listen for multiboot" {
    if (!std.mem.eql(u8, opts.emu, "gbahawk")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const romf = try iface.readFile(alloc, opts.handoff_rom);
    defer alloc.free(romf);
    const rom = try alloc.dupe(u8, romf);
    defer alloc.free(rom);

    rom[0x10] ^= 0xff; // bad logo, first word still a branch
    try std.testing.expect(!try listensForMultiboot(rom, NO_KEYS));
    try std.testing.expect(!try listensForMultiboot(rom, B_HELD));
    rom[0x10] ^= 0xff;
    rom[0xbd] ^= 0x01; // bad header checksum
    try std.testing.expect(!try listensForMultiboot(rom, NO_KEYS));
    try std.testing.expect(!try listensForMultiboot(rom, B_HELD));
}

// SPDX-License-Identifier: MIT
//! Host-side execution of the RAM-region permutation matrix: boots the standalone harness ROM
//! (rom/perm_harness.zig), which runs the same shared executor (rom/perm.zig) as the on-GBA test ROM,
//! then reads the RESULT table back from EWRAM and checks it against the goldens in ram_perm.zig.
const std = @import("std");
const iface = @import("iface");
const emu = @import("emu");
const opts = @import("test_options");
const spec = @import("ram_perm.zig");
const layout = @import("layout");
const protocol = @import("protocol");

const DONE_MAGIC: u32 = protocol.DONE_MAGIC;
const RESULT_OFF: u32 = layout.perm_result.base - 0x02000000;
const DIAG_OFF: u32 = layout.perm_diag.base - 0x02000000;

fn bootHarness(a: std.mem.Allocator, core: *emu.Core) !void {
    const bios = try iface.readFile(a, opts.bios_path);
    defer a.free(bios);
    const rom = try iface.readFile(a, opts.perm_harness_rom);
    defer a.free(rom);
    try core.boot(bios, rom);
    var f: usize = 0;
    while (f < 600) : (f += 1) {
        core.frameAdvance(.{});
        if (iface.readWord(core, .wram, 0) == DONE_MAGIC) return;
    }
    return error.HarnessTimeout;
}

// BitUnPack uses only 32-bit stores (no emulator-divergent 8-bit-write quirk), so these goldens hold
// on both backends; point `-Dbios=<path>` at a reference BIOS to check them.
test "BitUnPack offset-0 timing (both backends)" {
    const a = std.testing.allocator;
    var core = try emu.Core.create(a);
    defer core.deinit();
    try bootHarness(a, &core);
    inline for (spec.DIAG, 0..) |dg, i| {
        const cyc = iface.readWord(&core, .wram, DIAG_OFF + @as(u32, @intCast(i)) * 4);
        errdefer std.debug.print("FAIL BitUnPack {d}B fill=0x{X:0>2}: cyc={d} (want {d})\n", .{ dg.bytes, dg.fill, cyc, dg.cyc });
        try std.testing.expectEqual(dg.cyc, cyc);
    }
}

test "RAM permutation matrix matches goldens (shared harness)" {
    // Both backends check cycles and destination checksums against the regression baselines in ram_perm.zig.
    const a = std.testing.allocator;
    var core = try emu.Core.create(a);
    defer core.deinit();
    try bootHarness(a, &core);

    const N = spec.N;
    inline for (spec.OPS, 0..) |op, o| {
        var p: usize = 0;
        while (p < N * N) : (p += 1) {
            const idx = o * N * N + p;
            const cyc = iface.readWord(&core, .wram, RESULT_OFF + @as(u32, @intCast(idx)) * 8);
            const sum = iface.readWord(&core, .wram, RESULT_OFF + @as(u32, @intCast(idx)) * 8 + 4);
            const dst_col = p % N; // 0=EW 1=IW 2=PR 3=VR 4=OA
            const src = spec.REGIONS[p / N].name;
            const dst = spec.REGIONS[dst_col].name;
            errdefer std.debug.print("FAIL {s} {s}->{s}: cyc={d} (want {d}) sum={d} (want {d})\n", .{ op.name, src, dst, cyc, spec.GOLDEN_CYC[o][p], sum, spec.GOLDEN_SUM[o][p] });
            try std.testing.expectEqual(spec.GOLDEN_CYC[o][p], cyc);
            try std.testing.expectEqual(spec.GOLDEN_SUM[o][p], sum);
        }
    }
}

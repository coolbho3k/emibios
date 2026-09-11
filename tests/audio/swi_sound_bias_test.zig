// SPDX-License-Identifier: MIT
//! SoundBias tests for bias target selection and in-place ramping.
//! Sound SWIs currently pin correctness only, not cycle counts.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.sound_bias_rom };

// The boot state leaves SOUNDBIAS at 0x200.
const targets = [_]u32{ 0, 0, 1, 0, 0xFFFF, 5, 0, 0x10000, 0x80000000, 0, 1, 1 };
const want = [_]u32{ 0, 0, 0x200, 0, 0x200, 0x200, 0, 0x200, 0x200, 0, 0x200, 0x200 };

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [targets.len]gba.Cmd = undefined;
    for (targets, 0..) |tg, i| cmds[i] = .{ .r0 = tg, .r1 = 4 };
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    var fails: u32 = 0;
    for (targets, want, res) |tg, w, r| {
        if (r.r1 != w) {
            if (fails == 0) t.info("soundbias target 0x{X}: got 0x{X}, want 0x{X}\n", .{ tg, r.r1, w });
            fails += 1;
        }
    }
    try t.checkEqual("targets", @as(u32, 0), fails);
}

test "SoundBias" {
    try testing.host(run, std.testing.allocator);
}

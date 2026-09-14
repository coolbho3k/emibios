// SPDX-License-Identifier: MIT
//! SWI test inventory. `module` must match the @import name in rom/main.zig.
pub const Swi = struct { opt: []const u8, num: u8 };
pub const Test = struct { module: []const u8, path: []const u8, swis: []const Swi };

pub const swi_tests = [_]Test{
    .{ .module = "swi_div_test", .path = "tests/math/swi_div_test.zig", .swis = &.{.{ .opt = "div_rom", .num = 6 }} },
    .{ .module = "swi_div_arm_test", .path = "tests/math/swi_div_arm_test.zig", .swis = &.{.{ .opt = "div_arm_rom", .num = 7 }} },
    .{ .module = "swi_sqrt_test", .path = "tests/math/swi_sqrt_test.zig", .swis = &.{.{ .opt = "sqrt_rom", .num = 8 }} },
    .{ .module = "swi_arc_tan_test", .path = "tests/math/swi_arc_tan_test.zig", .swis = &.{.{ .opt = "arc_tan_rom", .num = 9 }} },
    .{ .module = "swi_arc_tan2_test", .path = "tests/math/swi_arc_tan2_test.zig", .swis = &.{.{ .opt = "arc_tan2_rom", .num = 10 }} },
    .{ .module = "swi_bg_affine_set_test", .path = "tests/math/swi_bg_affine_set_test.zig", .swis = &.{.{ .opt = "bg_affine_set_rom", .num = 14 }} },
    .{ .module = "swi_obj_affine_set_test", .path = "tests/math/swi_obj_affine_set_test.zig", .swis = &.{.{ .opt = "obj_affine_set_rom", .num = 15 }} },
    .{ .module = "swi_cpu_set_test", .path = "tests/memory/swi_cpu_set_test.zig", .swis = &.{.{ .opt = "cpu_set_rom", .num = 11 }} },
    .{ .module = "swi_cpu_fast_set_test", .path = "tests/memory/swi_cpu_fast_set_test.zig", .swis = &.{.{ .opt = "cpu_fast_set_rom", .num = 12 }} },
    .{ .module = "swi_get_bios_checksum_test", .path = "tests/system/swi_get_bios_checksum_test.zig", .swis = &.{.{ .opt = "get_bios_checksum_rom", .num = 13 }} },
    .{ .module = "swi_sound_bias_test", .path = "tests/audio/swi_sound_bias_test.zig", .swis = &.{.{ .opt = "sound_bias_rom", .num = 25 }} },
    .{ .module = "swi_midi_key2freq_test", .path = "tests/audio/swi_midi_key2freq_test.zig", .swis = &.{.{ .opt = "midi_key2freq_rom", .num = 31 }} },
    .{ .module = "swi_lz77_test", .path = "tests/decompression/swi_lz77_test.zig", .swis = &.{ .{ .opt = "lz77_wram_rom", .num = 17 }, .{ .opt = "lz77_vram_rom", .num = 18 } } },
    .{ .module = "swi_rl_test", .path = "tests/decompression/swi_rl_test.zig", .swis = &.{ .{ .opt = "rl_wram_rom", .num = 20 }, .{ .opt = "rl_vram_rom", .num = 21 } } },
    .{ .module = "swi_huff_test", .path = "tests/decompression/swi_huff_test.zig", .swis = &.{.{ .opt = "huff_rom", .num = 19 }} },
    .{ .module = "swi_diff_test", .path = "tests/decompression/swi_diff_test.zig", .swis = &.{ .{ .opt = "diff8_wram_rom", .num = 22 }, .{ .opt = "diff8_vram_rom", .num = 23 }, .{ .opt = "diff16_rom", .num = 24 } } },
    .{ .module = "swi_bit_unpack_test", .path = "tests/decompression/swi_bit_unpack_test.zig", .swis = &.{.{ .opt = "bit_unpack_rom", .num = 16 }} },
};

// Harness-level tests that aren't a single SWI invocation, so they keep a different shape on each platform.
// The host test file lives here with a dedicated runner in rom/main.zig rather than the shared run(t, a) form.
pub const platform_specific = [_]struct { path: []const u8, reason: []const u8 }{
    .{ .path = "tests/system/handoff_test.zig", .reason = "register/latch snapshot, not a SWI call" },
    .{ .path = "tests/memory/ram_perm_test.zig", .reason = "12x25 region matrix from ram_perm.OPS" },
    .{ .path = "tests/system/rom_selfcheck_test.zig", .reason = "boots the on-GBA test ROM end to end" },
    .{ .path = "tests/audio/sound_mode_reverb_test.zig", .reason = "stateful: Init then Mode then read SoundInfo" },
    .{ .path = "tests/audio/sound_loop_test.zig", .reason = "stateful: sample looping and PCM output" },
    .{ .path = "tests/audio/sound_reentry_test.zig", .reason = "stateful: nested SWI 0x1C from the sequencer hook" },
};

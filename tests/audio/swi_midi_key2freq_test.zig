// SPDX-License-Identifier: MIT
//! MidiKey2Freq tests for WaveData frequency conversion.
//! Sound SWIs currently pin correctness only, not cycle counts.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.midi_key2freq_rom };

const RefCase = struct { fq: u32, key: u32, fine: u32, want: u32 };
const refs = [_]RefCase{
    .{ .fq = 0x800000, .key = 60, .fine = 0, .want = 0x2000 }, // middle C
    .{ .fq = 0x800000, .key = 69, .fine = 0, .want = 0x35D1 }, // A4
    .{ .fq = 0x400000, .key = 48, .fine = 128, .want = 0x83C }, // half-semitone fine interpolation
    .{ .fq = 0xFFFFFF, .key = 127, .fine = 255, .want = 0xCB248 }, // top of range
};

fn waveData(freq: u32) [8]u8 {
    var b = [_]u8{0} ** 8;
    std.mem.writeInt(u32, b[4..8], freq, .little); // WaveData->freq at offset 4 (the only field read)
    return b;
}

// key 0 -> ratio 1.0, so the high word of freq*2^17 is freq>>15 (exact for the physical freq range).
fn key0(t: anytype, a: std.mem.Allocator) !void {
    const fqs = [_]u32{ 0x100000, 0x800000, 0xFFFFFF, 0x123456 };
    var wds: [fqs.len][8]u8 = undefined;
    var cmds: [fqs.len]gba.Cmd = undefined;
    for (fqs, 0..) |fq, i| {
        wds[i] = waveData(fq);
        cmds[i] = .{ .r0_buf = &wds[i], .r1 = 0, .r2 = 0 };
    }
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    var fails: u32 = 0;
    for (fqs, res) |fq, r| {
        if (r.r0 != fq >> 15) {
            if (fails == 0) t.info("midi key0 fq=0x{X}: got 0x{X}, want 0x{X}\n", .{ fq, r.r0, fq >> 15 });
            fails += 1;
        }
    }
    try t.checkEqual("key0", @as(u32, 0), fails);
}

// Frequency rises monotonically with key.
fn monotonic(t: anytype, a: std.mem.Allocator) !void {
    var wd = waveData(0x800000);
    var cmds: [128]gba.Cmd = undefined;
    for (&cmds, 0..) |*c, k| c.* = .{ .r0_buf = &wd, .r1 = @intCast(k), .r2 = 0 };
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    var prev: u32 = 0;
    var fails: u32 = 0;
    for (res, 0..) |r, k| {
        if (r.r0 < prev) {
            if (fails == 0) t.info("midi key {d}: 0x{X} drops below 0x{X}\n", .{ k, r.r0, prev });
            fails += 1;
        }
        prev = r.r0;
    }
    try t.checkEqual("monotonic", @as(u32, 0), fails);
}

// Reference frequencies.
fn reference(t: anytype, a: std.mem.Allocator) !void {
    var wds: [refs.len][8]u8 = undefined;
    var cmds: [refs.len]gba.Cmd = undefined;
    for (refs, 0..) |c, i| {
        wds[i] = waveData(c.fq);
        cmds[i] = .{ .r0_buf = &wds[i], .r1 = c.key, .r2 = c.fine };
    }
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (refs, 0..) |c, i|
        try t.checkEqual(std.fmt.comptimePrint("ref[{d}]", .{i}), c.want, res[i].r0);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try key0(t, a);
    try monotonic(t, a);
    try reference(t, a);
}

test "MidiKey2Freq key0" {
    try testing.host(key0, std.testing.allocator);
}
test "MidiKey2Freq monotonic" {
    try testing.host(monotonic, std.testing.allocator);
}
test "MidiKey2Freq reference" {
    try testing.host(reference, std.testing.allocator);
}

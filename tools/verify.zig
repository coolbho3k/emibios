// SPDX-License-Identifier: LGPL-3.0-or-later
//! Verifies a file against a SHA-256 text file.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var sfw: Io.File.Writer = .init(.stdout(), io, &.{});
    const w = &sfw.interface;

    if (args.len < 3) {
        try w.print("usage: verify <file> <sha256-file>\n", .{});
        try w.flush();
        std.process.exit(2);
    }

    const data = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});

    const got = std.fmt.bytesToHex(digest, .lower);

    const raw = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(4096));
    const want = std.mem.trim(u8, raw[0..@min(raw.len, 64)], " \t\r\n");

    if (std.mem.eql(u8, &got, want)) {
        try w.print("verify ok: sha256={s}\n", .{got});
        try w.flush();
    } else {
        try w.print("mismatch: got={s} want={s}\n", .{ got, want });
        try w.flush();
        std.process.exit(1);
    }
}

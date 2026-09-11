// SPDX-License-Identifier: GPL-3.0-or-later
//! Copy <in> to <out>, zero-padded up to <size> bytes.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage; // pad <in> <out> <size>

    const size = try std.fmt.parseInt(usize, args[3], 0);
    const data = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    if (data.len > size) return error.InputExceedsPadSize;

    const out = if (data.len == size) data else blk: {
        const buf = try arena.alloc(u8, size);
        @memcpy(buf[0..data.len], data);
        @memset(buf[data.len..], 0);
        break :blk buf;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out });
}

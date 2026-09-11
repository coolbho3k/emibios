// SPDX-License-Identifier: GPL-3.0-or-later
//! Generates the on-GBA test ROM's font atlas from the font sheet
const std = @import("std");
const Io = std.Io;
const fs = @import("font_sheet.zig");

const FONT = "assets/gbstudio_default_ascii.png";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const font = try fs.loadPng(gpa, io, FONT);
    const at = try fs.buildAtlas(gpa, font);
    if (args.len >= 2) {
        const path = try std.fs.path.join(gpa, &.{ args[1], "font.bin" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = at.raw });
    } else {
        var ow: Io.File.Writer = .init(.stdout(), io, &.{});
        try ow.interface.writeAll(at.raw);
        try ow.interface.flush();
    }
}

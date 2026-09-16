// SPDX-License-Identifier: LGPL-3.0-or-later
//! Shared font sheet + 1bpp glyph logic
const std = @import("std");
const Io = std.Io;
const zigimg = @import("zigimg");

pub const GB_CELL = 8;
pub const GB_COLS = 16;
pub const GB_FIRST = 0x20;
pub const ATLAS_TILE = 8;
pub const ATLAS_LO = 0x20;
pub const ATLAS_HI = 0x7E;

pub const Px = struct { w: usize, h: usize, p: []zigimg.color.Rgba32 };

pub fn loadPng(gpa: std.mem.Allocator, io: Io, path: []const u8) !Px {
    const rbuf = try gpa.alloc(u8, 1 << 20);
    var img = try zigimg.Image.fromFilePath(gpa, io, path, rbuf);
    try img.convert(gpa, .rgba32);
    return .{ .w = img.width, .h = img.height, .p = img.pixels.rgba32 };
}

pub fn isWhite(px: zigimg.color.Rgba32) bool {
    return px.r == 255 and px.g == 255 and px.b == 255;
}

pub fn glyph(font: Px, ch: u8) [GB_CELL][GB_CELL]u1 {
    const idx: usize = ch - GB_FIRST;
    const ox = (idx % GB_COLS) * GB_CELL;
    const oy = (idx / GB_COLS) * GB_CELL;
    var g: [GB_CELL][GB_CELL]u1 = undefined;
    for (0..GB_CELL) |y| for (0..GB_CELL) |x| {
        g[y][x] = if (isWhite(font.p[(oy + y) * font.w + (ox + x)])) 0 else 1;
    };
    return g;
}

pub fn buildAtlas(gpa: std.mem.Allocator, font: Px) !struct { raw: []u8, n: usize } {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    var ch: u8 = ATLAS_LO;
    while (ch <= ATLAS_HI) : (ch += 1) {
        const g = glyph(font, ch);
        for (0..ATLAS_TILE) |ry| {
            var acc: u8 = 0;
            for (0..ATLAS_TILE) |rx| acc |= @as(u8, g[ry][rx]) << @intCast(rx);
            try out.append(gpa, acc);
        }
        n += 1;
    }
    return .{ .raw = out.items, .n = n };
}

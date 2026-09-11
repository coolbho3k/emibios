// SPDX-License-Identifier: MIT
//! Bump allocator over a fixed memory slab
const std = @import("std");
const Alignment = std.mem.Alignment;

pub const Bump = struct {
    buf: []u8,
    end: usize = 0,
    outstanding: usize = 0,

    pub fn init(base: usize, len: usize) Bump {
        const p: [*]u8 = @ptrFromInt(base);
        return .{ .buf = p[0..len] };
    }

    pub fn reset(self: *Bump) void {
        self.end = 0;
        self.outstanding = 0;
    }

    pub fn allocator(self: *Bump) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Bump = @ptrCast(@alignCast(ctx));
        // Min word alignment: an SWI source's header is read as a 32-bit word
        const start = std.mem.alignForward(usize, self.end, @max(alignment.toByteUnits(), 4));
        if (start + n > self.buf.len) return null;
        self.end = start + n;
        self.outstanding += n;
        return self.buf.ptr + start;
    }

    fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Bump = @ptrCast(@alignCast(ctx));
        self.outstanding -= memory.len;
    }
};

// SPDX-License-Identifier: MIT
pub const Span = struct { base: u32, len: u32 };

pub const state: Span = .{ .base = 0x02000000, .len = 0x14000 };
pub const mem_dest: Span = .{ .base = 0x02018000, .len = 0x2000 };
pub const handoff: Span = .{ .base = 0x02022000, .len = 0x100 };
pub const perm_src: Span = .{ .base = 0x02023000, .len = 0x400 };
pub const perm_dst: Span = .{ .base = 0x02023400, .len = 0x400 };
pub const perm_result: Span = .{ .base = 0x02024000, .len = 0x1000 };
pub const perm_info: Span = .{ .base = 0x02025000, .len = 0x1000 };
pub const perm_diag: Span = .{ .base = 0x02026000, .len = 0x800 };
pub const summary: Span = .{ .base = 0x02026800, .len = 0x100 };
pub const shim: Span = .{ .base = 0x02027000, .len = 0x1000 };
pub const bump: Span = .{ .base = 0x02028000, .len = 0x18000 };

comptime {
    const spans = [_]Span{ state, mem_dest, handoff, perm_src, perm_dst, perm_result, perm_info, perm_diag, summary, shim, bump };
    for (spans, 0..) |s, i| {
        if (s.base < 0x02000000 or s.base + s.len > 0x02040000) @compileError("EWRAM span out of range");
        for (spans[i + 1 ..]) |o| {
            if (s.base < o.base + o.len and o.base < s.base + s.len) @compileError("EWRAM spans overlap");
        }
    }
}

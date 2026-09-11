// SPDX-License-Identifier: MIT
const std = @import("std");

pub const Cmd = struct {
    r0: u32 = 0,
    r1: u32 = 0,
    r2: u32 = 0,
    r3: u32 = 0,
    r0_buf: ?[]const u8 = null,
};

pub const Result = struct { r0: u32, r1: u32, r2: u32, r3: u32, cycles: u32 };

pub const MemCmd = struct {
    src: []const u8,
    dest: []u8,
    r2: u32 = 0,
    r3: u32 = 0,
    src_addr: ?u32 = null,
    r2_ptr: ?[]const u8 = null,
};

pub const DONE_MAGIC: u32 = std.mem.readInt(u32, "DONE"[0..4], .little);
pub const UI_MAGIC: u32 = std.mem.readInt(u32, "UIOK"[0..4], .little);
pub const CMD_OFF: u32 = 0x400;
pub const CMD_STRIDE: u32 = 16;
pub const RES_OFF: u32 = 4;
pub const RES_STRIDE: u32 = 20;

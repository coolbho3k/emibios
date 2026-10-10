// SPDX-License-Identifier: MIT
//! GBA side execution of the RAM region matrix
const std = @import("std");
const gba = @import("gba");
const spec = @import("ram_perm");
const layout = @import("layout");

pub const RESULT: u32 = layout.perm_result.base;
pub const N_RESULTS = spec.OPS.len * spec.N * spec.N;
const INFO_ADDR: u32 = layout.perm_info.base;

// Stage a byte slice into `addr` using 32-bit stores
fn stage(addr: u32, bytes: []const u8) void {
    const p: [*]volatile u32 = @ptrFromInt(addr);
    var i: usize = 0;
    while (i * 4 < bytes.len) : (i += 1) {
        var w: u32 = 0;
        var b: usize = 0;
        while (b < 4 and i * 4 + b < bytes.len) : (b += 1) w |= @as(u32, bytes[i * 4 + b]) << @intCast(b * 8);
        p[i] = w;
    }
}

fn zeroR(addr: u32, nbytes: usize) void {
    const p: [*]volatile u32 = @ptrFromInt(addr);
    var i: usize = 0;
    while (i * 4 < nbytes) : (i += 1) p[i] = 0;
}

// Additive byte checksum of [addr..addr+nbytes), read via 32-bit loads.
fn sumR(addr: u32, nbytes: usize) u32 {
    const p: [*]volatile u32 = @ptrFromInt(addr);
    var s: u32 = 0;
    var i: usize = 0;
    while (i * 4 < nbytes) : (i += 1) {
        const w = p[i];
        var b: usize = 0;
        while (b < 4 and i * 4 + b < nbytes) : (b += 1) s +%= (w >> @intCast(b * 8)) & 0xFF;
    }
    return s;
}

pub const DIAG_RESULT: u32 = layout.perm_diag.base;

/// Runs BitUnPack EW->EW for each spec.DIAG fixture and writes the cycle count to DIAG_RESULT
pub fn runDiag() void {
    const SRC = spec.REGIONS[0].src; // EWRAM
    const DST = spec.REGIONS[0].dst; // EWRAM
    const res: [*]volatile u32 = @ptrFromInt(DIAG_RESULT);
    inline for (spec.DIAG, 0..) |dg, i| {
        const sp: [*]volatile u8 = @ptrFromInt(SRC);
        var k: usize = 0;
        while (k < dg.bytes) : (k += 1) sp[k] = dg.fill;
        const info: [*]volatile u32 = @ptrFromInt(INFO_ADDR);
        info[0] = @as(u32, dg.bytes) | (1 << 16) | (8 << 24); // src_len, src_width=1, dst_width=8
        info[1] = 0; // data_offset = 0
        const out_words = (@as(usize, dg.bytes) * 8 + 3) / 4;
        const dp: [*]volatile u32 = @ptrFromInt(DST);
        var w: usize = 0;
        while (w < out_words) : (w += 1) dp[w] = 0;
        res[i] = gba.execAt(spec.bit_unpack_swi, SRC, DST, INFO_ADDR, 0);
    }
}

pub const BUP_RESULT: u32 = layout.perm_bup.base;
const BUP_INFO_IW: u32 = 0x03000800;

fn bupAddr(loc: spec.Loc, ro: u32, iw: u32, ew: u32) u32 {
    return switch (loc) {
        .ro => ro,
        .iw => iw,
        .ew => ew,
    };
}

/// Runs BitUnPack for each spec.BUP_PLACES x width x offset case and writes the cycle count to BUP_RESULT
pub fn runBup() void {
    const res: [*]volatile u32 = @ptrFromInt(BUP_RESULT);
    for (spec.BUP_PLACES, 0..) |pl, p| {
        for (spec.BUP_WIDTHS, 0..) |w, wi| {
            for (0..spec.BUP_OFFSETS.len) |oi| {
                const k = wi * spec.BUP_OFFSETS.len + oi;
                const info = bupAddr(pl.info, @intFromPtr(&spec.BUP_INFO[k]), BUP_INFO_IW, INFO_ADDR);
                const src = bupAddr(pl.src, @intFromPtr(&spec.BUP_SRC), spec.REGIONS[1].src, spec.REGIONS[0].src);
                const dst = bupAddr(pl.dst, 0, spec.REGIONS[1].dst, spec.REGIONS[0].dst);
                if (pl.info != .ro) stage(info, std.mem.asBytes(&spec.BUP_INFO[k]));
                if (pl.src != .ro) stage(src, &spec.BUP_SRC);
                zeroR(dst, (spec.BUP_SRC.len * @as(usize, w.dw)) >> @intCast(@ctz(w.sw)));
                res[p * spec.BUP_K + k] = gba.execAt(spec.bit_unpack_swi, src, dst, info, 0);
            }
        }
    }
}

/// Run every (op x src-region x dst-region) permutation and write {cycles, dst-checksum} to RESULT
pub fn runMatrix() void {
    const res: [*]volatile u32 = @ptrFromInt(RESULT);
    inline for (spec.OPS, 0..) |op, o| {
        for (spec.REGIONS, 0..) |sr, si| {
            for (spec.REGIONS, 0..) |dr, di| {
                stage(sr.src, op.src);
                zeroR(dr.dst, op.out_bytes);
                var r2 = op.r2;
                if (op.info) |info| {
                    stage(INFO_ADDR, info);
                    r2 = INFO_ADDR;
                }
                const cyc = gba.execAt(op.swi, sr.src, dr.dst, r2, op.r3);
                const sum = sumR(dr.dst, op.out_bytes);
                const idx = o * spec.N * spec.N + si * spec.N + di;
                res[idx * 2] = cyc;
                res[idx * 2 + 1] = sum;
            }
        }
    }
}

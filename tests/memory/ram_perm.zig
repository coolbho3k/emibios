// SPDX-License-Identifier: MIT
//! Table-driven spec for the RAM-region copy permutation matrix. Each RAM-copy SWI runs over every
//! (src region x dst region) pair, copying a fixed 32-byte fixture and checking the destination
//! checksum plus the TM0 cycle count.
const std = @import("std");
const layout = @import("layout");

// Fixed BIOS SWI numbers
const SWI = struct {
    const cpu_set = 0x0B;
    const cpu_fast_set = 0x0C;
    const bit_unpack = 0x10;
    const lz77_wram = 0x11;
    const lz77_vram = 0x12;
    const huff = 0x13;
    const rl_wram = 0x14;
    const rl_vram = 0x15;
    const diff8_wram = 0x16;
    const diff8_vram = 0x17;
    const diff16 = 0x18;
};

pub const bit_unpack_swi = SWI.bit_unpack;

// BitUnPack EW->EW hardware reference timing fixtures with data_offset 0.
pub const Diag = struct { bytes: u16, fill: u8, cyc: u32 };
pub const DIAG = [_]Diag{
    .{ .bytes = 4, .fill = 0x00, .cyc = 982 }, // nz=0
    .{ .bytes = 8, .fill = 0x00, .cyc = 1802 }, // nz=0
    .{ .bytes = 16, .fill = 0x00, .cyc = 3442 }, // nz=0
    .{ .bytes = 4, .fill = 0xFF, .cyc = 1046 }, // nz=32
    .{ .bytes = 8, .fill = 0xFF, .cyc = 1930 }, // nz=64
};

// BitUnPack placement matrix: each width and data_offset case runs with the info block, source and
// destination placed in ROM, IWRAM or EWRAM (names read info/src>dst). The goldens are hardware-reference
// measurements.
pub const Loc = enum { ro, iw, ew };
pub const BupWidth = struct { sw: u8, dw: u8 };
pub const BUP_WIDTHS = [_]BupWidth{
    .{ .sw = 1, .dw = 1 },  .{ .sw = 1, .dw = 2 },  .{ .sw = 1, .dw = 4 }, .{ .sw = 1, .dw = 8 },
    .{ .sw = 1, .dw = 16 }, .{ .sw = 1, .dw = 32 }, .{ .sw = 2, .dw = 8 }, .{ .sw = 4, .dw = 16 },
    .{ .sw = 8, .dw = 32 },
};
pub const BUP_OFFSETS = [_]u32{ 0, 0x10 };
pub const BUP_K = BUP_WIDTHS.len * BUP_OFFSETS.len;
pub const BUP_SRC align(4) = [_]u8{ 0xA5, 0x00, 0x3C, 0xFF };
pub const BUP_INFO: [BUP_K][2]u32 = blk: {
    var t: [BUP_K][2]u32 = undefined;
    for (BUP_WIDTHS, 0..) |w, wi| {
        for (BUP_OFFSETS, 0..) |off, oi| {
            t[wi * BUP_OFFSETS.len + oi] = .{ BUP_SRC.len | (@as(u32, w.sw) << 16) | (@as(u32, w.dw) << 24), off };
        }
    }
    break :blk t;
};
pub const BupPlace = struct { name: []const u8, info: Loc, src: Loc, dst: Loc };
pub const BUP_PLACES = blk: {
    var t: [18]BupPlace = undefined;
    var n: usize = 0;
    for ([_]Loc{ .ro, .iw, .ew }) |i| {
        for ([_]Loc{ .ro, .iw, .ew }) |sr| {
            for ([_]Loc{ .iw, .ew }) |d| {
                t[n] = .{ .name = @tagName(i) ++ "/" ++ @tagName(sr) ++ ">" ++ @tagName(d), .info = i, .src = sr, .dst = d };
                n += 1;
            }
        }
    }
    break :blk t;
};
// [place][width * BUP_OFFSETS.len + offset] TM0 cycles.
pub const BUP_GOLDEN = [BUP_PLACES.len][BUP_K]u32{
    .{ 978, 978, 980, 980, 984, 984, 992, 992, 1008, 1008, 1040, 1040, 620, 620, 436, 436, 342, 342 }, // ro/ro>iw
    .{ 983, 983, 990, 990, 1004, 1004, 1032, 1032, 1088, 1088, 1200, 1200, 640, 640, 456, 456, 362, 362 }, // ro/ro>ew
    .{ 962, 962, 964, 964, 968, 968, 976, 976, 992, 992, 1024, 1024, 604, 604, 420, 420, 326, 326 }, // ro/iw>iw
    .{ 967, 967, 974, 974, 988, 988, 1016, 1016, 1072, 1072, 1184, 1184, 624, 624, 440, 440, 346, 346 }, // ro/iw>ew
    .{ 970, 970, 972, 972, 976, 976, 984, 984, 1000, 1000, 1032, 1032, 612, 612, 428, 428, 334, 334 }, // ro/ew>iw
    .{ 975, 975, 982, 982, 996, 996, 1024, 1024, 1080, 1080, 1192, 1192, 632, 632, 448, 448, 354, 354 }, // ro/ew>ew
    .{ 952, 952, 954, 954, 958, 958, 966, 966, 982, 982, 1014, 1014, 594, 594, 410, 410, 316, 316 }, // iw/ro>iw
    .{ 957, 957, 964, 964, 978, 978, 1006, 1006, 1062, 1062, 1174, 1174, 614, 614, 430, 430, 336, 336 }, // iw/ro>ew
    .{ 936, 936, 938, 938, 942, 942, 950, 950, 966, 966, 998, 998, 578, 578, 394, 394, 300, 300 }, // iw/iw>iw
    .{ 941, 941, 948, 948, 962, 962, 990, 990, 1046, 1046, 1158, 1158, 598, 598, 414, 414, 320, 320 }, // iw/iw>ew
    .{ 944, 944, 946, 946, 950, 950, 958, 958, 974, 974, 1006, 1006, 586, 586, 402, 402, 308, 308 }, // iw/ew>iw
    .{ 949, 949, 956, 956, 970, 970, 998, 998, 1054, 1054, 1166, 1166, 606, 606, 422, 422, 328, 328 }, // iw/ew>ew
    .{ 968, 968, 970, 970, 974, 974, 982, 982, 998, 998, 1030, 1030, 610, 610, 426, 426, 332, 332 }, // ew/ro>iw
    .{ 973, 973, 980, 980, 994, 994, 1022, 1022, 1078, 1078, 1190, 1190, 630, 630, 446, 446, 352, 352 }, // ew/ro>ew
    .{ 952, 952, 954, 954, 958, 958, 966, 966, 982, 982, 1014, 1014, 594, 594, 410, 410, 316, 316 }, // ew/iw>iw
    .{ 957, 957, 964, 964, 978, 978, 1006, 1006, 1062, 1062, 1174, 1174, 614, 614, 430, 430, 336, 336 }, // ew/iw>ew
    .{ 960, 960, 962, 962, 966, 966, 974, 974, 990, 990, 1022, 1022, 602, 602, 418, 418, 324, 324 }, // ew/ew>iw
    .{ 965, 965, 972, 972, 986, 986, 1014, 1014, 1070, 1070, 1182, 1182, 622, 622, 438, 438, 344, 344 }, // ew/ew>ew
};

pub const Region = struct { name: []const u8, src: u32, dst: u32 };
pub const REGIONS = [_]Region{
    .{ .name = "EW", .src = layout.perm_src.base, .dst = layout.perm_dst.base }, // EWRAM, clear of State + scratch
    .{ .name = "IW", .src = 0x03000000, .dst = 0x03000400 }, // IWRAM low (stack lives at the top)
    .{ .name = "PR", .src = 0x05000000, .dst = 0x05000200 }, // PRAM (1KB; unused in mode 3)
    .{ .name = "VR", .src = 0x06015000, .dst = 0x06016000 }, // VRAM above the framebuffer
    .{ .name = "OA", .src = 0x07000000, .dst = 0x07000200 }, // OAM (1KB; no sprites in mode 3)
};
pub const N = REGIONS.len;

// 8 words / 32 bytes: small enough that src+dst both fit a 1KB region (PRAM/OAM) for same-region pairs.
pub const FIX = [_]u32{ 0x11111111, 0x22222222, 0xDEADBEEF, 0x00000000, 0x0FF00FF0, 0xFFFFFFFF, 0x00000007, 0x80000000 };
pub const FIXB: []const u8 = std.mem.sliceAsBytes(FIX[0..]);

const WORD: u32 = 1 << 26; // CpuSet 32-bit units

// One op = one suite. `src` is staged into the src region and `out_bytes` is zeroed then checksummed
// at the dst region. `info`, if set, is staged at INFO_ADDR and pointed to by r2 (BitUnPack).
pub const Op = struct {
    name: []const u8,
    swi: u8,
    r2: u32 = 0,
    r3: u32 = 0,
    src: []const u8,
    out_bytes: usize,
    info: ?[]const u8 = null,
};
const copy_ops = [_]Op{
    .{ .name = "CpuSet32 copy", .swi = SWI.cpu_set, .r2 = 8 | WORD, .src = FIXB, .out_bytes = 32 },
    .{ .name = "CpuSet16 copy", .swi = SWI.cpu_set, .r2 = 16, .src = FIXB, .out_bytes = 32 },
    .{ .name = "CpuFastSet copy", .swi = SWI.cpu_fast_set, .r2 = 8, .src = FIXB, .out_bytes = 32 },
};
pub const OPS = copy_ops ++ decomp_ops; // decomp_ops appended below so copy indices stay stable

// Decompression fixtures, pre-generated by tests/decompression/codec.zig from the 16-byte original
// "ABCDABCDABCDABCD" (BitUnPack: a 4-byte 1->8 bit expansion). The 8-bit-write codecs produce
// region-dependent output.
const comp_lz77 = [_]u8{ 16, 16, 0, 0, 8, 65, 66, 67, 68, 144, 3, 0 }; // disp>=2, safe for WRAM + VRAM
const comp_rl = [_]u8{ 48, 16, 0, 0, 15, 65, 66, 67, 68, 65, 66, 67, 68, 65, 66, 67, 68, 65, 66, 67, 68, 0, 0, 0 };
const comp_huff = [_]u8{ 40, 16, 0, 0, 3, 0, 192, 193, 65, 66, 67, 68, 27, 27, 27, 27, 0, 0, 0, 0, 0, 0, 0, 0 };
const comp_diff8 = [_]u8{ 129, 16, 0, 0, 65, 1, 1, 1, 253, 1, 1, 1, 253, 1, 1, 1, 253, 1, 1, 1 };
const comp_diff16 = [_]u8{ 130, 16, 0, 0, 3, 20, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34 };
const bup_src = [_]u8{ 165, 60, 255, 1 };
const bup_info = [_]u8{ 4, 0, 1, 8, 0, 0, 0, 0 }; // src_len=4, src_w=1, dst_w=8, off=0 -> 32 bytes out
const decomp_ops = [_]Op{
    .{ .name = "LZ77w decomp", .swi = SWI.lz77_wram, .src = &comp_lz77, .out_bytes = 16 },
    .{ .name = "LZ77v decomp", .swi = SWI.lz77_vram, .src = &comp_lz77, .out_bytes = 16 },
    .{ .name = "RLw decomp", .swi = SWI.rl_wram, .src = &comp_rl, .out_bytes = 16 },
    .{ .name = "RLv decomp", .swi = SWI.rl_vram, .src = &comp_rl, .out_bytes = 16 },
    .{ .name = "Huff decomp", .swi = SWI.huff, .src = &comp_huff, .out_bytes = 16 },
    .{ .name = "Diff8w unfilt", .swi = SWI.diff8_wram, .src = &comp_diff8, .out_bytes = 16 },
    .{ .name = "Diff8v unfilt", .swi = SWI.diff8_vram, .src = &comp_diff8, .out_bytes = 16 },
    .{ .name = "Diff16 unfilt", .swi = SWI.diff16, .src = &comp_diff16, .out_bytes = 16 },
    .{ .name = "BitUnPack", .swi = SWI.bit_unpack, .src = &bup_src, .out_bytes = 32, .info = &bup_info },
};

// Hardware reference goldens per op, indexed [src*N + dst] in REGIONS order (EW,IW,PR,VR,OA), measured
// black box on the reference BIOS under forced blank. GOLDEN_CYC is TM0 cycles; GOLDEN_SUM is the
// additive byte checksum of the destination.
pub const GOLDEN_CYC = [OPS.len][N * N]u32{
    // CpuSet32 copy (8 words)
    .{
        286, 246, 254, 254, 246, // EW -> *
        246, 206, 214, 214, 206, // IW -> *
        254, 214, 222, 222, 214, // PR -> *
        254, 214, 222, 222, 214, // VR -> *
        246, 206, 214, 214, 206, // OA -> *
    },
    // CpuSet16 copy (16 halfwords)
    .{
        368, 336, 336, 336, 336,
        336, 304, 304, 304, 304,
        336, 304, 304, 304, 304,
        336, 304, 304, 304, 304,
        336, 304, 304, 304, 304,
    },
    // CpuFastSet copy (8 words)
    .{
        228, 188, 196, 196, 188,
        188, 148, 156, 156, 148,
        196, 156, 164, 164, 156,
        196, 156, 164, 164, 156,
        188, 148, 156, 156, 148,
    },
    .{ 404, 348, 348, 348, 348, 383, 327, 327, 327, 327, 384, 328, 328, 328, 328, 384, 328, 328, 328, 328, 383, 327, 327, 327, 327 }, // LZ77w decomp
    .{ 577, 537, 537, 537, 537, 556, 516, 516, 516, 516, 557, 517, 517, 517, 517, 557, 517, 517, 517, 517, 556, 516, 516, 516, 516 }, // LZ77v decomp
    .{ 385, 353, 353, 353, 353, 346, 314, 314, 314, 314, 347, 315, 315, 315, 315, 347, 315, 315, 315, 315, 346, 314, 314, 314, 314 }, // RLw decomp
    .{ 477, 461, 461, 461, 461, 438, 422, 422, 422, 422, 439, 423, 423, 423, 423, 439, 423, 423, 423, 423, 438, 422, 422, 422, 422 }, // RLv decomp
    .{ 1454, 1434, 1438, 1438, 1434, 1280, 1260, 1264, 1264, 1260, 1282, 1262, 1266, 1266, 1262, 1282, 1262, 1266, 1266, 1262, 1280, 1260, 1264, 1264, 1260 }, // Huff decomp
    .{ 389, 357, 357, 357, 357, 352, 320, 320, 320, 320, 353, 321, 321, 321, 321, 353, 321, 321, 321, 321, 352, 320, 320, 320, 320 }, // Diff8w unfilt
    .{ 479, 463, 463, 463, 463, 442, 426, 426, 426, 426, 443, 427, 427, 427, 427, 443, 427, 427, 427, 427, 442, 426, 426, 426, 426 }, // Diff8v unfilt
    .{ 253, 237, 237, 237, 237, 232, 216, 216, 216, 216, 233, 217, 217, 217, 217, 233, 217, 217, 217, 217, 232, 216, 216, 216, 216 }, // Diff16 unfilt
    .{ 1016, 976, 984, 984, 976, 1008, 968, 976, 976, 968, 1008, 968, 976, 976, 968, 1008, 968, 976, 976, 968, 1008, 968, 976, 976, 968 }, // BitUnPack
};
// 8-bit-write codecs: stores land in EW/IW (sum 1064), byte-duplicate in PR (sum 1072), and are
// dropped in VR/OA.
const W0 = [_]u32{ 1064, 1064, 1072, 0, 0 } ** N;
pub const GOLDEN_SUM = [OPS.len][N * N]u32{
    .{2693} ** (N * N), // CpuSet32 copy: dst == FIX, sum(FIX) = 2693
    .{2693} ** (N * N), // CpuSet16 copy
    .{2693} ** (N * N), // CpuFastSet copy
    W0, // LZ77w decomp
    .{1064} ** (N * N), // LZ77v decomp
    W0, // RLw decomp
    .{1064} ** (N * N), // RLv decomp
    .{1064} ** (N * N), // Huff decomp
    W0, // Diff8w unfilt
    .{1064} ** (N * N), // Diff8v unfilt
    .{1832} ** (N * N), // Diff16 unfilt
    .{17} ** (N * N), // BitUnPack
};

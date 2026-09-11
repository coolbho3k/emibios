// SPDX-License-Identifier: GPL-3.0-or-later
//! Prints BIOS size usage from the installed binary and ELF symbol table.
//! SWI ordering comes from src/swi/swi_table.s so the report follows the dispatch table.
const std = @import("std");
const Io = std.Io;
const CAP: u32 = 16 * 1024;

const Sym = std.StringHashMap(u32);

fn rd32(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .little);
}
fn rd16(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .little);
}

// Walks the ELF32 section table directly.
// ARM mapping symbols are skipped because they do not name reportable code spans.
fn parseElf(gpa: std.mem.Allocator, d: []const u8) !Sym {
    var syms = Sym.init(gpa);
    if (d.len < 0x34 or !std.mem.eql(u8, d[0..4], "\x7fELF") or d[4] != 1) return error.NotElf32;
    const e_shoff = rd32(d, 0x20);
    const e_shentsize = rd16(d, 0x2E);
    const e_shnum = rd16(d, 0x30);

    var symtab_off: usize = 0;
    var symtab_size: usize = 0;
    var symtab_entsize: usize = 0;
    var strtab_off: usize = 0;
    var i: u16 = 0;
    while (i < e_shnum) : (i += 1) {
        const sh = e_shoff + @as(usize, i) * e_shentsize;
        if (rd32(d, sh + 4) == 2) { // SHT_SYMTAB
            symtab_off = rd32(d, sh + 16);
            symtab_size = rd32(d, sh + 20);
            symtab_entsize = rd32(d, sh + 36);
            const link = rd32(d, sh + 24); // sh_link -> .strtab section index
            strtab_off = rd32(d, e_shoff + @as(usize, link) * e_shentsize + 16);
        }
    }
    if (symtab_entsize == 0) return error.NoSymtab;

    var k: usize = 0;
    while (k < symtab_size / symtab_entsize) : (k += 1) {
        const off = symtab_off + k * symtab_entsize;
        const st_name = rd32(d, off);
        const st_value = rd32(d, off + 4);
        if (st_name == 0) continue;
        const start = strtab_off + st_name;
        const len = std.mem.indexOfScalar(u8, d[start..], 0) orelse continue;
        const name = d[start .. start + len];
        if (name.len != 0 and name[0] != '$' and !syms.contains(name)) {
            try syms.put(name, st_value);
        }
    }
    return syms;
}

const Entry = struct { idx: usize, name: []const u8, sym: []const u8, mode: []const u8 };

// The assembly comment after swi_DoNothing is the public name for unimplemented SWIs.
fn parseSwiTable(gpa: std.mem.Allocator, src: []const u8) !std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    var in_table = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!in_table) {
            if (std.mem.eql(u8, line, "swi_table:")) in_table = true;
            continue;
        }
        if (line.len == 0 or line[line.len - 1] == ':') break;
        const wpos = std.mem.indexOf(u8, line, ".hword") orelse continue;
        const body_full = line[wpos + 6 ..];
        const at = std.mem.indexOfScalar(u8, body_full, '@');
        const body = std.mem.trim(u8, if (at) |a| body_full[0..a] else body_full, " \t");
        const comment = if (at) |a| std.mem.trim(u8, body_full[a + 1 ..], " \t") else "";
        // entries are written as `(sym [+ 1] - bios_base)` so the assembler folds them reloc-free
        const stripped = std.mem.trim(u8, body, "() \t");
        const minus = std.mem.indexOfScalar(u8, stripped, '-');
        const core = std.mem.trim(u8, if (minus) |m| stripped[0..m] else stripped, " \t");
        const plus = std.mem.indexOfScalar(u8, core, '+');
        const mode: []const u8 = if (plus != null) "Thumb" else "ARM";
        const sym = std.mem.trim(u8, if (plus) |p| core[0..p] else core, " \t");
        var name: []const u8 = undefined;
        if (std.mem.eql(u8, sym, "swi_DoNothing") and comment.len != 0) {
            const paren = std.mem.indexOfScalar(u8, comment, '(');
            name = std.mem.trim(u8, if (paren) |p| comment[0..p] else comment, " \t");
        } else {
            name = if (std.mem.startsWith(u8, sym, "swi_")) sym[4..] else sym;
        }
        try out.append(gpa, .{ .idx = out.items.len, .name = name, .sym = sym, .mode = mode });
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    var sfw: Io.File.Writer = .init(.stdout(), io, &.{});
    const w = &sfw.interface;

    const cwd = Io.Dir.cwd();
    const elf = try cwd.readFileAlloc(io, "zig-out/bin/bios.elf", gpa, .limited(4 * 1024 * 1024));
    const bin = try cwd.readFileAlloc(io, "zig-out/bin/gba_bios.bin", gpa, .limited(2 * CAP));
    const src = try cwd.readFileAlloc(io, "src/swi/swi_table.s", gpa, .limited(8 * 1024 * 1024));

    const syms = try parseElf(gpa, elf);
    const entries = try parseSwiTable(gpa, src);

    var used: u32 = 0;
    for (bin, 0..) |b, idx| if (b != 0) {
        used = @intCast(idx + 1);
    };
    const free = CAP - used;

    // Shared dispatch targets should not create zero-size duplicate spans.
    var starts: std.ArrayList(u32) = .empty;
    for (entries.items) |e| if (syms.get(e.sym)) |a| {
        var dup = false;
        for (starts.items) |s| if (s == a) {
            dup = true;
        };
        if (!dup) try starts.append(gpa, a);
    };
    // End the MultiBoot size range at the receiver, and the HardReset range at the IRQ handler.
    if (syms.get("multiboot_receiver_detect")) |cap| try starts.append(gpa, cap);
    if (syms.get("exception_irq")) |cap| try starts.append(gpa, cap);
    std.mem.sort(u32, starts.items, {}, std.sort.asc(u32));
    var span = std.AutoHashMap(u32, u32).init(gpa);
    for (starts.items, 0..) |a, i| {
        const nxt = if (i + 1 < starts.items.len) starts.items[i + 1] else used;
        try span.put(a, if (nxt > a) nxt - a else 0);
    }

    try w.print("\nBIOS space report\n", .{});
    try w.print(
        "  used: {d:5} / {d} bytes ({d:.1}%)\n",
        .{ used, CAP, @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(CAP)) * 100 },
    );
    try w.print("  free: {d:5} bytes (0x{X:0>4})\n\n", .{ free, free });

    // ---- region summary. File-boundary symbols split the image into coarse regions; the
    // boot screen file also holds the receiver's progress UI and shared render helpers,
    // hence the combined label. ----
    // HardReset lives at 0x68 inside the reset region, so the resident-SWI region starts at
    // the first handler past the pinned 0x128 IRQ handler instead of the raw minimum.
    var min_swi: u32 = used;
    for (entries.items) |e| if (syms.get(e.sym)) |a| {
        if (a >= 0x128 and a < min_swi) min_swi = a;
    };
    const marks = [_]struct { sym: []const u8, label: []const u8 }{
        .{ .sym = "multiboot_receiver_detect", .label = "multiboot receiver" },
        .{ .sym = "bs_blob", .label = "boot assets" },
        .{ .sym = "boot_screen_entry", .label = "boot screen + receive UI" },
        .{ .sym = "boot_final_burn", .label = "handoff tail" },
    };
    var regions: std.ArrayList(struct { start: u32, label: []const u8 }) = .empty;
    try regions.append(gpa, .{ .start = 0, .label = "core" });
    try regions.append(gpa, .{ .start = min_swi, .label = "resident SWIs" });
    for (marks) |m| if (syms.get(m.sym)) |a| try regions.append(gpa, .{ .start = a, .label = m.label });
    std.mem.sort(@TypeOf(regions.items[0]), regions.items, {}, struct {
        fn lt(_: void, x: @TypeOf(regions.items[0]), y: @TypeOf(regions.items[0])) bool {
            return x.start < y.start;
        }
    }.lt);
    try w.print("  region                                       start    size  hex\n", .{});
    try w.print("  -------------------------------------------  ------  -----  ------\n", .{});
    for (regions.items, 0..) |r, i| {
        const nxt = if (i + 1 < regions.items.len) regions.items[i + 1].start else used;
        const sz = if (nxt > r.start) nxt - r.start else 0;
        try w.print("  {s: <43}  0x{X:0>4}  {d:5}  0x{X:0>4}\n", .{ trunc(r.label, 43), r.start, sz, sz });
    }
    try w.print("\n", .{});
    try w.print("  SWI   name                            mode   start    size  hex\n", .{});
    try w.print("  ----  ------------------------------  -----  ------  -----  ------\n", .{});
    for (entries.items) |e| {
        if (syms.get(e.sym)) |a| {
            try w.print(
                "  0x{X:0>2}  {s: <30}  {s: <5}  0x{X:0>4}  {d:5}  0x{X:0>4}\n",
                .{ e.idx, trunc(e.name, 30), e.mode, a, span.get(a) orelse 0, span.get(a) orelse 0 },
            );
        } else {
            try w.print("  0x{X:0>2}  {s: <30}  {s: <5}  ?       ?\n", .{ e.idx, trunc(e.name, 30), e.mode });
        }
    }
    try w.flush();
}

fn trunc(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

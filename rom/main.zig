// SPDX-License-Identifier: MIT
//! BIOS test ROM that runs on GBA itself
const std = @import("std");
const gba = @import("gba");
const div = @import("swi_div_test");
const div_arm = @import("swi_div_arm_test");
const sqrt = @import("swi_sqrt_test");
const arc_tan = @import("swi_arc_tan_test");
const arc_tan2 = @import("swi_arc_tan2_test");
const bg_affine = @import("swi_bg_affine_set_test");
const obj_affine = @import("swi_obj_affine_set_test");
const cpuset = @import("swi_cpu_set_test");
const cpufast = @import("swi_cpu_fast_set_test");
const getbios = @import("swi_get_bios_checksum_test");
const sound_bias = @import("swi_sound_bias_test");
const midi = @import("swi_midi_key2freq_test");
const lz77 = @import("swi_lz77_test");
const rl = @import("swi_rl_test");
const huff = @import("swi_huff_test");
const diff = @import("swi_diff_test");
const bitunpack = @import("swi_bit_unpack_test");
const ram_perm = @import("ram_perm");
const perm = @import("perm");
const testing = @import("testing");
const layout = @import("layout");
const protocol = @import("protocol");
const manifest = @import("test_manifest");
const Bump = @import("bump.zig").Bump;
comptime {
    _ = @import("divrt.zig");
}

const font = @embedFile("font.bin");

export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SWITESTS", "SWIT");

// MMIO + framebuffer
const REG_DISPCNT: *volatile u16 = @ptrFromInt(0x04000000);
const VRAM: [*]volatile u16 = @ptrFromInt(0x06000000);
const W = 240;
const H = 160;

inline fn rgb(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r & 31)) | (@as(u16, g & 31) << 5) | (@as(u16, b & 31) << 10);
}

fn plot(x: usize, y: usize, c: u16) void {
    if (x >= W or y >= H) return;
    VRAM[y * W + x] = c;
}

fn clear(c: u16) void {
    const w32 = @as(u32, c) | (@as(u32, c) << 16);
    const p: [*]volatile u32 = @ptrFromInt(0x06000000);
    var i: usize = 0;
    while (i < W * H / 2) : (i += 1) p[i] = w32;
}

// Fill a full-width band of ROW_H scanlines starting at `y`
fn fillRow(y: usize, c: u16) void {
    const w32 = @as(u32, c) | (@as(u32, c) << 16);
    const p: [*]volatile u32 = @ptrFromInt(0x06000000 + y * W * 2);
    var i: usize = 0;
    while (i < W * ROW_H / 2) : (i += 1) p[i] = w32;
}

// Erase one 8x8 glyph cell to the background
fn clearCell(x: usize, y: usize) void {
    for (0..ROW_H) |r| {
        for (0..8) |cx| plot(x + cx, y + r, bg);
    }
}

fn drawChar(x: usize, y: usize, ch: u8, c: u16) void {
    if (ch < 0x20 or ch > 0x7E) return;
    const g = font[(@as(usize, ch) - 0x20) * 8 ..][0..8];
    for (0..8) |row| {
        const bits = g[row];
        for (0..8) |col| {
            if ((bits >> @intCast(col)) & 1 != 0) plot(x + col, y + row, c);
        }
    }
}

fn drawStr(x: usize, y: usize, s: []const u8, c: u16) void {
    var cx = x;
    for (s) |ch| {
        drawChar(cx, y, ch, c);
        cx += 8;
    }
}

// Render 32 bits as 8 hex digits
fn drawHex32(x: usize, y: usize, v: u32, c: u16) void {
    const digits = "0123456789ABCDEF";
    for (0..8) |i| drawChar(x + i * 8, y, digits[(v >> @intCast((7 - i) * 4)) & 0xF], c);
}

// Decimal render
fn drawDec(x: usize, y: usize, v: u32, c: u16) void {
    var buf: [10]u8 = undefined;
    var n = v;
    var i: usize = 0;
    if (n == 0) {
        drawChar(x, y, '0', c);
        return;
    }
    while (n > 0) {
        const d = gba.udiv(n, 10);
        buf[i] = '0' + @as(u8, @intCast(d.r));
        i += 1;
        n = d.q;
    }
    var k: usize = 0;
    while (k < i) : (k += 1) drawChar(x + k * 8, y, buf[i - 1 - k], c);
}

// Entry
const white = rgb(31, 31, 31);
const green = rgb(6, 31, 6);
const red = rgb(31, 7, 7);
const cyan = rgb(10, 28, 31);
const grey = rgb(18, 18, 20);
const bg = rgb(1, 2, 5);

fn okColor(ok: bool) u16 {
    return if (ok) green else red;
}
fn nameColor(ok: bool) u16 {
    return if (ok) white else red;
}
fn passColor(pass: u32, total: u32) u16 {
    return okColor(pass == total);
}

// Results model
const Type = enum(u8) { math, memory, regions, decompression, system, audio, handoff };
const TYPE_NAMES = [_][]const u8{ "MATH", "MEMORY", "REGIONS", "DECOMPRESS", "SYSTEM", "AUDIO", "HANDOFF" };

const Case = struct { name: []const u8, exp: u32, meas: u32, pass: bool };
const Test = struct { name: []const u8, typ: Type, first: u16, n: u16, pass: u16 };

const MAX_CASES = 2048;
const MAX_TESTS = 128;
const Item = struct { header: bool, idx: u16 };

const State = struct {
    cases: [MAX_CASES]Case,
    n_cases: u32,
    tests: [MAX_TESTS]Test,
    n_tests: u32,
    cur: u32,
    items: [MAX_TESTS + 8]Item,
    n_items: u32,
    screen: u8,
    sel: u32,
    menu_scroll: u32,
    det_test: u32,
    det_cursor: u32,
    det_scroll: u32,
    expected: bool,
    a_armed: bool,
};
const st: *State = @ptrFromInt(layout.state.base);
comptime {
    std.debug.assert(@sizeOf(State) <= layout.state.len);
}

fn beginTest(name: []const u8, typ: Type) void {
    st.tests[st.n_tests] = .{ .name = name, .typ = typ, .first = @intCast(st.n_cases), .n = 0, .pass = 0 };
    st.cur = st.n_tests;
    st.n_tests += 1;
}
fn addCase(name: []const u8, exp: u32, meas: u32, pass: bool) void {
    if (st.n_cases >= MAX_CASES) {
        st.tests[st.cur].n += 1;
        return;
    }
    st.cases[st.n_cases] = .{ .name = name, .exp = exp, .meas = meas, .pass = pass };
    st.n_cases += 1;
    st.tests[st.cur].n += 1;
    if (pass) st.tests[st.cur].pass += 1;
}

fn nameLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

fn sortTests() void {
    var i: usize = 1;
    while (i < st.n_tests) : (i += 1) {
        const key = st.tests[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0) : (j -= 1) {
            const t = st.tests[@intCast(j)];
            const after = @intFromEnum(t.typ) > @intFromEnum(key.typ) or
                (t.typ == key.typ and nameLess(key.name, t.name));
            if (!after) break;
            st.tests[@intCast(j + 1)] = t;
        }
        st.tests[@intCast(j + 1)] = key;
    }
}

fn buildMenu() void {
    st.n_items = 0;
    var last: i32 = -1;
    var t: u32 = 0;
    while (t < st.n_tests) : (t += 1) {
        const ty = @intFromEnum(st.tests[t].typ);
        if (@as(i32, ty) != last) {
            st.items[st.n_items] = .{ .header = true, .idx = @intCast(ty) };
            st.n_items += 1;
            last = ty;
        }
        st.items[st.n_items] = .{ .header = false, .idx = @intCast(t) };
        st.n_items += 1;
    }
}

const ROW_H = 8;
const TOP = 20;
const VISIBLE = (H - TOP) / ROW_H;
const MARK_X = 2;
const NAME_X = 14;
const CONTENT_R = 29 * 8;
const ARROW_X = 29 * 8;
const COL_VAL = 21 * 8;

const K_A = 0x01;
const K_B = 0x02;
const K_RIGHT = 0x10;
const K_LEFT = 0x20;
const K_UP = 0x40;
const K_DOWN = 0x80;
const DPAD = K_UP | K_DOWN | K_LEFT | K_RIGHT;
const REPEAT_DELAY = 14;
const REPEAT_RATE = 3;

fn numDigits(v: u32) usize {
    if (v < 10) return 1;
    if (v < 100) return 2;
    if (v < 1000) return 3;
    return 4;
}

// Draw a decimal right-aligned in `w` cells, padded with zeroes on the left
fn drawDecPad(x: usize, y: usize, v: u32, w: usize, c: u16) void {
    const d = numDigits(v);
    var k: usize = 0;
    while (k + d < w) : (k += 1) drawChar(x + k * 8, y, '0', c);
    drawDec(x + (w - d) * 8, y, v, c);
}

// Draw "pass/total" ending at x=right
fn drawFrac(right: usize, y: usize, pass: u32, total: u32, c: u16, min_w: usize) void {
    const dp = @max(numDigits(pass), min_w);
    const dt = @max(numDigits(total), min_w);
    const x = right - (dp + 1 + dt) * 8;
    drawDecPad(x, y, pass, dp, c);
    drawChar(x + dp * 8, y, '/', grey);
    drawDecPad(x + (dp + 1) * 8, y, total, dt, c);
}

// Scrollable list UI
const List = struct {
    cursor: *u32,
    scroll: *u32,
    count: u32,
    selectable: *const fn (gi: u32) bool,
    content: *const fn (y: usize, gi: u32) void,
};

fn rowY(i: usize) usize {
    return TOP + i * ROW_H;
}

fn drawArrow(x: usize, y: usize, down: bool, c: u16) void {
    for (0..4) |r| {
        const lo = if (down) r else 3 - r;
        const hi = if (down) 6 - r else 3 + r;
        var xx = lo;
        while (xx <= hi) : (xx += 1) plot(x + xx, y + 2 + r, c);
    }
}

// Draw the scroll indicator arrows
fn drawArrows(scroll: u32, count: u32) void {
    if (scroll > 0) drawArrow(ARROW_X, rowY(0), false, cyan);
    if (scroll + VISIBLE < count) drawArrow(ARROW_X, rowY(VISIBLE - 1), true, cyan);
}

fn drawSection(y: usize, name: []const u8) void {
    drawStr(MARK_X, y, name, cyan);
    var x = MARK_X + (name.len + 1) * 8;
    while (x + 8 <= W) : (x += 8) drawChar(x, y, '=', grey);
}

fn drawTitleBar(title: []const u8, pass: u32, total: u32) void {
    drawStr(MARK_X, 1, title, cyan);
    drawFrac(CONTENT_R, 1, pass, total, passColor(pass, total), 1);
}

fn clearSpan(x: usize, y: usize, w: usize) void {
    for (0..ROW_H) |r| {
        var cx = x;
        while (cx < x + w) : (cx += 1) plot(cx, y + r, bg);
    }
}

fn drawRow(list: *const List, view_i: usize) void {
    const y = rowY(view_i);
    fillRow(y, bg);
    const gi = list.scroll.* + view_i;
    if (gi >= list.count) return;
    list.content(y, gi);
    if (gi == list.cursor.*) drawChar(MARK_X, y, '>', white);
}

fn drawRows(list: *const List) void {
    var i: usize = 0;
    while (i < VISIBLE) : (i += 1) drawRow(list, i);
    drawArrows(list.scroll.*, list.count);
}

fn setMarker(view_i: usize, on: bool) void {
    const y = rowY(view_i);
    if (on) drawChar(MARK_X, y, '>', white) else clearCell(MARK_X, y);
}

fn homeSel(gi: u32) bool {
    return !st.items[gi].header;
}
fn homeRow(y: usize, gi: u32) void {
    const it = st.items[gi];
    if (it.header) {
        drawSection(y, TYPE_NAMES[it.idx]);
        return;
    }
    const t = st.tests[it.idx];
    drawStr(NAME_X, y, t.name, nameColor(t.pass == t.n));
    drawFrac(CONTENT_R, y, t.pass, t.n, passColor(t.pass, t.n), 2);
}
fn homeList() List {
    return .{ .cursor = &st.sel, .scroll = &st.menu_scroll, .count = st.n_items, .selectable = homeSel, .content = homeRow };
}
fn totals() struct { pass: u32, total: u32 } {
    var gp: u32 = 0;
    var gt: u32 = 0;
    var k: u32 = 0;
    while (k < st.n_tests) : (k += 1) {
        gp += st.tests[k].pass;
        gt += st.tests[k].n;
    }
    return .{ .pass = gp, .total = gt };
}
fn drawHomeHeader() void {
    const t = totals();
    drawTitleBar("TEST SUITES", t.pass, t.total);
}
fn renderHome() void {
    clear(bg);
    drawHomeHeader();
    const l = homeList();
    drawRows(&l);
}

fn detailSel(_: u32) bool {
    return true;
}
fn detailRow(y: usize, gi: u32) void {
    const t = st.tests[st.det_test];
    if (t.first + gi >= st.n_cases) {
        drawStr(NAME_X, y, "dropped", red);
        return;
    }
    const r = st.cases[t.first + gi];
    drawStr(NAME_X, y, r.name, nameColor(r.pass));
    if (st.expected) {
        drawHex32(COL_VAL, y, r.exp, if (r.pass) green else white);
    } else {
        drawHex32(COL_VAL, y, r.meas, okColor(r.pass));
    }
}
fn detailList() List {
    return .{ .cursor = &st.det_cursor, .scroll = &st.det_scroll, .count = st.tests[st.det_test].n, .selectable = detailSel, .content = detailRow };
}
fn drawValHeader() void {
    clearSpan(COL_VAL, 11, 8 * 8);
    drawStr(COL_VAL, 11, if (st.expected) "EXPECTED" else "MEASURED", grey);
}
fn drawDetailHeader() void {
    const t = st.tests[st.det_test];
    drawTitleBar(t.name, t.pass, t.n);
    drawStr(NAME_X, 11, "NAME", grey);
    drawValHeader();
}
fn renderDetail() void {
    clear(bg);
    drawDetailHeader();
    const l = detailList();
    drawRows(&l);
}

fn render() void {
    if (st.screen == 0) renderHome() else renderDetail();
}

const KEYINPUT: *volatile u16 = @ptrFromInt(0x04000130);
const VCOUNT: *volatile u16 = @ptrFromInt(0x04000006);

fn waitVBlank() void {
    while (VCOUNT.* >= 160) {}
    while (VCOUNT.* < 160) {}
}

// Captured BIOS to cart handoff state
const HANDOFF: u32 = layout.handoff.base;
comptime {
    std.debug.assert(HANDOFF == 0x02022000);
}

// The cart entry. Snapshots r0-r12/sp/lr/cpsr and the open bus latch.
export fn _start() linksection(".text.romstart") callconv(.naked) noreturn {
    asm volatile (
        \\ push {r0}
        \\ mov  r0, #0x02000000
        \\ add  r0, r0, #0x20000
        \\ add  r0, r0, #0x2000
        \\ str  r1, [r0, #4]
        \\ str  r2, [r0, #8]
        \\ str  r3, [r0, #12]
        \\ str  r4, [r0, #16]
        \\ str  r5, [r0, #20]
        \\ str  r6, [r0, #24]
        \\ str  r7, [r0, #28]
        \\ str  r8, [r0, #32]
        \\ str  r9, [r0, #36]
        \\ str  r10, [r0, #40]
        \\ str  r11, [r0, #44]
        \\ str  r12, [r0, #48]
        \\ ldr  r1, [sp]
        \\ str  r1, [r0, #0]
        \\ add  sp, sp, #4
        \\ str  sp, [r0, #52]
        \\ str  lr, [r0, #56]
        \\ mrs  r1, cpsr
        \\ str  r1, [r0, #60]
        \\ mov  r1, #0
        \\ ldr  r1, [r1]
        \\ str  r1, [r0, #64]
        \\ b    romMain
    );
}

fn maxScroll(count: u32) u32 {
    return if (count > VISIBLE) count - VISIBLE else 0;
}

fn onlyUnselectable(list: *const List, lo: u32, hi: u32) bool {
    var k = lo;
    while (k < hi) : (k += 1) if (list.selectable(k)) return false;
    return true;
}

fn firstSel(list: *const List) u32 {
    var i: u32 = 0;
    while (i < list.count) : (i += 1) if (list.selectable(i)) return i;
    return 0;
}

fn lastSel(list: *const List) u32 {
    var i = list.count;
    while (i > 0) {
        i -= 1;
        if (list.selectable(i)) return i;
    }
    return 0;
}

fn follow(list: *const List) void {
    const c = list.cursor.*;
    if (c < list.scroll.*) list.scroll.* = c;
    if (c >= list.scroll.* + VISIBLE) list.scroll.* = c - VISIBLE + 1;
    if (c == list.scroll.* and onlyUnselectable(list, 0, list.scroll.*)) list.scroll.* = 0;
    if (c == list.scroll.* + VISIBLE - 1 and onlyUnselectable(list, list.scroll.* + VISIBLE, list.count))
        list.scroll.* = maxScroll(list.count);
}

fn move(list: *const List, dir: i32) bool {
    var i: i32 = @intCast(list.cursor.*);
    while (true) {
        i += dir;
        if (i < 0 or i >= @as(i32, @intCast(list.count))) return false;
        if (list.selectable(@intCast(i))) {
            list.cursor.* = @intCast(i);
            follow(list);
            return true;
        }
    }
}

fn anchor(list: *const List) void {
    const c = list.cursor.*;
    if (c >= list.scroll.* and c < list.scroll.* + VISIBLE and list.selectable(c)) return;
    var i = list.scroll.*;
    const end = @min(list.scroll.* + VISIBLE, list.count);
    while (i < end) : (i += 1) if (list.selectable(i)) {
        list.cursor.* = i;
        return;
    };
}

fn navRow(list: *const List, dir: i32) void {
    const old_c = list.cursor.*;
    const old_s = list.scroll.*;
    if (!move(list, dir)) return;
    if (list.scroll.* != old_s) {
        drawRows(list);
    } else {
        setMarker(old_c - list.scroll.*, false);
        setMarker(list.cursor.* - list.scroll.*, true);
    }
}

fn navPage(list: *const List, dir: i32) void {
    const old_s = list.scroll.*;
    if (dir > 0) {
        list.scroll.* = @min(list.scroll.* + VISIBLE, maxScroll(list.count));
    } else {
        list.scroll.* = if (list.scroll.* > VISIBLE) list.scroll.* - VISIBLE else 0;
    }
    if (list.scroll.* == old_s) {
        const old_c = list.cursor.*;
        list.cursor.* = if (dir > 0) lastSel(list) else firstSel(list);
        if (list.cursor.* != old_c) {
            setMarker(old_c - list.scroll.*, false);
            setMarker(list.cursor.* - list.scroll.*, true);
        }
        return;
    }
    anchor(list);
    drawRows(list);
}

export fn romMain() callconv(.c) noreturn {
    REG_DISPCNT.* = 0x0080; // forced blank during the run so VRAM/PRAM/OAM is uncontended
    gba.timerInit();
    st.n_cases = 0;
    st.n_tests = 0;
    st.screen = 0;
    st.menu_scroll = 0;
    st.det_scroll = 0;
    st.det_cursor = 0;
    st.expected = false;
    st.a_armed = false;

    runAll();
    REG_DISPCNT.* = 0x0403; // mode 3, BG2 on
    sortTests();
    buildMenu();

    const home = homeList();
    st.sel = firstSel(&home);
    follow(&home);
    render();

    const t = totals();
    const summary: [*]volatile u32 = @ptrFromInt(layout.summary.base);
    summary[1] = t.pass;
    summary[2] = t.total;
    summary[0] = protocol.UI_MAGIC;

    var prev: u16 = 0;
    var repeat_cd: u32 = 0;
    while (true) {
        waitVBlank();
        const keys = ~KEYINPUT.* & 0x3FF;
        const edge = keys & ~prev;
        var act = edge;
        if (edge != 0) {
            repeat_cd = REPEAT_DELAY;
        } else if (keys != 0 and keys == prev) {
            if (repeat_cd > 0) repeat_cd -= 1;
            if (repeat_cd == 0) {
                act = keys & DPAD;
                repeat_cd = REPEAT_RATE;
            }
        }
        prev = keys;

        if (st.screen == 0) {
            const l = homeList();
            if (act & K_UP != 0) navRow(&l, -1);
            if (act & K_DOWN != 0) navRow(&l, 1);
            if (act & K_LEFT != 0) navPage(&l, -1);
            if (act & K_RIGHT != 0) navPage(&l, 1);
            if (edge & K_A != 0 and homeSel(st.sel)) {
                st.det_test = st.items[st.sel].idx;
                st.det_cursor = 0;
                st.det_scroll = 0;
                st.expected = false;
                st.a_armed = false;
                st.screen = 1;
                renderDetail();
            }
        } else {
            const l = detailList();
            const a_held = (keys & K_A) != 0;
            if (!a_held) st.a_armed = true;
            const want_exp = a_held and st.a_armed;
            if (want_exp != st.expected) {
                st.expected = want_exp;
                drawValHeader();
                drawRows(&l);
            }
            if (act & K_UP != 0) navRow(&l, -1);
            if (act & K_DOWN != 0) navRow(&l, 1);
            if (act & K_LEFT != 0) navPage(&l, -1);
            if (act & K_RIGHT != 0) navPage(&l, 1);
            if (edge & K_B != 0) {
                st.screen = 0;
                renderHome();
            }
        }
    }
}

fn runHandoff() void {
    const ho: [*]volatile u32 = @ptrFromInt(HANDOFF);
    addCase("r0=0", 0, ho[0], ho[0] == 0);
    addCase("r1=0", 0, ho[1], ho[1] == 0);
    addCase("r2=0", 0, ho[2], ho[2] == 0);
    addCase("r3=0", 0, ho[3], ho[3] == 0);
    addCase("r12=0", 0, ho[12], ho[12] == 0);
    addCase("latch", 0xE129F000, ho[16], ho[16] == 0xE129F000);
}

fn runPermSuite(comptime o: usize) void {
    const res: [*]volatile u32 = @ptrFromInt(perm.RESULT);
    inline for (ram_perm.REGIONS, 0..) |sr, si| {
        inline for (ram_perm.REGIONS, 0..) |dr, di| {
            const p = si * ram_perm.N + di;
            const idx = o * ram_perm.N * ram_perm.N + p;
            const cyc = res[idx * 2];
            const sum = res[idx * 2 + 1];
            const ok = cyc == ram_perm.GOLDEN_CYC[o][p] and sum == ram_perm.GOLDEN_SUM[o][p];
            addCase(std.fmt.comptimePrint("{s}>{s}", .{ sr.name, dr.name }), ram_perm.GOLDEN_CYC[o][p], cyc, ok);
        }
    }
}

fn recordCase(c: testing.Case) void {
    addCase(c.name, c.exp, c.meas, c.passed);
}

const SWI_TESTS = .{
    .{ "Div", Type.math, div, "swi_div_test" },
    .{ "DivArm", Type.math, div_arm, "swi_div_arm_test" },
    .{ "Sqrt", Type.math, sqrt, "swi_sqrt_test" },
    .{ "ArcTan", Type.math, arc_tan, "swi_arc_tan_test" },
    .{ "ArcTan2", Type.math, arc_tan2, "swi_arc_tan2_test" },
    .{ "BgAffineSet", Type.math, bg_affine, "swi_bg_affine_set_test" },
    .{ "ObjAffineSet", Type.math, obj_affine, "swi_obj_affine_set_test" },
    .{ "CpuSet", Type.memory, cpuset, "swi_cpu_set_test" },
    .{ "CpuFastSet", Type.memory, cpufast, "swi_cpu_fast_set_test" },
    .{ "LZ77UnComp", Type.decompression, lz77, "swi_lz77_test" },
    .{ "RLUnComp", Type.decompression, rl, "swi_rl_test" },
    .{ "HuffUnComp", Type.decompression, huff, "swi_huff_test" },
    .{ "DiffUnFilter", Type.decompression, diff, "swi_diff_test" },
    .{ "BitUnPack", Type.decompression, bitunpack, "swi_bit_unpack_test" },
    .{ "GetBiosChecksum", Type.system, getbios, "swi_get_bios_checksum_test" },
    .{ "SoundBias", Type.audio, sound_bias, "swi_sound_bias_test" },
    .{ "MidiKey2Freq", Type.audio, midi, "swi_midi_key2freq_test" },
};

comptime {
    std.debug.assert(SWI_TESTS.len == manifest.swi_tests.len);
    for (manifest.swi_tests) |mt| {
        var found = false;
        for (SWI_TESTS) |entry| {
            if (std.mem.eql(u8, entry[3], mt.module)) found = true;
        }
        if (!found) @compileError("test_manifest module missing from SWI_TESTS: " ++ mt.module);
    }
}

fn runDiagSuite() void {
    const res: [*]volatile u32 = @ptrFromInt(perm.DIAG_RESULT);
    inline for (ram_perm.DIAG, 0..) |dg, i| {
        const cyc = res[i];
        addCase(std.fmt.comptimePrint("{d}B fill {X:0>2}", .{ dg.bytes, dg.fill }), dg.cyc, cyc, cyc == dg.cyc);
    }
}

fn runAll() void {
    var bump = Bump.init(layout.bump.base, layout.bump.len);
    testing.setSink(&recordCase);
    perm.runMatrix();
    perm.runDiag();
    inline for (SWI_TESTS) |entry| {
        beginTest(entry[0], entry[1]);
        testing.setSuite(entry[0]);
        bump.reset();
        entry[2].run(testing, bump.allocator()) catch addCase("run error", 0, 0, false);
        if (bump.outstanding != 0) addCase("leaked bytes", @intCast(bump.outstanding), 0, false);
    }
    beginTest("Handoff", Type.handoff);
    runHandoff();
    inline for (0..ram_perm.OPS.len) |o| {
        beginTest(ram_perm.OPS[o].name, Type.regions);
        runPermSuite(o);
    }
    beginTest("BitUnPackDiag", Type.regions);
    runDiagSuite();
}

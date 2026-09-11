// SPDX-License-Identifier: GPL-3.0-or-later
//! Style linter for the GBA BIOS assembly sources. Pass --fix to apply (zig build lint -Dfix=true).
//! Assembly style rules:
//!   - 4 spaces per indent, never tabs; no trailing whitespace; files end in exactly one newline.
//!   - structural directives (.thumb/.arm, .text/.data/.section, .global, .align/.p2align, ...) sit
//!     flush-left in column 0; data (.word/.byte/...) and symbol-defs (.equ/.set) keep their indent.
//!   - within a block (a run of code lines between labels, blank lines, or comment lines) operands align
//!     to one column and inline comments to another (one space past the longest mnemonic / code).
//!   - a run of .set/.equ lines aligns its values to one column the same way (full-line comments do not
//!     break the run).
//!   - one space after a comma, none before; lowercase r0-r15 and 0x hex; one space after '@'.
//!   - no blank line directly after a label; never two blank lines in a row; a blank line may
//!     precede only a comment or directive (a section break is blank + comment), never a label
//!     or instruction.
//!   - no multi-line inline comment; hoist it to a block above the instruction so the next line stays put.
//!   - warnings: lines over 120 columns; UPPER_SNAKE .equ/.set names; lower_snake / swi_<Name> labels;
//!     an instruction before any .arm/.thumb (each file declares its own mode; state leaks across #includes).
const std = @import("std");
const Io = std.Io;

const MAX_LEN: usize = 120;

// Diagnostics
const Reporter = struct {
    w: *Io.Writer,
    rel: []const u8 = "",
    n_err: usize = 0,
    n_warn: usize = 0,

    fn note(self: *Reporter, level: []const u8, line: usize, col: usize, rule: []const u8, msg: []const u8) !void {
        try self.w.print("{s}:{d}:{d}: {s} {s}: {s}\n", .{ self.rel, line, col, level, rule, msg });
    }
    fn err(self: *Reporter, line: usize, col: usize, rule: []const u8, msg: []const u8) !void {
        self.n_err += 1;
        try self.note("error", line, col, rule, msg);
    }
    fn warn(self: *Reporter, line: usize, col: usize, rule: []const u8, msg: []const u8) !void {
        self.n_warn += 1;
        try self.note("warn", line, col, rule, msg);
    }
};

// Text helpers
fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn rstrip(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r')) e -= 1;
    return s[0..e];
}

fn leadingSpaces(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    return i;
}

// Split at the first comment marker outside a string. The comment keeps the marker.
fn splitComment(line: []const u8) struct { code: []const u8, comment: []const u8 } {
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
        } else if (c == '"') {
            in_str = true;
        } else if (c == '@') {
            return .{ .code = line[0..i], .comment = line[i..] };
        }
    }
    return .{ .code = line, .comment = "" };
}

// Name predicates for the warning rules
fn isUpperSnake(s: []const u8) bool {
    if (s.len == 0 or !(s[0] >= 'A' and s[0] <= 'Z')) return false;
    for (s) |c| if (!((c >= 'A' and c <= 'Z') or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

fn isLowerSnake(s: []const u8) bool {
    if (s.len == 0 or !(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s) |c| if (!((c >= 'a' and c <= 'z') or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

fn isSwiName(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "swi_")) return false;
    const r = s[4..];
    if (r.len == 0 or !std.ascii.isAlphabetic(r[0])) return false;
    for (r) |c| if (!isWord(c)) return false;
    return true;
}

// The declared name of a top-level `.equ` / `.set` (whitespace may precede the directive), else null.
fn equName(line: []const u8) ?[]const u8 {
    var s: usize = 0;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t')) s += 1;
    const rest = line[s..];
    if (!std.mem.startsWith(u8, rest, ".equ") and !std.mem.startsWith(u8, rest, ".set")) return null;
    var j: usize = 4; // ".equ" and ".set" are both 4 chars
    if (j >= rest.len or !(rest[j] == ' ' or rest[j] == '\t')) return null;
    while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) j += 1;
    const start = j;
    if (j >= rest.len or !(std.ascii.isAlphabetic(rest[j]) or rest[j] == '_')) return null;
    while (j < rest.len and isWord(rest[j])) j += 1;
    return rest[start..j];
}

// The name of a global label (one starting in column 0, not a local `.label`), else null.
fn globalLabel(line: []const u8) ?[]const u8 {
    if (line.len == 0 or !(std.ascii.isAlphabetic(line[0]) or line[0] == '_')) return null;
    var i: usize = 0;
    while (i < line.len and isWord(line[i])) i += 1;
    if (i >= line.len or line[i] != ':') return null;
    return line[0..i];
}

// A line that is nothing but a label (optional indent, name, ':', optional trailing space).
fn isLabelLine(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    const start = i;
    if (i >= s.len or !(std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == '.')) return false;
    while (i < s.len and (isWord(s[i]) or s[i] == '.')) i += 1;
    if (i == start or i >= s.len or s[i] != ':') return false;
    i += 1;
    while (i < s.len) : (i += 1) if (s[i] != ' ' and s[i] != '\t') return false;
    return true;
}

// Apply SegFn to text outside string literals.
const SegFn = *const fn (std.mem.Allocator, *std.ArrayList(u8), []const u8) anyerror!void;

fn mapOutsideStrings(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, f: SegFn) !void {
    var in_str = false;
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (c == '\\') {
                try out.append(gpa, c);
                if (i + 1 < s.len) {
                    try out.append(gpa, s[i + 1]);
                    i += 1;
                }
                continue;
            }
            try out.append(gpa, c);
            if (c == '"') in_str = false;
        } else if (c == '"') {
            try f(gpa, out, s[run_start..i]);
            try out.append(gpa, c);
            in_str = true;
        } else if (i == s.len - 1) {
            try f(gpa, out, s[run_start .. i + 1]);
        }
        if (!in_str and c == '"') run_start = i + 1;
    }
}

fn applyWhole(gpa: std.mem.Allocator, line: []const u8, f: SegFn) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try mapOutsideStrings(gpa, &out, line, f);
    return out.items;
}

// Comment text keeps its spelling and spacing, so most fixers run only on the code.
fn applyCode(gpa: std.mem.Allocator, line: []const u8, f: SegFn) ![]const u8 {
    const sc = splitComment(line);
    var out: std.ArrayList(u8) = .empty;
    try mapOutsideStrings(gpa, &out, sc.code, f);
    try out.appendSlice(gpa, sc.comment);
    return out.items;
}

fn segTabs(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    for (seg) |c| {
        if (c == '\t') try out.appendSlice(gpa, "    ") else try out.append(gpa, c);
    }
}

// Lowercase 0x hex literals.
fn segHex(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    var i: usize = 0;
    while (i < seg.len) {
        if (seg[i] == '0' and i + 2 < seg.len and (seg[i + 1] == 'x' or seg[i + 1] == 'X') and isHex(seg[i + 2])) {
            try out.appendSlice(gpa, "0x");
            i += 2;
            while (i < seg.len and isHex(seg[i])) : (i += 1) try out.append(gpa, std.ascii.toLower(seg[i]));
        } else {
            try out.append(gpa, seg[i]);
            i += 1;
        }
    }
}

// Lowercase an uppercase r0..r15 register that stands as its own word.
fn segReg(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    var i: usize = 0;
    while (i < seg.len) {
        if (seg[i] == 'R' and i + 1 < seg.len and std.ascii.isDigit(seg[i + 1])) {
            var j = i + 1;
            while (j < seg.len and std.ascii.isDigit(seg[j])) j += 1;
            const before_ok = i == 0 or !isWord(seg[i - 1]);
            const after_ok = j == seg.len or !isWord(seg[j]);
            const num = std.fmt.parseInt(u8, seg[i + 1 .. j], 10) catch 99;
            if (before_ok and after_ok and num <= 15) {
                try out.append(gpa, 'r');
                try out.appendSlice(gpa, seg[i + 1 .. j]);
                i = j;
                continue;
            }
        }
        try out.append(gpa, seg[i]);
        i += 1;
    }
}

// Comma spacing: no space before, at least one after. Existing multi-space alignment after a comma
// (constant tables, .equ value columns) is intentional and left alone.
fn segComma(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    var i: usize = 0;
    while (i < seg.len) {
        const c = seg[i];
        if (c == ' ' or c == '\t') {
            var j = i;
            while (j < seg.len and (seg[j] == ' ' or seg[j] == '\t')) j += 1;
            if (j < seg.len and seg[j] == ',') {
                i = j;
                continue;
            }
            try out.appendSlice(gpa, seg[i..j]);
            i = j;
            continue;
        }
        try out.append(gpa, c);
        if (c == ',' and i + 1 < seg.len and seg[i + 1] != ' ' and seg[i + 1] != '\t') {
            try out.append(gpa, ' ');
        }
        i += 1;
    }
}

// Per-line fixers
const LineFix = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

fn fixTabs(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyWhole(gpa, line, segTabs);
}
fn fixReg(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyCode(gpa, line, segReg);
}
fn fixComma(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyCode(gpa, line, segComma);
}
fn fixHex(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyWhole(gpa, line, segHex);
}
fn fixTrailing(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    _ = gpa;
    return rstrip(line);
}

fn fixAtSpace(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    const sc = splitComment(line);
    if (sc.comment.len >= 2 and sc.comment[0] == '@' and std.ascii.isAlphanumeric(sc.comment[1])) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(gpa, sc.code);
        try out.appendSlice(gpa, "@ ");
        try out.appendSlice(gpa, sc.comment[1..]);
        return out.items;
    }
    return line;
}

// Structural directives operate at file scope and belong flush-left (column 0), like labels, not in
// the indented instruction stream. Excludes data-emitting (.word/.byte/.ascii/...), symbol-def
// (.equ/.set), and block-control (.macro/.rept/.if) directives: those are content or follow block nesting.
const FLUSH_DIRECTIVES = [_][]const u8{
    ".thumb",       ".arm",         ".code",       ".thumb_func", ".arm_func",       ".force_thumb",
    ".syntax",      ".text",        ".data",       ".bss",        ".rodata",         ".section",
    ".subsection",  ".pushsection", ".popsection", ".previous",   ".global",         ".globl",
    ".local",       ".weak",        ".weakref",    ".extern",     ".hidden",         ".protected",
    ".internal",    ".comm",        ".common",     ".lcomm",      ".type",           ".size",
    ".align",       ".balign",      ".balignw",    ".balignl",    ".p2align",        ".p2alignw",
    ".p2alignl",    ".arch",        ".cpu",        ".fpu",        ".arch_extension", ".eabi_attribute",
    ".object_arch", ".org",         ".file",       ".ident",
};

// The ".name" directive at the start of a line's code (ignoring indent), or null if it is not a
// '.'-directive. A trailing ':' marks a local `.label:`, which is not a directive.
fn directiveName(line: []const u8) ?[]const u8 {
    const code = splitComment(line).code;
    var i: usize = leadingSpaces(code);
    if (i >= code.len or code[i] != '.') return null;
    const start = i;
    i += 1;
    while (i < code.len and (isWord(code[i]) or code[i] == '.')) i += 1;
    if (i < code.len and code[i] == ':') return null;
    return code[start..i];
}

// Pull a flush-left structural directive back to column 0. Runs after fixTabs, so the indent is spaces.
fn fixDirectiveIndent(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    _ = gpa;
    const ws = leadingSpaces(line);
    if (ws == 0) return line;
    const name = directiveName(line) orelse return line;
    for (FLUSH_DIRECTIVES) |d| if (std.mem.eql(u8, name, d)) return line[ws..];
    return line;
}

const Fixer = struct { rule: []const u8, msg: []const u8, f: LineFix };

// Order matters: tabs first so later gaps are spaces, trailing-ws last to clean up. Operand and comment
// columns are aligned afterwards by alignBlocks, which needs the whole block.
const FIXERS = [_]Fixer{
    .{ .rule = "tabs", .msg = "tab character (use 4 spaces)", .f = fixTabs },
    .{ .rule = "directive-flush", .msg = "structural directive must be flush-left (column 0)", .f = fixDirectiveIndent },
    .{ .rule = "reg-case", .msg = "register should be lowercase", .f = fixReg },
    .{ .rule = "comma-space", .msg = "one space after a comma, none before", .f = fixComma },
    .{ .rule = "hex-case", .msg = "hex literal should be lowercase (0x...)", .f = fixHex },
    .{ .rule = "at-space", .msg = "missing space after '@' in comment", .f = fixAtSpace },
    .{ .rule = "trailing-ws", .msg = "trailing whitespace", .f = fixTrailing },
};

// Move inline comments with hanging continuation lines above their instruction.
fn hoistInlineBlocks(gpa: std.mem.Allocator, lines: []const []const u8, fix: bool, rep: *Reporter) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const sc = splitComment(lines[i]);
        const code_end = rstrip(sc.code).len;
        if (code_end != 0 and sc.comment.len != 0) {
            var k: usize = 0;
            while (i + 1 + k < lines.len) {
                const scn = splitComment(lines[i + 1 + k]);
                if (rstrip(scn.code).len != 0 or scn.comment.len == 0) break; // a code line or a blank
                if (scn.code.len < code_end) break; // a normal leading comment, not a continuation
                k += 1;
            }
            if (k != 0) {
                try rep.err(i + 1, code_end + 1, "inline-block", "multi-line inline comment; move it to a block above the instruction");
                if (fix) {
                    const indent = sc.code[0..leadingSpaces(sc.code)];
                    try out.append(gpa, try std.mem.concat(gpa, u8, &.{ indent, sc.comment }));
                    var j: usize = 0;
                    while (j < k) : (j += 1) {
                        const scn = splitComment(lines[i + 1 + j]);
                        try out.append(gpa, try std.mem.concat(gpa, u8, &.{ indent, scn.comment }));
                    }
                    try out.append(gpa, rstrip(sc.code));
                    i += 1 + k;
                    continue;
                }
            }
        }
        try out.append(gpa, lines[i]);
        i += 1;
    }
    return out.items;
}

// Align operands and inline comments within each run of instructions.
// Labels, blank lines, and comments break the run.
const Tok = struct {
    code: []const u8, // text before the comment
    tend: usize, // column where the mnemonic ends
    operands: []const u8, // operand text, trailing-stripped (may be empty)
    comment: []const u8, // the comment incl. '@' (may be empty)

    fn of(line: []const u8) Tok {
        const sc = splitComment(line);
        var t = leadingSpaces(sc.code);
        while (t < sc.code.len and sc.code[t] != ' ' and sc.code[t] != '\t') t += 1;
        var o = t;
        while (o < sc.code.len and (sc.code[o] == ' ' or sc.code[o] == '\t')) o += 1;
        return .{ .code = sc.code, .tend = t, .operands = rstrip(sc.code[o..]), .comment = sc.comment };
    }
    fn codeEnd(self: Tok, operand_col: usize) usize {
        return if (self.operands.len != 0) operand_col + self.operands.len else self.tend;
    }
};

// A line that belongs to an alignment block: an instruction. Directives (.equ/.byte/.org/.align/...) and
// #includes start with '.' or '#', so they are excluded and break the block; labels and blanks do too.
fn isInstruction(line: []const u8) bool {
    const code = splitComment(line).code;
    var i: usize = 0;
    while (i < code.len and (code[i] == ' ' or code[i] == '\t')) i += 1;
    if (i >= code.len or !std.ascii.isAlphabetic(code[i])) return false;
    return !isLabelLine(line);
}

fn formatLine(gpa: std.mem.Allocator, line: []const u8, operand_col: usize, comment_col: usize) ![]const u8 {
    const t = Tok.of(line);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, t.code[0..t.tend]);
    if (t.operands.len != 0) {
        try out.appendNTimes(gpa, ' ', operand_col - t.tend);
        try out.appendSlice(gpa, t.operands);
    }
    if (t.comment.len != 0) {
        const ce = t.codeEnd(operand_col);
        // Fall back to a single space when alignment would push the line past the limit.
        const col = if (comment_col + t.comment.len > MAX_LEN) ce + 1 else comment_col;
        try out.appendNTimes(gpa, ' ', col - ce);
        try out.appendSlice(gpa, t.comment);
    }
    return out.items;
}

fn alignBlocks(gpa: std.mem.Allocator, lines: []const []const u8, fix: bool, rep: *Reporter) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        if (!isInstruction(lines[i])) {
            try out.append(gpa, lines[i]);
            i += 1;
            continue;
        }
        var end = i;
        var operand_col: usize = 0;
        while (end < lines.len and isInstruction(lines[end])) : (end += 1) {
            const t = Tok.of(lines[end]);
            if (t.operands.len != 0 and t.tend + 1 > operand_col) operand_col = t.tend + 1;
        }
        var comment_col: usize = 0;
        for (lines[i..end]) |line| {
            const t = Tok.of(line);
            if (t.comment.len != 0) {
                const ce = t.codeEnd(operand_col) + 1;
                if (ce > comment_col) comment_col = ce;
            }
        }
        for (lines[i..end], i + 1..) |line, n| {
            const canonical = try formatLine(gpa, line, operand_col, comment_col);
            if (!std.mem.eql(u8, line, canonical)) {
                try rep.err(n, Tok.of(line).tend + 1, "block-align", "align operands and inline comment to the block columns");
                try out.append(gpa, if (fix) canonical else line);
            } else try out.append(gpa, line);
        }
        i = end;
    }
    return out.items;
}

// Align .set/.equ values and inline comments. Full-line comments do not break the run.
fn isSetLine(line: []const u8) bool {
    const d = directiveName(line) orelse return false;
    if (!std.mem.eql(u8, d, ".set") and !std.mem.eql(u8, d, ".equ")) return false;
    return std.mem.indexOfScalar(u8, splitComment(line).code, ',') != null;
}

fn isCommentLine(line: []const u8) bool {
    const i = leadingSpaces(line);
    return i < line.len and line[i] == '@';
}

const SetTok = struct {
    head: usize, // length of "    .set NAME," including the comma
    val: []const u8,
    comment: []const u8,

    fn of(line: []const u8) SetTok {
        const sc = splitComment(line);
        const comma = std.mem.indexOfScalar(u8, sc.code, ',').?;
        var v = comma + 1;
        while (v < sc.code.len and (sc.code[v] == ' ' or sc.code[v] == '\t')) v += 1;
        return .{ .head = comma + 1, .val = rstrip(sc.code[v..]), .comment = sc.comment };
    }
};

fn formatSetLine(gpa: std.mem.Allocator, line: []const u8, val_col: usize, comment_col: usize) ![]const u8 {
    const t = SetTok.of(line);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, splitComment(line).code[0..t.head]);
    try out.appendNTimes(gpa, ' ', val_col - t.head);
    try out.appendSlice(gpa, t.val);
    if (t.comment.len != 0) {
        const ce = val_col + t.val.len;
        const col = if (comment_col + t.comment.len > MAX_LEN) ce + 1 else comment_col;
        try out.appendNTimes(gpa, ' ', col - ce);
        try out.appendSlice(gpa, t.comment);
    }
    return out.items;
}

fn alignSetBlocks(gpa: std.mem.Allocator, lines: []const []const u8, fix: bool, rep: *Reporter) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        if (!isSetLine(lines[i])) {
            try out.append(gpa, lines[i]);
            i += 1;
            continue;
        }
        var last = i;
        var end = i + 1;
        while (end < lines.len) : (end += 1) {
            if (isSetLine(lines[end])) {
                last = end;
            } else if (!isCommentLine(lines[end])) break;
        }
        var val_col: usize = 0;
        for (lines[i .. last + 1]) |line| {
            if (isSetLine(line) and SetTok.of(line).head + 1 > val_col) val_col = SetTok.of(line).head + 1;
        }
        var comment_col: usize = 0;
        for (lines[i .. last + 1]) |line| {
            if (!isSetLine(line)) continue;
            const t = SetTok.of(line);
            if (t.comment.len != 0 and val_col + t.val.len + 1 > comment_col) comment_col = val_col + t.val.len + 1;
        }
        for (lines[i .. last + 1], i + 1..) |line, n| {
            if (!isSetLine(line)) {
                try out.append(gpa, line);
                continue;
            }
            const canonical = try formatSetLine(gpa, line, val_col, comment_col);
            if (!std.mem.eql(u8, line, canonical)) {
                try rep.err(n, SetTok.of(line).head + 1, "set-align", "align .set/.equ values to the run's column");
                try out.append(gpa, if (fix) canonical else line);
            } else try out.append(gpa, line);
        }
        i = last + 1;
    }
    return out.items;
}

// Warnings
fn warnLine(rep: *Reporter, n: usize, line: []const u8) !void {
    if (line.len > MAX_LEN)
        try rep.warn(n, MAX_LEN + 1, "line-length", "line exceeds 120 columns");
    if (equName(line)) |name| {
        if (!isUpperSnake(name)) try rep.warn(n, 1, "const-name", "constant should be UPPER_SNAKE");
    }
    if (globalLabel(line)) |name| {
        if (!isLowerSnake(name) and !isSwiName(name) and !std.mem.eql(u8, name, "_start"))
            try rep.warn(n, 1, "label-name", "global label should be lower_snake or swi_<Name>");
    }
}

// Macro bodies assemble at their invocation site, so they do not count as the first instruction.
fn warnModeDecl(rep: *Reporter, lines: []const []const u8) !void {
    var in_macro = false;
    for (lines, 1..) |line, n| {
        if (directiveName(line)) |d| {
            if (std.mem.eql(u8, d, ".macro")) in_macro = true;
            if (std.mem.eql(u8, d, ".endm")) in_macro = false;
            if (std.mem.eql(u8, d, ".arm") or std.mem.eql(u8, d, ".thumb") or
                std.mem.eql(u8, d, ".code") or std.mem.eql(u8, d, ".force_thumb")) return;
        } else if (!in_macro and isInstruction(line)) {
            try rep.warn(n, 1, "mode-decl", "instruction before any .arm/.thumb directive");
            return;
        }
    }
}

// Per-file driver
fn lintFile(gpa: std.mem.Allocator, io: Io, path: []const u8, fix: bool, rep: *Reporter) !void {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    // Generated files are exempt: the marker is the first line, or the second behind an SPDX tag.
    var head_it = std.mem.splitScalar(u8, text, '\n');
    for (0..2) |_| {
        if (std.mem.startsWith(u8, head_it.next() orelse break, "@ Generated by")) return;
    }

    const had_nl = text.len != 0 and text[text.len - 1] == '\n';
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    if (had_nl) _ = lines.pop(); // drop empty tail from trailing '\n'

    const proc = try hoistInlineBlocks(gpa, lines.items, fix, rep);

    var fixed: std.ArrayList([]const u8) = .empty;
    var blank_run: usize = 0;
    var prev_label = false;
    for (proc, 1..) |line, n| {
        var cur = line;
        for (FIXERS) |fx| {
            const nxt = try fx.f(gpa, cur);
            if (!std.mem.eql(u8, cur, nxt)) {
                try rep.err(n, 1, fx.rule, fx.msg);
                if (fix) cur = nxt;
            }
        }
        const blank = cur.len == 0;
        if (blank) {
            blank_run += 1;
            if (prev_label) {
                try rep.err(n, 1, "blank-after-label", "blank line directly after a label (the label should hug its first line)");
                if (fix) continue; // drop it; prev_label stays set so a run of blanks all go
            } else if (blank_run >= 2) {
                try rep.err(n, 1, "blank-lines", "consecutive blank lines");
                if (fix) continue;
            } else if (n < proc.len and (isInstruction(proc[n]) or isLabelLine(proc[n]))) {
                try rep.err(n, 1, "blank-before-code", "blank line before a label/instruction (a section break is blank + comment)");
                if (fix) continue;
            }
        } else blank_run = 0;
        try fixed.append(gpa, cur);
        prev_label = !blank and isLabelLine(cur);
    }

    // Align operand and comment columns per block, then warn on the final shape (line length is post-align).
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(gpa, try alignSetBlocks(gpa, try alignBlocks(gpa, fixed.items, fix, rep), fix, rep));
    for (out.items, 1..) |line, n| try warnLine(rep, n, line);
    try warnModeDecl(rep, out.items);

    // Source files end with exactly one newline and no trailing blank lines.
    while (out.items.len != 0 and out.items[out.items.len - 1].len == 0) {
        try rep.err(proc.len, 1, "eof-newline", "trailing blank line(s) at end of file");
        _ = out.pop();
    }
    if (!had_nl and proc.len != 0)
        try rep.err(proc.len, 1, "eof-newline", "no newline at end of file");

    if (fix) {
        var nt: std.ArrayList(u8) = .empty;
        for (out.items) |l| {
            try nt.appendSlice(gpa, l);
            try nt.append(gpa, '\n');
        }
        if (!std.mem.eql(u8, nt.items, text))
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = nt.items });
    }
}

// Discovery + entry point
fn discover(gpa: std.mem.Allocator, io: Io, files: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".s")) continue;
        if (std.mem.indexOf(u8, entry.path, ".git/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "zig-out/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, ".zig-cache/") != null) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, lessStr);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var fix = false;
    var strict = false;
    var files: std.ArrayList([]const u8) = .empty;
    const args = try init.minimal.args.toSlice(gpa);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--fix")) {
            fix = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else try files.append(gpa, a);
    }
    if (files.items.len == 0) try discover(gpa, io, &files);

    var sfw: Io.File.Writer = .init(.stdout(), io, &.{});
    const w = &sfw.interface;
    var efw: Io.File.Writer = .init(.stderr(), io, &.{});
    const e = &efw.interface;

    var rep = Reporter{ .w = w };
    for (files.items) |path| {
        rep.rel = path;
        try lintFile(gpa, io, path, fix, &rep);
    }
    try w.flush();

    try e.print(
        "\nlint_asm: {d} error(s) {s}, {d} warning(s), {d} file(s)\n",
        .{ rep.n_err, if (fix) "fixed" else "found", rep.n_warn, files.items.len },
    );
    if (fix) try e.print(
        "run `zig build verify` to confirm the image is unchanged.\n",
        .{},
    );
    try e.flush();

    // In --fix, mechanical errors are now resolved, so only remaining warnings can fail (and only under
    // --strict). Without --fix, any error fails, plus warnings under --strict.
    const failed = if (fix) (strict and rep.n_warn != 0) else (rep.n_err != 0 or (strict and rep.n_warn != 0));
    if (failed) std.process.exit(1);
}

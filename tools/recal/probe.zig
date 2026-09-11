// SPDX-License-Identifier: MIT
//! Runs a candidate BIOS on the selected emulator core and prints the handoff
//! CPU cycle. The ROM argument supplies a cart image for the boot path.
const std = @import("std");
const Io = std.Io;
const iface = @import("iface");
const emu = @import("emu");

const TIMEOUT_IN_CYCLES: u32 = 200_000_000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var ew: Io.File.Writer = .init(.stderr(), io, &.{});
    if (args.len < 3) {
        try ew.interface.print("usage: probe <bios.bin> <rom.gba>\n", .{});
        try ew.interface.flush();
        std.process.exit(2);
    }

    const bios = try iface.readFile(gpa, args[1]);
    const romf = try iface.readFile(gpa, args[2]);
    var core = try emu.Core.create(gpa);
    defer core.deinit();
    try core.boot(bios, romf);

    const h = core.runToHandoff(TIMEOUT_IN_CYCLES);
    if (h.pc != 0x08000000) {
        try ew.interface.print("error: pc=0x{x:0>8}; BIOS did not hand off to cart ROM\n", .{h.pc});
        try ew.interface.flush();
        std.process.exit(1);
    }
    var ow: Io.File.Writer = .init(.stdout(), io, &.{});
    try ow.interface.print("cyc={d}\n", .{h.cycle});
    try ow.interface.flush();
}

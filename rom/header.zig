// SPDX-License-Identifier: MIT
const logo = @embedFile("gba_logo.bin");

pub fn gbaHeader(comptime title: []const u8, comptime code: []const u8) [0xC0]u8 {
    var h = [_]u8{0} ** 0xC0;
    h[0] = 0x2E;
    h[3] = 0xEA;
    for (logo, 0..) |b, i| h[4 + i] = b;
    for (title, 0..) |c, i| h[0xA0 + i] = c;
    for (code, 0..) |c, i| h[0xAC + i] = c;
    h[0xB0] = '0';
    h[0xB1] = '1';
    h[0xB2] = 0x96;
    var sum: u8 = 0;
    var i: usize = 0xA0;
    while (i <= 0xBC) : (i += 1) sum +%= h[i];
    var chk: u8 = 0;
    chk -%= 0x19;
    chk -%= sum;
    h[0xBD] = chk;
    return h;
}

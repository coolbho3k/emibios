// SPDX-License-Identifier: MIT
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("HANDTIME", "HTME");

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    while (true) {}
}

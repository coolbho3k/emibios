@ SPDX-License-Identifier: GPL-3.0-or-later
@ swi_HardReset IO init table.
.hard_reset_IO_values:
    @ address, value
    .hword 0x0000, 0x0080
    .hword 0x0020, 0x0100
    .hword 0x0026, 0x0100
    .hword 0x0030, 0x0100
    .hword 0x0036, 0x0100
    .hword 0x0082, 0x880e
    .hword 0x0088, 0x0200
    .hword 0x0134, 0x8000
.hard_reset_IO_values_end:

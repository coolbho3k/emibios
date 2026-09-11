/* SPDX-License-Identifier: MIT */
SECTIONS {
  . = 0x08000000;
  .gbaheader : { KEEP(*(.gbaheader)) }
  .text : {
    KEEP(*(.text.romstart))
    *(.text*) *(.rodata*) *(.data*) *(.bss*) *(COMMON)
  }
  /* Discard .ARM.extab. If kept, the linker can place it at 0x08000000, ahead of .gbaheader. */
  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.ARM.attributes) *(.comment) *(.note*) }
}
/* Every ROM root must export the 0xC0-byte header from rom/header.zig (gbaHeader). */
ASSERT(SIZEOF(.gbaheader) == 0xC0, "ROM root is missing the gbaHeader export (rom/header.zig)")

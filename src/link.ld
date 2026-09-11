/* SPDX-License-Identifier: GPL-3.0-or-later */
SECTIONS {
  . = 0x0;
  .text : { *(.text*) *(.rodata*) *(.data*) }
  /* DISCARD drops ARM unwind tables, build attributes, and compiler notes. */
  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) *(.note*) }
}
/* The dispatcher's ldrh immediate (SWI_TBL_OFF) hard codes the exception_swi to swi_table
   distance. */
ASSERT(swi_table - exception_swi == 0x54, "swi_table moved: re-derive SWI_TBL_OFF in dispatcher.s")
ASSERT(ADDR(.text) + SIZEOF(.text) <= 0x10000,
       "BIOS symbols no longer fit SoundGetJumpList's 16-bit pointer table")

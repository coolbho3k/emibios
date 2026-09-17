@ SPDX-License-Identifier: LGPL-3.0-or-later
.arm
.syntax unified
.align 2

#include "definitions.s"
#include "boot/timing.s"

@ Exception vector table (0x00-0x1c).
bios_base:
b exception_reset
b exception_undefined
b exception_swi
b exception_unused
b exception_unused
b exception_unused
b exception_irq
b exception_unused

#include "boot/hard_reset.s"
#include "boot/reset_io_table.s"

@ The IRQ handler must be at 0x128 so the return address it hands the user handler is exactly
@ 0x138. Games save this to their stack, so it should match retail.
.org 0x128
#include "irq_handler.s"

@ Used to detect whether game divergences are due to BIOS layout when set to anything other than 0.
.ifdef LAYOUT_PERTURB
    .space LAYOUT_PERTURB, 0
.endif

#include "swi/dispatcher.s"
@ Keep the table directly after the dispatcher.
#include "swi/swi_table.s"

@ Trivial vector targets.
exception_undefined:
exception_unused:
    b .

@ swi_SoftReset + reset_modes, grouped here with the boot/reset code.
#include "swi/system/soft_reset.s"

@ SWI handlers
#include "swi/memory/cpu_set.s"
#include "swi/decompression/decompression.s"
#include "swi/math/math.s"
#include "swi/power/power.s"
#include "swi/memory/register_ram_reset.s"
#include "swi/system/get_bios_checksum.s"
#include "swi/audio/audio.s"
#include "swi/link/multiboot.s"

@ Boot time code
#include "boot/multiboot_receiver.s"
#include "boot/boot_screen.s"
#include "boot/handoff_tail.s"

.org BIOS_SIZE
padding:

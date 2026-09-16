@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Boot timing and cart handoff calibration constants.
@
@ Cart handoff must land on an exact cycle and PPU phase. Re-measure after boot path changes.

@ Last data word loaded before cart handoff. Some games can observe this latch.
.equ PRIME_LATCH_WORD, 18742926

@ VBlank-synced animation + hold budget. Hold tracks animation length.
.equ BOOT_TOTAL_FRAMES, 265

@ Good-cart draw is fixed cost. Bad headers hang. Scratch stack keeps handoff memory bare.
@ Draw+cleanup time is absorbed by boot_final_burn's re-anchor and generated burn constants.

@ handoff_latch_prime loop count. Latches depend on the loop shape/literal, not this count.
.equ BOOT_PRIME_ITERS, 16

@ VCount-match anchor for the final burn. Cleanup carries this to the handoff scanline.
@ FINAL_BURN_PAD/FINAL_FINE place the exact dot.
.equ HANDOFF_SCANLINE, 99

@ Recal writes FINAL_BURN_PAD/FINAL_FINE here.
#include "calibration.s"

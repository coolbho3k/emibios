@ SPDX-License-Identifier: GPL-3.0-or-later
@ Boot screen.
@
@ We also check the ROM header. Why?  BIOS replacement that may run on real hardware should check
@ the header to avoid jumping into corrupted code and crashing or showing you garbage.
@
@ Cart header check:
@   * Header checksum byte at 0xbd must be correct.
@   * Nintendo logo against a known good hash. We do not include the actual Nintendo logo.
@   * Fixed value at 0xb2 must be 0x96.
.align 2
#include "boot_screen_data.s"

.equ VRAM,            VRAM_START
.equ BGPAL,           PAL_START
.equ MMIO,            MMIO_BASE
.equ SCRATCH,         IWRAM_START                @ BUF1: Huff output / LZ stream
.equ BS_BUF2,         0x03000800                 @ BUF2: LZ output / 1bpp art
@ Low IWRAM scratch stack.
.equ BS_STACK_TOP,    0x03002000
.equ SCREEN_BASE,     VRAM + 0x4000              @ BG0 tilemap
.equ COL_GRAY,        0x6338                     @ backdrop gray (197,202,193)
.equ BS_PURPLE_COLOR, 0x7c18                     @ exact gr_chan result for hue 112: RGB5 (24, 0, 31)
.equ COL_BLACK,       0x0862                     @ text/content black (20,24,20)
.equ LOGO_TX,         5                          @ logo top-left tile
.equ LOGO_TY,         6                          @ logo+text group is vertically centered
.equ CART,            ROM_ENTRYPOINT             @ GamePak base
.equ HDR_TITLE,       0xa0                       @ 12-byte internal title
.equ HDR_CODE,        0xac                       @ 4-byte game code (U-TT-D)
@ Header logo hash over 0x04..0x9f. h = word ^ ror(h,5), 39 LE words.
.equ LOGO_HASH,       0xc23fa529
.equ TITLE_TX,        LOGO_TX                    @ title left, aligned to the logo's left edge
.equ TITLE_TY,        13                         @ just below screen center, under the logo
.equ CODE_TX,         (LOGO_TX + BS_LOGO_TW - 5) @ code right edge under the logo's mid-right
.equ CODE_TY,         13                         @ same line as the title
.equ TITLE_LEN,       12
.equ CODE_LEN,        4
.equ MBRDY_TX,        LOGO_TX                    @ "MULTIBOOT RDY"
.equ MBRDY_TY,        TITLE_TY
.equ MBRDY_LEN,       9
.equ CLEAN_TX,        LOGO_TX                    @ "CLEAN CART!"
.equ CLEAN_TY,        17
.equ CLEAN_LEN,       11
.equ BS_BLINK_FRAMES, 30                         @ "CLEAN CART!" blink frames
@ HBlank DMA for logo animation
.equ BS_WOBBLE,       0x03001200
.equ BS_COPPER,       0x03001400
.equ BS_WPHASE,       0x03001600
.equ BS_CPHASE,       0x03001602
.equ BS_REVB,         0x03001604
.equ BS_PURB,         0x03001606
.equ BS_PURCOL,       0x03001608
@ Glyph mode mask
.equ BS_GMODE,        0x0300160c
.equ BS_STRBUF,       0x03001610                 @ small scratch for runtime-built debug strings ("XX/XX", "XX")
.equ BS_WENV,         0x03001618                 @ wobble amplitude envelope (hword): starts large, exp-decays to 0
.equ DMA0SAD,         REG_DMA0SAD                @ HBlank DMA0: wobble  -> BG0HOFS
.equ BG0HOFS,         REG_BG0HOFS
.equ BS_WOB_FREQ,     3                          @ wobble: sine index step per scanline
.equ BS_WOB_SHIFT,    12                         @ wobble: (s16)sine(2.14) >> 12 -> +-4 px settled amplitude
.equ BS_WOB_SPEED,    5                          @ wobble: phase advance per frame (ripple speed)
.equ BS_WOB_ENV0,     384
.equ BS_WOB_DECAY,    3
.equ BS_WOB_FBOOST,   4
.equ BS_COP_FREQ,     4                          @ copper: hue step per scanline (bar tightness)
.equ BS_COP_SPEED,    4                          @ copper: hue advance per frame (scroll speed, a touch quicker)
.equ DMA3SAD,         REG_DMA3SAD                @ HBlank DMA3: copper -> palette[1] ink, one hword/scanline
.equ VCOUNT,          REG_VCOUNT
.equ DMA_HBL_PAL,     0xa240                     @ enable|HBlank|repeat|16bit|src-inc|dst-fixed
.equ LOGO_Y0,         (LOGO_TY*8)                @ first logo scanline (48)
.equ BS_LOGO_LINES,   (BS_LOGO_TH*8)             @ logo scanline span (32) == reveal/converge wipe length
.equ BS_BAND_I0,      (LOGO_Y0 - 1)              @ first copper/wobble TABLE index (HBlank-ahead: idx i -> scanline i+1)
.equ PAL_TEXT,        (BGPAL + 4)                @ palette[2]  = credit/banner/bad-header ink (bank 0)
.equ PAL_TITLE,       (BGPAL + 36)               @ palette[18] = title+code ink (bank 1, index 2)
.equ PAL_BANK1,       0x1000                     @ tilemap palette-bank-1 select (bits 12-15)
.equ BS_FADE_FRAMES,  2                          @ phases 2/3: frames per fade step (8 steps each)

@ BS_ANIM_FRAMES + BOOT_HOLD_FRAMES + BOOT_FRAME_TRIM == BOOT_TOTAL_FRAMES.
.equ BS_ANIM_FRAMES,   (2*BS_LOGO_LINES + 16*BS_FADE_FRAMES) @ = 2*32 + 16*2 = 96 (ACTION 0 handoff path)
.equ BOOT_HOLD_FRAMES, (BOOT_TOTAL_FRAMES - BOOT_FRAME_TRIM - BS_ANIM_FRAMES)
.if BOOT_HOLD_FRAMES < 0
.error "boot screen: BS_ANIM_FRAMES exceeds BOOT_TOTAL_FRAMES, the animation does not fit the boot budget"
.endif

.arm
.align 2                               @ 4-byte align: ARM bl target
@ Keeps the pre-0x128 entrypoint call site at one 4-byte `bl`.
boot_screen_entry:
    @ Multiboot with no cart. Valid GamePak starts with an 0xeaxxxxxx ARM branch.
    mov   r0, #ROM_ENTRYPOINT
    ldr   r0, [r0]
    and   r0, r0, #0xff000000
    cmp   r0, #0xea000000
    ldrne r0, =multiboot_receiver_detect + 1
    bxne  r0
    mov   r0, #0
    ldr   r1, =boot_screen_show + 1
    bx    r1

.thumb

@ ARM call veneer. r3 = ARM target.
bs_call_arm:
    bx r3

@ bs_trig_check: sample Start+Select.
@ ACTION 2 sniffs JoyBus reset. Clobbers r0, r1.
bs_trig_check:
    cmp  r7, #2
    beq  .btc_sniff
    ldr  r0, =REG_KEYINPUT
    ldrh r1, [r0]
    movs r0, #(KEY_START | KEY_SELECT)
    ands r1, r0
    cmp  r1, #0
    bne  .btc_ret
    @ Hide text immediately. The flag is acted on after animation/hold.
    ldr  r0, =MB_MODE_FLAG
    movs r1, #1
    strb r1, [r0]
    ldr  r0, =BGPAL
    ldr  r1, =COL_GRAY
    strh r1, [r0, #4]
    strh r1, [r0, #36]
    b    .btc_ret
.btc_sniff:
    @ GameCube reset latches JOYCNT.RESET while RCNT selects JoyBus.
    ldr  r0, =REG_RCNT
    ldr  r1, =RCNT_JOYBUS
    strh r1, [r0]
    ldr  r0, =REG_JOYCNT
    ldrh r0, [r0]
    movs r1, #JOYCNT_RESET
    ands r0, r1
    beq  .btc_ret
    ldr  r0, =multiboot_receiver_joybus + 1
    bx   r0
.btc_ret:
    bx lr
bs_wait_vblank:
    ldr r0, =VCOUNT
.bwv_a:
    ldrh r1, [r0]
    cmp  r1, #160
    beq  .bwv_a
.bwv_b:
    ldrh r1, [r0]
    cmp  r1, #160
    bne  .bwv_b
    bx   lr
bs_draw_banner:
    push {lr}
    movs r3, #0
    ldr  r0, =bs_str_mbrdy
    movs r1, #MBRDY_LEN
    ldr  r2, =(MBRDY_TY*32 + MBRDY_TX)
    bl   bs_puts
    ldr  r0, =(bs_str_mbrdy + 10)
    movs r1, #3
    movs r2, #MBRDY_TY
    bl   bs_putr @ "RDY" right-aligned
    pop  {pc}

@ bs_mbrdy_fade: fade in "MULTIBOOT RDY" just before listening. Clobbers r0-r5.
bs_mbrdy_fade:
    push {r4, r5, lr}
    movs r4, #0
.mrf_step:
    ldr  r0, =bs_fade
    lsls r1, r4, #1
    adds r0, r0, r1
    ldrh r2, [r0]
    ldr  r0, =PAL_TEXT
    strh r2, [r0]
    movs r5, #BS_FADE_FRAMES
.mrf_fh:
    bl   bs_wait_vblank
    subs r5, #1
    bne  .mrf_fh
    adds r4, #1
    cmp  r4, #8
    blt  .mrf_step
    pop  {r4, r5, pc}

@ bs_hold: exact BOOT_HOLD_FRAMES VBlank hold. Returns early for multiboot.
bs_hold:
    push {r4, lr}
    ldr  r4, =BOOT_HOLD_FRAMES
.bh_loop:
    bl   bs_trig_check
    ldr  r0, =MB_MODE_FLAG
    ldrb r0, [r0]
    cmp  r0, #0
    bne  .bh_done
    bl   bs_wait_vblank
    subs r4, #1
    bne  .bh_loop
.bh_done:
    pop {r4, pc}
.ltorg                                 @ near literal pool for the early functions (entry/trig/hold)

@ boot_screen_show(r0 = 0 normal / nonzero multiboot)
.align 2
boot_screen_show:
    @ Scratch stack avoids the boot reserve and is zeroed before handoff.
    mov  r1, sp
    ldr  r2, =BS_STACK_TOP
    mov  sp, r2
    push {r1, r4-r7, lr}
    adds r7, r0, #0
    ldr  r0, =MB_MODE_FLAG
    movs r1, #0
    strb r1, [r0]
    bl   bs_draw
    bl   bs_anim
    ldr  r0, =MB_MODE_FLAG
    ldrb r0, [r0]
    cmp  r0, #0
    bne  .bss_multiboot
    bl   bs_hold
    ldr  r0, =MB_MODE_FLAG
    ldrb r0, [r0]
    cmp  r0, #0
    bne  .bss_multiboot
    @ Re-anchor to VBlank, then burn to the calibrated handoff cycle.
    ldr  r3, =boot_final_burn
    bl   bs_call_arm
    bl   bs_cleanup
    pop  {r1, r4-r7}
    pop  {r3}
    mov  sp, r1
    ldr  r0, =SCRATCH
    ldr  r2, =((BS_STACK_TOP - SCRATCH) / 4)
    movs r1, #0
.bs_eclr:
    str  r1, [r0]
    adds r0, r0, #4
    subs r2, r2, #1
    bne  .bs_eclr
    @ Bus note: =handoff_latch_prime is the last bus access before handoff.
    mov lr, r3
    ldr r3, =handoff_latch_prime
    bx  r3
    @ Bus note: never executed.
    @ Pins the Thumb prefetch word observed at handoff in retail.
    .word 0x49c1b5f0

@ Multiboot tail: erase text, fade palette[2] back in, then listen.
.bss_multiboot:
    ldr  r1, =BGPAL
    ldr  r2, =COL_GRAY
    strh r2, [r1, #4]
    strh r2, [r1, #36]
    bl   bs_wait_vblank
    bl   bs_map_clear
    movs r0, #BS_LOGO_T0
    ldr  r1, =(LOGO_TY*32 + LOGO_TX)
    movs r2, #BS_LOGO_TW
    movs r3, #BS_LOGO_TH
    bl   bs_place
    bl   bs_draw_banner
    bl   bs_mbrdy_fade
    ldr  r0, =multiboot_receiver_listen + 1
    bx   r0

@ bs_draw(r7=mode) -> 0 good, 1 bad header, 2 multiboot, 3 no cart, 4 debug B held.
bs_draw:
    push {r4-r7, lr}
    ldr  r1, =BGPAL
    ldr  r2, =COL_GRAY
    strh r2, [r1, #0]
    strh r2, [r1, #2]
    strh r2, [r1, #4]
    strh r2, [r1, #36]
    movs r1, #(BS_PURPLE_COLOR >> 8)
    lsls r1, r1, #8
    adds r1, #(BS_PURPLE_COLOR & 0xff)
    ldr  r0, =BS_PURCOL
    strh r1, [r0]
    ldr  r0, =BS_GMODE
    movs r1, #0
    mvns r1, r1
    str  r1, [r0]
    @ Logo tiles are column major, font atlas is row major for BitUnpack.
    ldr r0, =bs_blob
    ldr r1, =SCRATCH
    ldr r3, =swi_HuffUnCompReadNormal_nv
    bl  bs_call_arm
    ldr r0, =SCRATCH
    ldr r1, =BS_BUF2
    ldr r3, =swi_LZ77UnCompWrite8bit_nv
    bl  bs_call_arm
    ldr r0, =(BS_BUF2 + BS_OFF_LOGO)
    ldr r5, =(VRAM + BS_LOGO_T0*32)
    ldr r6, =(BS_BUF2 + BS_OFF_LOGO + BS_LOGO_RAW)
.bs_lx_tile:
    movs r2, #0
.bs_lx_row:
    movs r4, #0
    movs r3, #7
.bs_lx_px:
    ldrb r1, [r0, r3]
    lsrs r1, r2
    lsls r1, #31
    lsrs r1, #31
    lsls r4, #4
    orrs r4, r1
    subs r3, #1
    bpl  .bs_lx_px
    str  r4, [r5]
    adds r5, #4
    adds r2, #1
    cmp  r2, #8
    blt  .bs_lx_row
    adds r0, #8
    cmp  r0, r6
    blo  .bs_lx_tile
    ldr  r0, =(BS_BUF2 + BS_OFF_ATLAS)
    ldr  r1, =(VRAM + BS_ATLAS_T0*32)
    ldr  r2, =bs_atlas_info
    ldr  r3, =swi_BitUnpack
    bl   bs_call_arm
    bl   bs_map_clear
    movs r0, #BS_LOGO_T0
    ldr  r1, =(LOGO_TY*32 + LOGO_TX)
    movs r2, #BS_LOGO_TW
    movs r3, #BS_LOGO_TH
    bl   bs_place
    cmp  r7, #0
    bne  .bs_draw_mb
    bl   bs_hdr_check
    cmp  r0, #0
    bne  .bs_draw_invalid
    @ B held overlays diagnostics while still booting normally.
    ldr  r0, =REG_KEYINPUT
    ldrh r0, [r0]
    movs r1, #KEY_B
    ands r0, r1
    bne  .bs_draw_good_normal
    movs r0, #0
    bl   bs_draw_debug
    movs r4, #4
    b    .bs_draw_fin
.bs_draw_good_normal:
    movs r3, #0
    ldr  r0, =(CART + HDR_TITLE)
    movs r1, #TITLE_LEN
    ldr  r2, =(TITLE_TY*32 + TITLE_TX)
    bl   bs_puts
    ldr  r3, =PAL_BANK1
    ldr  r0, =(CART + HDR_CODE)
    movs r1, #CODE_LEN
    ldr  r2, =(CODE_TY*32 + CODE_TX)
    bl   bs_puts
    movs r4, #0
    b    .bs_draw_fin
.bs_draw_invalid:
    cmp  r0, #2
    beq  .bs_draw_nocart
    movs r0, #1
    bl   bs_draw_debug
    movs r4, #1
    b    .bs_draw_fin
.bs_draw_nocart:
    movs r4, #3
    b    .bs_draw_fin
.bs_draw_mb:
    bl   bs_draw_banner
    movs r4, #2
.bs_draw_fin:
    ldr  r1, =MMIO
    movs r2, #8
    lsls r2, r2, #8
    strh r2, [r1, #8]
    movs r2, #0
    strh r2, [r1, #0x10]
    strh r2, [r1, #0x12]
    movs r2, #1
    lsls r2, r2, #8
    strh r2, [r1, #0]
    adds r0, r4, #0
    pop  {r4-r7, pc}

@ bs_hdr_check -> r0 = 0 good / 1 bad header / 2 no cart.
bs_hdr_check:
    push {r4-r7, lr}
    bl   bs_hdr_sum
    ldr  r1, =(CART + 0xbd)
    ldrb r3, [r1]
    adds r0, r0, r3
    movs r3, #0xff
    ands r0, r3
    adds r7, r0, #0
    bl   bs_logo_hash
    ldr  r6, =LOGO_HASH
    cmp  r7, #0
    bne  .bhc_invalid
    cmp  r0, r6
    bne  .bhc_invalid
    ldr  r1, =(CART + 0xb2)
    ldrb r1, [r1]
    cmp  r1, #0x96
    bne  .bhc_invalid
    movs r0, #0
    pop  {r4-r7, pc}
.bhc_invalid:
    @ NO CART reads halfword[A] = (A>>1)&0xffff. Check three spread words.
    ldr  r1, =CART
    ldr  r3, [r1]
    movs r2, #1
    lsls r2, r2, #16
    cmp  r3, r2
    bne  .bhc_badhdr
    ldr  r1, =(CART + 0x80)
    ldr  r3, [r1]
    movs r2, #0x41
    lsls r2, r2, #16
    adds r2, r2, #0x40
    cmp  r3, r2
    bne  .bhc_badhdr
    ldr  r1, =(CART + 0xa0)
    ldr  r3, [r1]
    movs r2, #0x51
    lsls r2, r2, #16
    adds r2, r2, #0x50
    cmp  r3, r2
    bne  .bhc_badhdr
    movs r0, #2
    pop  {r4-r7, pc}
.bhc_badhdr:
    movs r0, #1
    pop  {r4-r7, pc}

.align 2
bs_hdr_sum:
    ldr  r1, =(CART + 0xa0)
    movs r2, #29
    movs r0, #0
.bhs_sum:
    ldrb r3, [r1]
    adds r1, r1, #1
    adds r0, r0, r3
    subs r2, r2, #1
    bne  .bhs_sum
    adds r0, r0, #0x19
    movs r3, #0xff
    ands r0, r3
    bx   lr

.align 2
bs_logo_hash:
    push {r5, lr}
    movs r0, #0
    ldr  r1, =(CART + 0x04)
    movs r2, #38
    movs r5, #5
.blh_hash:
    ldr  r3, [r1]
    adds r1, r1, #4
    rors r0, r5
    eors r0, r3
    subs r2, r2, #1
    bne  .blh_hash
    ldr  r3, [r1]
    movs r2, #0x84
    mvns r2, r2
    ands r3, r2
    rors r0, r5
    eors r0, r3
    pop  {r5, pc}

@ bs_puts(r0=src, r1=count, r2=map offset, r3=bank): branchless per char.
.align 2
bs_puts:
    push {r4-r7, lr}
    adds r4, r0, #0
    adds r5, r1, #0
    ldr  r6, =SCREEN_BASE
    lsls r2, r2, #1
    adds r6, r6, r2
    ldr  r7, =BS_GMODE
    ldr  r7, [r7]
.bs_ps:
    ldrb r0, [r4]
    adds r4, r4, #1
    @ CLEAN folds a-z to A-Z.
    adds r1, r0, #0
    subs r1, #0x61
    lsls r1, r1, #24
    lsrs r1, r1, #24
    subs r1, #0x1a
    asrs r1, r1, #31
    ands r1, r7
    movs r2, #0x20
    ands r1, r2
    subs r0, r0, r1
    @ Clamp printable ASCII to atlas range.
    subs r0, #0x20
    lsls r0, r0, #24
    lsrs r0, r0, #24
    adds r1, r0, #0
    subs r1, #0x5f
    asrs r1, r1, #31
    ands r0, r1
    @ DEBUG maps non-printable bytes to '.'.
    orrs r1, r7
    mvns r1, r1
    movs r2, #0x0e
    ands r1, r2
    orrs r0, r1
    adds r0, r0, #BS_ATLAS_T0
    orrs r0, r3
    strh r0, [r6]
    adds r6, r6, #2
    subs r5, r5, #1
    bne  .bs_ps
    pop  {r4-r7, pc}

@ bs_putr(r0=src, r1=count, r2=row): right align to the game code edge.
.align 2
bs_putr:
    lsls r2, r2, #5
    adds r2, #24
    subs r2, r2, r1
    movs r3, #0
    b    bs_puts

@ bs_put_okbad(r0=1 ok / 0 bad, r2=row): right-aligned "OK" or "BAD"
bs_put_okbad:
    cmp  r0, #0
    beq  .pob_bad
    ldr  r0, =bs_str_ok
    movs r1, #2
    b    bs_putr
.pob_bad:
    ldr  r0, =bs_str_bad
    movs r1, #3
    b    bs_putr

@ nib2char(r0=nibble 0..15) -> r0 = ASCII hex digit
nib2char:
    adds r0, #0x30
    cmp  r0, #0x39
    ble  .n2c_done
    adds r0, #7
.n2c_done:
    bx lr
@ bs_hex2(r0=byte, r1=dst): write 2 ASCII hex chars at dst
bs_hex2:
    push {r4, r5, lr}
    adds r4, r1, #0
    adds r5, r0, #0
    lsrs r0, r5, #4
    bl   nib2char
    strb r0, [r4]
    movs r0, #0x0f
    ands r0, r5
    bl   nib2char
    strb r0, [r4, #1]
    pop  {r4, r5, pc}

@ bs_logo_ok -> r0 = 1 if cart logo hash matches. Clobbers r1-r3.
bs_logo_ok:
    push {lr}
    bl   bs_logo_hash
    ldr  r3, =LOGO_HASH
    cmp  r0, r3
    bne  .lok_bad
    movs r0, #1
    pop  {pc}
.lok_bad:
    movs r0, #0
    pop  {pc}

@ bs_draw_debug(r0=show_heading): LOGO/HEADER/name/code/CHECKSUM/FIX.
.align 2
bs_draw_debug:
    push {r4-r7, lr}
    adds r7, r0, #0
    ldr  r0, =BS_GMODE
    movs r1, #0
    str  r1, [r0]
    movs r3, #0
    ldr  r0, =(CART + HDR_TITLE)
    movs r1, #TITLE_LEN
    ldr  r2, =(TITLE_TY*32 + TITLE_TX)
    bl   bs_puts
    movs r3, #0
    ldr  r0, =(CART + HDR_CODE)
    movs r1, #CODE_LEN
    ldr  r2, =(CODE_TY*32 + CODE_TX)
    bl   bs_puts
    @ Bank 1 lets the hang blink CLEAN CART! independently.
    cmp  r7, #0
    beq  .dbg_no_heading
    ldr  r3, =PAL_BANK1
    ldr  r0, =bs_str_clean
    movs r1, #CLEAN_LEN
    ldr  r2, =(CLEAN_TY*32 + CLEAN_TX)
    bl   bs_puts
.dbg_no_heading:
    ldr  r0, =bs_str_logo
    movs r1, #4
    movs r2, #11
    bl   dbg_label
    bl   bs_logo_ok
    movs r2, #11
    bl   bs_put_okbad
    bl   bs_hdr_sum
    movs r1, #0xff
    negs r4, r0
    ands r4, r1
    ldr  r1, =(CART + 0xbd)
    ldrb r5, [r1]
    cmp  r4, r5
    beq  .dbg_hdr_ok
    movs r6, #0
    b    .dbg_hdr_done
.dbg_hdr_ok:
    movs r6, #1
.dbg_hdr_done:
    ldr  r0, =bs_str_header
    movs r1, #3
    movs r2, #12
    bl   dbg_label
    adds r0, r6, #0
    movs r2, #12
    bl   bs_put_okbad
    ldr  r0, =bs_str_cksum
    movs r1, #5
    movs r2, #14
    bl   dbg_label
    adds r0, r5, #0
    adds r1, r4, #0
    movs r2, #14
    bl   dbg_hexrow
    ldr  r0, =bs_str_fix
    movs r1, #3
    movs r2, #15
    bl   dbg_label
    ldr  r0, =(CART + 0xb2)
    ldrb r0, [r0]
    movs r1, #0x96
    movs r2, #15
    bl   dbg_hexrow
    pop  {r4-r7, pc}

@ dbg_label(r0=str, r1=len, r2=row): render a debug label.
.align 2
dbg_label:
    lsls r2, r2, #5
    adds r2, #LOGO_TX
    movs r3, #0
    b    bs_puts

@ dbg_hexrow(r0=byte_a, r1=byte_b, r2=row): render "AA/BB" right-aligned.
.align 2
dbg_hexrow:
    push {r1, r2, lr}
    ldr  r1, =BS_STRBUF
    bl   bs_hex2
    movs r0, #0x2f
    ldr  r1, =BS_STRBUF
    strb r0, [r1, #2]
    pop  {r0}
    ldr  r1, =(BS_STRBUF + 3)
    bl   bs_hex2
    ldr  r0, =BS_STRBUF
    movs r1, #5
    pop  {r2, r3}
    mov  lr, r3
    b    bs_putr
.ltorg

@ Multiboot receive UI (called from boot/multiboot_receiver.s)
.equ MBP_STRBUF,  0x03001620 @ 12 bytes: "CCCC/TTTT" build area
.equ MBP_SW_DONE, 0x03001630 @ sweep: logo lines already turned to the target color
.equ MBP_SW_DIR,  0x03001638 @ sweep: 0 = top->bottom, 1 = bottom->top (the D bit)
.equ MBP_SW_TGT,  0x0300163c @ sweep: target BGR555
.equ MBP_SW_ACT,  0x03001640 @ sweep: active flag (written last on start; single-writer)
.equ MBP_SW_VBL,  0x03001644 @ frame edge detector: 1 while in VBlank
.equ MBP_TINT,    0x03001648 @ last applied palette byte + 1 (0 = none). Resends are no-ops
.align 2
mbp_lut: @ logo tints selected by palette byte CCC (index 0 = boot purple)
    .hword BS_PURPLE_COLOR, 0x001f, 0x01ff, 0x039f, 0x1380, 0x7340, 0x7d46, 0x739c
mbp_str_rdy:
    .ascii "      RDY" @ 9 chars: erases a stale progress field and restores idle banner
.align 2

@ mbp_idle: restore the right-side "RDY" field. Clobbers r0-r3.
mbp_idle:
    ldr  r0, =mbp_str_rdy
    movs r1, #9
    movs r2, #MBRDY_TY
    b    bs_putr

@ mbp_reset: clear receive UI, park copper DMA, restore boot purple. Clobbers r0-r3.
mbp_reset:
    push {lr}
    movs r0, #0
    ldr  r1, =MBP_STRBUF
    str  r0, [r1, #(MBP_SW_ACT - MBP_STRBUF)] @ MBP_SW_ACT: no sweep in flight
    str  r0, [r1, #(MBP_SW_VBL - MBP_STRBUF)] @ MBP_SW_VBL: frame edge detector cleared
    str  r0, [r1, #(MBP_TINT - MBP_STRBUF)]   @ MBP_TINT:   next palette byte reapplies
    ldr  r1, =DMA3SAD
    strh r0, [r1, #0xa]                       @ DMA3CNT_H = 0: park the copper
    ldr  r0, =BS_PURCOL
    ldrh r0, [r0]
    ldr  r1, =BGPAL
    strh r0, [r1, #2]                         @ palette[1] = the boot purple: logo restored
    bl   mbp_idle
    pop  {pc}

@ mbp_field(r0=cur, r1=total): bytes in, "CCCC/TTTT" in 16-byte blocks, ???? until total known.
mbp_field:
    push {r4, r5, r6, lr}
    adds r4, r0, #0 @ raw byte counts (the sweep needs them unsaturated)
    adds r5, r1, #0
    @ Sweep line k turns when cur*INK >= (k+1)*total.
    ldr  r2, =MBP_STRBUF
    ldr  r3, [r2, #(MBP_SW_ACT - MBP_STRBUF)]
    cmp  r3, #0
    beq  .mbpf_nosweep
    cmp  r5, #0
    beq  .mbpf_nosweep @ total still unknown (header phase)
    ldr  r6, [r2, #(MBP_SW_DONE - MBP_STRBUF)]
    movs r0, #BS_LOGO_INK
    muls r0, r4        @ cur * INK (cur <= 0x40000, fits easily)
.mbpf_adv:
    cmp  r6, #BS_LOGO_INK
    bge  .mbpf_advstore
    adds r1, r6, #1
    muls r1, r5 @ (done+1) * total
    cmp  r0, r1
    blo  .mbpf_advstore
    push {r0}
    ldr  r1, [r2, #(MBP_SW_DIR - MBP_STRBUF)]
    cmp  r1, #0
    beq  .mbpf_top
    movs r1, #(BS_LOGO_INK - 1)
    subs r1, r1, r6
    b    .mbpf_addr
.mbpf_top:
    adds r1, r6, #0
.mbpf_addr:
    lsls r1, r1, #1
    ldr  r0, =(BS_COPPER + BS_BAND_I0*2)
    adds r0, r1
    ldr  r1, [r2, #(MBP_SW_TGT - MBP_STRBUF)]
    strh r1, [r0]
    pop  {r0}
    adds r6, #1
    b    .mbpf_adv
.mbpf_advstore:
    str r6, [r2, #(MBP_SW_DONE - MBP_STRBUF)]
.mbpf_nosweep:
    cmp  r5, #0
    beq  .mbpf_blocks
    cmp  r4, r5
    blo  .mbpf_blocks
    adds r4, r5, #0
    adds r4, #15
.mbpf_blocks:
    lsrs r4, r4, #4
    adds r5, #15
    lsrs r5, r5, #4
    lsrs r0, r4, #8
    adds r1, r2, #0
    bl   bs_hex2
    lsls r0, r4, #24
    lsrs r0, r0, #24
    adds r1, r2, #2
    bl   bs_hex2
    movs r0, #0x2f
    strb r0, [r2, #4]
    cmp  r5, #0
    bne  .mbpf_tot
    movs r0, #0x3f
    strb r0, [r2, #5]
    strb r0, [r2, #6]
    strb r0, [r2, #7]
    strb r0, [r2, #8]
    b    .mbpf_draw
.mbpf_tot:
    lsrs r0, r5, #8
    adds r1, r2, #5
    bl   bs_hex2
    lsls r0, r5, #24
    lsrs r0, r0, #24
    adds r1, r2, #7
    bl   bs_hex2
.mbpf_draw:
    adds r0, r2, #0
    movs r1, #9
    movs r2, #MBRDY_TY
    bl   bs_putr
    pop  {r4, r5, r6, pc}

@ mbp_tint(r0=0b1CCCDSS1): start progress driven logo recolor.
mbp_tint:
    push {lr}
    ldr  r2, =MBP_STRBUF
    ldr  r1, [r2, #(MBP_TINT - MBP_STRBUF)]
    adds r3, r0, #1
    cmp  r1, r3
    beq  .mbpn_done
    str  r3, [r2, #(MBP_TINT - MBP_STRBUF)]
    lsrs r1, r0, #4
    movs r3, #7
    ands r1, r3
    lsls r1, r1, #1
    ldr  r3, =mbp_lut
    ldrh r3, [r3, r1]
    str  r3, [r2, #(MBP_SW_TGT - MBP_STRBUF)]
    lsrs r1, r0, #3
    movs r3, #1
    ands r1, r3
    str  r1, [r2, #(MBP_SW_DIR - MBP_STRBUF)]
    movs r0, #0
    str  r0, [r2, #(MBP_SW_DONE - MBP_STRBUF)]
    @ HBlank repeat DMA source runs off during VBlank. mbp_tick re-arms SAD.
    ldr  r2, =BGPAL
    ldrh r2, [r2, #2]
    ldr  r0, =BS_COPPER
    movs r1, #160
    bl   bs_fill16
    ldr  r0, =DMA3SAD
    ldr  r1, =(BGPAL + 2)
    str  r1, [r0, #4]                         @ DMA3DAD = palette[1] (dst-fixed), set once
    movs r1, #1
    str  r1, [r0, #8]                         @ DMA3CNT_L = 1, set once
    ldr  r0, =MBP_STRBUF
    str  r1, [r0, #(MBP_SW_ACT - MBP_STRBUF)] @ MBP_SW_ACT = 1 (r1 already holds 1)
.mbpn_done:
    pop {pc}

@ mbp_tick: VBlank-edge sweep service. Call continuously so it also sees non-VBlank.
mbp_tick:
    push {r0-r3, lr}
    ldr  r0, =VCOUNT
    ldrh r0, [r0]
    movs r1, #0
    cmp  r0, #160
    blo  .mbpk_low
    movs r1, #1
.mbpk_low:
    ldr r2, =MBP_STRBUF
    ldr r3, [r2, #(MBP_SW_VBL - MBP_STRBUF)]
    str r1, [r2, #(MBP_SW_VBL - MBP_STRBUF)]
    cmp r1, #1
    bne .mbpk_out
    cmp r3, #0
    bne .mbpk_out
    ldr r3, [r2, #(MBP_SW_ACT - MBP_STRBUF)]
    cmp r3, #0
    beq .mbpk_out
    @ Re-arm SAD. DAD/CNT_L were set once by mbp_tint.
    ldr  r0, =DMA3SAD
    movs r1, #0
    strh r1, [r0, #0xa]
    ldr  r1, =BS_COPPER
    str  r1, [r0, #0]
    ldr  r1, =DMA_HBL_PAL
    strh r1, [r0, #0xa]
    ldr  r3, [r2, #(MBP_SW_DONE - MBP_STRBUF)]
    cmp  r3, #BS_LOGO_INK @ the sweep spans the ink rows
    blt  .mbpk_out
    ldr  r3, [r2, #(MBP_SW_TGT - MBP_STRBUF)]
    ldr  r0, =BGPAL
    strh r3, [r0, #2]
    ldr  r0, =DMA3SAD
    movs r1, #0
    strh r1, [r0, #0xa]
    str  r1, [r2, #(MBP_SW_ACT - MBP_STRBUF)]
.mbpk_out:
    pop {r0-r3, pc}

@ mbp_finish: settle in-flight sweep and restore DMA3 baseline. Clobbers r0-r2.
mbp_finish:
    ldr  r0, =MBP_STRBUF
    ldr  r1, [r0, #(MBP_SW_ACT - MBP_STRBUF)]
    cmp  r1, #0
    beq  .mbpz_dma
    movs r1, #0
    str  r1, [r0, #(MBP_SW_ACT - MBP_STRBUF)]
    ldr  r1, [r0, #(MBP_SW_TGT - MBP_STRBUF)]
    ldr  r0, =BGPAL
    strh r1, [r0, #2]
.mbpz_dma:
    ldr  r0, =DMA3SAD
    movs r1, #0
    str  r1, [r0, #0]
    str  r1, [r0, #4]
    str  r1, [r0, #8]
    bx   lr
.ltorg

@ bs_fill16(r0=dst, r1=count, r2=hword val): shared 16-bit fill. Clobbers r0-r1.
.align 2
bs_fill16:
.bf16:
    strh r2, [r0]
    adds r0, r0, #2
    subs r1, r1, #1
    bne  .bf16
    bx   lr

@ bs_map_clear: zero the 32x32 tilemap.
.align 2
bs_map_clear:
    ldr  r0, =SCREEN_BASE
    ldr  r1, =(32*32)
    movs r2, #0
    b    bs_fill16

@ bs_place(r0=first tile id, r1=map offset, r2=tw, r3=th): lay a tile block.
.align 2
bs_place:
    push {r4-r7, lr}
    ldr  r4, =SCREEN_BASE
    lsls r1, r1, #1
    adds r4, r4, r1
    adds r5, r3, #0
.bs_pr:
    adds r6, r2, #0
.bs_pc:
    strh r0, [r4]
    adds r4, r4, #2
    adds r0, r0, #1
    subs r6, r6, #1
    bne  .bs_pc
    movs r7, #32
    subs r7, r7, r2
    lsls r7, r7, #1
    adds r4, r4, r7
    subs r5, r5, #1
    bne  .bs_pr
    pop  {r4-r7, pc}

@ bs_cleanup: restore display, DMA, palette, and VRAM state.
.align 2
bs_cleanup:
    push {lr}
    ldr  r1, =DMA3SAD
    movs r2, #0
    str  r2, [r1, #0]
    str  r2, [r1, #4]
    str  r2, [r1, #8]
    ldr  r1, =DMA0SAD
    str  r2, [r1, #0]
    str  r2, [r1, #4]
    str  r2, [r1, #8]
    ldr  r1, =MMIO
    movs r2, #0x80
    strh r2, [r1, #0]
    movs r2, #0
    strh r2, [r1, #8]
    ldr  r1, =BGPAL
    strh r2, [r1, #0]
    strh r2, [r1, #2]
    strh r2, [r1, #4]
    strh r2, [r1, #36]
    bl   bs_map_clear
    ldr  r0, =VRAM
    ldr  r2, =(BS_LAST_T * 32 / 4)
    movs r1, #0
.bs_ct:
    str  r1, [r0]
    adds r0, r0, #4
    subs r2, r2, #1
    bne  .bs_ct
    pop  {pc}

@ bs_anim(r0=ACTION): reveal, fade text, converge logo, then return/hang.
.ltorg @ literal pool for the early functions (bs_anim onward pools after fill_wobble)
bs_anim:
    push {r4-r7, lr}
    adds r7, r0, #0
    @ palette[0]/[1] = gray. [2]/[18]/[BS_PURCOL] were set by bs_draw.
    ldr  r1, =BGPAL
    ldr  r2, =COL_GRAY
    strh r2, [r1, #0]
    strh r2, [r1, #2]
    @ ACTION 1 text is static. CLEAN CART! blinks after convergence.
    cmp r7, #1
    bne .an_phase_reset
.an_text_black:
    ldr  r2, =COL_BLACK
    strh r2, [r1, #4]
.an_phase_reset:
    ldr  r0, =BS_WPHASE
    movs r1, #0
    strh r1, [r0]
    strh r1, [r0, #4]
    strh r1, [r0, #6]
    ldr  r2, =BS_WENV
    ldr  r1, =BS_WOB_ENV0
    strh r1, [r2]
    ldr  r1, =(CART + 0xbd)
    ldrb r1, [r1]
    strh r1, [r0, #2]
    ldr  r0, =BS_COPPER
    movs r1, #160
    ldr  r2, =COL_GRAY
    bl   bs_fill16
    ldr  r0, =BS_WOBBLE
    movs r1, #160
    movs r2, #0
    bl   bs_fill16
    @ Set HBlank DMA dst+count once. bs_frame re-arms src+enable.
    ldr  r6, =DMA3SAD
    ldr  r1, =(BGPAL + 2)
    str  r1, [r6, #4]
    movs r1, #1
    strh r1, [r6, #8]
    ldr  r6, =DMA0SAD
    ldr  r1, =BG0HOFS
    str  r1, [r6, #4]
    movs r1, #1
    strh r1, [r6, #8]
    ldr  r5, =BS_REVB
    movs r4, #0
.an_reveal:
    adds r4, #1
    strh r4, [r5]
    bl   bs_frame
    bl   bs_bcheck
    adds r7, r0, #0
    cmp  r4, #BS_LOGO_LINES
    blt  .an_reveal
    cmp  r7, #0
    beq  .an_dofade
    cmp  r7, #4
    bne  .an_converge
.an_dofade:
    ldr r6, =PAL_TEXT
    bl  an_fade8
    ldr r6, =PAL_TITLE
    bl  an_fade8
    b   .an_converge_entry
an_fade8:
    push {r6, lr}
    movs r4, #0
.anf_step:
    ldr  r6, [sp, #0]
    ldr  r2, =bs_fade
    lsls r1, r4, #1
    adds r2, r2, r1
    ldrh r3, [r2]
    @ ACTION 4 snaps palette[2] to black once diagnostics own the screen.
    ldr r1, =PAL_TEXT
    cmp r6, r1
    bne .anf_w
    cmp r7, #4
    bne .anf_w
    ldr r3, =COL_BLACK
.anf_w:
    strh r3, [r6]
    movs r5, #BS_FADE_FRAMES
.anf_fh:
    bl   bs_frame
    bl   bs_bcheck
    adds r7, r0, #0
    subs r5, #1
    bne  .anf_fh
    adds r4, #1
    cmp  r4, #8
    blt  .anf_step
    pop  {r6, pc}
.an_converge_entry:
.an_converge:
    ldr  r5, =BS_PURB
    movs r4, #0
.an_conv:
    adds r4, #1
    strh r4, [r5]
    bl   bs_frame
    bl   bs_bcheck
    adds r7, r0, #0
    cmp  r4, #BS_LOGO_LINES
    blt  .an_conv
    @ Band is uniformly BS_PURCOL, so disabling DMAs is visually seamless.
    ldr  r6, =DMA3SAD
    movs r1, #0
    strh r1, [r6, #0xa]
    ldr  r6, =DMA0SAD
    strh r1, [r6, #0xa]
    ldr  r2, =BG0HOFS
    strh r1, [r2]
    ldr  r1, =BGPAL
    ldr  r2, =BS_PURCOL
    ldrh r2, [r2]
    strh r2, [r1, #2]
    cmp  r7, #1
    beq  .an_hang
    cmp  r7, #3
    beq  .an_hang
    pop  {r4-r7, pc}
.an_hang:
    @ Hang screens still sample Start+Select for multiboot.
    ldr  r0, =(BGPAL + 36)
    ldr  r1, =COL_BLACK
    strh r1, [r0]
    movs r4, #0
    movs r5, #1
.ah_loop:
    bl   bs_trig_check
    ldr  r0, =MB_MODE_FLAG
    ldrb r0, [r0]
    cmp  r0, #0
    bne  .ah_to_multiboot
    bl   bs_wait_vblank
    adds r4, #1
    cmp  r4, #BS_BLINK_FRAMES
    blt  .ah_loop
    movs r4, #0
    movs r1, #1
    eors r5, r1
    ldr  r0, =(BGPAL + 36)
    cmp  r5, #0
    beq  .ah_hide
    ldr  r1, =COL_BLACK
    strh r1, [r0]
    b    .ah_loop
.ah_hide:
    ldr  r1, =COL_GRAY
    strh r1, [r0]
    b    .ah_loop
.ah_to_multiboot:
    pop {r4-r7, pc}

@ bs_frame: VBlank, refill band tables, re-arm HBlank DMAs. Clobbers r0-r3, r6.
bs_frame:
    push {lr}
    bl   bs_trig_check
    bl   bs_wait_vblank
    bl   fill_copper
    ldr  r6, =DMA3SAD
    movs r1, #0
    strh r1, [r6, #0xa]
    ldr  r1, =BS_COPPER
    str  r1, [r6, #0]
    ldr  r1, =DMA_HBL_PAL
    strh r1, [r6, #0xa]
    bl   fill_wobble
    ldr  r6, =DMA0SAD
    movs r1, #0
    strh r1, [r6, #0xa]
    ldr  r1, =BS_WOBBLE
    str  r1, [r6, #0]
    ldr  r1, =DMA_HBL_PAL
    strh r1, [r6, #0xa]
    pop  {pc}

@ bs_bcheck(r7=ACTION) -> ACTION or 4 if B enables diagnostics. Preserves r4-r7.
bs_bcheck:
    push {lr}
    cmp  r7, #0
    bne  .bc_keep
    ldr  r0, =REG_KEYINPUT
    ldrh r0, [r0]
    movs r1, #KEY_B
    ands r0, r1
    bne  .bc_keep
    movs r0, #0
    bl   bs_draw_debug
    ldr  r1, =BGPAL
    ldr  r2, =COL_BLACK
    strh r2, [r1, #4]
    movs r0, #4
    pop  {pc}
.bc_keep:
    adds r0, r7, #0
    pop  {pc}

@ fill_copper: rebuild logo-band palette[1] and stamp wipes.
.align 2
fill_copper:
    push {r4-r7, lr}
    ldr  r6, =sine_lut
    ldr  r5, =(BS_COPPER + BS_BAND_I0*2)
    ldr  r3, =BS_CPHASE
    ldrh r7, [r3]
    subs r7, #BS_COP_SPEED
    strh r7, [r3]
    movs r4, #BS_LOGO_LINES
.fc_loop:
    adds r0, r7, #0
    bl   gr_chan
    adds r1, r0, #0
    adds r0, r7, #0
    adds r0, #85
    bl   gr_chan
    lsls r0, r0, #5
    orrs r1, r0
    adds r0, r7, #0
    adds r0, #170
    bl   gr_chan
    lsls r0, r0, #10
    orrs r1, r0
    strh r1, [r5]
    adds r5, #2
    adds r7, #BS_COP_FREQ
    subs r4, #1
    bne  .fc_loop
    ldr  r2, =BS_REVB
    ldrh r3, [r2]
    ldrh r6, [r2, #2]
    ldr  r5, =(BS_COPPER + BS_BAND_I0*2)
    movs r1, #BS_LOGO_LINES
    subs r1, r1, r3
    beq  .fc_nogray
    lsls r0, r3, #1
    adds r0, r5, r0
    ldr  r2, =COL_GRAY
    bl   bs_fill16
.fc_nogray:
    cmp  r6, #0
    beq  .fc_nopur
    ldr  r2, =BS_PURCOL
    ldrh r2, [r2]
    adds r0, r5, #0
    adds r1, r6, #0
    bl   bs_fill16
.fc_nopur:
    pop {r4-r7, pc}
@ gr_chan(r0=hue) -> 0..31 channel. Branchless because hue can be cart-derived.
gr_chan:
    movs  r3, #0xff
    ands  r0, r3
    lsls  r0, r0, #1
    ldrsh r0, [r6, r0]
    asrs  r0, r0, #8
    asrs  r3, r0, #31
    bics  r0, r3
    lsrs  r3, r0, #5
    negs  r3, r3
    asrs  r3, r3, #31
    bics  r0, r3
    lsrs  r3, r3, #27
    orrs  r0, r3
    bx    lr

@ fill_wobble: rebuild logo band BG0HOFS offsets.
.align 2
fill_wobble:
    push {r4-r7, lr}
    ldr  r6, =sine_lut
    ldr  r5, =(BS_WOBBLE + BS_BAND_I0*2)
    ldr  r3, =BS_WPHASE
    ldrh r7, [r3]
    adds r7, #BS_WOB_SPEED
    strh r7, [r3]
    ldr  r2, =BS_PURB
    ldrh r2, [r2]
    movs r1, #BS_LOGO_LINES
    subs r2, r1, r2
    ldr  r3, =BS_WENV
    ldrh r1, [r3]
    adds r2, r2, r1
    @ wenv also boosts per line frequency until it decays.
    lsrs r4, r1, #BS_WOB_FBOOST
    adds r4, #BS_WOB_FREQ
    lsrs r0, r1, #BS_WOB_DECAY
    subs r1, r1, r0
    strh r1, [r3]
    adds r3, r4, #0
    movs r4, #BS_LOGO_LINES
.fw_loop:
    adds  r0, r7, #0
    movs  r1, #0xff
    ands  r0, r1
    lsls  r0, r0, #1
    ldrsh r0, [r6, r0]
    asrs  r0, r0, #BS_WOB_SHIFT
    muls  r0, r2
    asrs  r0, r0, #5
    strh  r0, [r5]
    adds  r5, #2
    adds  r7, r3
    subs  r4, #1
    bne   .fw_loop
    pop   {r4-r7, pc}
bs_fade:
    .hword 0x6338, 0x56d5, 0x4a72, 0x3e0f, 0x2d8b, 0x2128, 0x14c5, 0x0862
.ltorg

@ BitUnpack info: 1bpp -> 4bpp, nonzero -> palette index 2.
.align 2
bs_atlas_info:
    .hword BS_ATLAS_RAW
    .byte 1
    .byte 4
    .word 1                             @ atlas glyph ink, palette index 2
bs_str_mbrdy:
    .ascii "MULTIBOOT RDY"
bs_str_clean:
    .ascii "CLEAN CART!"
bs_str_logo:
    .ascii "LOGO"
bs_str_header:
    .ascii "HDR"
bs_str_cksum:
    .ascii "CKSUM"
bs_str_fix:
    .ascii "FIX"
bs_str_ok:
    .ascii "OK"
bs_str_bad:
    .ascii "BAD"

.align 2
.ltorg

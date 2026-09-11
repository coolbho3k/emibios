@ SPDX-License-Identifier: GPL-3.0-or-later
@ BitUnpack (SWI 0x10): expands packed bit units into wider units with an additive offset.
@
@ Entry:  r0 = source (packed data)
@         r1 = destination (32-bit aligned)
@         r2 = BitUnpack info:
@                u16 src_len      source length in bytes
@                u8  src_width    bits per source unit (1,2,4,8)
@                u8  dest_width   bits per dest unit (1,2,4,8,16,32)
@                u32 data_offset  added to nonzero units. bit31 = also add to zero units
@ Return: r0 = src + src_len, r1 = dst + stored_bytes, r2 preserved. Only whole 32-bit
@ words are stored. A trailing partial word is dropped and stays in r3.
@ r4-r11 saved/restored.
@
@ Source units are read LSB first, src_width bits each. A nonzero unit outputs
@ (unit + offset). A zero unit outputs offset when bit31 of data_offset is set, else it
@ is skipped and packs a zero. Output units (dest_width bits) are packed LSB first into
@ 32-bit words and stored.
@
@ Register roles: r0 src ptr, r1 dst ptr, r3 word accumulator, r4 src end, r5 offset,
@ r6 src_width, r7 dst_width, r8 output bit position, r9 src mask, r10 current byte,
@ r11 bits left in byte, r12 unit/out, lr zero-flag mask.
@
@ Cycles = DONE + BYTE*bytes + (UNIT+NZ)*packed + UNIT*skipped. NZ sits in the pack code,
@ so a skipped unit (value 0 with the zero-flag clear) is cheaper, since it leaves a zero
@ and skips the pack.
.arm
    .set BUP_BYTE,    6
    .set BUP_UNIT,    5
    .set BUP_NZ,      2
    .set BUP_WORD,    0
    .set BUP_DONE,    4 @ nops on the offset!=0 done path (after cmp/beq). offset==0 skips them -> -2
    .set BUP_DONE_RS, 7
swi_BitUnpack:
    push {r4-r11, lr}
    ldrh r4, [r2]
    @ Dual source region guard (src and src+len, len from the info struct, src not advanced).
    decomp_guard_arm r0, .bup_guardpad, r4
.bup_afterguard:
    ldrb r6, [r2, #2]
    ldrb r7, [r2, #3]
    ldr  r5, [r2, #4]
    and  lr, r5, #BIT31
    bic  r5, r5, #BIT31
    mov  r9, #1
    mov  r9, r9, lsl r6
    sub  r9, r9, #1
    add  r4, r0, r4
    mov  r3, #0
    mov  r8, #0
.bup_byte:
    cmp  r0, r4
    bge  .bup_done
    ldrb r10, [r0], #1
    mov  r11, #8
    .rept BUP_BYTE
    nop
    .endr
.bup_unit:
    ands  r12, r10, r9
    cmpeq lr, #0
    add   r12, r12, r5
    mov   r10, r10, lsr r6
    .rept BUP_UNIT
    nop
    .endr
    beq .bup_adv
    orr r3, r3, r12, lsl r8
    .rept BUP_NZ
    nop
    .endr
.bup_adv:
    add r8, r8, r7
    cmp r8, #32
    bne .bup_nextunit
    str r3, [r1], #4
    mov r3, #0
    mov r8, #0
    .rept BUP_WORD
    nop
    .endr
.bup_nextunit:
    subs r11, r11, r6
    bne  .bup_unit
    b    .bup_byte
.bup_done:
    @ Retail is observed 2 cycles cheaper when the added offset is 0, which is the common case of just
    @ widening packed units with no offset.
    cmp r5, #0 @ r5 = added offset (data_offset with bit31 cleared)
    beq .bup_done_zoff
    .rept BUP_DONE
    nop
    .endr
.bup_done_zoff:
    .rept BUP_DONE_RS
    mov r4, r4, lsl r4 @ register-specified shift pad. r4 is restored by the pop below,
    .endr                      @ so this changes no caller-visible register
.bup_badsrc:                    @ shared return. On guard fail, dst untouched and r0 = src
    pop {r4-r11, lr}
    bx  lr
.bup_guardpad:                  @ guard only: pad the skip path, then rejoin the shared return
    guard_pad 11 @ +11 plus the rejoin branch (3) -> 128, matches the retail BIOS
    b         .bup_badsrc

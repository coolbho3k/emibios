@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundGetJumpList (SWI 0x2a): writes a 36-entry jump table to [r0] for the game sound engine.
@
@ Entry:  r0 = table destination.  Return: r0 = dest + 144.
@
@ Games run the BIOS sound sequencer through this table. A track command byte C in 0xb1..0xce
@ dispatches to table[C - 0xb1](player, track). Notes and a few control commands are handled by
@ the game itself. Most slots are single byte parameter setters that read the arg at the track
@ command pointer (+0x40), store it into a track field, set the track's refresh flags (+0x00),
@ and consume the byte. Slot 12 loads a voice and slot 35 clears a player at init. Slots not yet
@ observed in any game currently point at a stub.
.thumb
.set GJL_BURN,   198
.set GJL_TRIM,   1
.set SCS_PAD,    0
.set UNLINK_PAD, 0
.macro SLOT_BURN cyc
    movs r3, #((\cyc + 1) / 4)
7017:
    subs r3, r3, #1
    bgt  7017b
    .rept ((\cyc + 1) % 4)
    nop
    .endr
.endm
.macro GJL_PTR target
    .hword \target - bios_base + 1
.endm
swi_SoundGetJumpList:
    ldr  r1, =gjl_ptr_table
    movs r2, #36
.gjl_loop:
    ldrh r3, [r1]
    str  r3, [r0]
    adds r0, r0, #4
    adds r1, r1, #2
    subs r2, r2, #1
    bgt  .gjl_loop
    @ Leave r1 at gjl_ptr_table + 144.
    adds r1, r1, #72
    movs r2, #GJL_BURN
.gjl_burn:
    subs            r2, r2, #1
    bgt             .gjl_burn
    guard_pad_thumb GJL_TRIM
    bx              lr
sound_jmpstub:
    bx lr

@ Slot 0 FINE (0xb1, track end). Release every channel in the track's chain (status |= 0x40,
@ owner +0x2c cleared), then clear the track's chain head (+0x20) and flags (+0x00) so the
@ sequencer stops advancing.
sound_fine:
    SLOT_BURN 22
    push      {r4, r5, r6}
    ldr       r2, [r1, #0x20]
    movs      r4, #0x40
    movs      r5, #0
1:
    cmp  r2, #0
    beq  2f
    ldr  r6, [r2, #0x34]
    ldrb r3, [r2, #0x00]
    orrs r3, r4
    strb r3, [r2, #0x00]
    str  r5, [r2, #0x2c]
    str  r5, [r2, #0x30]
    str  r5, [r2, #0x34]
    movs r2, r6
    b    1b
2:
    strb r5, [r1, #0x00]
    str  r5, [r1, #0x20]
    pop  {r4, r5, r6}
    bx   lr

@ Slot 1 GOTO (0xb2). Jump to cmdPtr, a 4-byte absolute target.
sound_goto:
    SLOT_BURN 16
    push      {r4}
    ldr       r2, [r1, #0x40]
    ldrb      r3, [r2, #0]
    ldrb      r4, [r2, #1]
    lsls      r4, r4, #8
    orrs      r3, r4
    ldrb      r4, [r2, #2]
    lsls      r4, r4, #16
    orrs      r3, r4
    ldrb      r4, [r2, #3]
    lsls      r4, r4, #24
    orrs      r3, r4
    str       r3, [r1, #0x40]
    pop       {r4}
    bx        lr

@ Slot 2 PATT (0xb3, pattern call). Push return (cmdPtr+4) onto the track's stack at
@ +0x44 + level*4, bump patternLevel (+0x02), and jump to the 4-byte target.
sound_patt:
    SLOT_BURN 25
    push      {r4, r5}
    ldrb      r2, [r1, #0x02]
    ldr       r4, [r1, #0x40]
    ldrb      r5, [r4, #0]
    ldrb      r3, [r4, #1]
    lsls      r3, r3, #8
    orrs      r5, r3
    ldrb      r3, [r4, #2]
    lsls      r3, r3, #16
    orrs      r5, r3
    ldrb      r3, [r4, #3]
    lsls      r3, r3, #24
    orrs      r5, r3
    adds      r4, r4, #4
    lsls      r3, r2, #2
    adds      r3, r3, r1
    str       r4, [r3, #0x44]
    adds      r2, r2, #1
    strb      r2, [r1, #0x02]
    str       r5, [r1, #0x40]
    pop       {r4, r5}
    bx        lr

@ Slot 3 PEND (0xb4, pattern return). If patternLevel>0, drop a level and restore cmdPtr
@ from the stack entry. Otherwise do nothing.
sound_pend:
    ldrb r2, [r1, #0x02]
    cmp  r2, #0
    beq  1f
    subs r2, r2, #1
    strb r2, [r1, #0x02]
    lsls r3, r2, #2
    adds r3, r3, r1
    ldr  r3, [r3, #0x44]
    str  r3, [r1, #0x40]
1:
    bx lr

@ Single byte parameter setter. field = track field offset, flags = refresh bits OR'd into the
@ track status (+0x00; 0 = none), bias = 1 subtracts 0x40 (center) from the byte first.
.macro PARAMSET name, field, flags, bias=0, pad=20
\name:
    SLOT_BURN \pad
    ldr       r2, [r1, #0x40]
    ldrb      r3, [r2]
    adds      r2, r2, #1
    str       r2, [r1, #0x40]
.if \bias
    subs r3, r3, #0x40
.endif
    strb r3, [r1, #\field]
.if \flags
    ldrb r2, [r1]
    movs r3, #\flags
    orrs r2, r3
    strb r2, [r1]
.endif
    bx lr
.endm
PARAMSET sound_priority, 0x1d, 0,    0, 20
PARAMSET sound_keyshift, 0x0a, 0x0c, 0, 20
PARAMSET sound_volume,   0x12, 0x03, 0, 20
PARAMSET sound_pan,      0x14, 0x03, 1, 20
PARAMSET sound_bend,     0x0e, 0x0c, 1, 20
PARAMSET sound_bendrange, 0x0f, 0x0c, 0, 20
PARAMSET sound_lfospeed, 0x19, 0,    0, 24
PARAMSET sound_lfodelay, 0x1b, 0,    0, 20
PARAMSET sound_moddepth, 0x17, 0,    0, 24
PARAMSET sound_modtype,  0x18, 0x0f, 0, 25
PARAMSET sound_tune,     0x0c, 0x0c, 1, 20

@ Slot 29 EOT (0xce, end tie). The operand is optional. Only a byte < 0x80 is a key
@ argument (consume + store to +0x05). A command/wait byte >= 0x80 is left in the stream.
sound_endtie:
    SLOT_BURN 30
    ldr       r2, [r1, #0x40]
    ldrb      r3, [r2]
    cmp       r3, #0x80
    bhs       1f
    adds      r2, r2, #1
    str       r2, [r1, #0x40]
    strb      r3, [r1, #0x05]
1:
    bx lr

@ Slot 10 Tempo (0xbb). player+0x1c = arg*2 (tempoU); recompute tempoI (player+0x20) =
@ (tempoU * tempoD) >> 8 so the sequencer ticks at the song's tempo, not the init default.
sound_tempo:
    SLOT_BURN 18
    ldr       r2, [r1, #0x40]
    ldrb      r3, [r2]
    adds      r2, r2, #1
    str       r2, [r1, #0x40]
    lsls      r3, r3, #1
    strh      r3, [r0, #0x1c]
    ldrh      r2, [r0, #0x1e]
    muls      r3, r2
    lsrs      r3, r3, #8
    strh      r3, [r0, #0x20]
    bx        lr

@ Slot 12 SetVoice (0xbd). Look up the program byte's 12-byte ToneData in the voicegroup at
@ [player+0x30] and copy it into the track (+0x24). Consume the program byte.
@ Entry: r0 = player, r1 = track.  Return: r0/r1 preserved, r2 = ToneData ptr, r3 = its last word.
sound_setvoice:
    SLOT_BURN 43
    push      {r4, r5}
    ldr       r4, [r1, #0x40]
    ldrb      r5, [r4]
    adds      r4, r4, #1
    str       r4, [r1, #0x40]
    lsls      r4, r5, #2
    lsls      r5, r5, #3
    adds      r5, r5, r4
    ldr       r2, [r0, #0x30]
    adds      r2, r2, r5
    ldr       r3, [r2]
    str       r3, [r1, #0x24]
    ldr       r3, [r2, #4]
    str       r3, [r1, #0x28]
    ldr       r3, [r2, #8]
    str       r3, [r1, #0x2c]
    pop       {r4, r5}
    bx        lr

@ Slot 34 unlink a channel from its track's doubly-linked chain.
@ track+0x20 = head; channel +0x30 = prev, +0x34 = next, +0x2c = owning track.
sound_unlinkchan:
    @ tk == 0: nothing to unlink (~10 cycles). Otherwise, relink the
    @ neighbours/track head around the channel and clear tk only (pp/np stay, as on retail).
    ldr             r3, [r0, #0x2c]
    cmp             r3, #0
    beq             .ul_out
    guard_pad_thumb UNLINK_PAD
    ldr             r2, [r0, #0x34]
    ldr             r1, [r3, #0x20]
    cmp             r1, r0
    bne             2f
    str             r2, [r3, #0x20]
2:
    ldr r1, [r0, #0x30]
    cmp r1, #0
    beq 3f
    str r2, [r1, #0x34]
3:
    cmp r2, #0
    beq 4f
    str r1, [r2, #0x30]
4:
    movs r1, #0
    str  r1, [r0, #0x2c]
.ul_out:
    bx lr

@ Slot 35 clear a 0x40-byte player struct at init, before the game fills it.
@ Entry: r0 = struct.  Return: r0 = struct + 0x40.
sound_clearstruct:
    movs            r1, #0
    movs            r2, #0
    movs            r3, #0
    stmia           r0!, {r1, r2, r3}
    stmia           r0!, {r1, r2, r3}
    stmia           r0!, {r1, r2, r3}
    stmia           r0!, {r1, r2, r3}
    stmia           r0!, {r1, r2, r3}
    str             r1, [r0]
    adds            r0, r0, #4
    guard_pad_thumb SCS_PAD
    bx              lr

.align 1
gjl_ptr_table:
    @ Entries are absolute addresses.
    GJL_PTR sound_fine
    GJL_PTR sound_goto
    GJL_PTR sound_patt
    GJL_PTR sound_pend
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_priority
    GJL_PTR sound_tempo
    GJL_PTR sound_keyshift
    GJL_PTR sound_setvoice
    GJL_PTR sound_volume
    GJL_PTR sound_pan
    GJL_PTR sound_bend
    GJL_PTR sound_bendrange
    GJL_PTR sound_lfospeed
    GJL_PTR sound_lfodelay
    GJL_PTR sound_moddepth
    GJL_PTR sound_modtype
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_tune
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_endtie
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_jmpstub
    GJL_PTR sound_unlinkchan
    GJL_PTR sound_clearstruct
    .ltorg

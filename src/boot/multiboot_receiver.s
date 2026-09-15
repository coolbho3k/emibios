@ SPDX-License-Identifier: GPL-3.0-or-later
@ Receives a program at boot time. Start+Select or no cart enters here.
@ Derived from GBATEK plus SIO captures via logic analyzer.
@ Supports JoyBus, Multiplay, or Normal-32.
@
@ JoyBoot: challenge-derived LCG key, clear 0xc0-byte header, encrypted body:
@     key   = 0x6177614b * key + 1
@     plain = cipher ^ key ^ -(0x02000000+off) ^ 0x20796220
@ CRC-16 seed 0x15a0/poly 0xa1c1. Final word is (totalBytes<<16)|crc16.
@ Per-word status keeps PSF1 set and toggles PSF0 from the word offset.
.thumb

@ JOY register offsets from REG_KEYINPUT (0x04000130).
    .set JB_RCNT,   (REG_RCNT   - REG_KEYINPUT)
    .set JB_JOYCNT, (REG_JOYCNT - REG_KEYINPUT)
    .set JB_RECV,   (REG_JOY_RECV  - REG_KEYINPUT)
    .set JB_TRANS,  (REG_JOY_TRANS - REG_KEYINPUT)
    .set JB_STAT,   (REG_JOYSTAT - REG_KEYINPUT)

@ Receiver scratch: in high IWRAM.
.equ MB_DONE_MARK,         0x03007f08 @ "booted a valid image" marker
.equ MB_CRC_STASH,         0x03007f0c @ dword(hh, rr1, rr2, rr3) stashed for the CRC final mix
@ JoyBoot state block lives low because JoyBus runs with IRQs live.
.equ RXF_POLY,             0          @ receive-loop stack frame, pushed at .rxn_cfg_done
.equ RXF_MAGIC,            4
.equ MBJ_BASE,             0x03001700
.equ MBJ_OFF,              0          @ received byte offset into the image
.equ MBJ_KEY,              4          @ Kawasedo cipher key (nonce ^ seed)
.equ MBJ_CRC,              8          @ running CRC accumulator
.equ MBJ_PHASE,            12         @ 0 = await authInitCode, 1 = body
.equ MBJ_END,              16         @ image end offset (decoded from the authInitCode)
.equ MBJ_GATE,             20         @ final-word CRC verified (0 = truncated transfer never boots)
.equ MBJ_FINAL,            24         @ address of the final (length|crc) word, precomputed at authInit
@ Set by bs_trig_check when Start+Select is held during cart boot.
.equ MB_MODE_FLAG,         0x03007f1c
.equ MB_WAIT_TIMEOUT,      0x00200000
.equ MB_WAIT_TIMEOUT_LONG, 0x08000000

@ Transport detector:
@   * GameCube (JoyBus):    a JOY_RESET latches JOYCNT.RESET (bit0)          -> joybus
@   * GBA link (Multiplay): the sender clocks a 16-bit transfer -> IF bit7   -> normal r11=1
@   * Normal-32 (some accesories): a 32-bit transfer  -> IF bit7    -> normal r11=0
@ Cycles RCNT/SIOCNT modes. Senders will retry until a dwell catches.
multiboot_receiver_detect:
    ldr r0, =SYS_STACK
    mov sp, r0
    @ If we enter while boot is happening, stop effect DMAs for the ready screen.
    movs r1, #0
    ldr  r0, =REG_DMA3CNT_H
    strh r1, [r0]
    ldr  r0, =REG_DMA0CNT_H
    strh r1, [r0]
    ldr  r0, =REG_BG0HOFS
    strh r1, [r0]
    @ Keep SIO neutral during the animation. Showing Multiplay too early desyncs link senders.
    movs r7, #1
    bl   bs_draw
    ldr  r6, =REG_SIO_BASE
    movs r0, #0
    strh r0, [r6, #0x14]
    movs r0, #0x08 @ SO-high idle: not a premature Multiplay/Normal receiver
    strh r0, [r6, #0x08]
    movs r0, #2    @ ACTION 2 = reveal + converge (logo only, no text)
    bl   bs_anim
    bl   bs_mbrdy_fade
    @ fall through. Listen re-inits stack/SIO

@ Steady-state transport listen loop. Also used after Start+Select during cart boot.
multiboot_receiver_listen:
    ldr  r0, =SYS_STACK
    mov  sp, r0
    movs r1, #0            @ stop any boot-screen HBlank DMAs
    ldr  r0, =REG_DMA3CNT_H
    strh r1, [r0]
    ldr  r0, =REG_DMA0CNT_H
    strh r1, [r0]
    ldr  r0, =REG_BG0HOFS
    strh r1, [r0]
    ldr  r6, =REG_SIO_BASE @ SIO base: SIODATA32 +0, SIOCNT +8, SIOMLT_SEND +0xa, RCNT +0x14
    ldr  r5, =REG_IF       @ IF
    ldr  r4, =REG_JOYCNT   @ JOYCNT
    movs r0, #0
    strh r0, [r6, #0x14]
    str  r0, [r6, #0x00]   @ pre-commit senders see zero, not stale junk
    strh r0, [r6, #0x0a]
    movs r0, #0x08
    strh r0, [r6, #0x08]   @ SIOCNT = SO-high idle until a dwell arms a mode
    bl   mbp_reset         @ receive UI back to idle "RDY"
    @ Quick initial scan, then mostly-Multiplay dwell so link senders see a steady receiver.
    @ r8/r9/r10 = Multiplay/JoyBus/Normal-32 dwells.
    movs r7, #0x20
    ldr  r3, =0x00000800
    mov  r8, r3
    mov  r9, r3
    mov  r10, r3
.det_round:
    movs r0, #0
    strh r0, [r6, #0x14]
    ldr  r0, =0x00006003
    strh r0, [r6, #0x08]
    movs r0, #0x80 @ drain a stale SIO IF latched at the tail of another dwell,
    strh r0, [r5]  @ so this dwell only triggers on ITS OWN completion
    mov  r3, r8    @ Multiplay dwell
.det_mp:
    ldrh r0, [r5]
    movs r1, #0x80
    tst  r0, r1
    bne  .det_go_multi
    ldrh r0, [r4]
    movs r1, #JOYCNT_RESET
    tst  r0, r1
    bne  .det_go_joybus
    subs r3, #1
    bne  .det_mp
    ldr  r0, =RCNT_JOYBUS @ JoyBus dwell
    strh r0, [r6, #0x14]
    mov  r3, r9
.det_jb:
    ldrh r0, [r4]
    movs r1, #JOYCNT_RESET
    tst  r0, r1
    bne  .det_go_joybus
    subs r3, #1
    bne  .det_jb
    movs r0, #0          @ Normal-32 dwell
    strh r0, [r6, #0x14]
    str  r0, [r6, #0x00] @ idle reply 0 (what a pre-commit retail receiver presents)
    ldr  r0, =0x00005080
    strh r0, [r6, #0x08]
    movs r0, #0x80       @ drain stale SIO IF (see the Multiplay dwell)
    strh r0, [r5]
    mov  r3, r10
.det_n32:
    ldrh r0, [r5]
    movs r1, #0x80
    tst  r0, r1
    bne  .det_go_norm32
    ldrh r0, [r4]
    movs r1, #JOYCNT_RESET
    tst  r0, r1
    bne  .det_go_joybus
    subs r3, #1
    bne  .det_n32
    cmp  r7, #0
    beq  .det_round
    subs r7, #1
    bne  .det_round
    @ Settle: mostly Multiplay, with JoyBus/Normal dips wide enough for sender retries.
    ldr r3, =0x00080000
    mov r8, r3
    ldr r3, =0x00030000
    mov r9, r3
    ldr r3, =0x0001a000
    mov r10, r3
    b   .det_round
.det_go_joybus:
    ldr r0, =multiboot_receiver_joybus + 1
    bx  r0
@ A completed transfer can be cross-mode noise. Commit only on the repeated recognition word.
.det_go_multi:
    movs r0, #0x80
    strh r0, [r5]        @ consume the IF this commit is acting on
    ldrh r0, [r6, #0x00] @ SIOMULTI0 = the sender's word
    ldr  r1, =0x00006200
    cmp  r0, r1
    bne  .det_round
    movs r0, #1          @ r11 = transport: Multiplay
    mov  r11, r0
    ldr  r0, =multiboot_receiver_normal + 1
    bx   r0
.det_go_norm32:
    movs r0, #0x80
    strh r0, [r5]
    ldr  r0, [r6, #0x00] @ SIODATA32
    ldr  r1, =0x00006200
    cmp  r0, r1
    bne  .det_round
    movs r0, #0          @ r11 = transport: Normal-32
    mov  r11, r0
    ldr  r0, =multiboot_receiver_normal + 1
    bx   r0

    .ltorg

@ GameCube JoyBoot receive
multiboot_receiver_joybus:
    ldr  r0, =SYS_STACK
    mov  sp, r0            @ private stack
    ldr  r6, =REG_KEYINPUT @ base for all JOY register accesses
    ldr  r0, =RCNT_JOYBUS
    strh r0, [r6, #JB_RCNT]
    movs r0, #0
    ldr  r1, =MB_DONE_MARK
    str  r0, [r1]          @ may hold stale data pre-RamReset
    @ Fresh receive UI per session.
    bl mbp_reset
    @ Route SIO/JOY IRQs through the BIOS user-IRQ vector.
    ldr r0, =mb_joy_irq @ ARM trampoline (exception_irq's ldr-pc runs it in ARM)
    ldr r1, =USER_IRQ_VECTOR_MIRROR
    str r0, [r1]
    @ Enable Serial IRQ before presenting the challenge. JOYSTAT=0x08 is the GC's ready signal.
    movs r0, #0x47            @ JOYCNT IRQ-enable (bit6) + clear RESET/RECV/TRANS pending from the
    strh r0, [r6, #JB_JOYCNT] @ detect phase so no stale bit mis-dispatches
    ldr  r2, =REG_IE
    movs r0, #0x80
    strh r0, [r2]
    movs r0, #1
    strh r0, [r2, #8]
    bl   mb_joy_seed
@ Wait with IRQs live until the handler marks the image boot-ready.
.mbj_wait:
    bl  mbp_tick       @ palette sweep runs in the foreground. The port lives in the IRQ
    ldr r1, =MB_DONE_MARK
    ldr r0, [r1]
    cmp r0, #0xb7
    bne .mbj_wait
    bl  mb_boot_linger @ the retail ~3s post-receive window. The GC polls status through it.
    ldr r1, =MB_DONE_MARK
    ldr r0, [r1]
    cmp r0, #0xb7      @ a mid-window GC RESET rewinds the boot. Go back to receiving
    bne .mbj_wait
    bl  mbp_finish     @ settle the palette sweep + park DMA3 before entering the image
    @ Clear IWRAM, then patch entry to B 0x020000e0 so the JoyBus path runs.
    ldr  r0, =IWRAM_START
    ldr  r1, =0x03007e00
    movs r2, #0
.mbj_clr:
    str  r2, [r0]
    adds r0, #4
    cmp  r0, r1
    blo  .mbj_clr
    ldr  r0, =RAM_ENTRYPOINT
    ldr  r1, =0xea000036 @ B 0x020000e0 (JoyBus entry)
    str  r1, [r0]
    ldr  r0, =0x020000c4 @ JoyBus channel = 1. A wrong channel gets no response and forces a reset
    movs r1, #1
    str  r1, [r0]
    @ JoyBus handoff: JOYCNT IRQ enabled, JOYSTAT/JOY_TRANS clear. Game drives verify+data.
    ldr  r2, =REG_IE
    movs r0, #0
    strh r0, [r2, #8]
    strh r0, [r2]
    ldr  r1, =0x0000ffff
    strh r1, [r2, #2] @ IF = ack pending
    movs r0, #0
    @ JOYSTAT = 0. Do not write JOY_TRANS here. Hardware would set SEND.
    strh r0, [r6, #JB_STAT]
    movs r0, #0x40
    strh r0, [r6, #JB_JOYCNT]
    ldr  r0, =0x00005088
    ldr  r1, =REG_SIOCNT
    strh r0, [r1] @ SIOCNT handoff value
    movs r0, #0
    movs r1, #0
    ldr  r5, =RAM_ENTRYPOINT
    mov  lr, r5
    ldr  r2, =mb_boot_tail + 1
    bx   r2

@ Seed JoyBoot state and present the challenge nonce. in: r6=JOY base. Clobbers r0-r3.
mb_joy_seed:
    ldr  r3, =MBJ_BASE
    ldr  r0, =0xc0debabe      @ challenge nonce
    str  r0, [r6, #JB_TRANS]
    ldr  r1, =MB_LCG_MUL
    eors r0, r1
    movs r2, #0
    str  r2, [r3, #MBJ_OFF]
    str  r0, [r3, #MBJ_KEY]
    ldr  r0, =0x000015a0
    str  r0, [r3, #MBJ_CRC]
    str  r2, [r3, #MBJ_PHASE] @ phase = 0 (await authInitCode)
    str  r2, [r3, #MBJ_END]   @ image end offset = unknown (decoded from the authInitCode)
    str  r2, [r3, #MBJ_GATE]  @ final-word CRC verified? 0 = no (so a truncated transfer never boots)
    movs r0, #JOYSTAT_SEND
    strh r0, [r6, #JB_STAT]
    bx   lr
mb_joy_rearm:
    push {lr}
    movs r1, #0x47
    strh r1, [r6, #JB_JOYCNT]
    bl   mb_joy_seed
    movs r0, #(JOYSTAT_PSF0 | JOYSTAT_SEND)
    strh r0, [r6, #JB_STAT]
    bl   mbp_reset
    pop  {pc}

@ SIO/JOY IRQ handler = JoyBoot state machine. One transfer per IRQ. Phases: authInitCode, body.
@ After the done read, retail stays status 0 while the program boots and takes over the port.
@ ARM trampoline: exception_irq's vector load enters ARM state. bx into the Thumb body.
.arm
.align 2
mb_joy_irq:
    ldr r12, =mb_joy_irq_t + 1
    bx  r12
.thumb
mb_joy_irq_t:
    push {r4-r7, lr}
    ldr  r6, =REG_KEYINPUT @ JOY base
    ldr  r0, =REG_IF
    movs r1, #0x80
    strh r1, [r0]          @ ack the Serial IRQ
    ldr  r3, =MB_DONE_MARK
    ldr  r3, [r3]
    cmp  r3, #0xb7
    bne  .mbj_h_notbooted
    @ During post-receive linger, retail presents status 0. RESET here cancels the pending boot.
    ldrh r0, [r6, #JB_JOYCNT]
    movs r1, #JOYCNT_RESET
    tst  r0, r1
    beq  .mbj_h_boot_ack
    ldr  r1, =MB_DONE_MARK
    movs r0, #0
    str  r0, [r1]
    bl   mb_joy_rearm @ full receive-UI unwind (sweep parked, logo purple, "RDY")
    b    .mbj_h_ret
.mbj_h_boot_ack:
    movs r1, #0x47
    strh r1, [r6, #JB_JOYCNT]
    b    .mbj_h_ret
.mbj_h_notbooted:
    ldr  r3, =MBJ_BASE
    ldrh r0, [r6, #JB_JOYCNT]
    movs r1, #JOYCNT_RESET
    tst  r0, r1
    beq  .mbj_h_not_reset
    @ RESET restarts the handshake: ack stale bits, re-seed, present 0x18, unwind UI.
    bl mb_joy_rearm
    b  .mbj_h_ret
.mbj_h_not_reset:
    ldr  r4, [r3, #MBJ_OFF]
    ldr  r1, =RAM_ENTRYPOINT
    adds r4, r1     @ r4 = dest = 0x02000000 + off
    ldr  r5, [r3, #MBJ_KEY]
    ldr  r7, [r3, #MBJ_CRC]
    movs r1, #JOYCNT_RECV
    tst  r0, r1
    bne  .mbj_h_recv
    movs r1, #JOYCNT_TRANS
    tst  r0, r1
    bne  .mbj_h_trans
    b    .mbj_h_ret @ spurious
@ a READ (JOY_TRANS)
.mbj_h_trans:
    movs r1, #0x44
    strh r1, [r6, #JB_JOYCNT]
    ldr  r0, [r3, #MBJ_PHASE]
    cmp  r0, #1
    bhs  .mbj_h_trans_done @ (invert + long branch: the done-read handler outgrew Thumb's range)
    b    .mbj_h_ret        @ phase 0: challenge read -> leave the nonce in JOY_TRANS, ignore
.mbj_h_trans_done:
    @ Done-read after the last body word: boot only if the final CRC/length gate opened.
    ldr  r1, [r3, #MBJ_GATE] @ r3 = MBJ_BASE here (set at .mbj_h_not_reset)
    cmp  r1, #0
    beq  .mbj_h_badimg
    movs r0, #0
    strh r0, [r6, #JB_STAT]  @ PSF clear, belt+braces if the body-end scrub was missed
    ldr  r1, =MB_DONE_MARK
    movs r0, #0xb7
    str  r0, [r1]
    b    .mbj_h_ret
.mbj_h_badimg:
    @ Corrupt/truncated image: never boot it. Re-arm like RESET.
    bl mb_joy_rearm
    b  .mbj_h_ret
@ a WRITE (JOY_RECV)
.mbj_h_recv:
    movs r1, #0x42
    strh r1, [r6, #JB_JOYCNT]
    @ One 32-bit read clears JOYSTAT.RECV reliably. Halfword reads left it sticky on OpenFPGA.
    ldr  r0, [r6, #JB_RECV]
    ldr  r2, [r3, #MBJ_PHASE]
    cmp  r2, #0
    beq  .mbj_h_authinit
    ldr  r1, [r3, #MBJ_END] @ retry/stray at/past end: consume and keep clean done-read state
    ldr  r2, =RAM_ENTRYPOINT
    adds r1, r2
    cmp  r4, r1             @ (r4 is the full dest address. End is an image offset)
    blo  .mbj_h_body
    movs r0, #0
    strh r0, [r6, #JB_STAT]
    ldr  r0, =0x020001f8
    ldr  r1, [r0, #4]
    ldr  r0, [r0]
    muls r0, r1
    str  r0, [r6, #JB_TRANS]
    b    .mbj_h_ret
.mbj_h_body:
    @ Ack before decrypt+CRC. The GC polls JOYSTAT immediately after each word.
    adds r1, r4, #0
    lsrs r1, r1, #2
    movs r2, #1
    ands r1, r2
    eors r1, r2 @ PSF0 = !((off>>2)&1) (word0 -> PSF0=1, toggling)
    lsls r1, r1, #4
    adds r1, #(JOYSTAT_PSF1 | JOYSTAT_RECV)
    strh r1, [r6, #JB_STAT]
    @ Program word: header stores clear. Body decrypts + CRCs.
    ldr  r1, =MB_RAM_ENTRY
    cmp  r4, r1
    blo  .mbj_h_store
    ldr  r1, =0x6177614b
    muls r5, r1
    adds r5, #1
    eors r0, r5
    negs r1, r4
    eors r0, r1
    ldr  r1, =0x20796220
    eors r0, r1 @ -> plaintext
    @ Final word is (totalBytes<<16)|crc16 over prior body words. Verify, do not fold.
    ldr r1, [r3, #MBJ_FINAL]
    cmp r4, r1
    beq .mbj_h_final
    bl  mb_crc @ updates r7 (crc), clobbers r1-r3, preserves r0,r4,r5,r6
    b   .mbj_h_store
.mbj_h_final:
    lsls r1, r0, #16
    lsrs r1, r1, #16         @ received CRC (low 16)
    lsls r2, r7, #16
    lsrs r2, r2, #16         @ our running CRC (low 16)
    cmp  r1, r2
    bne  .mbj_h_store        @ mismatch: store the word but leave the gate clear -> no boot
    lsrs r1, r0, #16         @ claimed length (high 16)
    ldr  r2, [r3, #MBJ_END]
    subs r2, #4
    lsls r2, r2, #16
    lsrs r2, r2, #16
    cmp  r1, r2
    bne  .mbj_h_store
    movs r1, #1
    str  r1, [r3, #MBJ_GATE] @ final word verified -> boot-gate open
.mbj_h_store:
    str  r0, [r4]
    adds r4, #4
    ldr  r3, =MBJ_BASE       @ mb_crc clobbered r3. Reload the state base
    ldr  r1, =RAM_ENTRYPOINT
    subs r4, r1
    str  r4, [r3, #MBJ_OFF]
    str  r5, [r3, #MBJ_KEY]
    str  r7, [r3, #MBJ_CRC]
    ldr  r1, [r3, #MBJ_END]
    adds r0, r4, #0
    bl   mbp_field           @ progress CCCC/TTTT (preserves r4-r7; ~3us of the ~317us budget)
    ldr  r3, =MBJ_BASE
    ldr  r1, [r3, #MBJ_END]  @ at body end, scrub PSF+TRANS for retail-like done-read status
    cmp  r4, r1
    bne  .mbj_h_ret
    movs r0, #0
    strh r0, [r6, #JB_STAT]
    ldr  r0, =0x020001f8
    ldr  r1, [r0, #4]
    ldr  r0, [r0]
    muls r0, r1
    str  r0, [r6, #JB_TRANS] @ 32-bit, like every JOY data access
    b    .mbj_h_ret
.mbj_h_authinit:
    @ authInitCode enters body and encodes packetPairCount in t3 bits 0-6, 8-14, 16.
    @ GC send loop includes the final word, so image end = 8*count + 0x204.
    ldr  r1, =0x6177614b
    eors r0, r1          @ t3 candidate
    movs r1, #2
    lsls r1, r1, #8      @ bit9
    tst  r0, r1
    beq  .mbj_h_ai_key
    ldr  r1, =0x0e130438 @ = 0x6177614b ^ 0x6f646573: flip to the other key's t3
    eors r0, r1
.mbj_h_ai_key:
    movs r1, #0x7f
    ands r1, r0             @ count bits 0-6
    lsrs r2, r0, #8
    movs r4, #0x7f
    ands r2, r4
    lsls r2, r2, #7
    orrs r1, r2             @ | count bits 7-13 (t3 bits 8-14)
    lsrs r2, r0, #16
    movs r4, #1
    ands r2, r4
    lsls r2, r2, #14
    orrs r1, r2             @ | count bit 14 (t3 bit 16)
    lsls r1, r1, #3         @ *8 bytes per pair
    ldr  r2, =0x204
    adds r1, r2
    str  r1, [r3, #MBJ_END] @ image end offset
    ldr  r2, =(RAM_ENTRYPOINT - 4)
    adds r2, r1
    @ Precompute final word address so the check is one compare per word.
    str  r2, [r3, #MBJ_FINAL]
    lsrs r4, r0, #16 @ paletteSpeedCoded: same CCC/D/SS layout as link palette byte
    movs r2, #0xff
    ands r4, r2
    @ Do not touch JOY_TRANS here. Even writing 0 sets JOYSTAT.SEND.
    movs r0, #1
    str  r0, [r3, #MBJ_PHASE] @ phase = 1
    movs r0, #JOYSTAT_PSF1
    strh r0, [r6, #JB_STAT]
    @ Protocol writes done. UI updates use a gap before the next wire write.
    adds r0, r4, #0
    bl   mbp_tint
    movs r0, #0
    ldr  r1, =MBJ_BASE
    ldr  r1, [r1, #MBJ_END]
    bl   mbp_field @ 0000/TTTT: the denominator is known from here on
    b    .mbj_h_ret
.mbj_h_ret:
    pop {r4-r7}
    pop {r3} @ saved lr (exception_irq's ARM return, 0x138)
    @ bx, not pop-pc: switch back to ARM for exception_irq's IRET.
    bx r3

@ Retail leaves ~3s between transfer end and image entry. Senders rely on that window.
@ Clobbers r0-r2.
mb_boot_linger:
    push {r4, lr}
    movs r4, #180
.mbl_frame:
    ldr r0, =REG_VCOUNT
.mbl_w1:
    bl   mbp_tick @ tick continuously so its edge detector sees non-VBlank too
    ldrh r1, [r0]
    cmp  r1, #160
    beq  .mbl_w1
.mbl_w2:
    bl   mbp_tick
    ldrh r1, [r0]
    cmp  r1, #160
    bne  .mbl_w2
    subs r4, #1
    bne  .mbl_frame
    pop  {r4, pc}

@ CRC-16 step over a 32-bit plaintext word. in: r0=word, r7=crc. Preserves r0,r4,r5,r6.
mb_crc:
    push {r0}
    movs r2, #32
    ldr  r3, =0x0000a1c1
.mb_crc_bit:
    adds r1, r0, #0
    eors r1, r7
    lsrs r7, r7, #1
    lsrs r1, r1, #1 @ test old bit0 (-> carry)
    bcc  .mb_crc_no
    eors r7, r3
.mb_crc_no:
    lsrs r0, r0, #1
    subs r2, #1
    bne  .mb_crc_bit
    pop  {r0}
    bx   lr

    .ltorg

@ GBA-link receiver: r11=0 Normal-32, r11!=0 Multiplay. Sender clocks every transfer.
@ Flow: recognition, header, palette, handshake, length, encrypted body, CRC, boot.
multiboot_receiver_normal:
    ldr  r0, =SYS_STACK
    mov  sp, r0
    ldr  r6, =REG_SIO_BASE
    movs r0, #0
    strh r0, [r6, #0x14] @ RCNT = 0 (Normal vs Multiplay chosen via SIOCNT below)
    mov  r0, r11
    cmp  r0, #0
    beq  .rxn_cfg_norm32
    ldr  r0, =0x00006003 @ SIOCNT: Multiplay receiver + IRQ + baud
    ldr  r1, =0x0000a517
    ldr  r2, =MB_MAGIC_MULTI
    b    .rxn_cfg_done
.rxn_cfg_norm32:
    @ Normal-32 is armed only after reply word is loaded, so no stale SIODATA32 leaks.
    ldr r0, =0x00005008
    ldr r1, =0x0000c37b
    ldr r2, =MB_MAGIC_NORMAL
.rxn_cfg_done:
    push {r1, r2} @ frame: [sp, #RXF_POLY] = CRC poly, [sp, #RXF_MAGIC] = handshake magic
    strh r0, [r6, #0x08]
    ldr  r1, =REG_IE
    movs r0, #0x80
    strh r0, [r1] @ IE = SIO so IF latches each transfer (IME stays 0, we poll)
    @ Fresh receive UI per attempt.
    bl   mbp_reset
    movs r2, #0 @ first recognition reply = 0 (per GBATEK)
    mov  r9, r2 @ echo accumulator (low 16 of last sender word)
    movs r4, #0 @ state = 0 (recognition)
    b    .rx_setreply
@ Per transfer: wait IF bit7, read sender word, stage NEXT reply, advance state.
.rxn_loop:
    ldr r1, =REG_IF          @ IF
    ldr r3, =MB_WAIT_TIMEOUT @ re-arm the watchdog for THIS transfer's wait
    cmp r4, #4               @ state 4 (length wait) = the sender's pre send menu. Be patient
    bne .rxn_wait
    ldr r3, =MB_WAIT_TIMEOUT_LONG
.rxn_wait:
    bl   mbp_tick    @ preserves all registers. Frame edge gated palette sweep
    ldrh r0, [r1]
    lsls r2, r0, #24 @ IF bit7 -> bit31
    bmi  .rxn_got
    subs r3, #1
    bne  .rxn_wait
    @ Stalled: mid-protocol re-arm this mode. In recognition, return to transport detect.
    cmp r4, #0
    beq .rxn_to_listen
    ldr r0, =multiboot_receiver_normal + 1 @ (r11 mode survives)
    bx  r0
.rxn_to_listen:
    ldr r0, =multiboot_receiver_listen + 1
    bx  r0
.rxn_got:
    movs r0, #0x80
    strh r0, [r1]        @ clear IF bit7
    mov  r2, r11
    cmp  r2, #0
    bne  .rxn_rd_multi
    ldr  r0, [r6, #0x00] @ Normal: SIODATA32 = full 32-bit word
    mov  r9, r0          @ low 16 is echoed in our next reply (Normal convention)
    b    .rxn_rd_done
.rxn_rd_multi:
    ldrh r0, [r6, #0x00] @ Multiplay: SIOMULTI0 = 16-bit word
.rxn_rd_done:
    @ Reply lags one transfer, so repeated commands must be idempotent.
    cmp r4, #1
    beq .rx_header
    cmp r4, #2
    beq .rx_post
    cmp r4, #3
    beq .rx_palette
    cmp r4, #4 @ (far targets from here on: invert + long branch, past Thumb's +/-256)
    bne .rx_disp_chk5
    b   .rx_length
.rx_disp_chk5:
    cmp r4, #5
    bne .rx_disp_chk6
    b   .rx_body_lo
.rx_disp_chk6:
    cmp r4, #6
    bne .rx_disp_chk7
    b   .rx_body_hi
.rx_disp_chk7:
    cmp r4, #7
    bne .rx_disp_chk8
    b   .rx_comp
.rx_disp_chk8:
    cmp r4, #8
    bne .rx_disp_chk9
    b   .rx_done
.rx_disp_chk9:
    cmp r4, #9
    bne .rx_recog @ no state matched 1-9: state 0 = recognition
    b   .rx_comp_ready
rx_getbit:
    @ r3 = 1 << receiver id. Multiplay reads SIOCNT[5:4]. Normal-32 acts as lone id 1.
    @ clobbers r1, preserves r0.
    mov  r3, r11
    cmp  r3, #0
    beq  .rx_getbit_n32
    ldrh r1, [r6, #0x08] @ SIOCNT
    lsrs r1, r1, #4
    movs r3, #3
    ands r3, r1          @ id 0..3
    movs r1, #1
    lsls r1, r3
    adds r3, r1, #0      @ r3 = 1<<id
    bx   lr
.rx_getbit_n32:
    movs r3, #0x02 @ Normal: lone receiver = id 1
    bx   lr
.rx_recog:                            @ 0x62xx -> reply 0x72|bit (idempotent). 0x61xx ends recognition
    bl   rx_getbit
    movs r2, #0x72
    lsls r2, r2, #8
    orrs r2, r3
    lsrs r1, r0, #8
    cmp  r1, #0x61
    beq  .rx_recog_adv
    b    .rx_setreply
.rx_recog_adv:                        @ 0x61xx ends recognition
    movs r4, #1
    ldr  r7, =RAM_ENTRYPOINT @ header dest
    bl   rx_getbit
    movs r2, #0x60
    lsls r2, r2, #8
    orrs r2, r3              @ pre-load 0x60<<8|bit (header countdown start). Sender reads it next
    bl   .rx_reply_now       @ stage first (the UI draws ride the sender's inter-transfer gap)
    movs r0, #0
    movs r1, #0
    bl   mbp_field           @ transfer begins: 0000/0000 replaces RDY
    b    .rxn_loop
.rx_header:                           @ store the 0xc0-byte header to 0x02000000..
    strh r0, [r7]
    adds r7, #2
    @ Header reply high byte counts down 0x60..0x00. Fixed value makes sender restart.
    bl   rx_getbit
    ldr  r1, =MB_RAM_ENTRY
    subs r1, r1, r7
    lsrs r1, r1, #1
    lsls r1, r1, #8
    orrs r1, r3
    adds r2, r1, #0
    ldr  r1, =MB_RAM_ENTRY
    cmp  r7, r1
    bcs  .rx_header_done
    bl   .rx_reply_now
    b    .rx_hdr_field
.rx_header_done:
    movs r4, #2 @ -> post-header wait
    bl   .rx_reply_now
.rx_hdr_field:
    adds r0, r7, #0 @ staged. Now draw 0002..00C0 / 0000 in the gap window
    ldr  r1, =RAM_ENTRYPOINT
    subs r0, r1
    movs r1, #0
    bl   mbp_field
    b    .rxn_loop
.rx_post:                             @ post-header wait: 0x62xx -> 0x72|bit. 0x63pp -> enter palette
    lsrs r1, r0, #8
    cmp  r1, #0x63
    bne  .rx_post_wait
    movs r4, #3
    b    .rx_palette
.rx_post_wait:
    bl   rx_getbit
    movs r2, #0x72
    lsls r2, r2, #8
    orrs r2, r3
    b    .rx_setreply
.ifndef RX_CC
    .equ RX_CC, 0xc8 @ our receiver_data (palette reply low byte + cipher seed cc)
.endif
.ifndef RX_RR
    .equ RX_RR, 0xc8 @ our length-reply low byte (the sender reads this as the CRC 'rr')
.endif
.rx_palette:                          @ 0x63pp -> save pp into the seed low byte, reply 0x73cc (idempotent)
    lsrs r1, r0, #8
    cmp  r1, #0x64
    beq  .rx_palette_hs
    lsls r1, r0, #24
    lsrs r1, r1, #24
    adds r5, r1, #0 @ seed low = pp (cd1..cd3 folded in at the handshake below)
    ldr  r2, =(0x7300 | RX_CC)
    bl   .rx_reply_now
    adds r0, r5, #0
    bl   mbp_tint   @ recolor after staging
    b    .rxn_loop
.rx_palette_hs:                       @ 0x64hh -> finalize the cipher seed, reply 0x73rr
    @ Multiplay seed folds all receivers' cd bytes, so read all SIOMULTI slots.
    mov  r1, r11
    cmp  r1, #0
    beq  .rx_pal_hs_n32
    adds r3, r5, #0
    bl   rx_pack3
    adds r5, r3, #0 @ cipher seed m
    @ Stash hh from the wire for final CRC mix. It is not recomputable from seed.
    lsls r1, r0, #24
    lsrs r1, r1, #24
    ldr  r3, =MB_CRC_STASH
    str  r1, [r3]
    b    .rx_pal_hs_reply
.rx_pal_hs_n32:                       @ Normal single receiver: seed = pp | cc<<8 | 0xffff<<16
    @ Normal seed uses absent receivers as 0xff: m=0xffffccpp.
    movs r1, #RX_CC
    lsls r1, r1, #8
    orrs r5, r1
    ldr  r1, =0xffff0000
    orrs r5, r1
    @ Stash wire hh. Sender includes absent receivers in it too.
    lsls r1, r0, #24
    lsrs r1, r1, #24
    ldr  r3, =MB_CRC_STASH
    str  r1, [r3]
.rx_pal_hs_reply:
    ldr  r2, =(0x7300 | RX_RR) @ reply 0x73rr, advance to length
    movs r4, #4
    b    .rx_setreply
.rx_length:                           @ llll -> count = llll + 0x34. Set up the body region
    @ Build final CRC mix now. SIOMULTI1/2/3 hold length replies when sender reads.
    mov r1, r11
    cmp r1, #0
    beq .rx_len_nocrc
    ldr r2, =MB_CRC_STASH
    ldr r3, [r2]
    bl  rx_pack3
    str r3, [r2] @ stash dword(hh, rr1, rr2, rr3) for .rx_fincrc
.rx_len_nocrc:
    lsls r1, r0, #16
    lsrs r1, r1, #16
    adds r1, #0x34
    lsls r1, r1, #2
    ldr  r7, =MB_RAM_ENTRY @ body dest (entry point)
    adds r1, r7
    mov  r8, r1            @ r8 = body end
    @ >256KB body would mirror-wrap over the image with the wire CRC still passing.
    ldr r0, =(RAM_ENTRYPOINT + 0x40000)
    cmp r1, r0
    bls .rx_len_ok
    b   .rx_crc_bad
.rx_len_ok:
    mov r0, r11 @ CRC seed per mode
    cmp r0, #0
    beq .rx_len_seedN
    ldr r1, =0x0000fff8
    b   .rx_len_seedD
.rx_len_seedN:
    ldr r1, =0x0000c387
.rx_len_seedD:
    mov  r10, r1
    ldr  r2, =0x000000c0 @ reply = first body offset 0xc0
    movs r4, #5
    bl   .rx_reply_now   @ stage first (the body starts ~36us out), then the denominator
    movs r0, #0xc0
    mov  r1, r8
    ldr  r2, =RAM_ENTRYPOINT
    subs r1, r2
    bl   mbp_field       @ 000C/TTTT: total bytes = 0xc0 + (length + 0x34)*4
    b    .rxn_loop
@ Body: Normal sends 32-bit words. Multiplay sends low/high halves. Replies lag one transfer.
.rx_body_lo:                          @ state 5: a body transfer
    mov r1, r11
    cmp r1, #0
    beq .rx_body_proc @ Normal: r0 already holds the full 32-bit enc word
    @ Multiplay: this is the LOW 16-bit halfword
    lsls r1, r0, #16
    lsrs r1, r1, #16
    mov  r9, r1 @ save low half
    adds r2, r7, #0
    lsls r2, r2, #16
    lsrs r2, r2, #16
    adds r2, #2 @ reply = next (high) halfword's offset
    movs r4, #6
    b    .rx_setreply
.rx_body_hi:                          @ Multiplay state 6: second halfword -> assemble enc32 in r0
    lsls r0, r0, #16
    mov  r1, r9
    orrs r0, r1
@ Shared body word path. Stage reply before decrypt+CRC. Sender can clock again ~36us later.
.rx_body_proc:
    adds r2, r7, #4
    lsls r2, r2, #16
    lsrs r2, r2, #16 @ reply = next offset
    movs r4, #5      @ next state: more body, or completion after the last word
    adds r1, r7, #4
    cmp  r1, r8
    bcc  .rx_bp_arm
    movs r4, #7
.rx_bp_arm:
    bl   .rx_reply_now @ preserves r0 (enc32) + r2. Clobbers r1, r3
    ldr  r1, =MB_LCG_MUL
    muls r5, r1
    adds r5, #1        @ m = MB_LCG_MUL*m + 1 (advance BEFORE)
    negs r1, r7
    eors r0, r1
    eors r0, r5
    ldr  r1, [sp, #RXF_MAGIC]
    eors r0, r1        @ -> plaintext
    str  r0, [r7]
    @ Fold CRC incrementally so completion is ready for the 0x65 retries.
    mov  r1, r10
    eors r0, r1
    ldr  r2, [sp, #RXF_POLY]
    bl   .rx_crc32
    mov  r10, r0
    adds r7, #4
    adds r0, r7, #0
    ldr  r1, =RAM_ENTRYPOINT
    subs r0, r1
    mov  r1, r8
    ldr  r2, =RAM_ENTRYPOINT
    subs r1, r2
    bl   mbp_field     @ progress (reply already staged. This rides the sender's gap window)
    cmp  r7, r8
    bcc  .rx_body_more @ reply/state already staged. Wait for the next transfer
    @ Body done: final CRC mix -> r5 for the 0x66 exchange.
    mov r0, r10
    mov r3, r11
    cmp r3, #0
    beq .rx_fin_n32
    ldr r1, =MB_CRC_STASH
    ldr r1, [r1]
    b   .rx_fin_mixed
.rx_fin_n32:                          @ hh = the received broadcast byte (0x11+cc+0xff+0xff, not 0x11+cc)
    ldr  r1, =MB_CRC_STASH
    ldrb r1, [r1]
    ldr  r3, =(0xffff0000 | (RX_RR << 8))
    orrs r1, r3
.rx_fin_mixed:
    eors r0, r1
    ldr  r2, [sp, #RXF_POLY]
    bl   .rx_crc32
    adds r5, r0, #0 @ final CRC (low 16 replied at 0x66)
    @ Patch boot mode [0xc4] and receiver ID [0xc5].
    ldr  r0, =MB_RAM_ENTRY
    mov  r3, r11
    cmp  r3, #0
    bne  .rx_id_mp
    movs r1, #0x02 @ Normal-32: boot mode 02h
    strb r1, [r0, #4]
    movs r1, #0x01 @ lone receiver -> ID 1
    strb r1, [r0, #5]
    b    .rx_id_done
.rx_id_mp:
    movs r1, #0x03       @ Multiplay: boot mode 03h
    strb r1, [r0, #4]
    ldrh r1, [r6, #0x08] @ this receiver's multiplayer ID lives in SIOCNT bits 5:4
    lsrs r1, r1, #4
    movs r3, #3
    ands r1, r3
    strb r1, [r0, #5]
.rx_id_done:
.rx_body_more:
    b .rxn_loop @ reply + next state were staged at .rx_body_proc, before the decrypt
.rx_comp:                             @ state 7, first 0x0065 -> reply 0x0074 (busy), advance to state 9
    @ Completion is 0x0074 busy, then 0x0075 ready, then 0x0066 CRC exchange.
    lsls r1, r0, #24
    lsrs r1, r1, #24
    cmp  r1, #0x66
    beq  .rx_comp_crc
    ldr  r2, =0x00000074 @ busy
    movs r4, #9
    b    .rx_setreply
.rx_comp_ready:                       @ state 9, 0x0065 -> 0x0075 (ready, idempotent). 0x0066 -> CRC exchange
    lsls r1, r0, #24
    lsrs r1, r1, #24
    cmp  r1, #0x66
    beq  .rx_comp_crc
    ldr  r2, =0x00000075 @ ready
    b    .rx_setreply
.rx_comp_crc:                         @ 0x0066: reply our CRC (low 16). The sender verifies it
    adds r2, r5, #0
    lsls r2, r2, #16
    lsrs r2, r2, #16
    movs r4, #8 @ -> state 8: verify the sender's CRC, then boot
    b    .rx_setreply
.rx_done:                             @ state 8: the sender sends its CRC
    @ Boot only if sender CRC equals ours.
    lsls r1, r0, #16
    lsrs r1, r1, #16
    adds r0, r5, #0
    lsls r0, r0, #16
    lsrs r0, r0, #16
    cmp  r1, r0
    bne  .rx_crc_bad
    ldr  r1, =MB_DONE_MARK
    movs r0, #0xb7
    str  r0, [r1]          @ done marker
    bl   mb_boot_linger    @ the retail ~3s post-receive window before entering the image
    ldr  r5, =MB_RAM_ENTRY @ Normal/Multiplay: enter at the RAM entry point (0xc0)
    @ fall into the GBA-link boot handoff
@ Enter Normal/Multiplay image. GBA-link handoff leaves r0=REG_SIO_BASE and r1=SIOCNT.
mb_boot_handoff:
    bl   mbp_finish        @ settle the palette sweep + park DMA3 before entering the image
    mov  lr, r5
    ldr  r0, =REG_IE
    movs r1, #0
    strh r1, [r0]
    ldr  r0, =REG_IME
    strh r1, [r0]
    ldr  r0, =REG_SIO_BASE @ r0 = I/O base
    ldrh r1, [r0, #8]      @ r1 = SIOCNT (this receiver's multiplayer ID)
mb_boot_tail:
    ldr  r2, =SYS_STACK
    mov  sp, r2
    movs r2, #0
    movs r3, #0
    movs r4, #0
    movs r5, #0
    movs r6, #0
    movs r7, #0
    mov  r8, r7
    mov  r9, r7
    mov  r10, r7
    mov  r11, r7
    mov  r12, r7
    bx   lr
.rx_crc_bad:                          @ CRC mismatch: drop image and restart transport detect
    ldr r0, =multiboot_receiver_listen + 1
    bx  r0
.rx_setreply:
    bl .rx_reply_now
    b  .rxn_loop
@ Stage r2 as NEXT reply; Normal-32 also arms Start. r2 = reply value.
@ Preserves r0, r2, r4-r11; clobbers r1, r3.
.rx_reply_now:
    mov  r3, r11
    cmp  r3, #0
    beq  .rx_rn_norm32
    strh r2, [r6, #0x0a] @ Multiplay: SIOMLT_SEND = reply for the next transfer
    bx   lr
.rx_rn_norm32:
    @ Normal-32: high 16 = reply, low 16 = sender echo.
    lsls r3, r2, #16
    mov  r1, r9
    lsls r1, r1, #16
    lsrs r1, r1, #16     @ echo = low 16 of the sender's last word
    orrs r3, r1
    str  r3, [r6, #0x00] @ SIODATA32 = (reply << 16) | echo
    ldr  r1, =0x00005080 @ arm only after reply is loaded
    strh r1, [r6, #0x08]
    bx   lr

@ Fold SIOMULTI1/2/3 low bytes into r3 bits 8/16/24. Absent receiver -> 0xff.
rx_pack3:
    ldrh r1, [r6, #0x02] @ SIOMULTI1
    lsls r1, r1, #24
    lsrs r1, r1, #16
    orrs r3, r1
    ldrh r1, [r6, #0x04] @ SIOMULTI2
    lsls r1, r1, #24
    lsrs r1, r1, #8
    orrs r3, r1
    ldrh r1, [r6, #0x06] @ SIOMULTI3
    lsls r1, r1, #24
    orrs r3, r1
    bx   lr

@ CRC-16 fold, 32 bits. in: r0 = crc ^ word, r2 = poly. out: r0 = crc. Clobbers r1.
.rx_crc32:
    movs r1, #32
.rx_crc32_bit:
    lsrs r0, r0, #1
    bcc  .rx_crc32_no
    eors r0, r2
.rx_crc32_no:
    subs r1, #1
    bne  .rx_crc32_bit
    bx   lr

    .ltorg

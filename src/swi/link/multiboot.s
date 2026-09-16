@ SPDX-License-Identifier: LGPL-3.0-or-later
@ MultiBoot (SWI 0x25): the GBA to GBA link cable sender.
@ The receiver side lives in boot/multiboot_receiver.s.
.thumb

@ Inter-transfer pacing gap, in countdown iterations: 160 iters of the 4-cycle subs/bne = ~38us,
@ GBATEK's "wait Start-clear + 36us" sender rule.
.equ MB_XFER_GAP, 160

@ MultiBoot (SWI 0x25), sender.
@
@ Entry:  r0 = MultiBootParam*, r1 = mode (0=Normal 256KHz, 1=Multiplay 115KHz, 2=Normal 2MHz)
@ Return: r0 = 0 (ok) / 1 (fail: invalid mode, completion timeout, or CRC mismatch); r4-r7
@ saved/restored, r2/r11/r12 dispatcher-restored.
@
@ The game handles receiver recognition, the 0xc0-byte header, palette exchange, and handshake.
@ The SWI sends the length word and encrypted body, then completes the 0x65/0x66 CRC exchange.
@ The CRC folds all receivers' length replies, so multi receiver downloads work.
@
@ All three modes share one code path. A 4-word stack frame holds the transport, XOR magic,
@ parameter pointer, and receivers' length replies. The first two select the transfer mode:
@   * transport ([sp] = SIOCNT-start): Normal 0/2 = one 32-bit SIODATA32 transfer (0x1081/0x1083),
@     Multiplay 1 = 16-bit transfers (0x2083), a body word going out as two halfwords with the
@     receiver reply read from SIOMULTI1. Normal vs Multiplay is taken from SIOCNT-start bit13.
@   * XOR magic ([sp+4]): MB_MAGIC_NORMAL / MB_MAGIC_MULTI.
@ The cipher does not depend on the transfer mode: seed m = palette | receiver_data<<8..<<24. Per body word at
@ receiver offset 0xc0+, m = MB_LCG_MUL*m + 1 first, then enc = plain ^ -(0x02000000+off) ^ m ^
@ magic (m advances BEFORE each word, the opposite order to JoyBoot's per word key).
@
@ Body registers: r4 = src, r5 = m (LCG state), r6 = receiver dest addr (for the -(addr) term),
@ r7 = remaining word count.
swi_MultiBoot:
    push {r4, r5, r6, r7, lr}
    mov  r3, r10
    push {r3}
    @ 4-word stack frame [sp]=SIOCNT-start, [sp+4]=magic, [sp+8]=param, [sp+12]=rr. Push param + rr-slot
    @ FIRST so they land at +8/+12 once the start/magic pair goes on top.
    movs r2, #0
    push {r0, r2}
    @ Save caller IME (r12, restored at .mb_return). The transfer runs with IRQs masked: a
    @ mid transfer IRQ would desync the cipher LCG and corrupt every later word.
    ldr  r2, =REG_IME
    ldrh r2, [r2]
    mov  r12, r2
    @ pick per-mode SIOCNT-start (r2) + XOR magic (r3). Default = Normal 256KHz
    ldr r2, =0x00001081
    ldr r3, =MB_MAGIC_NORMAL
    cmp r1, #0
    beq .mb_params_done
    cmp r1, #2
    beq .mb_params_2m
    cmp r1, #1
    beq .mb_params_multi
    @ invalid mode: still complete the 4-word frame so the shared return tail's `add sp` balances, then fail
    push {r2, r3}
    movs r0, #1
    b    .mb_return
.mb_params_2m:
    adds r2, #2
    b    .mb_params_done
.mb_params_multi:
    ldr r2, =0x00002083
    ldr r3, =MB_MAGIC_MULTI
.mb_params_done:
    push {r2, r3}
    ldr  r3, =0x0000c37b
    mov  r10, r3
    movs r3, #1
    lsls r3, r3, #13
    tst  r2, r3
    beq  .mb_poly_done
    ldr  r3, =0x0000a517
    mov  r10, r3
.mb_poly_done:
    ldr  r4, [r0, #0x20] @ src = boot_srcp
    ldr  r1, [r0, #0x24] @ boot_endp
    subs r7, r1, r4
    lsrs r7, r7, #2      @ r7 = body word count
    @ seed m = palette | cd1<<8 | cd2<<16 | cd3<<24 (an absent receiver's cd reads as 0xff)
    ldrb r5, [r0, #0x1c] @ palette_data
    ldrb r1, [r0, #0x19] @ receiver_data[1]
    lsls r1, r1, #8
    orrs r5, r1
    ldrb r1, [r0, #0x1a] @ receiver_data[2]
    lsls r1, r1, #16
    orrs r5, r1
    ldrb r1, [r0, #0x1b] @ receiver_data[3]
    lsls r1, r1, #24
    orrs r5, r1
    ldr  r1, =REG_SIO_BASE
    movs r0, #0
    strh r0, [r1, #0x14] @ RCNT = 0 (select Normal/Multiplay)
    ldr  r1, =REG_IME
    strh r0, [r1]
    @ --- length word (llll = bodyWordCount - 0x34). Per GBATEK the SWI resumes HERE, after the game did
    @     recognition, the 0xc0-byte header, palette and handshake. ---
    adds r0, r7, #0
    subs r0, #0x34
    lsls r0, r0, #16
    lsrs r0, r0, #16
    bl   mb_xfer @ receiver(s) reply 0x73rr
    @ Build the CRC final-mix tail = rr1 | rr2<<8 | rr3<<16 from the real SIOMULTI2/3 replies
    @ (absent receivers read 0xff), since hardcoding them would mismatch every multi receiver download.
    lsls r0, r0, #24
    lsrs r0, r0, #24
    ldr  r1, [sp, #0]    @ SIOCNT-start bit13 = Multiplay
    movs r2, #1
    lsls r2, r2, #13
    tst  r1, r2
    beq  .mb_rr_normal
    ldr  r1, =REG_SIO_BASE
    ldrh r2, [r1, #0x04] @ SIOMULTI2 (0xffff if absent)
    lsls r2, r2, #24
    lsrs r2, r2, #16
    orrs r0, r2
    ldrh r2, [r1, #0x06] @ SIOMULTI3
    lsls r2, r2, #24
    lsrs r2, r2, #8
    orrs r0, r2
    b    .mb_rr_done
.mb_rr_normal:
    ldr  r1, =0x00ffff00
    orrs r0, r1
.mb_rr_done:
    str r0, [sp, #12]
    @ Init the running CRC (r11, dispatcher-saved) and fold incrementally as each body word sends: a
    @ second pass after the send would insert a gap that grows with the body size before the 0x65 completion,
    @ and a real receiver desyncs on it.
    ldr  r2, [sp, #0]
    movs r3, #1
    lsls r3, r3, #13
    tst  r2, r3
    beq  .mb_crc_seed_n
    ldr  r2, =0x0000fff8
    b    .mb_crc_seed_d
.mb_crc_seed_n:
    ldr r2, =0x0000c387
.mb_crc_seed_d:
    mov r11, r2
    @ --- encrypted main-program transfer ---
    ldr r6, =MB_RAM_ENTRY @ receiver dest (offset 0xc0)
.mb_body:
    cmp  r7, #0
    beq  .mb_body_done
    ldr  r1, =MB_LCG_MUL @ m = MB_LCG_MUL*m + 1 (advance BEFORE the word)
    muls r5, r1
    adds r5, #1
    ldr  r0, [r4]
    @ fold the plaintext word into r11 before encrypting (poly per mode). Preserves r0
    mov  r2, r11
    eors r2, r0
    mov  r1, r10
    bl   mb_crcfold
    mov  r11, r2
    negs r1, r6
    eors r0, r1 @ ^ -(0x02000000 + off)
    eors r0, r5 @ ^ m
    ldr  r1, [sp, #4]
    eors r0, r1 @ r0 = ciphertext
    ldr  r1, [sp, #0]
    movs r2, #1
    lsls r2, r2, #13
    tst  r1, r2
    beq  .mb_body_normal
    @ Multiplay: send ciphertext as two 16-bit halfwords (low, then high), each its own transfer
    @ with the same 36us reply-staging gap mb_xfer grants.
    ldr  r3, =REG_SIO_BASE
    bl   mb_send_h
    lsrs r0, r0, #16
    bl   mb_send_h
    b    .mb_body_adv
.mb_body_normal:
    bl mb_xfer
.mb_body_adv:
    adds r4, #4
    adds r6, #4
    subs r7, #1
    b    .mb_body
.mb_body_done:
    @ ===== 0x65/0x66 completion handshake (CRC already folded into r11) =====
    mov r5, r11
    @ final mix: one CRC round over dword(hh, rr1, rr2, rr3), hh = handshake_data, rrN = receiver N's
    @ length reply ([sp+12], captured at the length transfer)
    ldr  r0, [sp, #8]
    ldrb r0, [r0, #0x14] @ hh = handshake_data
    ldr  r1, [sp, #12]
    lsls r1, r1, #8
    orrs r0, r1
    adds r2, r5, #0
    eors r2, r0
    mov  r1, r10
    bl   mb_crcfold
    adds r5, r2, #0
    @ completion: send 0x0065 until the receiver replies ..0x75, then 0x0066, then exchange the CRC.
    @ The retry budget must cover the RECEIVER's CRC compute: a retail receiver CRCs the whole body
    @ only now, replying 0x74 "busy" throughout (~9ms/KB on real hardware, so ~2.4s at the 256KB
    @ maximum). At ~170us per poll, 0x8000 retries = ~5.5s.
    ldr r7, =0x00008000
.mb_comp_wait:
    movs r0, #0x65
    bl   mb_xfer
    lsls r1, r0, #24
    lsrs r1, r1, #24
    cmp  r1, #0x75
    bne  .mb_comp_retry
    @ Multiplay: every client_bit-declared receiver must reply ready before 0x66.
    ldr  r1, [sp, #0]
    movs r2, #1
    lsls r2, r2, #13
    tst  r1, r2
    beq  .mb_comp_crc
    ldr  r1, [sp, #8]
    ldrb r1, [r1, #0x1e]
    ldr  r3, =REG_SIO_BASE
    movs r2, #0x04
    tst  r1, r2
    beq  .mb_cw_r3
    ldrh r2, [r3, #0x04]
    cmp  r2, #0x75
    bne  .mb_comp_retry
.mb_cw_r3:
    movs r2, #0x08
    tst  r1, r2
    beq  .mb_comp_crc
    ldrh r2, [r3, #0x06]
    cmp  r2, #0x75
    beq  .mb_comp_crc
.mb_comp_retry:
    subs r7, #1
    bne  .mb_comp_wait
    movs r0, #1
    b    .mb_return
.mb_comp_crc:
    movs r0, #0x66
    bl   mb_xfer
    adds r0, r5, #0
    bl   mb_xfer @ send our CRC. The transfer returns each receiver's CRC reply
    @ Every present receiver must echo our CRC. A mismatch is a corrupted transfer -> fail (caller retries).
    @ Absent Multiplay slots read 0xffff and are skipped. r2 = our CRC low 16.
    lsls r2, r5, #16
    lsrs r2, r2, #16
    lsls r0, r0, #16
    lsrs r0, r0, #16
    cmp  r0, r2
    bne  .mb_comp_fail
    ldr  r1, [sp, #0]
    movs r3, #1
    lsls r3, r3, #13
    tst  r1, r3
    beq  .mb_comp_ok
    @ Verify each client_bit-declared receiver's CRC echo (no 0xffff = absent shortcut).
    ldr  r1, [sp, #8]
    ldrb r1, [r1, #0x1e] @ client_bit
    ldr  r3, =REG_SIO_BASE
    movs r0, #0x04
    tst  r1, r0
    beq  .mb_comp_c3
    ldrh r0, [r3, #0x04] @ SIOMULTI2
    cmp  r0, r2
    bne  .mb_comp_fail
.mb_comp_c3:                 @ r3 still = REG_SIO_BASE on both paths here (set above), no reload
    movs r0, #0x08
    tst  r1, r0
    beq  .mb_comp_ok
    ldrh r0, [r3, #0x06] @ SIOMULTI3
    cmp  r0, r2
    bne  .mb_comp_fail
.mb_comp_ok:
    movs r0, #0
    b    .mb_return
.mb_comp_fail:
    movs r0, #1
.mb_return:
    @ restore caller IME (r12), keeping r0. All paths reach here with r12 set in the prologue, so the
    @ invalid-mode path is a no-op.
    ldr  r1, =REG_IME
    mov  r2, r12
    strh r2, [r1]
    @ Return to the ARM dispatcher via bx, not `pop {pc}`: pop-pc does NOT interwork on ARMv4T. lr was
    @ clobbered by the bl mb_xfer calls, so the stacked copy is the real return. First drop the 4-word frame.
    add sp, #16
    pop {r3}
    mov r10, r3
    pop {r4, r5, r6, r7}
    pop {r3}
    bx  r3

@ Readiness spin bound (~3ms, >>80x the 36us rule). A healthy receiver passes instantly. On timeout,
@ send anyway and let the protocol's own checkpoints fail the transfer: a per word bound keeps a
@ yanked cable worst case finite instead of hanging the SWI.
.equ MB_READY_SPIN, 0x2000

@ Mode-aware single transfer: r0 = out, returns r0 = reply. Clobbers r1-r3 (the caller's r4-r7
@ survive). Every transfer is preceded by the 36us pacing gap (GBATEK's sender rule: the receiver
@ stages its reply in that window. A wire capture of a real sender shows exactly this cadence, and
@ sending with no gap outruns a real receiver and corrupts the transfer) and a bounded readiness
@ check (Multiplay SD = all units in-mode, Normal SI low = receiver ready).
@   Normal    (start bit13 = 0): 32-bit SIODATA32 transfer. reply = SIODATA32.
@   Multiplay (start bit13 = 1): 16-bit transfer via SIOMLT_SEND. reply = SIOMULTI1.
mb_xfer:
    ldr  r3, =REG_SIO_BASE
    ldr  r2, [sp, #0] @ SIOCNT-start
    movs r1, #MB_XFER_GAP
.mb_xfer_gap:
    subs r1, #1
    bne  .mb_xfer_gap
    push {r4}
    ldr  r1, =MB_READY_SPIN
    movs r4, #1
    lsls r4, r4, #13
    tst  r2, r4
    beq  .mb_xfer_rdyn
.mb_xfer_rdym:
    ldrh r4, [r3, #8]
    lsrs r4, r4, #4 @ SD (bit3) -> carry: 1 = all GBAs ready
    bcs  .mb_xfer_ready
    subs r1, #1
    bne  .mb_xfer_rdym
    b    .mb_xfer_ready
.mb_xfer_rdyn:
    ldrh r4, [r3, #8]
    lsrs r4, r4, #3 @ SI (bit2) -> carry: 0 = receiver's SO low = ready
    bcc  .mb_xfer_ready
    subs r1, #1
    bne  .mb_xfer_rdyn
.mb_xfer_ready:
    pop  {r4}
    movs r1, #1
    lsls r1, r1, #13
    tst  r2, r1
    bne  .mb_xfer_multi
@ Normal 32-bit
    str  r0, [r3, #0]
    strh r2, [r3, #8]
.mb_xfer_nw:
    ldrh r1, [r3, #8]
    lsls r1, r1, #24
    bmi  .mb_xfer_nw
    ldr  r0, [r3, #0]
    lsrs r0, r0, #16 @ Normal-32: receiver reply is in the high 16 (low 16 echoes our cmd). Return
    bx   lr          @ it in the low 16 so every caller reads it like Multiplay
@ Multiplay 16-bit
.mb_xfer_multi:
    strh r0, [r3, #0x0a]
    strh r2, [r3, #8]
.mb_xfer_mw:
    ldrh r1, [r3, #8]
    lsls r1, r1, #24
    bmi  .mb_xfer_mw
    ldrh r0, [r3, #2] @ SIOMULTI1 (receiver 1 reply)
    bx   lr
mb_send_h:
    movs r2, #MB_XFER_GAP
.msh_gap:
    subs r2, #1
    bne  .msh_gap
    strh r0, [r3, #0x0a]
    strh r1, [r3, #8]
.msh_wait:
    ldrh r2, [r3, #8]
    lsls r2, r2, #24
    bmi  .msh_wait
    bx   lr

@ MultiBoot CRC-16 fold (GBATEK): r2 = crc ^ word, r1 = poly. Returns r2 folded, clobbers r3.
mb_crcfold:
    movs r3, #32
.mb_cf_bit:
    lsrs r2, r2, #1
    bcc  .mb_cf_no
    eors r2, r1
.mb_cf_no:
    subs r3, #1
    bne  .mb_cf_bit
    bx   lr

    .ltorg

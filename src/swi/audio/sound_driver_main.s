@ SPDX-License-Identifier: GPL-3.0-or-later
@ SoundDriverMain (SWI 0x1c): mix one frame of DirectSound PCM for the active SoundInfo.
@
@ Entry:  none (SoundInfo from [SOUND_INFO_PTR])
@ Return: r4-r12 preserved. An ident mismatch (word != SOUND_IDENT) returns immediately with
@ r1 untouched and r3 = the word loaded from [SI].
@
@ The game's M4A sound engine in ROM owns sequencing, the track command parser, and channel
@ allocation. This renders the actual audio. The mixer iterates maxChans (SoundInfo+0x06,
@ default 8) channel structs at SoundInfo+0x50, stride 0x40.
@
@ Each frame writes pcmSamplesPerVBlank (psv) bytes into a slice of the two FIFO
@ work buffers (A/right at +0x350, B/left at +0x980, 0x630 bytes apart). The slice
@ is picked from pcmDmaCounter and cleared to silence before any channel mixes:
@
@   chunk  = pcmDmaCounter == 0
@          ? 0
@          : (pcmDmaPeriod + 1 - pcmDmaCounter) mod pcmDmaPeriod
@   offset = chunk * psv
@   right  = SoundInfo + 0x350 + offset
@   left   = SoundInfo + 0x980 + offset
@
@ For each active channel (status != 0) advance the ADSR envelope, then resample
@ WaveData->data with linear interpolation, scale by the per-side envelope volume
@   envR/envL = (((vol * (mainVolume+1)) >> 4) * envVol) >> 8
@ and accumulate into the slice with a wrapping 8-bit add (add then strb).
@
@ Mixer byproducts are the contract with the M4A engine. Keep the writebacks for
@ cp(+0x28), E(+0x1c), ct(+0x18), envR(+0x0a), and envL(+0x0b).
@
@ SoundChannel fields used here:
@   status@0x00 (0x80 key-on -> 3 attack -> 2 decay -> 1 sustain, 0x40 release, 0 free)
@   rVol@0x02 lVol@0x03 attack@0x04 decay@0x05 sustain@0x06 release@0x07 envVol@0x09
@   ct@0x18 E/fw@0x1c freq@0x20 wav@0x24 cp@0x28
@ WaveData fields: status@0x02 loopStart@0x08 size@0x0c data@0x10
.thumb
    .set MAIN_CLEAR_PAD,   6
    .set MIXF_ADV_PAD,     0
    .set MIXC_ADV_PAD,     9
    .set MIXC_M3_PAD,      0
    .set CS_TAIL_PAD,      11
    .set CSN_PAD,          2
    .set WB_PAD,           0
    .set MC_STOP_PAD,      4
    .set CSL_PAD,          1
    .set CSML_PAD,         0
    .set MCLW_PAD,         0
    .set WBL_PAD,          0
    .set MIXC_RD_PAD,      6
    .set ENV_START_PAD,    0
    .set EA_ATK_PAD,       4
    .set CHAN_FREE_PAD,    0
    .set NEXT_CHAN_PAD,    0
    .set MIXC_EXTRA_PAD,   0
.set MIXC_ITER_PAD,        3
    .set MIXC_OUT_PAD,     0
    .set MIXC_NADV_PAD,    1
    .set CHAN_SETUP_PAD,   6
    .set ASCAN_PAD,        13
    .set MAIN_VALID_PAD,   0
    .set ENV_PAD,          0
    .set MAIN_CHUNK_PAD,   1
    .set ACLR_PAD,         6
    .set AT8_PAD,          0
    .set ABASE_PAD,        0
    .set ADONE_PAD,        0
    .set MAIN_BASE_PAD,    0
    .set MAIN_ENTRY_PAD_A, 1
    .set MAIN_ENTRY_PAD_B, 5
    .set MAIN_HOOK_PAD,    5
    .set CLEAR_Z_PAD,      1
    .set CLEAR_T8_PAD,     1
    .set RVB_HEAD_PAD,     0
    .set RVB_CHUNK_PAD,    0
    .set RVB_ITER_PAD,     0
    .set RVB_TAIL_PAD,     0
    .set FX_HEAD_PAD,      0
    .set FX_CONT_PAD,      0
    .set FX_ITER_PAD,      0
    .set FX_TAIL_PAD,      0
    .set FX_LAST_PAD,      0
    .set FXS_PAD,          4
@ ARM from entry.
.align 2
.arm
swi_SoundDriverMain:
    guard_pad MAIN_ENTRY_PAD_A
    ldr       r0, =SOUND_INFO_PTR
    ldr       r0, [r0]
    ldr       r3, [r0]
    ldr       r2, =SOUND_IDENT
    cmp       r3, r2
    bxne      lr
    guard_pad MAIN_ENTRY_PAD_B
    stmdb     sp!, {r4, r5, r6, r7}
    sub       sp, sp, #0x40
    str       r8, [sp, #0x2c]
    str       r9, [sp, #0x1c]
    str       r10, [sp, #0x30]
    str       lr, [sp, #0x0c]
    @ Re-entrancy lock: ident+1 while the driver runs
    add       r2, r2, #1
    str       r2, [r0]
    mov       r5, r0
    str       r0, [sp, #0x3c]
    ldr       r3, [r0, #0x20]
    ldr       r0, [r0, #0x24]
    cmp       r3, #0
    movne     lr, pc
    bxne      r3
    guard_pad MAIN_HOOK_PAD
    ldr       r3, [r5, #0x28]
    mov       r0, r5
    mov       lr, pc
    bx        r3
.main_valid_arm_fall:
.main_valid_arm:
    guard_pad MAIN_VALID_PAD
    ldrh      r3, [r5, #0x04]
    subs      r0, r3, #1
    bhi       .mv_slow
    mov       r0, #0
    guard_pad 2
    b         .mv_hc
.mv_slow_chunk:
    ldrb      r4, [r5, #0x0b]
    subs      r0, r4, r0
    sublo     r0, r0, r4
    guard_pad MAIN_CHUNK_PAD
.mv_hc:
    ldr r6, [r5, #0x10]
    str r6, [sp, #0x08]
    mul r1, r6, r0
    add r1, r1, r5
    add r1, r1, #0x350
    str r1, [sp, #0x00]
    add r2, r1, #0x630
    str r2, [sp, #0x04]
    mov r4, r6, lsr #4
    mov r3, #0
    mov r0, #0
    mov r7, #0
    mov r8, #0
.mv_clear:
    stmia     r1!, {r0, r3, r7, r8}
    stmia     r2!, {r0, r3, r7, r8}
    guard_pad ACLR_PAD
    subs      r4, r4, #1
    bgt       .mv_clear
    movs      r4, r6, lsl #28
    beq       .mv_cleared
    str       r3, [r1]
    str       r3, [r2]
    bpl       .mv_cleared
    str       r3, [r1, #4]
    str       r3, [r2, #4]
    guard_pad AT8_PAD
.mv_cleared:
    guard_pad ABASE_PAD
    ldr       r11, [r5, #0x18]
    ldr       r12, [r5, #0x14]
    ldrb      r1, [r5, #0x07]
    add       r1, r1, #1
    str       r1, [sp, #0x10]
    add       r7, r5, #0x50
    str       r7, [sp, #0x14]
    ldrb      r6, [r5, #0x06]
.ascan:
    ldrb      r0, [r7, #0x00]
    cmp       r0, #0
    bne       .ascan_act
    guard_pad ASCAN_PAD
    add       r7, r7, #0x40
    subs      r6, r6, #1
    bgt       .ascan
    b         .main_done_arm
.ascan_act:
    str r7, [sp, #0x14]
    str r6, [sp, #0x18]
    @ ADSR envelope FSM. status bits: 0x80 start, 0x40 stop/release, 0x10 loop marker,
    @ low 2 = phase (3 attack, 2 decay, 1 sustain).
    guard_pad ENV_PAD
    tst       r0, #0x80
    bne       .ea_start
    ldrb      r1, [r7, #0x09]
    tst       r0, #0x40
    bne       .ea_release
    and       r2, r0, #3
    cmp       r2, #2
    blo       .ea_sustain
    beq       .ea_decay
.ea_attack:
    ldrb      r2, [r7, #0x04]
    add       r1, r1, r2
    cmp       r1, #0xff
    movhs     r1, #0xff
    subhs     r0, r0, #1
    mulhs     r2, r1, r12
    guard_pad EA_ATK_PAD
    b         .ea_wb
.ea_start:
    ldr       r2, [r7, #0x24]
    add       r2, r2, #0x10
    str       r2, [r7, #0x28]
    tst       r0, #0x40
    bne       .fx_kill
    ldr       r1, [r2, #-4]
    str       r1, [r7, #0x18]
    ldrb      r1, [r7, #0x04]
    cmp       r1, #0xff
    movshs    r0, #2
    movslo    r0, #3
    mulhs     r3, r1, r12
    ldrb      r3, [r7, #0x01]
    eors      r3, r3, #0x08
    beq       .fx_stub
    ldrh      r3, [r2, #-14]
    ands      r3, r3, #0x4000
    beq       .ea_join
    orr       r0, r0, #0x10
    eors      r3, r3, #0x4000
    guard_pad 5
.ea_join:
    strb r0, [r7, #0x00]
    strb r1, [r7, #0x09]
    str  r3, [r7, #0x1c]
    b    .cs_envcalc
.fx_stub:
    ldrh      r3, [r2, #-14]
    tst       r3, #0x4000
    orrne     r0, r0, #0x10
    mov       r3, #0
    teq       r3, #1
    guard_pad FXS_PAD
    b         .ea_join
.ea_decay:
    ldrb      r2, [r7, #0x05]
    mul       r3, r1, r2
    mov       r1, r3, lsr #8
    ldrb      r2, [r7, #0x06]
    cmp       r1, r2
    bhi       .ea_wbv
    mov       r1, r2
    sub       r0, r0, #1
    guard_pad 1
    b         .ea_wb
.ea_sustain:
    ldrb r1, [r7, #0x06]
    b    .ea_wbv
.ea_release:
    guard_pad 1
    ldrb      r2, [r7, #0x07]
    mul       r3, r1, r2
    movs      r1, r3, lsr #8
    bne       .ea_wbv
    mov       r0, #0
    strb      r0, [r7, #0x00]
    b         .chan_free_arm
.ea_wb:
    strb r0, [r7, #0x00]
.ea_wbv:
    strb r1, [r7, #0x09]
    b    .chan_setup_arm
.align 2
.ltorg
.align 2
.arm
.main_done_arm:
    guard_pad ADONE_PAD
    ldr       r3, [sp, #0x3c]
    ldr       r2, =SOUND_IDENT
    str       r2, [r3]
    ldr       lr, [sp, #0x0c]
    ldr       r8, [sp, #0x2c]
    ldr       r9, [sp, #0x1c]
    ldr       r10, [sp, #0x30]
    add       sp, sp, #0x40
    ldmia     sp!, {r4, r5, r6, r7}
    bx        lr
.mv_slow:
    movs      r12, r3, lsr #8
    beq       .mv_slow_chunk
    ands      r0, r3, #0xfe
    beq       .mv_rvb_head
    and       r0, r3, #0xff
    sub       r0, r0, #1
    ldrb      r4, [r5, #0x0b]
    sub       r0, r4, r0
    cmp       r0, r4
    subhs     r0, r0, r4
    guard_pad RVB_CHUNK_PAD
.mv_rvb_head:
    ldr       r6, [r5, #0x10]
    str       r6, [sp, #0x08]
    mul       r1, r6, r0
    add       r1, r1, r5
    add       r1, r1, #0x350
    str       r1, [sp, #0x00]
    add       r2, r1, #0x630
    add       r8, r1, r6
    add       r9, r5, #0x980
    cmp       r8, r9
    subhs     r8, r8, #0x630
    add       r9, r8, #0x630
    guard_pad RVB_HEAD_PAD
.mv_rvloop:
    ldrsb     r4, [r1]
    ldrsb     r7, [r2]
    add       r4, r4, r7
    ldrsb     r7, [r8], #1
    add       r4, r4, r7
    ldrsb     r7, [r9], #1
    add       r4, r4, r7
    mul       r7, r4, r12
    mov       r4, r7, asr #31
    add       r7, r7, r4, lsr #23
    mov       r7, r7, asr #9
    guard_pad RVB_ITER_PAD
    strb      r7, [r1], #1
    strb      r7, [r2], #1
    subs      r6, r6, #1
    bne       .mv_rvloop
    guard_pad RVB_TAIL_PAD
    b         .mv_cleared
.cs_fixed:
    strb      r9, [r7, #0x0a]
    strb      lr, [r7, #0x0b]
    ldr       r4, [r7, #0x18]
    ldr       r1, [r7, #0x28]
    ldr       r0, [sp, #0x00]
    ldr       r5, [sp, #0x08]
    mov       r6, #0x630
    sub       r6, r6, #1
    ldrb      r2, [r7]
    tst       r2, #0x10
    bne       .fx_looping
    cmp       r4, r5
    mul       r2, r7, r7
    b         .+4
    nop
    bls       .fx_last
    sub       r4, r4, r5
    str       r4, [r7, #0x18]
    add       r4, r1, r5
    str       r4, [r7, #0x28]
    guard_pad 3
.fx_loop:
    ldrsb     r3, [r1], #1
    mul       r2, r3, r9
    ldrb      r8, [r0]
    add       r2, r8, r2, asr #8
    strb      r2, [r0], #1
    mul       r2, r3, lr
    ldrb      r8, [r0, r6]
    add       r2, r8, r2, asr #8
    strb      r2, [r0, r6]
    guard_pad 4
    subs      r5, r5, #1
    bgt       .fx_loop
.fx_exit:
    guard_pad FX_TAIL_PAD
    b         .next_chan_arm
.fx_last:
    movs r5, r4
    mov  r4, #0
    strb r4, [r7, #0x00]
    bne  .fx_loop
    b    .fx_exit
.fx_looping:
    cmp r4, #0
    bne .fx_looping_sample
    ldr r2, [r7, #0x24]
    ldr r3, [r2, #8]
    ldr r4, [r2, #12]
    sub r4, r4, r3
    add r1, r2, #16
    add r1, r1, r3
.fx_looping_sample:
    ldrsb r3, [r1], #1
    mul   r2, r3, r9
    ldrb  r8, [r0]
    add   r2, r8, r2, asr #8
    strb  r2, [r0], #1
    mul   r2, r3, lr
    ldrb  r8, [r0, r6]
    add   r2, r8, r2, asr #8
    strb  r2, [r0, r6]
    sub   r4, r4, #1
    subs  r5, r5, #1
    bgt   .fx_looping
    str   r4, [r7, #0x18]
    str   r1, [r7, #0x28]
    b     .fx_exit
.fx_kill:
    mov r4, #0
    b   .fx_last
.ltorg
.chan_setup_arm:
    guard_pad CHAN_SETUP_PAD
    ldrb      r2, [r7, #0x01]
    tst       r2, #0x08
.cs_envcalc:
    ldr       r2, [sp, #0x10]
    ldrb      r3, [r7, #0x02]
    mul       r4, r3, r2
    mov       r4, r4, lsr #4
    mul       r3, r4, r1
    mov       r9, r3, lsr #8
    ldrb      r3, [r7, #0x03]
    mul       r4, r3, r2
    mov       r4, r4, lsr #4
    mul       r3, r4, r1
    mov       lr, r3, lsr #8
    bne       .cs_fixed
    ldrb      r3, [r7, #0x00]
    ldr       r1, [r7, #0x28]
    ldr       r10, [r7, #0x18]
    tst       r3, #0x10
    bne       .cs_mk
    mov       r3, #0
    str       r3, [sp, #0x34]
    guard_pad CSML_PAD
    b         .cs_common
.cs_mk:
    ldr       r2, [r7, #0x24]
    ldr       r3, [r2, #0x08]
    add       r4, r2, r3
    str       r4, [sp, #0x38]
    ldr       r4, [r2, #0x0c]
    sub       r4, r4, r3
    str       r4, [sp, #0x34]
    guard_pad CSL_PAD
.cs_common:
    ldr r8, [r7, #0x20]
    ldr r0, [sp, #0x00]
    mov r6, #0x630
    sub r6, r6, #1
    ldr r5, [sp, #0x08]
    ldr r2, [r7, #0x1c]
    cmp r2, r12
    blo .cs_go
1:  sub   r2, r2, r12
    add       r1, r1, #1
    subs      r10, r10, #1
    ble       .mc_wrap
    cmp       r2, r12
    bhs       1b
    guard_pad CSN_PAD
.cs_go:
    mov r3, #(CS_TAIL_PAD + 1) / 4
7803:
    subs r3, r3, #1
    bgt  7803b
    .rept (CS_TAIL_PAD + 1) % 4
    nop
    .endr
.mix_careful_arm:
    cmp       r2, r12
    bhs       .mc_adv
    guard_pad MIXC_NADV_PAD
.mc_do:
    guard_pad MIXC_OUT_PAD
    ldrsb     r4, [r1, #1]
    ldrsb     r3, [r1]
    sub       r4, r4, r3
    mul       r7, r11, r2
    mul       r4, r7, r4
    add       r3, r3, r4, asr #23
    mul       r4, r3, r9
    mul       r3, r3, lr
    ldrb      r7, [r0]
    add       r4, r7, r4, asr #8
    strb      r4, [r0], #1
    ldrb      r7, [r0, r6]
    add       r3, r7, r3, asr #8
    strb      r3, [r0, r6]
    add       r2, r2, r8
    subs      r5, r5, #1
    bgt       .mix_careful_arm
.mix_writeback_arm:
    ldr       r3, [sp, #0x14]
    str       r2, [r3, #0x1c]
    str       r10, [r3, #0x18]
    str       r1, [r3, #0x28]
    strb      r9, [r3, #0x0a]
    strb      lr, [r3, #0x0b]
    guard_pad WB_PAD
    b         .next_chan_arm
.chan_free_arm:
    guard_pad CHAN_FREE_PAD
    b         .next_chan_core
.next_chan_arm:
    guard_pad NEXT_CHAN_PAD
.next_chan_core:
    ldr  r7, [sp, #0x14]
    add  r7, r7, #0x40
    str  r7, [sp, #0x14]
    ldr  r6, [sp, #0x18]
    subs r6, r6, #1
    str  r6, [sp, #0x18]
    bgt  .ascan
    b    .main_done_arm
.mc_adv:
    cmp       r2, r12, lsl #1
    bhs       .mc_multi
    sub       r2, r2, r12
    add       r1, r1, #1
    subs      r10, r10, #1
    beq       .mc_wrap
    guard_pad MIXC_ADV_PAD
    b         .mc_do
.mc_multi:
    sub  r2, r2, r12, lsl #1
    add  r1, r1, #2
    subs r10, r10, #2
    ble  .mc_wrap
    cmp  r2, r12
    bhs  .mc_m3
    mov  r4, r4, lsr r6
    b    .mc_do
.mc_m3:
    sub       r2, r2, r12
    add       r1, r1, #1
    subs      r10, r10, #1
    ble       .mc_wrap
    cmp       r2, r12
    bhs       .mc_m3
    guard_pad MIXC_M3_PAD
    b         .mc_do
.mc_wrap:
    ldr       r4, [sp, #0x34]
    cmp       r4, #0
    bne       .mc_loopwrap
    ldr       r3, [sp, #0x14]
    mov       r4, #0
    strb      r4, [r3, #0x00]
    strb      r9, [r3, #0x0a]
    strb      lr, [r3, #0x0b]
    guard_pad MC_STOP_PAD
    b         .next_chan_arm
.mc_loopwrap:
    ldr r1, [sp, #0x38]
    @ Preserve overshoot across short loops.
.mc_loop_normalize:
    add       r10, r10, r4
    cmp       r10, #0
    ble       .mc_loop_normalize
    add       r1, r1, r4
    sub       r1, r1, r10
    add       r1, r1, #0x10
    guard_pad MCLW_PAD
    cmp       r2, r12
    bhs       .mc_adv
    b         .mc_do
.ltorg
.thumb
    .ltorg

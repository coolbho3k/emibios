@ SPDX-License-Identifier: LGPL-3.0-or-later

@ ARM7TDMI-S CPU definitions
.equ MODE_IRQ,    0x12
.equ MODE_SVC,    0x13
.equ MODE_SYS,    0x1f
.equ IRQ_DISABLE, 0x80
.equ FIQ_DISABLE, 0x40
.equ BIT31,       0x80000000

@ GBA related definitions
.equ BIOS_SIZE,      0x4000
.equ ROM_ENTRYPOINT, 0x08000000
.equ RAM_ENTRYPOINT, 0x02000000
.equ IWRAM_START,    0x03000000
.equ MB_RAM_ENTRY,   (RAM_ENTRYPOINT + 0xc0)
.equ SVC_STACK,      0x03007fe0
.equ IRQ_STACK,      0x03007fa0
.equ SYS_STACK,      0x03007f00

@ BIOS user IRQ vector.
.equ USER_IRQ_VECTOR,        0x03007ffc
.equ USER_IRQ_VECTOR_MIRROR, 0x03fffffc

.equ MMIO_BASE, 0x04000000

.equ REG_DISPSTAT, 0x04000004
.equ REG_VCOUNT,   0x04000006
.equ REG_BG0CNT,   0x04000008
.equ REG_BG0HOFS,  0x04000010
.equ REG_WINOUT,   0x0400004a

.equ REG_DMA0SAD,   0x040000b0
.equ REG_DMA0CNT_H, 0x040000ba

.equ REG_DMA1SAD,   0x040000bc
.equ REG_DMA1CNT_L, 0x040000c4

.equ REG_DMA3SAD,   0x040000d4
.equ REG_DMA3CNT_H, 0x040000de

.equ REG_SOUNDCNT_L, 0x04000080
.equ REG_SOUNDBIAS,  0x04000088
.equ REG_FIFO_A,     0x040000a0
.equ REG_FIFO_B,     0x040000a4

.equ REG_KEYINPUT,  0x04000130
.equ REG_RCNT,      0x04000134
.equ REG_JOYCNT,    0x04000140
.equ REG_JOY_RECV,  0x04000150
.equ REG_JOY_TRANS, 0x04000154
.equ REG_JOYSTAT,   0x04000158

.equ REG_SIO_BASE, 0x04000120
.equ REG_SIOCNT,   0x04000128

.equ REG_TM0CNT_L, 0x04000100

@ Keypad bits (REG_KEYINPUT): 0 = pressed.
.equ KEY_B,      0x0002
.equ KEY_SELECT, 0x0004
.equ KEY_START,  0x0008

@ JoyBus mode select in RCNT (bits 15:14 = 11).
.equ RCNT_JOYBUS,  0xc000
@ REG_JOYCNT flags
.equ JOYCNT_RESET, 0x0001
.equ JOYCNT_RECV,  0x0002
.equ JOYCNT_TRANS, 0x0004
@ REG_JOYSTAT bits
.equ JOYSTAT_RECV, 0x0002
.equ JOYSTAT_SEND, 0x0008
.equ JOYSTAT_PSF0, 0x0010
.equ JOYSTAT_PSF1, 0x0020

.equ REG_IE,      0x04000200
.equ REG_IF,      0x04000202
.equ REG_IME,     0x04000208
.equ REG_POSTFLG, 0x04000300
.equ REG_HALTCNT, 0x04000301

.equ PAL_START,  0x05000000
.equ VRAM_START, 0x06000000

.equ SOUND_INFO_PTR, 0x03007ff0
.equ SOUND_IDENT,    0x68736d53

.equ MB_LCG_MUL,      0x6f646573
.equ MB_MAGIC_NORMAL, 0x43202f2f
.equ MB_MAGIC_MULTI,  0x6465646f

@ Shared decompression / memory-copy source-region guard
.equ SRC_REGION_MASK, 0x0e000000

@ ARM form (immediate mask, 0x0e000000 = 0x0e ROR 8)
.macro decomp_guard_arm srcreg, badlbl, sizereg, tmpreg=lr
    tst \srcreg, #SRC_REGION_MASK
    beq \badlbl
  .ifnb \sizereg
    add \tmpreg, \srcreg, \sizereg
    tst \tmpreg, #SRC_REGION_MASK
    beq \badlbl
  .endif
.endm

@ Thumb form: shift-based
.macro decomp_guard_thumb srcreg, scratch, badlbl, sizereg, tmpreg
    lsls \scratch, \srcreg, #4
    lsrs \scratch, \scratch, #29
    beq  \badlbl
  .ifnb \sizereg
    adds \tmpreg, \srcreg, \sizereg
    lsls \tmpreg, \tmpreg, #4
    lsrs \tmpreg, \tmpreg, #29
    beq  \badlbl
  .endif
.endm

@ Cycle pad when skipped
.macro guard_pad cyc
    .rept (\cyc) / 3
    b .+4
    .endr
    .rept (\cyc) % 3
    nop
    .endr
.endm

@ Thumb form of guard_pad
.macro guard_pad_thumb cyc
    .rept (\cyc) / 3
    b 9f
9:
    .endr
    .rept (\cyc) % 3
    nop
    .endr
.endm

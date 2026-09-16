@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SWI dispatcher.
@
@ Hardware state on SWI entry (ARM7TDMI):
@   * the CPU has switched to Supervisor mode (CPSR.mode=0x13).
@   * set CPSR.I=1 (IRQs masked) and CPSR.T=0 (ARM).
@   * copied the caller's CPSR into SPSR_svc
@   * set r14_svc to the address of the instruction following the SWI, and branched here via the vector
@     at 0x08.
@
@ Requirements for handlers:
@   * handlers run in System mode (so they use the user/system stack and a mid-SWI IRQ banks the right
@     r13/r14), in ARM or Thumb per bit0 of the table entry (entered with `bx`), and return with `bx lr`.
@   * the caller's IRQ/FIQ mask is carried into the handler, so interruptible SWIs (Halt/IntrWait and any
@     long copy/decompress) take IRQs exactly when the caller allowed them.
@   * r2, r4-r11, r12, r13, r14 are preserved across the SWI: the dispatcher itself saves/restores
@     r2, r11, r12, the SPSR and both lr's, so handlers owe only r4-r10 (and sp). r0, r1, r3 carry
@     results and the documented residues; handler values of r2/r11/r12 are visible only to a mid-SWI IRQ.
@ swi_table follows this file directly (entrypoint.s include order) so the ldrh reach is fixed
@ by this file alone: table = exception_swi + 0x54, minus the add's pc+8 leaves 0x44.
.equ SWI_TBL_OFF, 0x44
.arm
.global exception_swi
exception_swi:
    stmfd sp!, {r11, r12, lr}
    @ r12 = SWI number. The number byte sits at lr-2 for both states:
    @   ARM   `swi #(n<<16)`: instr word at lr-4, bits23..16 (=n) at lr-2
    @   Thumb `swi n`:        instr half at lr-2, bits7..0  (=n) at lr-2
    @ The number is not range checked.
    ldrb  r12, [lr, #-2]
    add   r11, pc, r12, lsl #1
    ldrh  r12, [r11, #SWI_TBL_OFF]
    mrs   r11, spsr
    stmfd sp!, {r11}
    and   r11, r11, #(IRQ_DISABLE | FIQ_DISABLE)
    orr   r11, r11, #MODE_SYS
    @ enter System mode with the caller's IRQ mask. r11 is left holding the
    @ mode value (0x1f normal), NOT the swi_table base, so an IRQ taken
    @ mid-SWI captures r11 = mode, not a layout-dependent address.
    msr cpsr_fc, r11
    @ r2 is saved on the System stack, not the SVC stack, so both the SVC
    @ stack residue and the System stack handler frame keep the incidental
    @ values games read off the stack. These are values the ABI doesn't
    @ document but retail leaves fixed.
    stmfd sp!, {r2, lr}
    mov   lr, pc
    bx    r12
    ldmfd sp!, {r2, lr}
    msr   cpsr_fc, #(MODE_SVC | IRQ_DISABLE | FIQ_DISABLE)
    ldmfd sp!, {r11}
    msr   spsr_fc, r11
    ldmfd sp!, {r11, r12, lr}
    @ Timing note: exit is 1 cyc longer than minimal.
    nop
    movs pc, lr
    @ Bus note: after a SWI returns, code that reads the BIOS region gets the last opcode the BIOS
    @ prefetched. Pin 0xe3a02004 (`mov r2, #4`), as some games may read it.
    .word 0xe3a02004
    .word 0xe3a02004

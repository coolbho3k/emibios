@ SPDX-License-Identifier: GPL-3.0-or-later
@ SWI dispatch table, halfword entries (to save space!) indexed by SWI number 0x00-0x2a. Bit 0 of
@ an entry selects the handler's instruction state (+1 = Thumb).
.arm
.global swi_table
swi_table:
    .hword (swi_SoftReset - bios_base)
    .hword (swi_RegisterRamReset + 1 - bios_base)   @ +1 = Thumb handler
    .hword (swi_Halt - bios_base)
    .hword (swi_Stop - bios_base)
    .hword (swi_IntrWait - bios_base)
    .hword (swi_VBlankIntrWait - bios_base)
    .hword (swi_Div - bios_base)
    .hword (swi_DivArm - bios_base)
    .hword (swi_Sqrt - bios_base)
    .hword (swi_ArcTan - bios_base)
    .hword (swi_ArcTan2 - bios_base)
    .hword (swi_CpuSet + 1 - bios_base)
    .hword (swi_CpuFastSet - bios_base)
    .hword (swi_GetBiosChecksum - bios_base)
    .hword (swi_BGAffineSet - bios_base)
    .hword (swi_ObjAffineSet - bios_base)
    .hword (swi_BitUnpack - bios_base)
    .hword (swi_LZ77UnCompWrite8bit - bios_base)
    .hword (swi_LZ77UnCompWrite16bit - bios_base)
    .hword (swi_HuffUnCompReadNormal - bios_base)
    .hword (swi_RLUnCompReadNormalWrite8bit + 1 - bios_base)
    .hword (swi_RLUnCompReadNormalWrite16bit + 1 - bios_base)
    .hword (swi_Diff8bitUnfilterWrite8bit + 1 - bios_base)
    .hword (swi_Diff8bitUnfilterWrite16bit - bios_base)
    .hword (swi_Diff16bitUnfilter - bios_base)
    .hword (swi_SoundBias + 1 - bios_base)
    .hword (swi_SoundDriverInit + 1 - bios_base)
    .hword (swi_SoundDriverMode + 1 - bios_base)
    .hword (swi_SoundDriverMain - bios_base)
    .hword (swi_SoundDriverVSync + 1 - bios_base)
    .hword (swi_SoundChannelClear + 1 - bios_base)
    .hword (swi_MidiKey2Freq - bios_base)
    .hword (swi_DoNothing + 1 - bios_base)   @ SoundWhatever0
    .hword (swi_DoNothing + 1 - bios_base)   @ SoundWhatever1
    .hword (swi_DoNothing + 1 - bios_base)   @ SoundWhatever2
    .hword (swi_DoNothing + 1 - bios_base)   @ SoundWhatever3
    .hword (swi_MusicPlayerFadeOut + 1 - bios_base)
    .hword (swi_MultiBoot + 1 - bios_base)
    .hword (swi_HardReset - bios_base)
    .hword (swi_CustomHalt - bios_base)
    .hword (swi_SoundDriverVSyncOff + 1 - bios_base)
    .hword (swi_SoundDriverVSyncOn + 1 - bios_base)
    .hword (swi_SoundGetJumpList + 1 - bios_base)
.thumb
swi_DoNothing:
    bx lr
.arm
.align 2

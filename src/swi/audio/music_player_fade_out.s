@ SPDX-License-Identifier: LGPL-3.0-or-later
@ MusicPlayerFadeOut (SWI 0x24): start a fade on a music player.
@
@ Entry:  r0 = player, r1 = fade speed
@ Return: r0 preserved; r1 = 0x100 on a valid ident, else the speed unchanged.
@
@ Validates the player ident at +0x34 (SOUND_IDENT). Invalid = no-op. Valid: fade
@ interval (+0x24) = counter (+0x26) = speed, fade volume (+0x28) = 0x100. The game's
@ player tick then steps the fade each frame.
.thumb
swi_MusicPlayerFadeOut:
    ldr  r2, [r0, #0x34]
    ldr  r3, =SOUND_IDENT
    cmp  r2, r3
    bne  .fade_ret
    strh r1, [r0, #0x24]
    strh r1, [r0, #0x26]
    movs r1, #0x80
    lsls r1, r1, #1
    strh r1, [r0, #0x28]
.fade_ret:
    bx lr
    .ltorg

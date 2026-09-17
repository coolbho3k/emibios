// SPDX-License-Identifier: MIT
// mGBA 0.10.5: reset during boot, before any payload.
// Build with mGBA development headers and libmgba:
// cc tests/system/joyboot_dma_test.c $(pkg-config --cflags --libs mgba) -o /tmp/joyboot_dma_test
// Run: /tmp/joyboot_dma_test BIOS.bin reset-frame [cart.gba|-] [keys]
#include <mgba/core/core.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/sio.h>
#include <mgba-util/vfs.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static color_t pixels[240 * 160];

static int displayActive(struct mCore* core, struct GBA* gba) {
    // BG0HOFS is write-only.
    return (core->busRead16(core, 0x040000ba) & 0x8000) ||
           (core->busRead16(core, 0x040000de) & 0x8000) ||
           gba->memory.io[0x10 / 2] != 0;
}

int main(int argc, char** argv) {
    if (argc < 3 || argc > 5 || atoi(argv[2]) <= 0) {
        fprintf(stderr, "Usage: %s BIOS.bin reset-frame [cart.gba|-] [keys]\n", argv[0]);
        return 2;
    }
    struct mCore* core = GBACoreCreate();
    if (!core || !core->init(core)) return 2;
    mCoreInitConfig(core, NULL);
    core->setVideoBuffer(core, pixels, 240);
    if (!core->loadBIOS(core, VFileOpen(argv[1], O_RDONLY), 0)) return 2;
    if (argc >= 4 && strcmp(argv[3], "-") &&
        !core->loadROM(core, VFileOpen(argv[3], O_RDONLY))) return 2;
    core->opts.useBios = 1;
    core->opts.skipBios = 0;
    core->reset(core);
    core->setKeys(core, argc == 5 ? atoi(argv[4]) : 12); // Start+Select.

    int frame = atoi(argv[2]);
    for (int f = 0; f < frame; ++f) core->runFrame(core);
    struct GBA* gba = core->board;
    struct GBASIODriver joy = {.p = &gba->sio};
    uint8_t data[5] = {0};
    printf("Before reset at frame %d: DMA0=%04x DMA3=%04x\n", frame,
           core->busRead16(core, 0x040000ba), core->busRead16(core, 0x040000de));
    GBASIOJOYSendCommand(&joy, JOY_RESET, data);
    for (int f = 0; f < 5; ++f) core->runFrame(core);

    uint32_t challenge = core->busRead32(core, 0x04000154);
    printf("Receiver: challenge=%08x DMA0=%04x DMA3=%04x BG0HOFS=%04x\n",
           challenge, core->busRead16(core, 0x040000ba),
           core->busRead16(core, 0x040000de), gba->memory.io[0x10 / 2]);
    int bad = challenge != 0xc0debabe || displayActive(core, gba) ||
              core->busRead8(core, 0x04000300) != 1;
    for (int f = 0; f < 60; ++f) {
        core->runFrame(core);
        bad |= displayActive(core, gba);
    }
    printf("%s: receiver display remains parked before any payload is sent\n",
           bad ? "FAIL" : "PASS");
    core->deinit(core);
    return bad;
}

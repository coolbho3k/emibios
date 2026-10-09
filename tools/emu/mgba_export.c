// SPDX-License-Identifier: MIT
// Headless C ABI over the mGBA GBA core for tools/emu/mgba.zig
#include <mgba/core/config.h>
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/timing.h>
#include <mgba/internal/arm/arm.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/overrides.h>
#include <mgba/internal/gba/video.h>
#include <mgba-util/crc32.h>
#include <mgba-util/vfs.h>

// Logo CRC mGBA checks before running the BIOS
#define LOGO_CRC 0xD0BEB55E

struct MG {
	struct ARMCore cpu;
	struct GBA gba;
	struct mCPUComponent* components[CPU_COMPONENT_MAX];
	struct GBAVideoRenderer dummy;
	bool live;
};

static void quiet(struct mLogger* l, int c, enum mLogLevel v, const char* f, va_list a) {
	(void) l; (void) c; (void) v; (void) f; (void) a;
}
static struct mLogger quietLogger = { .log = quiet };

// The mCore frontend and its config are not built. Log filters and cheats never use them here.
const struct mCoreMemoryBlock* mCoreGetMemoryBlockInfo(struct mCore* core, uint32_t address) {
	(void) core; (void) address;
	return NULL;
}
const char* mCoreConfigGetValue(const struct mCoreConfig* c, const char* key) {
	(void) c; (void) key;
	return NULL;
}
bool mCoreConfigGetBoolValue(const struct mCoreConfig* c, const char* key, bool* value) {
	(void) c; (void) key; (void) value;
	return false;
}
bool mCoreConfigGetIntValue(const struct mCoreConfig* c, const char* key, int* value) {
	(void) c; (void) key; (void) value;
	return false;
}
void mCoreConfigSetValue(struct mCoreConfig* c, const char* key, const char* value) {
	(void) c; (void) key; (void) value;
}
void mCoreConfigSetIntValue(struct mCoreConfig* c, const char* key, int value) {
	(void) c; (void) key; (void) value;
}
void mCoreConfigEnumerate(const struct mCoreConfig* c, const char* prefix, void (*handler)(const char*, const char*, enum mCoreConfigLevel, void*), void* user) {
	(void) c; (void) prefix; (void) handler; (void) user;
}

static void teardown(struct MG* p) {
	if (!p->live) return;
	ARMDeinit(&p->cpu);
	GBADestroy(&p->gba);
	p->live = false;
}

struct MG* MG_create(void) {
	mLogSetDefaultLogger(&quietLogger);
	return calloc(1, sizeof(struct MG));
}

void MG_destroy(struct MG* p) {
	teardown(p);
	free(p);
}

// Fresh core per boot, set up like mGBA's own core reset with the BIOS run (no skip).
void MG_boot(struct MG* p, const uint8_t* bios, size_t blen, const uint8_t* rom, size_t rlen) {
	teardown(p);
	memset(&p->cpu, 0, sizeof(p->cpu));
	memset(&p->gba, 0, sizeof(p->gba));
	memset(p->components, 0, sizeof(p->components));
	GBACreate(&p->gba);
	ARMSetComponents(&p->cpu, &p->gba.d, CPU_COMPONENT_MAX, p->components);
	ARMInit(&p->cpu);
	GBAVideoDummyRendererCreate(&p->dummy);
	GBAVideoAssociateRenderer(&p->gba.video, &p->dummy);
	p->live = true;

	GBALoadROM(&p->gba, VFileMemChunk(rom, rlen));
	GBALoadBIOS(&p->gba, VFileMemChunk(bios, blen));
	p->gba.memory.hw.devices &= ~HW_GB_PLAYER_DETECTION;
	GBAOverrideApplyDefaults(&p->gba, NULL);
	ARMReset(&p->cpu);
	if (rlen >= 0xA0 && doCrc32(&p->gba.memory.rom[1], 0x9C) != LOGO_CRC) GBASkipBIOS(&p->gba);
	mTimingInterrupt(&p->gba.timing);
}

// buttons is active low like KEYINPUT.
void MG_frame(struct MG* p, uint16_t buttons) {
	struct GBA* gba = &p->gba;
	gba->keysActive = ~buttons & 0x3FF;
	GBATestKeypadIRQ(gba);
	uint32_t frame = gba->video.frameCounter;
	uint32_t start = mTimingCurrentTime(&gba->timing);
	while (gba->video.frameCounter == frame && mTimingCurrentTime(&gba->timing) - start < VIDEO_TOTAL_LENGTH + VIDEO_HORIZONTAL_LENGTH) {
		ARMRunLoop(&p->cpu);
	}
}

// gprs[15] runs one fetch ahead of the next instruction.
static uint32_t curPc(struct MG* p) {
	return p->cpu.gprs[ARM_PC] - (p->cpu.executionMode == MODE_THUMB ? 2 : 4);
}

// Cycles since reset. mTimingGlobalTime only counts with debugger support built in.
static uint64_t now(struct MG* p) {
	return (uint32_t) mTimingCurrentTime(&p->gba.timing);
}

// Steps until PC first enters cart ROM.
uint64_t MG_run_to_handoff(struct MG* p, uint64_t cap, uint32_t* out_pc) {
	p->gba.keysActive = 0;
	while (now(p) < cap) {
		uint32_t pc = curPc(p);
		if (pc >= 0x08000000 && pc < 0x0E000000) break;
		ARMRun(&p->cpu);
	}
	*out_pc = curPc(p);
	return now(p);
}

uint8_t MG_read(struct MG* p, uint8_t region, uint32_t off) {
	struct GBA* gba = &p->gba;
	switch (region) { // tags from mgba.zig regionTag()
	case 0: return off < SIZE_WORKING_RAM ? ((uint8_t*) gba->memory.wram)[off] : 0;
	case 1: return off < SIZE_WORKING_IRAM ? ((uint8_t*) gba->memory.iwram)[off] : 0;
	case 2: return off < sizeof(gba->memory.io) ? ((uint8_t*) gba->memory.io)[off] : 0;
	case 3: return off < SIZE_PALETTE_RAM ? ((uint8_t*) gba->video.palette)[off] : 0;
	case 4: return off < SIZE_OAM ? ((uint8_t*) gba->video.oam.raw)[off] : 0;
	case 5: return off < SIZE_VRAM ? ((uint8_t*) gba->video.vram)[off] : 0;
	default: return 0;
	}
}

void MG_get_regs(struct MG* p, uint32_t* dest) {
	for (int i = 0; i < 15; i++) dest[i] = p->cpu.gprs[i];
	dest[15] = curPc(p);
}

// Open bus BIOS read latch.
uint32_t MG_get_biosread(struct MG* p) {
	return p->gba.memory.biosPrefetch;
}

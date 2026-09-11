// SPDX-License-Identifier: MIT
// Local GBAHawk C exports for tools/emu/gbahawk.zig
#include "GBAHawk.h"
#include "Core.h"
#include "LinkCore.h"
#include <cstdint>

using namespace GBAHawk;

GBAHawk_EXPORT uint64_t GBA_run_to_handoff(GBACore* p, uint16_t ctrl1, uint64_t cap, uint32_t* out_pc)
{
	p->GBA.New_Controller = ctrl1;
	p->GBA.controller_state_old = p->GBA.controller_state;
	p->GBA.controller_state = ctrl1;
	p->GBA.VBlank_Rise = false;
	while (p->GBA.CycleCount < cap)
	{
		uint32_t pc = p->GBA.cpu_Regs[15];
		if (pc >= 0x08000000 && pc < 0x0E000000) { if (out_pc) *out_pc = pc; return p->GBA.CycleCount; }
		p->GBA.Single_Step();
		// The frontend drains the audio delta buffers every frame; this raw step loop never does.
		// A sound-playing boot (the retail BIOS jingle) overruns samples_L/R[25000] without this.
		if (p->GBA.num_samples_R > 8192 || p->GBA.num_samples_L > 8192)
		{
			p->GBA.num_samples_R = 0;
			p->GBA.num_samples_L = 0;
		}
	}
	if (out_pc) *out_pc = p->GBA.cpu_Regs[15];
	return p->GBA.CycleCount;
}

// CPU register file r0-r15 for the handoff-state test (tests/system/handoff_test.zig).
GBAHawk_EXPORT void GBA_get_regs(GBACore* p, uint32_t* dest)
{
	for (int i = 0; i < 16; i++) dest[i] = p->GBA.cpu_Regs[i];
}

// Open-bus BIOS-read latch (Last_BIOS_Read). The handoff-state test pins its value so a wrong
// latch at handoff is caught.
GBAHawk_EXPORT uint32_t GBA_get_biosread(GBACore* p) { return p->GBA.Last_BIOS_Read; }

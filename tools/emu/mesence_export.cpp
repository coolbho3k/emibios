// SPDX-License-Identifier: MIT
// Headless C ABI over MesenCE's emulation Core for tools/emu/mesence.zig
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <chrono>

#include "Shared/Emulator.h"
#include "Shared/EmuSettings.h"
#include "Shared/SettingTypes.h"
#include "Shared/MemoryType.h"
#include "Shared/Video/VideoDecoder.h"
#include "Shared/Video/VideoRenderer.h"
#include "GBA/GbaConsole.h"
#include "GBA/GbaCpu.h"
#include "GBA/GbaTypes.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/VirtualFile.h"

namespace fs = std::filesystem;

namespace {

MemoryType regionType(uint8_t r) {
  switch (r) { // tags from mesence.zig regionTag()
    case 1: return MemoryType::GbaIntWorkRam;
    case 3: return MemoryType::GbaPaletteRam;
    case 4: return MemoryType::GbaSpriteRam;
    case 5: return MemoryType::GbaVideoRam;
    default: return MemoryType::GbaExtWorkRam; // 0 wram; 2 ioregs has no dumpable region (read returns 0)
  }
}

struct Shim {
  std::unique_ptr<Emulator> emu;
  GbaConsole* console = nullptr;
  std::string biosDir;
  bool locked = false;
};

bool g_static_init = false;

void park(Shim* s) {
  if (!s->locked) { s->emu->Lock(); s->locked = true; }
}

// Advance one frame. Lock alone can re-park before any frame runs, so wait for the frame counter to
// move. It may overshoot by a frame, which is harmless here.
void stepOneFrame(Shim* s) {
  uint32_t fc0 = s->console->GetFrameCount();
  if (s->locked) { s->emu->Unlock(); s->locked = false; }
  while (s->console->GetFrameCount() == fc0) std::this_thread::yield();
  s->emu->Lock();
  s->locked = true;
}

} // namespace

extern "C" {

void* Mesen_create() {
  if (!g_static_init) { GbaCpu::StaticInit(); g_static_init = true; }
  Shim* s = new Shim();

  // Per-instance temp firmware dir
  auto uniq = std::to_string(reinterpret_cast<uintptr_t>(s)) + "_" +
              std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
  fs::path biosDir = fs::temp_directory_path() / ("mesence_bios_" + uniq);
  std::error_code ec;
  fs::create_directories(biosDir, ec);
  s->biosDir = biosDir.string();
  FolderUtilities::SetHomeFolder(s->biosDir);
  FolderUtilities::SetFolderOverrides("", "", "", s->biosDir); // 4th arg = firmware folder

  s->emu = std::make_unique<Emulator>();
  s->emu->Initialize(false);
  s->emu->GetVideoDecoder()->StopThread(); // headless
  s->emu->GetVideoRenderer()->StopThread();
  s->emu->GetSettings()->SetFlag(EmulationFlags::TestMode); // unthrottled
  return s;
}

void Mesen_destroy(void* p) {
  Shim* s = static_cast<Shim*>(p);
  if (s->locked) { s->emu->Unlock(); s->locked = false; }
  s->emu->Stop(false);
  s->emu->Release();
  std::error_code ec;
  fs::remove_all(s->biosDir, ec);
  delete s;
}

void Mesen_boot(void* p, const uint8_t* bios, size_t biosLen, const uint8_t* rom, size_t romLen) {
  Shim* s = static_cast<Shim*>(p);
  std::string biosPath = (fs::path(s->biosDir) / "gba_bios.bin").string(); // GbaConsole loads it per LoadRom
  FILE* f = fopen(biosPath.c_str(), "wb");
  if (f) { fwrite(bios, 1, biosLen, f); fclose(f); }
  if (s->locked) { s->emu->Unlock(); s->locked = false; } // release the old emu thread before LoadRom restarts it
  VirtualFile romFile(rom, (uint32_t)romLen, "game.gba");
  s->emu->LoadRom(romFile, VirtualFile()); // stopRom=true spawns the emulation thread, Run sets up FrameLimiter
  park(s);
  s->console = static_cast<GbaConsole*>(s->emu->GetConsole().get());
}

void Mesen_frame(void* p, uint16_t buttons, uint8_t render, uint8_t sound) {
  (void)buttons; (void)render; (void)sound;
  stepOneFrame(static_cast<Shim*>(p));
}

uint8_t Mesen_read(void* p, uint8_t region, uint32_t off) {
  Shim* s = static_cast<Shim*>(p);
  if (region == 2) return 0; // ioregs: TODO
  ConsoleMemoryInfo info = s->emu->GetMemory(regionType(region));
  if (info.Memory && off < info.Size) return ((uint8_t*)info.Memory)[off];
  return 0;
}

// Frame-granular handoff. Couldn't find a way to do cycle-granular unfortunately.
uint64_t Mesen_run_to_handoff(void* p, uint64_t cap, uint32_t* outPc) {
  Shim* s = static_cast<Shim*>(p);
  (void)cap;
  GbaConsole* c = s->console;
  auto pc = [&]() { return c->GetCpu()->GetState().R[15]; };
  for (int frame = 0; frame < 100000; frame++) {
    stepOneFrame(s);
    uint32_t v = pc();
    if (v >= 0x08000000 && v < 0x0A000000) { *outPc = 0x08000000; return c->GetMasterClock(); }
  }
  *outPc = pc();
  return c->GetMasterClock();
}

void Mesen_get_regs(void* p, uint32_t* dest) {
  Shim* s = static_cast<Shim*>(p);
  GbaCpuState& st = s->console->GetCpu()->GetState();
  for (int i = 0; i < 16; i++) dest[i] = st.R[i];
}

} // extern "C"

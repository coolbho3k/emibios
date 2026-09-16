// SPDX-License-Identifier: LGPL-3.0-or-later
const std = @import("std");
const manifest = @import("tools/test_manifest.zig");

// Build graph for emibios.
pub fn build(b: *std.Build) void {
    const zig = b.graph.zig_exe;

    // recal.zig detects BIOS changes by hashing the built gba_bios.bin against bios.sha256.
    const no_recal = b.option(bool, "no-recal", "skip the handoff gate/recal") orelse false;

    // -Dlayout-perturb=N shifts everything below the IRQ handler down by N bytes.
    // This flag is used to smoke out if game divergences are caused by BIOS layout differences, which are fine.
    const layout_perturb = b.option(usize, "layout-perturb", "shift the BIOS layout by N bytes") orelse 0;

    // Build-time generators
    //   1. Sine LUT used by affine and boot screen
    //   2. Boot screen assets
    const sine_exe = b.addExecutable(.{ .name = "gen_sine", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen/sine_lut.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const sine_dir = b.addRunArtifact(sine_exe).addOutputDirectoryArg("gen"); // writes gen/sine_lut.s

    const boot_exe = b.addExecutable(.{ .name = "gen_boot_screen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/boot_screen/gen_boot_screen.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "zigimg", .module = b.dependency("zigimg", .{}).module("zigimg") }},
    }) });
    const boot_run = b.addRunArtifact(boot_exe);
    boot_run.setCwd(b.path("."));
    boot_run.addFileInput(b.path("assets/emibios_logo_2bpp.png"));
    boot_run.addFileInput(b.path("assets/gbstudio_default_ascii.png"));
    const boot_dir = boot_run.addOutputDirectoryArg("gen"); // writes gen/boot_screen_data.s

    // Test ROM font atlas
    const font_exe = b.addExecutable(.{ .name = "gen_font_atlas", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/boot_screen/gen_font_atlas.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "zigimg", .module = b.dependency("zigimg", .{}).module("zigimg") }},
    }) });
    const font_run = b.addRunArtifact(font_exe);
    font_run.setCwd(b.path(".")); // reads the source PNG by project-relative path
    font_run.addFileInput(b.path("assets/gbstudio_default_ascii.png"));
    const font_bin = font_run.addOutputDirectoryArg("gen").path(b, "font.bin");

    // Assemble preprocessed
    const asm_cmd = b.addSystemCommand(&.{ zig, "cc", "-c", "-x", "assembler-with-cpp" });
    asm_cmd.addFileArg(b.path("src/entrypoint.s"));
    asm_cmd.addArg("-target");
    asm_cmd.addArg("arm-freestanding-eabi");
    asm_cmd.addArg("-mcpu=arm7tdmi");
    asm_cmd.addArg("-I");
    asm_cmd.addArg("src");
    asm_cmd.addArg("-I");
    asm_cmd.addDirectoryArg(sine_dir);
    asm_cmd.addArg("-I");
    asm_cmd.addDirectoryArg(boot_dir);
    if (layout_perturb != 0) asm_cmd.addArg(b.fmt("-Wa,--defsym,LAYOUT_PERTURB={d}", .{layout_perturb}));
    asm_cmd.addArg("-MD"); // emit a depfile alongside the object...
    _ = asm_cmd.addPrefixedDepFileOutputArg("-MF", "entrypoint.o.d"); // ...which the Run step parses for inputs
    asm_cmd.addArg("-o");
    const obj = asm_cmd.addOutputFileArg("entrypoint.o");

    // The linker script fixes the BIOS layout and objcopy extracts the visible 16 KiB image.
    const bios = linkBin(b, zig, b.path("src/link.ld"), obj, "bios");
    const inst = b.addInstallBinFile(bios.bin, "gba_bios.bin");
    const elf_inst = b.addInstallBinFile(bios.elf, "bios.elf"); // the report tool reads symbols from it
    b.getInstallStep().dependOn(&inst.step);
    b.getInstallStep().dependOn(&elf_inst.step);

    // Hashes the built BIOS against bios.sha256 and shells out to `zig build recal` on a mismatch.
    // `-Dno-recal` inner builds skip the gate.
    const rc_exe = b.addExecutable(.{ .name = "recal", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/recal/recal.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    if (!no_recal and layout_perturb == 0) {
        const gate = b.addRunArtifact(rc_exe);
        gate.setCwd(b.path("."));
        gate.addArg("gate");
        gate.addArg(zig);
        gate.step.dependOn(&inst.step);
        b.getInstallStep().dependOn(&gate.step);
    }

    const verify = b.step("verify", "Build the BIOS and check its SHA-256");
    const v = b.addSystemCommand(&.{ zig, "run", "tools/verify.zig", "--", "zig-out/bin/gba_bios.bin", "bios.sha256" });
    v.setCwd(b.path("."));
    // Skip the recalibration gate when checking the committed hash.
    v.step.dependOn(&inst.step);
    verify.dependOn(&v.step);

    const report = b.step("report", "Build the BIOS and print the space report");
    const r = b.addSystemCommand(&.{ zig, "run", "tools/space_report.zig" });
    r.setCwd(b.path("."));
    r.step.dependOn(b.getInstallStep());
    report.dependOn(&r.step);

    // Selectable emulator backend for recal and the SWI tests.
    const EmuKind = enum { gbahawk, mesence };
    const emu_kind = b.option(EmuKind, "emu", "emulator backend for recal/test: gbahawk (default) | mesence") orelse .gbahawk;
    // Calibrated BIOS to cart handoff cycle
    const handoff_target: u64 = 76001675;
    const iface_mod = b.createModule(.{ .root_source_file = b.path("tools/emu/iface.zig") });
    const emu_core = b.step("emu-core", "Build the selected emulator core library (recal/test dependency)");
    const recal = b.step("recal", "Re-pin the boot handoff to the committed phase");

    // ARM modules shared by the on-GBA test ROM and the standalone permutation harness ROM
    const arm = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
    });
    const protocol_arm = b.createModule(.{ .root_source_file = b.path("rom/protocol.zig"), .target = arm, .optimize = .ReleaseSmall });
    const layout_arm = b.createModule(.{ .root_source_file = b.path("rom/layout.zig"), .target = arm, .optimize = .ReleaseSmall });
    const manifest_arm = b.createModule(.{ .root_source_file = b.path("tools/test_manifest.zig"), .target = arm, .optimize = .ReleaseSmall });
    const rgba = b.createModule(.{ .root_source_file = b.path("rom/gba.zig"), .target = arm, .optimize = .ReleaseSmall });
    rgba.addImport("protocol", protocol_arm);
    rgba.addImport("layout", layout_arm);
    // The ROM build's `test_options`. Each `<swi>_rom` is the SWI number.
    const rom_opts = b.addOptions();
    rom_opts.addOption([]const u8, "bios_path", "");
    rom_opts.addOption([]const u8, "emu", "gba");
    rom_opts.addOption(u64, "handoff_cycle", handoff_target);
    rom_opts.addOption([]const u8, "handoff_rom", "");
    for (manifest.swi_tests) |t| for (t.swis) |s| rom_opts.addOption(u8, s.opt, s.num);
    const ropts = rom_opts.createModule();
    const codec_arm = b.createModule(.{ .root_source_file = b.path("tests/decompression/codec.zig"), .target = arm, .optimize = .ReleaseSmall });
    const helpers_arm = b.createModule(.{ .root_source_file = b.path("tests/decompression/test_helpers.zig"), .target = arm, .optimize = .ReleaseSmall });
    helpers_arm.addImport("gba", rgba);
    const testing_arm = b.createModule(.{ .root_source_file = b.path("tests/testing.zig"), .target = arm, .optimize = .ReleaseSmall });
    testing_arm.addImport("layout", layout_arm);
    const ram_perm_mod = b.createModule(.{ .root_source_file = b.path("tests/memory/ram_perm.zig"), .target = arm, .optimize = .ReleaseSmall });
    ram_perm_mod.addImport("layout", layout_arm);
    const perm_mod = b.createModule(.{ .root_source_file = b.path("rom/perm.zig"), .target = arm, .optimize = .ReleaseSmall });
    perm_mod.addImport("gba", rgba);
    perm_mod.addImport("ram_perm", ram_perm_mod);
    perm_mod.addImport("layout", layout_arm);

    // Build the test files into a bootable cart using the generated test_options and rom/gba.zig executor.
    const test_rom_gba = blk: {
        const root = b.createModule(.{ .root_source_file = b.path("rom/main.zig"), .target = arm, .optimize = .ReleaseSmall });
        root.addImport("gba", rgba);
        root.addImport("test_options", ropts);
        root.addImport("ram_perm", ram_perm_mod); // the shared permutation spec
        root.addImport("perm", perm_mod); // the shared permutation matrix executor
        root.addImport("testing", testing_arm); // the assertion shim main.zig hands to each test body
        root.addImport("layout", layout_arm);
        root.addImport("protocol", protocol_arm);
        root.addImport("test_manifest", manifest_arm);
        root.addAnonymousImport("font.bin", .{ .root_source_file = font_bin }); // generated from the PNG above
        for (manifest.swi_tests) |t| {
            const m = b.createModule(.{ .root_source_file = b.path(t.path), .target = arm, .optimize = .ReleaseSmall });
            m.addImport("gba", rgba);
            m.addImport("test_options", ropts);
            m.addImport("codec.zig", codec_arm); // resolves the decompression tests' @import("codec.zig")
            m.addImport("test_helpers.zig", helpers_arm); // shared so it belongs to one module, not each
            m.addImport("testing", testing_arm);
            root.addImport(t.module, m);
        }
        break :blk buildGbaRom(b, zig, "test_rom", root, 1 << 20); // pad to 1 MiB
    };
    b.step("rom", "Build the on-GBA test ROM (zig-out/bin/test_rom.gba)")
        .dependOn(&b.addInstallBinFile(test_rom_gba, "test_rom.gba").step);

    // To add a test core:
    //   1. Add a tools/emu/<core>.zig backend
    //   2. Write a build<Core>() function
    //   3. Add to this switch case
    const backend: ?Backend = switch (emu_kind) {
        .gbahawk => buildGbahawk(b, iface_mod, emu_core),
        .mesence => buildMesence(b, iface_mod, emu_core),
    };
    if (backend) |bk| {
        const emu_lib = bk.lib;
        const emu_mod = bk.mod;

        // The probe reports the handoff cycle for one ROM.
        const probe = b.addExecutable(.{ .name = "probe", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/recal/probe.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libcpp = true,
        }) });
        probe.root_module.linkLibrary(emu_lib);
        probe.root_module.addImport("iface", iface_mod);
        probe.root_module.addImport("emu", emu_mod);

        const hs_root = b.createModule(.{ .root_source_file = b.path("rom/handoff_stub.zig"), .target = arm, .optimize = .ReleaseSmall });
        const rom_gba = buildGbaRom(b, zig, "handoff_stub", hs_root, null);

        const sm_root = b.createModule(.{ .root_source_file = b.path("rom/sound_mode_stub.zig"), .target = arm, .optimize = .ReleaseSmall });
        const sound_mode_gba = buildGbaRom(b, zig, "sound_mode_stub", sm_root, null);

        const sr_root = b.createModule(.{ .root_source_file = b.path("rom/sound_reentry_stub.zig"), .target = arm, .optimize = .ReleaseSmall });
        const sound_reentry_gba = buildGbaRom(b, zig, "sound_reentry_stub", sr_root, null);

        const sl_root = b.createModule(.{ .root_source_file = b.path("rom/sound_loop_stub.zig"), .target = arm, .optimize = .ReleaseSmall });
        const sound_loop_gba = buildGbaRom(b, zig, "sound_loop_stub", sl_root, null);

        // `zig build recal` recalibrates the handoff.
        const rc = b.addRunArtifact(rc_exe);
        rc.setCwd(b.path("."));
        rc.addArg("deep");
        rc.addArg(zig);
        rc.addArtifactArg(probe);
        rc.addFileArg(rom_gba);
        rc.addArg(b.fmt("{d}", .{handoff_target}));
        recal.dependOn(&rc.step);

        // Standalone permutation harness ROM
        const ph_root = b.createModule(.{ .root_source_file = b.path("rom/perm_harness.zig"), .target = arm, .optimize = .ReleaseSmall });
        ph_root.addImport("gba", rgba);
        ph_root.addImport("perm", perm_mod);
        ph_root.addImport("protocol", protocol_arm);
        const perm_harness_gba = buildGbaRom(b, zig, "perm_harness", ph_root, 1 << 20);
        b.step("perm-harness", "Build the standalone RAM-permutation harness ROM")
            .dependOn(&b.addInstallBinFile(perm_harness_gba, "perm_harness.gba").step);

        const protocol_host = b.createModule(.{ .root_source_file = b.path("rom/protocol.zig"), .target = b.graph.host, .optimize = .Debug });
        const layout_host = b.createModule(.{ .root_source_file = b.path("rom/layout.zig"), .target = b.graph.host, .optimize = .Debug });

        const test_opts = b.addOptions();
        const bios_opt = b.option([]const u8, "bios", "Path to a BIOS binary to test (default: the built zig-out/bin/gba_bios.bin)");
        test_opts.addOption([]const u8, "bios_path", bios_opt orelse "zig-out/bin/gba_bios.bin");
        test_opts.addOption([]const u8, "emu", @tagName(emu_kind));
        test_opts.addOption(u64, "handoff_cycle", handoff_target);
        for (manifest.swi_tests) |t| for (t.swis) |s| test_opts.addOptionPath(s.opt, swiTestRom(b, zig, rgba, protocol_arm, arm, s.num));
        test_opts.addOptionPath("handoff_rom", rom_gba);
        test_opts.addOptionPath("sound_mode_rom", sound_mode_gba);
        test_opts.addOptionPath("sound_reentry_rom", sound_reentry_gba);
        test_opts.addOptionPath("sound_loop_rom", sound_loop_gba);
        test_opts.addOptionPath("perm_harness_rom", perm_harness_gba);
        test_opts.addOptionPath("test_rom_path", test_rom_gba);

        const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this substring");
        const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
        // Each test file is its own test binary so they run concurrently.
        const test_files = comptime blk: {
            var paths: [manifest.swi_tests.len + manifest.platform_specific.len][]const u8 = undefined;
            for (manifest.swi_tests, 0..) |t, i| paths[i] = t.path;
            for (manifest.platform_specific, 0..) |p, i| paths[manifest.swi_tests.len + i] = p.path;
            break :blk paths;
        };
        const opts_mod = test_opts.createModule();
        const gba_mod = b.createModule(.{ .root_source_file = b.path("tests/gba.zig"), .target = b.graph.host, .optimize = .Debug });
        gba_mod.addImport("iface", iface_mod);
        gba_mod.addImport("emu", emu_mod);
        gba_mod.addImport("protocol", protocol_host);
        const testing_host = b.createModule(.{ .root_source_file = b.path("tests/testing.zig"), .target = b.graph.host, .optimize = .Debug });
        testing_host.addImport("layout", layout_host);
        const test_step = b.step("test", "Run the SWI unit tests in parallel (-Demu=<backend>, -Dbios=<path>, -Dtest-filter=<name>)");
        for (test_files) |file| {
            const t = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(file),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .link_libcpp = true,
                }),
                .filters = test_filters,
            });
            t.root_module.linkLibrary(emu_lib);
            t.root_module.addImport("gba", gba_mod);
            t.root_module.addImport("iface", iface_mod); // handoff_test.zig drives the core directly
            t.root_module.addImport("emu", emu_mod);
            t.root_module.addImport("test_options", opts_mod);
            t.root_module.addImport("testing", testing_host);
            t.root_module.addImport("layout", layout_host);
            t.root_module.addImport("protocol", protocol_host);
            const run = b.addRunArtifact(t);
            run.setCwd(b.path("."));
            // Build the candidate BIOS unless -Dbios supplied one.
            if (bios_opt == null) run.step.dependOn(b.getInstallStep());
            test_step.dependOn(&run.step);
        }
    }

    const lint = b.step("lint", "Lint the assembly source. -Dfix rewrites fixable issues. Warnings fail unless -Dstrict=false)");
    const lint_fix = b.option(bool, "fix", "lint: rewrite fixable issues in-place") orelse false;
    const lint_strict = b.option(bool, "strict", "lint: treat warnings as failures") orelse true;
    const lint_exe = b.addExecutable(.{ .name = "lint_asm", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lint_asm.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const lint_run = b.addRunArtifact(lint_exe);
    lint_run.setCwd(b.path("."));
    if (lint_fix) lint_run.addArg("--fix");
    if (lint_strict) lint_run.addArg("--strict");
    if (b.args) |a| lint_run.addArgs(a); // file paths to lint
    lint.dependOn(&lint_run.step);

    const fmt = b.step("fmt", "Format build.zig and the tools with zig fmt");
    fmt.dependOn(&b.addFmt(.{ .paths = &.{ "build.zig", "tools" } }).step);
}

// We must support multiple emulator backends so we can cross check for accuracy. Today, that is GBAHawk and MesenCE.
// Tests should pass on all cycle-accurate emulators we add (or there is a bug with the emulator or our BIOS).
// Emulator sources are fetched and built with Zig itself targeting the host, so you don't need any other dependencies.

// An emulator backend consists of the compiled core library plus a tools/emu/<core>.zig module.
const Backend = struct { lib: *std.Build.Step.Compile, mod: *std.Build.Module };

// A static C++ core lib.
fn emuLib(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libcpp = true }),
    });
}

// Register a built core lib.
fn bindBackend(b: *std.Build, iface_mod: *std.Build.Module, lib_step: *std.Build.Step, lib: *std.Build.Step.Compile, zig_src: []const u8) Backend {
    lib_step.dependOn(&lib.step);
    const mod = b.createModule(.{ .root_source_file = b.path(zig_src) });
    mod.addImport("iface", iface_mod);
    return .{ .lib = lib, .mod = mod };
}

// GBAHawk emulator test backend
fn buildGbahawk(b: *std.Build, iface_mod: *std.Build.Module, lib_step: *std.Build.Step) ?Backend {
    const dep = b.lazyDependency("gbahawk", .{}) orelse return null;
    const stub = b.addWriteFiles();
    _ = stub.add("Memory.h", "");
    _ = stub.add("FLash_Mappers.h", "#include \"Flash_Mappers.h\"\n");
    const lib = emuLib(b, "gbahawk");
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("libHawk/GBAHawk"),
        .files = &.{
            "GBAHawk.cpp", "CPU_ARM.cpp",   "CPU_Thumb.cpp",   "CPU_LDM_Glitch.cpp",
            "PPU.cpp",     "MemoryMap.cpp", "Bus_Updater.cpp", "GBA_System.cpp",
        },
        .flags = &.{ "-std=c++17", "-w" },
    });
    lib.root_module.addIncludePath(stub.getDirectory());
    // tools/emu/gbahawk_export.cpp extends the packaged C ABI with a handoff helper.
    lib.root_module.addCSourceFile(.{ .file = b.path("tools/emu/gbahawk_export.cpp"), .flags = &.{ "-std=c++17", "-w" } });
    lib.root_module.addIncludePath(dep.path("libHawk/GBAHawk"));
    return bindBackend(b, iface_mod, lib_step, lib, "tools/emu/gbahawk.zig");
}

// MesenCE emulator test backend
fn buildMesence(b: *std.Build, iface_mod: *std.Build.Module, lib_step: *std.Build.Step) ?Backend {
    const dep = b.lazyDependency("mesence", .{}) orelse return null;
    const lib = emuLib(b, "mesence");
    const m = lib.root_module;
    // Include roots, matching MesenCE's makefile CXXFLAGS minus the SDL/frontend dirs.
    m.addIncludePath(dep.path("."));
    m.addIncludePath(dep.path("Core"));
    m.addIncludePath(dep.path("Utilities"));

    // Configure time walk of the dep tree. Skips UI/SDL frontends.
    var cxx_files: std.ArrayList([]const u8) = .empty;
    var c_files: std.ArrayList([]const u8) = .empty;
    const root_path = dep.builder.build_root.path orelse @panic("mesence: dependency has no build_root path");
    var root_dir = std.Io.Dir.cwd().openDir(b.graph.io, root_path, .{ .iterate = true }) catch @panic("mesence: openDir failed");
    defer root_dir.close(b.graph.io);
    var walker = root_dir.walk(b.allocator) catch @panic("mesence: walk failed");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch @panic("mesence: walk failed")) |entry| {
        if (entry.kind != .file) continue;
        const p = entry.path;
        if (std.mem.endsWith(u8, p, ".cpp") and
            (std.mem.startsWith(u8, p, "Core/") or std.mem.startsWith(u8, p, "Utilities/")))
            cxx_files.append(b.allocator, b.dupe(p)) catch @panic("oom");
        if (std.mem.endsWith(u8, p, ".c") and
            (std.mem.startsWith(u8, p, "Utilities/") or std.mem.startsWith(u8, p, "Lua/") or std.mem.startsWith(u8, p, "SevenZip/")))
            c_files.append(b.allocator, b.dupe(p)) catch @panic("oom");
    }
    const cxx = &[_][]const u8{ "-std=c++17", "-fPIC", "-w" };
    const cc = &[_][]const u8{ "-fPIC", "-w" };
    m.addCSourceFiles(.{ .root = dep.path("."), .files = cxx_files.items, .flags = cxx });
    m.addCSourceFiles(.{ .root = dep.path("."), .files = c_files.items, .flags = cc });
    m.addCSourceFile(.{ .file = b.path("tools/emu/mesence_export.cpp"), .flags = cxx }); // our headless shim

    return bindBackend(b, iface_mod, lib_step, lib, "tools/emu/mesence.zig");
}

const RomBin = struct { elf: std.Build.LazyPath, bin: std.Build.LazyPath };

// Link an ARM object through a linker script + objcopy into a BIOS image or .gba cart.
fn linkBin(b: *std.Build, zig: []const u8, script: std.Build.LazyPath, obj: std.Build.LazyPath, name: []const u8) RomBin {
    const ld = b.addSystemCommand(&.{ zig, "cc", "-target", "arm-freestanding-eabi", "-nostdlib", "-Wl,-e,0", "-T" });
    ld.addFileArg(script);
    ld.addFileArg(obj);
    ld.addArg("-o");
    const elf = ld.addOutputFileArg(b.fmt("{s}.elf", .{name}));
    const oc = b.addSystemCommand(&.{ zig, "objcopy", "-O", "binary" });
    oc.addFileArg(elf);
    return .{ .elf = elf, .bin = oc.addOutputFileArg(b.fmt("{s}.bin", .{name})) };
}

// Timing harness for each SWI: rom/swi_harness.zig with the SWI number baked in.
fn swiTestRom(b: *std.Build, zig: []const u8, gba_mod: *std.Build.Module, protocol_mod: *std.Build.Module, target: std.Build.ResolvedTarget, swi: u8) std.Build.LazyPath {
    const opts = b.addOptions();
    opts.addOption(u8, "swi", swi);
    const root = b.createModule(.{ .root_source_file = b.path("rom/swi_harness.zig"), .target = target, .optimize = .ReleaseSmall });
    root.addImport("gba", gba_mod);
    root.addImport("harness_opts", opts.createModule());
    root.addImport("protocol", protocol_mod);
    return buildGbaRom(b, zig, b.fmt("swi{d}", .{swi}), root, null);
}

// Link a freestanding-ARM root module into a bootable .gba.
// pad_bytes zero-pads the image to a size.
fn buildGbaRom(b: *std.Build, zig: []const u8, name: []const u8, root: *std.Build.Module, pad_bytes: ?usize) std.Build.LazyPath {
    // Every ROM root builds its header through rom/header.zig, which embeds the GBA logo.
    root.addAnonymousImport("gba_logo.bin", .{ .root_source_file = b.path("assets/gba_logo.bin") });
    const obj = b.addObject(.{ .name = name, .root_module = root });
    const bin = linkBin(b, zig, b.path("rom/rom.ld"), obj.getEmittedBin(), name).bin;
    const target = pad_bytes orelse return bin;
    const pad = b.addSystemCommand(&.{ zig, "run", "tools/pad.zig", "--" });
    pad.addFileArg(bin);
    const out = pad.addOutputFileArg(b.fmt("{s}.gba", .{name}));
    pad.addArg(b.fmt("{d}", .{target}));
    return out;
}

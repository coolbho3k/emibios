# emibios unit tests

Zig unit tests that exercise the BIOS by running small GBA programs on a cycle-accurate emulator
core (GBAHawk by default) and checking the results in Zig. The same test bodies also build into a
bootable cart that runs them and renders the results.

The tests are not yet comprehensive. Please be patient as I port more of my own tooling to Zig.

```sh
zig build test                                 # run every test
zig build test --test-timeout 240s             # may be required on slower computers
zig build test -Dtest-filter=Sqrt              # run only tests whose name contains "Sqrt"
zig build test -Dbios=/path/to/gba_bios.bin    # run the suite against any arbitrary BIOS
zig build test -Demu=mesence                   # select the emulator backend (default: gbahawk)
zig build rom                                  # build the test ROM (zig-out/bin/test_rom.gba)
```

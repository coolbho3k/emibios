# Known BIOS audio software

As far as I know, these are the only games in the commercial library that substantially use the
BIOS audio driver implemented by emibios in [`src/swi/audio`](https://github.com/coolbho3k/emibios/tree/main/src/swi/audio).

- Atari Anniversary Advance
- Cyberdrive Zoids
- Lizzie McGuire - On the Go!
- Mail de Cute
- Namco Museum 50th Anniversary
- Phantasy Star Collection
- Pocket Professor: KwikNotes Volume One
- Rampage: Puzzle Attack
- Saibara Rieko no Dendo Mahjong
- X-Men: Reign of Apocalypse

This applies to all regions and versions of these games, where there are multiple.

About half of these titles were created by American developer [Digital Eclipse](https://en.wikipedia.org/wiki/Digital_Eclipse),
which I suspect reused its sound engine code in a few games.

emibios implements the BIOS sound functionality required by the known commercial games above.

Fun fact: despite being required by less than 0.3% of the commercial library, `src/swi/audio` is
over 20% of the assembly lines in emibios! Having full sound functionality was an early design goal
of emibios, and I think it is important for historical preservation for *all* commercial games to
be playable with sound, regardless of demand for the games themselves.

If you know of more titles than the above, then they likely may not work with emibios yet. Please
file an issue to let me know, and I will do my best to add support as quickly as possible.

## More background on BIOS audio

The original Game Boy Advance BIOS includes a software PCM mixer and music playback functionality
closely related to Nintendo's MusicPlayer2000 (MP2K/m4a) sound engine.

Although MP2K became the most common sound engine for commercial GBA games, nearly all games embed
their own copy of the driver in cartridge ROM. This is because Nintendo distributed a newer,
improved version with the GBA SDK, but the commercial games listed above depend on the sound driver
in the BIOS. Since the BIOS is fixed permanently in mask ROM on the AGB CPU, Nintendo could not
update it, and since the SDK version was updated, most developers chose to use the newer version.

I'm pretty hazy on the history of official GBA development. If you have information or context
into why these developers may have chosen to use the BIOS sound driver instead of the SDK's, I'd
be curious to know! I'd love to be in touch with folks working on the Digital Eclipse team at the
time, for example.

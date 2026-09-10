# Save Format Assumptions

What Chains believes about emulator save files — and why it doesn't need to
believe much. Chains stores **opaque bytes**: it never parses a save file,
so a format it has never seen still round-trips byte-identical. This doc
records the real-world formats the fixtures and tests are modeled on.

## Battery saves (portable, preferred)

| File | System | Size | Emulators | Notes |
|---|---|---|---|---|
| `.srm` | SNES | 8 KB (LoROM) / 32 KB (HiROM) | Snes9x, RetroArch (Snes9x/bsnes cores), BizHawk | Raw SRAM dump, no header |
| `.sav` | GBA | 32 KB (256Kbit flash/SRAM) / 64 KB (512Kbit flash) | mGBA, VBA-M, RetroArch (mGBA/VBA cores) | Raw flash/SRAM dump, no header |
| `.sav` | GB/GBC | 8 KB / 32 KB | mGBA, VBA-M, RetroArch | Same raw-dump convention |
| `.mcr` | PSX | 128 KB | DuckStation, ePSXe, RetroArch (Beetle PSX core) | Raw memory-card dump, no header |
| `.ps2` | PS2 | 8 MB (16 MB for extended cards) | PCSX2, RetroArch (PCSX2 core) | Raw memory-card dump, no header; default card is 8 MB |
| `.gci` | GameCube | 8 KB per block (1–4 blocks typical) | Dolphin, RetroArch (Dolphin core) | Per-game save export; 64-byte header opens with the 4-letter game ID |
| `.dsv` | NDS | 512 KB typical (flash size varies per game) | DeSmuME | Raw save + small DeSmuME footer; Chains stores the bytes opaquely |
| `.sra` | N64 | 32 KB | Project64, mupen64plus, RetroArch (ParaLLEl core) | SRAM dump, no header |
| `.eep` | N64 | 2 KB (512-byte for some games) | Project64, mupen64plus, RetroArch (ParaLLEl core) | EEPROM dump, no header |
| `.fla` | N64 | 128 KB | Project64, mupen64plus, RetroArch (ParaLLEl core) | FlashRAM dump, no header |
| `.SaveRAM` | multi-system | varies per system (e.g. 8/32 KB SNES SRAM) | BizHawk | Raw SaveRAM dump written next to the ROM (e.g. `Game.SaveRAM`); matched case-insensitively |
| `.vmi` + `.vms` | Dreamcast | 44 B index + data in multiples of 512 B | Flycast, Redream, RetroArch (Flycast core) | Per-game VMU save export; `.vmi` is the index header, `.vms` the save data — tracked as a same-basename pair |

Battery saves are the future-proof format: any emulator for the system can
read them. Chains' guidance is **save in-game, not just save-state**.

## Save states (opaque, version-sensitive)

`*.state*` files are emulator-internal snapshots (CPU, PPU, memory, etc.).
They are **not portable across emulator versions** — a state from Snes9x
1.60 may not load in 1.62. Chains versions them like anything else, but the
bytes are only guaranteed meaningful to the emulator build that wrote them.

**PPSSPP** save states are tracked as `` `.ppst` `` files — they live in
`PSP/PPSSPP_STATE/` and are named `<GAMEID>_<version>_<slot>.ppst` (e.g.
`ULES01521_1.00_0.ppst`; PPSSPP also writes an `.undo.ppst` autosave
variant). PPSSPP writes a same-basename `.png` thumbnail next to each
state — the thumbnail is deliberately *not* tracked. In-game saves are
per-game folders under `PSP/SAVEDATA/` with no single-file extension, so
the `.ppst` state is the versioned unit; save in-game when you can.

Three more state extensions are tracked beyond `*.state*`:

| File | System | Emulators | Notes |
|---|---|---|---|
| `.sgm` | GBA/GB/GBC | VBA-M (and original VBA) | Save state, named `<romname>.sgm`; VBA-M keeps up to 10 slots (`<romname>.sgN` numeric variants are rare — the plain `.sgm` is the convention) |
| `.zst` | SNES | ZSNES | Save state slots are `game.zst`, `game.zs1`–`game.zs9` — Chains tracks `*.zst` only. **Caveat:** `.zst` is also the zstd compression extension; a zstd archive in a watched save dir would be versioned as bytes — harmless (opaque round-trip), but keep watch dirs save-only anyway |
| `.savestate` | PSX | DuckStation | Named `<GAMEID>_<slot>.savestate` under the savestates dir (e.g. `SLUS-01066_1.savestate`); DuckStation also writes same-basename `.png` thumbnails, which are deliberately *not* tracked |

Like all save states, these are version-sensitive to the emulator build
that wrote them — Chains preserves the bytes exactly, it does not make
them load anywhere else.

## Paired exports (Dreamcast VMU)

Dreamcast saves live on Visual Memory Units. **Flycast**, **Redream**, and
RetroArch's Flycast core export each per-game save as a same-basename pair
in the VMU data directory:

- `` `.vmi` `` — the Visual Memory System index: a fixed **44-byte header**
  describing the save (game name, icon, data file reference).
- `` `.vms` `` — the actual save data, sized in multiples of **512 bytes**.

The pair is the atomic unit — a `.vms` without its `.vmi` loses the
human-readable label and icon, so Chains tracks **both** patterns
(`*.vmi`, `*.vms`). As with the other battery-save formats, the bytes are
opaque: Chains stores the exported files byte-identical, so they can be
dropped back into any VMU-capable emulator unchanged. Save in-game on the
VMU; avoid snapshotting whole VMU card images unless the per-game export
isn't available.

## Why byte-identity is the whole contract

- Snapshots are stored as full file bytes, keyed by SHA256 of the exact
  bytes. No parsing, no normalization, no line-ending or encoding transforms.
- `restore` writes the stored bytes back verbatim; the regression suite
  asserts byte-identity with real-world sizes (32 KB `.srm`, 64 KB `.sav`).
- `verify` re-hashes every blob: silent corruption of even one byte is caught.

## Format-specific caveats

- **mGBA** may write a `.sav` alongside RTC/timing sidecar data for some
  games; the `.sav` itself stays a raw dump. Sidecars with other extensions
  are ignored unless they match a tracked pattern (`*.sav` / `*.srm` /
  `*.state*` / `*.mcr` / `*.ps2` / `*.gci` / `*.ppst` / `*.dsv` / `*.SaveRAM` / `*.sra` / `*.eep` / `*.fla`).
- **DeSmuME** writes `.dsv` battery saves (raw flash data plus a small
  DeSmuME footer) — by default in its Battery folder next to the ROM path.
  Chains never parses the footer; the snapshot is the full file bytes, so
  round-trips stay byte-identical and `verify` re-hashes the whole thing.
- **DuckStation** memory cards default to `*.mcr` (128 KB raw dumps, one
  per card slot); per-game cards use the same format, so they track
  automatically.
- **PCSX2** memory cards default to `*.ps2` (raw dumps, one per slot —
  8 MB default, 16 MB for extended cards). Like everything else, they
  round-trip as opaque bytes; the full card is one snapshot blob, so an
  8 MB card costs 8 MB of vault per unique state — dedupe still applies,
  but note the card is one commit-granularity blob, not per-game.
- **Dolphin** exports per-game GameCube saves as `*.gci` (whole-block files,
  8 KB per block; first 4 bytes are the game's 4-letter ID, e.g. `GM8E`).
  Raw memory-card dumps (`*.raw`) are *not* tracked — one `*.gci` per game
  is the portable unit, and the opaque-bytes rule means a card dump would
  still round-trip as a blob if tracked manually.
- **PPSSPP** save states (`*.ppst`, slots 0–4) are emulator-version snapshots
  like everything under `*.state*` — not portable across PPSSPP versions.
  They live in `PSP/PPSSPP_STATE/` next to a same-basename `.png` thumbnail
  (untracked) and an optional `.undo.ppst` autosave variant (tracked, same
  extension). PPSSPP's *in-game* saves are whole folders under
  `PSP/SAVEDATA/<GAMEID>/`, not single files, so Chains versions the state,
  not the folder.
- **RetroArch** save locations vary per core and per config (`saves/` under
  the config dir by default); `watch -Known` covers the defaults, explicit
  `watch -Add` covers the rest.
- **BizHawk** multi-system saves use `.SaveRAM` (tracked); like
  everything else, they round-trip as opaque bytes — never parsed.
- **N64**: Project64/mupen64plus battery saves are SRAM (`.sra`, 32 KB),
  EEPROM (`.eep`, 2 KB / 512-byte), or FlashRAM (`.fla`, 128 KB) dumps —
  three extensions for the three save types the hardware used. Chains
  tracks all three; Controller Pak files (`.mpk`) are *not* tracked, since
  they're peripheral data rather than cartridge battery saves.

## Non-goals

Chains will never parse, patch, or "fix" a save file. Anything that needs to
understand game data (editors, converters) belongs in another tool.

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
| `.dsv` | NDS | 512 KB typical (flash size varies per game) | DeSmuME | Raw save + small DeSmuME footer; Chains stores the bytes opaquely |
| `.sra` | N64 | 32 KB | Project64, mupen64plus, RetroArch (ParaLLEl core) | SRAM dump, no header |
| `.eep` | N64 | 2 KB (512-byte for some games) | Project64, mupen64plus, RetroArch (ParaLLEl core) | EEPROM dump, no header |
| `.fla` | N64 | 128 KB | Project64, mupen64plus, RetroArch (ParaLLEl core) | FlashRAM dump, no header |
| `.SaveRAM` | multi-system | varies per system (e.g. 8/32 KB SNES SRAM) | BizHawk | Raw SaveRAM dump written next to the ROM (e.g. `Game.SaveRAM`); matched case-insensitively |

Battery saves are the future-proof format: any emulator for the system can
read them. Chains' guidance is **save in-game, not just save-state**.

## Save states (opaque, version-sensitive)

`*.state*` files are emulator-internal snapshots (CPU, PPU, memory, etc.).
They are **not portable across emulator versions** — a state from Snes9x
1.60 may not load in 1.62. Chains versions them like anything else, but the
bytes are only guaranteed meaningful to the emulator build that wrote them.

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
  `*.state*` / `*.mcr` / `*.dsv` / `*.sra` / `*.eep` / `*.fla`).
- **DeSmuME** writes `.dsv` battery saves (raw flash data plus a small
  DeSmuME footer) — by default in its Battery folder next to the ROM path.
  Chains never parses the footer; the snapshot is the full file bytes, so
  round-trips stay byte-identical and `verify` re-hashes the whole thing.
- **DuckStation** memory cards default to `*.mcr` (128 KB raw dumps, one
  per card slot); per-game cards use the same format, so they track
  automatically.
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

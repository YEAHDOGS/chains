# Chains — "git for save data"

*Never lose a game save again.*

Chains is version control for emulator save files: snapshot them, write a message about where you are in the game, browse history, diff two points in time byte-for-byte, and restore any commit. It was born the night a save got lost.

## Quick Start

```powershell
cd ~\Documents           # or wherever you want the vault to live
.\chains.ps1 init
.\chains.ps1 watch -Known        # auto-find RetroArch / mGBA / Snes9x save dirs
.\chains.ps1 watch -Add "D:\roms\saves"   # ...or point at any folder

# ...play...

.\chains.ps1 commit -m "beat the Elite Four, Mewtwo next"
.\chains.ps1 status              # what changed since last commit
.\chains.ps1 log                 # history
.\chains.ps1 diff a1b2c3 d4e5f6  # what changed between commits
.\chains.ps1 restore a1b2c3      # go back (auto-backs up current state first)
.\chains.ps1 verify              # prove the journal + snapshots are untampered
```

## What Gets Tracked

Battery saves and save states — the files that hold *your progress*:

| System | Battery save | Emulators |
|---|---|---|
| SNES | `.srm` | Snes9x, RetroArch (Snes9x/bsnes cores), BizHawk |
| GBA | `.sav` | mGBA, VBA-M, RetroArch (mGBA/VBA cores) |
| N64 | `.sra` / `.eep` / `.fla` | Project64, mupen64plus, RetroArch (ParaLLEl core) |
| PSX | `.mcr` | DuckStation, ePSXe, RetroArch (Beetle PSX core) |
| PS2 | `.ps2` | PCSX2, RetroArch (PCSX2 core) |
| GameCube | `.gci` | Dolphin, RetroArch (Dolphin core) |
| NDS | `.dsv` | DeSmuME |
| Any (BizHawk) | `.SaveRAM` | BizHawk (multi-system SaveRAM dumps) |
| Any | `.state*` | save states (emulator-specific, less portable) |

Tracked patterns: `*.srm`, `*.sav`, `*.state*`, `*.mcr`, `*.ps2`, `*.gci`, `*.dsv`, `*.SaveRAM`, `*.sra`, `*.eep`, `*.fla`. Only save data is ever stored — **never ROMs or firmware** (those live in the separate `arcade/` project).

> Save states are emulator-version-sensitive; battery saves (`.srm`/`.sav`) are the portable, future-proof format. When in doubt, save in-game, not just save-state.

## How It Works

A vault is any directory containing `.chains/`:

```text
.chains/
├── config.json        # version, watch paths
├── journal.jsonl      # append-only history: one JSON object per commit
└── snapshots/<sha256> # full file bytes, content-addressed (saves are KBs,
                       # so full snapshots beat binary deltas -- simple + robust)
```

- **commit** scans watched dirs, hashes every save (SHA256), stores unseen blobs, appends a journal entry. Identical tree → "nothing to commit".
- **diff** reports added / deleted / modified files with size deltas *and* a byte-level "N of M bytes differ" summary (skipped over 4 MB).
- **restore** auto-commits the current state as `pre-restore auto-backup` first, then writes the commit's blobs back. You can always undo a restore.
- **verify** re-derives every commit id from its parent id, timestamp, message, and file list — any edit to the journal breaks the chain — and re-hashes every stored blob against its recorded SHA256, catching silent snapshot corruption. The `verify` command exits non-zero on failure, so it can run in scripts.
- Commits are addressable by full id or unique prefix, plus `HEAD`.

## Cloud Sync

The sync story is specified in [SYNC.md](SYNC.md). Short version:

1. **LAN vault (now):** the vault directory can live on a Castle network share, so every machine on the LAN sees the same history.
2. **Local remote sync (now):** `.\chains.ps1 push -Remote <dir>` / `.\chains.ps1 fetch -Remote <dir>` move journal + blobs through any directory (USB stick, LAN share, mounted cloud drive). Offline-first, no network code in the engine — default-deny. A bash twin (`bash scripts/chains-sync.sh <vault> <remote> --direction push|fetch`) implements the same contract and writes cross-compatible pins. Preview what a sync would do first with `bash scripts/chains-sync-plan.sh <vault> <remote>` — read-only, shows the exact commits and blobs that would transfer plus the pin verdict.
3. **Network sync (next):** journal + content-addressed blobs map 1:1 onto a sync server: `PUT /sync/upload/chains/<vault-id>/<sha256>`, journal as the manifest. Blobs dedupe globally by hash.
4. **Offsite tier (future):** encrypted offsite replication of the vault directory — your saves survive a house fire.

Conflict policy: commits are content-addressed and the journal is append-only, so merges are last-writer-wins on the journal with both histories preserved — same shape as git, minus the DAG.

## Non-goals

- Not a ROM/firmware manager.
- Not netplay or multiplayer state sync.
- No account, no telemetry — your saves are yours.

## Roadmap

- `push`/`pull` against a network sync server (local-filesystem remote ships now — see SYNC.md).
- Scheduled auto-commit (e.g. commit on emulator exit / every 30 min).
- GUI client.
- More systems: GBC/GB (`.sav`, already tracked — melonDS NDS battery
  saves use `.sav` too, also tracked).

## Tests

`tests/chains.Tests.ps1` is a Pester v5 suite locking in the save → commit → diff → restore cycle. Run it with:

```powershell
Invoke-Pester -Path ./tests
```

Every test builds a throwaway vault under the OS temp folder — nothing touches real saves.

## Origin

Chains started life as the `saves/` module ("SaveVault") inside the Castle repo, then moved out to stand on its own.

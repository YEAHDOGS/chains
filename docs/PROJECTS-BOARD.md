# Chains — GitHub Projects Board Draft

Brando: the board still needs to be created in the YEAHDOGS org. One-click
recipe: Projects → New project → Board → name it **Chains**, create these
columns, then copy the cards below into them. This file stays in the repo
as the source of truth for the board's contents.

## Columns

`Now` · `Next` · `Later` · `Done`

## Now

- **Network sync backend** — implement `push`/`fetch` against a real sync
  server per [SYNC.md](SYNC.md)'s backend contract (`PUT /sync/upload/chains/<vault-id>/<sha256>`,
  journal as manifest). Requirements from the contract: TLS, token auth,
  default-deny (explicit opt-in, never silent). Local-filesystem backend
  already ships (`scripts/chains-sync.sh`).
- **Scheduled auto-commit** — commit on emulator exit and/or every 30 min
  while watched files change. Start with a watcher script (inotify on
  Linux, scheduled-task trigger on Windows) that runs `chains.ps1 commit`
  only when the tree is dirty ("nothing to commit" otherwise).
- **PSX tracking follow-through** — `*.mcr` landed in `$SavePatterns`;
  needs a Windows-side Pester case proving commit/restore round-trips a
  128 KB memory-card blob byte-identical (bash side can't run Pester).

## Next

- **GUI client** — his stack: Svelte + Tauri. Timeline view of commits,
  diff preview, one-click restore with the pre-restore auto-backup shown.
- **Encrypted offsite replication** — encrypted mirror of the vault
  directory (survive a house fire). Ties into Castle's offsite story.
- **More save formats** — BizHawk `.SaveRAM` (proposed in
  [SAVE-FORMATS.md](SAVE-FORMATS.md)), NDS `.dsv`, N64 `.sra` /
  Controller-Pak files. Each addition must also update
  `tests/test-save-patterns.sh`'s documented-pattern check.
- **Push/fetch over SSH/SFTP** — second network backend behind the same
  contract; ships as a separate script so the engine stays network-free.

## Later

- **Restore-conflict UX** — fetch merges are last-writer-wins on the
  journal; surface a "which history won, what to keep" view for
  divergent trees.
- **Save-file health dashboard** — `chains-doctor.sh` output as a small
  web report (saves untracked, corrupt-looking files, disk stats).
- **Diff viewer for humans** — byte-diff summaries are opaque; research
  game-agnostic visualizers (heatmaps of changed regions) without parsing
  game data.

## Done

- Local-filesystem remote sync: `chains-sync.sh` push/fetch (45 tests green)
- `chains-sync-plan.sh` read-only dry run (31 tests green)
- `chains-doctor.sh` vault health checks (test suite green)
- PSX memory-card (`.mcr`) tracking + pattern-docs regression test
- This board draft (`docs/PROJECTS-BOARD.md`)

# chains doctor

`scripts/chains-doctor.sh` is a dependency-free health check for a Chains
vault. It exists for the moments PowerShell isn't around — a Linux rescue
boot, a headless Castle box, a quick sanity check before a risky restore.
By default it reads and never writes. `--fix` performs a small, bounded
set of safe, reversible repairs (see below); everything else stays
report-only.

## Usage

```bash
bash scripts/chains-doctor.sh [vault-root] [--fix] [--json]
```

`vault-root` is the directory containing `.chains/` (default: current
directory). Exit codes: **0** healthy, **1** warnings only, **2** errors.
With `--fix`, the exit code still reflects the **pre-repair** scan — re-run
the doctor to confirm the vault is clean afterwards.
on stdout and nothing else, with the same exit codes and the same findings
as the human report — pipe it into scripts, cron jobs, or CI:

```json
{
  "vault": "/path/to/vault",
  "result": "healthy",        // "healthy" | "warnings" | "errors"
  "exit": 0,                  // mirrors the process exit code
  "errors": 0,
  "warnings": 0,
  "findings": [
    { "severity": "ok", "message": "config.json parses" }
  ],
  "summary": {
    "commit_count": 2,
    "blob_count": 2,
    "pin_count": 1,
    "head": "b2c3d4e5f6a7",
    "head_files": [ { "key": "...", "rel": "game.srm", "sha256": "..." } ],
    "referenced": [ "<sha256>", "..." ],
    "watch_paths": [ "/path/to/saves" ]
  }
}
```

Finding severities are `ok`, `warn`, `fail`, and `info`. `--json` is
covered by the same read-only contract as the human report: it never
writes inside (or outside) the vault.

Needs only `bash`, `python3` (stdlib), `df`, and `sha256sum`.

## `--fix`: safe, reversible auto-repairs

Without `--fix`, the doctor never writes — the read-only contract holds
and the test suite asserts it on every fixture. With `--fix`, exactly two
repairs run, and **only** these:

1. **Malformed remote pin entries** are deleted from `config.json`.
   A bad pin can't be trusted anyway; the next `push`/`fetch` TOFU-pins
   the remote again. The good pins are untouched.
2. **Orphan snapshots** are *moved* (never deleted) out of `snapshots/`.

Everything else stays report-only: the doctor cannot fabricate missing
blobs, un-edit a tampered journal, or invent commit data — those need the
manual steps below.

**Snapshot-before-repair:** before any write, `--fix` copies
`config.json` and `journal.jsonl` into
`.chains/repair-backups/<utc-timestamp>/` and writes a `repairs.json`
manifest there. Orphan blobs land in `orphans/` inside the backup.
Reversing a repair is a manual copy-back (see the `reverses` field in
the manifest). If the journal is unparseable or `config.json` is not a
JSON object, no repair is attempted at all. Repairs are reported as
ordinary `ok` findings, so `--json --fix` carries them as machine-readable
records too.

## What it checks

| Check | WARN | FAIL |
|---|---|---|
| `config.json` parses | missing `version` | missing / invalid JSON |
| `journal.jsonl` parses | — | missing, unreadable, broken line, entry without id |
| Commit chain (refs) | first entry has a parent | duplicate id, **dangling parent ref** (a commit pointing at a parent that isn't in the journal) |
| Commit id re-derivation | — | **id mismatch** (a journal entry's id doesn't recompute from its parent id, timestamp, message, and file list -- the entry was modified after commit, same check as `chains.ps1 verify`; pre-chain entries without a `parent` field are skipped) |
| Snapshot presence | — | journal names a blob with no file under `snapshots/` |
| Blob byte-identity | — | blob's SHA256 doesn't match its filename (corruption) |
| Orphan snapshots | file on disk referenced by no commit | — |
| HEAD working-tree drift | a file in the newest commit is gone from its watched source path; a file's bytes no longer match the committed blob (**uncommitted changes** -- progress since the last commit); watched path itself missing | — |
| Untracked saves | save file matching one of the engine's tracked patterns under a watched path that is **not in HEAD** (a new game played but never committed -- `restore HEAD` would never bring it back). The doctor reads the pattern list from the engine's `$Script:SavePatterns` when run from the repo | — |
| Remote fingerprint pins | vault synced before but no pins recorded; pin missing fingerprint/timestamp | `remotePins` not an object; pin entry malformed |
| Last-sync staleness | newest pin older than 7 days | — |
| Disk space | under 1 GiB free on the vault's filesystem (`CHAINS_DOCTOR_MIN_FREE_MB` overrides) | — |

A vault that has never synced reports an informational note — first sync
will TOFU-pin the remote, per `SYNC.md`.

## Repair guide (manual steps -- plus what `--fix` automates)

- **Dangling parent ref / broken journal line.** The journal is append-only
  and tamper-evident; a dangling parent means it was hand-edited or
  truncated. Restore `journal.jsonl` from your last known-good copy (or
  fetch the journal from a remote you trust -- its pin will tell you if the
  remote itself was rolled back), then re-run the doctor.
- **Commit id mismatch (integrity check).** A journal entry was modified
  after it was committed -- message, file list, or timestamp rewritten --
  even though the parent refs still line up. The journal is append-only, so
  any rewrite is corruption or tampering: restore `journal.jsonl` from a
  known-good copy or a pinned remote and re-run the doctor. (`chains.ps1
  verify` runs the same re-derivation; the two tools agree.)
- **Missing snapshot blob.** The history references bytes that are gone
  locally. `fetch` the vault from a remote that has them; the engine
  re-hashes every blob against the journal before accepting it. If no
  remote has them, that commit's files are unrecoverable -- the rest of the
  history is still intact.
- **Blob hash mismatch.** Corruption on disk. Same remedy as a missing
  blob: fetch a good copy from a pinned remote.
- **Malformed pin.** Auto-repaired by `--fix`: the offending pin entry is
  deleted from `config.json` (the pre-repair backup keeps the original),
  and the next push re-pins TOFU-style. Manual equivalent: delete the pin
  entry (or the whole `remotePins` object) and push again -- first contact
  is trusted and a fresh pin is recorded. See `SYNC.md` ("Re-trusting a
  remote"); treat it like deleting an SSH known-hosts line.
- **No pins after syncing.** The engine writes pins on the push/fetch
  success path; if they're absent, the sync may never have completed.
  Push/fetch again and re-run the doctor.
- **Stale sync.** Not an error by itself -- just run `push`/`fetch`.
- **Orphan snapshots.** Auto-repaired by `--fix`: unreferenced blobs are
  *moved* (never deleted) into the repair backup's `orphans/` directory,
  so they're recoverable if you ever need them. Unrepaired they're
  harmless; they can never be resurrected into history.
- **Uncommitted changes (working-tree drift).** The emulator wrote to a
  save after your last commit. `commit` the current state to capture the
  progress -- or `restore` the commit to throw the new bytes away (the
  pre-restore auto-backup keeps them recoverable).
- **Save file not tracked in HEAD.** A save exists under a watched path
  that no commit covers -- typically a new game started after your last
  commit. `commit` to bring it into history; if it's junk (a test ROM's
  save), delete it by hand -- the doctor never touches your saves.
- **HEAD files missing from the working tree.** The emulator deleted or
  moved them. Re-save in-game, or `restore` the commit to put the bytes
  back -- the doctor only reports; `chains.ps1 restore` does the writing.

## Regression tests

`tests/test-doctor.sh` builds ten fixture vaults (healthy, dangling
parent, missing pins, stale sync, broken journal line, working-tree
drift, untracked saves, journal tampering, malformed pins, orphan
snapshot) in a temp dir, runs the doctor against each, and asserts exit
codes, report markers, and the read-only contract: a hash of every
fixture file must be identical before and after any run *without*
`--fix`. The `--fix` write path is covered separately: on the healthy
vault it creates no backup and writes nothing; on the tampered vault it
refuses to repair (exit 2, nothing written); on the malformed-pins vault
it deletes exactly the bad pin entries, keeps the good pin, snapshots
the pre-repair `config.json`/`journal.jsonl` into
`.chains/repair-backups/<utc-timestamp>/` with a `repairs.json` manifest,
and a re-run comes back healthy; on the orphan vault it moves the blob
into the backup's `orphans/` directory (recoverable, never deleted) while
committed blobs stay in place. Fixture commit ids are minted with the
same formula as the engine (`mint_id`), so the doctor's id re-derivation
check treats honest fixtures as clean and only flags genuine tampering.
It also runs the doctor with `--json` against the healthy, dangling-parent,
stale-sync, drift, untracked, and tampered fixtures and asserts the JSON
document parses, carries the same exit/result verdicts, has a valid
findings schema, and emits no human-format lines. Run it from the repo root:

```bash
bash tests/test-doctor.sh
```

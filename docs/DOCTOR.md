# chains doctor

`scripts/chains-doctor.sh` is a dependency-free health check for a Chains
vault. It exists for the moments PowerShell isn't around — a Linux rescue
boot, a headless Castle box, a quick sanity check before a risky restore.
It reads, it never writes.

## Usage

```bash
bash scripts/chains-doctor.sh [vault-root] [--fix] [--json]
```

`vault-root` is the directory containing `.chains/` (default: current
directory). Exit codes: **0** healthy, **1** warnings only, **2** errors.
`--fix` is accepted for forward compatibility but is report-only in this
pass — the doctor has no write code paths at all, so it cannot modify your
saves even by accident. `--json` prints one machine-readable JSON document
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
| Untracked saves | save file matching `*.srm`/`*.sav`/`*.state*` under a watched path that is **not in HEAD** (a new game played but never committed -- `restore HEAD` would never bring it back) | — |
| Remote fingerprint pins | vault synced before but no pins recorded; pin missing fingerprint/timestamp | `remotePins` not an object; pin entry malformed |
| Last-sync staleness | newest pin older than 7 days | — |
| Disk space | under 1 GiB free on the vault's filesystem (`CHAINS_DOCTOR_MIN_FREE_MB` overrides) | — |

A vault that has never synced reports an informational note — first sync
will TOFU-pin the remote, per `SYNC.md`.

## Repair guide (manual -- the doctor won't do these for you)

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
- **Malformed pin.** Delete the offending pin entry (or the whole
  `remotePins` object) from `.chains/config.json` and push again -- first
  contact is trusted and a fresh pin is recorded. See `SYNC.md`
  ("Re-trusting a remote"); treat it like deleting an SSH known-hosts line.
- **No pins after syncing.** The engine writes pins on the push/fetch
  success path; if they're absent, the sync may never have completed.
  Push/fetch again and re-run the doctor.
- **Stale sync.** Not an error by itself -- just run `push`/`fetch`.
- **Orphan snapshots.** Unreferenced blobs. Harmless; delete them by hand
  only if you need the space (they can never be resurrected into history).
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

`tests/test-doctor.sh` builds eight fixture vaults (healthy, dangling
parent, missing pins, stale sync, broken journal line, working-tree
drift, untracked saves, journal tampering) in a temp dir, runs the doctor
against each, and asserts exit codes, report markers, and the read-only
contract (a hash of every fixture file must be identical before and after
the run, including under `--fix`). Fixture commit ids are minted with the
same formula as the engine (`mint_id`), so the doctor's id re-derivation
check treats honest fixtures as clean and only flags genuine tampering.
It also runs the doctor with `--json` against the healthy, dangling-parent,
stale-sync, drift, untracked, and tampered fixtures and asserts the JSON
document parses, carries the same exit/result verdicts, has a valid
findings schema, and emits no human-format lines. Run it from the repo root:

```bash
bash tests/test-doctor.sh
```

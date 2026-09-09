# Engine port decision: modules/vault.ps1 stays PowerShell

**Decision: DO NOT PORT the engine to bash.** Recorded 2026-09-09 (Phase 2
conversion work). This is a direction, not a suicide pact — the door stays
open, but only when the parity proof below can actually be run.

## Why the bar is "prove id parity or don't port"

Commit ids are the vault format's load-bearing invariant
(`New-SaveCommitId` in `modules/vault.ps1`):

```
id = SHA256("<parent>|<ts>|<message>|<sorted key=sha256 list, comma-joined>")[0:12]
```

Every consumer derives from the id function:

- `Test-SaveChain` (`chains verify`) **re-derives every id** from the stored
  parent/ts/message/file list — any derivation difference reads as tampering.
- Sync pins (`Set-RemotePin`/`Test-RemotePin`) fingerprint the sorted id list;
  `Merge-JournalFile` treats same-id-different-bytes as corruption.
- The bash twins (`chains-doctor.sh` id re-derivation, `chains-sync.sh`
  journal merge) already interoperate with PS-minted vaults on the
  assumption that ids are minted exactly one way.

A bash engine whose ids differ by even one hex char **forks the vault
format**: `verify` fails on honest vaults, sync aborts on honest remotes,
and the two engines can never share a vault. The required proof was:
generate commits with *both* engines on identical fixtures and compare ids
byte-for-byte.

## Why the proof cannot be run here

1. **No PowerShell runtime.** `pwsh` is not installed in this environment,
   and the default-deny rule forbids installing it. The Pester suite
   (`tests/chains.Tests.ps1`, 475 lines) can't run here either.
2. **No engine-minted reference ids exist in the repo.** The doctor fixtures
   mint ids with a Python replica of the formula (`mint_id` in
   `tests/test-doctor.sh`), not with the PS engine — verifying the replica
   against itself is circular, not parity. (Checked via `git log`: the
   "engine-minted fixture ids" commit message means "minted with the
   engine's formula", i.e. the replica.)
3. **The sort order is under-specified.** The id seed sorts `key=sha256`
   strings with PowerShell's `Sort-Object`, which uses .NET
   **culture-sensitive collation** — not byte order, not a portable
   "case-insensitive" order. The order therefore depends on the PS host's
   culture (Windows user locale vs. PS Core on Linux with ICU/invariant).
   The repo's bash replica approximates it with casefold-codepoint order,
   which matched every fixture tried so far — but "case-insensitive" does
   not uniquely determine an order across all inputs (documented .NET
   behavior gives punctuation like hyphens variable collation weight, so
   linguistic order and codepoint order can disagree on realistic keys such
   as `D:\my-saves\game-a.srm` vs `D:\my-saves\gamea.srm`). Without pwsh we
   cannot enumerate the real order, so the approximation cannot be proven
   exact — and an inexact approximation forks vaults.
4. **Journal byte-serialization is part of the interop surface.**
   `Merge-JournalFile`'s tamper check compares `ConvertTo-Json -Compress`
   bytes for same-id entries. A bash engine would have to reproduce that
   serialization byte-for-byte (key order, non-ASCII escaping, control-char
   escapes) — again unverifiable without pwsh. (The existing bash sync twin
   sidesteps this by comparing canonicalized JSON and never re-serializing
   known entries; a minting engine could not sidestep it.)

## What already covers the bash side

Per the project's own philosophy — bash twins exist "for the moments
PowerShell isn't around" (`docs/DOCTOR.md`) — the PS-absent scenarios are
already covered without touching the engine:

- `scripts/chains-doctor.sh` — read-only health check + `--fix` repairs
  (87 tests green), including id re-derivation.
- `scripts/chains-sync.sh` — real push/fetch, cross-compatible pins
  (50 tests green); `scripts/chains-sync-plan.sh` — read-only dry run
  (31 tests green).
- **`chains.sh` (new, repo root)** — bash dispatcher twin of `chains.ps1`:
  same flags, same commands, same exit codes. It parses argv in bash and
  delegates each command to `pwsh` running the one canonical engine, so
  behavior is identical by construction. Fails closed with exit 1 where
  `pwsh` is missing. Tested by `tests/test-chains-sh.sh` (80 assertions,
  pwsh-shim based).

The engine itself works, is tested by the Pester suite, and PowerShell
Core runs it on Linux unchanged. Rewriting 818 lines of tested,
format-critical code on an unprovable parity claim would be the suicide
pact; keeping it is the direction.

## What would reopen this

- A machine with `pwsh` available, generating commits from **both**
  engines on an adversarial fixture corpus: mixed-case keys, hyphenated
  and punctuated filenames, non-ASCII messages and paths, multi-file trees
  where sort order actually varies — then byte-comparing ids *and* journal
  lines.
- A pinned, byte-level spec of the journal serialization (or a move of
  the tamper check to canonical JSON on both sides, as the bash sync twin
  already does).
- Until then: engine stays PowerShell; bash stays at the edges.

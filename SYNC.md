# Chains Sync Contract

How a Chains vault moves between machines. This is the contract every sync
backend implements — the engine itself speaks only this contract, so adding a
new backend (SSH, R2, Castle share) never touches commit/restore/verify logic.

## Design principles

- **Offline-first, default-deny.** The engine contains zero network code.
  The built-in backend is the **local filesystem** (a directory on disk: USB
  stick, Castle LAN share, mounted cloud drive). Network backends are future
  work and must be explicit opt-in — never silent, never third-party mirrors.
- **Manifest + blobs.** The journal (`journal.jsonl`) is the manifest: it
  names every blob every commit needs. Blobs live content-addressed under
  `blobs/<sha256>` and dedupe globally by hash — identical saves on two
  machines upload once.
- **Append-only, id-keyed merge.** Commit ids are content-derived
  (parent id + timestamp + message + file list), so two machines can only
  *agree* on an id if the commit is byte-identical. Sync is a union of both
  journals keyed by id: nothing is ever deleted, both histories survive.
- **Corruption is not a conflict.** The same id with different bytes is
  impossible without tampering — sync aborts loudly instead of "resolving"
  it. Run `chains verify` on both ends afterwards.

## Backend interface

A backend implements two operations over a vault-id namespace:

| Op | Input | Effect |
|---|---|---|
| `push` | local journal + snapshots | remote journal gains any missing entries (appended, ts-ordered); remote gains any missing blobs |
| `fetch` | remote journal + blobs | local journal gains any missing entries (appended, ts-ordered); local gains any missing blobs, **each re-hashed against the journal before acceptance** |

Both ops are idempotent: re-running them transfers nothing new.

### Remote layout (local filesystem backend)

```text
<remote>/vaults/<vault-id>/
├── journal.jsonl      # union of all known commits for the vault
└── blobs/<sha256>     # content-addressed blobs, deduped by hash
```

`<vault-id>` is a GUID minted at `init` (backfilled for older vaults) and
stored in `config.json`. To sync a second machine, point it at the same
vault id: `fetch` remembers it (`config.syncVaultId`), so later `push`/`fetch`
calls need no arguments beyond the remote path.

### Fetch safety

Fetched blobs are staged to a temp dir and SHA256-checked against the
journal *before* the local journal is extended. A tampered or truncated
remote blob aborts the whole fetch — the local vault is never left with
journal entries pointing at bad bytes.

### Remote fingerprint pinning (TOFU)

Hash checks and id-keyed merges stop *forgery*, but not *rollback*: a remote
whose journal was replaced with an older copy (or swapped for a different
vault's journal) would still "merge" cleanly and silently resurrect history
you already had. After every successful push/fetch, the vault pins the set of
commit ids it has seen on that remote root + vault id (`config.json`
→ `remotePins`). The next sync requires every pinned id to still be present
on the remote; a missing id aborts the sync before any local state changes.

- First contact has no pin and is trusted, then pinned on success — same
  trust-on-first-use model as SSH host keys.
- The pin moves forward only on the success path; a failed sync never moves
  it, so a poisoned remote can't launder itself through a retry.
- Pins are per remote root *and* per vault id: one USB stick hosting two
  vaults, or one vault syncing to USB + LAN share, get independent pins.
- Re-trusting a remote: the pin is fail-closed on purpose, so if you
  *legitimately* wipe or migrate a remote (new USB stick, rebuilt share),
  every push/fetch to it will abort with the rollback warning and the pin
  will never move — sync is stuck by design. To re-trust it, delete the pin
  entry (keyed `"<remote root>|<vault id>"`) or the whole `remotePins`
  object from `.chains/config.json`, then push again: first contact is
  trusted and a fresh pin is recorded. Treat this like deleting an SSH
  known-hosts line — only do it when you know why the remote changed.

## Conflict policy

Commits are content-addressed and the journal is append-only, so "conflicts"
are just divergence: machine A commits `x`, machine B commits `y`, neither
has seen the other's. After a push/fetch round-trip both journals contain
`x` and `y` in timestamp order — last-writer-wins on ordering, both histories
preserved. Same shape as git, minus the DAG (there are no branches, only one
append-only line per vault).

## Future backends

The README's HTTP sketch maps 1:1 onto this contract:

- `PUT /sync/upload/chains/<vault-id>/<sha256>` ← push blobs
- journal upload/download ← push/fetch manifest

When a network backend lands, it must: use TLS, authenticate with a token
from the Secure Vault (never chat, never config files), and keep the
local-filesystem backend as the air-gapped fallback. No backend may phone
home, report telemetry, or touch anything outside its vault-id namespace.

## CLI

```powershell
.\chains.ps1 push -Remote "E:\chains-remote"     # upload to a USB stick / LAN share
.\chains.ps1 fetch -Remote "\\CASTLE\chains"     # pull down on another machine
```

### Preview a sync before running it

```bash
bash scripts/chains-sync-plan.sh <vault-root> <remote-root> [--direction push|fetch|both] [--json]
```

The plan is the read-only twin of the doctor: it computes exactly what a
`push`/`fetch` would do — which commit ids would be added each way, which
blobs would transfer and how many bytes — **without writing anything** to the
vault or the remote, and with zero network code (the local-filesystem remote
is the only backend it previews). It also verdicts the same preconditions a
real sync enforces: the TOFU pin check (a rolled-back remote fails the pin
and aborts), same-id-different-bytes collisions (tampering), blobs the
journal names but a side is missing, and an unparseable journal on either
side. Exit codes match the doctor's contract: 0 the plan is clean (sync
would succeed), 1 warnings only (e.g. the remote has no data for this vault
yet — push first), 2 a real sync would abort. `--json` emits a bare plan
document for scripts and CI. Regression suite: `bash tests/test-sync-plan.sh`
(31 assertions; asserts the plan never writes by hashing every fixture file
before and after each run).

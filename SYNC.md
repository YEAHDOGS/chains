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

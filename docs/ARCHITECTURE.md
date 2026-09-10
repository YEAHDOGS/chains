# Chains Architecture Decisions

The load-bearing design choices behind Chains, with the options considered,
the recommendation, and why. Written 2026-09-10 against master plus the
`jack/chains-*` staging branches (doctor, sync, doctor-chainverify,
doctor-patterns); where a decision depends on staging work not yet merged,
it says so.

Guiding principle: **Chains stores opaque bytes and never parses them.**
Most of these decisions follow from that. Anything that needs to understand
game data — editors, converters, cheat patchers — belongs in another tool.

Status key: `ACCEPTED` (do it / already doing it), `PROPOSED` (recommended,
not yet built), `OPEN` (needs Brandon's call).

---

## D1. Storage model — custom content-addressed store, not git plumbing, not SQLite

**Status:** ACCEPTED (implemented: `modules/vault.ps1`; `.chains/snapshots/<sha256>` + `journal.jsonl`).

**Options considered:**

1. **Build on real git plumbing** (loose objects, refs, git-commit on save files).
2. **Custom content-addressed store** — blobs keyed by SHA256, history in an
   append-only journal.
3. **SQLite database** — journal and blob metadata in tables, blobs on disk.

**Recommendation: 2, the custom store.** Rationale, from save-data
constraints:

- **Binary, tiny, frequent writes.** A SNES `.srm` is 8–32 KB, a GBA `.sav`
  32–64 KB, and the natural commit cadence is "every play session". Git's
  delta engine (xdiff) is tuned for text and buys nothing on opaque game
  blobs — it actually costs: delta chains on 8 MB PS2 memory cards or 128 KB
  PSX cards turn restores into CPU work with zero size benefit (a re-saved
  memory card differs in scattered sectors; deltas approach full-file size
  anyway). Full snapshots are simpler and robust: restore is one `Copy-Item`.
- **git plumbing fights us.** We'd inherit text-oriented conveniences we
  don't want (smudge/clean filters, `.gitattributes` binary guesswork) and a
  config surface users can misfire (a `core.autocrlf` accident on a save
  file is corruption). Vendoring libgit2 into PowerShell/bash twins doubles
  the port surface for no gain. Git's object model also assumes a DAG we
  explicitly don't want (see D6).
- **SQLite is the wrong kind of opaque.** The journal must be human-readable,
  hand-repairable, and transmissible as a plain manifest — a corrupted
  `journal.jsonl` can be inspected and surgically edited in Notepad; a
  corrupted SQLite file is a recovery project. Sync needs "send me your
  history" as a trivial stream of lines, not a database diff protocol.

**Trade-offs, honestly:**

- JSONL scans are O(n) per command. At the observed scale (tens of commits,
  one user), this is irrelevant. If it ever matters, the fix is a derived
  index sidecar (e.g. `.chains/index.json` mapping commit id → file offset),
  rebuilt on demand, never the source of truth. **Never index the journal
  into SQLite as primary storage** — that trades the hand-repairability that
  justifies JSONL.
- Full snapshots mean an 8 MB PS2 card costs 8 MB per unique state. Dedupe
  by hash already applies; the experiment that could change this is measuring
  real-world card-change density across sessions. Until that data exists,
  simplicity wins.

**Experiments that would settle the open bits:** log per-commit byte-deltas
vs full-file sizes for memory-card formats over 30 days of real use; if
median delta ratio < 0.2 for cards, consider xdelta3 on *large* blobs only,
keeping small blobs as full snapshots.

---

## D2. Identity model — the tracked unit is the file, not the game

**Status:** ACCEPTED.

A "save" is identified by its **working-tree key**:

```text
<canonical watchdir path>::<relative path, forward slashes>
```

(e.g. `C:/Users/brando/saves::zelda3.srm`). The canonical save record is the
pair `(key, sha256)` recorded in each journal entry.

**Options considered:**

1. **Content hash only** — same bytes, same identity, wherever the file is.
2. **Path + format fingerprint** (chosen).
3. **Sidecar metadata** — a `.chains/meta/<id>.json` declaring game title,
   ROM hash, emulator.

**Why path+hash, not the game:** identity must survive the things users
actually do — the same ROM played in Snes9x on Windows and RetroArch on
Linux produces the same *game progress* in different *files*. Tying identity
to "the game" requires ROM-hash matching and an emulator-aware mapping
layer, which breaks the opaque-bytes principle (we'd need to know which
save belongs to which ROM, and same-basename conventions vary per
emulator). The file key is honest: it names exactly what will be written
back on `restore`.

**Cross-emulator dedupe already falls out of the design:** raw-dump battery
formats (`.srm`, `.sav`, `.sra`) are byte-identical across emulators, so the
same progress stored under two keys shares one blob by content hash. The
journal distinguishes the *keys*; the snapshot store distinguishes the
*bytes*. That separation is the whole trick.

**Normalization rules (normative):**

- Watchdir: the fully resolved canonical path at `watch -Add` time (resolve
  symlinks, strip trailing separators).
- Relative path: forward slashes on all platforms; leading separator trimmed.
- Matching is case-sensitive on Linux, case-insensitive on Windows
  (matches the filesystem); the `.SaveRAM` regression fixture pins the
  case-insensitive behavior on Windows.

**Consequences:** moving or renaming a save file is a delete+add, not a
rename — `diff` shows `- old/+ new`. This is intentional; rename detection
(content-hash cross-referencing between added/deleted keys) is listed as a
future diff enhancement, not an identity feature. Sidecar metadata
(game title, ROM hash) may be added later as *annotation* on keys — never as
primary identity.

---

## D3. Emulator compatibility matrix and the format-extension model

**Status:** ACCEPTED (formats on staging branches; extension model defined here).

### Current matrix

Because storage is opaque bytes, "supporting a format" means *recognizing*
it. Tracked patterns (`$Script:SavePatterns` in `modules/vault.ps1`):

| Pattern | Kind | System | Emulators |
|---|---|---|---|
| `*.srm` | battery | SNES | Snes9x, RetroArch, BizHawk |
| `*.sav` | battery | GBA, GB/GBC | mGBA, VBA-M, RetroArch |
| `*.mcr` | battery | PSX | DuckStation, ePSXe, RetroArch |
| `*.ps2` | battery | PS2 | PCSX2, RetroArch |
| `*.gci` | battery | GameCube | Dolphin, RetroArch |
| `*.dsv` | battery | NDS | DeSmuME |
| `*.sra` / `*.eep` / `*.fla` | battery | N64 | Project64, mupen64plus, RetroArch |
| `*.SaveRAM` | battery | multi | BizHawk |
| `*.vmi` / `*.vms` | battery (paired) | Dreamcast | Flycast, Redream, RetroArch |
| `*.state*` | state | any | generic save states |
| `*.sgm` | state | GBA/GB/GBC | VBA-M |
| `*.zst` | state | SNES | ZSNES |
| `*.savestate` | state | PSX | DuckStation |
| `*.ppst` | state | PSP | PPSSPP |

Caveats live with the formats, not the architecture: save states are
emulator-version-sensitive (a state is only guaranteed loadable by the
build that wrote it); `.zst` collides with the zstd extension (opaque
round-trip, harmless — but keep watch dirs save-only); thumbnails
(`*.png` next to `.ppst`/`.savestate`) and N64 Controller Pak (`.mpk`)
files are deliberately untracked. Detail source:
`docs/SAVE-FORMATS.md` (staging branch `jack/chains-doctor-patterns`).

### The extension model

**A new format is a recipe, not a plugin.** To add one, a contributor
implements exactly three things:

1. **Pattern** — add the glob to the tracked-pattern registry
   (`$Script:SavePatterns` in `modules/vault.ps1`; the bash doctor reads
   the same list from the engine).
2. **Documentation** — one entry in `docs/SAVE-FORMATS.md`: file/pattern,
   system, expected sizes, which emulators, paired-file rules (e.g. VMU
   `.vmi`+`.vms` must be tracked together), thumbnails/sidecars to exclude.
3. **Regression fixture** — a byte-identity round-trip test at real-world
   size through commit→restore, plus any format-specific behavior
   (case-insensitive match, paired-file atomicity). The
   `test-save-patterns.sh` documented-pattern check must keep passing —
   every engine pattern documented, every documented pattern in the engine.

**Why not a runtime plugin system:** there is no parser to plug in. Loading
per-format modules would add a code-loading attack surface (see D5) for
zero behavior. *However*, one forward hook is reserved: if Chains ever needs
format-aware behavior (e.g. GCI per-game identity from the 4-letter game ID
in the header, or state-file version warnings), the hook is a static
per-format descriptor file — data, not code. The engine may one day read
`docs/formats/<name>.json` (pattern, system, size expectations, paired
rules, magic bytes for validation-only checks); it will never `eval` a
contributor's script.

---

## D4. Cloud sync — R2 backend on the SYNC.md contract, union-merge conflicts, client-side encryption

**Status:** PROPOSED (contract + local backend exist; network backend pending).

### Sync to what

**Recommendation: Cloudflare R2** (his stack — S3-compatible API, no egress
fees, he already runs R2 for media). The backend implements the contract in
`SYNC.md` (staging): the journal is the manifest, blobs are PUT by hash,
commit ids are content-derived (parent id + timestamp + message + file
list) so two machines can only agree on an id if the commit is byte-identical.

**Backend rules (non-negotiable):**

- The engine stays network-free. Backends are separate scripts/binaries
  implementing push/fetch; adding R2 never touches commit/restore/verify.
- TLS always; token auth with a token from the Secure Vault (never chat,
  never config files — the `.chains/` dir is synced and shareable, so a
  token in it is a leak by design).
- The local-filesystem backend (`scripts/chains-sync.sh`) remains the
  air-gapped fallback. Default-deny: sync is explicit opt-in per remote,
  never silent, never a third-party mirror.

### Conflict resolution

**There is no "conflict" in the git sense — only divergence.** Machine A
commits `x`, machine B commits `y`, neither has seen the other. Sync takes
the **id-keyed union** of both journals, ordered by timestamp: both
histories survive, nothing is deleted. Last-writer-wins applies only to
*ordering*, never to content.

- **Corruption is not a conflict.** Same id + different bytes is impossible
  without tampering; sync aborts loudly (fetch re-hashes every blob against
  the journal before accepting it). `chains.ps1 verify` and the doctor's
  id re-derivation check are the adjudicators.
- **Rollback is not a conflict.** A remote whose journal was replaced with
  an older copy merges "cleanly" but silently resurrects history — defeated
  by TOFU remote fingerprint pins (`remotePins` in `config.json`, staging):
  the next sync requires every pinned commit id to still be present.
- **Divergent saves** (two histories both contain different bytes for the
  same key) are *not* auto-merged — binary saves can't be merged. The UX
  contract: surface both, show the byte-diff summary, make the user pick
  which commit to restore. The doctor's drift check already reports
  uncommitted working-tree changes; the "which history won, what to keep"
  view is on the projects board (`docs/PROJECTS-BOARD.md`, staging).

### Encryption at rest

**Recommendation: encrypt blobs client-side before upload; the remote never
sees plaintext.** Decisions:

- **Algorithm:** age-style authenticated encryption (XChaCha20-Poly1305) or
  libsodium `crypto_secretbox`. Exact library is OPEN — the PowerShell/bash
  engine has no crypto binding today, so the R2 backend (new code) is where
  the choice lives. Experiment: benchmark age vs libsodium bindings usable
  from the Tauri/Svelte GUI and the bash backend; pick one, use it
  everywhere.
- **Keys live in the OS secure store** (Windows Credential Manager, macOS
  keychain, Linux libsecret via the GUI; CLI reads from env or a
  `0600`-permissioned file) — **never** in the vault directory, never in a
  journal, never in git, never in chat. Per-vault data key, generated at
  first encrypted push; the same key must be present on every machine that
  syncs that vault (export/import via the GUI as an explicit user action).
- Filenames on the remote are the SHA256 hex digests — content-derived,
  game-anonymous. The journal is also encrypted as one unit (it leaks
  filenames and timestamps otherwise). Local vault stays plaintext
  (convenience + the doctor needs to read it); encryption is a transport/
  remote-storage property.

**Honest gap:** the threat model is casual-cloud-storage snooping and
house-fire survival, not nation-state. If Brandon wants zero-trust against
the storage provider, that's the current design; if he wants deniability
of game libraries, per-blob padding to fixed size classes would be needed
— not currently recommended (cost/benefit).

---

## D5. Security model — untrusted bytes in, no parsers, no execution

**Status:** ACCEPTED (engine), PROPOSED (network backends).

Chains ingests the scariest input class there is: **binary blobs downloaded
from the internet** (save files from forums, Discord, GameFAQs-style
archives). The security posture is layered:

1. **No parsing is the primary defense.** The engine never interprets save
   bytes — no struct unpacking, no header checks, no format sniffing. A
   malformed blob is just bytes that round-trip. The largest class of
   binary-parser vulnerabilities (buffer overflows, integer overflows in
   length fields) cannot exist in code that doesn't parse.
2. **Never execute.** Save files are data. No emulator launching from
   Chains, no auto-run on commit/restore, no script evaluation of anything
   derived from a save (filenames included — see below).
3. **Size caps.** Ingest refuses single files above a hard cap (PROPOSED:
   1 GiB; `diff` already skips byte-diffing above 4 MB) so a malicious
   100 GB "save" can't fill the disk during commit or fetch. Journal lines
   are length-capped before JSON parsing (PROPOSED) to bound the doctor's
   and engine's memory on a hostile journal.
4. **Path safety.** Blob filenames are strictly `^[0-9a-f]{64}$` — a blob
   named `../../evil` is rejected before any filesystem touch. Restore
   writes only under the watchdir recorded in the key, and the resolved
   destination must stay under that watchdir (PROPOSED: canonicalize and
   re-check — defends against a tampered journal carrying `..` in `rel`).
   The scanner does not follow symlinks out of watched dirs (PROPOSED).
5. **Fetch-before-trust.** Fetched blobs are staged to a temp dir and
   SHA256-checked against the journal *before* the local journal is
   extended; a tampered remote blob aborts the whole fetch. TOFU pins
   defeat rollback (D4).
6. **Dependency minimalism.** The doctor needs only bash + python3 stdlib +
   sha256sum; the engine only PowerShell stdlib. No new dependency may be
   added for security-adjacent work without the default-deny review
   (no third-party mirrors, no unfamiliar hosts — Brando's rule).

**Audit surface, stated plainly:** the PowerShell JSON parsing of
`journal.jsonl` (`ConvertFrom-Json`) and the restore path are the two
places to re-audit whenever the journal schema changes. `chains.ps1 verify`
plus `chains-doctor.sh` are the integrity loop; both must agree on the
commit-id formula (the doctor's test suite mints fixtures with the same
formula — that cross-check is a regression requirement, not a nicety).

**Secret scan:** vaults must never contain tokens, ROMs, or firmware. The
doctor's untracked-save scan and the PII blocklist discipline apply: any
future scanner addition gets a "never track" denylist (`*.rom`, `*.iso`,
`*.chd`, firmware names) — PROPOSED, belongs on the board.

---

## D6. Versioning semantics — commits are whole-tree checkpoints; branches become tags

**Status:** ACCEPTED (commits), PROPOSED (tags).

**What a commit is:** a point-in-time snapshot of the *entire watched
tree*, not a per-file version. One command — `commit -m "beat the Elite
Four, Mewtwo next"` — freezes every save at once. The commit id is derived
from parent id + timestamp + message + sorted file list (staging branch
`jack/chains-doctor-chainverify`; master still mints without the parent
link — the parent-linked formula is the ACCEPTED direction), making the
journal tamper-evident: editing a committed entry changes its id, which the
doctor's re-derivation check and `chains.ps1 verify` both catch.

**Why whole-tree:** saves are interdependent in practice (the SNES `.srm`
and the save state you made at the same boss are one *moment*). Per-file
commits would let the tree drift into combinations that never existed.

**Branching:** not a DAG — and deliberately so. The branching use case for
saves is "before a boss fight," i.e. **named checkpoints**, not parallel
development. **Recommendation: tags, not branches.** `chains.ps1 tag
boss-fight` writes a named pointer to a commit id (stored in
`config.json` or a `tags` file; PROPOSED). Tags give the user the entire
workflow — `restore boss-fight` — with none of the DAG machinery, none of
the merge semantics that make no sense for binary blobs, and a sync story
that stays a simple id-keyed union. Full branching is deferred until a real
use case appears (e.g. collaborative/netplay-adjacent workflows); inventing
it now would be speculative complexity.

**Diffing binary saves:** `diff` reports added/deleted/modified with size
deltas plus a byte-level "N of M bytes differ" summary (skipped over 4 MB).
That's the honest ceiling for opaque bytes. The human-friendly future is a
**game-agnostic heatmap of changed regions** (which offsets moved, how much)
— visualization without parsing, explicitly not a semantic diff. Any
semantic diff ("you gained 3 levels") requires game-specific knowledge and
belongs in another tool.

**Restore safety:** `restore` auto-commits the current tree as
`pre-restore auto-backup` first — every restore is itself undoable. The
journal's append-only rule means history is never rewritten by a restore.

---

## Decision index

| ID | Question | Decision | Status |
|---|---|---|---|
| D1 | Storage model | Custom CAS: `snapshots/<sha256>` + append-only `journal.jsonl`; no git plumbing, no SQLite primary | ACCEPTED |
| D2 | Identity model | File key `<watchdir>::<relpath>` + content hash; identity is the file, cross-emulator dedupe by hash | ACCEPTED |
| D3 | Format extension | Recipe = pattern + docs entry + regression fixture; no runtime plugins; static descriptor hook reserved | ACCEPTED |
| D4 | Cloud sync | R2 backend on the SYNC.md contract; id-keyed union merge; client-side encryption, keys in OS secure store | PROPOSED |
| D5 | Security | Opaque bytes, never parse/execute; size caps; strict blob naming; fetch-before-trust; TOFU rollback pins | ACCEPTED/PROPOSED |
| D6 | Versioning | Whole-tree commits, tamper-evident ids, tags-not-branches, byte-level diff summaries | ACCEPTED/PROPOSED |

## Open questions for Brandon

1. **R2 as the sync backend** — green-light the Cloudflare R2 network
   backend (D4), or stay local-filesystem-only for now?
2. **Encryption library** — age vs libsodium for the client-side blob
   encryption; the choice also affects the Tauri GUI.
3. **Tags** — is the `tag`/`restore <tag>` workflow (D6) the right shape for
   "before a boss fight" checkpoints, or do you want real branches?
4. **Never-track denylist** — confirm the ROM/firmware denylist (D5)
   belongs in the scanner.
5. **GUI priority** — the Svelte+Tauri timeline client is on the board;
   where does it rank vs the R2 backend?

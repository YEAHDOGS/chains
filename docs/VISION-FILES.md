# Chains Vision: Chain of Custody for Every File

*Dictated 2026-09-10. Vision only — not a build order.*

## The expansion

Chains started as version control for game saves. In theory the same model
expands to **all files**: snapshot, hash, parent pointer, message. A save file
is just a file. The machinery doesn't care what the bytes mean.

## Every file has a chain of command

Every file carries a chain of custody whether we show it or not:

- **who** created it, who touched it, who touched it last
- **when** each touch happened
- **what** changed between touches
- **which** revision this is (the count)

Two anchors hold the whole thing up:

1. **User accounts.** Identity is the foundation — a chain of custody with no
   "who" is just a pile of timestamps. Every link in the chain is pinned to
   an account.
2. **Counts.** Version/edit counts are tremendously important. The revision
   number is what makes the sequence a *chain* instead of a rumor — you can
   point at revision 14 and know exactly what came before and after.

## The OS already knows (but won't tell you)

This isn't science fiction. Windows already tracks most of it:

- **USN Change Journal** — a per-volume log of every file change
- **File History** — periodic versioned backups
- **Volume Shadow Copy (VSS)** — point-in-time snapshots

But none of it is a *premier* part of the operating system. It's buried:
no first-class UI, no user-facing timeline, no "show me this file's history"
that a normal person can reach. Forensics tools walk in and read it all day
long — the data is sitting right there. The user just isn't allowed to see it.

## The principle: be transparent about it

Whatever we build here should be **transparent about the chain**:

- Every file shows its custody chain on demand — no forensics license required.
- Nothing hidden, nothing "trust us." The history is the feature.
- The user owns their file history the way they own their files.

## What this is not (yet)

- Not a replacement for backups (that's still the vault's job).
- Not surveillance — the chain belongs to the file's owner, on their machine.

## Update 2026-09-11 — the expansion shipped (part 1)

General file versioning landed: a vault's tracked set is now two glob
lists (`includePatterns` / `excludePatterns` in `config.json`), managed
with the `patterns` command; the save-data patterns remain the defaults,
so existing vaults behave exactly as before. Every commit now carries a
**revision number** (`seq`, monotonic per journal) and a snapshot of the
patterns in effect — the "which revision / what was tracked when" half of
the chain-of-custody vision, recorded in the journal itself. Both fields
are optional and backward-compatible: old entries verify, merge, and sync
exactly as before.

Still open: the **who** (user-account identity pinned to each link), the
OS-level surfacing (this is the layer destined for Castle OS), and the
naming question ("Gasoline" was floated in dictation — still unconfirmed,
so nothing is named that anywhere).

## Open questions

- Where does the chain live? (Sidecar ledger, filesystem xattrs/ADS, vault DB?)
- How do we handle files that move across machines / accounts?
- What does "restore revision N of any file" look like in the UI?
- Name for this expanded scope: ??? (dictation said something like "Gasoline"
  — confirm what was meant before naming anything)

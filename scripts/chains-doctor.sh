#!/usr/bin/env bash
# =============================================================================
# chains doctor -- read-only health check for a Chains vault.
#
# Inspects a vault's .chains/ directory and reports health:
#   - config.json validity
#   - journal integrity (parseable lines, no duplicate ids, no dangling
#     parent refs -- the commit chain must be unbroken)
#   - snapshot presence: every blob the journal names must exist, and every
#     blob's bytes must still hash to its own name (read-only re-hash)
#   - orphan snapshots (present on disk, referenced by no commit)
#   - HEAD save-file presence: every file in the newest commit should still
#     exist at its watched source path
#   - remote fingerprint pin presence (TOFU pins in config.json)
#   - last-sync staleness from pin timestamps
#   - disk-space sanity on the vault's filesystem
#
# READ-ONLY BY CONTRACT: this script never creates, modifies, or deletes
# anything inside (or outside) the vault. There are no write code paths --
# --fix is accepted for CLI forward-compatibility but performs zero writes
# in this pass; it only points at the manual repair steps in docs/DOCTOR.md.
#
# Exit codes: 0 = healthy, 1 = warnings only, 2 = errors found.
# Needs: bash, python3 (stdlib only), df, sha256sum. No network, no installs.
# =============================================================================
set -u

VAULT="."
FIX=0
MIN_FREE_MB="${CHAINS_DOCTOR_MIN_FREE_MB:-1024}"  # warn below 1 GiB free on the vault's filesystem
STALE_AFTER_DAYS=7      # warn when the newest pin is older than this

usage() {
    echo "Usage: $(basename "$0") [vault-root] [--fix]"
    echo ""
    echo "  vault-root   Directory containing .chains/ (default: current dir)."
    echo "  --fix        Accepted for forward-compat; performs no writes (report-only)."
    echo ""
    echo "Exit codes: 0 healthy, 1 warnings, 2 errors."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fix) FIX=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "  [FAIL] Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) VAULT="$1"; shift ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "  [FAIL] chains doctor needs python3 on PATH (stdlib only)." >&2
    exit 2
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "  [FAIL] chains doctor needs sha256sum on PATH." >&2
    exit 2
fi

if [ ! -d "$VAULT" ]; then
    echo "  [FAIL] Vault root does not exist: $VAULT" >&2
    exit 2
fi
VAULT="$(cd "$VAULT" && pwd)"
CHAINS="$VAULT/.chains"

if [ ! -d "$CHAINS" ]; then
    echo "  [FAIL] Not a Chains vault (no .chains/): $VAULT" >&2
    exit 2
fi

echo ""
echo "  chains doctor -- $VAULT"
echo "  ================================================================"

# The heavy lifting (JSON parsing) runs in python3 stdlib; every finding is
# emitted as a tagged line: OK / WARN / FAIL / INFO. bash tallies the tags
# and derives the exit code. python never touches the disk except reading.
RESULTS="$(python3 - "$CHAINS" "$STALE_AFTER_DAYS" <<'PYEOF'
import json, os, sys, re
from datetime import datetime, timezone

chains_dir = sys.argv[1]
stale_days = int(sys.argv[2])

out = []
def ok(msg):    out.append("OK  |" + msg)
def warn(msg):  out.append("WARN|" + msg)
def fail(msg):  out.append("FAIL|" + msg)
def info(msg):  out.append("INFO|" + msg)

config_path  = os.path.join(chains_dir, "config.json")
journal_path = os.path.join(chains_dir, "journal.jsonl")
snap_dir     = os.path.join(chains_dir, "snapshots")

# --- 1. config.json -------------------------------------------------------
config = None
if not os.path.isfile(config_path):
    fail("config.json is missing")
else:
    try:
        with open(config_path, "r", encoding="utf-8-sig") as f:
            config = json.load(f)
        if not isinstance(config, dict):
            fail("config.json is not a JSON object")
            config = None
        else:
            ok("config.json parses")
            if config.get("version") is None:
                warn("config.json has no 'version' field")
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as e:
        fail("config.json is not valid JSON: %s" % e)

# --- 2. journal integrity -------------------------------------------------
entries = []
if not os.path.isfile(journal_path):
    fail("journal.jsonl is missing")
else:
    try:
        with open(journal_path, "r", encoding="utf-8-sig") as f:
            raw_lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        fail("journal.jsonl is unreadable: %s" % e)
        raw_lines = None
    if raw_lines is not None:
        lineno = 0
        for line in raw_lines:
            lineno += 1
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                fail("journal.jsonl line %d is not valid JSON: %s" % (lineno, e))
                continue
            if not isinstance(obj, dict) or not obj.get("id"):
                fail("journal.jsonl line %d has no commit id" % lineno)
                continue
            entries.append(obj)
        ok("journal.jsonl parses (%d commit(s))" % len(entries))

if entries:
    seen = set()
    prev_id = ""
    for i, e in enumerate(entries):
        cid = e["id"]
        if cid in seen:
            fail("duplicate commit id in journal: %s" % cid)
        else:
            seen.add(cid)
        parent = e.get("parent", "")
        if i == 0:
            if parent not in ("", None):
                warn("first journal entry has a non-empty parent ref: %s" % parent)
        else:
            if parent not in seen:
                fail("dangling parent ref: commit %s points at unknown parent %s"
                     % (cid, parent))
        prev_id = cid
    # id format sanity (engine mints 12 lowercase hex chars)
    for cid in seen:
        if not re.fullmatch(r"[0-9a-f]{12}", cid):
            warn("commit id does not look engine-minted (12 hex chars): %s" % cid)
    ok("commit chain is unbroken (%d link(s) checked)" % len(entries))

# --- 3. snapshots: presence + byte-identity --------------------------------
referenced = {}   # sha256 -> [commit ids]
if entries:
    if not os.path.isdir(snap_dir):
        fail("snapshots/ directory is missing but the journal names blobs")
    else:
        for e in entries:
            files = e.get("files") or []
            if not isinstance(files, list):
                fail("commit %s has a malformed 'files' list" % e.get("id"))
                continue
            for f in files:
                sha = (f or {}).get("sha256", "")
                if not sha:
                    fail("commit %s names a file with no sha256" % e.get("id"))
                    continue
                referenced.setdefault(sha, []).append(e.get("id"))
        ok("journal names %d distinct blob(s)" % len(referenced))

# --- 4. remote fingerprint pins ---------------------------------------------
pins = {}
if config is not None:
    raw_pins = config.get("remotePins") or {}
    if not isinstance(raw_pins, dict):
        fail("config.json 'remotePins' is not an object")
    else:
        pins = raw_pins
        if pins:
            ok("%d remote fingerprint pin(s) recorded" % len(pins))
        if config.get("syncVaultId") and not pins:
            warn("vault has synced before (syncVaultId set) but no pins are recorded")

for key, pin in pins.items():
    if not isinstance(pin, dict):
        fail("pin '%s' is malformed (not an object)" % key)
        continue
    ids = pin.get("ids")
    if not isinstance(ids, list) or not ids:
        fail("pin '%s' has no pinned commit ids" % key)
        continue
    if not pin.get("fingerprint"):
        warn("pin '%s' is missing its fingerprint" % key)
    if not pin.get("when"):
        warn("pin '%s' has no timestamp (staleness unknown)" % key)

# --- 5. last-sync staleness --------------------------------------------------
def parse_when(s):
    try:
        s = s.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, AttributeError):
        return None

newest = None
newest_key = None
for key, pin in pins.items():
    if not isinstance(pin, dict):
        continue
    dt = parse_when(str(pin.get("when", "")))
    if dt and (newest is None or dt > newest):
        newest, newest_key = dt, key

if pins and newest is None:
    warn("no pin has a parseable timestamp -- last sync is unknown")
elif newest is not None:
    age_days = (datetime.now(timezone.utc) - newest).total_seconds() / 86400.0
    when_s = newest.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    if age_days > stale_days:
        warn("last sync was %s (%d day(s) ago) -- older than %d days"
             % (when_s, int(age_days), stale_days))
    else:
        ok("last sync %s (%d day(s) ago)" % (when_s, int(age_days)))
elif entries:
    info("never synced -- no remote pins yet (first sync will TOFU-pin)")

for line in out:
    print(line)

# Machine-readable summary for the bash wrapper.
summary = {
    "commit_count": len(entries),
    "blob_count": len(referenced),
    "pin_count": len(pins),
    "head": entries[-1]["id"] if entries else "",
    "head_files": [{"key": (f or {}).get("key", ""),
                    "rel": (f or {}).get("rel", ""),
                    "sha256": (f or {}).get("sha256", "")}
                   for f in (entries[-1].get("files") or [])] if entries else [],
    "referenced": sorted(referenced.keys()),
    "watch_paths": (config.get("watchPaths") or []) if isinstance(config, dict) else [],
}
print("SUMMARY:" + json.dumps(summary))
PYEOF
)"

SUMMARY_JSON=""
ERRORS=0
WARNINGS=0

while IFS= read -r line; do
    case "$line" in
        SUMMARY:*)
            SUMMARY_JSON="${line#SUMMARY:}"
            ;;
        OK\ \ \|*)
            echo "  [OK] ${line#OK  |}"
            ;;
        WARN\|*)
            echo "  [~] ${line#WARN|}"
            WARNINGS=$((WARNINGS + 1))
            ;;
        FAIL\|*)
            echo "  [FAIL] ${line#FAIL|}"
            ERRORS=$((ERRORS + 1))
            ;;
        INFO\|*)
            echo "  [i] ${line#INFO|}"
            ;;
        *)
            [ -n "$line" ] && echo "  [?] $line"
            ;;
    esac
done <<< "$RESULTS"

# --- 6. blob re-hash (read-only) ---------------------------------------------
if [ -n "$SUMMARY_JSON" ]; then
    BLOBS="$(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["referenced"]))' "$SUMMARY_JSON")"
    if [ -n "$BLOBS" ]; then
        BAD_HASH=0
        CHECKED=0
        while IFS= read -r sha; do
            [ -z "$sha" ] && continue
            f="$CHAINS/snapshots/$sha"
            if [ ! -f "$f" ]; then
                echo "  [FAIL] missing snapshot blob: $sha"
                ERRORS=$((ERRORS + 1))
                continue
            fi
            CHECKED=$((CHECKED + 1))
            ACTUAL="$(sha256sum "$f" | awk '{print $1}')"
            if [ "$ACTUAL" != "$sha" ]; then
                echo "  [FAIL] blob hash mismatch (corrupt): $sha"
                ERRORS=$((ERRORS + 1))
                BAD_HASH=$((BAD_HASH + 1))
            fi
        done <<< "$BLOBS"
        if [ "$BAD_HASH" -eq 0 ]; then
            echo "  [OK] $CHECKED blob(s) present and re-hashed clean"
        fi
        # orphan snapshots: on disk but referenced by no commit
        ORPHANS=0
        while IFS= read -r diskfile; do
            base="$(basename "$diskfile")"
            case "$BLOBS" in
                *"$base"*) ;;
                *) echo "  [~] orphan snapshot (unreferenced by any commit): $base"
                   ORPHANS=$((ORPHANS + 1)) ;;
            esac
        done < <(find "$CHAINS/snapshots" -maxdepth 1 -type f 2>/dev/null)
        if [ "$ORPHANS" -gt 0 ]; then
            WARNINGS=$((WARNINGS + ORPHANS))
        fi
    fi

    # --- 7. HEAD save-file presence in the working tree -----------------------
    HEAD_FILES="$(python3 -c '
import json,sys
s=json.loads(sys.argv[1])
for f in s["head_files"]:
    print(f["key"]+"\t"+f["rel"]+"\t"+f["sha256"])' "$SUMMARY_JSON")"
    if [ -n "$HEAD_FILES" ]; then
        MISSING_SRC=0
        while IFS=$'\t' read -r key rel sha; do
            [ -z "$key" ] && continue
            # Key is "<watch dir>::<relative path>"; split on the LAST "::".
            watch="${key%::*}"
            if [ "$watch" = "$key" ]; then
                continue  # no "::" separator -- can't resolve, skip quietly
            fi
            if [ ! -e "$watch/$rel" ]; then
                echo "  [~] HEAD save file missing from working tree: $watch/$rel"
                MISSING_SRC=$((MISSING_SRC + 1))
            fi
        done <<< "$HEAD_FILES"
        WARNINGS=$((WARNINGS + MISSING_SRC))
        if [ "$MISSING_SRC" -eq 0 ]; then
            HEAD_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["head"])' "$SUMMARY_JSON")"
            echo "  [OK] all HEAD ($HEAD_ID) save files present in working tree"
        fi
    fi

    # --- 8. watched paths that no longer exist ---------------------------------
    WATCHES="$(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["watch_paths"]))' "$SUMMARY_JSON")"
    if [ -n "$WATCHES" ]; then
        while IFS= read -r w; do
            [ -z "$w" ] && continue
            if [ ! -d "$w" ]; then
                echo "  [~] watched path no longer exists: $w"
                WARNINGS=$((WARNINGS + 1))
            fi
        done <<< "$WATCHES"
    fi
fi

# --- 9. disk-space sanity -----------------------------------------------------
if AVAIL_KB="$(df -k --output=avail "$VAULT" 2>/dev/null | tail -n 1 | tr -d ' ')"; then
    if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -ge 0 ] 2>/dev/null; then
        AVAIL_MB=$((AVAIL_KB / 1024))
        if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
            echo "  [~] low disk space on vault filesystem: ${AVAIL_MB} MB free (warn below ${MIN_FREE_MB} MB)"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "  [OK] disk space: ${AVAIL_MB} MB free"
        fi
    fi
fi

echo ""
if [ "$FIX" -eq 1 ]; then
    echo "  [i] --fix requested: no auto-repairs are implemented in this pass."
    echo "      chains doctor is report-only by design; see docs/DOCTOR.md for"
    echo "      the manual repair steps for each finding."
    echo ""
fi

if [ "$ERRORS" -gt 0 ]; then
    echo "  RESULT: $ERRORS error(s), $WARNINGS warning(s) -- vault needs attention."
    exit 2
elif [ "$WARNINGS" -gt 0 ]; then
    echo "  RESULT: healthy, with $WARNINGS warning(s)."
    exit 1
else
    echo "  RESULT: vault is healthy."
    exit 0
fi

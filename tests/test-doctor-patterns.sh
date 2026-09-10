#!/usr/bin/env bash
# =============================================================================
# Regression: chains doctor's untracked-saves scan must use the engine's
# FULL pattern set, not a stale hardcoded subset.
#
# The untracked-saves check used to scan with a hardcoded find expression
# covering only (*.srm, *.sav, *.state*, *.sgm, *.zst, *.savestate) -- a
# played-but-never-committed PS2 memory card (*.ps2), BizHawk SaveRAM,
# or Dreamcast VMU export would never be flagged. This test locks in the fix:
#   1. the doctor's bundled fallback pattern list must match the engine's
#      $Script:SavePatterns exactly (anti-drift, for standalone copies);
#   2. the scan must flag untracked saves in the NEWER formats when run
#      from the repo (derived from the engine at scan time).
#
# Needs: bash, python3 (stdlib only), sha256sum. No network, no installs.
# Run from the repo root:  bash tests/test-doctor-patterns.sh
# =============================================================================
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO/scripts/chains-doctor.sh"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

export CHAINS_DOCTOR_MIN_FREE_MB=1  # fixtures live on small tmpfs

# --- 1. fallback list == engine list (anti-drift) ------------------------------
engine_pats="$(grep -E '^\$Script:SavePatterns' "$REPO/modules/vault.ps1" \
    | grep -oE '"\*[^"]*"' | tr -d '"' | sort -u)"
[ -n "$engine_pats" ] || { echo "FAIL: no patterns parsed from engine"; exit 1; }
fallback_pats="$(sed -n '/# FALLBACK-PATTERNS-BEGIN/,/# FALLBACK-PATTERNS-END/p' \
    "$DOCTOR" | grep -oE '"\*[^"]*"' | tr -d '"' | sort -u)"
[ -n "$fallback_pats" ] || { echo "FAIL: no fallback patterns parsed from doctor"; exit 1; }

if [ "$engine_pats" = "$fallback_pats" ]; then ok
else
  no "doctor fallback patterns drifted from engine \$Script:SavePatterns"
  echo "  engine:   $(printf '%s' "$engine_pats" | tr '\n' ' ')"
  echo "  fallback: $(printf '%s' "$fallback_pats" | tr '\n' ' ')"
fi

# --- 2. scan flags untracked saves in the newer formats -----------------------
# Fixture vault: a watched dir with untracked saves in formats the old
# hardcoded find would never have matched (*.ps2, .SaveRAM, .vms), plus a
# *.srm control for the old list. HEAD is a single empty commit so every
# pattern-matched file counts as untracked.
V="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$V"' EXIT
mkdir -p "$V/.chains/snapshots" "$V/saves/sub"
printf 'SAVE-PS2-UNTRACKED'  > "$V/saves/MECHA_SLES-54439.ps2"
printf 'SAVE-BIZHAWK'        > "$V/saves/sub/Game.SaveRAM"
printf 'SAVE-VMU'            > "$V/saves/sub/sonic_3.vms"
printf 'SAVE-SRM-CONTROL'    > "$V/saves/control.srm"
printf 'not a save\n'        > "$V/saves/notes.txt"
TS="$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())')"
ID="$(python3 - "$TS" <<'PY'
import hashlib,sys
print(hashlib.sha256(("|%s|first|"%sys.argv[1]).encode("utf-8")).hexdigest()[:12])
PY
)"
python3 - "$V" "$ID" "$TS" <<'PY'
import json,sys
v, cid, ts = sys.argv[1], sys.argv[2], sys.argv[3]
with open(v + "/.chains/config.json", "w") as f:
    json.dump({"version": 1, "created": ts, "watchPaths": [v + "/saves"]}, f)
with open(v + "/.chains/journal.jsonl", "w") as f:
    json.dump({"id": cid, "parent": "", "ts": ts, "message": "first",
               "files": []}, f)
    f.write("\n")
PY

before="$(cd "$V" && find .chains -type f -exec sha256sum {} + | sort)"

OUT="$(bash "$DOCTOR" "$V" 2>&1)"; CODE=$?

[ "$CODE" -eq 1 ] && ok || no "expected exit 1 (warnings), got $CODE"
for f in MECHA_SLES-54439.ps2 sub/Game.SaveRAM sub/sonic_3.vms control.srm; do
  printf '%s' "$OUT" | grep -qF "not tracked in HEAD (never committed): $V/saves/$f" \
    && ok || no "untracked $f was not flagged"
done
printf '%s' "$OUT" | grep -qF "notes.txt" \
  && no "non-save notes.txt was flagged as a save" || ok

# The untracked scan is read-only: nothing in .chains may change.
after="$(cd "$V" && find .chains -type f -exec sha256sum {} + | sort)"
[ "$before" = "$after" ] && ok || no "doctor modified the vault during a read-only scan"

echo "doctor-patterns: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# =============================================================================
# Regression tests for chains doctor (scripts/chains-doctor.sh).
#
# Builds four fixture vaults in a temp dir -- healthy, dangling parent ref,
# missing pins, stale sync -- plus a broken-journal case, runs the doctor
# against each, and asserts the exit code (0 healthy / 1 warnings / 2 errors)
# plus key output markers. Also asserts the doctor is read-only: a hash of
# every file in the fixture vault must be identical before and after the run.
#
# Needs: bash, python3 (stdlib only), sha256sum. No network, no installs.
# Run from the repo root:  bash tests/test-doctor.sh
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/chains-doctor.sh"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

assert_exit() {  # assert_exit <expected> <actual> <label>
    if [ "$1" = "$2" ]; then pass "$3 (exit $2)"; else fail "$3 (expected exit $1, got $2)"; fi
}

assert_contains() {  # assert_contains <haystack> <needle> <label>
    if printf '%s' "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

# --- fixture builders --------------------------------------------------------

# mkvault <name> : creates $FIX/<name> with .chains/{config.json,journal.jsonl,snapshots/}
mkvault() {
    local v="$FIX/$1"
    mkdir -p "$v/.chains/snapshots"
    printf '%s' "$v"
}

# mkblob <vault> <bytes> : writes content-addressed blob, echoes sha256
mkblob() {
    local v="$1" content="$2"
    local sha
    sha="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
    printf '%s' "$content" > "$v/.chains/snapshots/$sha"
    printf '%s' "$sha"
}

# commit_entry <id> <parent> <ts> <msg> <files_json> : one journal.jsonl line
commit_entry() {
    python3 -c '
import json,sys
print(json.dumps({"id":sys.argv[1],"parent":sys.argv[2],"ts":sys.argv[3],
                  "message":sys.argv[4],"files":json.loads(sys.argv[5])}))' \
        "$1" "$2" "$3" "$4" "$5"
}

iso_now()     { python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())'; }
iso_days_ago() { python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=int(__import__("sys").argv[1]))).isoformat())' "$1"; }

write_config() {  # write_config <vault> <json>
    printf '%s' "$2" > "$1/.chains/config.json"
}

# snapshot_fixture <vault> : sha256 of every file, for the read-only assertion
snapshot_fixture() {
    ( cd "$1" && find .chains -type f -exec sha256sum {} + | sort )
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
export CHAINS_DOCTOR_MIN_FREE_MB=1  # fixtures live on small tmpfs; keep the disk check green

# --- fixture 1: healthy ------------------------------------------------------
V1="$(mkvault healthy)"
W1="$V1/saves"; mkdir -p "$W1"
printf 'SAVE-A' > "$W1/game.srm"
printf 'SAVE-B' > "$W1/game.sav"
SHA_A="$(mkblob "$V1" 'SAVE-A')"
SHA_B="$(mkblob "$V1" 'SAVE-B')"
write_config "$V1" "$(python3 - "$W1" "$(iso_now)" <<'PY'
import json,sys
print(json.dumps({"version":1,"created":sys.argv[2],"watchPaths":[sys.argv[1]],
  "remotePins":{"usb|vault-1":{"fingerprint":"abc","ids":["c1","c2"],"when":sys.argv[2]}}}))
PY
)"
FILES1="$(python3 - "$W1" "$SHA_A" "$SHA_B" <<'PY'
import json,sys
w=sys.argv[1]
print(json.dumps([
  {"key":w+"::game.srm","rel":"game.srm","sha256":sys.argv[2],"bytes":6},
  {"key":w+"::game.sav","rel":"game.sav","sha256":sys.argv[3],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$FILES1" > "$V1/.chains/journal.jsonl"
commit_entry "b2c3d4e5f6a7" "a1b2c3d4e5f6" "$(iso_now)" "second" "$FILES1" >> "$V1/.chains/journal.jsonl"

# --- fixture 2: dangling parent ref -------------------------------------------
V2="$(mkvault dangling)"
SHA_C="$(mkblob "$V2" 'SAVE-C')"
write_config "$V2" '{"version":1,"created":"2026-09-01T00:00:00+00:00","watchPaths":[]}'
F2="$(python3 - "$SHA_C" <<'PY'
import json,sys
print(json.dumps([{"key":"w::x.srm","rel":"x.srm","sha256":sys.argv[1],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$F2" > "$V2/.chains/journal.jsonl"
commit_entry "deadbeef1234" "nope-not-a-real-parent" "$(iso_now)" "bad" "$F2" >> "$V2/.chains/journal.jsonl"

# --- fixture 3: missing pins (synced vault, pins wiped) -----------------------
V3="$(mkvault missingpin)"
SHA_D="$(mkblob "$V3" 'SAVE-D')"
write_config "$V3" '{"version":1,"created":"2026-09-01T00:00:00+00:00","watchPaths":[],"syncVaultId":"vault-3"}'
F3="$(python3 - "$SHA_D" <<'PY'
import json,sys
print(json.dumps([{"key":"w::y.srm","rel":"y.srm","sha256":sys.argv[1],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$F3" > "$V3/.chains/journal.jsonl"

# --- fixture 4: stale sync ----------------------------------------------------
V4="$(mkvault stale)"
SHA_E="$(mkblob "$V4" 'SAVE-E')"
write_config "$V4" "$(python3 - "$(iso_days_ago 30)" <<'PY'
import json,sys
when=sys.argv[1]
print(json.dumps({"version":1,"created":when,"watchPaths":[],
  "remotePins":{"usb|vault-4":{"fingerprint":"abc","ids":["a1b2c3d4e5f6"],"when":when}}}))
PY
)"
F4="$(python3 - "$SHA_E" <<'PY'
import json,sys
print(json.dumps([{"key":"w::z.srm","rel":"z.srm","sha256":sys.argv[1],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$F4" > "$V4/.chains/journal.jsonl"

# --- fixture 5: broken journal line --------------------------------------------
V5="$(mkvault broken)"
write_config "$V5" '{"version":1,"created":"2026-09-01T00:00:00+00:00","watchPaths":[]}'
{ echo '{"id":"a1b2c3d4e5f6","parent":"","files":[]}'; echo 'this is not json{'; } > "$V5/.chains/journal.jsonl"

# --- run the doctor ------------------------------------------------------------
echo ""
echo "  chains doctor regression tests"
echo "  ================================================================"

run_doctor() {  # run_doctor <vault> : sets OUT and CODE; asserts read-only
    local v="$1"
    local before after
    before="$(snapshot_fixture "$v")"
    OUT="$("$DOCTOR" "$v" 2>&1)"
    CODE=$?
    after="$(snapshot_fixture "$v")"
    if [ "$before" = "$after" ]; then
        pass "doctor is read-only on $(basename "$v")"
    else
        fail "doctor modified files in $(basename "$v")"
    fi
}

run_doctor "$V1"
assert_exit 0 "$CODE" "healthy vault"
assert_contains "$OUT" "vault is healthy" "healthy vault report"

run_doctor "$V2"
assert_exit 2 "$CODE" "dangling parent ref"
assert_contains "$OUT" "dangling parent ref" "dangling parent reported"

run_doctor "$V3"
assert_exit 1 "$CODE" "missing pins"
assert_contains "$OUT" "no pins are recorded" "missing pins reported"

run_doctor "$V4"
assert_exit 1 "$CODE" "stale sync"
assert_contains "$OUT" "older than" "stale sync reported"

run_doctor "$V5"
assert_exit 2 "$CODE" "broken journal line"
assert_contains "$OUT" "not valid JSON" "broken journal reported"

# --fix must stay report-only: no writes, same health verdict
BEFORE_FIX="$(snapshot_fixture "$V1")"
OUT_FIX="$("$DOCTOR" --fix "$V1" 2>&1)"; CODE_FIX=$?
AFTER_FIX="$(snapshot_fixture "$V1")"
assert_exit 0 "$CODE_FIX" "--fix on healthy vault"
assert_contains "$OUT_FIX" "report-only" "--fix is report-only"
if [ "$BEFORE_FIX" = "$AFTER_FIX" ]; then pass "--fix performs no writes"; else fail "--fix modified files"; fi

# doctor must refuse a non-vault
OUT_BAD="$("$DOCTOR" "$FIX" 2>&1)"; CODE_BAD=$?
assert_exit 2 "$CODE_BAD" "non-vault rejected"

echo ""
echo "  $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]

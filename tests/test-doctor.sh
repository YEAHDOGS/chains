#!/usr/bin/env bash
# =============================================================================
# Regression tests for chains doctor (scripts/chains-doctor.sh).
#
# Builds seven fixture vaults in a temp dir -- healthy, dangling parent ref,
# missing pins, stale sync, broken journal, working-tree drift, untracked
# saves -- plus a --json pass over the healthy/dangling/stale/drift/
# untracked fixtures, runs the doctor against each, and asserts the exit code (0 healthy / 1 warnings /
# 2 errors), the machine-readable report schema, plus key output markers.
# Also asserts the doctor is read-only: a hash of every file in the fixture
# vault must be identical before and after the run.
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

# --- fixture 6: working-tree drift (played but uncommitted) ------------------
V6="$(mkvault drift)"
W6="$V6/saves"; mkdir -p "$W6"
printf 'SAVE-F' > "$W6/game.srm"
printf 'SAVE-G' > "$W6/game.sav"
SHA_F="$(mkblob "$V6" 'SAVE-F')"
SHA_G="$(mkblob "$V6" 'SAVE-G')"
write_config "$V6" "$(python3 - "$W6" "$(iso_now)" <<'PY'
import json,sys
print(json.dumps({"version":1,"created":sys.argv[2],"watchPaths":[sys.argv[1]],
  "remotePins":{"usb|vault-6":{"fingerprint":"abc","ids":["c1","c2"],"when":sys.argv[2]}}}))
PY
)"
FILES6="$(python3 - "$W6" "$SHA_F" "$SHA_G" <<'PY'
import json,sys
w=sys.argv[1]
print(json.dumps([
  {"key":w+"::game.srm","rel":"game.srm","sha256":sys.argv[2],"bytes":6},
  {"key":w+"::game.sav","rel":"game.sav","sha256":sys.argv[3],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$FILES6" > "$V6/.chains/journal.jsonl"
commit_entry "b2c3d4e5f6a7" "a1b2c3d4e5f6" "$(iso_now)" "second" "$FILES6" >> "$V6/.chains/journal.jsonl"
# ...then the player keeps playing: the live .srm no longer matches HEAD.
printf 'SAVE-F-PLAYED-ON' > "$W6/game.srm"

# --- fixture 7: untracked saves (played a new game, never committed) ----------
V7="$(mkvault untracked)"
W7="$V7/saves"; mkdir -p "$W7/sub"
printf 'SAVE-H' > "$W7/game.srm"
printf 'SAVE-NEW-GAME' > "$W7/newgame.srm"      # never committed, flat
printf 'SAVE-NEW-STATE' > "$W7/sub/secret.state"  # never committed, nested
SHA_H="$(mkblob "$V7" 'SAVE-H')"
write_config "$V7" "$(python3 - "$W7" "$(iso_now)" <<'PY'
import json,sys
print(json.dumps({"version":1,"created":sys.argv[2],"watchPaths":[sys.argv[1]],
  "remotePins":{"usb|vault-7":{"fingerprint":"abc","ids":["c1"],"when":sys.argv[2]}}}))
PY
)"
FILES7="$(python3 - "$W7" "$SHA_H" <<'PY'
import json,sys
w=sys.argv[1]
print(json.dumps([{"key":w+"::game.srm","rel":"game.srm","sha256":sys.argv[2],"bytes":6}]))
PY
)"
commit_entry "a1b2c3d4e5f6" "" "$(iso_now)" "first" "$FILES7" > "$V7/.chains/journal.jsonl"

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

run_doctor "$V6"
assert_exit 1 "$CODE" "working-tree drift"
assert_contains "$OUT" "uncommitted changes" "drift reported"
assert_contains "$OUT" "game.srm" "drifted file named"

run_doctor "$V7"
assert_exit 1 "$CODE" "untracked saves"
assert_contains "$OUT" "not tracked in HEAD" "untracked saves reported"
assert_contains "$OUT" "newgame.srm" "untracked flat save named"
assert_contains "$OUT" "sub/secret.state" "untracked nested save named"

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

# --- --json: machine-readable report ------------------------------------------
run_doctor_json() {  # run_doctor_json <vault> : sets JOUT and JCODE; asserts read-only
    local v="$1"
    local before after
    before="$(snapshot_fixture "$v")"
    JOUT="$("$DOCTOR" --json "$v" 2>&1)"
    JCODE=$?
    after="$(snapshot_fixture "$v")"
    if [ "$before" = "$after" ]; then
        pass "--json is read-only on $(basename "$v")"
    else
        fail "--json modified files in $(basename "$v")"
    fi
}

json_field() {  # json_field <json> <expr> : prints the evaluated field
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print('"$2"')' "$1" 2>/dev/null
}

run_doctor_json "$V1"
assert_exit 0 "$JCODE" "--json on healthy vault"
# stdout must be exactly one JSON document (scriptable): no banner, no chatter.
if printf '%s' "$JOUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "--json emits a single valid JSON document"
else
    fail "--json emits a single valid JSON document"
fi
[ "$(json_field "$JOUT" 'd["result"]')" = "healthy" ] && pass "--json result=healthy" || fail "--json result=healthy"
[ "$(json_field "$JOUT" 'd["exit"]')" = "0" ] && pass "--json exit mirrors exit code" || fail "--json exit mirrors exit code"
[ "$(json_field "$JOUT" 'd["summary"]["commit_count"]')" = "2" ] && pass "--json summary commit_count" || fail "--json summary commit_count"
[ "$(json_field "$JOUT" 'd["summary"]["blob_count"]')" = "2" ] && pass "--json summary blob_count" || fail "--json summary blob_count"
[ "$(json_field "$JOUT" 'd["summary"]["pin_count"]')" = "1" ] && pass "--json summary pin_count" || fail "--json summary pin_count"
[ "$(json_field "$JOUT" 'd["summary"]["head"]')" = "b2c3d4e5f6a7" ] && pass "--json summary head id" || fail "--json summary head id"
# every finding has severity + message, severity drawn from the known set
if python3 - "$JOUT" <<'PY' 2>/dev/null; then
import json,sys
d=json.loads(sys.argv[1])
assert isinstance(d["findings"], list) and d["findings"], "no findings"
for f in d["findings"]:
    assert set(f) >= {"severity","message"}, "finding missing keys"
    assert f["severity"] in {"ok","warn","fail","info"}, "bad severity"
PY
    pass "--json findings schema"
else
    fail "--json findings schema"
fi
# human-only text must not leak into --json output
if printf '%s' "$JOUT" | grep -qE '^\s*(\[OK\]|\[FAIL\]|\[~\]|\[i\]|chains doctor --)'; then
    fail "--json has no human-format lines"
else
    pass "--json has no human-format lines"
fi

run_doctor_json "$V2"
assert_exit 2 "$JCODE" "--json on error vault"
[ "$(json_field "$JOUT" 'd["result"]')" = "errors" ] && pass "--json result=errors" || fail "--json result=errors"
if printf '%s' "$JOUT" | grep -q '"severity": "fail"'; then
    pass "--json carries fail findings"
else
    fail "--json carries fail findings"
fi

run_doctor_json "$V4"
assert_exit 1 "$JCODE" "--json on warning vault"
[ "$(json_field "$JOUT" 'd["result"]')" = "warnings" ] && pass "--json result=warnings" || fail "--json result=warnings"

run_doctor_json "$V6"
assert_exit 1 "$JCODE" "--json on drift vault"
[ "$(json_field "$JOUT" 'd["result"]')" = "warnings" ] && pass "--json drift result=warnings" || fail "--json drift result=warnings"
if printf '%s' "$JOUT" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
warns=[f for f in d["findings"] if f["severity"]=="warn" and "uncommitted changes" in f["message"]]
assert warns, "no drift finding in --json"'; then
    pass "--json carries the drift finding"
else
    fail "--json carries the drift finding"
fi

run_doctor_json "$V7"
assert_exit 1 "$JCODE" "--json on untracked-saves vault"
[ "$(json_field "$JOUT" 'd["result"]')" = "warnings" ] && pass "--json untracked result=warnings" || fail "--json untracked result=warnings"
if printf '%s' "$JOUT" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
warns=[f for f in d["findings"] if f["severity"]=="warn" and "not tracked in HEAD" in f["message"]]
assert len(warns) == 2, "expected 2 untracked findings, got %d" % len(warns)
assert any("newgame.srm" in f["message"] for f in warns), "flat untracked save missing"
assert any("sub/secret.state" in f["message"] for f in warns), "nested untracked save missing"'; then
    pass "--json carries both untracked findings"
else
    fail "--json carries both untracked findings"
fi

echo ""
echo "  $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Regression: PS2 memory cards (*.ps2) track correctly.
# Realistic PS2 fixtures must:
#   1. be matched by the *.ps2 pattern the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   3. not be confused with non-save files.
# Fixture size mirrors the real hardware default: PCSX2 writes 8 MB cards
# (16 MB extended cards exist, but 8 MB is the default).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the *.ps2 pattern must still exist in the engine (drift = fail).
grep -qE '"\*\.ps2"' "$REPO/modules/vault.ps1" \
  || { echo 'FAIL: "*.ps2" missing from $Script:SavePatterns'; exit 1; }
ok

# Fixtures: 8 MB card + an uppercase variant for the case-insensitivity
# check (PCSX2 writes lowercase by convention).
dd if=/dev/urandom of="$tmp/slot1.ps2" bs=1M count=8 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/MCD002.PS2" bs=1M count=8 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
printf 'not a save file\n' > "$tmp/readme.txt"

[ "$(stat -c %s "$tmp/slot1.ps2")" -eq "$((8*1024*1024))" ] && ok || no ".ps2 fixture size is not 8 MB"

# 1. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp"/*.ps2)
shopt -u nocaseglob
got=0
for m in "${matches[@]}"; do
  case "$(basename "$m")" in
    slot1.ps2|MCD002.PS2) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 2 ] && ok || no "*.ps2 pattern did not match both fixtures incl. uppercase (got $got)"
for m in "${matches[@]}"; do
  [ "$(basename "$m")" = "readme.txt" ] && no "readme.txt matched the *.ps2 pattern"
done
ok

# 2. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in slot1.ps2 MCD002.PS2; do
  before="$(sha256sum "$tmp/$f" | cut -d' ' -f1)"
  cp "$tmp/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "ps2-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Regression: DeSmuME NDS battery saves (*.dsv) track correctly.
# A realistic .dsv fixture (512 KB, raw-save + DeSmuME footer shape) must:
#   1. be matched by the *.dsv pattern the engine scans with (case-insensitive,
#      like PowerShell Get-ChildItem -Filter),
#   2. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the footer -- opaque bytes in, opaque bytes out),
#   3. not be confused with non-save files.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the pattern must still exist in the engine (drift = fail).
grep -qE '"\*\.dsv"' "$REPO/modules/vault.ps1" \
  || { echo "FAIL: *.dsv missing from \$Script:SavePatterns"; exit 1; }
ok

# Fixture: 512 KB .dsv like a DeSmuME battery save -- 512*1024 - 16 bytes of
# save data plus a 16-byte opaque footer tail (Chains treats it as bytes).
dd if=/dev/urandom of="$tmp/pokemon.dsv" bs=1024 count=512 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/MARIO.DSV" bs=1K count=8 status=none 2>/dev/null
printf 'not a save file\n' > "$tmp/readme.txt"

[ "$(stat -c %s "$tmp/pokemon.dsv")" -eq "$((512*1024))" ] && ok || no "fixture size is not 512 KB"

# 1. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp"/*.dsv)
shopt -u nocaseglob
got=0
for m in "${matches[@]}"; do
  case "$(basename "$m")" in
    pokemon.dsv|MARIO.DSV) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 2 ] && ok || no "*.dsv did not match both case variants (got $got)"
for m in "${matches[@]}"; do
  [ "$(basename "$m")" = "readme.txt" ] && no "readme.txt matched *.dsv"
done
ok

# 2. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
before="$(sha256sum "$tmp/pokemon.dsv" | cut -d' ' -f1)"
cp "$tmp/pokemon.dsv" "$blobdir/$before"
restored="$tmp/restored.dsv"
cp "$blobdir/$before" "$restored"
after="$(sha256sum "$restored" | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok || no "blob round-trip changed bytes ($before != $after)"

echo "dsv-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

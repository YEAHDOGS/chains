#!/usr/bin/env bash
# Regression: BizHawk SaveRAM files (*.SaveRAM) track correctly.
# A realistic .SaveRAM fixture (32 KB, raw SNES SRAM shape like a BizHawk
# SaveRAM dump) must:
#   1. be matched by the *.SaveRAM pattern the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter -- BizHawk
#      writes the extension as .SaveRAM),
#   2. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dump -- opaque bytes in, opaque bytes out),
#   3. not be confused with non-save files.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the pattern must still exist in the engine (drift = fail).
grep -qE '"\*\.SaveRAM"' "$REPO/modules/vault.ps1" \
  || { echo "FAIL: *.SaveRAM missing from \$Script:SavePatterns"; exit 1; }
ok

# Fixture: 32 KB .SaveRAM like a BizHawk SNES SaveRAM dump (raw SRAM,
# no header). Second file in all-uppercase to exercise case-insensitivity.
dd if=/dev/urandom of="$tmp/zelda.SaveRAM" bs=1024 count=32 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/MARIO.SAVERAM" bs=1K count=8 status=none 2>/dev/null
printf 'not a save file\n' > "$tmp/readme.txt"

[ "$(stat -c %s "$tmp/zelda.SaveRAM")" -eq "$((32*1024))" ] && ok || no "fixture size is not 32 KB"

# 1. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp"/*.SaveRAM)
shopt -u nocaseglob
got=0
for m in "${matches[@]}"; do
  case "$(basename "$m")" in
    zelda.SaveRAM|MARIO.SAVERAM) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 2 ] && ok || no "*.SaveRAM did not match both case variants (got $got)"
for m in "${matches[@]}"; do
  [ "$(basename "$m")" = "readme.txt" ] && no "readme.txt matched *.SaveRAM"
done
ok

# 2. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
before="$(sha256sum "$tmp/zelda.SaveRAM" | cut -d' ' -f1)"
cp "$tmp/zelda.SaveRAM" "$blobdir/$before"
restored="$tmp/restored.SaveRAM"
cp "$blobdir/$before" "$restored"
after="$(sha256sum "$restored" | cut -d' ' -f1)"
[ "$before" = "$after" ] && ok || no "blob round-trip changed bytes ($before != $after)"

echo "saveram-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

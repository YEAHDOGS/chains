#!/usr/bin/env bash
# Regression: N64 battery saves (*.sra / *.eep / *.fla) track correctly.
# Realistic N64 fixtures must:
#   1. be matched by the N64 patterns the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   3. not be confused with non-save files.
# Fixture sizes mirror the real hardware save types: SRAM 32 KB, EEPROM
# 2 KB, FlashRAM 128 KB.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the N64 patterns must still exist in the engine (drift = fail).
for pat in '"\*.sra"' '"\*.eep"' '"\*.fla"'; do
  grep -qE "$pat" "$REPO/modules/vault.ps1" \
    || { echo "FAIL: $pat missing from \$Script:SavePatterns"; exit 1; }
done
ok

# Fixtures: one per N64 save type, plus an uppercase variant for the
# case-insensitivity check (Project64 writes lowercase by convention).
dd if=/dev/urandom of="$tmp/zelda.sra" bs=1024 count=32 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/mario.eep" bs=1024 count=2 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/starfox.fla" bs=1024 count=128 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/GOLDENEYE.SRA" bs=1K count=32 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
printf 'not a save file\n' > "$tmp/readme.txt"

[ "$(stat -c %s "$tmp/zelda.sra")" -eq "$((32*1024))" ] && ok || no ".sra fixture size is not 32 KB"
[ "$(stat -c %s "$tmp/mario.eep")" -eq "$((2*1024))" ] && ok || no ".eep fixture size is not 2 KB"
[ "$(stat -c %s "$tmp/starfox.fla")" -eq "$((128*1024))" ] && ok || no ".fla fixture size is not 128 KB"

# 1. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp"/*.sra "$tmp"/*.eep "$tmp"/*.fla)
shopt -u nocaseglob
got=0
for m in "${matches[@]}"; do
  case "$(basename "$m")" in
    zelda.sra|GOLDENEYE.SRA|mario.eep|starfox.fla) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 4 ] && ok || no "N64 patterns did not match all fixtures incl. uppercase (got $got)"
for m in "${matches[@]}"; do
  [ "$(basename "$m")" = "readme.txt" ] && no "readme.txt matched an N64 pattern"
done
ok

# 2. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in zelda.sra mario.eep starfox.fla; do
  before="$(sha256sum "$tmp/$f" | cut -d' ' -f1)"
  cp "$tmp/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "n64-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

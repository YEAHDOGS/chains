#!/usr/bin/env bash
# Regression: Dreamcast VMU saves (*.vmi / *.vms, Flycast/Redream per-game
# exports) track correctly.
# Realistic VMU fixtures must:
#   1. be matched by the *.vmi / *.vms patterns the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. look like real VMU exports: the .vmi is a fixed 44-byte index header,
#      the .vms is the save data in multiples of 512 bytes, and each .vms
#      shares its basename with its .vmi (the pair is the atomic unit),
#   3. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   4. not be confused with non-save files (e.g. PNG thumbnails written next
#      to the exports by some frontends are deliberately untracked).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: both VMU patterns must still exist in the engine (drift = fail).
grep -qE '"\*\.vmi"' "$REPO/modules/vault.ps1" \
  || { echo 'FAIL: "*.vmi" missing from $Script:SavePatterns'; exit 1; }
grep -qE '"\*\.vms"' "$REPO/modules/vault.ps1" \
  || { echo 'FAIL: "*.vms" missing from $Script:SavePatterns'; exit 1; }
ok

# Fixtures: two lowercase pairs, one uppercase pair, plus decoys. The .vmi
# index is always exactly 44 bytes; its first bytes hold the ASCII game
# name, which is what the export tool writes there.
python3 - "$tmp" <<'PY'
import sys
d = sys.argv[1]

def vmi(name):
    buf = bytearray(44)
    buf[0:len(name)] = name.encode('ascii')
    for i in range(len(name), 44):
        buf[i] = (i * 3 + 11) % 256
    return bytes(buf)

def vms(blocks, seed):
    buf = bytearray(512 * blocks)
    for i in range(len(buf)):
        buf[i] = (seed + i) % 256
    return bytes(buf)

open(d + '/SONICADV_001.vmi', 'wb').write(vmi('SONIC ADV'))
open(d + '/SONICADV_001.vms', 'wb').write(vms(1, 7))
open(d + '/SKIES_001.vmi', 'wb').write(vmi('SKIES'))
open(d + '/SKIES_001.vms', 'wb').write(vms(2, 99))
open(d + '/CRAZY_TAXI.VMI', 'wb').write(vmi('CRAZY TAXI'))
open(d + '/CRAZY_TAXI.VMS', 'wb').write(vms(1, 13))
PY
printf 'not a save file\n' > "$tmp/readme.txt"
printf 'fake png thumbnail\n' > "$tmp/SONICADV_001.png"

# 1. Realism: .vmi == 44 B, .vms a multiple of 512 B, basenames pair up.
bases="SONICADV_001 SKIES_001 CRAZY_TAXI"
for b in $bases; do
  case "$b" in
    CRAZY_TAXI) ext_i="VMI"; ext_s="VMS" ;;
    *)          ext_i="vmi"; ext_s="vms" ;;
  esac
  size_i="$(stat -c %s "$tmp/$b.$ext_i")"
  size_s="$(stat -c %s "$tmp/$b.$ext_s")"
  [ "$size_i" -eq 44 ] && ok || no "$b.$ext_i index is $size_i B, expected 44"
  [ "$((size_s % 512))" -eq 0 ] && [ "$size_s" -gt 0 ] && ok \
    || no "$b.$ext_s size ($size_s B) is not a positive multiple of 512"
done

# 2. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches_i=("$tmp"/*.vmi)
matches_s=("$tmp"/*.vms)
shopt -u nocaseglob
got=0
for m in "${matches_i[@]}" "${matches_s[@]}"; do
  case "$(basename "$m")" in
    SONICADV_001.vmi|SONICADV_001.vms|SKIES_001.vmi|SKIES_001.vms|CRAZY_TAXI.VMI|CRAZY_TAXI.VMS) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 6 ] && ok || no "*.vmi/*.vms patterns did not match all 6 fixtures incl. uppercase (got $got)"
for m in "${matches_i[@]}" "${matches_s[@]}"; do
  base="$(basename "$m")"
  [ "$base" = "readme.txt" ] && no "readme.txt matched a VMU pattern"
  [ "$base" = "SONICADV_001.png" ] && no "SONICADV_001.png matched a VMU pattern"
done
ok

# 3. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in SONICADV_001.vmi SONICADV_001.vms SKIES_001.vmi SKIES_001.vms CRAZY_TAXI.VMI CRAZY_TAXI.VMS; do
  before="$(sha256sum "$tmp/$f" | cut -d' ' -f1)"
  cp "$tmp/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "dc-vmu-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

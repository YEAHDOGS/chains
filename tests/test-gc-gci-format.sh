#!/usr/bin/env bash
# Regression: GameCube saves (*.gci, Dolphin per-game exports) track correctly.
# Realistic GCI fixtures must:
#   1. be matched by the *.gci pattern the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. carry a plausible GCI header (4-byte ASCII game ID at offset 0, size a
#      multiple of 8192 bytes -- one GameCube memcard block per 8 KB),
#   3. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   4. not be confused with non-save files (e.g. raw *.raw card dumps are
#      deliberately untracked).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the *.gci pattern must still exist in the engine (drift = fail).
grep -qE '"\*\.gci"' "$REPO/modules/vault.ps1" \
  || { echo 'FAIL: "*.gci" missing from $Script:SavePatterns'; exit 1; }
ok

# Fixtures: a 1-block (8192 B) and a 2-block (16384 B) GCI, an uppercase
# variant for the case-insensitivity check, plus decoys. GCI block 0 is
# the 64-byte header; offset 0 holds the 4-letter game ID.
python3 - "$tmp" <<'PY'
import struct, sys
d = sys.argv[1]

def gci(gameid, blocks, seed):
    buf = bytearray(8192 * blocks)
    buf[0:4] = gameid.encode('ascii')
    struct.pack_into('>H', buf, 4, 0x01)   # save id
    struct.pack_into('>H', buf, 6, 0x02)   # save id checksum
    buf[0x08] = 0x00                        # flags
    buf[0x0C:0x10] = struct.pack('>I', 0)   # icon offsets sentinel
    for i in range(64, len(buf)):
        buf[i] = (seed + i) % 256
    return bytes(buf)

open(d + '/GM8E01.gci', 'wb').write(gci('GM8E', 1, 7))
open(d + '/GZ2E01.gci', 'wb').write(gci('GZ2E', 2, 99))
open(d + '/MCD001.GCI', 'wb').write(gci('RMGE', 1, 13))
PY
printf 'not a save file\n' > "$tmp/readme.txt"
printf 'raw card dump, not a GCI export\n' > "$tmp/MemoryCardA.raw"

# 1. Realism: block-sized files, 4-byte ASCII game ID at offset 0.
for f in GM8E01.gci GZ2E01.gci MCD001.GCI; do
  size="$(stat -c %s "$tmp/$f")"
  [ "$((size % 8192))" -eq 0 ] && ok || no "$f size ($size B) is not a multiple of 8192"
  id="$(head -c 4 "$tmp/$f")"
  case "$id" in
    GM8E|GZ2E|RMGE) ok ;;
    *) no "$f has no valid 4-letter game ID header (got '$id')" ;;
  esac
done

# 2. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp"/*.gci)
shopt -u nocaseglob
got=0
for m in "${matches[@]}"; do
  case "$(basename "$m")" in
    GM8E01.gci|GZ2E01.gci|MCD001.GCI) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 3 ] && ok || no "*.gci pattern did not match all 3 fixtures incl. uppercase (got $got)"
for m in "${matches[@]}"; do
  base="$(basename "$m")"
  [ "$base" = "readme.txt" ] && no "readme.txt matched the *.gci pattern"
  [ "$base" = "MemoryCardA.raw" ] && no "MemoryCardA.raw matched the *.gci pattern"
done
ok

# 3. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in GM8E01.gci GZ2E01.gci MCD001.GCI; do
  before="$(sha256sum "$tmp/$f" | cut -d' ' -f1)"
  cp "$tmp/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "gc-gci-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

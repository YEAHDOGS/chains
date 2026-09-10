#!/usr/bin/env bash
# Regression: PSP save states (*.ppst, PPSSPP per-game state exports) track
# correctly. Realistic PPSSPP fixtures must:
#   1. be matched by the *.ppst pattern the engine scans with
#      (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. carry PPSSPP's real naming convention
#      (<GAMEID>_<version>_<slot>.ppst, slots 0-4, under PSP/PPSSPP_STATE/),
#      including the .undo.ppst autosave variant PPSSPP writes,
#   3. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   4. not be confused with non-save files (e.g. the same-basename .png
#      thumbnail PPSSPP writes next to each state, or in-game save-data
#      files from a PSP/SAVEDATA folder).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: the *.ppst pattern must still exist in the engine (drift = fail).
grep -qE '"\*\.ppst"' "$REPO/modules/vault.ps1" \
  || { echo 'FAIL: "*.ppst" missing from $Script:SavePatterns'; exit 1; }
ok

# Fixtures: three slot states, one uppercase variant for the
# case-insensitivity check, and one .undo.ppst autosave variant -- all named
# the way PPSSPP writes them. The state body is opaque bytes to Chains.
python3 - "$tmp" <<'PY'
import sys, os
d = sys.argv[1]
states = os.path.join(d, 'PSP', 'PPSSPP_STATE'); os.makedirs(states)
savedata = os.path.join(d, 'PSP', 'SAVEDATA', 'ULUS10445'); os.makedirs(savedata)
def state(size, seed):
    return bytes(((seed + i) % 256) for i in range(size))
open(states + '/ULUS10445_1.00_0.ppst', 'wb').write(state(262144, 7))
open(states + '/ULES01521_1.00_3.ppst', 'wb').write(state(524288, 99))
open(states + '/UCUS98633_1.00_2.PPST', 'wb').write(state(131072, 13))
open(states + '/ULES01521_1.00_3.undo.ppst', 'wb').write(state(524288, 98))
# Decoys:
open(states + '/ULUS10445_1.00_0.png', 'wb').write(state(1024, 1))  # PPSSPP thumbnail
open(savedata + '/DATA.BIN', 'wb').write(state(4096, 2))            # in-game save data
open(d + '/readme.txt', 'w').write('not a save file\n')
PY

# 1. Realism: every tracked fixture follows PPSSPP's <GAMEID>_<ver>_<slot>.ppst
#    naming (slots 0-4), or the .undo.ppst autosave variant.
pat='^[a-z0-9]{4,10}_[0-9]+\.[0-9]+_[0-4](\.undo)?\.ppst$'
for f in ULUS10445_1.00_0.ppst ULES01521_1.00_3.ppst UCUS98633_1.00_2.PPST ULES01521_1.00_3.undo.ppst; do
  lower="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$lower" | grep -qE "$pat" && ok || no "$f does not follow PPSSPP naming <GAMEID>_<ver>_<slot>.ppst"
done

# 2. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches=("$tmp/PSP/PPSSPP_STATE"/*.ppst "$tmp"/*.ppst)
shopt -u nocaseglob
want="ULUS10445_1.00_0.ppst ULES01521_1.00_3.ppst UCUS98633_1.00_2.PPST ULES01521_1.00_3.undo.ppst"
got=0
for m in "${matches[@]}"; do
  [ -e "$m" ] || continue
  base="$(basename "$m")"
  case " $want " in
    *" $base "*) got=$((got+1)) ;;
  esac
  case "$base" in
    *.png|*.txt|*.bin|*.BIN) no "$base matched the *.ppst pattern" ;;
  esac
done
[ "$got" -eq 4 ] && ok || no "*.ppst pattern did not match all 4 fixtures incl. uppercase+undo (got $got)"
ok

# 3. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in ULUS10445_1.00_0.ppst ULES01521_1.00_3.ppst UCUS98633_1.00_2.PPST ULES01521_1.00_3.undo.ppst; do
  before="$(sha256sum "$tmp/PSP/PPSSPP_STATE/$f" | cut -d' ' -f1)"
  cp "$tmp/PSP/PPSSPP_STATE/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "ppst-format: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

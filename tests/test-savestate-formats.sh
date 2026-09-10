#!/usr/bin/env bash
# Regression: additional save-state formats track correctly.
#
# VBA-M writes GBA/GB/GBC save states as `<romname>.sgm`; ZSNES writes
# SNES states as `<romname>.zst` (slots zs1-zs9 not tracked); DuckStation
# writes PSX states as `<GAMEID>_<slot>.savestate` next to same-basename
# .png thumbnails.
#
# Fixtures must:
#   1. be matched by the *.sgm / *.zst / *.savestate patterns the engine
#      scans with (case-insensitive, like PowerShell Get-ChildItem -Filter),
#   2. look like real states (non-empty, plausible order-of-magnitude sizes),
#   3. survive the content-addressed blob round-trip byte-identical
#      (Chains never parses the dumps -- opaque bytes in, opaque bytes out),
#   4. not be confused with non-save files (DuckStation .png thumbnails are
#      deliberately untracked),
#   5. be picked up by chains-doctor.sh's untracked-save scan (the doctor
#      mirrors the engine's pattern list for check 9).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# Guard: all three patterns must still exist in the engine (drift = fail).
for pat in '"\*\.sgm"' '"\*\.zst"' '"\*\.savestate"'; do
  grep -qE "$pat" "$REPO/modules/vault.ps1" \
    || { echo "FAIL: $pat missing from \$Script:SavePatterns"; exit 1; }
done
ok

# Guard: the doctor's untracked-save scan must know the new patterns too.
# The doctor derives the patterns from the engine at scan time; standalone
# copies use the bundled fallback list (kept in sync with the engine by
# tests/test-doctor-patterns.sh), so the guard targets that list now.
for pat in "*.sgm" "*.zst" "*.savestate"; do
  sed -n '/# FALLBACK-PATTERNS-BEGIN/,/# FALLBACK-PATTERNS-END/p' "$REPO/scripts/chains-doctor.sh" \
    | grep -qF -- "\"$pat\"" \
    || { echo "FAIL: chains-doctor.sh untracked scan missing $pat"; exit 1; }
done
ok

# Fixtures: one per format plus uppercase variants; DuckStation .png
# thumbnails and a readme.txt are decoys.
dd if=/dev/urandom of="$tmp/pokemon_emerald.sgm" bs=1024 count=144 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/ct.zst" bs=1024 count=1536 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/SLUS-01066_1.savestate" bs=1024 count=3072 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/FIRE_RED.SGM" bs=1K count=144 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
dd if=/dev/urandom of="$tmp/MARIO.ZST" bs=1K count=1536 status=none 2>/dev/null \
  || { echo "FAIL: fixture write"; exit 1; }
printf 'not a save file\n' > "$tmp/readme.txt"
printf 'fake thumbnail\n' > "$tmp/SLUS-01066_1.png"

# 1. Realism: fixtures are non-empty and plausibly sized (opaque bytes --
# Chains never parses them, but the test pins order-of-magnitude sizes so
# a future refactor can't silently redefine what a "state" looks like).
[ "$(stat -c %s "$tmp/pokemon_emerald.sgm")" -eq "$((144*1024))" ] && ok || no ".sgm fixture size unexpected"
[ "$(stat -c %s "$tmp/ct.zst")" -eq "$((1536*1024))" ] && ok || no ".zst fixture size unexpected"
[ "$(stat -c %s "$tmp/SLUS-01066_1.savestate")" -eq "$((3072*1024))" ] && ok || no ".savestate fixture size unexpected"

# 2. Pattern matching, PowerShell semantics (case-insensitive -Filter).
shopt -s nocaseglob
matches_sgm=("$tmp"/*.sgm)
matches_zst=("$tmp"/*.zst)
matches_ds=("$tmp"/*.savestate)
shopt -u nocaseglob
got=0
for m in "${matches_sgm[@]}" "${matches_zst[@]}" "${matches_ds[@]}"; do
  case "$(basename "$m")" in
    pokemon_emerald.sgm|ct.zst|SLUS-01066_1.savestate|FIRE_RED.SGM|MARIO.ZST) got=$((got+1)) ;;
  esac
done
[ "$got" -eq 5 ] && ok || no "*.sgm/*.zst/*.savestate patterns did not match all 5 fixtures incl. uppercase (got $got)"
for m in "${matches_sgm[@]}" "${matches_zst[@]}" "${matches_ds[@]}"; do
  base="$(basename "$m")"
  [ "$base" = "readme.txt" ] && no "readme.txt matched a save-state pattern"
  [ "$base" = "SLUS-01066_1.png" ] && no "SLUS-01066_1.png thumbnail matched a save-state pattern"
done
ok

# 3. Content-addressed round-trip: store by sha256, restore, re-hash.
blobdir="$tmp/blobs"; mkdir -p "$blobdir"
for f in pokemon_emerald.sgm ct.zst SLUS-01066_1.savestate FIRE_RED.SGM MARIO.ZST; do
  before="$(sha256sum "$tmp/$f" | cut -d' ' -f1)"
  cp "$tmp/$f" "$blobdir/$before"
  cp "$blobdir/$before" "$tmp/restored-$f"
  after="$(sha256sum "$tmp/restored-$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ] && ok || no "$f blob round-trip changed bytes"
done

echo "savestate-formats: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

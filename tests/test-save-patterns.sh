#!/usr/bin/env bash
# Regression: every pattern in $SavePatterns (modules/vault.ps1) must be
# documented in README.md ("Tracked patterns:") and docs/SAVE-FORMATS.md.
# Adding a pattern without updating the docs breaks this test on purpose.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
no()   { fail=$((fail+1)); echo "FAIL: $1"; }

line="$(grep -E '^\$Script:SavePatterns' "$REPO/modules/vault.ps1")" || {
  echo "FAIL: \$Script:SavePatterns not found in modules/vault.ps1"; exit 1; }

# Extract quoted patterns: "*.srm" "*.sav" ... -> *.srm *.sav ...
patterns="$(printf '%s' "$line" | grep -oE '"\*[^"]*"' | tr -d '"' | sort -u)"

[ -n "$patterns" ] || { echo "FAIL: no patterns parsed"; exit 1; }

tracked_line="$(grep -F 'Tracked patterns:' "$REPO/README.md" | head -1)"
[ -n "$tracked_line" ] || { echo "FAIL: no 'Tracked patterns:' line in README.md"; exit 1; }

while read -r pat; do
  [ -n "$pat" ] || continue
  if printf '%s' "$tracked_line" | grep -qF "$pat"; then ok; else no "README.md 'Tracked patterns:' missing $pat"; fi
  # SAVE-FORMATS.md may write the pattern with or without the '*' prefix.
  ext="${pat#\*}"   # ".mcr" style
  if grep -qF "$pat" "$REPO/docs/SAVE-FORMATS.md" || grep -qF "\`${ext}\`" "$REPO/docs/SAVE-FORMATS.md"; then ok; else no "docs/SAVE-FORMATS.md missing $pat"; fi
  # Engine actually scans with $Script:SavePatterns (guard against drift).
  if grep -q 'foreach (\$Pattern in \$Script:SavePatterns)' "$REPO/modules/vault.ps1"; then ok; else no "vault.ps1 scan loop no longer iterates \$Script:SavePatterns"; fi
done <<< "$patterns"

echo "save-patterns: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

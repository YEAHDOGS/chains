#!/usr/bin/env bash
# Regression guard: docs/ARCHITECTURE.md must stay a complete decision record.
# It pins the six decisions (D1-D6), the status taxonomy, and the open-questions
# section so future edits can't silently drop a decision.
set -u

DOC="docs/ARCHITECTURE.md"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [ok] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

[ -f "$DOC" ] || { echo "[FAIL] $DOC missing"; exit 1; }

for d in D1 D2 D3 D4 D5 D6; do
    grep -q "^## $d\." "$DOC" && ok "decision $d heading present" \
        || bad "decision $d heading missing"
done

# Each decision resolves, not hand-waves: a Recommendation / recommendation line.
for d in D1 D2 D3 D4 D5 D6; do
    awk "/^## $d\./,/^## [^D]|^## Open/" "$DOC" | grep -qi "recommend" \
        && ok "decision $d states a recommendation" \
        || bad "decision $d states no recommendation"
done

# Status taxonomy is declared and every decision carries a status.
grep -q "ACCEPTED" "$DOC" && ok "status taxonomy present" || bad "no ACCEPTED status"
for d in D1 D2 D3 D4 D5 D6; do
    awk "/^## $d\./,/^## [^D]|^## Open/" "$DOC" | grep -q "\*\*Status:\*\*" \
        && ok "decision $d has Status line" || bad "decision $d missing Status line"
done

# Open questions section exists with at least the sync question (D4's).
grep -q "^## Open questions for Brandon" "$DOC" \
    && ok "open-questions section present" || bad "open-questions section missing"
grep -qi "R2" "$DOC" && ok "R2 sync decision recorded" || bad "R2 missing"

# Decision index table covers all six.
for d in D1 D2 D3 D4 D5 D6; do
    grep -q "| $d |" "$DOC" && ok "index row for $d" || bad "index row for $d missing"
done

echo ""
echo "docs-architecture: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

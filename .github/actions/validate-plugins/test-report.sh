#!/usr/bin/env bash
# Tests for 90-report.sh's machine-readable verdicts (the bump-revert seam):
#   failed-subjects (revertable ENTRY NAMES — never invariant codes),
#   nonrevertable (whole-marketplace failures), and completed (infra-vs-clean).
# These guard the contract revert-failed-bumps.yml depends on.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

# Run 90-report.sh against a given results.jsonl; echoes "rc|completed|failed|nonrev".
run_report() {
  local results="$1"
  local tmp; tmp="$(mktemp -d)"
  printf '%s' "$results" > "$tmp/results.jsonl"
  VALIDATE_TMP="$tmp" ACTION_PATH="$HERE" \
    GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/sum" \
    bash "$HERE/scripts/90-report.sh" >/dev/null 2>&1
  local rc=$?
  local completed failed nonrev
  completed="$(sed -n 's/^completed=//p' "$tmp/out")"
  failed="$(sed -n 's/^failed-subjects=//p' "$tmp/out")"
  nonrev="$(sed -n 's/^nonrevertable=//p' "$tmp/out")"
  printf '%s|%s|%s|%s' "$rc" "$completed" "$failed" "$nonrev"
  rm -rf "$tmp"
}

echo "=== 90-report.sh verdict tests ==="

# 1. Mixed: cli-external fail (subject=name), per-entry invariant fail (subject=CODE,
#    entry=name), whole-marketplace fail (I2), marketplace-schema fail, AND the
#    synthetic die/fatal terminator row that the real action emits at the end of a
#    failing run. failed-subjects must be ENTRY NAMES (not "I11"); nonrevertable must
#    be the whole-marketplace subjects only — the "die" terminator must NOT poison it
#    (else every failing run looks non-revertable and the loop never reverts).
mixed='{"step":"cli-external","status":"pass","subject":"good","detail":"","entry":""}
{"step":"cli-external","status":"fail","subject":"bad-external","detail":"x","entry":""}
{"step":"invariants","status":"fail","subject":"I11","detail":"badName","entry":"bad-name-entry"}
{"step":"invariants","status":"fail","subject":"I2","detail":"dups","entry":""}
{"step":"cli-marketplace","status":"fail","subject":"marketplace.json","detail":"schema","entry":""}
{"step":"fatal","status":"fail","subject":"die","detail":"3 errors","entry":""}'
IFS='|' read -r rc completed failed nonrev <<<"$(run_report "$mixed")"
[ "$rc" = "1" ] && ok "mixed: exits 1 (failures present)" || bad "mixed exit" "rc=$rc"
[ "$completed" = "true" ] && ok "mixed: completed=true" || bad "mixed completed" "$completed"
if [ "$(jq -c 'sort' <<<"$failed")" = '["bad-external","bad-name-entry"]' ]; then
  ok "mixed: failed-subjects are ENTRY NAMES, not the invariant code"
else
  bad "mixed failed-subjects" "$failed (must be entry names, never I11)"
fi
if printf '%s' "$failed" | jq -e 'any(.[]; test("^I[0-9]+$"))' >/dev/null 2>&1; then
  bad "mixed: invariant code leaked into failed-subjects" "$failed"
else
  ok "mixed: no invariant code (Ixx) leaked into failed-subjects"
fi
if [ "$(jq -c 'sort' <<<"$nonrev")" = '["I2","marketplace.json"]' ]; then
  ok "mixed: nonrevertable = whole-marketplace + schema"
else
  bad "mixed nonrevertable" "$nonrev"
fi

# 2. Infra crash: empty results.jsonl → completed=false (NOT confusable with all-pass).
IFS='|' read -r rc completed failed nonrev <<<"$(run_report "")"
[ "$completed" = "false" ] && ok "empty results: completed=false (infra signal)" || bad "empty completed" "$completed"
[ "$failed" = "[]" ] && ok "empty results: failed-subjects=[]" || bad "empty failed" "$failed"

# 3. Clean all-pass → completed=true, empty failed/nonrev, exit 0.
allpass='{"step":"cli-external","status":"pass","subject":"a","detail":"","entry":""}
{"step":"invariants","status":"pass","subject":"summary","detail":"0 errors","entry":""}'
IFS='|' read -r rc completed failed nonrev <<<"$(run_report "$allpass")"
[ "$rc" = "0" ] && ok "all-pass: exits 0" || bad "all-pass exit" "rc=$rc"
[ "$completed" = "true" ] && ok "all-pass: completed=true (distinct from infra false)" || bad "all-pass completed" "$completed"
[ "$failed" = "[]" ] && [ "$nonrev" = "[]" ] && ok "all-pass: failed/nonrev empty" || bad "all-pass lists" "f=$failed n=$nonrev"

# 4. ONLY a per-entry invariant fail (+ the real die terminator) → revertable by
#    entry name, nonrevertable empty (the die row must NOT make it non-revertable).
inv='{"step":"invariants","status":"fail","subject":"I3","detail":"too short","entry":"shorty"}
{"step":"fatal","status":"fail","subject":"die","detail":"1 error","entry":""}'
IFS='|' read -r rc completed failed nonrev <<<"$(run_report "$inv")"
[ "$(jq -c '.' <<<"$failed")" = '["shorty"]' ] && ok "per-entry invariant: revertable by entry name" || bad "inv failed" "$failed"
[ "$nonrev" = "[]" ] && ok "per-entry invariant + die row: nonrevertable empty (die not counted)" || bad "inv nonrev" "$nonrev"

# 5. cli-external fail + its die terminator (the COMMON case): revertable, the loop
#    must NOT abort. This is the M2 regression — a die row previously poisoned nonrev.
ext='{"step":"cli-external","status":"fail","subject":"bad-ext","detail":"validate boom","entry":""}
{"step":"fatal","status":"fail","subject":"die","detail":"1 external plugin failed","entry":""}'
IFS='|' read -r rc completed failed nonrev <<<"$(run_report "$ext")"
[ "$(jq -c '.' <<<"$failed")" = '["bad-ext"]' ] && ok "common case (cli-external + die): revertable by name" || bad "ext failed" "$failed"
[ "$nonrev" = "[]" ] && ok "common case: nonrevertable empty → revert proceeds (not abort)" || bad "ext nonrev" "$nonrev (die must not poison it)"

echo
echo "=== $pass/$((pass+fail)) passed ==="
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Static test suite for invariants I1-I11. No API key, no network — pure
# bash/jq against synthetic marketplace.json fixtures. Run locally or in CI
# on every PR touching validate-plugins/.
#
# Usage: bash .github/actions/validate-plugins/test-invariants.sh

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0

run_invariants() {
  local mp="$1"
  export VALIDATE_TMP="$TMP/v" MARKETPLACE_PATH="$mp" BASE_REF=HEAD WARN_INVARIANTS=""
  rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
  cp "$mp" "$VALIDATE_TMP/marketplace.json"
  bash scripts/11-validate-invariants.sh 2>&1 || true
}

assert_fires() {
  local label="$1" code="$2" mp="$3"
  if run_invariants "$mp" | grep -q "invariant $code:"; then
    echo "  PASS $label — $code fires"
  else
    echo "  FAIL $label — expected $code to fire"; failures=$((failures+1))
  fi
}

assert_clean() {
  local label="$1" mp="$2"
  out="$(run_invariants "$mp")"
  if grep -qE '::error|::warning' <<<"$out"; then
    echo "  FAIL $label — expected clean, got:"; grep -E '::error|::warning' <<<"$out" | sed 's/^/    /'
    failures=$((failures+1))
  else
    echo "  PASS $label — clean"
  fi
}

mk() { local f="$TMP/$1.json"; shift; printf '%s' "$*" > "$f"; echo "$f"; }

GOOD_EXT='{"name":"aaa","description":"A valid description here.","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'

echo "=== validate-plugins invariant tests ==="

assert_clean  "baseline good entry"        "$(mk good   "{\"plugins\":[$GOOD_EXT]}")"
assert_fires  "I1 unsorted"           I1   "$(mk i1     "{\"plugins\":[{\"name\":\"zzz\",\"description\":\"ten chars ok\",\"source\":\"./z\"},{\"name\":\"aaa\",\"description\":\"ten chars ok\",\"source\":\"./a\"}]}")"
assert_fires  "I2 duplicate name"     I2   "$(mk i2     "{\"plugins\":[$GOOD_EXT,$GOOD_EXT]}")"
assert_fires  "I3 desc too short"     I3   "$(mk i3     '{"plugins":[{"name":"abc","description":"short","source":"./x"}]}')"
assert_fires  "I4 unsafe url"         I4   "$(mk i4     '{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"http://insecure.example/x","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}')"
assert_fires  "I5 missing sha"        I5   "$(mk i5     '{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y"}}]}')"
assert_fires  "I9 shell metachar"     I9   "$(mk i9     '{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y;rm","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}')"
assert_fires  "I10 hidden unicode"    I10  "$(mk i10    "{\"plugins\":[{\"name\":\"abc\",\"description\":\"hello"$'​'"world ten chars\",\"source\":\"./x\"}]}")"
assert_fires  "I11 bad name format"   I11  "$(mk i11    '{"plugins":[{"name":"Bad_Name","description":"ten chars ok","source":"./x"}]}')"

echo
echo "=== $((9-failures))/9 passed ==="
[[ "$failures" -eq 0 ]]

#!/usr/bin/env bash
# Smoke for superseded_abort_note — the pre-spend stale-head gate seam.
#
# Behavior under test (user-visible contract, not implementation):
#   - head moved      → non-empty abort body naming BOTH 7-char short SHAs
#                       (the operator greps logs/PR for them)
#   - head unchanged  → empty output, rc=0 (run proceeds)
#   - CURRENT_HEAD "" → empty output, rc=0 (gh fetch failed — fail-open;
#                       a review is better than no review on flaky GitHub)
#   - REVIEWED_SHA "" → rc=1 + stderr (worker invariant violated — fail-fast)
#
# Hermetic — sources lib/run-dir.sh and invokes the helper with explicit
# args; no closure state, no network, no fixtures.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

FAILS=0
SHA_OLD="abc1234567abcdef"
SHA_NEW="def9876543abcdef"

# 1. moved head → abort body carrying both short SHAs
out=$(superseded_abort_note "$SHA_OLD" "$SHA_NEW")
rc=$?
if [ "$rc" -ne 0 ] || [[ "$out" != *"abc1234"* ]] || [[ "$out" != *"def9876"* ]]; then
    echo "FAIL: moved head — expected abort body with both short SHAs (rc=0), got rc=$rc: $out"
    FAILS=$((FAILS+1))
else
    echo "  ok: moved head → abort body"
fi

# 2. unchanged head → empty, rc=0
out=$(superseded_abort_note "$SHA_OLD" "$SHA_OLD")
rc=$?
if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
    echo "FAIL: unchanged head — expected empty rc=0, got rc=$rc: $out"
    FAILS=$((FAILS+1))
else
    echo "  ok: unchanged head → proceed"
fi

# 3. empty CURRENT_HEAD (gh failure) → empty, rc=0 (fail-open)
out=$(superseded_abort_note "$SHA_OLD" "")
rc=$?
if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
    echo "FAIL: empty CURRENT_HEAD — expected fail-open (empty, rc=0), got rc=$rc: $out"
    FAILS=$((FAILS+1))
else
    echo "  ok: empty CURRENT_HEAD → fail-open"
fi

# 4. empty REVIEWED_SHA → rc=1 + stderr diagnostic
err=$(superseded_abort_note "" "$SHA_NEW" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 1 ] || [ -z "$err" ]; then
    echo "FAIL: empty REVIEWED_SHA — expected rc=1 with stderr diagnostic, got rc=$rc: $err"
    FAILS=$((FAILS+1))
else
    echo "  ok: empty REVIEWED_SHA → invariant violation (rc=1)"
fi

if [ "$FAILS" -gt 0 ]; then
    echo "superseded-abort-smoke: $FAILS failure(s)"
    exit 1
fi
echo "superseded-abort-smoke: all scenarios passed"

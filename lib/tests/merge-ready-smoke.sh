#!/usr/bin/env bash
# Smoke test for the SPARKLE FORK PATCH merge-ready scoping gate
# (lib/merge-ready.sh + the isDraft/labels fields lib/pr-enumerate.sh adds).
#
# Pure-logic: no gh, no docker, no flock, no network — so unlike the
# orchestrator smokes this one runs on a macOS dev box as well as on the
# production Linux host.
#
# What it fences, and why each case is here rather than assumed:
#   1. a labelled non-draft PR is reviewed              (the happy path)
#   2. a draft carrying the label is NOT reviewed       (draft beats label)
#   3. an unlabelled PR is NOT reviewed                 (the whole point)
#   4. a payload with NO labels key is NOT reviewed AND says so  <- rebase canary
#   5. empty MERGE_READY_LABELS is NOT "allow everything"        <- fail-closed
#   6. one match out of several labels is enough
#   7. a label that is a SUBSTRING of a configured one does NOT match
#   8. SKIP_DRAFT_PRS=false lets a labelled draft through
#   9. both enumeration paths normalise labels to the SAME flat shape
#
# Case 4 is the one that justifies the file existing. This is a fork patch on
# an upstream that lands 1-5 commits/day; the failure mode nobody would notice
# is a rebase silently dropping the lib/pr-enumerate.sh field additions, after
# which every PR looks unlabelled and the reviewer goes quiet forever. The gate
# must name that cause rather than skipping silently.
#
# Case 7 is the mutation guard on the matching itself: a naive
# `case $labels in *$label*)` passes cases 1-6 and still mismatches
# "ready" against "ready-for-review".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fails=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1 — $2"; fails=$((fails+1)); }

# Assert the gate's verdict AND (optionally) that its reason mentions a phrase.
# Both matter: a skip for the wrong reason is a different bug from a skip.
assert_gate() {
    local label="$1" want_rc="$2" want_reason="${3:-}" json="$4"
    local reason rc
    reason=$(pr_is_merge_ready "$json"); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        fail "$label" "expected rc=$want_rc, got rc=$rc (reason: $reason)"
        return
    fi
    if [ -n "$want_reason" ] && ! grep -q "$want_reason" <<< "$reason"; then
        fail "$label" "expected reason to mention '$want_reason', got: $reason"
        return
    fi
    pass "$label"
}

echo "=== lib/merge-ready.sh: pr_is_merge_ready ==="

# Defaults under test, set explicitly so a change to the file's defaults shows
# up as a failure here rather than silently redefining what is being asserted.
export MERGE_READY_LABELS="ready-for-review"
export SKIP_DRAFT_PRS=true
# shellcheck source=lib/merge-ready.sh
. "$PROJECT_ROOT/lib/merge-ready.sh"

assert_gate "1. labelled non-draft is reviewed" 0 "label ready-for-review" \
    '{"number":1,"isDraft":false,"labels":["ready-for-review"]}'

assert_gate "2. labelled DRAFT is skipped" 1 "draft" \
    '{"number":2,"isDraft":true,"labels":["ready-for-review"]}'

assert_gate "3. unlabelled non-draft is skipped" 1 "no merge-ready label" \
    '{"number":3,"isDraft":false,"labels":[]}'

# The rebase canary. A payload with no labels KEY at all must be distinguished
# from one with an empty labels array — same verdict, different cause, and only
# this one indicates the enumeration patch went missing.
assert_gate "4. payload with NO labels key names the missing patch" 1 "lib/pr-enumerate.sh fork patch is missing" \
    '{"number":4,"isDraft":false}'

assert_gate "6. one match among several labels is enough" 0 "label ready-for-review" \
    '{"number":6,"isDraft":false,"labels":["bug","ready-for-review","p1"]}'

# Substring guard: "ready" must NOT satisfy a gate configured for
# "ready-for-review". Comma-boundary matching is what makes this pass.
assert_gate "7. a substring label does NOT match" 1 "no merge-ready label" \
    '{"number":7,"isDraft":false,"labels":["ready"]}'

# 5. Empty config must fail CLOSED, not open. Asserted after the cases above so
# the earlier ones ran under a valid config.
MERGE_READY_LABELS="" assert_gate "5. empty MERGE_READY_LABELS is not 'allow all'" 1 "refusing" \
    '{"number":5,"isDraft":false,"labels":["ready-for-review"]}'

SKIP_DRAFT_PRS=false assert_gate "8. SKIP_DRAFT_PRS=false lets a labelled draft through" 0 "label ready-for-review" \
    '{"number":8,"isDraft":true,"labels":["ready-for-review"]}'

echo ""
echo "=== lib/pr-enumerate.sh: both paths normalise labels to one shape ==="

# The two enumeration paths return DIFFERENT native shapes — graphql nests
# labels under .labels.nodes[].name, `gh pr list` returns .labels[].name. The
# gate reads a flat string array, so a normaliser that only handles one path
# leaves the other permanently unreviewable. Assert the jq the file actually
# uses, extracted from the file itself so an edit there breaks this test.
graphql_raw='{"data":{"search":{"nodes":[{"number":9,"isDraft":false,"labels":{"nodes":[{"name":"ready-for-review"}]}}]}}}'
graphql_out=$(printf '%s' "$graphql_raw" | jq -c '[.data.search.nodes[]? | . + {labels: [(.labels.nodes // [])[].name]}]')
if [ "$(jq -r '.[0].labels[0]' <<< "$graphql_out")" = "ready-for-review" ]; then
    pass "9a. graphql path flattens labels.nodes[].name"
else
    fail "9a. graphql path flattens labels.nodes[].name" "got: $graphql_out"
fi

rest_raw='[{"number":10,"isDraft":false,"labels":[{"name":"ready-for-review","color":"fff"}]}]'
rest_out=$(printf '%s' "$rest_raw" | jq -c --arg r "drodio/sparkle" \
    'map(. + {repository: {nameWithOwner: $r}, labels: [(.labels // [])[].name]})')
if [ "$(jq -r '.[0].labels[0]' <<< "$rest_out")" = "ready-for-review" ]; then
    pass "9b. gh-pr-list path flattens labels[].name"
else
    fail "9b. gh-pr-list path flattens labels[].name" "got: $rest_out"
fi

# The normalised output of BOTH paths must satisfy the gate — the property that
# actually matters, rather than the intermediate shape.
assert_gate "9c. normalised graphql node passes the gate" 0 "" "$(jq -c '.[0]' <<< "$graphql_out")"
assert_gate "9d. normalised gh-pr-list node passes the gate" 0 "" "$(jq -c '.[0]' <<< "$rest_out")"

# Guard that the jq asserted above is the jq the file uses. Without this the
# test could keep passing against a normaliser the code no longer contains.
echo ""
echo "=== the asserted jq is the jq lib/pr-enumerate.sh actually uses ==="
# grep -F, not -E: these needles are jq source containing (, ), [, ] — every
# one an ERE metacharacter. Written as regexes they silently matched nothing.
for needle in 'labels: [(.labels.nodes // [])[].name]' 'labels: [(.labels // [])[].name]'; do
    if grep -qF "$needle" "$PROJECT_ROOT/lib/pr-enumerate.sh"; then
        pass "normaliser present in lib/pr-enumerate.sh: $needle"
    else
        fail "normaliser present in lib/pr-enumerate.sh" "missing: $needle"
    fi
done
if grep -q 'isDraft' "$PROJECT_ROOT/lib/pr-enumerate.sh"; then
    pass "isDraft is enumerated"
else
    fail "isDraft is enumerated" "lib/pr-enumerate.sh does not request isDraft"
fi

echo ""
if [ "$fails" -eq 0 ]; then
    echo "merge-ready smoke: ALL PASSED"
    exit 0
fi
echo "merge-ready smoke: $fails FAILURE(S)"
exit 1

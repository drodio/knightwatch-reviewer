#!/usr/bin/env bash
# Smoke for the re-eval fire-once marker check (reeval_marker_fired,
# lib/run-dir.sh). A PR added an optional `Sketch:` probe field whose
# fenced content gets rendered verbatim into the aggregator's posted review
# body (prompts/aggregator.md step 6: "A probe carrying a Sketch: renders
# its fenced code block directly under its rendered line, verbatim"). An
# earlier implementation grepped a raw substring window out of the
# concatenated $PRIOR_REVIEWS text, re-arming that window on ANY
# separator-shaped line — including a fake `--- review at ... ---` line
# rendered inside a Sketch fence deep in a body. reeval_marker_fired now
# reads each prior author-visible run's aggregator output FILE directly and
# inspects only its own leading 8 lines — no in-band separator parsing, so
# nothing a rendered fence can contain is ever window-eligible.
#
# This smoke sources the real lib/run-dir.sh and exercises the real
# function against fixture run dirs shaped the way author_visible_runs_iter
# expects: $state_dir/runs/<repo_slug>__<pr_num>__<ts>__<sha>/ with a
# meta.json (posted_at set, so is_run_author_visible accepts it) and an
# agents/aggregator/output.md body.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_FILE=/dev/null
PR_ID="test#0"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass_msg() { echo "PASS: $*"; PASS=$((PASS+1)); }

MARKER='<!-- knightwatch-reviewer:reeval-loc -->'
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
REPO_SLUG="acme_widgets"
PR_NUM="42"
mkdir -p "$STATE_DIR/runs"

# deep_fence_body <fence-content>
#   A realistic review body whose Probes section ends, 20+ lines in, with a
#   fenced block carrying the given content — the Sketch-render position.
deep_fence_body() {
    local body=$'_intent line_\n\n**Probes**\n1. [medium] some finding\n' i
    for i in $(seq 20); do body+=$'filler probe line\n'; done
    printf '%s' "$body"$'```text\n'"$1"$'\n```\n'
}

# check_marker_case <expect: fired|not-fired> <label> <body-content>
#   Builds a fresh author-visible fixture run with the given aggregator body
#   and asserts reeval_marker_fired's verdict.
check_marker_case() {
    local expect="$1" label="$2" body="$3"
    echo "  $label..."
    rm -rf "$STATE_DIR/runs"; mkdir -p "$STATE_DIR/runs"
    local run_dir="$STATE_DIR/runs/${REPO_SLUG}__${PR_NUM}__T100Z__abc1234"
    mkdir -p "$run_dir/agents/aggregator"
    printf '%s' "$body" > "$run_dir/agents/aggregator/output.md"
    printf '{"posted_at": "2026-01-01T00:00:00Z"}' > "$run_dir/meta.json"
    local fired=not-fired
    reeval_marker_fired "$MARKER" "$STATE_DIR" "$REPO_SLUG" "$PR_NUM" "" && fired=fired
    if [ "$fired" = "$expect" ]; then
        pass_msg "$label -> $fired"
    else
        fail_msg "$label -> $fired (expected $expect)"
    fi
}

echo "=== reeval-marker smoke ==="

check_marker_case fired \
    "(a) marker on line 2 of a prior run's aggregator body" \
    $'_intent line_\n'"$MARKER"$'\n\n> banner prose\n'
check_marker_case not-fired \
    "(b) marker string inside a fenced block 20+ lines into the body" \
    "$(deep_fence_body "$MARKER")"
check_marker_case not-fired \
    "(c) marker embedded mid-line (not a standalone line)" \
    $'_intent line_\nsome text '"$MARKER"$' more text\n'
check_marker_case not-fired \
    "(d) fake separator + marker both inside a deep fence" \
    "$(deep_fence_body $'--- review at T999Z ---\n'"$MARKER")"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "PASS ($PASS checks)"
    exit 0
else
    echo "FAIL ($FAIL failed, $PASS passed)"
    exit 1
fi

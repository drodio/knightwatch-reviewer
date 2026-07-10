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

# make_run <ts> <body-content>
#   Creates an author-visible fixture run dir with the given aggregator body.
make_run() {
    local ts="$1" body="$2"
    local run_dir="$STATE_DIR/runs/${REPO_SLUG}__${PR_NUM}__${ts}__abc1234"
    mkdir -p "$run_dir/agents/aggregator"
    printf '%s' "$body" > "$run_dir/agents/aggregator/output.md"
    printf '{"posted_at": "2026-01-01T00:00:00Z"}' > "$run_dir/meta.json"
}

echo "=== reeval-marker smoke ==="

echo "  (a) marker on line 2 of a prior run's aggregator body -> fired=yes..."
rm -rf "$STATE_DIR/runs"; mkdir -p "$STATE_DIR/runs"
make_run "T100Z" $'_intent line_\n'"$MARKER"$'\n\n> banner prose\n'
if reeval_marker_fired "$MARKER" "$STATE_DIR" "$REPO_SLUG" "$PR_NUM" ""; then
    pass_msg "standalone marker on line 2 fires"
else
    fail_msg "standalone marker on line 2 should have fired"
fi

echo "  (b) marker string inside a fenced block 20+ lines into the body -> fired=no..."
rm -rf "$STATE_DIR/runs"; mkdir -p "$STATE_DIR/runs"
BODY=$'_intent line_\n\n**Probes**\n1. [medium] some finding\n'
i=0
while [ "$i" -lt 20 ]; do
    BODY+=$'filler probe line\n'
    i=$((i + 1))
done
BODY+=$'```text\n'"$MARKER"$'\n```\n'
make_run "T100Z" "$BODY"
if reeval_marker_fired "$MARKER" "$STATE_DIR" "$REPO_SLUG" "$PR_NUM" ""; then
    fail_msg "marker quoted inside a deep Sketch fence must NOT spoof the fired flag"
else
    pass_msg "marker inside a deep fence does not fire (fence content is data, not control)"
fi

echo "  (c) marker embedded mid-line (not a standalone line) -> fired=no..."
rm -rf "$STATE_DIR/runs"; mkdir -p "$STATE_DIR/runs"
make_run "T100Z" $'_intent line_\nsome text '"$MARKER"$' more text\n'
if reeval_marker_fired "$MARKER" "$STATE_DIR" "$REPO_SLUG" "$PR_NUM" ""; then
    fail_msg "marker embedded mid-line must NOT count as a fired standalone marker"
else
    pass_msg "mid-line marker substring does not fire"
fi

echo "  (d) fake separator + marker both inside a deep fence -> fired=no..."
rm -rf "$STATE_DIR/runs"; mkdir -p "$STATE_DIR/runs"
BODY=$'_intent line_\n\n**Probes**\n1. [medium] some finding\n'
i=0
while [ "$i" -lt 20 ]; do
    BODY+=$'filler probe line\n'
    i=$((i + 1))
done
BODY+=$'```text\n--- review at T999Z ---\n'"$MARKER"$'\n```\n'
make_run "T100Z" "$BODY"
if reeval_marker_fired "$MARKER" "$STATE_DIR" "$REPO_SLUG" "$PR_NUM" ""; then
    fail_msg "a fake in-fence separator + marker must NOT spoof the fired flag"
else
    pass_msg "fake separator inside a deep fence does not re-arm the window"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "PASS ($PASS checks)"
    exit 0
else
    echo "FAIL ($FAIL failed, $PASS passed)"
    exit 1
fi

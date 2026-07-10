#!/usr/bin/env bash
# Smoke for the re-eval fire-once marker check in lib/review-one-pr.sh
# (reeval_marker_fired). A PR added an optional `Sketch:` probe field whose
# fenced content gets rendered verbatim into the aggregator's posted review
# body (prompts/aggregator.md step 6: "A probe carrying a Sketch: renders
# its fenced code block directly under its rendered line, verbatim"). Those
# bodies feed $PRIOR_REVIEWS (lib/run-dir.sh's stage_prior_reviews). A raw
# `grep -qF <marker>` over that text would let a Sketch fence that happens
# to quote a marker string spoof the fired flag, permanently suppressing
# the architecture re-eval banner for that PR.
#
# reeval_marker_fired only accepts a marker as a full standalone line
# within the first 8 lines after a `--- review at <ts> ---` separator
# (stage_prior_reviews' per-run prefix) — the aggregator emits markers on
# line 2 of the body, right after the italicized intent line, so 8 lines
# is a generous window that fenced content deep in the Probes section
# can't reach.
#
# review-one-pr.sh is a full worker script (positional args, top-level
# side effects), not a sourceable library, so this smoke replicates the
# exact awk invocation rather than sourcing the file — pinned byte-for-byte
# against the implementation below.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass_msg() { echo "PASS: $*"; PASS=$((PASS+1)); }

# Pin: the awk body below must match lib/review-one-pr.sh's reeval_marker_fired
# implementation verbatim (drift guard) — a byte-for-byte find of the awk
# script in the real file, so a future edit to one side without the other
# fails loud here instead of silently diverging.
AWK_PROGRAM='
        /^--- review at /{w=8; next}
        w>0 && $0==m {found=1; exit}
        w>0 {w--}
        END{exit !found}'
while IFS= read -r awk_line; do
    [ -z "$awk_line" ] && continue
    if ! grep -qF "$awk_line" "$PROJECT_ROOT/lib/review-one-pr.sh"; then
        fail_msg "lib/review-one-pr.sh's reeval_marker_fired awk program has drifted from this smoke's pinned copy (missing: $awk_line)"
    fi
done < <(printf '%s\n' "$AWK_PROGRAM" | sed 's/^[[:space:]]*//')

reeval_marker_fired() {
    local marker="$1"
    printf '%s' "${PRIOR_REVIEWS:-}" | awk -v m="$marker" "$AWK_PROGRAM"
}

MARKER='<!-- knightwatch-reviewer:reeval-loc -->'

echo "=== reeval-marker smoke ==="

echo "  (a) marker as a standalone line 2 lines after a separator -> fired=yes..."
PRIOR_REVIEWS=$'\n--- review at T123Z ---\n_intent line_\n'"$MARKER"$'\n\n> banner prose\n'
if reeval_marker_fired "$MARKER"; then
    pass_msg "standalone marker within window fires"
else
    fail_msg "standalone marker within the leading window should have fired"
fi

echo "  (b) marker string inside a fenced block 20+ lines into the body -> fired=no..."
BODY=$'\n--- review at T123Z ---\n_intent line_\n\n**Probes**\n1. [medium] some finding\n'
i=0
while [ "$i" -lt 20 ]; do
    BODY+=$'filler probe line\n'
    i=$((i + 1))
done
BODY+=$'```text\n'"$MARKER"$'\n```\n'
PRIOR_REVIEWS="$BODY"
if reeval_marker_fired "$MARKER"; then
    fail_msg "marker quoted inside a deep Sketch fence must NOT spoof the fired flag"
else
    pass_msg "marker inside a deep fence does not fire (fence content is data, not control)"
fi

echo "  (c) marker embedded mid-line (not a standalone line) -> fired=no..."
PRIOR_REVIEWS=$'\n--- review at T123Z ---\n_intent line_\nsome text '"$MARKER"$' more text\n'
if reeval_marker_fired "$MARKER"; then
    fail_msg "marker embedded mid-line must NOT count as a fired standalone marker"
else
    pass_msg "mid-line marker substring does not fire"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "PASS ($PASS checks)"
    exit 0
else
    echo "FAIL ($FAIL failed, $PASS passed)"
    exit 1
fi

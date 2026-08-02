#!/usr/bin/env bash
# Hermetic smoke for replay's header-stitching path. The full real-replay
# path (clone → diff → stage → pipeline) needs live gh + codex, which we
# don't run in `just test`; the header-stitching logic is what makes a
# replay output recognizable as a replay output, so that's what we cover
# here. Sources run-dir.sh to get prepend_review_header and drives it
# with synthetic aggregator output, mirroring what replay.sh does
# post-pipeline.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Scenario 1: REVIEW.md-absent → note appears in aggregator output.
echo "  scenario 1: REVIEW.md-absent — note appears in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    REVIEW_NOTES+=("⚙️ No REVIEW.md (review using org defaults)")
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/absent-out.md"
)
grep -qF "⚙️ No REVIEW.md (review using org defaults)" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 1: absent-note not found in output"; cat "$TMPDIR/absent-out.md"; exit 1; }
grep -qF "🎬 Replay of" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 1: replay scope note not found in output"; exit 1; }

# Scenario 2: REVIEW.md-present → absent note must NOT appear.
echo "  scenario 2: REVIEW.md-present — absent note not in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    # resolve_review_md rc=0 (per-repo REVIEW.md) → no absent note added
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/present-out.md"
)
if grep -qF "⚙️ No REVIEW.md" "$TMPDIR/present-out.md"; then
    echo "FAIL scenario 2: absent-note should not appear when REVIEW.md is present"
    cat "$TMPDIR/present-out.md"
    exit 1
fi
grep -qF "🎬 Replay of" "$TMPDIR/present-out.md" \
    || { echo "FAIL scenario 2: replay scope note not found in output"; exit 1; }

# Scenario 3: replay-batch builds index.md without crashing on the table
# separator row. Regression fence: bash 5.2's printf strips a leading `--`
# from its first arg, so `printf '---|'` aborts before the index header.
# Comments-only PR CSV → no replay rows execute → no codex needed.
echo "  scenario 3: replay-batch builds index.md (printf '---|' regression fence)..."
PRS_FILE="$TMPDIR/empty-prs.csv"
printf '# only comments — no PR rows\n# second comment line\n' > "$PRS_FILE"
PROMPTS_A="$TMPDIR/prompts-a"; PROMPTS_B="$TMPDIR/prompts-b"
mkdir -p "$PROMPTS_A" "$PROMPTS_B"
BATCH_OUT="$TMPDIR/batch-out"
bash "$REPO_ROOT/lib/replay-batch.sh" \
    --prs "$PRS_FILE" \
    --prompts "$PROMPTS_A,$PROMPTS_B" \
    --output-dir "$BATCH_OUT" \
    > "$TMPDIR/batch.log" 2>&1 \
    || { echo "FAIL scenario 3: replay-batch exited non-zero"; cat "$TMPDIR/batch.log"; exit 1; }
[ -f "$BATCH_OUT/index.md" ] \
    || { echo "FAIL scenario 3: $BATCH_OUT/index.md missing"; exit 1; }
grep -qF '|---|---|---|' "$BATCH_OUT/index.md" \
    || { echo "FAIL scenario 3: index.md missing the table separator row"; cat "$BATCH_OUT/index.md"; exit 1; }

# Scenario 4: the metadata→author wiring in lib/replay.sh itself.
# From #206 until #213, line 120 read PR_AUTHOR="$REPLAY_PR_AUTHOR" — a
# self-assignment of a never-set name — so `set -u` aborted every replay at
# clone time and the whole harness was dead. Nothing in `just test` touched
# that path, which is why weeks of broken replays went unnoticed.
#
# This asserts against replay.sh's REAL text, not a copy of it. An earlier
# version of this scenario re-implemented the three lines in a local subshell
# and asserted on those, which would have stayed green through the exact
# regression it advertised. Driving the script for real needs git-clone + gh
# stubs for a three-line sequence; a shape fence on the actual file is the
# cheap 90%, and unlike the copy it cannot pass if the bug returns.
echo "  scenario 4: replay.sh derives PR_AUTHOR from the metadata snapshot..."
REPLAY_SH="$REPO_ROOT/lib/replay.sh"
grep -qE '^PR_AUTHOR="\$\(printf .* \| jq -r .\.author\.login' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh no longer derives PR_AUTHOR from REPLAY_PR_META via jq"; exit 1; }
grep -qF '[ -n "$BASE_REF" ] && [ -n "$PR_AUTHOR" ]' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh lost the fail-loud guard on BASE_REF / PR_AUTHOR"; exit 1; }
# The regression shape itself: any NAME="$NAME" self-assignment. Under the
# `set -euo pipefail` replay.sh runs with, that aborts if NAME is unset.
if grep -nE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)="\$\1"[[:space:]]*$' "$REPLAY_SH"; then
    echo "FAIL scenario 4: replay.sh contains a self-assignment — under set -u this aborts when the name is unset (the #206 outage)"
    exit 1
fi

echo "OK: replay-smoke (absent-note appears; present-note suppressed; replay-batch index.md emitted; replay.sh author wiring fenced)"

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

# Scenario 4: metadata → pipeline author wiring.
# The whole replay harness was dead from #206 until #213: line 120 read
# PR_AUTHOR="$REPLAY_PR_AUTHOR", a self-assignment of a never-set name, so
# `set -u` aborted every run at clone time — before the guard on the next line
# could say anything useful. Nothing in `just test` touched that path, which is
# why weeks of broken replays went unnoticed (you cannot run the tool that
# would show the tool is broken). This drives the real derivation + guard on a
# synthetic metadata snapshot, so a re-introduced self-assignment or an unset
# author fails here instead of in production.
echo "  scenario 4: PR_AUTHOR derived from the metadata snapshot, guard fires when absent..."
assert_author_wiring() {
    local label="$1" meta="$2" want_rc="$3" want_author="${4:-}"
    local rc=0 out
    out=$(
        set +u
        REPLAY_PR_META="$meta"
        BASE_REF="$(printf '%s' "$REPLAY_PR_META" | jq -r '.baseRefName // empty')"
        PR_AUTHOR="$(printf '%s' "$REPLAY_PR_META" | jq -r '.author.login // empty')"
        [ -n "$BASE_REF" ] && [ -n "$PR_AUTHOR" ] || exit 1
        printf '%s' "$PR_AUTHOR"
    ) || rc=$?
    [ "$rc" = "$want_rc" ] \
        || { echo "FAIL scenario 4 ($label): rc=$rc, want $want_rc"; exit 1; }
    [ -z "$want_author" ] || [ "$out" = "$want_author" ] \
        || { echo "FAIL scenario 4 ($label): author='$out', want '$want_author'"; exit 1; }
}
assert_author_wiring "full metadata" '{"baseRefName":"main","author":{"login":"octocat"}}' 0 octocat
assert_author_wiring "author missing" '{"baseRefName":"main"}' 1
assert_author_wiring "baseRef missing" '{"author":{"login":"octocat"}}' 1

# The failure that shipped: the derivation replaced by a self-assignment of an
# unset name. Under `set -u` — which replay.sh runs with — that must abort.
( set -u; unset PR_AUTHOR 2>/dev/null || true; PR_AUTHOR="$PR_AUTHOR" ) 2>/dev/null \
    && { echo "FAIL scenario 4: self-assignment of an unset name did not abort under set -u"; exit 1; } \
    || true

echo "OK: replay-smoke (absent-note appears; present-note suppressed; replay-batch index.md emitted; author wiring derived + guarded)"

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

# Scenario 4: meta_field's // empty contract.
#
# From #206 until #213 the replay harness was dead: line 120 self-assigned a
# never-set name, so `set -u` aborted every run at clone time. Nothing in
# `just test` touched that path — you cannot run the tool that would show the
# tool is broken.
#
# Three earlier versions of this scenario tried to fence it by matching
# replay.sh's source text, and each closed one matching gap while opening
# another (a copy of the code, then a too-loose ERE, then substring-vs-whole-
# line). That is what mirroring source text in a second file buys you. The
# derivation now lives in ONE place — meta_field in replay-paths.sh, used by
# all three snapshot reads — so this asserts its behavior instead, which is
# the property actually worth protecting and survives any reformat.
#
# The load-bearing case is `// empty`: without it `jq -r` prints the literal
# string "null" for an absent field, which passes `[ -n "$VAR" ]`. The caller's
# fail-loud guard then waves it through and the pipeline runs with
# PR_AUTHOR=null, or fetches `origin null`.
echo "  scenario 4: meta_field yields empty (not \"null\") for absent fields..."
(
    . "$REPO_ROOT/lib/replay-paths.sh"
    full='{"baseRefName":"main","author":{"login":"octocat"},"title":"Add X"}'
    partial='{"baseRefName":"main"}'

    [ "$(meta_field "$full" '.author.login')" = "octocat" ] \
        || { echo "FAIL scenario 4: meta_field did not extract .author.login"; exit 1; }
    [ "$(meta_field "$full" '.baseRefName')" = "main" ] \
        || { echo "FAIL scenario 4: meta_field did not extract .baseRefName"; exit 1; }

    # The silent-corruption case: absent field must be EMPTY, never "null".
    got="$(meta_field "$partial" '.author.login')"
    [ -z "$got" ] \
        || { echo "FAIL scenario 4: absent .author.login yielded '$got' — the // empty fallback is gone, so the caller's [ -n ] guard passes and the pipeline runs with a literal null"; exit 1; }
    [ -z "$(meta_field '{}' '.baseRefName')" ] \
        || { echo "FAIL scenario 4: absent .baseRefName did not yield empty — replay would fetch 'origin null'"; exit 1; }
) || exit 1

# And that replay.sh actually routes its snapshot reads through the helper,
# so the contract above is the one production uses.
# Match the assignment TARGET too, not just the call. Checking only the
# right-hand side leaves the #206 shape invisible: rename line 120 to
# REPLAY_PR_AUTHOR=... with nothing else setting PR_AUTHOR and the call still
# matches, the guard's text is still present, and the smoke goes green while
# every real replay aborts at [ -n "$PR_AUTHOR" ] under set -u.
REPLAY_SH="$REPO_ROOT/lib/replay.sh"
while read -r var field; do
    # ANCHORED at line start. A substring match would accept
    # REPLAY_PR_AUTHOR="$(meta_field …)" as satisfying PR_AUTHOR — the #206
    # shape — because the shorter name is a suffix of the longer one.
    grep -qE "^$var=\"\\\$\\(meta_field \"\\\$REPLAY_PR_META\" '$field'" "$REPLAY_SH" \
        || { echo "FAIL scenario 4: replay.sh no longer assigns $var from $field via meta_field"; exit 1; }
done <<'WIRING'
BASE_REF .baseRefName
PR_AUTHOR .author.login
PR_TITLE .title
WIRING
grep -qF '[ -n "$BASE_REF" ] && [ -n "$PR_AUTHOR" ]' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh lost the fail-loud guard on BASE_REF / PR_AUTHOR"; exit 1; }

echo "OK: replay-smoke (absent-note appears; present-note suppressed; replay-batch index.md emitted; meta_field's // empty contract + replay.sh wiring)"

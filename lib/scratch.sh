#!/usr/bin/env bash
# write_scratch — writes input artifacts into the run dir's inputs/ and
# exposes them under the codex-scratch view in the workdir so agents can
# read them via the paths their prompts cite (e.g. ".codex-scratch/diff.patch").
#
# Sourced by lib/review-one-pr.sh (production path) and lib/replay.sh
# (operator-bench replay) so both stage scratch with identical shape:
# real files at .codex-scratch/<name>, archived to $RUN_DIR/inputs/.
# Replay's prompt A/B comparison is only valid if its scratch shape
# matches production's — same primitive, same paths, same file layout.
#
# Every entry is a REAL FILE, never a symlink: agents enumerate
# .codex-scratch to discover what was staged, and `find -type f` can't see a
# symlink. See docs/specs/2026-05-04-python-migration-design.md for the
# incident that established this.
# build_author_intent <pr_json>
#   stdout: the author-intent.md body — the PR's title + description, plus any
#   linked issues as bare `owner/repo#num`.
#
#   <pr_json> is a `gh pr view --json title,body,closingIssuesReferences` blob.
#   Shared by both staging sites (production + replay) for the same reason
#   write_scratch is: a replay whose author-intent.md differs in heading text,
#   reference shape, or cap from production silently invalidates the prompt A/B
#   comparison. One builder, one privacy contract, one place to fence.
#
#   PRIVACY: stage ONLY `owner/repo#num` — never an issue's body, title, or
#   URL. The bot's identity can read issues the public PR audience cannot, so
#   any of those leaks into the posted review via the aggregator render path.
#   The bare reference is metadata GitHub already exposes through
#   `closingIssuesReferences` to anyone who can see the PR. This minimization
#   does NOT retire the consumer-side prohibition: the bare reference is itself
#   enough to retrieve the issue, so the tool-capable prompts must also be told
#   never to resolve it.
build_author_intent() {
    local pr_json="$1" issues
    # Control bytes stripped from the title for the same reason PR_TITLE is
    # sanitized: it flows into prompts and meta.json, where a newline injects.
    printf '## PR Title\n%s\n\n## PR Description (author'"'"'s own explanation)\n\n%s\n' \
        "$(printf '%s' "$pr_json" | jq -r '.title // empty' | tr '\000-\037\177' ' ')" \
        "$(printf '%s' "$pr_json" | jq -r '.body // "(no description provided)"')"
    # Slice inside jq rather than piping to `head`: under `set -o pipefail` a
    # SIGPIPE'd jq (141) would propagate out of the command substitution.
    issues=$(printf '%s' "$pr_json" \
        | jq -r '[.closingIssuesReferences // []][0][0:5][]? | "- \(.owner.login)/\(.repo.name)#\(.number)"' 2>/dev/null)
    [ -n "$issues" ] && printf '\n## Linked issues (this PR closes)\n\n%s\n' "$issues"
    return 0
}

write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local input_path="$RUN_DIR/inputs/$filename"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$(dirname "$input_path")" "$scratch_dir/specialists"
    # rm first: `>` follows a planted symlink out of the workdir; `ln -sfn`
    # never did. Fences the planted entry; the directory redirect is the
    # caller's wipe — both callers rm -rf + recreate .codex-scratch
    # immediately before their first write_scratch (grep "Redirect-safe
    # staging"), and in production that also lands after PR-controlled
    # execution.
    rm -f "$scratch_dir/$filename"
    printf '%s' "$content" > "$scratch_dir/$filename"
    cp "$scratch_dir/$filename" "$input_path"
}

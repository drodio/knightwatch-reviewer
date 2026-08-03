#!/usr/bin/env bash
# Per-repo config seam. Reads a path from the repo's base branch via
# `git show`. Trust model: base branch only — PR head edits don't take
# effect until merged.
#
# Per-repo reviewer *policy* lives in one repo-root REVIEW.md — see
# default_review_md below for what that file is scoped to carry and what it
# is not. Per-repo *mechanics*
# (sibling allowlist, dead-code command, strict-typing command) keep their own
# file under .knightwatch/ with the natural format for that concern
# (line-oriented, bash). No central manifest, no parser dependency.
#
# The helper reports presence/content/failure; callers decide policy.
# Each call site documents its own PRESENT-empty and ABSENT semantics.
# The one universal rule: every caller MUST treat (2) ERROR as a hard
# abort so transient git failures (broken base ref, corrupt object
# store, etc.) cannot be misread as absence.

# read_knightwatch_file <repo_dir> <base_ref> <relative_path>
#   stdout: file content from <base_ref>:.knightwatch/<rel>
#           (may be empty when the file exists but has no content)
#   exit:   0 — PRESENT: file exists at the base ref (content possibly empty)
#           1 — ABSENT:  file doesn't exist at the base ref
#           2 — ERROR:   git invocation failed for a non-absence reason
#
# <base_ref> is the caller's responsibility — typically a SHA snapshotted
# BEFORE any PR-controlled code (e.g. `just test`) has had a chance to
# rewrite local refs. Passing a SHA (immutable) instead of a branch
# name (mutable via `git update-ref`) is the trust model: PR-head
# edits to local refs cannot redirect the read after the SHA is
# captured. The caller in review-one-pr.sh snapshots
# `git rev-parse origin/$DEFAULT_BRANCH` once, before tests run.
#
# Implementation: `git ls-tree <base_ref> -- <path>` gives a clean
# tri-state via stdout + exit-code, no stderr-message parsing:
#   exit 0 + non-empty stdout → path exists at base ref → PRESENT
#   exit 0 + empty stdout     → path doesn't exist at base ref → ABSENT
#   exit non-zero             → ref/tree problem → ERROR
# This handles every "file absent from base ref" case identically —
# including the onboarding scenario where `.knightwatch/<file>` exists
# on the PR branch only (the working tree). cat-file's stderr-message
# discriminator failed there because git emits a different message
# ("exists on disk, but not in 'REF'") rather than the canonical
# "does not exist in 'REF'", so the prior implementation classified
# onboarding PRs as ERROR and aborted reviews. ls-tree only inspects
# the ref's tree and never produces that confusion.
read_repo_file() {
    local repo_dir="$1" base_ref="$2" target="$3"
    local listing
    if ! listing=$(git -C "$repo_dir" ls-tree "$base_ref" -- "$target" 2>/dev/null); then
        echo "knightwatch-config: ls-tree failed for $base_ref ($target)" >&2
        return 2
    fi
    [ -z "$listing" ] && return 1
    # ls-tree found it, so a failed content read is an ERROR, never absence.
    # Forwarding git's raw status (128, …) would satisfy neither caller's
    # `rc = 2` abort nor the `rc = 1` absent branch, and the empty output would
    # be silently substituted with org defaults plus a false no-policy notice.
    git -C "$repo_dir" show "${base_ref}:${target}" 2>/dev/null || {
        echo "knightwatch-config: show failed for $base_ref ($target)" >&2
        return 2
    }
}

# Same contract, scoped to the .knightwatch/ mechanics files (siblings,
# dead-code.sh, strict-typing.sh). Reviewer *prose* moved to REVIEW.md at
# the repo root — see resolve_review_md below.
read_knightwatch_file() {
    read_repo_file "$1" "$2" ".knightwatch/$3"
}

# Org-default REVIEW.md, injected when a repo commits none. Most repos here
# are pre-PMF with a handful of users; absent a per-repo override, reviewers
# assume that and optimize for iteration speed rather than silently reviewing
# for scale (the recurring over-engineering failure). Shared by production
# staging (lib/review-one-pr.sh) and operator-bench replay (lib/replay.sh) so
# the two paths can't drift — a reworded default reaches both at once. A repo
# with a different operating point overrides this by committing REVIEW.md.
#
# Scope: the operating point ONLY. Universal review policy (voice posture,
# decline rules, review-loop rules) lives in prompts/policy.md, which the
# pipeline prepends to every agent — it does not belong in a per-repo file
# and does not need restating for 38 repos.
default_review_md() {
    cat <<'REVIEW_MD_EOF'
# Review instructions (org default — no per-repo REVIEW.md configured)

No `REVIEW.md` is committed for this repo, so assume the org default operating point.

## Product context

- **Stage:** pre-PMF, early. Shipping and iteration speed matter more than hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions, flags, parallel modes, and defensive edge-case handling sized for thousands of users are over-engineering at this stage, not robustness.
- **Spec rigidity:** treat specs and inferred intent as sketches, not contracts. A handled edge case the intent never asked for is a cost, not a feature.
- **Optimize for developer time:** elegant, DRY code that is easy to build on; every maintained code path taxes iteration speed.

If this repo needs a different operating point, commit `REVIEW.md` to the base branch.
REVIEW_MD_EOF
}

# Resolve the reviewer-policy input for a review: the per-repo REVIEW.md at
# base_ref if committed and non-empty, else the org default. Both production
# (lib/review-one-pr.sh) and operator-bench replay (lib/replay.sh) call it, so
# the present/absent/error contract can't drift between them (it did, twice,
# when each open-coded its own tri-state).
#
# The status IS the classification, so callers never re-derive it. Every earlier
# attempt to recover "did this fall back?" outside this function diverged from
# what was actually staged — ls-tree at the PR head, ls-tree at the base ref,
# matching a sentinel string, and a companion predicate that re-read the tree.
# A return code survives command substitution where a variable assignment would
# die in the subshell, which is what makes one read enough.
#
# rc: 0 — the repo's own REVIEW.md was used
#     1 — the org default was substituted (caller should disclose this)
#     2 — ERROR, no output; every caller MUST treat this as a hard abort
resolve_review_md() {
    local repo_dir="$1" base_ref="$2" content rc status
    content=$(read_repo_file "$repo_dir" "$base_ref" "REVIEW.md") && rc=0 || rc=$?
    [ "$rc" = 2 ] && return 2
    if [ -n "$content" ]; then
        printf '%s\n' "$content"
        status=0
    else
        default_review_md
        status=1
    fi
    return "$status"
}

# Convention detection/staging (formerly is_seed_repo/seed_test_summary, which
# hardcoded SEED) now lives in lib/conventions.sh as a convention-agnostic
# resolver driven by the operator's kwr-config repo. SEED is one operator-supplied
# convention, not an engine literal.

#!/usr/bin/env bash
# Per-repo config seam. Reads .knightwatch/<file> from the repo's base
# branch via `git show`. Trust model: base branch only — PR head edits
# don't take effect until merged.
#
# Each per-repo concern (sibling allowlist, product context, review
# priority, dead-code command, strict-typing command) gets its own
# file under .knightwatch/ with the natural format for that concern
# (line-oriented, markdown, bash). No central manifest, no parser
# dependency.
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
    git -C "$repo_dir" show "${base_ref}:${target}" 2>/dev/null
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
# This carries the shared review-loop block verbatim, so a repo that hasn't
# migrated yet still gets the convergence, recurrence, and prose-severity
# rules. Keep it byte-identical to the block in the tracked repos' REVIEW.md
# (grep for `shared: review-loop`).
default_review_md() {
    cat <<'REVIEW_MD_EOF'
# Review instructions (org default — no per-repo REVIEW.md configured)

No `REVIEW.md` is committed for this repo, so assume the org default operating point.

## Product context

- **Stage:** pre-PMF, early. Shipping and iteration speed matter more than hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions, flags, parallel modes, and defensive edge-case handling sized for thousands of users are over-engineering at this stage, not robustness.
- **Spec rigidity:** treat specs and inferred intent as sketches, not contracts. A handled edge case the intent never asked for is a cost, not a feature.
- **Optimize for developer time:** elegant, DRY code that is easy to build on; every maintained code path taxes iteration speed.

## Review priority

- Apply `standards.md` § Broken-Glass Test on all findings (universal Broken-Glass policy).
- No repo-specific contrast pairs. The universal contrast pairs in `standards.md` apply.

If this repo needs a different operating point, commit `REVIEW.md` to the base branch.

<!-- shared: review-loop -->
## Review-loop rules

**Scope.** The two rules immediately below — re-review convergence and
recurring-file escalation — govern *repeat* review only: they apply when your
context already contains prior reviews covering the lines you are re-examining.
Code that is new in what you are reviewing is always in scope, and neither rule
may suppress a finding on it. When you cannot tell whether a prior review
covered a line, report normally. They exist to stop a loop that will not
terminate, never to let a review pass without looking. The severity floor at
the end is not scoped this way — it always applies.

### Re-review convergence

Once a finding has been raised and the author has responded to it, do not raise
it again in another shape. A second opinion on lines already reviewed and
already revised is not reportable at any severity — wording you would phrase
differently, a fix you would have shaped another way, or a consequence of your
own earlier suggestion. High-confidence correctness and security bugs are
exempt and stay reportable no matter how late they surface.

### Recurring-file escalation

If the prior reviews in your context have already flagged the same file two or
more times, stop reporting individual issues on the lines those reviews
covered. The recurrence *is* the finding.

Report it once, as a question naming the structural cost: which seam keeps
producing these, and what single change would make the class disappear? Lines
the change under review newly adds stay reportable as usual. Enumerating facet
N+1 of a churning file is the failure mode this rule exists to stop — every
individual finding can be correct while the sequence never terminates.

### Severity floor for prose

In `.md` files, findings about wording, phrasing, parallelism, sentence shape,
line reflow, and list construction are the lowest severity you emit — never
medium or higher — and are worth at most one line in the summary.

A factual claim in a doc that contradicts the code it describes is a normal
finding at normal severity: this floor covers style, not truth.
<!-- /shared -->
REVIEW_MD_EOF
}

# Resolve the reviewer-policy input for a review: the per-repo REVIEW.md at
# base_ref if committed and non-empty, else the org default. This is the SINGLE
# read+classify+default seam — both production (lib/review-one-pr.sh) and
# operator-bench replay (lib/replay.sh) call it, so the present/absent/error
# contract can't drift between them (it did, twice, when each open-coded its
# own tri-state). Echoes the resolved content and returns 0 on PRESENT or
# ABSENT (default substituted); returns 2 WITHOUT output on a git/ref ERROR so
# each caller keeps its own abort cleanup (production logs + rm -rf the
# checkout; replay just exits).
resolve_review_md() {
    local repo_dir="$1" base_ref="$2" content rc
    content=$(read_repo_file "$repo_dir" "$base_ref" "REVIEW.md") && rc=0 || rc=$?
    [ "$rc" = 2 ] && return 2
    [ -n "$content" ] && printf '%s' "$content" || default_review_md
}

# Convention detection/staging (formerly is_seed_repo/seed_test_summary, which
# hardcoded SEED) now lives in lib/conventions.sh as a convention-agnostic
# resolver driven by the operator's kwr-config repo. SEED is one operator-supplied
# convention, not an engine literal.

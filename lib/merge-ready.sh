#!/usr/bin/env bash
# Merge-ready scoping gate (SPARKLE FORK PATCH — not upstream).
#
# Policy: review only the PRs we are about to merge, not every open PR.
#
# Why this exists: MAX_CONCURRENT is forced to 1 in container mode
# (review.sh, REVIEWER_CONTAINER_MODE), while drodio/sparkle merges 27-165 PRs
# per day. One Codex account cannot serve that; it sits quota-paused and the
# review-loop skips ticks until the reset epoch. Narrowing WHICH PRs are
# eligible is what makes a single account viable. It does NOT raise the
# throughput ceiling — that is still one review at a time.
#
# Why a separate file: this is a fork patch, and upstream is active (~1-5
# commits/day). A new file upstream does not have can never conflict on a
# rebase, so the only conflict surface is the small call site in review.sh and
# the two field additions in lib/pr-enumerate.sh.
#
# Cost contract: this gate decides from fields already present in the
# enumeration payload (lib/pr-enumerate.sh fetches isDraft + labels in the SAME
# request). It must never make a per-PR API call — the idle-skip gate it sits
# beside exists precisely to avoid those, and a gate that spent one call per PR
# per tick per container would cost more quota than the reviews it prevents.

# Master switch. Set MERGE_READY_GATE=false to restore stock upstream behavior
# (review every eligible open PR) — useful when bisecting against upstream.
MERGE_READY_GATE="${MERGE_READY_GATE:-true}"

# Comma-separated labels that mark a PR as one we intend to merge. A PR
# carrying ANY of them passes. Empty is a configuration error, not "allow all"
# — see pr_is_merge_ready.
MERGE_READY_LABELS="${MERGE_READY_LABELS:-ready-for-review}"

# Draft PRs are never merge-ready. Separate switch so a repo that uses drafts
# differently can opt out without giving up the label gate.
SKIP_DRAFT_PRS="${SKIP_DRAFT_PRS:-true}"

# pr_is_merge_ready <pr_json>
#
# Returns 0 (review it) or 1 (skip it). Prints a short human reason on stdout
# for the caller to log; the caller decides the log line's shape.
#
# FAIL-CLOSED by construction. Every uncertain answer returns 1 (skip):
#   - enumeration payload missing the labels field  -> skip + loud reason
#   - MERGE_READY_LABELS empty                      -> skip + loud reason
#   - draft (when SKIP_DRAFT_PRS)                   -> skip
#   - no matching label                             -> skip
# Failing OPEN here would point the reviewer at the entire open backlog, which
# is the one outcome the bring-up plan forbids (it must be proven on a single
# throwaway PR first). A gate that silently stops gating is worse than one that
# silently stops reviewing: the second is visible as "no reviews", the first is
# only visible as a surprise bill and comments on real PRs.
pr_is_merge_ready() {
    local pr_json="$1" labels is_draft label matched

    # The enumeration patch (lib/pr-enumerate.sh) is what supplies these
    # fields. If a rebase onto upstream drops it, `has("labels")` goes false
    # and every PR would silently become un-reviewable. Name that explicitly
    # rather than letting it read as "nothing is labelled".
    if ! printf '%s' "$pr_json" | jq -e 'has("labels")' >/dev/null 2>&1; then
        printf 'enumeration payload has no labels field — the lib/pr-enumerate.sh fork patch is missing (rebase regression?)'
        return 1
    fi

    if [ -z "${MERGE_READY_LABELS//,/}" ]; then
        printf 'MERGE_READY_LABELS is empty — refusing to treat that as "review everything"'
        return 1
    fi

    if [ "$SKIP_DRAFT_PRS" = "true" ]; then
        is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
        if [ "$is_draft" = "true" ]; then
            printf 'draft'
            return 1
        fi
    fi

    labels=$(printf '%s' "$pr_json" | jq -r '(.labels // [])[]' 2>/dev/null)

    matched=""
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        case ",${MERGE_READY_LABELS}," in
            *",${label},"*) matched="$label"; break ;;
        esac
    done <<< "$labels"

    if [ -n "$matched" ]; then
        printf 'label %s' "$matched"
        return 0
    fi

    printf 'no merge-ready label (want one of: %s)' "$MERGE_READY_LABELS"
    return 1
}

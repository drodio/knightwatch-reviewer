#!/usr/bin/env bash
# Sourceable helper for fetching all issue-level comments on a PR.
#
# fetch_issue_comments REPO PR_NUM
#
# On success: prints one JSON array on stdout containing every issue-
# level comment on the PR (paginated transparently) and exits 0.
# On `gh` failure (auth lapse, network outage, rate limit): exits
# non-zero, prints nothing to stdout, and logs gh's stderr (so the
# failure is diagnosable, not swallowed to /dev/null). The non-zero exit is independent of
# the caller's pipefail setting — checked inline via command
# substitution, not the pipe — so every caller can wrap the call
# with `|| { log; continue; }` and get fail-loud behavior without
# needing `set -o pipefail` themselves.
#
# Why this exists: `gh api repos/<repo>/issues/<pr>/comments` returns
# only page 1 (default 30 items) without `--paginate`. Three orchestrator-
# level scripts consume this endpoint to scan for /srosro-* slash-command
# triggers (review.sh, poll-pr-actions.sh, learn-from-replies.sh) —
# any divergence between them silently drops triggers on long PR threads.
# In the original PR that surfaced this (cncorp/plow-content#1, ~30+ top-
# level comments), review.sh missed a /srosro-update-review trigger that
# was on page 2 and the orchestrator never dispatched a re-review for
# 30+ minutes — the same bug class approve-/learn-from-replies had
# already independently fixed in their own copies. Now there's one
# shared seam: any future caller of this endpoint goes through this
# helper and gets correct pagination — and a uniform failure contract —
# by construction.

# The shared definition of "the comment's first non-blank line". CRLF-normalized
# because GitHub's web UI returns \r\n, which would otherwise leave a \r before
# the terminator on every line but the last.
#
# jq consumers, all three built on this — never re-implementing it:
#   review.sh            `asks` (trigger + vouch selectors)
#   lib/pr-comments.sh   thread-staging filter
#   specialist-bakeoff.sh  pass-2 feedback scan
#
# ONE anchoring consumer deliberately does NOT share it: is_approve_request in
# poll-pr-actions.sh. It must extract the first line with a bash loop, because
# the pipeline form takes SIGPIPE on bodies past the pipe buffer and
# `set -o pipefail` turns that into "no approval". It is instead held
# semantically identical by hand, and that obligation is real — the two had
# already drifted on the blank-line class ([[:space:]] there vs [ \t] here,
# which made a leading vertical tab approve what this fragment read as
# no-request) and on \r handling. Both are aligned now.
#
# Fences, stated narrowly because per-edit attribution here has been wrong
# twice: `firstline` is exercised through `asks` by VOUCH_MATRIX (row 7800 — a
# \v first line — covers the blank class; row 7900 — a leading lone CR —
# covers \r normalization) and through is_approve_request by
# APPROVE_BODY_MATRIX's mirrors of the same two. `firstline_is`'s own
# `sub("^[ \t]+"; "")` is NOT covered by either: no staging or bake-off fixture
# has a \v/\f/lone-CR first line, so widening that class alone leaves both
# matrices green. Held by hand; widen it and nothing will tell you.
#
# Whatever you change here, change the bash twin too.
#
# Lives in this file because it is the common ancestor every jq consumer already
# sources.
JQ_FIRSTLINE='def firstline: (gsub("\r\n"; "\n") | split("\n")
                             | map(select(test("^[ \t]*$") | not)) | .[0] // "");
def firstline_is(m): (firstline | sub("^[ \t]+"; "") | startswith(m));'

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-retry.sh"  # defines gh() — the rate-limit seam

fetch_issue_comments() {
    local repo="$1" pr_num="$2" raw err
    # Capture gh's stderr (instead of 2>/dev/null) so a fetch failure logs its
    # real cause — auth/network/rate-limit/etc. — rather than surfacing only an
    # opaque "comments fetch failed" at the call site. stdout (the JSON) is
    # captured separately into $raw, so the success contract is unchanged.
    err=$(mktemp)
    if ! raw=$(gh api --paginate "repos/${repo}/issues/${pr_num}/comments" 2>"$err"); then
        printf 'fetch_issue_comments: gh api failed for %s#%s: %s\n' \
            "$repo" "$pr_num" "$(tr '\n' ' ' < "$err" | head -c 400)" >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf '%s' "$raw" | jq -s 'add // []'
}

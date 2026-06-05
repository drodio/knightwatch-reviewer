#!/bin/bash
# Single open-PR poller (every 2 min via systemd): enumerate the open PRs ONCE,
# then run both reply-driven actions per PR — the /<prefix>-approve check and the
# re-request-review trigger. Merged from the former pr-reviewer-approve (60s) +
# pr-reviewer-re-request (120s) timers so the enumeration is shared and the
# per-PR fetch rate against the shared srosro GitHub budget is halved.
#
# Mechanism per PR:
#   approve_check    — scan issue comments for a trusted /<prefix>-approve and
#                      submit gh pr review --approve (presence-deduped in
#                      approves-seen.json via the flock-safe state-io seen store).
#   rerequest_check  — scan the issue timeline for review_requested events
#                      targeting $BOT_USER and post a /<prefix>-review trigger,
#                      watermarked per PR by latest event time in re-request-seen.json.
set -o pipefail
# PATH inherited from the systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/poll.log}"
APPROVES_SEEN_FILE="${APPROVES_SEEN_FILE:-$STATE_DIR/approves-seen.json}"
RR_SEEN_FILE="${RR_SEEN_FILE:-$STATE_DIR/re-request-seen.json}"
# Tracked-repo manifest (single source of truth in repos.conf). The shared
# loader at lib/tracked-repos.sh is the ONE seam every consumer goes through.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
. "$REVIEWER_LIB_DIR/pr-enumerate.sh"
# log() + presence seen_get/seen_set (flock + atomic rename), is_trusted_repo_author,
# fetch_issue_comments — all shared with review.sh / learn-from-replies.sh.
. "$REVIEWER_LIB_DIR/auth.sh"
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/gh-comments.sh"
require_tracked_targets
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

[ -f "$APPROVES_SEEN_FILE" ] || echo '{}' > "$APPROVES_SEEN_FILE"
[ -f "$RR_SEEN_FILE" ] || echo '{}' > "$RR_SEEN_FILE"

# re-request tracks a per-PR timestamp watermark (latest handled event), not a
# presence marker, so it keeps its own value-storing seen helpers — state-io's
# seen_set only records presence (true). Named rr_* to avoid shadowing those.
rr_seen_get() { jq -r --arg k "$1" '.[$k] // empty' "$RR_SEEN_FILE"; }
rr_seen_set() {
    local tmp
    tmp=$(jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$RR_SEEN_FILE") || {
        log "rr_seen_set FAILED for key=$1 — next tick may repost this trigger"; return 1
    }
    printf '%s' "$tmp" > "$RR_SEEN_FILE"
}

# Opt-in signal: comment body must START with /<prefix>-approve on a line
# (optional leading whitespace, optional trailing args). A substring match would
# treat "don't use /srosro-approve yet" as an approval — wrong for this side effect.
is_approve_request() {
    printf '%s' "$1" | grep -qiE "^[[:space:]]*/${BOT_CMD_PREFIX}-approve([[:space:]]|$)"
}

# Submit gh pr review --approve for any new trusted /<prefix>-approve on the PR.
approve_check() {
    local REPO="$1" PR_NUM="$2" COMMENTS COMMENT BODY ID USER APPROVE_KEY APPROVE_BODY
    # On fetch failure, log loud + skip this PR for this tick rather than silently
    # treating "API broken" as "no comments". Pagination correctness lives in
    # lib/gh-comments.sh (shared) so callers can't reinvent the bug.
    COMMENTS=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
        log "$REPO#$PR_NUM: comments fetch failed — skipping approve check this tick"
        return 0
    }
    while IFS= read -r COMMENT; do
        BODY=$(echo "$COMMENT" | jq -r '.body')
        # Skip the bot's own auto-posts (footers/acks name /<prefix>-approve literally).
        printf '%s' "$BODY" | grep -qF "$BOT_AUTO_POST_MARKER" && continue
        is_approve_request "$BODY" || continue
        ID=$(echo "$COMMENT" | jq -r '.id')
        USER=$(echo "$COMMENT" | jq -r '.user.login')
        APPROVE_KEY="${REPO}#${PR_NUM}#${ID}"
        [ -n "$(seen_get "$APPROVES_SEEN_FILE" "$APPROVE_KEY")" ] && continue
        # Defensive bot filter (cheap pre-check before the trust API call).
        case "$USER" in
            *"[bot]"|"Copilot"|"copilot")
                log "$APPROVE_KEY: /${BOT_CMD_PREFIX}-approve from bot @$USER ignored"
                seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"; continue ;;
        esac
        # Trust gate: only push-access collaborators can trigger an approval.
        if ! is_trusted_repo_author "$REPO" "$USER"; then
            log "$APPROVE_KEY: /${BOT_CMD_PREFIX}-approve from @$USER ignored (no push access)"
            seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"; continue
        fi
        # Body carries the marker so later ticks (and review.sh's filter) treat it
        # as a bot post and don't reprocess.
        APPROVE_BODY="$BOT_AUTO_POST_MARKER
Approved on @${USER}'s /${BOT_CMD_PREFIX}-approve request."
        if gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" >/dev/null 2>>"$LOG_FILE"; then
            log "$APPROVE_KEY: approved on @${USER}'s request"
            seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY" \
                || log "$APPROVE_KEY: WARNING — seen_set failed AFTER successful approval; next tick may post a duplicate APPROVED review"
        else
            # Most common: self-approve, PR already merged/closed, transient error.
            # Mark seen so we don't retry forever; the human can re-post to retry.
            log "$APPROVE_KEY: gh pr review --approve FAILED — see log; marking seen"
            seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"
        fi
    done < <(echo "$COMMENTS" | jq -c '.[]')
}

# Translate a new GitHub "Re-request review" event into a /<prefix>-review trigger.
rerequest_check() {
    local REPO="$1" PR_NUM="$2" PR_KEY="$1#$2" LATEST LAST_SEEN
    # Latest review_requested event targeting our bot user, if any.
    LATEST=$(gh api "repos/$REPO/issues/$PR_NUM/timeline" --paginate 2>/dev/null \
        | jq -r --arg u "$BOT_USER" \
            '[.[] | select(.event == "review_requested" and .requested_reviewer.login == $u)] | last | .created_at // empty')
    [ -z "$LATEST" ] && return 0
    LAST_SEEN=$(rr_seen_get "$PR_KEY")
    # ISO-8601 timestamps compare lexically.
    if [ -n "$LAST_SEEN" ] && [ ! "$LATEST" \> "$LAST_SEEN" ]; then
        return 0
    fi
    log "$PR_KEY: re-request review event at $LATEST — posting /${BOT_CMD_PREFIX}-review trigger"
    # Bare command only — extra prose would be treated as requester framing by
    # the trigger-comment.md prompts.
    if gh pr comment "$PR_NUM" --repo "$REPO" --body "/${BOT_CMD_PREFIX}-review" >/dev/null 2>&1; then
        rr_seen_set "$PR_KEY" "$LATEST"
    else
        log "$PR_KEY: failed to post /${BOT_CMD_PREFIX}-review trigger comment"
    fi
}

ALL_PRS=$(enumerate_open_prs) || { log "enumerate_open_prs failed — skipping this tick"; exit 0; }

while IFS= read -r PR_JSON; do
    REPO=$(echo "$PR_JSON" | jq -r '.repository.nameWithOwner')
    PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
    approve_check "$REPO" "$PR_NUM"
    rerequest_check "$REPO" "$PR_NUM"
done < <(echo "$ALL_PRS" | jq -c '.[]')

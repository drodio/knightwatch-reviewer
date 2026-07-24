#!/usr/bin/env bash
# Common entrypoint setup for every poller/orchestrator (review.sh,
# poll-pr-actions.sh, learn-from-replies.sh): default the shared paths + bot
# identity and source the lib core. Source once, after setting REVIEWER_LIB_DIR.
# STATE_DIR uses :- so a consumer that derives paths from it above this source
# (review.sh) can pre-set it harmlessly. tracked-repos.sh is sourced first — it
# loads config.env, which the others and the consumer's require_*/container-mode
# logic read.
STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
# Marker prepended to every bot auto-post; the orchestrator's jq filter excludes
# any comment containing it so the bot never self-triggers. Must match the
# literal in lib/review-one-pr.sh — a smoke scenario catches drift.
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
# Marker on the re-request poller's auto-posted /<prefix>-review trigger. Unlike
# the auto-post marker above, a comment carrying THIS one still triggers a review
# (it must — that's its whole job); it only tells the orchestrator to treat the
# body as a bare command, dropping the poller's human-facing attribution note so
# it isn't weighted as requester framing. See poll-pr-actions.sh + review.sh.
BOT_AUTO_TRIGGER_MARKER="${BOT_AUTO_TRIGGER_MARKER:-<!-- knightwatch-reviewer:auto-trigger -->}"
# Marker on the orchestrator's "nothing to diff" decline post (review.sh). Its
# body also carries BOT_AUTO_POST_MARKER, so the trigger filters already ignore
# it and it can't self-trigger; this second marker is the idempotency key that
# keeps the skip path from re-posting the same decline every tick.
BOT_DECLINE_MARKER="${BOT_DECLINE_MARKER:-<!-- knightwatch-reviewer:already-reviewed -->}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
# Identity defaults land AFTER config.env (sourced by tracked-repos.sh above), so
# config.env is the single seam for all of them — matching lib/review-one-pr.sh
# and specialist-bakeoff.sh, which carry the same `:-` defaults and also source
# tracked-repos.sh first. Defaulting before it would make a `${BOT_USER:-…}`
# config.env entry a no-op here while it took effect there, moving the
# orchestrator's suppression fence and leaving the worker's behind. BOT_USER must
# name the identity $GH_TOKEN posts as: two fences match on it — the worker's
# placeholder reuse and the orchestrator's already-reviewed decline — and both
# fail OPEN if it drifts, re-posting comments the bot no longer recognizes.
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
. "$REVIEWER_LIB_DIR/auth.sh"
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/gh-comments.sh"

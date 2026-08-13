#!/usr/bin/env bash
# Common entrypoint setup for every poller/orchestrator (review.sh,
# poll-pr-actions.sh, learn-from-replies.sh): default the shared paths + bot
# identity and source the lib core. Source once, after setting REVIEWER_LIB_DIR.
# STATE_DIR uses :- so a consumer that derives paths from it above this source
# (review.sh) can pre-set it harmlessly. tracked-repos.sh is sourced first — it
# loads config.env, which the others and the consumer's require_*/container-mode
# logic read.
STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
# Marker prepended to every bot auto-post. PRODUCER-SIDE CONTRACT, two parts:
# lead the body with this marker (never with a slash command), and post as
# $BOT_USER. Both are load-bearing, for different consumers.
#
# Marker-first covers the REQUEST selectors — `asks` (review.sh: trigger and
# vouch) and is_approve_request (poll-pr-actions.sh). Those read only the first
# non-blank line, so a marker-first body cannot read as a request. They carry no
# body-wide "contains this marker" test: it was redundant against every real
# producer and silently dropped genuine requests whose author quoted a bot post
# below their command (#221).
#
# $BOT_USER covers the one command consumer marker-first does NOT protect:
# is_memorize_request (learn-from-replies.sh) matches body-wide and unanchored,
# so a marker-first body CAN read as a memorize request there. What stops it is
# that file's author filter plus its ACK defanging — not anchoring.
#
# Two body-wide marker consumers remain by design, so a grep hit is not drift:
# lib/pr-comments.sh (staging: anchored for auto-post, body-wide for the
# auto-trigger marker) and specialist-bakeoff.sh's SUBSTANTIVE_REVIEW_JQ, which
# uses containment POSITIVELY to identify bot reviews. That file's pass-2
# feedback scan is anchored like everything else — do not "fix" it back.
#
# Must match the literal in lib/review-one-pr.sh — a smoke scenario catches drift.
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
# Marker on the re-request poller's auto-posted /<prefix>-review trigger. Unlike
# the auto-post marker above, a comment carrying THIS one still triggers a review
# (it must — that's its whole job); it only tells the orchestrator to treat the
# body as a bare command, dropping the poller's human-facing attribution note so
# it isn't weighted as requester framing. See poll-pr-actions.sh + review.sh.
BOT_AUTO_TRIGGER_MARKER="${BOT_AUTO_TRIGGER_MARKER:-<!-- knightwatch-reviewer:auto-trigger -->}"
# Marker on the orchestrator's "nothing to diff" decline post (review.sh). Its
# body leads with BOT_AUTO_POST_MARKER, so first-line anchoring keeps it from
# self-triggering; this second marker is the idempotency key that keeps the
# skip path from re-posting the same decline every tick.
BOT_DECLINE_MARKER="${BOT_DECLINE_MARKER:-<!-- knightwatch-reviewer:already-reviewed -->}"

. "$REVIEWER_LIB_DIR/tracked-repos.sh"
. "$REVIEWER_LIB_DIR/auth.sh"
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/gh-comments.sh"

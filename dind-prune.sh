#!/bin/bash
# Prune stale per-PR scenario images inside each reviewer sandbox's NESTED
# Docker daemon. Runs via the pr-reviewer-dind-prune.timer systemd unit.
#
# Why this can't be a host-level prune: each dind sidecar keeps its docker root
# in a host volume (knightwatch-reviewer_dindN-lib). The host daemon sees that
# volume as in-use by the running dind container and has no visibility into the
# images inside it, so a host `docker image prune` reclaims 0 B against this
# storage no matter how often it runs. Measured 2026-08-13: 1.35 TB accumulated
# across six sandboxes over ~7 weeks while the daily host prune ran clean and
# the root filesystem went to 100% (12 G free on 1.8 T).
#
# What accumulates: `just test` builds per-PR scenario images — roughly 5
# images / ~3.9 GB per PR. Once that PR's review rounds finish they are dead
# weight that nothing will ever hit again.
#
# What deliberately is NOT collected: named volumes. Measured on the same
# fleet, every sandbox carries the same three (plow_db-data, plow_minio-data,
# plow_test-db-data) — a fixed working set reused across PRs, ~17 GB fleet-wide
# against 1.29 TB of images, and NOT growing with PR count. Anonymous volumes
# are already reaped per-review by `docker rm -fv` in lib/run-dir.sh. A
# `volume prune -af` here would delete the working set the next review reuses
# (forcing a database re-seed) to reclaim storage that was no part of the
# incident.

set -u
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="$STATE_DIR/dind-prune.log"

# How old a per-PR image must be before it is collectable. A /babysit-pr loop
# re-reviews the same PR across days and does reuse that PR's images, so this
# window is what keeps the prune from forcing a ~4 GB scenario rebuild
# mid-loop.
#
# Known limit, accepted rather than engineered around: a cache-hit rebuild does
# not refresh Created, so this measures time since FIRST build, not since last
# use. A review loop still running past the window loses its images despite
# active reuse. Docker exposes no last-used timestamp for images, and the only
# fix would couple this script to the reviewer containers' workdir list; the
# cost of being wrong is one rebuild, so it is left as is.
PRUNE_HOURS="${PRUNE_HOURS:-168}"

# Per-PR images are named for the compose project, which docker compose derives
# from the workdir basename review.sh creates: <owner>_<repo>__<PR#> (live
# examples: cncorp_plow__885, plow-pbc_plow__1167). So every collectable image
# repository carries `__<digits>-` and nothing else does.
#
# Matching the NAME and testing age only afterwards is load-bearing, not a
# stylistic choice. `docker image prune -a --filter until=` keys off an image's
# Created timestamp, which for a PULLED base image is the UPSTREAM build date —
# on this fleet python:3.12-slim reads two months old and ubuntu:24.04 four. A
# blanket `-a --filter until=168h` therefore deletes precisely the base layers
# most worth keeping (the sandboxes hold no registry credentials, so re-pulling
# them is anonymous against Docker Hub's per-IP budget shared by all six
# sandboxes and the host) while KEEPING the freshly-built per-PR images it was
# meant to collect. Locally-built images are the one case where Created really
# does mean "built recently", which is why the age test is sound here and only
# here.
PR_IMAGE_RE='__[0-9]+-'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Raised by any nested prune that fails, so the run exits nonzero instead of
# letting systemd report a clean tick over storage that was never reclaimed.
# A sandbox that is merely busy or not yet up does NOT raise it: those are
# expected states the next tick handles, and a chronically red unit is one the
# operator learns to ignore.
FAILED=0

# Run a nested docker command; echo its last output line, return its status.
# Piping `docker exec` straight into `tail` would hand the pipeline tail's exit
# status and mask the error entirely, which is the whole point of this helper.
#
# It logs but does NOT set FAILED: every call site is a `$(...)` command
# substitution, which runs in a subshell, so an assignment here would be
# discarded while the log write (a file append) survived — a failure that
# reports in the journal yet still exits 0. Callers raise FAILED themselves.
nested() {
    local c="$1"; shift
    local out
    if out=$(docker exec "$c" docker "$@" 2>&1); then
        printf '%s\n' "$out" | tail -1
        return 0
    fi
    log "$c: 'docker $1' failed -- $(printf '%s\n' "$out" | tail -1)"
    return 1
}

# Count containers running inside a sandbox's nested daemon. Fails loudly
# rather than reporting 0: an unreachable daemon read as "idle" would let the
# destructive phases below fire against a sandbox we cannot actually see into.
# One attempt, no retry — at a 6-hourly cadence against a 7-week accumulation
# horizon, a sandbox whose dockerd is still starting is simply collected on the
# next tick.
nested_running() {
    local out
    out=$(docker exec "$1" docker ps -q 2>&1) || { printf '%s' "$out"; return 1; }
    printf '%s\n' "$out" | sed '/^$/d' | wc -l
}

# Enumerate sandboxes by compose service label rather than by hardcoded
# container names: lib/render-compose.sh renders the fleet to N units and the
# operator changes N. Capture the exit status separately — a `docker ps` that
# fails (daemon not up yet on a boot catch-up run, socket permission) yields an
# empty list, which would otherwise be indistinguishable from "no sandboxes"
# and log a false all-clear on the very day the prune was needed.
if ! PS_ALL=$(docker ps --format '{{.Names}}	{{.Label "com.docker.compose.service"}}' 2>&1); then
    log "FATAL: host docker unreachable -- $PS_ALL"
    exit 1
fi

mapfile -t DINDS < <(printf '%s\n' "$PS_ALL" | awk -F'\t' '$2 ~ /^dind/ { print $1 }' | sort)

if [ "${#DINDS[@]}" -eq 0 ]; then
    log "no dind sandboxes running -- nothing to prune"
    exit 0
fi

CUTOFF=$(date -d "$PRUNE_HOURS hours ago" +%s)

for C in "${DINDS[@]}"; do
    if ! RUNNING=$(nested_running "$C"); then
        log "$C: nested daemon unreachable -- skipping ($RUNNING)"
        continue
    fi
    if [ "$RUNNING" -ne 0 ]; then
        log "$C: $RUNNING container(s) running -- skipping (review in flight)"
        continue
    fi

    # Same fail-loud contract as the host `docker ps` above: an errored list
    # read as "no images" would log a clean green tick while the sandbox refills.
    if ! IMAGES=$(docker exec "$C" docker images --format '{{.Repository}}:{{.Tag}}	{{.CreatedAt}}' 2>&1); then
        log "$C: cannot list images -- skipping ($(printf '%s' "$IMAGES" | tail -1))"
        FAILED=1
        continue
    fi

    # Select TAGS, never bare image IDs. Two PRs whose build context is
    # identical produce one cache-hit image carrying both tags, and
    # `docker rmi <id>` refuses a multi-repository image ("must be forced") —
    # so an ID-based sweep would skip exactly the repeat-build case that
    # accumulates fastest. Removing by tag untags only what matched and lets
    # Docker free the image with its last tag; deduping would be wrong here.
    STALE=(); UNPARSED=0
    while IFS=$'\t' read -r tag created; do
        [ -n "$tag" ] || continue
        [[ "$tag" =~ $PR_IMAGE_RE ]] || continue
        # CreatedAt renders as "<date> <time> <offset> <zone-name>". Take only
        # the first three fields: the zone NAME varies with the daemon's TZ and
        # date(1) cannot parse it, while the numeric offset is unambiguous.
        built=$(date -d "$(printf '%s' "$created" | awk '{print $1, $2, $3}')" +%s 2>/dev/null) || {
            UNPARSED=$((UNPARSED + 1)); continue
        }
        [ "$built" -lt "$CUTOFF" ] && STALE+=("$tag")
    done < <(printf '%s\n' "$IMAGES")

    # Never let a parse failure masquerade as "nothing to collect".
    [ "$UNPARSED" -eq 0 ] \
        || log "$C: WARNING -- $UNPARSED image timestamp(s) unparseable, those images were not considered"

    if [ "${#STALE[@]}" -ne 0 ]; then
        # No -f: an image still referenced by a container must survive. A
        # nonzero status here is the benign mid-run race (a review started
        # since the idle check, so one tag is now in use) — surfaced in the log
        # but deliberately not raising FAILED, unlike a whole-phase prune
        # failure below.
        RMI=$(docker exec "$C" docker rmi "${STALE[@]}" 2>&1)
        UNTAGGED=$(printf '%s\n' "$RMI" | grep -c '^Untagged:')
        log "$C: ${#STALE[@]} stale per-PR tag(s) selected, $UNTAGGED untagged"
        ERRS=$(printf '%s\n' "$RMI" | grep -i '^error' | tail -1)
        [ -z "$ERRS" ] || log "$C: rmi reported errors -- $ERRS"
    else
        log "$C: no per-PR images older than ${PRUNE_HOURS}h"
    fi

    # Dangling layers only — deliberately NOT `-a`, per the header note.
    DANGLING=$(nested "$C" image prune -f) || { DANGLING="FAILED"; FAILED=1; }
    # BuildKit's until= DOES key off last use, unlike the image filter, so the
    # age window means what it says here. Build cache is a first-class consumer
    # in a sandbox that rebuilds ~4 GB of scenario stacks per PR.
    BUILDER=$(nested "$C" builder prune -f --filter "until=${PRUNE_HOURS}h") || { BUILDER="FAILED"; FAILED=1; }
    log "$C: dangling -- ${DANGLING:-no output}; build cache -- ${BUILDER:-no output}"
done

exit "$FAILED"

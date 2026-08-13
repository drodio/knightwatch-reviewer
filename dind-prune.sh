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

set -u
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/dind-prune.log}"
LOCK="${LOCK:-$STATE_DIR/dind-prune.lock}"

# How old a per-PR image must be before it is collectable. A /babysit-pr loop
# re-reviews the same PR across days and does reuse that PR's images, so this
# window is what keeps the prune from forcing a ~4 GB scenario rebuild
# mid-loop.
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

# Serialize against a manual `systemctl start` landing on top of a timer run.
# flock releases on process death, so a killed run leaves nothing to clean up.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another prune holds $LOCK -- skipping"
    exit 0
fi

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

# Count containers running inside a sandbox's nested daemon. Fails loudly
# rather than reporting 0: an unreachable daemon read as "idle" would let the
# destructive phases below fire against a sandbox we cannot actually see into.
nested_running() {
    local out
    out=$(docker exec "$1" docker ps -q 2>&1) || { printf '%s' "$out"; return 1; }
    printf '%s\n' "$out" | sed '/^$/d' | wc -l
}

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

    mapfile -t STALE < <(
        docker exec "$C" docker images --format '{{.ID}}	{{.Repository}}	{{.CreatedAt}}' 2>/dev/null \
            | while IFS=$'\t' read -r id repo created; do
                [[ "$repo" =~ $PR_IMAGE_RE ]] || continue
                # `docker` prints "... +0000 UTC"; date(1) parses the offset but
                # not the trailing zone name, so drop it.
                built=$(date -d "${created% UTC}" +%s 2>/dev/null) || continue
                [ "$built" -lt "$CUTOFF" ] && echo "$id"
            done | sort -u
    )

    if [ "${#STALE[@]}" -ne 0 ]; then
        # No -f: an image still referenced by a container must survive. rmi
        # reports per-image errors and removes the rest, which is exactly the
        # behavior wanted if a review started since the idle check above.
        OUT=$(docker exec "$C" docker rmi "${STALE[@]}" 2>&1 | tail -1)
        log "$C: removed ${#STALE[@]} stale per-PR image(s) -- ${OUT:-no output}"
    else
        log "$C: no per-PR images older than ${PRUNE_HOURS}h"
    fi

    # Dangling layers only — deliberately NOT `-a`, per the header note.
    docker exec "$C" docker image prune -f >/dev/null 2>&1
    # BuildKit's until= DOES key off last use, unlike the image filter, so the
    # age window means what it says here. Build cache is a first-class consumer
    # in a sandbox that rebuilds ~4 GB of scenario stacks per PR.
    docker exec "$C" docker builder prune -f --filter "until=${PRUNE_HOURS}h" >/dev/null 2>&1

    # Re-check idle immediately before the volume sweep. The image work above
    # runs for minutes on a backlogged sandbox and review-loop.sh polls
    # continuously, so the check at the top of this iteration is stale by now.
    # This phase is the one that can destroy a live scenario's state: `docker
    # volume prune` accepts no until= filter, and -a is required to reach NAMED
    # volumes (compose names the per-PR scenario stacks' volumes, so without -a
    # this reclaims nothing) — which also means -a will take a running
    # scenario's database volume if the sandbox turned busy.
    if ! RUNNING=$(nested_running "$C") || [ "$RUNNING" -ne 0 ]; then
        log "$C: busy or unreachable after image phase -- skipping volume prune"
        continue
    fi
    VOL=$(docker exec "$C" docker volume prune -af 2>&1 | tail -1)
    log "$C: volumes -- ${VOL:-no output}"
done

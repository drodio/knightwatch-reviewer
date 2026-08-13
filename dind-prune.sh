#!/bin/bash
# Prune stale per-PR scenario images inside each reviewer sandbox's NESTED
# Docker daemon. Runs daily via the pr-reviewer-dind-prune.timer systemd unit.
#
# Why this can't be a host-level prune: each dind sidecar keeps its docker root
# in a host volume (knightwatch-reviewer_dindN-lib). The host daemon sees that
# volume as in-use by the running dind container and has no visibility into the
# images inside it, so a host `docker image prune` reclaims 0 B against this
# storage no matter how often it runs. Measured 2026-08-13: 1.35 TB accumulated
# across six sandboxes over ~7 weeks while the daily host prune ran clean and
# the root filesystem went to 100% (12 G free on 1.8 T).
#
# What accumulates: `just test` builds per-PR scenario images tagged
# <project>__<PR#>-scenarios-<service> — roughly 5 images / ~3.9 GB per PR. The
# PR number is baked into the tag, so once that PR's review rounds finish those
# images are dead weight that nothing will ever hit again.

set -u
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/dind-prune.log}"
LOCK="${LOCK:-$STATE_DIR/dind-prune.lock}"

# Keep a week of images. Deliberately NOT an unconditional prune -- three costs
# the age filter buys off:
#   1. A /babysit-pr loop re-reviews the same PR across days and DOES reuse that
#      PR's __<PR#>-* images. Pruning mid-loop forces a ~4 GB scenario rebuild.
#   2. The sandboxes run no registry mirror and hold no registry credentials, so
#      every base-layer re-pull is anonymous against Docker Hub's 100-per-6h
#      per-IP budget -- shared by all six sandboxes and the host.
#   3. It sidesteps racing a review that has built or pulled an image but not
#      yet created the container that would protect it.
# At the measured ~28 GB/day growth rate a 168h window holds steady state near
# 200 GB, against the 1.35 TB that no window at all produced.
PRUNE_UNTIL="${PRUNE_UNTIL:-168h}"

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
# operator changes N.
mapfile -t DINDS < <(
    docker ps --format '{{.Names}}	{{.Label "com.docker.compose.service"}}' \
        | awk -F'\t' '$2 ~ /^dind/ { print $1 }' | sort
)

if [ "${#DINDS[@]}" -eq 0 ]; then
    log "no dind sandboxes running -- nothing to prune"
    exit 0
fi

for C in "${DINDS[@]}"; do
    if ! PS_OUT=$(docker exec "$C" docker ps -q 2>&1); then
        log "$C: nested daemon unreachable -- skipping ($PS_OUT)"
        continue
    fi

    # Skip a sandbox with a review in flight. The image prune's until= filter
    # already protects fresh layers, but `docker volume prune` accepts only
    # label= filters (no until=), so this idle check is the only thing keeping
    # it from pulling scratch volumes out from under a running scenario.
    RUNNING=$(printf '%s\n' "$PS_OUT" | sed '/^$/d' | wc -l)
    if [ "$RUNNING" -ne 0 ]; then
        log "$C: $RUNNING container(s) running -- skipping (review in flight)"
        continue
    fi

    IMG=$(docker exec "$C" docker image prune -af --filter "until=$PRUNE_UNTIL" 2>&1 | tail -1)
    VOL=$(docker exec "$C" docker volume prune -f 2>&1 | tail -1)
    log "$C: images -- ${IMG:-no output}; volumes -- ${VOL:-no output}"
done

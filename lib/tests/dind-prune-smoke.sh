#!/bin/bash
# dind-prune.sh guards. The script is destructive against live sandboxes, so
# every guard that stands between it and a running review is asserted here
# against a stubbed `docker` — there is no daemon at unit-test time.
#
# The headline case is the base-image one: an earlier draft used
# `docker image prune -a --filter until=`, which keys off an image's Created
# timestamp. For a pulled base image that is the UPSTREAM build date, so the
# blanket form deleted python:/ubuntu: (forcing anonymous Docker Hub re-pulls
# across six sandboxes) while keeping the fresh per-PR images it was meant to
# collect. The name-match-then-age-test contract is what fixes that, and the
# assertions below pin both halves.
set -u

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/dind-prune.sh"

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin"

echo "=== dind-prune smoke ==="

# Fixture dates are computed relative to now, never hardcoded: a literal date
# would silently cross the 168h window as real time passed and turn the
# "recent image is kept" assertion into a false pass.
OLD_DATE=$(date -u -d '30 days ago' '+%Y-%m-%d %H:%M:%S +0000 UTC')
NEW_DATE=$(date -u -d '1 hour ago'  '+%Y-%m-%d %H:%M:%S +0000 UTC')

# Host `docker ps` view: two sandboxes, plus a reviewer and a db that must
# never be touched (the ^dind service-label filter is the only thing excluding
# them).
cat > "$d/host-ps" <<HOSTPS
knightwatch-reviewer-dind-1-1	dind-1
knightwatch-reviewer-dind-2-1	dind-2
knightwatch-reviewer-reviewer-1-1	reviewer-1
plow-db-1	db
HOSTPS

# Nested image inventory, as repo:tag + CreatedAt. Collectable: the two stale
# per-PR tags only.
#   __950 / __951 — a cache-hit twin pair. Identical build context yields ONE
#                   image id under two tags; selecting by id and deduping would
#                   collapse them and then fail rmi outright ("referenced in
#                   multiple repositories, must be forced"), which is why
#                   selection is by tag. Both must be untagged.
#   __962         — per-PR but built inside the window (a live /babysit-pr loop)
#   python/ubuntu — base images, Created months ago, no __<digits>- in the repo
cat > "$d/images" <<IMAGES
cncorp_plow__950-scenarios-plow-api:latest	$OLD_DATE
cncorp_plow__951-scenarios-plow-api:latest	$OLD_DATE
cncorp_plow__962-scenarios-plow-api:latest	$NEW_DATE
python:3.12-slim	$OLD_DATE
ubuntu:24.04	$OLD_DATE
IMAGES

# Zone NAME varies with the daemon's TZ and date(1) cannot parse it; only the
# numeric offset is portable. A row that still won't parse must be counted and
# surfaced, never silently dropped into a clean all-clear.
cat > "$d/images-badtime" <<BADTIME
cncorp_plow__950-scenarios-plow-api:latest	not-a-timestamp
BADTIME

cat > "$d/bin/docker" <<STUB
#!/bin/bash
echo "docker \$*" >> "\$CALLS"
if [ "\$1" = exec ]; then
    C="\$2"; shift 3   # drop: exec, <container>, the nested "docker"
    case "\$1 \${2:-}" in
        "ps -q")
            [ "\$C" = "\${PS_FAIL_DIND:-}" ] && {
                echo "Cannot connect to the Docker daemon at tcp://127.0.0.1:2375" >&2; exit 1; }
            [ "\$C" = "\${BUSY_DIND:-}" ] && echo deadbeefcafe
            exit 0 ;;
        "images --format")
            [ -n "\${IMAGES_FAIL:-}" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
            cat "\${IMAGES_FIXTURE:-$d/images}"; exit 0 ;;
        "rmi "*)
            # RMI_FAIL: every tag conflicts (stopped containers pin them all) —
            # the permanent zero-reclaim shape. Default: all tags untag.
            if [ -n "\${RMI_FAIL:-}" ]; then
                echo "conflict: unable to remove repository reference: container 9f2 is using it" >&2
                exit 1
            fi
            shift; for t in "\$@"; do echo "Untagged: \$t"; done; exit 0 ;;
        "image prune")
            [ -n "\${PRUNE_FAIL:-}" ] && { echo "Error response from daemon: prune failed" >&2; exit 1; }
            echo "Total reclaimed space: 1.5GB"; exit 0 ;;
        "builder prune") echo "Total reclaimed space: 2GB"; exit 0 ;;
    esac
    exit 0
fi
if [ "\$1" = ps ]; then
    [ -n "\${HOST_PS_FAIL:-}" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    cat "$d/host-ps"; exit 0
fi
exit 0
STUB
chmod +x "$d/bin"/*
export PATH="$d/bin:$PATH"
export CALLS="$d/docker.calls"

run_prune() { : > "$CALLS"; : > "$d/dind-prune.log"; STATE_DIR="$d" bash "$SCRIPT"; }

# --- (a) happy path: stale per-PR images collected, bases and fresh kept -----
echo "  (a) collects stale per-PR images, keeps base + in-window images..."
run_prune || fail "(a) clean run exited non-zero"

grep -q "rmi.*__950" "$CALLS" || fail "(a) stale per-PR tag __950 was not removed"
grep -q "rmi.*__951" "$CALLS" || fail "(a) cache-hit twin __951 was not removed — id-dedupe regression"
grep -q "rmi.*__962" "$CALLS" && fail "(a) removed __962, a per-PR image still inside the window"
grep -q "rmi.*python" "$CALLS" && fail "(a) removed python base image — the Created-vs-pulled inversion is back"
grep -q "rmi.*ubuntu" "$CALLS" && fail "(a) removed ubuntu base image — the Created-vs-pulled inversion is back"

# Both twins must ride in ONE rmi call, by tag, with no id-dedupe collapsing them.
grep -qE "rmi .*__950.*__951|rmi .*__951.*__950" "$CALLS" \
    || fail "(a) cache-hit twins were not passed together as tags"

# The regression guard proper: no code path may reintroduce the blanket sweep.
grep -qE "image prune.*-a|image prune.*--all" "$CALLS" \
    && fail "(a) 'docker image prune -a' reintroduced — it deletes base images by upstream Created date"
grep -q "image prune -f" "$CALLS" || fail "(a) dangling-layer prune never ran"

# Named volumes are a fixed working set reused across PRs (~17 GB fleet-wide vs
# 1.29 TB of images), and lib/run-dir.sh already reaps anonymous ones per review.
# Pruning them here would delete the set the next review reuses.
grep -q "volume prune" "$CALLS" && fail "(a) volume prune reintroduced — deletes the reused working set for no reclaim"
grep -q "builder prune" "$CALLS" || fail "(a) BuildKit cache never pruned"

# Every reclaim phase must report into the journal — a muted phase turns a
# failed prune into a green tick.
grep -q "dangling --"    "$d/dind-prune.log" || fail "(a) dangling prune result never logged"
grep -q "build cache --" "$d/dind-prune.log" || fail "(a) builder prune result never logged"
echo "  PASS"

# --- (b) only ^dind services are targeted -----------------------------------
echo "  (b) reviewer/db containers are never entered..."
grep -q "exec knightwatch-reviewer-reviewer-1-1" "$CALLS" && fail "(b) entered a reviewer container"
grep -q "exec plow-db-1" "$CALLS" && fail "(b) entered the db container"
echo "  PASS"

# --- (c) a busy sandbox is skipped entirely ---------------------------------
echo "  (c) sandbox with a review in flight is skipped..."
BUSY_DIND=knightwatch-reviewer-dind-2-1 run_prune || fail "(c) run exited non-zero"
grep -q "exec knightwatch-reviewer-dind-2-1 docker rmi" "$CALLS" \
    && fail "(c) removed images from a sandbox with a running container"
grep -q "exec knightwatch-reviewer-dind-1-1 docker rmi" "$CALLS" \
    || fail "(c) idle sibling sandbox was skipped too"
echo "  PASS"

# --- (d) host docker failure is loud, not a silent all-clear ----------------
echo "  (d) unreachable host daemon fails loudly..."
: > "$CALLS"; : > "$d/dind-prune.log"
if HOST_PS_FAIL=1 STATE_DIR="$d" bash "$SCRIPT"; then
    fail "(d) exited 0 when the host daemon was unreachable"
fi
grep -q "FATAL" "$d/dind-prune.log" || fail "(d) no FATAL logged for an unreachable host daemon"
grep -q "no dind sandboxes running" "$d/dind-prune.log" \
    && fail "(d) reported a false all-clear instead of surfacing the daemon failure"
echo "  PASS"

# --- (e) a failing image list is not a clean all-clear ----------------------
echo "  (e) unlistable images skip the sandbox loudly..."
: > "$CALLS"; : > "$d/dind-prune.log"
IMAGES_FAIL=1 STATE_DIR="$d" bash "$SCRIPT" && fail "(e) exited 0 despite being unable to list images"
grep -q "cannot list images" "$d/dind-prune.log" || fail "(e) image-list failure never surfaced"
grep -q "no per-PR images older than" "$d/dind-prune.log" \
    && fail "(e) reported a clean all-clear despite being unable to list images"
grep -q "docker rmi" "$CALLS" && fail "(e) attempted removals from an unlistable sandbox"
echo "  PASS"

# --- (f) unparseable timestamps are counted, not swallowed ------------------
echo "  (f) unparseable image timestamps are surfaced..."
IMAGES_FIXTURE="$d/images-badtime" run_prune || fail "(f) run exited non-zero"
grep -q "WARNING -- 1 image timestamp" "$d/dind-prune.log" \
    || fail "(f) unparseable timestamp was silently dropped"
grep -q "rmi" "$CALLS" && fail "(f) removed an image whose age could not be established"
echo "  PASS"

# --- (g) an unreachable nested daemon is skipped, siblings still run --------
# A give-up path that returned 0 would let rmi / image prune / builder prune
# all fire against a sandbox the script cannot see into. Not a hard failure:
# a dockerd still starting is an expected state the next 6-hourly tick handles.
echo "  (g) unreachable nested daemon is skipped, siblings still run..."
PS_FAIL_DIND=knightwatch-reviewer-dind-1-1 run_prune \
    || fail "(g) a not-yet-ready sandbox should not fail the whole run"
grep -q "nested daemon unreachable" "$d/dind-prune.log" \
    || fail "(g) unreachable daemon never surfaced in the log"
for phase in rmi "image prune" "builder prune"; do
    grep -q "exec knightwatch-reviewer-dind-1-1 docker $phase" "$CALLS" \
        && fail "(g) ran '$phase' against a sandbox whose daemon never answered"
done
grep -q "exec knightwatch-reviewer-dind-2-1 docker rmi" "$CALLS" \
    || fail "(g) one unreachable sandbox aborted the sweep for its siblings"
echo "  PASS"

# --- (h) a failed prune phase exits nonzero --------------------------------
# `docker exec … | tail -1` hands the pipeline tail's status, so a failed prune
# would otherwise read as a clean tick while storage stayed put.
echo "  (h) a failed reclaim phase surfaces and exits nonzero..."
: > "$CALLS"; : > "$d/dind-prune.log"
PRUNE_FAIL=1 STATE_DIR="$d" bash "$SCRIPT" && fail "(h) exited 0 despite a failed prune phase"
grep -q "'docker image' failed" "$d/dind-prune.log" || fail "(h) prune failure never logged"
echo "  PASS"

# --- (i) selected tags but none removed is a failure, not a clean tick ------
# lib/run-dir.sh reaps a sandbox's leftover containers at the START of its next
# review and nothing cleans up when one ends, so a sandbox that stops claiming
# PRs sits on stopped containers pinning its own images — reclaiming nothing on
# every tick, forever, while the journal shows a one-line error and exit 0.
echo "  (i) tags selected but none untagged is reported as failure..."
: > "$CALLS"; : > "$d/dind-prune.log"
RMI_FAIL=1 STATE_DIR="$d" bash "$SCRIPT" && fail "(i) exited 0 when every selected tag failed to remove"
grep -q "none untagged" "$d/dind-prune.log" || fail "(i) the zero-reclaim case was not surfaced"
echo "  PASS"

echo ""
echo "PASS (9 checks)"

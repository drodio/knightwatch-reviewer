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

# Nested image inventory. Only stale-per-PR (aaa111) is collectable:
#   bbb222 — per-PR but built inside the window (a live /babysit-pr loop)
#   ccc333/ddd444 — base images, Created months ago, no __<digits>- in the repo
cat > "$d/images" <<IMAGES
aaa111	cncorp_plow__950-scenarios-plow-api	$OLD_DATE
bbb222	cncorp_plow__962-scenarios-plow-api	$NEW_DATE
ccc333	python	$OLD_DATE
ddd444	ubuntu	$OLD_DATE
IMAGES

cat > "$d/bin/docker" <<STUB
#!/bin/bash
echo "docker \$*" >> "\$CALLS"
if [ "\$1" = exec ]; then
    C="\$2"; shift 3   # drop: exec, <container>, the nested "docker"
    case "\$1 \${2:-}" in
        "ps -q")
            # BUSY_DIND is busy from the start. TURNS_BUSY_DIND is idle on the
            # FIRST poll and busy on every later one — that models a review
            # starting during the (minutes-long) image phase, which is the only
            # way to exercise the re-check guarding the volume sweep.
            [ "\$C" = "\${BUSY_DIND:-}" ] && { echo deadbeefcafe; exit 0; }
            if [ "\$C" = "\${TURNS_BUSY_DIND:-}" ]; then
                n=\$(cat "$d/psq.\$C" 2>/dev/null || echo 0); n=\$((n + 1))
                echo "\$n" > "$d/psq.\$C"
                [ "\$n" -gt 1 ] && echo deadbeefcafe
            fi
            exit 0 ;;
        "images --format") cat "$d/images"; exit 0 ;;
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

grep -q "rmi.*aaa111" "$CALLS" || fail "(a) stale per-PR image aaa111 was not removed"
grep -q "rmi.*bbb222" "$CALLS" && fail "(a) removed bbb222, a per-PR image still inside the ${PRUNE_HOURS:-168}h window"
grep -q "rmi.*ccc333" "$CALLS" && fail "(a) removed python base image — the Created-vs-pulled inversion is back"
grep -q "rmi.*ddd444" "$CALLS" && fail "(a) removed ubuntu base image — the Created-vs-pulled inversion is back"

# The regression guard proper: no code path may reintroduce the blanket sweep.
grep -qE "image prune.*-a|image prune.*--all" "$CALLS" \
    && fail "(a) 'docker image prune -a' reintroduced — it deletes base images by upstream Created date"
grep -q "image prune -f" "$CALLS" || fail "(a) dangling-layer prune never ran"

# Volumes DO need -a: compose names the per-PR scenario volumes, so the
# unqualified form reclaims nothing.
grep -q "volume prune -af" "$CALLS" || fail "(a) volume prune did not use -a (named volumes would be missed)"
grep -q "builder prune" "$CALLS"    || fail "(a) BuildKit cache never pruned"
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
grep -q "exec knightwatch-reviewer-dind-2-1 docker volume prune" "$CALLS" \
    && fail "(c) volume-pruned a sandbox with a running container — this destroys live scenario state"
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

# --- (e) a concurrent run backs off on the lock -----------------------------
echo "  (e) second concurrent invocation exits on the lock..."
: > "$CALLS"; : > "$d/dind-prune.log"
exec 8>"$d/dind-prune.lock"
flock -n 8 || fail "(e) could not take the lock to build the contention fixture"
STATE_DIR="$d" bash "$SCRIPT" || fail "(e) lock-contended run should exit 0, not error"
grep -q "another prune holds" "$d/dind-prune.log" || fail "(e) contended run did not log the back-off"
[ ! -s "$CALLS" ] || fail "(e) contended run still shelled out to docker"
exec 8>&-
echo "  PASS"

# --- (f) TOCTOU: idle at entry, busy by the time the volume sweep runs ------
# The volume sweep is the destructive phase (-a reaches named volumes, and
# there is no until= filter to soften it), and the image phase in front of it
# runs for minutes on a backlogged sandbox. Sampling idle once at the top of
# the iteration is therefore not enough; this pins the re-check.
echo "  (f) sandbox that turns busy during the image phase skips the volume sweep..."
rm -f "$d"/psq.*
TURNS_BUSY_DIND=knightwatch-reviewer-dind-1-1 run_prune || fail "(f) run exited non-zero"
grep -q "exec knightwatch-reviewer-dind-1-1 docker rmi" "$CALLS" \
    || fail "(f) image phase never ran on a sandbox that was idle at entry"
grep -q "exec knightwatch-reviewer-dind-1-1 docker volume prune" "$CALLS" \
    && fail "(f) volume-pruned a sandbox that turned busy mid-run — the TOCTOU re-check is missing"
echo "  PASS"

echo ""
echo "PASS (6 checks)"

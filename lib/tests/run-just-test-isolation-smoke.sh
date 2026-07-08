#!/bin/bash
# Security-contract smoke for run_just_test's container isolation branch: when
# REVIEWER_TEST_USER is set, `just test` must run with the reviewer's tokens
# scrubbed (env -i) so PR-controlled test code can't read them, while
# DOCKER_HOST is preserved (the test needs the dind daemon). Behavioral: a
# stubbed `just` reports what env it actually saw. runuser/timeout/chown are
# stubbed (can't switch uid in a unit test) so only the env contract is under
# test, not the privilege drop itself (that's a Task-7 live-bring-up check).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/run-dir.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/repo"
printf '#!/bin/bash\nshift 3\nexec "$@"\n' > "$d/bin/timeout"   # drop `-k <dur> <dur>`
printf '#!/bin/bash\nshift 3\nexec "$@"\n' > "$d/bin/runuser"   # drop `-u <user> --` (no real uid switch)
printf '#!/bin/bash\nexit 0\n'             > "$d/bin/chown"
# Stub the reviewer-test reap (pkill -u / pgrep -u) like the other privileged
# ops above: the reap is a bring-up check, not asserted here. Unstubbed, when
# this suite itself runs AS reviewer-test (the container review path), the real
# `pkill -KILL -u reviewer-test` would kill the test runner — a harness
# artifact, not a prod issue (the prod worker runs as root and reaps a distinct
# reviewer-test). pgrep exits 1 (no survivors) so run_just_test's reap-confirm
# loop proceeds cleanly.
printf '#!/bin/bash\nexit 0\n'             > "$d/bin/pkill"
printf '#!/bin/bash\nexit 1\n'             > "$d/bin/pgrep"
# /scenario-shared is a root-owned named volume in prod; run_just_test's
# `mkdir -p /scenario-shared && chmod 1777` on it (and the reclaim helper's
# `mkdir /scenario-shared/{uv,pip}` under it) are privileged ops like the chown
# above (they fail un-privileged, and as reviewer-test in the container self-
# review chmod hits EPERM). No-op any /scenario-shared* path so this un-privileged
# smoke doesn't trip; every other mkdir/chmod (the repo-dir mode-strip asserted
# below) passes through to the real binary, kept honest. The reclaim seam's own
# behavior is tested directly further down against a real temp root, not here.
cat > "$d/bin/mkdir" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in /scenario-shared*) exit 0;; esac; done
exec "$(command -v -p mkdir)" "$@"
STUB
cat > "$d/bin/chmod" <<'STUB'
#!/bin/bash
for a in "$@"; do [ "$a" = /scenario-shared ] && exit 0; done
exec "$(command -v -p chmod)" "$@"
STUB
# reviewer-test (uid 10001) is created in the Dockerfile but does not exist on the
# unprivileged test host, so reclaim_scenario_shared_caches's `id -u <user>` guard
# would reject it. Fake ONLY that name as resolvable (like the chown/runuser stubs
# paper over its non-existence); every other id query — the reclaim tests' own
# `id -un`/`id -u`, the invalid-user fail-loud case — passes through, kept honest.
cat > "$d/bin/id" <<'STUB'
#!/bin/bash
for a in "$@"; do [ "$a" = reviewer-test ] && exit 0; done
exec "$(command -v -p id)" "$@"
STUB
cat > "$d/bin/just" <<'STUB'
#!/bin/bash
echo "GH_TOKEN_VISIBLE=${GH_TOKEN:-<unset>}"
echo "DOCKER_HOST_VISIBLE=${DOCKER_HOST:-<unset>}"
echo "XDG_CACHE_HOME_VISIBLE=${XDG_CACHE_HOME:-<unset>}"
STUB
chmod +x "$d/bin"/*
export PATH="$d/bin:$PATH" DOCKER_HOST="tcp://dind:2375" GH_TOKEN="secret-xyz"

# Container branch: the token in run_just_test's own env must NOT reach `just`.
export REVIEWER_TEST_USER=reviewer-test
run_just_test /dev/null "$d/repo" "$d/log" 30s 5s
grep -q "GH_TOKEN_VISIBLE=<unset>" "$d/log"            || fail "GH_TOKEN leaked into the test command env despite the env -i scrub"
grep -q "DOCKER_HOST_VISIBLE=tcp://dind:2375" "$d/log" || fail "DOCKER_HOST not preserved for the dind daemon"
grep -q "XDG_CACHE_HOME_VISIBLE=/scenario-shared" "$d/log" || fail "XDG_CACHE_HOME not steered to /scenario-shared (nested-dind scenario token bridge missing)"

# Mode-strip: the container branch strips group/other write from the checkout
# after the test, so a leftover proc / a test that ran `chmod 777` can't write it
# while the root scratch-staging path runs. (The detached-writer reap, pkill -u,
# needs a real uid switch and is verified at bring-up.)
chmod 0777 "$d/repo"
run_just_test /dev/null "$d/repo" "$d/log1b" 30s 5s
(( 8#$(stat -c %a "$d/repo") & 0022 )) && fail "repo_dir still group/other-writable after run_just_test (mode-strip missing)" || true

# Host branch (no REVIEWER_TEST_USER): unchanged — runs as the operator, env not
# scrubbed. Pins that the scrub is container-only, not a behavior change on host.
unset REVIEWER_TEST_USER
run_just_test /dev/null "$d/repo" "$d/log2" 30s 5s
grep -q "GH_TOKEN_VISIBLE=secret-xyz" "$d/log2"        || fail "host path unexpectedly scrubbed the env (should be container-only)"

# reclaim_scenario_shared_caches: the run_just_test pre-runuser step that heals a
# stale root-owned uv/pip cache on the persistent scenario-shared volume. Its core
# root→test-user OWNERSHIP transition is uid-gated (needs root, like the chown/
# runuser/reap above) so it's a bring-up + live-on-fleet check, not asserted here.
# What IS unit-testable without a uid switch is the safety contract the isolation
# leans on: leave a correctly-owned cache AND the sibling token bridge untouched,
# and fail LOUD (non-zero) when a privileged op can't complete. Run with the real
# chown/rm/stat unshadowed — the stubs above fake chown to exit 0, which would
# mask the fail-loud path.
realp="${PATH#"$d/bin:"}"
sroot=$(mktemp -d)
mkdir -p "$sroot/uv/pkgs" "$sroot/pip/pkgs" "$sroot/plow-scenario-shared"
touch "$sroot/uv/pkgs/wheel" "$sroot/pip/pkgs/wheel" "$sroot/plow-scenario-shared/bridge-token"
# Every entry already test-user-owned → the foreign-entry probe finds nothing →
# no-op: caches survive intact (NOT discarded) and the sibling token bridge is
# never touched (scoped to uv/pip). (The discard→recreate TRANSITION needs a
# genuinely foreign-owned entry, which needs root to plant — so, like the chown/
# runuser above, it's a bring-up + live-on-fleet check, incl. the mixed-tree heal.)
PATH="$realp" reclaim_scenario_shared_caches "$sroot" "$(id -un)" || fail "reclaim returned non-zero on already-correct caches"
{ [ -f "$sroot/uv/pkgs/wheel" ] && [ -f "$sroot/pip/pkgs/wheel" ]; } || fail "reclaim discarded a correctly-owned cache (should be a no-op)"
[ -f "$sroot/plow-scenario-shared/bridge-token" ] || fail "reclaim touched the sibling token bridge (must be scoped to uv/pip)"
rm -rf "$sroot"
# Fail LOUD (non-zero) when it can't do its job, so run_just_test aborts instead of
# running against a still-broken cache: an empty root is rejected outright, an
# unresolvable user is rejected before the probe (else `find ! -user <bad>` errors
# and silently reads as "nothing foreign"), and a create into an unwritable root
# surfaces the mkdir failure.
PATH="$realp" reclaim_scenario_shared_caches "" "$(id -un)" && fail "reclaim accepted an empty root"
badroot=$(mktemp -d)   # disposable, not a shared path — so an ordering regression that ran the rm loop can't touch /tmp itself
PATH="$realp" reclaim_scenario_shared_caches "$badroot" "nobody-does-not-exist" && fail "reclaim did not fail loud on an unresolvable user"
rm -rf "$badroot"
if [ "$(id -u)" != 0 ]; then   # root ignores the mode bits; the container self-review runs unprivileged
    roroot=$(mktemp -d); chmod 500 "$roroot"
    PATH="$realp" reclaim_scenario_shared_caches "$roroot" "$(id -un)" && fail "reclaim did not fail loud when it could not create the cache dir"
    chmod 700 "$roroot"; rm -rf "$roroot"
fi
# A symlink raced into the cache path (a dind-side test process can, via DOCKER_HOST,
# mutate this shared volume) must fail loud via the non-`-p` mkdir before chown can
# dereference it and hand the target's ownership to the test user. Deterministic and
# unprivileged with a DANGLING symlink: `[ -e ]` is false (target absent) so control
# reaches `mkdir "$dir"`, which refuses the existing name (EEXIST). Locks the non-`-p`
# contract against a revert to `mkdir -p` (which would accept the symlink and chown it).
slroot=$(mktemp -d); ln -s "$slroot/no-such-target" "$slroot/uv"
PATH="$realp" reclaim_scenario_shared_caches "$slroot" "$(id -un)" && fail "reclaim did not fail loud on a symlink occupying the cache path"
[ -L "$slroot/uv" ] || fail "reclaim followed/replaced the symlink at the cache path instead of failing loud"
rm -rf "$slroot"

echo "PASS: run-just-test-isolation-smoke"

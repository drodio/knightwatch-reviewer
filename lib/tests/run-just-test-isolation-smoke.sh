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
# Already test-user-owned (we own the mktemp tree) → no-op: caches survive intact
# (NOT discarded) and the sibling token bridge is never touched (scoped to uv/pip).
PATH="$realp" reclaim_scenario_shared_caches "$sroot" "$(id -un)" || fail "reclaim returned non-zero on already-correct caches"
{ [ -f "$sroot/uv/pkgs/wheel" ] && [ -f "$sroot/pip/pkgs/wheel" ]; } || fail "reclaim discarded a correctly-owned cache (should be a no-op)"
[ -f "$sroot/plow-scenario-shared/bridge-token" ] || fail "reclaim touched the sibling token bridge (must be scoped to uv/pip)"
# Wrong owner → exercises the discard+recreate path; the chown to a user we can't
# become fails, and the helper must surface that as non-zero so run_just_test
# aborts instead of running against a still-broken cache. Bridge stays untouched.
PATH="$realp" reclaim_scenario_shared_caches "$sroot" "nobody-does-not-own-this" && fail "reclaim did not fail loud when the privileged chown could not complete"
[ -d "$sroot/plow-scenario-shared" ] || fail "reclaim removed the sibling token bridge on the reclaim path"
# Empty root rejected — guards an rm against a mis-derived path.
PATH="$realp" reclaim_scenario_shared_caches "" "$(id -un)" && fail "reclaim accepted an empty root"
rm -rf "$sroot"

echo "PASS: run-just-test-isolation-smoke"

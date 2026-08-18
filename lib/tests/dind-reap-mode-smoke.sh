#!/usr/bin/env bash
# Contract smoke for dind_reap_mode (lib/run-dir.sh) — the Sparkle fork's
# dind-removal guard (bead sparkle-akpqb7).
#
# WHY THIS FILE EXISTS, AND WHY IT IS PURE LOGIC.
# The reap this guard fronts is `docker ps -aq` + `docker rm -fv` — it deletes
# every container the daemon it is pointed at can see. Upstream therefore pins
# it to one endpoint and treats anything else as fatal. This fork deletes the
# privileged dind sidecar, so DOCKER_HOST is now UNSET, which under upstream's
# logic FATALs on every review reaching the test lane. Exactly one case moves:
# unset, refuse -> skip.
#
# The smoke that covers the surrounding code (run-just-test-isolation-smoke.sh)
# needs Linux and fails on a macOS workstation before it reaches this branch, so
# without this file the security-relevant case would ship unverified. Written
# pure-logic — no docker, no root, no flock — for the same reason
# merge-ready-smoke.sh was: so it runs anywhere the fork is edited.
#
# A NEW FILE ON PURPOSE: upstream does not have one, so it can never conflict on
# a rebase. That matters more than usual here — the rebase is exactly how the
# privileged sidecar comes back.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
check() {  # check <input> <expected> <why>
    local got; got=$(dind_reap_mode "$1")
    if [ "$got" = "$2" ]; then
        printf '  ok   %-34s -> %-6s  %s\n' "${1:-<unset>}" "$got" "$3"
    else
        printf '  FAIL %-34s -> %-6s (expected %s)  %s\n' "${1:-<unset>}" "$got" "$2" "$3" >&2
        fails=$((fails + 1))
    fi
}

echo "=== dind_reap_mode smoke ==="

# Source ONLY the function, not the whole file: run-dir.sh is sourced by
# review-one-pr.sh under `set -u` and expects its callers' state.
eval "$(awk '/^dind_reap_mode\(\) \{/,/^\}/' "$REPO_ROOT/lib/run-dir.sh")"
command -v dind_reap_mode >/dev/null 2>&1 \
    || { echo "FAIL: could not extract dind_reap_mode from lib/run-dir.sh" >&2; exit 1; }

# 1. The configuration this fork ships. If this ever returns anything but skip,
#    every review that reaches the test lane dies at the guard.
check ""                             skip   "no sidecar: nothing to reap"

# 2. The endpoint upstream pins to, kept working so a rebase that restores the
#    sidecar still reaps rather than silently leaking containers.
check "tcp://127.0.0.1:2375"         reap   "the dedicated dind endpoint"

# 3. THE PROPERTY WORTH PROTECTING. Each of these is a real daemon that is NOT
#    ours, and reaching the reap with any of them would `docker rm -fv` someone
#    else's containers. "unset" must not have widened into "anything falsy".
check "unix:///var/run/docker.sock"  refuse "the HOST daemon — the case the pin exists for"
check "tcp://127.0.0.1:2376"         refuse "right host, wrong port (TLS daemon)"
check "tcp://0.0.0.0:2375"           refuse "same port, reachable off-loopback"
check "tcp://10.0.0.5:2375"          refuse "another machine's daemon"
check " "                            refuse "whitespace is not unset"
check "0"                            refuse "a falsy-looking string is still a value"
check "TCP://127.0.0.1:2375"         refuse "case-differing scheme is not the pinned literal"
check "tcp://127.0.0.1:2375 "        refuse "trailing space is not the pinned literal"

if [ "$fails" -ne 0 ]; then echo "FAIL: dind_reap_mode smoke ($fails)" >&2; exit 1; fi
echo "PASS: dind_reap_mode smoke (10 assertions)"

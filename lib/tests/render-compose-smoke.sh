#!/usr/bin/env bash
# Contract smoke for lib/render-compose.sh.
#
# Acceptance is `docker compose config` — the same parse the fleet's own
# bring-up does — rather than a parallel topology schema of our own: it catches
# invalid-compose-project semantics a plain YAML parse cannot (a service naming
# an undeclared volume parses fine and takes the whole fleet down on `up`). It
# is client-side, so it holds on the host and in the reviewer container alike.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The generator rejects a missing mount source: docker auto-creates it (a FILE
# source as a DIRECTORY) and consumers stage it behind a `[ -f … ]` that skips.
SECRETS="$SANDBOX/secrets"
mkdir -p "$SECRETS"/codex-account-{a,b,d} "$SECRETS/claude-standards"
: > "$SECRETS/config.env"; : > "$SECRETS/repos.conf"

# $SECRETS sits under $OUT's dir, so the generator emits the same
# compose-relative form it ships with (./docker/secrets → ./secrets here).
render() {  # render <fleet-conf> [config-env] -> $SANDBOX/out.yml
    printf '%s\n' "$1" > "$SANDBOX/fleet.conf"
    printf '%s\n' "${2:-}" > "$SANDBOX/config.env"
    rm -f "$SANDBOX/out.yml"
    SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
        CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
        bash "$REPO_ROOT/lib/render-compose.sh" >"$SANDBOX/render.log" 2>&1
}
valid() { docker compose -f "$SANDBOX/out.yml" config --quiet || fail "$1"; }
count() { grep -cF "$1" "$SANDBOX/out.yml"; }  # 2 == "on every unit"

echo "=== render-compose smoke ==="

# --- 1. non-consecutive units: a commented row is excluded, not renumbered ---
echo "  1: rendered structure..."
render "1  codex-account-a
#3  codex-account-c
4  codex-account-d" || fail "2-unit render exited non-zero: $(cat "$SANDBOX/render.log")"
valid "rendered compose is not a valid compose project"
# One pair inspected end to end — unit 4, the one a renumbering bug would call 2.
for token in "  dind-1:" "  reviewer-1:" "  dind-4:" "  reviewer-4:" \
             'WORKER_ID: "4"' 'network_mode: "service:dind-4"' "depends_on: [dind-4]" \
             "claims:/shared" "reviewer4-local:/local" "dind4-lib:/var/lib/docker" \
             "./secrets/codex-account-d:/root/.codex" \
             "./secrets/claude-standards:/root/.claude:ro" "name: kwr_claims" "GENERATED"; do
    grep -qF "$token" "$SANDBOX/out.yml" || fail "render is missing: $token"
done
grep -qF codex-account-c "$SANDBOX/out.yml" && fail "a commented fleet.conf row was rendered"
# Same path on BOTH sides of the pair (PR #161).
[ "$(count 'scenario-shared4:/scenario-shared')" = 2 ] \
    || fail "scenario-shared4 is not bridged on both dind-4 and reviewer-4"

# --- 2. kid wiring is conditional on KID_ROOT -------------------------------
echo "  2: kid wiring conditional..."
KID="$SANDBOX/kid-index"; EXTRA="$SANDBOX/plow-kid"; mkdir -p "$KID" "$EXTRA"
render "1  codex-account-a
2  codex-account-b" "KID_ROOT=$KID
KID_EXTRA_MOUNTS=$EXTRA" || fail "kid render exited non-zero: $(cat "$SANDBOX/render.log")"
valid "kid-wired render is not a valid compose project"
# The extra index mounts at the same host and container path (one KID_PATHS
# value serves both namespaces).
for want in "KWR_CLONE_ROOT: /kwr" "$KID:/kwr:ro" "$EXTRA:$EXTRA:ro"; do
    [ "$(count "$want")" = 2 ] || fail "expected '$want' on both units, got $(count "$want")"
done

# KID_ROOT alone (today's production config): the /kwr mount on each unit and
# nothing more — a collapsed two-field read of config.env hands KID_ROOT back as
# an unpaired extra self-mount, showing up as a third and fourth hit.
render "1  codex-account-a
2  codex-account-b" "KID_ROOT=$KID" || fail "KID_ROOT alone: $(cat "$SANDBOX/render.log")"
valid "KID_ROOT-alone render is not a valid compose project"
[ "$(count "$KID")" = 2 ] || fail "KID_EXTRA_MOUNTS unset but the render emitted an extra mount"

render "1  codex-account-a
2  codex-account-b" || fail "kid-less render exited non-zero: $(cat "$SANDBOX/render.log")"
grep -q KWR_CLONE_ROOT "$SANDBOX/out.yml" \
    && fail "KID_ROOT unset but the render still wired KWR_CLONE_ROOT"

# --- 3. invalid input fails loud, leaving no partial output ------------------
echo "  3: error cases fail loud..."
assert_render_fails() {  # assert_render_fails <label> <fleet-conf> [config-env]
    local label="$1"; shift
    render "$@" && fail "$label: render succeeded but should have failed"
    [ ! -f "$SANDBOX/out.yml" ] || fail "$label: failed render left a partial docker-compose.yml"
}
assert_render_fails "every row commented" "# parked
#1  codex-account-a"
assert_render_fails "duplicate worker id" "1  codex-account-a
1  codex-account-b"
assert_render_fails "duplicate account dir" "1  codex-account-a
2  codex-account-a"
assert_render_fails "malformed row" "1  codex-account-a  extra-field"
assert_render_fails "non-numeric worker id" "one  codex-account-a"
assert_render_fails "absent account dir" "1  codex-account-zzz"
assert_render_fails "KID_ROOT names a missing dir" "1  codex-account-a" "KID_ROOT=$SANDBOX/nope"
assert_render_fails "KID_EXTRA_MOUNTS without KID_ROOT" "1  codex-account-a" \
    "KID_EXTRA_MOUNTS=$EXTRA"
for away in claude-standards config.env repos.conf; do  # the silent-degradation mounts
    mv "$SECRETS/$away" "$SANDBOX/mount-away"
    assert_render_fails "absent $away" "1  codex-account-a"
    mv "$SANDBOX/mount-away" "$SECRETS/$away"
done

echo "PASS: render-compose smoke"

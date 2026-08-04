#!/usr/bin/env bash
# Contract smoke for lib/render-compose.sh.
#
# The generator replaced four hand-maintenance parity fences in
# container-state-split-smoke.sh. Those checked that a human copied a unit
# block correctly; this checks the one thing that can still be wrong — the
# generator itself.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="$REPO_ROOT/lib/render-compose.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Build a fake secrets dir. Account dirs must exist — the generator rejects a
# row naming a missing one (docker would otherwise auto-create it empty).
SECRETS="$SANDBOX/secrets"
mkdir -p "$SECRETS"/codex-account-{a,b,c,d}

render() {  # render <fleet-conf-contents> [config-env-contents] -> $SANDBOX/out.yml
    printf '%s\n' "$1" > "$SANDBOX/fleet.conf"
    printf '%s\n' "${2:-}" > "$SANDBOX/config.env"
    rm -f "$SANDBOX/out.yml"
    SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
        CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
        bash "$RENDER" >"$SANDBOX/render.log" 2>&1
}

echo "=== render-compose smoke ==="

# --- 1. commented row is excluded, neighbors keep their identities ----------
echo "  1: commented row excluded..."
render "1  codex-account-a
#3  codex-account-c
4  codex-account-d" || fail "render of a 2-unit fleet exited non-zero: $(cat "$SANDBOX/render.log")"

for absent in 'reviewer-3:' 'dind-3:' 'reviewer3-local:' 'dind3-lib:' 'scenario-shared3:'; do
    grep -q "^  $absent" "$SANDBOX/out.yml" \
        && fail "commented-out unit 3 still rendered '$absent'"
done
for present in 'reviewer-1:' 'dind-1:' 'reviewer-4:' 'dind-4:'; do
    grep -q "^  $present" "$SANDBOX/out.yml" \
        || fail "unit missing from render: '$present'"
done

# --- 2. per-unit invariants -------------------------------------------------
echo "  2: per-unit invariants..."
unit_block() {  # unit_block <service-name>
    awk "/^  $1:/{f=1;next} /^  [a-z]/{f=0} f" "$SANDBOX/out.yml"
}
declare -A ACCT=( [1]=codex-account-a [4]=codex-account-d )
for n in 1 4; do
    rev="$(unit_block "reviewer-$n")"
    dind="$(unit_block "dind-$n")"

    printf '%s' "$rev" | grep -qF "service:dind-$n" \
        || fail "reviewer-$n does not share dind-$n's netns"
    # Same path on BOTH sides or the nested-dind scenario token mount resolves
    # to an empty auto-created dir and the stack's token wait blocks (PR #161).
    printf '%s' "$rev" | grep -qF "scenario-shared$n:/scenario-shared" \
        || fail "reviewer-$n missing its scenario-shared$n bridge"
    printf '%s' "$dind" | grep -qF "scenario-shared$n:/scenario-shared" \
        || fail "dind-$n missing its scenario-shared$n bridge"
    grep -q "^  scenario-shared$n:" "$SANDBOX/out.yml" \
        || fail "scenario-shared$n volume not declared"
    printf '%s' "$rev" | grep -qF "WORKER_ID: \"$n\"" \
        || fail "reviewer-$n missing WORKER_ID: \"$n\""
    printf '%s' "$rev" | grep -qF "${ACCT[$n]}:/root/.codex" \
        || fail "reviewer-$n not mounted at account dir ${ACCT[$n]}"
    printf '%s' "$rev" | grep -qF "reviewer$n-local:/local" \
        || fail "reviewer-$n missing its per-container local volume"
    # The shared read-only mounts every reviewer needs. These four had their own
    # parity fences before generation.
    for m in '/shared/repos.conf' '/root/.kwr/config.env' '/root/.kwr/repo-env' '/root/.kwr-config'; do
        printf '%s' "$rev" | grep -qF "$m" \
            || fail "reviewer-$n missing shared mount $m"
    done
done

# --- 3. kid wiring is conditional on KID_ROOT -------------------------------
echo "  3: kid wiring conditional..."
render "1  codex-account-a
2  codex-account-b" "KID_ROOT=/srv/kid-index"
for n in 1 2; do
    rev="$(unit_block "reviewer-$n")"
    printf '%s' "$rev" | grep -qF 'KWR_CLONE_ROOT: /kwr' \
        || fail "KID_ROOT set but reviewer-$n has no KWR_CLONE_ROOT (would silently review without prior art)"
    printf '%s' "$rev" | grep -qF '/srv/kid-index:/kwr:ro' \
        || fail "KID_ROOT set but reviewer-$n has no read-only index mount"
done

render "1  codex-account-a
2  codex-account-b"
grep -q 'KWR_CLONE_ROOT' "$SANDBOX/out.yml" \
    && fail "KID_ROOT unset but the render still wired KWR_CLONE_ROOT"

# --- 4. valid YAML ----------------------------------------------------------
echo "  4: output parses as YAML..."
python3 - "$SANDBOX/out.yml" <<'PY' || fail "rendered compose is not valid YAML"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)   # pyyaml absent: skip rather than fail the suite
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
assert "services" in doc and doc["services"], "no services rendered"
assert "volumes" in doc, "no volumes block rendered"
PY

# --- 5. idempotent ----------------------------------------------------------
echo "  5: idempotent..."
cp "$SANDBOX/out.yml" "$SANDBOX/first.yml"
render "1  codex-account-a
2  codex-account-b"
cmp -s "$SANDBOX/first.yml" "$SANDBOX/out.yml" \
    || fail "two renders of the same fleet.conf differ"

# --- 6. generated banner (token-level, never prose — REVIEW.md:56) ----------
echo "  6: generated banner..."
grep -q 'GENERATED' "$SANDBOX/out.yml" || fail "render carries no GENERATED marker"
grep -q 'fleet.conf' "$SANDBOX/out.yml" || fail "render does not name its source file"

# --- 7. fails loud, leaves no partial output --------------------------------
echo "  7: error cases fail loud..."
assert_render_fails() {  # assert_render_fails <label> <fleet-conf> [config-env]
    local label="$1"; shift
    render "$@" && fail "$label: render succeeded but should have failed"
    [ ! -f "$SANDBOX/out.yml" ] || fail "$label: failed render left a partial docker-compose.yml"
}
assert_render_fails "zero enabled rows" "# every row commented
#1  codex-account-a"
assert_render_fails "duplicate worker id" "1  codex-account-a
1  codex-account-b"
assert_render_fails "malformed row" "1  codex-account-a  extra-field"
assert_render_fails "non-numeric worker id" "one  codex-account-a"
assert_render_fails "absent account dir" "1  codex-account-zzz"

rm -f "$SANDBOX/fleet.conf"
SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
    CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
    bash "$RENDER" >/dev/null 2>&1 \
    && fail "missing fleet.conf: render succeeded but should have failed"

# A crash mid-write (disk full, killed process) must never leave a partial
# docker-compose.yml — this is what the temp-file+mv contract buys over
# writing straight to $OUT. Force it deterministically with a tiny file-size
# ulimit; a validated 4-unit fleet's rendered output blows past 1 block.
printf '1  codex-account-a\n2  codex-account-b\n3  codex-account-c\n4  codex-account-d\n' \
    > "$SANDBOX/fleet.conf"
rm -f "$SANDBOX/out.yml"
( ulimit -f 1
  SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
      CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
      bash "$RENDER" ) >/dev/null 2>&1
[ ! -f "$SANDBOX/out.yml" ] \
    || fail "write crash left a partial docker-compose.yml"

echo "PASS: render-compose smoke"

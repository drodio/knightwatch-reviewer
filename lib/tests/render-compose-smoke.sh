#!/usr/bin/env bash
# Contract smoke for lib/render-compose.sh.
#
# The generator replaced four hand-maintenance parity fences in
# container-state-split-smoke.sh. Those checked that a human copied a unit
# block correctly; this checks the one thing that can still be wrong — the
# generator itself. The per-unit invariants are asserted structurally over
# EVERY rendered unit (parsed YAML), not by grepping two hard-coded ones.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="$REPO_ROOT/lib/render-compose.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Build a fake secrets dir. Account dirs must exist — the generator rejects a
# row naming a missing one (docker would otherwise auto-create it empty).
SECRETS="$SANDBOX/secrets"
mkdir -p "$SECRETS"/codex-account-{a,b,c,d} "$SECRETS/claude-standards"
# Separated from the check below so a host without pyyaml gets its own name
# rather than reading as invalid generator output.
python3 -c 'import yaml' 2>/dev/null \
    || fail "pyyaml required for the compose structural check (apt install python3-yaml)"
# $SECRETS sits under $OUT's dir, so the generator renders the same
# compose-relative form it ships with (./docker/secrets → ./secrets here).
SECRETS_REF="./secrets"

render() {  # render <fleet-conf-contents> [config-env-contents] -> $SANDBOX/out.yml
    printf '%s\n' "$1" > "$SANDBOX/fleet.conf"
    printf '%s\n' "${2:-}" > "$SANDBOX/config.env"
    rm -f "$SANDBOX/out.yml"
    SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
        CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
        bash "$RENDER" >"$SANDBOX/render.log" 2>&1
}

# Every structural invariant the fleet depends on, asserted over the WHOLE
# render: the exact service/volume sets, and per unit the netns pairing, the
# scenario-shared bridge on both sides, the account mount, and the shared
# read-only mounts + env. Generic over units — adding a sixth needs no edit.
check_render() {  # check_render <id>=<acct>...
    python3 - "$SANDBOX/out.yml" "$SECRETS_REF" "$@" <<'PY' \
        || fail "structural check failed (assertion above)"
import sys
import yaml

path, sref, *spec = sys.argv[1:]
units = dict(p.split("=", 1) for p in spec)
with open(path) as fh:
    doc = yaml.safe_load(fh)
svcs, vols = doc["services"], doc["volumes"]

want_svcs = {f"{k}-{n}" for n in units for k in ("dind", "reviewer")}
assert set(svcs) == want_svcs, f"services {sorted(svcs)} != {sorted(want_svcs)}"

want_vols = {"claims"}
for n in units:
    want_vols |= {f"reviewer{n}-local", f"dind{n}-lib", f"scenario-shared{n}"}
assert set(vols) == want_vols, f"volumes {sorted(vols)} != {sorted(want_vols)}"

# EXTERNAL fixed-name, so the shared review state (runs/ — the KNOWN_SHA dedup
# history) survives project rename / `down -v` / prune. PR #130's contract.
assert vols["claims"] == {"external": True, "name": "kwr_claims"}, \
    f"claims volume is not external kwr_claims (durability regressed — PR #130): {vols['claims']}"

for n, acct in units.items():
    rev, dind = svcs[f"reviewer-{n}"], svcs[f"dind-{n}"]
    assert rev["network_mode"] == f"service:dind-{n}", \
        f"reviewer-{n} does not share dind-{n}'s netns: {rev.get('network_mode')}"
    assert rev["depends_on"] == [f"dind-{n}"], \
        f"reviewer-{n} depends_on {rev.get('depends_on')}, not [dind-{n}]"

    env = rev["environment"]
    assert env["WORKER_ID"] == str(n), f"reviewer-{n} WORKER_ID is {env.get('WORKER_ID')!r}"
    # The convention cache and the per-repo secret-env seam reach the fleet ONLY
    # via these env pointers + their read-only mounts below; dropping either
    # silently breaks convention lookup / test-scenario creds at review time.
    assert env["KWR_CONFIG_DIR"] == "/root/.kwr-config", f"reviewer-{n}: {env.get('KWR_CONFIG_DIR')!r}"
    assert env["REPO_ENV_DIR"] == "/root/.kwr/repo-env", f"reviewer-{n}: {env.get('REPO_ENV_DIR')!r}"

    # Same path on BOTH sides or the nested-dind scenario token mount resolves
    # to an empty auto-created dir and the stack's token wait blocks (PR #161).
    bridge = f"scenario-shared{n}:/scenario-shared"
    assert bridge in rev["volumes"], f"reviewer-{n} missing its {bridge} bridge"
    assert bridge in dind["volumes"], f"dind-{n} missing its {bridge} bridge"

    for want in [
        "claims:/shared",
        f"reviewer{n}-local:/local",
        f"{sref}/{acct}:/root/.codex",
        f"{sref}/repos.conf:/shared/repos.conf:ro",
        f"{sref}/config.env:/root/.kwr/config.env:ro",
        f"{sref}/repo-env:/root/.kwr/repo-env:ro",
        f"{sref}/claude-standards:/root/.claude:ro",
        "${HOME}/services/kwr-config:/root/.kwr-config:ro",
    ]:
        assert want in rev["volumes"], f"reviewer-{n} missing mount {want}: {rev['volumes']}"
PY
}

echo "=== render-compose smoke ==="

# --- 1. structure: commented row excluded, every rendered unit is complete ---
echo "  1: rendered structure..."
render "1  codex-account-a
#3  codex-account-c
4  codex-account-d" || fail "render of a 2-unit fleet exited non-zero: $(cat "$SANDBOX/render.log")"
check_render 1=codex-account-a 4=codex-account-d

# --- 2. kid wiring is conditional on KID_ROOT -------------------------------
# Counted across the file rather than parsed per unit: the contract is "on
# EVERY unit", and a count is the direct expression of that.
echo "  2: kid wiring conditional..."
KID_INDEX="$SANDBOX/kid-index"; PLOW_INDEX="$SANDBOX/plow-kid"
mkdir -p "$KID_INDEX" "$PLOW_INDEX"
render "1  codex-account-a
2  codex-account-b" "KID_ROOT=$KID_INDEX
KID_EXTRA_MOUNTS=\"$PLOW_INDEX:/kid-ro/plow-kid $KID_INDEX:/kid-ro/second\"" \
    || fail "kid render exited non-zero: $(cat "$SANDBOX/render.log")"
check_render 1=codex-account-a 2=codex-account-b
for expect in "KWR_CLONE_ROOT: /kwr" "$KID_INDEX:/kwr:ro" \
              "$PLOW_INDEX:/kid-ro/plow-kid:ro" "$KID_INDEX:/kid-ro/second:ro"; do
    [ "$(grep -cF "$expect" "$SANDBOX/out.yml")" = 2 ] \
        || fail "expected '$expect' on both units, got $(grep -cF "$expect" "$SANDBOX/out.yml")"
done

# KID_ROOT alone: exactly the /kwr mount, no extras. Fences the two-field read
# of config.env — a collapsed read hands KID_ROOT's own value back as an
# (unpaired) extra mount.
render "1  codex-account-a
2  codex-account-b" "KID_ROOT=$KID_INDEX" \
    || fail "KID_ROOT alone should render: $(cat "$SANDBOX/render.log")"
[ "$(grep -cF "$KID_INDEX:/kwr:ro" "$SANDBOX/out.yml")" = 2 ] \
    || fail "KID_ROOT alone did not mount /kwr on both units"
grep -qF '/kid-ro' "$SANDBOX/out.yml" \
    && fail "KID_EXTRA_MOUNTS unset but the render still emitted an extra mount"

render "1  codex-account-a
2  codex-account-b"
grep -q 'KWR_CLONE_ROOT' "$SANDBOX/out.yml" \
    && fail "KID_ROOT unset but the render still wired KWR_CLONE_ROOT"

# --- 3. generated banner (token-level, never prose — REVIEW.md:56) ----------
echo "  3: generated banner..."
grep -q 'GENERATED' "$SANDBOX/out.yml" || fail "render carries no GENERATED marker"
grep -q 'fleet.conf' "$SANDBOX/out.yml" || fail "render does not name its source file"

# --- 4. fails loud, leaves no partial output --------------------------------
echo "  4: error cases fail loud..."
assert_render_fails() {  # assert_render_fails <label> <fleet-conf> [config-env]
    local label="$1"; shift
    render "$@" && fail "$label: render succeeded but should have failed"
    [ ! -f "$SANDBOX/out.yml" ] || fail "$label: failed render left a partial docker-compose.yml"
}
assert_render_fails "zero enabled rows" "# every row commented
#1  codex-account-a"
assert_render_fails "duplicate worker id" "1  codex-account-a
1  codex-account-b"
# Two units on one ~/.codex refresh a single auth.json concurrently, and their
# quota-pause state splits across /shared/pool/, so one pausing on an exhausted
# account doesn't stop the other hammering it.
assert_render_fails "duplicate account dir" "1  codex-account-a
2  codex-account-a"
assert_render_fails "malformed row" "1  codex-account-a  extra-field"
assert_render_fails "non-numeric worker id" "one  codex-account-a"
assert_render_fails "absent account dir" "1  codex-account-zzz"
assert_render_fails "KID_ROOT names a missing dir" "1  codex-account-a
2  codex-account-b" "KID_ROOT=$SANDBOX/no-such-kid-index"
assert_render_fails "KID_EXTRA_MOUNTS names a missing dir" "1  codex-account-a" \
    "KID_ROOT=$KID_INDEX
KID_EXTRA_MOUNTS=$SANDBOX/no-such-index:/kid-ro/x"
assert_render_fails "KID_EXTRA_MOUNTS pair is malformed" "1  codex-account-a" \
    "KID_ROOT=$KID_INDEX
KID_EXTRA_MOUNTS=$PLOW_INDEX"
assert_render_fails "KID_EXTRA_MOUNTS without KID_ROOT" "1  codex-account-a" \
    "KID_EXTRA_MOUNTS=$PLOW_INDEX:/kid-ro/plow-kid"
mv "$SECRETS/claude-standards" "$SANDBOX/standards-away"
assert_render_fails "absent claude-standards" "1  codex-account-a"
mv "$SANDBOX/standards-away" "$SECRETS/claude-standards"

rm -f "$SANDBOX/fleet.conf"
SECRETS_DIR="$SECRETS" FLEET_CONF="$SANDBOX/fleet.conf" \
    CONFIG_ENV="$SANDBOX/config.env" OUT="$SANDBOX/out.yml" \
    bash "$RENDER" >/dev/null 2>&1 \
    && fail "missing fleet.conf: render succeeded but should have failed"

echo "PASS: render-compose smoke"

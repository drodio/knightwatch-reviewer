#!/bin/bash
# SPARKLE FORK PATCH. Pins the pnpm install contract in docker/Dockerfile.
#
# WHY THIS EXISTS. This fork reviews drodio/sparkle, whose `just test` is
# `pnpm -r test`. pnpm was absent from the image, so the recipe exit-127'd and
# EVERY review the fork posted carried "Tests not run" — the reviewer was
# structurally blind to test outcomes for the whole of the step-9 bring-up
# (bead sparkle-wl1cjy). The direction of that failure was at least honest.
# The direction of the NEXT one is not: with pnpm present but the install
# dropped, `pnpm -r test` in a fresh clone dies at "vitest: not found" and
# renders as a FALSE "Tests failed" on every PR, which is strictly worse.
#
# So this is the same class of guard as the compose-plugin and jq-1.7 pins in
# container-state-split-smoke.sh, and it is a pure TEXT assertion for the same
# reason: this suite never builds the image, so a Dockerfile edit that silently
# drops the tool would otherwise stay green here and fail only on live PRs.
#
# It lives in its OWN FILE, not in container-state-split-smoke.sh, because that
# file is upstream's: upstream lands 1-5 commits/day and keeps its own image
# contract, so a fork assertion added inside it is a conflict on every rebase.
# Same reasoning as lib/merge-ready.sh and lib/tests/dind-reap-mode-smoke.sh.
#
# WHEN THE PIN NEEDS BUMPING: it tracks the REVIEWED repo, not this one. Read
# `packageManager` in drodio/sparkle's root package.json; when that moves, move
# ARG PNPM_VERSION and the literal below together. Matching it is the point —
# the reviewer should resolve dependencies with the resolver that repo is
# actually tested with, not with whatever `latest` is on the day of a rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$(cd "$HERE/.." && pwd)/docker/Dockerfile"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Guard the file's existence separately. `grep -q ... || fail` on a MISSING file
# fires the fail with the wrong message — reporting a content regression for a
# file that isn't there — which is the misattribution container-state-split-
# smoke.sh already earned this same guard for.
[ -f "$DOCKERFILE" ] || fail "Dockerfile not found at $DOCKERFILE"

# The pin itself, as a literal. Asserting only that SOME version is pinned would
# stay green through a silent drift to a version the reviewed repo is not tested
# with, which is the whole thing the pin buys.
grep -qE '^ARG PNPM_VERSION=10\.7\.1$' "$DOCKERFILE" \
  || fail "Dockerfile missing pinned 'ARG PNPM_VERSION=10.7.1' (must match drodio/sparkle's package.json packageManager — bead sparkle-wl1cjy)"

# The install must actually happen, and must go through the ARG rather than
# re-typing a version — two literals drift, and the drift is invisible until a
# live review reports the wrong resolver.
grep -qF 'npm install -g "pnpm@${PNPM_VERSION}"' "$DOCKERFILE" \
  || fail "Dockerfile does not install pnpm globally via \${PNPM_VERSION} (a fresh-clone 'just test' will exit 127 and every review will say 'Tests not run' — bead sparkle-wl1cjy)"

# Global, not corepack. `corepack enable` writes its shims into whichever \$HOME
# ran it, so it would resolve for root and be INVISIBLE to the unprivileged
# reviewer-test user that actually runs `just test` under `env -i` — a shape
# that passes an interactive `docker exec` check and fails every real review.
# Written as an `if`, not `grep ... && fail`: under `set -e` that AND-list form
# is exempt from errexit only because grep is not its LAST element — a fact one
# refactor away from turning the PASSING path into a silent exit 1.
if grep -qE '^RUN[[:space:]]+corepack[[:space:]]+enable' "$DOCKERFILE"; then
  fail "Dockerfile installs pnpm via 'corepack enable': its shims land in the invoking user's \$HOME, so reviewer-test (who runs 'just test') would not resolve pnpm"
fi

echo "PASS: sparkle pnpm pin smoke (4 assertions)"

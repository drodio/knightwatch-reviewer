#!/usr/bin/env bash
# Hermetic smoke for stage_convention_run (lib/conventions.sh) — replay's
# convention-staging seam. Replay runs under `set -euo pipefail`; the shipped bug
# was that a bare `_CONV_DOC=$(resolve_binding ...)` aborted the WHOLE replay on
# the common no-convention (rc 1) path. The existing replay-smoke only exercised
# header stitching, so it sailed past green. This covers the seam directly +
# fences the errexit-safety of replay's caller pattern.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$LIB_DIR/conventions.sh"
. "$LIB_DIR/scratch.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export RUN_DIR="$T/run"                       # write_scratch target

REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t; git -C "$REPO" config commit.gpgsign false
printf '# Purpose\n' > "$REPO/SEED.md"; git -C "$REPO" add SEED.md; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)

fail() { echo "FAIL: $1"; exit 1; }
echo "=== replay-staging smoke (errexit-safe) ==="

# (a) No convention (KWR_CONFIG_REPO unset): under this script's `set -euo
# pipefail`, returns rc 1 WITHOUT aborting (reaching the next line proves no
# abort — the shipped replay bug aborted the run here) and stages nothing.
echo "  no-convention → rc 1, no abort, nothing staged..."
unset KWR_CONFIG_REPO || true
rc=0; note=$(stage_convention_run "$REPO" "acme/app" "$BASE") || rc=$?
[ "$rc" -eq 1 ] || fail "no-convention expected rc 1, got $rc"
[ -e "$RUN_DIR/inputs/convention.md" ] && fail "no-convention must stage nothing"
[ -n "${note:-}" ] && fail "no-convention must echo no note"

# kwr-config fixture
CFG="$T/kwr-config"; mkdir -p "$CFG/conventions"
printf '{ "bindings": [ { "match": {"org":"acme","marker":"SEED.md"}, "doc":"conventions/seed.md" } ] }\n' > "$CFG/config.json"
cat > "$CFG/conventions/seed.md" <<'MD'
---
test-note: "gate is ref/verify.sh"
---
# heading
review by the grammar
MD
export KWR_CONFIG_REPO="https://example.invalid/acme/kwr-config.git" KWR_CONFIG_DIR="$CFG"

# (c) Convention match: rc 0, convention.md staged (frontmatter stripped), note returned.
echo "  convention match → stages convention.md + returns test-note..."
rc=0; note=$(stage_convention_run "$REPO" "acme/app" "$BASE") || rc=$?
[ "$rc" -eq 0 ] || fail "match expected rc 0, got $rc"
[ "$note" = "gate is ref/verify.sh" ] || fail "expected test-note, got '$note'"
[ -s "$RUN_DIR/inputs/convention.md" ] || fail "convention.md not staged"
grep -q '^test-note:' "$RUN_DIR/inputs/convention.md" && fail "frontmatter not stripped from staged body"
grep -q 'review by the grammar' "$RUN_DIR/inputs/convention.md" || fail "staged body missing"

# (d) Broken config (parseable but wrong shape): rc 2 (fail loud).
echo "  broken config (bindings not an array) → rc 2 (fail loud)..."
printf '{ "bindings": "nope" }\n' > "$CFG/config.json"
rc=0; stage_convention_run "$REPO" "acme/app" "$BASE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "broken-shape config expected rc 2, got $rc"

echo "  PASS (replay-staging: no-convention-no-abort + match-stages + broken-shape-fail-loud)"

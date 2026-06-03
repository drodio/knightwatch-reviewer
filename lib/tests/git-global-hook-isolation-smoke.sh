#!/usr/bin/env bash
# Regression for the `just test` global-hook isolation contract (justfile: the
# `export GIT_CONFIG_GLOBAL=/dev/null` line). The suite commits throwaway fixture
# repos under /tmp; on a box where roborev installed a machine-global
# core.hooksPath, those commits would fire post-commit and enqueue stray live
# review jobs against the daemon (polluting ~/.roborev/reviews.db). The recipe
# suppresses that by exporting GIT_CONFIG_GLOBAL=/dev/null, which makes git
# ignore the global ~/.gitconfig (and thus its hooksPath) for the whole suite.
#
# This asserts the suppression actually holds. It INHERITS GIT_CONFIG_GLOBAL from
# the recipe rather than setting its own, so removing the export from `just test`
# makes git honor the global hook again and this smoke FAILS — that's the point.
# (Therefore it must run under `just test`, not standalone.)
set -euo pipefail
fail() { echo "FAIL: $1" >&2; exit 1; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export HOME="$d"
mkdir -p "$d/hooks"
printf '#!/bin/sh\ntouch "%s/FIRED"\n' "$d" > "$d/hooks/post-commit"
chmod +x "$d/hooks/post-commit"
git config --file "$d/.gitconfig" core.hooksPath "$d/hooks"   # the would-be machine-global hook

git init -q "$d/repo"
git -C "$d/repo" config user.email t@t
git -C "$d/repo" config user.name t
git -C "$d/repo" config commit.gpgsign false

# Positive control: with the suppression lifted, the global hook MUST fire — proves
# the hook is wired and the assertion below isn't passing vacuously.
echo a > "$d/repo/a"; git -C "$d/repo" add a
env -u GIT_CONFIG_GLOBAL git -C "$d/repo" commit -qm control
[ -e "$d/FIRED" ] || fail "control: global post-commit hook did not fire even without suppression — test setup is broken, not exercising a real hook"
rm -f "$d/FIRED"

# Contract: under the env the recipe exports (GIT_CONFIG_GLOBAL=/dev/null inherited),
# git must ignore the global hooksPath and the commit must NOT fire post-commit.
echo b > "$d/repo/b"; git -C "$d/repo" add b
git -C "$d/repo" commit -qm contract
[ -e "$d/FIRED" ] && fail "global post-commit hook fired under the suite env — GIT_CONFIG_GLOBAL=/dev/null isolation is not in effect (the just-test export was likely removed)"

echo "PASS: git-global-hook-isolation-smoke"

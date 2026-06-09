#!/usr/bin/env bash
# Smoke for lib/conventions.sh — the convention-agnostic resolver that replaced
# the SEED-hardcoded is_seed_repo/seed_test_summary (PR #151). Covers: active-state
# tri-state, binding resolution (org-only / slug-glob / marker-at-base-ref),
# first-match-wins, base-ref trust (a marker present only on PR head must NOT
# match), matched-but-doc-missing → fail-loud, malformed/inactive → fallback,
# frontmatter/body parsing, stage_convention write, and resolve_standards.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$LIB_DIR/conventions.sh"
. "$LIB_DIR/scratch.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkgit() {  # mkgit <dir> — init a quiet git repo with deterministic identity
    git -C "$1" init -q -b main
    git -C "$1" config user.email t@t
    git -C "$1" config user.name t
    git -C "$1" config commit.gpgsign false
}

# --- fixture repos ---------------------------------------------------------
# REPO: a root SEED.md committed at base.
REPO="$T/repo"; mkdir -p "$REPO"; mkgit "$REPO"
printf '# Purpose\n' > "$REPO/SEED.md"; git -C "$REPO" add SEED.md; git -C "$REPO" commit -qm base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

# PLAIN: no marker file at all.
PLAIN="$T/plain"; mkdir -p "$PLAIN"; mkgit "$PLAIN"
echo x > "$PLAIN/x"; git -C "$PLAIN" add x; git -C "$PLAIN" commit -qm base
PLAIN_SHA=$(git -C "$PLAIN" rev-parse HEAD)

# HEADONLY: base has NO SEED.md; a later commit adds it. The base SHA must miss.
HEADONLY="$T/headonly"; mkdir -p "$HEADONLY"; mkgit "$HEADONLY"
echo x > "$HEADONLY/x"; git -C "$HEADONLY" add x; git -C "$HEADONLY" commit -qm base
HEADONLY_BASE=$(git -C "$HEADONLY" rev-parse HEAD)
printf '# Purpose\n' > "$HEADONLY/SEED.md"; git -C "$HEADONLY" add SEED.md; git -C "$HEADONLY" commit -qm "add SEED.md on head"
HEADONLY_HEAD=$(git -C "$HEADONLY" rev-parse HEAD)

# --- kwr-config fixture ----------------------------------------------------
CFG="$T/kwr-config"; mkdir -p "$CFG/conventions" "$CFG/standards"
cat > "$CFG/config.json" <<'JSON'
{ "bindings": [
  { "match": {"org":"plow-pbc","slug-glob":"seed-* openseed"}, "doc":"conventions/seed.md" },
  { "match": {"org":"plow-pbc","marker":"SEED.md"},            "doc":"conventions/seed.md" },
  { "match": {"org":"acme"},                                   "doc":"conventions/house.md" },
  { "match": {"org":"dup","slug-glob":"app-*"},               "doc":"conventions/first.md" },
  { "match": {"org":"dup","marker":"SEED.md"},                "doc":"conventions/second.md" },
  { "match": {"org":"brokenorg","marker":"SEED.md"},          "doc":"conventions/missing.md" }
] }
JSON
cat > "$CFG/conventions/seed.md" <<'MD'
---
test-note: "`just test` is N/A; the gate is `ref/verify.sh`."
test-header: "gate is `ref/verify.sh` (no `just test`)"
---
# SEED-convention repo

Review by the SEED grammar.
MD
printf '# House rules\n\nReview acme repos this way.\n'   > "$CFG/conventions/house.md"
printf '# First\n'  > "$CFG/conventions/first.md"
printf '# Second\n' > "$CFG/conventions/second.md"
printf '## Operator standards\n\nBe concise.\n' > "$CFG/standards/10-base.md"

export KWR_CONFIG_DIR="$CFG"

fail() { echo "FAIL: $1"; exit 1; }

echo "=== conventions smoke ==="

# --- kwr_config_valid (shared usable-config predicate) ---------------------
echo "  kwr_config_valid: unset / set+missing / set+malformed / jq-absent → non-0; set+valid → 0..."
MAL="$T/malformed"; mkdir -p "$MAL"; printf '{ bad' > "$MAL/config.json"
( unset KWR_CONFIG_REPO;                          kwr_config_valid ) && fail "valid(unset) should be non-0"
( export KWR_CONFIG_REPO=x KWR_CONFIG_DIR="$T/nope"; kwr_config_valid ) && fail "valid(set,missing) should be non-0"
( export KWR_CONFIG_REPO=x KWR_CONFIG_DIR="$MAL";    kwr_config_valid ) && fail "valid(set,malformed) should be non-0"
( export KWR_CONFIG_REPO=x PATH="$T"; kwr_config_valid ) && fail "valid should be non-0 when jq is absent from PATH"
( export KWR_CONFIG_REPO=x;                        kwr_config_valid ) || fail "valid(set,present,valid-json) should be 0"

# Everything below runs with an active kwr-config.
export KWR_CONFIG_REPO="https://example.invalid/op/kwr-config.git"

echo "  resolve_binding: slug-glob match (seed-* / openseed)..."
out=$(resolve_binding "plow-pbc/seed-foo" "$PLAIN" "$PLAIN_SHA") || fail "seed-foo slug should match (rc=$?)"
[ "$out" = "$CFG/conventions/seed.md" ] || fail "seed-foo → expected seed.md, got '$out'"
out=$(resolve_binding "plow-pbc/openseed" "$PLAIN" "$PLAIN_SHA") || fail "openseed slug should match"
[ "$out" = "$CFG/conventions/seed.md" ] || fail "openseed → expected seed.md, got '$out'"

echo "  resolve_binding: slug-glob is NOT pathname-expanded against the cwd..."
# Regression: a bare `for g in $slug_glob` globs the patterns against the cwd, so
# a repo dir containing a `seed-*` file would expand `seed-*` to that filename and
# break detection. Run from a cwd polluted with a matching file; must still match.
GLOBDIR="$T/globtrap"; mkdir -p "$GLOBDIR"; : > "$GLOBDIR/seed-decoy"
out=$(cd "$GLOBDIR" && resolve_binding "plow-pbc/seed-foo" "$PLAIN" "$PLAIN_SHA") \
    || fail "slug-glob match must survive a cwd containing a seed-* file (rc=$?)"
[ "$out" = "$CFG/conventions/seed.md" ] || fail "cwd-glob regression → expected seed.md, got '$out'"

echo "  resolve_binding: marker at base ref matches a non-glob slug..."
out=$(resolve_binding "plow-pbc/myapp" "$REPO" "$BASE_SHA") || fail "myapp w/ SEED.md@base should match (rc=$?)"
[ "$out" = "$CFG/conventions/seed.md" ] || fail "marker → expected seed.md, got '$out'"

echo "  resolve_binding: org-only binding = unconditional org-wide..."
out=$(resolve_binding "acme/anything" "$PLAIN" "$PLAIN_SHA") || fail "acme org-wide should match"
[ "$out" = "$CFG/conventions/house.md" ] || fail "acme → expected house.md, got '$out'"

echo "  resolve_binding: no binding for the org → rc 1 (fallback)..."
resolve_binding "otherorg/repo" "$PLAIN" "$PLAIN_SHA" >/dev/null; [ "$?" -eq 1 ] || fail "otherorg expected rc 1"

echo "  resolve_binding: first-match-wins across two matching bindings..."
# dup/app-1 with SEED.md@base matches BOTH the slug binding (first.md) and the
# marker binding (second.md); the earlier one wins.
printf '# Purpose\n' > "$REPO/SEED.md"  # REPO already has SEED.md@base; reuse it
out=$(resolve_binding "dup/app-1" "$REPO" "$BASE_SHA") || fail "dup/app-1 should match"
[ "$out" = "$CFG/conventions/first.md" ] || fail "first-match-wins → expected first.md, got '$out'"

echo "  resolve_binding: base-ref trust — marker on PR head only must NOT match..."
resolve_binding "plow-pbc/myapp" "$HEADONLY" "$HEADONLY_BASE" >/dev/null; [ "$?" -eq 1 ] || fail "head-only marker must miss at base SHA"
out=$(resolve_binding "plow-pbc/myapp" "$HEADONLY" "$HEADONLY_HEAD") || fail "marker at head SHA should match (control)"
[ "$out" = "$CFG/conventions/seed.md" ] || fail "head SHA control → expected seed.md, got '$out'"

echo "  resolve_binding: matched binding but doc missing on disk → rc 2 (fail loud)..."
resolve_binding "brokenorg/x" "$REPO" "$BASE_SHA" >/dev/null 2>&1; [ "$?" -eq 2 ] || fail "missing doc expected rc 2"

echo "  resolve_binding: inactive (KWR_CONFIG_REPO unset) → rc 1..."
( unset KWR_CONFIG_REPO; resolve_binding "plow-pbc/seed-foo" "$PLAIN" "$PLAIN_SHA" >/dev/null ); [ "$?" -eq 1 ] || fail "inactive expected rc 1"

echo "  resolve_binding: active but config.json absent → rc 2 (fail loud, broken deploy)..."
( export KWR_CONFIG_DIR="$T/cold-nope"; resolve_binding "plow-pbc/seed-foo" "$PLAIN" "$PLAIN_SHA" >/dev/null 2>&1 ); [ "$?" -eq 2 ] || fail "active+missing config expected rc 2"

echo "  resolve_binding: malformed config.json → rc 2 (fail loud, not silent fallback)..."
BAD="$T/bad"; mkdir -p "$BAD"; printf '{ not json' > "$BAD/config.json"
( export KWR_CONFIG_DIR="$BAD"; resolve_binding "plow-pbc/seed-foo" "$PLAIN" "$PLAIN_SHA" >/dev/null 2>&1 ); [ "$?" -eq 2 ] || fail "malformed config expected rc 2"

echo "  convention_frontmatter: extracts flat key:value, strips quotes..."
got=$(convention_frontmatter "$CFG/conventions/seed.md" "test-header")
[ "$got" = 'gate is `ref/verify.sh` (no `just test`)' ] || fail "frontmatter test-header mismatch: '$got'"
[ -z "$(convention_frontmatter "$CFG/conventions/seed.md" "nope")" ] || fail "absent key should be empty"

echo "  convention_body: strips the frontmatter fence..."
body=$(convention_body "$CFG/conventions/seed.md")
echo "$body" | grep -q '^test-note:' && fail "body still contains frontmatter"
echo "$body" | grep -q 'Review by the SEED grammar.' || fail "body missing prose"
# A doc with no frontmatter is echoed verbatim.
[ "$(convention_body "$CFG/conventions/house.md")" = "$(cat "$CFG/conventions/house.md")" ] || fail "no-frontmatter doc must pass through"

echo "  stage_convention: writes .codex-scratch/convention.md (frontmatter stripped)..."
RUN_DIR="$T/run"; mkdir -p "$RUN_DIR"
SCR="$T/scratchrepo"; mkdir -p "$SCR"
stage_convention "$SCR" "$CFG/conventions/seed.md"
[ -s "$RUN_DIR/inputs/convention.md" ] || fail "stage_convention did not write inputs/convention.md"
grep -q '^test-note:' "$RUN_DIR/inputs/convention.md" && fail "staged convention.md still has frontmatter"
grep -q 'Review by the SEED grammar.' "$RUN_DIR/inputs/convention.md" || fail "staged convention.md missing body"

echo "  resolve_standards: uses kwr-config standards/ when active..."
std=$(resolve_standards)
echo "$std" | grep -q 'Operator standards' || fail "resolve_standards did not include kwr-config standards/"

echo "  resolve_binding: a doc path escaping the config repo (../) → rc 2 (path guard)..."
printf 'root-only secret\n' > "$T/escape.txt"          # a real file OUTSIDE the config repo
ESC="$T/esc-config"; mkdir -p "$ESC/conventions"
printf '{ "bindings": [ { "match": {"org":"evil","marker":"SEED.md"}, "doc":"../escape.txt" } ] }\n' > "$ESC/config.json"
( export KWR_CONFIG_DIR="$ESC"; resolve_binding "evil/x" "$REPO" "$BASE_SHA" >/dev/null 2>&1 ); [ "$?" -eq 2 ] || fail "traversal doc (../escape.txt) must be rejected with rc 2"

echo "  sync_kwr_config: rejects credential-bearing (incl. bare-token) / query / fragment URLs..."
for badurl in "https://user:tok@example.com/o/r.git" "https://ghp_xxx@example.com/o/r.git" "https://example.com/o/r.git?x=1" "https://example.com/o/r.git#f"; do
    err=$( ( export KWR_CONFIG_REPO="$badurl" KWR_CONFIG_DIR="$T/wont-clone"; sync_kwr_config ) 2>&1 )
    echo "$err" | grep -qiE 'must not (contain|embed)' || fail "unsafe URL not rejected by hygiene guard: $badurl"
    [ -d "$T/wont-clone" ] && fail "hygiene guard let a clone proceed for: $badurl"
done
echo "  sync_kwr_config: plain https + scp-style ssh URLs are NOT rejected by the hygiene guard..."
# Occupied dir → `git clone` fails on its dest check BEFORE any network/SSH, so we
# isolate the (pre-clone) hygiene guard without a real clone attempt.
OCC="$T/occupied"; mkdir -p "$OCC"; : > "$OCC/x"
for okurl in "https://example.com/o/r.git" "git@example.com:o/r.git" "ssh://git@example.com/o/r.git"; do
    err=$( ( export KWR_CONFIG_REPO="$okurl" KWR_CONFIG_DIR="$OCC"; sync_kwr_config ) 2>&1 )
    echo "$err" | grep -qiE 'must not (contain|embed)' && fail "plain/key-auth URL wrongly rejected by hygiene guard: $okurl"
done

echo "  PASS (conventions: 5 config-valid + 13 resolve_binding + path-guard + url-hygiene + 2 frontmatter + 2 body + 1 stage + 1 standards)"

# Fix Merge-from-Main Mis-Attribution and Sibling-Repo Path Leak

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the reviewer from (1) attributing files brought in via `git merge origin/main` to the PR author, and (2) leaking absolute host paths (`/home/odio/...`, workdir paths) into public PR comments.

**Architecture:** Two cooperating fixes.

1. *Diff scope.* Today the reviewer hands `gh pr diff` (GitHub's three-dot view) to specialists. That view includes everything since the merge-base, including main commits the PR pulled in via `git merge origin/main`. Replace that with a locally-computed diff filtered to files the PR's own non-merge commits actually touched.
2. *Path leak.* Today `lib/search-roots.sh` writes the absolute path of each sibling checkout (`/home/odio/Hacking/plow-content`) into `search-roots.md`; specialists cite that path back when they find a hit, and `architecture`/etc. cite the workdir's absolute path (`/home/odio/.pr-reviewer/workdirs/...`). Symlink siblings under `<workdir>/.siblings/<owner>/<repo>` so cited paths can be workdir-relative, update the search-roots format, and add a `scrub_paths` safety net that runs over the assembled comment body before `gh pr comment`.

**Tech Stack:** bash, git, gh CLI, smoke-test framework in `lib/tests/`. No new dependencies.

**Repo conventions to respect:**
- Pre-merge gate is `just test`; every new helper file gets a `lib/tests/<helper>-smoke.sh` and the smoke is added to the `justfile`.
- `default: test` in `justfile`; smoke tests `set -euo pipefail`, use `mktemp -d`, trap-cleanup, and stub external commands via `PATH` injection.
- Production runs from `~/Hacking/knightwatch-reviewer/` (symlinked into `~/.pr-reviewer/`); this repo (`knightwatch-reviewer3`) is the dev checkout. **All work happens here**, lands as a PR on `srosro/knightwatch-reviewer`, and is deployed by `~/.pr-reviewer/lib` symlink already pointing at the production checkout (operator updates that side after merge).

**Operator note (in commit message, not this plan):** depth-50 → depth-500 means the canonical clone gets a one-time `git fetch --depth=500` rewrite on the next tick after deploy. This is a few seconds of extra fetch on first tick per repo. Acceptable.

---

### Task 1: Branch + scratch verify

**Files:**
- No file edits.

- [ ] **Step 1: Create feature branch from main**

```bash
cd /home/odio/Hacking/knightwatch-reviewer3
git checkout -b fix/merge-attribution-and-path-leak
```

- [ ] **Step 2: Verify clean tree and `just test` passes baseline**

```bash
git status
just test
```

Expected: `working tree clean`, then `all checks passed` from `just test`.

- [ ] **Step 3: No commit yet — this is the baseline.**

---

### Task 2: `lib/diff-scope.sh` — authored-files helper (TDD)

**Files:**
- Create: `lib/diff-scope.sh`
- Create: `lib/tests/diff-scope-smoke.sh`
- Modify: `justfile` (add the smoke test)

The helper has one responsibility: given a workdir and a base ref, return the list of files touched by the branch's non-merge commits, one per line.

- [ ] **Step 1: Write the failing smoke test**

Create `lib/tests/diff-scope-smoke.sh`:

```bash
#!/bin/bash
# Smoke test for lib/diff-scope.sh. Verifies that authored_files()
# returns ONLY files touched by the branch's non-merge commits, and
# specifically excludes files brought in by `git merge origin/main`
# (the bug that caused PR 552's reviewer to flag PR #547/#548 changes
# as if plonkus had authored them).

set -euo pipefail

TMPDIR=$(mktemp -d -t diff-scope-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../diff-scope.sh
. "$SCRIPT_DIR/diff-scope.sh"

REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email t@t; git config user.name t

# Initial commit on main.
echo a > a.txt; git add a.txt; git commit -qm "init"

# Branch off main.
git checkout -qb feature
echo f > feature.txt; git add feature.txt; git commit -qm "add feature.txt"

# Meanwhile main moves: another team adds main-only.txt and edits a.txt.
git checkout -q main
echo m > main-only.txt; git add main-only.txt; git commit -qm "main: add main-only.txt"
echo a2 >> a.txt; git add a.txt; git commit -qm "main: edit a.txt"

# Feature merges main into itself.
git checkout -q feature
git merge --no-ff -q -m "Merge main into feature" main

# Feature adds one more file after the merge.
echo f2 > feature2.txt; git add feature2.txt; git commit -qm "add feature2.txt"

cd - > /dev/null

# Authored files (non-merge, branch-only) should be feature.txt + feature2.txt.
# main-only.txt and a.txt's mainline edit must NOT appear — those were
# brought in via the merge commit and were not authored on the branch.
got=$(compute_pr_authored_files "$REPO" "main" | sort)
want=$(printf '%s\n' "feature.txt" "feature2.txt" | sort)

if [ "$got" != "$want" ]; then
    echo "FAIL: compute_pr_authored_files returned wrong list"
    echo "  got:"; printf '%s\n' "$got" | sed 's/^/    /'
    echo "  want:"; printf '%s\n' "$want" | sed 's/^/    /'
    exit 1
fi

# Empty-result fallback: when the branch has zero non-merge commits
# (degenerate case), the function should print nothing and exit non-zero
# so callers can detect and fall back.
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb only-merges
git -C "$REPO" checkout main -- a.txt  # no-op; branch == main
if compute_pr_authored_files "$REPO" "main" | grep . > /dev/null; then
    echo "FAIL: expected empty output for branch-equals-main case"
    exit 1
fi

echo "  ok: compute_pr_authored_files filters merge-from-main content"
```

- [ ] **Step 2: Run the smoke and confirm it fails** (`diff-scope.sh` doesn't exist yet)

```bash
bash lib/tests/diff-scope-smoke.sh
```

Expected: fails with `lib/diff-scope.sh: No such file or directory` from the `source` line.

- [ ] **Step 3: Implement `lib/diff-scope.sh`**

```bash
#!/bin/bash
# Diff-scope helper: identify files the PR actually authored, ignoring
# content brought in via `git merge origin/<default-branch>`.
#
# Today review-one-pr.sh hands `gh pr diff` (GitHub's three-dot view)
# to specialists. That view includes everything since the merge-base,
# so when a PR runs `git merge origin/main`, every main commit pulled
# in shows up as if the PR author wrote it. Specialists then file
# findings against the wrong author. compute_pr_authored_files filters
# the diff back down to "files that branch-unique non-merge commits
# touched" — the PR's actual contribution.
#
# Caller responsibility: ensure the workdir has enough history that
# `git log <base>..HEAD` is computable. review-one-pr.sh fetches with
# --depth=500 (Task 5) which covers the long tail of long-lived
# branches; if a branch exceeds that, the caller must fall back to the
# unfiltered diff and log a degradation note.

# compute_pr_authored_files <repo_dir> <default_branch>
#   stdout: one path per line, sorted, unique. Files touched by
#           non-merge commits unique to HEAD vs origin/<default_branch>.
#   exit:   0 if at least one file. 1 if empty (branch has no
#           non-merge content) — caller decides fallback.
compute_pr_authored_files() {
    local repo_dir="$1" default_branch="$2"
    local files
    files=$(git -C "$repo_dir" log --no-merges \
        "origin/${default_branch}..HEAD" \
        --name-only --pretty=format: 2>/dev/null \
        | grep -v '^$' | sort -u)
    [ -z "$files" ] && return 1
    printf '%s\n' "$files"
    return 0
}
```

- [ ] **Step 4: Smoke uses `origin/main`, but the test repo has no `origin`**

The smoke creates a local `main` branch but no `origin` remote. The helper does `git log origin/${default_branch}..HEAD` — this will fail in the smoke unless we either (a) add a fake `origin` remote in the smoke, or (b) make the helper accept a base ref that's a local branch.

Pick (a): the production caller always has `origin/<default_branch>`. Update the smoke to set it up:

In `lib/tests/diff-scope-smoke.sh`, after `git init` and the initial commit, add:

```bash
# Create a fake "origin" remote that aliases the same repo. This lets
# `git log origin/main..HEAD` work without a network fetch.
git -C "$REPO" remote add origin "$REPO/.git"
git -C "$REPO" fetch -q origin main
```

Then the script tracks main against `origin/main`. The merge step (`git merge -q -m "..." main`) needs adjustment — actually merging the remote ref:

```bash
# Re-fetch origin/main so the feature-branch sees the latest main commits.
git -C "$REPO" fetch -q origin main
git merge --no-ff -q -m "Merge main into feature" origin/main
```

Adjust the smoke accordingly.

- [ ] **Step 5: Re-run smoke; confirm it passes**

```bash
bash lib/tests/diff-scope-smoke.sh
```

Expected: `ok: compute_pr_authored_files filters merge-from-main content`.

- [ ] **Step 6: Add the new smoke to `justfile`**

In `justfile`, after the `=== search-roots smoke test ===` block, add:

```
    echo ""
    echo "=== diff-scope smoke test ==="
    bash lib/tests/diff-scope-smoke.sh
```

- [ ] **Step 7: Run full suite**

```bash
just test
```

Expected: `all checks passed`, with the new `diff-scope smoke test` listed.

- [ ] **Step 8: Commit**

```bash
git add lib/diff-scope.sh lib/tests/diff-scope-smoke.sh justfile
git commit -m "diff-scope: add helper for PR-authored files (no merge-from-main)"
```

---

### Task 3: Wire `compute_pr_authored_files` into `review-one-pr.sh`

**Files:**
- Modify: `lib/review-one-pr.sh` (replace `gh pr diff` calls in the diff-build block)

The current diff-build block (around line 372–401) calls `gh pr diff "$PR_NUM"` in three places: known-SHA-missing, force-whole-pr, and the silent-fallback path. We replace each with a local-git computation that filters to authored files; we keep `gh pr diff` only as a degradation fallback.

- [ ] **Step 1: Source the new helper**

Near the existing `. "$_LIB_DIR/search-roots.sh"` (line ~95), add:

```bash
. "$_LIB_DIR/diff-scope.sh"
```

- [ ] **Step 2: Add a single helper that produces the filtered diff**

Right above the `# ---- build diff + REVIEW_TASK ----` block (around line 364), add:

```bash
# Build the diff handed to specialists/aggregator. Filters out content
# brought in via `git merge origin/<default-branch>` so specialists
# don't review (and mis-attribute) commits authored on main. Falls back
# to the unfiltered `gh pr diff` if the local history is too shallow
# or the branch has no non-merge content.
build_pr_diff() {
    local repo_dir="$1" repo="$2" pr_num="$3" default_branch="$4"
    local authored unfiltered
    if authored=$(compute_pr_authored_files "$repo_dir" "$default_branch"); then
        # Three-dot diff (matches GitHub's PR view), restricted to the
        # set of files the PR's non-merge commits touched. Pass the
        # files via xargs to handle paths with spaces robustly.
        local diff_out
        diff_out=$(printf '%s\n' "$authored" | (cd "$repo_dir" && \
            xargs -d '\n' git diff "origin/${default_branch}...HEAD" --))
        if [ -n "$diff_out" ]; then
            printf '%s' "$diff_out"
            return 0
        fi
        log "$PR_ID: filtered diff was empty despite $(printf '%s\n' "$authored" | wc -l) authored file(s) — falling back to gh pr diff"
    else
        log "$PR_ID: no non-merge commits on branch (or shallow history) — falling back to gh pr diff"
    fi
    gh pr diff "$pr_num" --repo "$repo" 2>/dev/null
}
```

- [ ] **Step 3: Replace the three `gh pr diff` call sites**

Search for `gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null` in the diff-build block. There are exactly three occurrences (lines ~373, ~383, ~397 in the current file). Replace each with:

```bash
build_pr_diff "$REPO_DIR" "$REPO" "$PR_NUM" "$DEFAULT_BRANCH"
```

Verify after edit:

```bash
grep -n 'gh pr diff' lib/review-one-pr.sh
```

Expected: zero matches outside `build_pr_diff()` itself.

- [ ] **Step 4: `bash -n` syntax check**

```bash
bash -n lib/review-one-pr.sh
```

Expected: no output (clean parse).

- [ ] **Step 5: Run smoke suite**

```bash
just test
```

Expected: `all checks passed`. (No existing smoke covers the diff-build block; we add an integration smoke in Task 9.)

- [ ] **Step 6: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "review-one-pr: filter diff to PR-authored files (no merge-from-main)"
```

---

### Task 4: Bump fetch depth from 50 → 500

**Files:**
- Modify: `lib/review-one-pr.sh` (the two fetch lines around 287, 291)

`compute_pr_authored_files` uses `git log origin/main..HEAD` which needs the merge-base in local history. Depth-50 will fail merge-base on long-lived branches; depth-500 covers the realistic worst case. Long-lived branches over 500 commits hit `build_pr_diff`'s `gh pr diff` fallback, which is identical to today's behavior — fail-soft.

- [ ] **Step 1: Edit the canonical fetch lines**

In `lib/review-one-pr.sh`, find:

```bash
if ! git -C "$CANONICAL_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet; then
```

Change `--depth=50` to `--depth=500`. Same for the next fetch line:

```bash
if ! git -C "$CANONICAL_DIR" fetch origin "+refs/pull/$PR_NUM/head:$PR_BRANCH" --depth=50 --quiet; then
```

Also the initial clone line (around line 263):

```bash
if ! gh repo clone "$REPO" "$CANONICAL_DIR" -- --depth=50 --no-single-branch; then
```

Change to `--depth=500`.

Verify:

```bash
grep -n 'depth=' lib/review-one-pr.sh
```

Expected: three lines, all `--depth=500`.

- [ ] **Step 2: Sanity — bash -n + just test**

```bash
bash -n lib/review-one-pr.sh
just test
```

Expected: clean syntax, all smoke pass.

- [ ] **Step 3: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "review-one-pr: bump fetch depth 50 → 500 so merge-base computes"
```

---

### Task 5: Sibling symlinks under `.siblings/`

**Files:**
- Create: `lib/sibling-symlinks.sh`
- Create: `lib/tests/sibling-symlinks-smoke.sh`
- Modify: `justfile`
- Modify: `lib/review-one-pr.sh` (call the new helper after workdir is created)

Goal: have `<workdir>/.siblings/<owner>/<repo>` point at `${SOURCE_PATHS[<owner>/<repo>]}` for every configured sibling that exists. This lets specialists grep workdir-relative paths and cite `<owner>/<repo>/<rel>:<line>` instead of `/home/odio/...`.

- [ ] **Step 1: Failing smoke**

Create `lib/tests/sibling-symlinks-smoke.sh`:

```bash
#!/bin/bash
# Smoke for lib/sibling-symlinks.sh. Verifies symlinks land at
# <workdir>/.siblings/<owner>/<repo> pointing at SOURCE_PATHS values,
# and that missing siblings (no SOURCE_PATHS dir on disk) are skipped
# silently — the search-roots seam already classifies those.

set -euo pipefail

TMPDIR=$(mktemp -d -t sibling-symlinks-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../sibling-symlinks.sh
. "$SCRIPT_DIR/sibling-symlinks.sh"

WORKDIR="$TMPDIR/work"
mkdir -p "$WORKDIR/.git"  # mimic a real workdir
mkdir -p "$TMPDIR/foo" "$TMPDIR/bar"
# acme/qux is intentionally missing on disk.

declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/self"
    ["acme/foo"]="$TMPDIR/foo"
    ["acme/bar"]="$TMPDIR/bar"
    ["acme/qux"]="$TMPDIR/qux"
)
REPO="acme/self"

# Run.
materialize_sibling_symlinks "$WORKDIR" "$REPO" SOURCE_PATHS

# Self should NEVER be symlinked.
if [ -e "$WORKDIR/.siblings/acme/self" ]; then
    echo "FAIL: self symlink should not exist"; exit 1
fi

# foo + bar should resolve to their abs paths.
got_foo=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo" != "$TMPDIR/foo" ]; then
    echo "FAIL: foo symlink target wrong (got '$got_foo', want '$TMPDIR/foo')"
    exit 1
fi
got_bar=$(readlink "$WORKDIR/.siblings/acme/bar")
if [ "$got_bar" != "$TMPDIR/bar" ]; then
    echo "FAIL: bar symlink target wrong"; exit 1
fi

# qux is missing on disk — must NOT be symlinked.
if [ -L "$WORKDIR/.siblings/acme/qux" ]; then
    echo "FAIL: qux symlink should not exist (path missing on disk)"; exit 1
fi

# Re-running must be idempotent (production calls per-PR, fresh workdir
# usually, but defensive against re-runs).
materialize_sibling_symlinks "$WORKDIR" "$REPO" SOURCE_PATHS
got_foo2=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo2" != "$TMPDIR/foo" ]; then
    echo "FAIL: re-run changed foo symlink target"; exit 1
fi

echo "  ok: sibling symlinks materialized correctly"
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bash lib/tests/sibling-symlinks-smoke.sh
```

Expected: fails — `lib/sibling-symlinks.sh: No such file or directory`.

- [ ] **Step 3: Implement the helper**

Create `lib/sibling-symlinks.sh`:

```bash
#!/bin/bash
# Materialize sibling-repo symlinks under <workdir>/.siblings/<owner>/<repo>.
#
# Why: lib/search-roots.sh used to write absolute host paths (e.g.
# /home/odio/Hacking/plow-content) into .codex-scratch/search-roots.md,
# and specialists cited those paths back when they found a hit — leaking
# the reviewer's filesystem layout into public PR comments. Symlinking
# siblings into the workdir gives specialists a workdir-relative grep
# target (.siblings/<owner>/<repo>/...) and a citation form
# (<owner>/<repo>/<rel-path>) that's safe to post.
#
# Caller passes SOURCE_PATHS by name (bash declare -n). The current
# repo's own entry is NEVER symlinked — it'd alias the workdir to
# itself.

# materialize_sibling_symlinks <workdir> <current_repo> <source_paths_var_name>
materialize_sibling_symlinks() {
    local workdir="$1" current_repo="$2"
    local -n _src_paths="$3"
    local slug src target_dir

    mkdir -p "$workdir/.siblings"

    for slug in "${!_src_paths[@]}"; do
        [ "$slug" = "$current_repo" ] && continue
        src="${_src_paths[$slug]}"
        [ -z "$src" ] && continue
        [ -d "$src" ] || continue

        target_dir="$workdir/.siblings/$slug"
        mkdir -p "$(dirname "$target_dir")"
        ln -sfn "$src" "$target_dir"
    done
}
```

- [ ] **Step 4: Re-run smoke; confirm it passes**

```bash
bash lib/tests/sibling-symlinks-smoke.sh
```

Expected: `ok: sibling symlinks materialized correctly`.

- [ ] **Step 5: Add to justfile**

After the `=== diff-scope smoke test ===` block, add:

```
    echo ""
    echo "=== sibling-symlinks smoke test ==="
    bash lib/tests/sibling-symlinks-smoke.sh
```

- [ ] **Step 6: Wire into `review-one-pr.sh`**

Source the helper near the other lib sources (around line 95):

```bash
. "$_LIB_DIR/sibling-symlinks.sh"
```

Then call it after the workdir is freshly cloned (around line 314, just after the successful checkout of `origin/$PR_BRANCH`):

```bash
materialize_sibling_symlinks "$REPO_DIR" "$REPO" SOURCE_PATHS
```

- [ ] **Step 7: bash -n + just test**

```bash
bash -n lib/review-one-pr.sh
just test
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/sibling-symlinks.sh lib/tests/sibling-symlinks-smoke.sh \
        justfile lib/review-one-pr.sh
git commit -m "sibling-symlinks: materialize .siblings/<owner>/<repo> in workdir"
```

---

### Task 6: Switch `search-roots.sh` to workdir-relative paths

**Files:**
- Modify: `lib/search-roots.sh`
- Modify: `lib/tests/search-roots-smoke.sh`
- Modify: `lib/review-one-pr.sh` (the `stage_search_roots` call site)

Today the `included` line emits the absolute path. Switch it to `.siblings/<owner>/<repo>` so the prompt-visible reference matches the workdir layout from Task 5.

- [ ] **Step 1: Update the smoke test first** (TDD: change the contract test, watch it fail)

In `lib/tests/search-roots-smoke.sh`, find every `assert_contains` that asserts the form `acme/foo included $TMPDIR/repos/foo` and change the expected suffix to `.siblings/acme/foo`. Examples:

Search for occurrences with:

```bash
grep -n 'included \$' lib/tests/search-roots-smoke.sh
```

Expected: roughly 5–8 lines. For each, change the asserted text from:

```bash
"acme/foo included $TMPDIR/repos/foo"
```

to:

```bash
"acme/foo included .siblings/acme/foo"
```

(Apply the same substitution for `acme/bar` etc. The test's path-on-disk setup stays the same — we're only changing what the function emits.)

- [ ] **Step 2: Run the smoke; confirm it fails**

```bash
bash lib/tests/search-roots-smoke.sh
```

Expected: a `FAIL` line citing one of the new expected substrings (function still emits the abs path).

- [ ] **Step 3: Update `lib/search-roots.sh`**

In `stage_search_roots`, find the line:

```bash
body+="$sibling_repo included $sibling_path"$'\n'
```

Change to:

```bash
body+="$sibling_repo included .siblings/$sibling_repo"$'\n'
```

The header docs (top-of-file comment) need updating too. Find the block under `# Output format:` and replace `<absolute-path>` with `.siblings/<repo-slug>` in the example, plus update the description ("path only when status=included" stays accurate).

- [ ] **Step 4: Re-run the smoke; confirm it passes**

```bash
bash lib/tests/search-roots-smoke.sh
```

Expected: smoke passes.

- [ ] **Step 5: Full suite + bash -n**

```bash
bash -n lib/search-roots.sh
just test
```

Expected: `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add lib/search-roots.sh lib/tests/search-roots-smoke.sh
git commit -m "search-roots: emit .siblings/<owner>/<repo> instead of host abs paths"
```

---

### Task 7: Update prompts (consumers, dead-code-search, common-header)

**Files:**
- Modify: `prompts/dead-code-search.md`
- Modify: `prompts/consumers.md`
- Modify: `prompts/common-header.md`

These prompts describe the search-roots format and tell specialists how to cite files. Update them to match the new workdir-relative layout AND add explicit citation-form rules to prevent future leaks even if the model wanders.

- [ ] **Step 1: `prompts/dead-code-search.md`**

Find the bullet:

```
- `<repo-slug> included <absolute-path>` — author has push access; grep this path.
```

Replace with:

```
- `<repo-slug> included .siblings/<repo-slug>` — author has push access; grep this workdir-relative path. The `.siblings/` directory is a tree of symlinks pointing at the operator's local checkouts of each sibling repo.
```

After that bullet list, add a new paragraph:

```
**Citation form (cross-repo).** When you find a hit in a sibling repo, cite it as `<owner>/<repo>/<rel-path>:<line>` (e.g. `cncorp/plow-content/plow_content/emit_pr.py:59`) — no `.siblings/` prefix and no host absolute paths. Specialists that leak `.siblings/` or `/home/...` paths into the review get scrubbed to the slug form by the post step, so don't rely on that — emit the right form yourself so the in-prompt context stays clean for the aggregator.
```

- [ ] **Step 2: `prompts/consumers.md`**

Find the paragraph that begins:

```
**Search-roots coverage.** First line of `.codex-scratch/search-roots.md` is a `# coverage:` marker. Each subsequent line classifies one sibling: `<repo-slug> included <path>` (grep this), ...
```

Update the inline format to read `<repo-slug> included .siblings/<repo-slug>` and append a sentence at the end of the paragraph:

```
When citing files from an `included` sibling, use the form `<owner>/<repo>/<rel-path>:<line>` (e.g. `cncorp/plow-content/plow_content/emit_pr.py:59`). Never include a `.siblings/` prefix or an absolute `/home/...` path in your output.
```

Also find the bullet:

```
- For each symbol, `grep -rn "<symbol>"` across this repo and the `included` siblings from `.codex-scratch/search-roots.md`.
```

Append (same line):

```
The `included` value is now a workdir-relative path (e.g. `.siblings/cncorp/plow-content`); grep against that.
```

Frame-shift on cross-repo findings. Find the paragraph that begins `**External / public-API consumers are NOT your concern**` and after it, insert a new paragraph:

```
**Cross-repo finding framing.** When a sibling repo has a stale caller of a symbol this PR changed, the *user impact* is "this PR's change here will break consumer X" — frame the remedy as "coordinate with X" or "wire X's install of this package", not "fix this in X." The PR author can act on the former; they cannot land code in the sibling repo as part of this PR.
```

- [ ] **Step 3: `prompts/common-header.md`**

Add one bullet to the `**Inputs already prepared for you:**` list, after the `search-roots.md` mention or near the top of the list (whichever flows better — there isn't a search-roots bullet today, but the file does describe `.codex-scratch/dead-code.md`). Add this bullet:

```
- `.siblings/<owner>/<repo>/` — workdir-internal symlinks to sibling-repo source checkouts the operator has configured, exposed for cross-repo grep by the `consumers` and `dead-code-search` specialists. Cite files under these as `<owner>/<repo>/<rel-path>:<line>`, NOT with the `.siblings/` prefix and NOT as `/home/...` absolute paths.
```

- [ ] **Step 4: bash -n + just test**

(Prompts are markdown; the only verification is that the smoke suite still passes — there's no markdown linter in this project.)

```bash
just test
```

Expected: `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add prompts/dead-code-search.md prompts/consumers.md prompts/common-header.md
git commit -m "prompts: cite sibling-repo files in <owner>/<repo>/ form"
```

---

### Task 8: `scrub_paths` safety net before `gh pr comment`

**Files:**
- Create: `lib/path-scrub.sh`
- Create: `lib/tests/path-scrub-smoke.sh`
- Modify: `justfile`
- Modify: `lib/review-one-pr.sh`

Defense-in-depth. Even with the prompt updates, models will occasionally emit absolute paths. The aggregator output is concatenated into `$COMMENT_BODY` just before `gh pr comment` — that's the right place to scrub. We replace:

1. `<workdir>` prefix → empty (paths in the current repo become repo-relative).
2. Each `${SOURCE_PATHS[slug]}` prefix → `<slug>` (sibling abs paths become slug-prefixed).
3. `.siblings/` prefix → empty (workdir-internal sibling paths become slug-prefixed).

- [ ] **Step 1: Failing smoke**

Create `lib/tests/path-scrub-smoke.sh`:

```bash
#!/bin/bash
# Smoke for lib/path-scrub.sh. The reviewer's specialists/aggregator
# can emit absolute paths from the workdir or sibling-repo abs paths.
# scrub_review_paths() runs before `gh pr comment` and rewrites those
# to safe forms.

set -euo pipefail

TMPDIR=$(mktemp -d -t path-scrub-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../path-scrub.sh
. "$SCRIPT_DIR/path-scrub.sh"

WORKDIR="$TMPDIR/.pr-reviewer/workdirs/acme_self__42"
declare -A SOURCE_PATHS=(
    ["acme/self"]="$WORKDIR"
    ["acme/foo"]="/home/op/Hacking/foo"
    ["acme/bar"]="/home/op/Hacking/bar"
)

# Input body simulating real specialist + aggregator output.
input=$(cat <<EOF
## Findings

1. The new seam at $WORKDIR/app/Phoenix/ContainerRegistry.swift:93 bypasses
   the existing routing target.
   Files: [app/Phoenix/X.swift]($WORKDIR/app/Phoenix/X.swift:1)

2. /home/op/Hacking/foo/src/main.py:42 still calls the old API.
   Files: /home/op/Hacking/foo/src/main.py:42, /home/op/Hacking/bar/lib/x.py:7

3. Workdir-internal sibling cite: .siblings/acme/foo/src/other.py:10
EOF
)

got=$(scrub_review_paths "$input" "$WORKDIR" SOURCE_PATHS)

# 1. Workdir prefix gone.
if printf '%s' "$got" | grep -q "$WORKDIR"; then
    echo "FAIL: workdir abs path still present"; exit 1
fi
if ! printf '%s' "$got" | grep -q 'app/Phoenix/ContainerRegistry.swift:93'; then
    echo "FAIL: workdir-relative path lost"; exit 1
fi

# 2. SOURCE_PATHS abs paths replaced with slug.
if printf '%s' "$got" | grep -q '/home/op/Hacking/foo'; then
    echo "FAIL: sibling abs path still present"; exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/foo/src/main.py:42'; then
    echo "FAIL: sibling slug-prefixed form missing"; exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/bar/lib/x.py:7'; then
    echo "FAIL: second sibling slug-prefixed form missing"; exit 1
fi

# 3. .siblings/ prefix stripped.
if printf '%s' "$got" | grep -q '\.siblings/'; then
    echo "FAIL: .siblings/ prefix not stripped"; exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/foo/src/other.py:10'; then
    echo "FAIL: .siblings-stripped path lost"; exit 1
fi

echo "  ok: scrub_review_paths normalizes workdir + sibling + .siblings paths"
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bash lib/tests/path-scrub-smoke.sh
```

Expected: fails (no `lib/path-scrub.sh` yet).

- [ ] **Step 3: Implement `lib/path-scrub.sh`**

```bash
#!/bin/bash
# Path-scrub safety net. Runs over the assembled review comment body
# right before `gh pr comment`. Three substitutions, in order:
#   1. <workdir>/                  -> ""             (current-repo paths become repo-relative)
#   2. <SOURCE_PATHS[slug]>/       -> "<slug>/"      (sibling abs paths become slug-prefixed)
#   3. .siblings/                  -> ""             (workdir-internal sibling form -> slug form)
#
# Why: prompts tell specialists to cite repo-relative + slug-prefixed
# paths, and the workdir-relative `.siblings/<owner>/<repo>/...` layout
# (Task 5) makes the right thing easy. But models occasionally emit the
# old form (absolute path of cwd) or leak the symlink prefix. This pass
# is the seatbelt.
#
# scrub_review_paths emits the rewritten body to stdout; the caller
# captures it. Order matters: workdir replacement first (it's a longer
# match than any single SOURCE_PATHS entry — but identical when current
# repo is in SOURCE_PATHS). SOURCE_PATHS replacement is order-stable
# across runs because we sort the keys.

# scrub_review_paths <body> <workdir> <source_paths_var_name>
scrub_review_paths() {
    local body="$1" workdir="$2"
    local -n _src_paths="$3"
    local slug src

    # 1. Workdir abs prefix -> empty.
    body="${body//$workdir\//}"

    # 2. SOURCE_PATHS abs prefix -> slug. Sort for deterministic order
    #    (not strictly required since values shouldn't overlap, but
    #    cheap insurance against future config drift).
    for slug in $(printf '%s\n' "${!_src_paths[@]}" | LC_ALL=C sort); do
        src="${_src_paths[$slug]}"
        [ -z "$src" ] && continue
        body="${body//$src\//$slug/}"
    done

    # 3. .siblings/ prefix -> empty.
    body="${body//.siblings\//}"

    printf '%s' "$body"
}
```

- [ ] **Step 4: Re-run smoke; confirm it passes**

```bash
bash lib/tests/path-scrub-smoke.sh
```

Expected: `ok: scrub_review_paths normalizes workdir + sibling + .siblings paths`.

- [ ] **Step 5: Add to justfile**

After the `=== sibling-symlinks smoke test ===` block, add:

```
    echo ""
    echo "=== path-scrub smoke test ==="
    bash lib/tests/path-scrub-smoke.sh
```

- [ ] **Step 6: Wire into `review-one-pr.sh`**

Source the helper near the other libs:

```bash
. "$_LIB_DIR/path-scrub.sh"
```

Then add a single call right after `COMMENT_BODY=$(prepend_review_header ...)` finishes (around line 870) and before `gh pr comment`:

```bash
COMMENT_BODY=$(scrub_review_paths "$COMMENT_BODY" "$REPO_DIR" SOURCE_PATHS)
```

- [ ] **Step 7: bash -n + just test**

```bash
bash -n lib/review-one-pr.sh
just test
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/path-scrub.sh lib/tests/path-scrub-smoke.sh \
        justfile lib/review-one-pr.sh
git commit -m "path-scrub: strip workdir + sibling abs paths before posting review"
```

---

### Task 9: Verify end-to-end on the real PR 552

**Files:**
- No file edits.

The dev checkout (`knightwatch-reviewer3`) isn't what production runs from, but we can dry-run the changed code paths against a realistic input by re-using the existing PR 552 workdir/inputs.

- [ ] **Step 1: Look at the broken finding inputs once more**

```bash
RUN=/home/odio/.pr-reviewer/runs/cncorp_plow__552__20260430T155615407Z__da4f39a
grep -E "vercel\.json|build_tutorial|/home/odio" $RUN/agents/aggregator/output.md | head
```

Expected: shows the spurious findings present today.

- [ ] **Step 2: In a fresh tmp dir, rebuild what the new code would produce**

```bash
TMP=$(mktemp -d)
cp -a /home/odio/.pr-reviewer/workdirs/cncorp_plow__552/. "$TMP/"
cd "$TMP"
git fetch -q origin main --depth=500 || true   # if shallow, deepen
. /home/odio/Hacking/knightwatch-reviewer3/lib/diff-scope.sh
compute_pr_authored_files "$TMP" "main" | grep -E 'vercel\.json|build_tutorial' || \
    echo "  ✓ neither vercel.json nor build_tutorial in PR-authored files"
```

Expected: the message `✓ neither vercel.json nor build_tutorial in PR-authored files`. If anything matches, investigate before continuing.

- [ ] **Step 3: Verify scrub_paths against an aggregator output**

```bash
. /home/odio/Hacking/knightwatch-reviewer3/lib/path-scrub.sh
declare -A SOURCE_PATHS=(["cncorp/plow-content"]="/home/odio/Hacking/plow-content")
WORKDIR=/home/odio/.pr-reviewer/workdirs/cncorp_plow__552
INPUT=$(cat /home/odio/.pr-reviewer/runs/cncorp_plow__552__20260430T155615407Z__da4f39a/agents/aggregator/output.md)
OUT=$(scrub_review_paths "$INPUT" "$WORKDIR" SOURCE_PATHS)

printf '%s' "$OUT" | grep -E '/home/odio|\.siblings/' && \
    { echo "FAIL: leaks remain"; exit 1; } || \
    echo "  ✓ no /home/odio or .siblings/ leaks remain"
printf '%s' "$OUT" | grep -F 'cncorp/plow-content/plow_content/emit_pr.py' && \
    echo "  ✓ slug-prefixed sibling form present"
```

Expected: both `✓` lines, nothing else.

- [ ] **Step 4: Clean up tmp, no commit (this task is verification only)**

```bash
rm -rf "$TMP"
```

---

### Task 10: PR

**Files:**
- No file edits beyond what previous tasks committed.

- [ ] **Step 1: Final sanity**

```bash
git status
just test
git log --oneline main..HEAD
```

Expected: clean tree, all smoke green, ~7 commits (one per Task 2–8).

- [ ] **Step 2: Push**

```bash
git push -u origin fix/merge-attribution-and-path-leak
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "fix: don't review main-merged content; scrub host paths from review comments" --body "$(cat <<'EOF'
## Summary

Two cooperating fixes for the reviewer:

1. **Don't review changes brought in via `git merge origin/main`.** Today specialists see GitHub's three-dot diff (`gh pr diff`), which includes everything since the merge-base — so when a PR runs `git merge origin/main`, every main-side commit pulled in shows up as if the PR author wrote it. New `lib/diff-scope.sh::compute_pr_authored_files` filters the diff to files touched by the branch's non-merge commits only. Falls back to `gh pr diff` if the local history is too shallow (depth bumped 50 → 500 to make merge-base reliable).

2. **Stop leaking host filesystem paths into public PR comments.** `lib/search-roots.sh` used to write absolute paths (`/home/.../plow-content`) into `search-roots.md` and specialists cited those paths back. Sibling repos are now symlinked under `<workdir>/.siblings/<owner>/<repo>`; search-roots emits that workdir-relative form; prompts tell specialists to cite as `<owner>/<repo>/<rel-path>:<line>`; and `lib/path-scrub.sh` runs over the assembled comment body before `gh pr comment` to strip any remaining workdir, sibling-abs, or `.siblings/` prefixes.

## Background

Both bugs surfaced together on cncorp/plow#552: the reviewer flagged a `[medium]` deployment-policy regression on five `vercel.json` files (which were actually changed by PR #548 and merged into 552's branch from main) and a `[blocking]` cross-repo `build_tutorial` finding that exposed `/home/odio/Hacking/plow-content/...` paths in the public PR comment.

## Test plan

- [ ] `just test` passes (existing smokes + four new ones: `diff-scope`, `sibling-symlinks`, `path-scrub`, plus updated `search-roots`)
- [ ] On the next reviewer tick after this lands + the production checkout updates, re-run a /srosro-review on cncorp/plow#552 and confirm: the vercel.json finding does NOT appear, the build_tutorial finding (or any sibling-repo finding) cites paths in `<owner>/<repo>/<rel>:<line>` form, NO `/home/...` or `.siblings/` strings in the posted comment.
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: Hand off to babysit-pr**

Per the user's request, after the PR is open, invoke `/babysit-pr <PR#>`.

---

## Self-review checklist

- [ ] Spec coverage: both issues (diff scope + path leak) are addressed; verified.
- [ ] Placeholders: none. Every step has the exact command, exact filename, exact expected output.
- [ ] Type/name consistency:
    - `compute_pr_authored_files` (helper, smoke, caller) — same name everywhere.
    - `materialize_sibling_symlinks` (helper, smoke, caller) — same name.
    - `scrub_review_paths` (helper, smoke, caller) — same name.
    - `build_pr_diff` (caller-internal) — only inside `review-one-pr.sh`.
    - `SOURCE_PATHS` (associative array, defined in `repos.conf`, passed by name to the new helpers via `local -n`) — same name everywhere.
- [ ] Each task ends with a commit (TDD + frequent commits).
- [ ] Smoke tests are added to `justfile` so they run with the rest.

#!/usr/bin/env bash
# Convention seam — operator-defined review conventions, generalized.
#
# Replaces the SEED-hardcoded is_seed_repo()/seed_test_summary() (PR #151)
# with a convention-AGNOSTIC resolver driven by the operator's kwr-config
# repo. kwr ships no convention-specific literals; "SEED" is just one
# operator-supplied convention living in kwr-config, not in the engine.
#
# The operator hosts a kwr-config repo (pulled by org-sync.sh into
# $KWR_CONFIG_DIR) with:
#   config.json   { "bindings": [ {"match":{"org","slug-glob?","marker?"}, "doc"} ] }
#   conventions/  the review-posture docs each binding's `doc` points at
#   standards/    the $STANDARDS bundle (operator-owned; see resolve_standards)
#
# A binding matches a repo when the org equals the repo owner AND (if given)
# the slug-glob matches the repo name AND (if given) the marker file exists at
# the TRUSTED base ref. First match wins → its doc is the authoritative
# convention. No kwr-config configured → no binding (caller falls back to the
# repo's own .knightwatch/ then built-in defaults).
#
# Parsing split: config.json is JSON → jq (kwr already depends on jq). The
# markdown doc frontmatter is flat `key: value` → awk, mirroring
# knightwatch-config.sh's parser-light per-repo .knightwatch/ reads.

# Local cache of the pulled kwr-config repo. org-sync.sh keeps it fresh; every
# other consumer only READS it. Override via env / config.env if needed.
: "${KWR_CONFIG_DIR:=$HOME/services/kwr-config}"

# kwr_config_active
#   0 — operator wired an external kwr-config repo AND its config.json is on disk.
#   1 — KWR_CONFIG_REPO unset: the open-source default (no external config).
#   2 — set but config.json absent: a cold/not-yet-pulled or removed cache. The
#       caller degrades to fallback with a loud log — NOT a hard abort, so a box
#       whose first org-sync tick hasn't run yet still reviews (the hard-abort
#       case is narrower: a binding that matches but whose doc is missing, see
#       resolve_binding rc 2).
kwr_config_active() {
    [ -n "${KWR_CONFIG_REPO:-}" ] || return 1
    [ -f "$KWR_CONFIG_DIR/config.json" ] || return 2
    return 0
}

# convention_frontmatter <doc_path> <key>
#   Echo the value of a flat `key: value` line inside the doc's leading `---`
#   frontmatter fence (surrounding quotes stripped). Empty if absent.
convention_frontmatter() {
    local doc="$1" key="$2"
    awk -v k="$key" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { exit }
        infm {
            idx=index($0, ":")
            if (idx>0) {
                fk=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",fk)
                if (fk==k) {
                    v=substr($0,idx+1); gsub(/^[ \t]+|[ \t]+$/,"",v)
                    gsub(/^"|"$/,"",v)
                    print v; exit
                }
            }
        }
    ' "$doc"
}

# convention_body <doc_path>
#   Echo the doc with any leading `---` frontmatter fence stripped. A doc
#   without frontmatter is echoed verbatim.
convention_body() {
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { infm=0; next }
        infm { next }
        { print }
    ' "$1"
}

# resolve_binding <repo_slug> <repo_dir> <base_ref>
#   stdout: absolute path to the matched convention doc.
#   exit 0 — a binding matched (doc path on stdout).
#        1 — no convention applies: kwr-config unset, cold cache, malformed
#            config.json, or no binding matched. Caller falls back.
#        2 — a binding MATCHED this repo but its doc is missing on disk — the
#            operator declared a convention that can't be delivered. Caller
#            fails loud (reviewing it as a generic repo silently is the exact
#            failure this design removes).
# Markers are read from <base_ref> (a SHA snapshotted before PR code runs), so a
# PR that adds a marker on its head can't flip detection. A git error reading a
# marker fails that binding soft (advisory staging, not a trust gate).
resolve_binding() {
    local repo_slug="$1" repo_dir="$2" base_ref="$3"
    local rc; kwr_config_active; rc=$?
    if [ "$rc" -eq 1 ]; then return 1; fi
    if [ "$rc" -eq 2 ]; then
        echo "conventions: KWR_CONFIG_REPO set but $KWR_CONFIG_DIR/config.json absent — falling back (cold cache?)" >&2
        return 1
    fi

    local cfg="$KWR_CONFIG_DIR/config.json"
    local owner="${repo_slug%%/*}" name="${repo_slug##*/}"

    local bindings
    if ! bindings=$(jq -c '.bindings[]?' "$cfg" 2>/dev/null); then
        echo "conventions: malformed $cfg — falling back" >&2
        return 1
    fi

    local b match_org slug_glob marker doc g matched listing _globs
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        match_org=$(jq -r '.match.org // ""' <<<"$b")
        [ "$match_org" = "$owner" ] || continue

        slug_glob=$(jq -r '.match["slug-glob"] // ""' <<<"$b")
        if [ -n "$slug_glob" ]; then
            matched=0
            # read -ra splits on whitespace WITHOUT pathname expansion — a bare
            # `for g in $slug_glob` would glob the patterns (`seed-*`) against the
            # cwd, so a repo containing a `seed-*` file would break detection.
            read -ra _globs <<<"$slug_glob"
            for g in "${_globs[@]}"; do
                # shellcheck disable=SC2053  — $g is a glob pattern matched against $name
                [[ "$name" == $g ]] && { matched=1; break; }
            done
            [ "$matched" = 1 ] || continue
        fi

        marker=$(jq -r '.match.marker // ""' <<<"$b")
        if [ -n "$marker" ]; then
            listing=$(git -C "$repo_dir" ls-tree "$base_ref" -- "$marker" 2>/dev/null) || continue
            [ -n "$listing" ] || continue
        fi

        doc=$(jq -r '.doc // ""' <<<"$b")
        [ -n "$doc" ] || continue
        if [ ! -f "$KWR_CONFIG_DIR/$doc" ]; then
            echo "conventions: binding matched $repo_slug but doc missing: $KWR_CONFIG_DIR/$doc" >&2
            return 2
        fi
        printf '%s\n' "$KWR_CONFIG_DIR/$doc"
        return 0
    done <<<"$bindings"

    return 1
}

# stage_convention <repo_dir> <doc_path>
#   The shared write primitive — both the live worker (lib/review-one-pr.sh) and
#   operator-bench replay (lib/replay.sh) call it so convention.md is staged with
#   identical shape. Requires write_scratch (caller sources lib/scratch.sh) and a
#   set $RUN_DIR.
stage_convention() {
    write_scratch "$1" "convention.md" "$(convention_body "$2")"
}

# resolve_standards
#   Echo the $STANDARDS bundle. When an external kwr-config is active and ships
#   standards/*.md, concatenate those (sorted — name them 10-/20-/… for order).
#   Otherwise the operator's ~/.claude bundle (back-compat for the current
#   deploy, and the open-source no-config default).
resolve_standards() {
    if kwr_config_active 2>/dev/null; then
        local f any=0
        for f in "$KWR_CONFIG_DIR"/standards/*.md; do
            [ -f "$f" ] || continue
            cat "$f"; printf '\n\n'; any=1
        done
        [ "$any" -eq 1 ] && return 0
        # active but no standards/ shipped → fall through to ~/.claude.
    fi
    [ -f ~/.claude/CODING_STANDARDS.md ]        && { cat ~/.claude/CODING_STANDARDS.md; printf '\n\n'; }
    [ -f ~/.claude/REVIEW_PRACTICES.md ]        && { cat ~/.claude/REVIEW_PRACTICES.md; printf '\n\n'; }
    [ -f ~/.claude/TESTING.md ]                 && { cat ~/.claude/TESTING.md; printf '\n\n'; }
    [ -f ~/.claude/COMMENT_REVIEW_MISTAKES.md ] && { printf '## Known Review Mistakes (avoid repeating these)\n'; cat ~/.claude/COMMENT_REVIEW_MISTAKES.md; }
}

# sync_kwr_config
#   Clone or fast-forward the operator's kwr-config repo into $KWR_CONFIG_DIR.
#   No-op when KWR_CONFIG_REPO is unset. Called by org-sync.sh on each tick (the
#   pull cadence). ff-only pull is non-destructive: a transient outage leaves the
#   last-good cache in place rather than blanking config. Returns non-zero on
#   clone/pull failure for the caller to log.
sync_kwr_config() {
    [ -n "${KWR_CONFIG_REPO:-}" ] || return 0
    if [ -d "$KWR_CONFIG_DIR/.git" ]; then
        git -C "$KWR_CONFIG_DIR" pull --ff-only --quiet
    else
        mkdir -p "$(dirname "$KWR_CONFIG_DIR")"
        git clone --quiet "$KWR_CONFIG_REPO" "$KWR_CONFIG_DIR"
    fi
}

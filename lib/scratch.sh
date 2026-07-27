#!/usr/bin/env bash
# write_scratch — writes input artifacts into the run dir's inputs/ and
# exposes them under the codex-scratch view in the workdir so agents can
# read them via the paths their prompts cite (e.g. ".codex-scratch/diff.patch").
#
# Sourced by lib/review-one-pr.sh (production path) and lib/replay.sh
# (operator-bench replay) so both stage scratch with identical shape:
# real files at .codex-scratch/<name>, archived to $RUN_DIR/inputs/.
# Replay's prompt A/B comparison is only valid if its scratch shape
# matches production's — same primitive, same paths, same file layout.
#
# The scratch entry is a REAL FILE, not a symlink to the run dir: agents
# enumerate .codex-scratch to discover what was staged, and `find -type f`
# (find defaults to -P, no-follow) never matches a symlink. An aggregator
# that probed that way saw only the specialists' real files and posted a
# "no artifacts were staged" bail-out in place of a review (plow#1139,
# howto#25). A real file is visible to any enumeration.
write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local input_path="$RUN_DIR/inputs/$filename"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$(dirname "$input_path")" "$scratch_dir/specialists"
    # rm first: `>` follows an existing symlink at that path and would write
    # through it, out of the workdir. `ln -sfn` never did. Callers all run
    # after the .codex-scratch wipe, but the primitive owns the property.
    rm -f "$scratch_dir/$filename"
    printf '%s' "$content" > "$scratch_dir/$filename"
    cp "$scratch_dir/$filename" "$input_path"
}

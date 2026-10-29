#!/usr/bin/env bash
# Keep only the release-note lines whose pull requests are in the commit being released. release-drafter keeps adding
# pull requests to the draft while a release builds; a line naming a pull request (#123) that merged after the build's
# commit is dropped here, and the next draft lists it instead.
#
#   scripts/notes-for-build.sh <commit> <draft-body.md >notes.md
#
# Lines without a pull request number are kept. A pull request whose merge commit is not an ancestor of <commit> (or
# is not merged, or not in this clone) drops its line. Prints how many lines it dropped on stderr, as "dropped <n>".
set -euo pipefail
commit="${1:?usage: scripts/notes-for-build.sh <commit> <body >notes}"
repo="${GITHUB_REPOSITORY:-heed-build/heed}"

# Whether a pull request is in <commit>; looked up once per pull request (bash 3.2: a cache file, not an array).
cache="$(mktemp)"
trap 'rm -f "$cache"' EXIT
merged_in() {
    local pr="$1" sha answer
    answer="$(sed -n "s/^$pr //p" "$cache")"
    if [ -z "$answer" ]; then
        sha="$(gh api "repos/$repo/pulls/$pr" --jq '.merge_commit_sha // empty' 2>/dev/null || true)"
        if [ -n "$sha" ] && git merge-base --is-ancestor "$sha" "$commit" 2>/dev/null; then answer=yes; else answer=no; fi
        echo "$pr $answer" >>"$cache"
    fi
    [ "$answer" = yes ]
}

dropped=0
while IFS= read -r line || [ -n "$line" ]; do
    keep=1
    for pr in $(grep -oE '\(#[0-9]+\)' <<<"$line" | tr -d '(#)' || true); do
        merged_in "$pr" || { keep=0; break; }
    done
    if [ "$keep" = 1 ]; then printf '%s\n' "$line"; else dropped=$((dropped + 1)); fi
done
echo "dropped $dropped" >&2

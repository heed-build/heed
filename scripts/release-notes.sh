#!/usr/bin/env bash
# Write the release notes the appcast carries, as HTML: this release's, then those of the releases before it, newest
# first, each in a <div data-sparkle-version="<build>">. Sparkle (2.5+) marks the div of the build that is installed
# with the class sparkle-installed-version, and the CSS below hides it and everything older, so the update window
# reads as everything new since the version you have.
#
#   scripts/release-notes.sh <tag> <build> [how many earlier releases, default 20] >notes.html
#
# A release's build (its CFBundleVersion, what Sparkle compares) comes from the appcast it shipped with; releases from
# before heed updated itself have none, and nobody updates from them through Sparkle, so they are left out.
set -euo pipefail
tag="${1:?usage: scripts/release-notes.sh <tag> <build> [earlier]}"
build="${2:?build}"
earlier="${3:-20}"
repo="${GITHUB_REPOSITORY:-heed-build/heed}"
[[ "$build" =~ ^[0-9]+$ ]] || { echo "release-notes: build must be a number, got $build" >&2; exit 1; }

# One release's notes, as GitHub renders them.
section() {
    local tag="$1" build="$2" body
    body="$(gh release view "$tag" -R "$repo" --json body -q .body 2>/dev/null || true)"
    [ -n "$body" ] || body="Heed ${tag#v}."
    printf '<div class="release" data-sparkle-version="%s">\n<h2>Heed %s</h2>\n' "$build" "${tag#v}"
    gh api markdown -f text="$body" -f mode=gfm -f context="$repo"
    printf '</div>\n'
}

cat <<'HTML'
<style>
  .release h2 { margin-top: 1.2em; }
  .release:first-of-type h2 { margin-top: 0; }
  /* The installed version, and everything older, is not news. */
  .release.sparkle-installed-version, .release.sparkle-installed-version ~ .release { display: none; }
</style>
HTML
section "$tag" "$build"

gh release list -R "$repo" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName,publishedAt \
    -q 'sort_by(.publishedAt) | reverse | .[].tagName' \
    | grep -vx "$tag" \
    | while read -r older; do
        [ "$earlier" -gt 0 ] || break
        appcast="$(gh release download "$older" -R "$repo" -p appcast.xml -O - 2>/dev/null || true)"
        older_build="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' <<<"$appcast" | head -1)"
        [ -n "$older_build" ] || continue
        section "$older" "$older_build"
        earlier=$((earlier - 1))
    done

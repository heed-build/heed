#!/usr/bin/env bash
# Build the documentation exactly as CI does, then serve it: docs-builder, then the landing page over the generated
# index.html. `docs-builder serve` renders on demand and never applies that override, so it would preview the wrong
# home page.
#
#   mise run docs              build and serve on http://localhost:4000
#   mise run docs -- --noserve build only
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# The sub-path GitHub Pages serves from; empty at the domain root (heed.nullean.net). The landing page's <base href>
# and the workflow's prefix: input must agree with it, and nothing but this check would notice if they drifted.
path_prefix=""
landing="docs/heed-landing.html"
workflow=".github/workflows/docs.yml"
expected_base="/"
[[ -n "$path_prefix" ]] && expected_base="/$path_prefix/"
actual_base="$(grep -o '<base href="[^"]*"' "$landing" | sed 's/<base href="//; s/"$//')"
if [[ "$actual_base" != "$expected_base" ]]; then
  echo "docs: $landing has <base href=\"$actual_base\"> but the site builds for \"$expected_base\"" >&2
  exit 1
fi
if [[ -z "$path_prefix" ]] && grep -q 'prefix:' "$workflow"; then
  echo "docs: $workflow has a prefix: input but path_prefix is empty" >&2
  exit 1
fi

# docs-builder is a native binary, not a dotnet tool; cached under .artifacts. Delete it to pick up a newer release,
# or set DOCS_BUILDER_VERSION to pin one.
tool=".artifacts/tools/docs-builder"
if [[ ! -x "$tool" ]]; then
  arch="$(uname -m)"; [[ "$arch" == "x86_64" ]] && arch="x64"
  archive="docs-builder-mac-$arch.zip"
  version="${DOCS_BUILDER_VERSION:-latest}"
  if [[ "$version" == "latest" ]]; then
    url="https://github.com/elastic/docs-builder/releases/latest/download/$archive"
  else
    url="https://github.com/elastic/docs-builder/releases/download/$version/$archive"
  fi
  echo "docs: downloading $url"
  mkdir -p .artifacts/tools
  curl -fsSL "$url" -o "/tmp/$archive"
  unzip -o -q -j "/tmp/$archive" docs-builder -d .artifacts/tools
  rm "/tmp/$archive"
  chmod +x "$tool"
fi

if [[ -n "$path_prefix" ]]; then
  "$tool" build --path docs --path-prefix "$path_prefix"
else
  "$tool" build --path docs
fi
out=".artifacts/docs/html"
cp "$landing" "$out/index.html"
cp docs/robots.txt "$out/robots.txt"
cp install.sh "$out/install.sh"
# docs-builder copies images, not fonts; the landing page needs its two.
mkdir -p "$out/fonts" && cp docs/fonts/*.woff2 "$out/fonts/"
echo "docs: built $out (landing page applied)"

[[ "${1:-}" == "--noserve" ]] && exit 0
echo "docs: serving http://localhost:4000"
cd "$out" && exec python3 -m http.server 4000

#!/usr/bin/env bash
# Fetches the zmx release builds pinned in packaging/zmx/zmx.lock into Vendor/zmx/<version>/<platform>/zmx, checking
# each against its sha256. Idempotent: a build already there with the right sum is kept.
#
#   scripts/zmx.sh                 fetch and verify (bundle.sh runs this)
#   scripts/zmx.sh --print-sums    print the sums of the version in the lock file, for updating it
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/packaging/zmx/zmx.lock"
version="$(sed -n 's/^version=//p' "$lock")"
platforms=(macos-aarch64 linux-x86_64 linux-aarch64)
dest="$root/Vendor/zmx/$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for platform in "${platforms[@]}"; do
  url="https://zmx.sh/a/zmx-$version-$platform.tar.gz"
  if [ "${1:-}" = "--print-sums" ]; then
    curl -fsSL -o "$work/$platform.tar.gz" "$url"
    echo "$platform=$(shasum -a 256 "$work/$platform.tar.gz" | cut -d' ' -f1)"
    continue
  fi
  want="$(sed -n "s/^$platform=//p" "$lock")"
  [ -n "$want" ] || { echo "zmx: no sum for $platform in $lock" >&2; exit 1; }
  stamp="$dest/$platform/.sha256"
  if [ -x "$dest/$platform/zmx" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
    continue
  fi
  curl -fsSL -o "$work/$platform.tar.gz" "$url"
  got="$(shasum -a 256 "$work/$platform.tar.gz" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "zmx: $platform sum is $got, the lock file says $want" >&2; exit 1; }
  mkdir -p "$dest/$platform"
  tar -xzf "$work/$platform.tar.gz" -C "$dest/$platform" zmx
  echo "$want" >"$stamp"
  echo "zmx: $version $platform"
done

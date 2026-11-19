#!/usr/bin/env bash
# Keep the newest few caches whose key starts with a prefix, and delete the rest. Every run of ci on main saves a new
# .build cache per job (each about 700 MB, named after the commit), and the repository's 10 GB allowance filled up with old
# ones, so GitHub evicted whatever was least recently used, GhosttyKit and the toolchain included.
#
#   GH_TOKEN=... GH_REPO=owner/name scripts/prune-caches.sh KEY_PREFIX [KEEP]     (the token needs actions: write)
set -euo pipefail
prefix="${1:?usage: prune-caches.sh KEY_PREFIX [KEEP]}"
keep="${2:-2}"

ids=$(gh cache list --key "$prefix" --sort created_at --order desc --limit 100 --json id --jq ".[$keep:][].id")
if [ -z "$ids" ]; then
  echo "prune-caches: nothing to delete under $prefix (keeping $keep)"
  exit 0
fi
printf '%s\n' "$ids" | while read -r id; do
  gh cache delete "$id" && echo "prune-caches: deleted cache $id"
done

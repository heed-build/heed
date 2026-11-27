#!/usr/bin/env bash
# The live smoke suite for Browse: real GitHub reads (LiveGitHubContractTests) and an end-to-end run on one throwaway
# repository, Mpdreamz/heed-smoke (LiveBrowseE2ETests): real worktrees, the real ACP adapter on haiku, the hardened
# policy, bulk writes. It calls a model and writes to GitHub, so it only runs when asked twice: HEED_LIVE=1 here, and
# this script sets HEED_LIVE_BROWSE=1 (`mise run live`, which sets only HEED_LIVE, skips these two suites).
#
#   HEED_LIVE=1 mise run live-browse
#
# The report goes to $HEED_LIVE_REPORT, else ~/Projects/heed-plans/browse/audit/live-smoke-<date>.md.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${HEED_LIVE:-}" != 1 ]; then
  echo "live-browse calls a model (haiku) and writes to Mpdreamz/heed-smoke: run it as HEED_LIVE=1 mise run live-browse" >&2
  exit 2
fi

scripts/slot.sh swift build --product HeedPackageTests
HEED_LIVE_BROWSE=1 exec swift test --skip-build \
  --filter 'HeedCoreTests.LiveSmokeGuardTests' \
  --filter 'HeedCoreTests.LiveGitHubContractTests' \
  --filter 'HeedCoreTests.LiveBrowseE2ETests'

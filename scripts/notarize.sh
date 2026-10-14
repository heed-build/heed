#!/bin/bash
# Notarizes and staples a signed Heed.app or disk image: scripts/notarize.sh <path>
# Needs KEY_P8 (the App Store Connect API key's contents), KEY_ID and ISSUER in the environment, as the release
# workflow sets them. An app is zipped for the upload; a .dmg goes as it is. Stops with Apple's log when rejected.
set -euo pipefail
target="${1:?usage: scripts/notarize.sh <Heed.app|file.dmg>}"
work="$(mktemp -d)"
key="$work/notary.p8"
trap 'rm -rf "$work"' EXIT
printf '%s\n' "${KEY_P8:?KEY_P8 is not set}" >"$key"
auth=(--key "$key" --key-id "${KEY_ID:?KEY_ID is not set}" --issuer "${ISSUER:?ISSUER is not set}")

upload="$target"
if [ -d "$target" ]; then
  upload="$work/notarize.zip"
  ditto -c -k --keepParent "$target" "$upload"
fi

# Upload first and keep Apple's submission id, then wait for the verdict apart from that: a timeout then still says
# which submission it was. Usually minutes; a team's first submissions can take far longer.
xcrun notarytool submit "$upload" "${auth[@]}" --output-format json >"$work/submit.json" 2>&1 || true
id="$(jq -r '.id // empty' "$work/submit.json" 2>/dev/null || true)"
if [ -z "$id" ]; then
  echo "::error::The upload of $(basename "$target") to Apple failed:"
  cat "$work/submit.json"
  exit 1
fi
echo "notarization: submitted $(basename "$target") as $id"
xcrun notarytool wait "$id" "${auth[@]}" --timeout 60m || true
# Asked again on failure: a runner's network can drop for a moment, and a release should not hinge on it.
status=""
for attempt in 1 2 3 4 5; do
  status="$(xcrun notarytool info "$id" "${auth[@]}" --output-format json 2>/dev/null | jq -r '.status // empty')"
  [ -n "$status" ] && break
  echo "notarization: no answer from Apple (attempt $attempt), asking again in 30s"
  sleep 30
done
[ -n "$status" ] || { echo "::error::No verdict from Apple for submission $id." >&2; exit 1; }
echo "notarization: $status ($id)"
if [ "$status" = "In Progress" ]; then
  echo "::error::Apple is still processing submission $id after an hour. Nothing was released; run again later."
  exit 1
fi
if [ "$status" != "Accepted" ]; then
  # Apple's reasons, then stop: nothing has been attached to the draft.
  for attempt in 1 2 3; do xcrun notarytool log "$id" "${auth[@]}" && break || sleep 30; done
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
# What Gatekeeper will say on someone else's Mac.
if [ -d "$target" ]; then
  spctl --assess --type execute -vv "$target" 2>&1 | tee "$work/spctl.txt"
else
  spctl --assess --type open --context context:primary-signature -vv "$target" 2>&1 | tee "$work/spctl.txt"
fi
grep -q "source=Notarized Developer ID" "$work/spctl.txt"

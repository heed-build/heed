#!/bin/bash
# Renders packaging/dmg/background.html to packaging/dmg/background.tiff, 660x400 with a 2x layer for Retina, with
# Playwright's headless Chromium (npx playwright-core). Run after changing the HTML; the TIFF is committed.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
browser="${CHROMIUM:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/Google\ Chrome\ for\ Testing.app/Contents/MacOS/Google\ Chrome\ for\ Testing 2>/dev/null | tail -1)}"
[ -x "$browser" ] || { echo "no Chromium found (set CHROMIUM, or npx playwright install chromium)" >&2; exit 1; }
cat >"$work/render.mjs" <<JS
import { chromium } from "playwright-core";
const browser = await chromium.launch({ executablePath: process.env.BROWSER });
for (const scale of [1, 2]) {
  const page = await browser.newPage({ viewport: { width: 660, height: 400 }, deviceScaleFactor: scale });
  await page.goto("file://" + process.env.HTML);
  await page.waitForTimeout(400);
  await page.screenshot({ path: process.env.OUT + "/bg" + scale + ".png" });
}
await browser.close();
JS
(cd "$work" && npm init -y >/dev/null && npm i -s playwright-core >/dev/null)
BROWSER="$browser" HTML="$PWD/packaging/dmg/background.html" OUT="$work" node "$work/render.mjs"
tiffutil -cathidpicheck "$work/bg1.png" "$work/bg2.png" -out packaging/dmg/background.tiff
echo "wrote packaging/dmg/background.tiff"

#!/usr/bin/env bash
# Write the appcast Sparkle reads to update Heed: one item, the release being made, with the zip's EdDSA signature
# and length (from Sparkle's sign_update) and the release notes as HTML. The release workflow attaches it to the
# release, so https://github.com/heed-build/heed/releases/latest/download/appcast.xml always names the latest one.
#
#   scripts/appcast.sh <version> <build> <signature> <length> <notes.html> >appcast.xml
#
# <build> is CFBundleVersion (the commit count), which Sparkle compares; <version> is what people see.
set -euo pipefail
version="${1:?usage: scripts/appcast.sh <version> <build> <signature> <length> <notes.html>}"
build="${2:?build}"
signature="${3:?signature}"
length="${4:?length}"
notes="${5:?notes.html}"
[[ "$build" =~ ^[0-9]+$ ]] || { echo "appcast: build must be a number, got $build" >&2; exit 1; }
[[ "$length" =~ ^[0-9]+$ ]] || { echo "appcast: length must be a number, got $length" >&2; exit 1; }
url="https://github.com/heed-build/heed/releases/download/v$version/Heed-arm64.zip"
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# The notes go in CDATA; a "]]>" inside them would end it early.
html="$(sed 's/]]>/]]]]><![CDATA[>/g' "$notes")"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Heed</title>
    <link>https://heed.build/</link>
    <description>New versions of Heed</description>
    <language>en</language>
    <item>
      <title>Heed $version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$html]]></description>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML

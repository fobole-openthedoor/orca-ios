#!/bin/sh
# Builds an unsigned Release IPA for signing elsewhere (the signer's profile supplies the entitlements: push
# notifications for com.thm.orcaios, and the widget extension com.thm.orcaios.widgets).
# Usage: scripts/ipa.sh [output.ipa]
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.build/Orca-unsigned.ipa}"
derived="$root/.build/DerivedData-release"
cd "$root"
xcodegen --quiet
xcodebuild -project Orca.xcodeproj -scheme Orca -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build 2>&1 \
  | grep -E "^/.*error: |BUILD (SUCCEEDED|FAILED)" | sort -u
app="$derived/Build/Products/Release-iphoneos/Orca.app"
stage="$(mktemp -d)"
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/"
mkdir -p "$(dirname "$out")"
rm -f "$out"
(cd "$stage" && zip -qry "$out" Payload)
rm -rf "$stage"
echo "$out"

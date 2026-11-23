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
log="$(mktemp)"
if ! xcodebuild -project Orca.xcodeproj -scheme Orca -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$log" 2>&1; then
  grep -E "error: |BUILD FAILED" "$log" | sort -u
  exit 1
fi
rm -f "$log"
app="$derived/Build/Products/Release-iphoneos/Orca.app"
# A failed build can still leave a bundle with resources in it; only a bundle with the app in it ships.
[ -x "$app/Orca" ] || { echo "no executable in $app" >&2; exit 1; }
stage="$(mktemp -d)"
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/"
mkdir -p "$(dirname "$out")"
rm -f "$out"
(cd "$stage" && zip -qry "$out" Payload)
rm -rf "$stage"
echo "$out"

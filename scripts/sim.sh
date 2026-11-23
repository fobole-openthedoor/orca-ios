#!/bin/sh
# Builds Orca for the iOS Simulator, installs it on one simulator, launches it and saves a screenshot.
# Usage: scripts/sim.sh <simulator udid> <screenshot.png> [seconds to wait]
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
root="$(cd "$(dirname "$0")/.." && pwd)"
udid="$1"
shot="$2"
derived="${ORCA_DERIVED_DATA:-$root/.build/DerivedData}"
cd "$root"
xcodegen --quiet
xcodebuild -project Orca.xcodeproj -scheme Orca -destination "id=$udid" -derivedDataPath "$derived" build 2>&1 \
  | grep -E "^/.*error: |BUILD (SUCCEEDED|FAILED)" | sort -u
app="$derived/Build/Products/Debug-iphonesimulator/Orca.app"
xcrun simctl terminate "$udid" com.thm.orcaios >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" com.thm.orcaios >/dev/null
sleep "${3:-4}"
xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
echo "$shot"

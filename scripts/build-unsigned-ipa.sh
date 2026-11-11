#!/usr/bin/env bash
# Build an unsigned Fuentes Archive .ipa for SideStore.
# Requires Xcode 16 or newer on macOS. This script does not sign the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild was not found."
  echo "This Mac does not have Xcode, or this script is running on Linux."
  echo "On a Mac: install Xcode 16+, then run scripts/build-unsigned-ipa.sh"
  echo "Or push the repo and download the IPA from the GitHub Actions artifact."
  exit 1
fi

DERIVED="${DERIVED:-$ROOT/build/DerivedData}"
mkdir -p "$ROOT/build"

echo "Building FuentesArchive (unsigned, iphoneos)…"
xcodebuild \
  -project "$ROOT/FuentesArchive.xcodeproj" \
  -scheme FuentesArchive \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$(find "$DERIVED/Build/Products/Release-iphoneos" -type d -name "FuentesArchive.app" | head -n 1)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "The .app bundle was not produced under $DERIVED/Build/Products/Release-iphoneos" >&2
  exit 1
fi

STAGE="$ROOT/build/Payload"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

IPA="$ROOT/build/FuentesArchive-unsigned.ipa"
rm -f "$IPA"
(
  cd "$ROOT/build"
  zip -r -y -q "FuentesArchive-unsigned.ipa" Payload
)

# SideStore wants a zip whose first entry is Payload/<App>.app.
if ! unzip -l "$IPA" | grep -q "Payload/FuentesArchive.app/Info.plist"; then
  echo "The IPA layout is wrong:" >&2
  unzip -l "$IPA" | head
  exit 1
fi

echo "Wrote $IPA"
echo "Install it with SideStore (see README). It is unsigned on purpose."

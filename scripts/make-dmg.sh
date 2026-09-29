#!/usr/bin/env bash
#
# Builds SimpleBrowser.app from the SwiftPM executable product and wraps it in
# a drag-to-Applications DMG. Needs only the Command Line Tools; no Xcode.
#
#   scripts/make-dmg.sh                       # ad-hoc signed, arm64 + x86_64
#   ARCHS=arm64 scripts/make-dmg.sh           # native only, faster
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh
#
# Output: dist/SimpleBrowser-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SimpleBrowser"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$DIST/dmg-root"

# ---------------------------------------------------------------- build ----
# `swift build --arch a --arch b` needs Xcode's xcbuild. Building one slice per
# `--triple` and merging with lipo needs only the Command Line Tools.
slices=()
BIN_DIR=""
for arch in $ARCHS; do
  triple="$arch-apple-macosx"
  echo "▸ Building $APP_NAME ($arch, release)"
  swift build -c release --product "$APP_NAME" --triple "$triple"
  dir="$(swift build -c release --product "$APP_NAME" --triple "$triple" --show-bin-path)"
  [ -x "$dir/$APP_NAME" ] || { echo "binary not found in $dir" >&2; exit 1; }
  slices+=("$dir/$APP_NAME")
  BIN_DIR="${BIN_DIR:-$dir}"   # resource bundles are identical across slices
done

mkdir -p "$DIST"
MERGED="$DIST/$APP_NAME.merged"
if [ "${#slices[@]}" -gt 1 ]; then
  lipo -create "${slices[@]}" -output "$MERGED"
else
  cp "${slices[0]}" "$MERGED"
fi

# ---------------------------------------------------------------- icon -----
ICON_PNG="$ROOT/packaging/AppIcon-1024.png"
ICNS="$DIST/AppIcon.icns"
if [ ! -f "$ICON_PNG" ]; then
  echo "▸ Rendering app icon"
  swift "$ROOT/packaging/render-icon.swift" "$ICON_PNG"
fi

# ---------------------------------------------------------------- bundle ---
echo "▸ Assembling $APP"
rm -rf "$APP" "$DMG" "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

mv "$MERGED" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundles (e.g. InspectKit's agent.js) live next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICNS"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ---------------------------------------------------------------- sign -----
echo "▸ Signing ($CODESIGN_IDENTITY)"
sign_flags=(--force --deep --sign "$CODESIGN_IDENTITY")
if [ "$CODESIGN_IDENTITY" != "-" ]; then
  sign_flags+=(--options runtime --timestamp)
fi
# Passkeys need Apple's browser passkey entitlement, and the provisioning
# profile that grants it: without the profile the app would not launch, so
# the entitlement is only added with one.
if [ -n "${PASSKEYS_PROVISIONING_PROFILE:-}" ]; then
  echo "▸ With the passkey entitlement ($PASSKEYS_PROVISIONING_PROFILE)"
  cp "$PASSKEYS_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  sign_flags+=(--entitlements "$ROOT/packaging/Passkeys.entitlements")
fi
codesign "${sign_flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# ---------------------------------------------------------------- dmg ------
echo "▸ Creating $DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE" "$ICNS"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

# The in-app updater installs a DMG only if this signature verifies against
# the public key compiled into the app (Sources/BrowserApp/Updater.swift).
# The key is the repository secret UPDATE_SIGNING_KEY in CI, or
# ~/.simplebrowser-update-signing-key for a release made by hand.
if [ -z "${UPDATE_SIGNING_KEY:-}" ] && [ -f "$HOME/.simplebrowser-update-signing-key" ]; then
  UPDATE_SIGNING_KEY="$(cat "$HOME/.simplebrowser-update-signing-key")"
fi
if [ -n "${UPDATE_SIGNING_KEY:-}" ]; then
  echo "▸ Signing the update"
  UPDATE_SIGNING_KEY="$UPDATE_SIGNING_KEY" swift run -c release SignUpdate "$DMG"
else
  echo "⚠ UPDATE_SIGNING_KEY not set: this DMG cannot be offered as an in-app update"
fi

echo
echo "✔ $DMG"
du -h "$DMG" | cut -f1
echo
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "Ad-hoc signed: Gatekeeper will warn on first launch. Right-click → Open, or"
  echo "  xattr -d com.apple.quarantine /Applications/$APP_NAME.app"
  echo "For distribution, set CODESIGN_IDENTITY to a Developer ID and notarize the DMG."
fi

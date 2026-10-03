#!/usr/bin/env bash
#
# Builds Keel.app from the SwiftPM executable product and wraps it in
# a drag-to-Applications DMG. Needs only the Command Line Tools; no Xcode.
#
#   scripts/make-dmg.sh                       # ad-hoc signed, arm64 + x86_64
#   ARCHS=arm64 scripts/make-dmg.sh           # native only, faster
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh
#
# With a Developer ID, the app and the DMG are notarized and stapled when
# notarytool has credentials: NOTARY_KEYCHAIN_PROFILE (made once with
# `xcrun notarytool store-credentials`), or an App Store Connect API key in
# NOTARY_KEY (the .p8 file), NOTARY_KEY_ID and NOTARY_ISSUER. Then a
# downloaded DMG opens with no Gatekeeper warning.
#
# The DMG's window has a background with an arrow to Applications, laid
# out through the Finder; DMG_LAYOUT=0 makes a plain one.
#
# The `keel` command-line tool (pairing, the stdio MCP launcher, replay) is
# built alongside and ships inside the app as Contents/Helpers/keel; install
# it on the PATH with scripts/install-cli.sh. It cannot sit next to the app
# binary as Contents/MacOS/keel: on a case-insensitive disk that is the same
# file as Contents/MacOS/Keel.
#
# Output: dist/Keel-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Keel"
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
CLI_PRODUCT="keel-cli"
slices=()
cli_slices=()
BIN_DIR=""
for arch in $ARCHS; do
  triple="$arch-apple-macosx"
  echo "▸ Building $APP_NAME ($arch, release)"
  swift build -c release --product "$APP_NAME" --triple "$triple"
  dir="$(swift build -c release --product "$APP_NAME" --triple "$triple" --show-bin-path)"
  [ -x "$dir/$APP_NAME" ] || { echo "binary not found in $dir" >&2; exit 1; }
  slices+=("$dir/$APP_NAME")
  echo "▸ Building keel ($arch, release)"
  swift build -c release --product "$CLI_PRODUCT" --triple "$triple"
  [ -x "$dir/$CLI_PRODUCT" ] || { echo "keel binary not found in $dir" >&2; exit 1; }
  cli_slices+=("$dir/$CLI_PRODUCT")
  BIN_DIR="${BIN_DIR:-$dir}"   # resource bundles are identical across slices
done

mkdir -p "$DIST"
MERGED="$DIST/$APP_NAME.merged"
if [ "${#slices[@]}" -gt 1 ]; then
  lipo -create "${slices[@]}" -output "$MERGED"
else
  cp "${slices[0]}" "$MERGED"
fi
# Not "keel.merged": on a case-insensitive disk that is the app's own "Keel.merged".
CLI_MERGED="$DIST/keel-cli.merged"
if [ "${#cli_slices[@]}" -gt 1 ]; then
  lipo -create "${cli_slices[@]}" -output "$CLI_MERGED"
else
  cp "${cli_slices[0]}" "$CLI_MERGED"
fi

# ---------------------------------------------------------------- icon -----
# packaging/AppIcon.svg is the icon's source. Quick Look renders it with
# WebKit; the committed AppIcon-1024.png is the fallback when it cannot.
ICON_SVG="$ROOT/packaging/AppIcon.svg"
ICON_PNG="$ROOT/packaging/AppIcon-1024.png"
ICNS="$DIST/AppIcon.icns"
echo "▸ Rendering app icon from $(basename "$ICON_SVG")"
ICON_RENDER="$DIST/icon-render"
rm -rf "$ICON_RENDER" && mkdir -p "$ICON_RENDER"
if qlmanage -t -s 1024 -o "$ICON_RENDER" "$ICON_SVG" >/dev/null 2>&1 && [ -s "$ICON_RENDER/AppIcon.svg.png" ]; then
  ICON_PNG="$ICON_RENDER/AppIcon.svg.png"
else
  echo "  (Quick Look could not render the SVG; using packaging/AppIcon-1024.png)"
fi

# ---------------------------------------------------------------- bundle ---
echo "▸ Assembling $APP"
rm -rf "$APP" "$DMG" "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

mv "$MERGED" "$APP/Contents/MacOS/$APP_NAME"
mv "$CLI_MERGED" "$APP/Contents/Helpers/keel"
chmod 755 "$APP/Contents/Helpers/keel"
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
rm -rf "$ICON_RENDER"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ---------------------------------------------------------------- sign -----
echo "▸ Signing ($CODESIGN_IDENTITY)"
# No --deep: it would re-sign Contents/Helpers/keel with the app's
# entitlements. The helper is signed on its own below, before the app.
sign_flags=(--force --sign "$CODESIGN_IDENTITY")
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
# The helper first, with the same identity and hardened runtime but none of
# the app's entitlements; then the app, which seals it in.
cli_sign_flags=(--force --sign "$CODESIGN_IDENTITY" --identifier dev.simplebrowser.keel-cli)
if [ "$CODESIGN_IDENTITY" != "-" ]; then
  cli_sign_flags+=(--options runtime --timestamp)
fi
codesign "${cli_sign_flags[@]}" "$APP/Contents/Helpers/keel"
codesign "${sign_flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$APP/Contents/Helpers/keel"

# ---------------------------------------------------------------- notarize -
notary_args=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
NOTARIZE=0
if [ "$CODESIGN_IDENTITY" != "-" ] && [ "${#notary_args[@]}" -gt 0 ]; then NOTARIZE=1; fi

# Sends a file to Apple and waits; stops the build if Apple says no, with its log.
notarize() {
  local file="$1" out id
  echo "▸ Notarizing $(basename "$file")"
  out="$(xcrun notarytool submit "$file" "${notary_args[@]}" --wait --output-format json)" || true
  echo "$out"
  id="$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q '"status" *: *"Accepted"'; then
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" || true
    echo "✘ Notarization of $(basename "$file") was not accepted" >&2
    exit 1
  fi
}

if [ "$NOTARIZE" = 1 ]; then
  APP_ZIP="$DIST/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------- dmg ------
echo "▸ Creating $DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# One file with both sizes, which the Finder picks from on a Retina screen.
tiffutil -cathidpicheck "$ROOT/packaging/dmg-background.png" "$ROOT/packaging/dmg-background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 || cp "$ROOT/packaging/dmg-background.png" "$STAGE/.background/background.tiff"
rm -f "$DMG"

# The window: its size, a background with an arrow, the app on the left and
# Applications on the right, as the background expects. The Finder writes
# that into the image's .DS_Store; without it (DMG_LAYOUT=0, or no Finder to
# ask) the DMG is plain but works the same.
laid_out=0
if [ "${DMG_LAYOUT:-1}" = "1" ]; then
  RW="$DIST/$APP_NAME-rw.dmg"
  rm -f "$RW"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ -quiet "$RW"
  attached="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
  device="$(printf '%s\n' "$attached" | awk '/^\/dev\// { print $1; exit }')"
  volume="$(printf '%s\n' "$attached" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
  if [ -n "$volume" ] && osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$(basename "$volume")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  then
    laid_out=1
  else
    echo "⚠ The Finder could not lay out the window: a plain DMG instead"
  fi
  chflags hidden "$volume/.background" 2>/dev/null || true
  sync
  hdiutil detach "$device" -quiet || hdiutil detach "$device" -force -quiet
  if [ "$laid_out" = 1 ]; then
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
  fi
  rm -f "$RW"
fi
if [ "$laid_out" = 0 ]; then
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
fi
rm -rf "$STAGE" "$ICNS"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  # What a downloaded copy will face: Gatekeeper, from the app and the image.
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
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
  echo "For distribution, set CODESIGN_IDENTITY to a Developer ID and give notarytool credentials."
elif [ "$NOTARIZE" = 0 ]; then
  echo "Signed but not notarized: Gatekeeper will still warn. Give notarytool credentials"
  echo "(NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY with NOTARY_KEY_ID and NOTARY_ISSUER)."
else
  echo "Notarized and stapled: it opens with no warning."
fi
echo
echo "The keel command line ships inside the app. After installing Keel:"
echo "  /Applications/$APP_NAME.app/Contents/Helpers/keel help"
echo "  scripts/install-cli.sh      # puts \`keel\` on the PATH"
echo "  claude mcp add keel -- keel mcp"

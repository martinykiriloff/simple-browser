#!/usr/bin/env bash
#
# The in-app updater, end to end, without GitHub and without touching
# /Applications: version 0.0.1 is installed into a scratch folder, 0.0.2 is
# built, signed and served from a local feed, and 0.0.1 is asked to update.
# It must refuse a DMG whose signature does not verify, then install the
# genuine one, replace itself and relaunch as 0.0.2.
#
#   scripts/test-update.sh        # needs the signing key: UPDATE_SIGNING_KEY or ~/.simplebrowser-update-signing-key
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build 2>&1 | grep -E "error|Build complete" || true
"$ROOT/.build/debug/UpdateKitChecks"

WORK="$(mktemp -d -t simplebrowser-update-test)"
PORT=8768
FEED="$WORK/feed"
APPS="$WORK/Applications"
mkdir -p "$FEED" "$APPS"
cleanup() {
  pkill -f "$APPS/SimpleBrowser.app" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "▸ Building 0.0.1 (the installed copy)"
VERSION=0.0.1 ARCHS=arm64 ./scripts/make-dmg.sh >/dev/null
ditto dist/SimpleBrowser.app "$APPS/SimpleBrowser.app"

echo "▸ Building 0.0.2 (the update)"
VERSION=0.0.2 ARCHS=arm64 ./scripts/make-dmg.sh >/dev/null
cp dist/SimpleBrowser-0.0.2.dmg dist/SimpleBrowser-0.0.2.dmg.sig "$FEED/"

cat > "$FEED/latest" <<JSON
{"tag_name":"v0.0.2","draft":false,"prerelease":false,"body":"Test release.",
 "html_url":"http://127.0.0.1:$PORT/","assets":[
 {"name":"SimpleBrowser-0.0.2.dmg","browser_download_url":"http://127.0.0.1:$PORT/SimpleBrowser-0.0.2.dmg"},
 {"name":"SimpleBrowser-0.0.2.dmg.sig","browser_download_url":"http://127.0.0.1:$PORT/SIG"}]}
JSON
(cd "$FEED" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1

version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APPS/SimpleBrowser.app/Contents/Info.plist"; }
failures=0

echo "▸ A tampered update is refused"
# A valid signature, but for a different file.
echo "not the dmg" > "$WORK/other"
UPDATE_SIGNING_KEY="${UPDATE_SIGNING_KEY:-$(cat "$HOME/.simplebrowser-update-signing-key")}" "$ROOT/.build/debug/SignUpdate" "$WORK/other" >/dev/null
cp "$WORK/other.sig" "$FEED/SIG"
"$APPS/SimpleBrowser.app/Contents/MacOS/SimpleBrowser" --update-feed "http://127.0.0.1:$PORT/latest" --update-selftest "$WORK/refused.json" about:blank >/dev/null 2>&1 &
for _ in $(seq 1 90); do [ -s "$WORK/refused.json" ] && break; sleep 1; done
if grep -q "not signed by SimpleBrowser" "$WORK/refused.json" 2>/dev/null && [ "$(version)" = "0.0.1" ]; then
  echo "✔ refused, and 0.0.1 is untouched"
else
  echo "✘ a tampered update was not refused: $(cat "$WORK/refused.json" 2>/dev/null) version=$(version)"; failures=$((failures + 1))
fi
pkill -f "$APPS/SimpleBrowser.app" 2>/dev/null || true
sleep 1

echo "▸ The genuine update installs and relaunches"
cp "$FEED/SimpleBrowser-0.0.2.dmg.sig" "$FEED/SIG"
"$APPS/SimpleBrowser.app/Contents/MacOS/SimpleBrowser" --update-feed "http://127.0.0.1:$PORT/latest" --update-selftest "$WORK/installed.json" about:blank >/dev/null 2>&1 &
for _ in $(seq 1 120); do [ "$(version 2>/dev/null)" = "0.0.2" ] && break; sleep 1; done
relaunched=no
for _ in $(seq 1 20); do pgrep -f "$APPS/SimpleBrowser.app/Contents/MacOS/SimpleBrowser" >/dev/null && { relaunched=yes; break; }; sleep 0.5; done
if [ "$(version)" = "0.0.2" ] && codesign --verify --deep --strict "$APPS/SimpleBrowser.app" && [ ! -e "$APPS/SimpleBrowser.app.previous" ]; then
  echo "✔ replaced with 0.0.2, signature intact, old copy cleaned up"
else
  echo "✘ not updated: version=$(version) report=$(cat "$WORK/installed.json" 2>/dev/null)"; failures=$((failures + 1))
fi
if [ "$relaunched" = yes ]; then echo "✔ relaunched"; else echo "✘ did not relaunch"; failures=$((failures + 1)); fi

exit $failures

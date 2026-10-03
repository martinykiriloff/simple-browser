#!/usr/bin/env bash
#
# Runs the UI self-test: the app presses its own ⌘, and ⇧⌘H, types into the
# Settings field through the field editor, and clicks the Home toolbar button
# and the Settings buttons, then reports what happened. It runs inside the app
# because macOS will not let an outside process press keys without the
# Accessibility permission.
#
# The test uses a scratch settings suite, so your own homepage is never
# touched. The app takes focus for about half a minute, and the screen has to
# be unlocked: a locked screen is reported as an environment problem (exit 3).
#
#   scripts/test-ui.sh                       # debug build
#   APP=dist/Keel.app/Contents/MacOS/Keel scripts/test-ui.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${APP:-}"
if [ -z "$APP" ]; then
  swift build 2>&1 | grep -E "error|Build complete" || true
  APP="$ROOT/.build/debug/Keel"
fi
REPORT="${REPORT:-$(mktemp -t ui-report).json}"
rm -f "$REPORT"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8765/; then
  python3 Tests/Fixtures/devtools/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  sleep 1
fi

pkill -x Keel 2>/dev/null || true
sleep 0.5
"$APP" --ui-selftest "$REPORT" http://127.0.0.1:8765/ >/dev/null 2>&1 &
APP_PID=$!

for _ in $(seq 1 180); do
  [ -f "$REPORT" ] && break
  sleep 1
done
sleep 0.5
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

if [ ! -f "$REPORT" ]; then
  echo "✘ no report was written (the app did not finish the self-test)" >&2
  exit 2
fi

python3 - "$REPORT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for failure in data.get("failures", []):
    print("✘", failure)
for problem in data.get("environment", []):
    print("⚠", problem, "(environment, not the app; run it again)")
if data.get("passed"):
    print("✔ all UI checks passed")
    sys.exit(0)
sys.exit(1 if data.get("failures") else 3)
PY

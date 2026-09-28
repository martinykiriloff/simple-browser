#!/usr/bin/env bash
#
# Tests translation, the right-click menu and downloads: TranslateKit's unit
# checks, then the in-app self-test against the fixture site in
# Tests/Fixtures/page. Google is never called (the app is given a stub), and
# nothing is written outside a scratch folder. Right-clicks are real mouse
# events, sent to the app's own window.
#
# It runs quietly: the app never becomes active and its windows stay beneath
# yours. FOCUS=1 runs it in front instead.
#
#   scripts/test-page.sh
#   SNAPSHOTS=/tmp/shots scripts/test-page.sh     # also saves pictures of the window
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build 2>&1 | grep -E "error|Build complete" || true
"$ROOT/.build/debug/TranslateKitChecks"
APP="$ROOT/.build/debug/SimpleBrowser"
REPORT="${REPORT:-$(mktemp -t page-report).json}"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8767/; then
  python3 Tests/Fixtures/page/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  sleep 1
fi

rm -f "$REPORT"
QUIET_FLAG=--quiet
[ -n "${FOCUS:-}" ] && QUIET_FLAG=
"$APP" $QUIET_FLAG --page-selftest "$REPORT" ${SNAPSHOTS:+--snapshot-windows "$SNAPSHOTS"} about:blank >/dev/null 2>&1 &
APP_PID=$!
for _ in $(seq 1 180); do
  [ -s "$REPORT" ] && break
  sleep 1
done
kill "$APP_PID" 2>/dev/null || true

if [ ! -s "$REPORT" ]; then
  echo "✘ the self-test wrote no report"
  exit 1
fi
python3 - "$REPORT" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
for line in report["failures"]:
    print("✘", line)
for line in report["environment"]:
    print("⚠", line)
if report["passed"]:
    print(f"✔ all {report['checksPassed']} page checks passed")
sys.exit(0 if report["passed"] else 1)
PY

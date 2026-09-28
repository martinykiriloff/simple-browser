#!/usr/bin/env bash
#
# Tests the roadmap features (tabs, session restore, history, …): the unit
# checks, then the in-app feature self-test against the fixture site in
# Tests/Fixtures/page. Settings go to a scratch suite.
#
# It runs quietly: the app never becomes active and its windows stay beneath
# yours, so you can keep working (and typing) while it runs. FOCUS=1 runs it
# in front instead, as a person would see it.
#
#   scripts/test-features.sh
#   ONLY=tabs,history scripts/test-features.sh      # some sections only
#   SNAPSHOTS=/tmp/shots scripts/test-features.sh   # also saves pictures of windows
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build 2>&1 | grep -E "error|Build complete" || true
"$ROOT/.build/debug/BrowserKitChecks"
"$ROOT/.build/debug/BlockKitChecks"
APP="$ROOT/.build/debug/SimpleBrowser"
REPORT="${REPORT:-$(mktemp -t feature-report).json}"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8767/; then
  python3 Tests/Fixtures/page/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  sleep 1
fi

rm -f "$REPORT"
QUIET_FLAG=--quiet
[ -n "${FOCUS:-}" ] && QUIET_FLAG=
"$APP" $QUIET_FLAG --feature-selftest "$REPORT" ${ONLY:+--only "$ONLY"} ${SNAPSHOTS:+--snapshot-windows "$SNAPSHOTS"} about:blank >/dev/null 2>&1 &
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
for line in report.get("skipped", []):
    print("– not tested here:", line)
if report["passed"]:
    print(f"✔ all {report['checksPassed']} feature checks passed")
sys.exit(0 if report["passed"] else 1)
PY

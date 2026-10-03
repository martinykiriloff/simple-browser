#!/usr/bin/env bash
#
# The performance budget: the app is launched cold, opens tabs to 20 and 50,
# lets Memory Saver run, then idles with ten busy background pages; it
# writes what it measured and BrowserKitChecks judges the numbers against
# the budget in BrowserKit/PerformanceBudget.swift (the README's table).
# Over budget, this fails. It runs quietly, beneath your windows.
#
#   scripts/test-performance.sh
#   IDLE=60 scripts/test-performance.sh        # a longer idle measurement
#   RELEASE=1 scripts/test-performance.sh      # the release build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIG=debug
[ -n "${RELEASE:-}" ] && CONFIG=release
swift build -c "$CONFIG" 2>&1 | grep -E "error|Build complete" || true
APP="$ROOT/.build/$CONFIG/Keel"
CHECKS="$ROOT/.build/$CONFIG/BrowserKitChecks"
REPORT="${REPORT:-$(mktemp -t performance-report).json}"
WORK="$(mktemp -d -t keel-performance)"
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8767/; then
  python3 Tests/Fixtures/page/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  sleep 1
fi

rm -f "$REPORT"
"$APP" --quiet --performance "$REPORT" --performance-idle "${IDLE:-20}" --session-dir "$WORK/session" --downloads-dir "$WORK/downloads" keel://start >/dev/null 2>"$WORK/log" &
APP_PID=$!
for _ in $(seq 1 300); do
  [ -s "$REPORT" ] && break
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 1
done
for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
kill "$APP_PID" 2>/dev/null || true

if [ ! -s "$REPORT" ]; then
  echo "✘ the performance run wrote no report"
  cat "$WORK/log" | tail -20
  exit 1
fi
grep "\[performance\]" "$WORK/log" || true
"$CHECKS" --performance-verdict "$REPORT"

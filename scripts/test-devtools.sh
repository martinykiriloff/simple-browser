#!/usr/bin/env bash
#
# Runs the DevTools test suite: starts the fixture site, launches the app with
# DevTools open, runs Tests/Fixtures/devtools/drive-all.js inside the DevTools
# UI, prints the report and exits non-zero on any failure.
#
#   scripts/test-devtools.sh                 # debug build
#   APP=dist/Keel.app/Contents/MacOS/Keel scripts/test-devtools.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${APP:-}"
if [ -z "$APP" ]; then
  swift build 2>&1 | grep -E "error|Build complete" || true
  APP="$ROOT/.build/debug/Keel"
fi
REPORT="${REPORT:-$(mktemp -t devtools-report).json}"
rm -f "$REPORT"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8765/; then
  python3 Tests/Fixtures/devtools/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  sleep 1
fi

# A Node.js process to debug from the Node panel, when Node is installed.
NODE_PID=""
if command -v node >/dev/null 2>&1; then
  node --inspect=127.0.0.1:9339 -e 'globalThis.fixtureValue = 21; setInterval(() => console.log("node fixture tick"), 700)' >/dev/null 2>&1 &
  NODE_PID=$!
fi

pkill -x Keel 2>/dev/null || true
sleep 0.5
"$APP" --show-devtools --devtools-script "$ROOT/Tests/Fixtures/devtools/drive-all.js" \
       --devtools-out "$REPORT" --devtools-delay 4 http://127.0.0.1:8765/ >/dev/null 2>&1 &
APP_PID=$!

for _ in $(seq 1 360); do
  [ -f "$REPORT" ] && break
  sleep 1
done
sleep 1
kill "$APP_PID" 2>/dev/null || true
[ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null || true

if [ ! -f "$REPORT" ]; then
  echo "✘ no report was written (the app did not finish the driver)" >&2
  exit 2
fi

python3 - "$REPORT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not data.get("ok"):
    print("✘ driver error:", data.get("error")); sys.exit(2)
value = data["value"]
for failure in value.get("failures", []):
    print("✘", failure)
print("✔ all DevTools checks passed" if value.get("passed") else f"✘ {len(value.get('failures', []))} check(s) failed")
sys.exit(0 if value.get("passed") else 1)
PY

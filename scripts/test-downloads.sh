#!/usr/bin/env bash
#
# Downloads across a relaunch: the app starts two large downloads, pauses one
# and quits (as a person would, ⌘Q) while the other is still running. On the
# next launch both must be in the list, paused, and go on from where they
# stopped rather than start over. Uses its own downloads folder, never the
# real one. It runs quietly; FOCUS=1 runs it in front.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build 2>&1 | grep -E "error|Build complete" || true
APP="$ROOT/.build/debug/SimpleBrowser"
WORK="$(mktemp -d -t simplebrowser-downloads-test)"
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT
mkdir -p "$WORK/downloads/Files"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8767/; then
  python3 Tests/Fixtures/page/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  sleep 1
fi

QUIET_FLAG=--quiet
[ -n "${FOCUS:-}" ] && QUIET_FLAG=

# First launch: it quits by itself once the report is written.
"$APP" $QUIET_FLAG --downloads-dir "$WORK/downloads" --feature-selftest "$WORK/seed.json" --only session-downloads-seed --quit-when-done about:blank >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then
  echo "✘ the app did not quit"; kill "$PID" 2>/dev/null || true
fi
wait "$PID" 2>/dev/null || true

"$APP" $QUIET_FLAG --downloads-dir "$WORK/downloads" --feature-selftest "$WORK/verify.json" --only session-downloads-verify about:blank >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 120); do [ -s "$WORK/verify.json" ] && break; sleep 1; done
kill "$PID" 2>/dev/null || true

python3 - "$WORK/seed.json" "$WORK/verify.json" <<'PY'
import json, sys
ok = True
passed = 0
for path in sys.argv[1:]:
    try:
        report = json.load(open(path))
    except Exception as error:
        print("✘ no report:", path, error); ok = False; continue
    passed += report.get("checksPassed", 0)
    for line in report["failures"] + report["environment"]:
        print("✘", line); ok = False
if ok:
    print(f"✔ downloads went on after a relaunch ({passed} checks)")
sys.exit(0 if ok else 1)
PY

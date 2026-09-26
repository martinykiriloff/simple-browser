#!/usr/bin/env bash
#
# Session restore after a crash: the app opens tabs in two windows, is killed
# with SIGKILL (no chance to save or clean up), and must relaunch into both
# windows with every tab, and say it did not close properly. Uses its own
# session folder, never the real one. The app takes focus while it runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build 2>&1 | grep -E "error|Build complete" || true
APP="$ROOT/.build/debug/SimpleBrowser"
WORK="$(mktemp -d -t simplebrowser-session-test)"
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8767/; then
  python3 Tests/Fixtures/page/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  sleep 1
fi

"$APP" --session-dir "$WORK/session" --feature-selftest "$WORK/seed.json" --only session-seed about:blank >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do [ -s "$WORK/seed.json" ] && break; sleep 1; done
sleep 1
kill -9 "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
[ -f "$WORK/session/Session.running" ] && echo "▸ killed mid-run; the running marker was left behind, as after a crash"

"$APP" --session-dir "$WORK/session" --feature-selftest "$WORK/verify.json" --only session-verify about:blank >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do [ -s "$WORK/verify.json" ] && break; sleep 1; done
kill "$PID" 2>/dev/null || true

python3 - "$WORK/seed.json" "$WORK/verify.json" <<'PY'
import json, sys
ok = True
for path in sys.argv[1:]:
    try:
        report = json.load(open(path))
    except Exception as error:
        print("✘ no report:", path, error); ok = False; continue
    for line in report["failures"] + report["environment"]:
        print("✘", line); ok = False
if ok:
    print("✔ the session came back after SIGKILL")
sys.exit(0 if ok else 1)
PY

#!/usr/bin/env bash
#
# Tests the password manager: PasswordKit's unit checks, then the in-app
# self-test, which signs in to the fixture site (Tests/Fixtures/passwords) the
# way a person would and checks what gets offered, saved, filled and shown.
#
# Nothing here touches your own saved passwords or settings: the app is given
# a scratch vault with its own key, and a scratch settings suite. The app
# briefly takes focus while it runs.
#
#   scripts/test-passwords.sh                # debug build
#   APP=dist/SimpleBrowser.app/Contents/MacOS/SimpleBrowser scripts/test-passwords.sh
#   KEYCHAIN=1 scripts/test-passwords.sh     # also round-trips a throwaway key through the login Keychain
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${APP:-}"
if [ -z "$APP" ]; then
  swift build 2>&1 | grep -E "error|Build complete" || true
  APP="$ROOT/.build/debug/SimpleBrowser"
  "$ROOT/.build/debug/PasswordKitChecks" ${KEYCHAIN:+--keychain}
fi
REPORT="${REPORT:-$(mktemp -t passwords-report).json}"

if ! curl -s -m 2 -o /dev/null http://127.0.0.1:8766/; then
  python3 Tests/Fixtures/passwords/server.py >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  sleep 1
fi

# Only ever stop the instance started here: another test run, or the browser
# you are actually using, may be running too.
for attempt in 1 2 3; do
  rm -f "$REPORT"
  "$APP" --passwords-selftest "$REPORT" about:blank >/dev/null 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 240); do
    [ -f "$REPORT" ] && break
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.5
  done
  sleep 0.5
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  [ -f "$REPORT" ] && break
  echo "⚠ the app stopped before finishing (attempt $attempt); something else ended it. Trying again." >&2
done

if [ ! -f "$REPORT" ]; then
  echo "✘ no report was written" >&2
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
    print(f"✔ all {data.get('checksPassed')} password manager checks passed")
    sys.exit(0)
sys.exit(1 if data.get("failures") else 3)
PY

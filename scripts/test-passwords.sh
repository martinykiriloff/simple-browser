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
#   QUIET=1 scripts/test-passwords.sh        # without taking the keyboard: skips the steps that need it
#
# The list under a sign-in field only drops when the page has keyboard focus,
# which needs the app in front. QUIET=1 keeps the app beneath your windows,
# runs everything else, and says which steps it skipped.
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
  "$APP" ${QUIET:+--quiet} --passwords-selftest "$REPORT" about:blank >/dev/null 2>&1 &
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

python3 - "$REPORT" "${QUIET:-}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
quiet = len(sys.argv) > 2 and sys.argv[2] != ""
for failure in data.get("failures", []):
    print("✘", failure)
environment = data.get("environment", [])
needs_keyboard = [p for p in environment if "could not take focus" in p]
for problem in environment:
    if quiet and problem in needs_keyboard:
        print("– skipped, needs the keyboard:", problem.split(":")[0])
    else:
        print("⚠", problem, "(environment, not the app; run it again)")
if data.get("failures"):
    sys.exit(1)
if data.get("passed") or (quiet and environment == needs_keyboard):
    print(f"✔ all {data.get('checksPassed')} password manager checks passed" + (" (quietly)" if quiet else ""))
    sys.exit(0)
sys.exit(3)
PY

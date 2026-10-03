#!/usr/bin/env bash
#
# The trust layer end to end: a sandbox session with approvals answered
# "deny", then a session that runs out of its action budget. Runs quietly.
#
#   scripts/test-trust.sh
#   APP=dist/Keel.app/Contents/MacOS/Keel scripts/test-trust.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${APP:-}"
if [ -z "$APP" ]; then
  swift build 2>&1 | grep -E "error|Build complete" || true
  APP="$ROOT/.build/debug/Keel"
fi

PORT="${PORT:-9398}"
SITE_PORT="${SITE_PORT:-8792}"
SITE="http://127.0.0.1:$SITE_PORT"
python3 -m http.server "$SITE_PORT" --bind 127.0.0.1 --directory Tests/Fixtures/agent >/dev/null 2>&1 &
SERVER_PID=$!
APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

run() { # mode, extra app flags...
  local mode="$1"; shift
  local token="test-$(uuidgen)"
  local dir; dir="$(mktemp -d -t keel-agents)"
  KEEL_AGENT_DIR="$dir" "$APP" --quiet --mcp-port "$PORT" --mcp-token "$token" "$@" "$SITE/person.html" >/dev/null 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 60); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.5; done
  local status=0
  MODE="$mode" PORT="$PORT" TOKEN="$token" SITE="$SITE" KEEL_AGENT_DIR="$dir" python3 Tests/Fixtures/agent/mcp-trust-e2e.py || status=$?
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  rm -rf "$dir"
  return $status
}

status=0
echo "— sandbox, approvals denied"
run deny --agent-approve deny || status=1
echo "— action budget"
run budget --agent-approve deny --agent-budget-actions 2 || status=1
exit $status

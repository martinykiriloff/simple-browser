#!/usr/bin/env bash
#
# Runs the agent server's checks: AgentKit's unit checks, then an MCP client
# (Tests/Fixtures/agent/mcp-e2e.py) driving the real app against the fixture
# site through every tool. Runs quietly: the app stays behind your windows.
#
#   scripts/test-agent.sh                 # debug build
#   APP=dist/SimpleBrowser.app/Contents/MacOS/SimpleBrowser scripts/test-agent.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift run -q AgentKitChecks

APP="${APP:-}"
if [ -z "$APP" ]; then
  swift build 2>&1 | grep -E "error|Build complete" || true
  APP="$ROOT/.build/debug/SimpleBrowser"
fi

PORT="${PORT:-9399}"
SITE_PORT="${SITE_PORT:-8791}"
TOKEN="test-$(uuidgen)"

python3 -m http.server "$SITE_PORT" --bind 127.0.0.1 --directory Tests/Fixtures/agent >/dev/null 2>&1 &
SERVER_PID=$!
"$APP" --quiet --mcp-port "$PORT" --mcp-token "$TOKEN" "http://127.0.0.1:$SITE_PORT/page2.html" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.5
done

PORT="$PORT" TOKEN="$TOKEN" SITE="http://127.0.0.1:$SITE_PORT" python3 Tests/Fixtures/agent/mcp-e2e.py

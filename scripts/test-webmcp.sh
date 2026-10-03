#!/usr/bin/env bash
#
# Runs the WebMCP checks (AR-9): an MCP client (Tests/Fixtures/agent/webmcp-e2e.py)
# drives the real app against a page that registers tools through
# document.modelContext. WebMCP is switched on for this run only
# (--agent-webmcp); the person's setting is left as it was.
#
#   scripts/test-webmcp.sh                 # debug build
#   APP=dist/Keel.app/Contents/MacOS/Keel scripts/test-webmcp.sh
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
TOKEN="test-$(uuidgen)"

python3 -m http.server "$SITE_PORT" --bind 127.0.0.1 --directory Tests/Fixtures/agent >/dev/null 2>&1 &
SERVER_PID=$!
"$APP" --quiet --mcp-port "$PORT" --mcp-token "$TOKEN" --agent-approve all --agent-webmcp >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.5
done

PORT="$PORT" TOKEN="$TOKEN" SITE="http://127.0.0.1:$SITE_PORT" python3 Tests/Fixtures/agent/webmcp-e2e.py

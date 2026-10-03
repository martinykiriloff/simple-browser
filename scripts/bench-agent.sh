#!/usr/bin/env bash
#
# Token-efficiency benchmark: an MCP client (Tests/Fixtures/bench/bench.py)
# drives the real app over the benchmark pages and compares snapshot tokens
# with a full-DOM dump, then checks each debugging scenario's problem is
# reported. Runs quietly: the app stays behind your windows.
#
#   scripts/bench-agent.sh                # debug build
#   APP=dist/Keel.app/Contents/MacOS/Keel scripts/bench-agent.sh
#   BENCH_OUT=/tmp/bench.md scripts/bench-agent.sh   # also write the table
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
TOKEN="bench-$(uuidgen)"

python3 Tests/Fixtures/bench/server.py "$SITE_PORT" >/dev/null 2>&1 &
SERVER_PID=$!
"$APP" --quiet --mcp-port "$PORT" --mcp-token "$TOKEN" --agent-approve all >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.5
done
for _ in $(seq 1 20); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$SITE_PORT/layout.html" && break
  sleep 0.25
done

PORT="$PORT" TOKEN="$TOKEN" SITE="http://127.0.0.1:$SITE_PORT" python3 Tests/Fixtures/bench/bench.py

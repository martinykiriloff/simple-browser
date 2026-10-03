#!/usr/bin/env bash
#
# Puts the `keel` command on the PATH as a symlink to the binary inside
# Keel.app (Contents/Helpers/keel), or to this checkout's build.
#
#   scripts/install-cli.sh                 # the installed app's keel, else a debug build
#   scripts/install-cli.sh --dev           # always this checkout's build (builds it)
#   scripts/install-cli.sh --app /path/Keel.app
#   scripts/install-cli.sh --uninstall
#
# The link goes in /usr/local/bin when that is writable, else ~/.local/bin.
# Set KEEL_BIN_DIR to choose another directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="auto"
APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) MODE="dev" ;;
    --app) shift; APP="${1:?--app needs a path}"; MODE="app" ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

# Where the link goes.
if [ -n "${KEEL_BIN_DIR:-}" ]; then
  BIN_DIR="$KEEL_BIN_DIR"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
LINK="$BIN_DIR/keel"

if [ "$MODE" = "uninstall" ]; then
  removed=0
  for candidate in "$LINK" /usr/local/bin/keel "$HOME/.local/bin/keel"; do
    if [ -L "$candidate" ]; then rm -f "$candidate" && echo "✔ Removed $candidate" && removed=1; fi
  done
  [ "$removed" = 1 ] || echo "No keel link found."
  echo "The stored token stays in the Keychain; \`keel unpair\` deletes it."
  exit 0
fi

# What it points at.
app_binary() {
  local app="$1"
  for path in "$app/Contents/Helpers/keel"; do
    [ -x "$path" ] && { echo "$path"; return 0; }
  done
  return 1
}

dev_binary() {
  echo "▸ Building keel (debug)" >&2
  (cd "$ROOT" && swift build --product keel-cli >&2)
  local dir
  dir="$(cd "$ROOT" && swift build --product keel-cli --show-bin-path)"
  echo "$dir/keel-cli"
}

TARGET=""
case "$MODE" in
  app)
    TARGET="$(app_binary "$APP")" || { echo "No keel binary in $APP (expected Contents/Helpers/keel)" >&2; exit 1; } ;;
  dev)
    TARGET="$(dev_binary)" ;;
  auto)
    for app in /Applications/Keel.app "$HOME/Applications/Keel.app" "$ROOT/dist/Keel.app"; do
      if TARGET="$(app_binary "$app")"; then break; fi
      TARGET=""
    done
    [ -n "$TARGET" ] || TARGET="$(dev_binary)" ;;
esac
[ -x "$TARGET" ] || { echo "Not executable: $TARGET" >&2; exit 1; }

mkdir -p "$BIN_DIR"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "$LINK exists and is not a symlink; not replacing it." >&2
  exit 1
fi
ln -sfn "$TARGET" "$LINK"
echo "✔ $LINK → $TARGET"
"$LINK" --version

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "⚠ $BIN_DIR is not on your PATH. Add it, e.g. for zsh:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac

echo
echo "Next:"
echo "  keel pair                          # approve the request in Keel"
echo "  claude mcp add keel -- keel mcp    # Claude Code over stdio"

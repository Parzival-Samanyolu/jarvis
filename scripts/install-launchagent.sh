#!/bin/zsh
# Start Jarvis at login. Usage: scripts/install-launchagent.sh [uninstall]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Library/LaunchAgents/com.jarvis.app.plist"
if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "gui/$UID/com.jarvis.app" 2>/dev/null || true
  rm -f "$DEST"; echo "Removed."; exit 0
fi
[ -d Jarvis.app ] || { echo "Run scripts/bundle.sh first."; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__APP__|$PWD/Jarvis.app|g" -e "s|__HOME__|$HOME|g" launchagent/com.jarvis.app.plist.template > "$DEST"
plutil -lint "$DEST"
launchctl bootout "gui/$UID/com.jarvis.app" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$DEST"
echo "Installed. Jarvis will start at every login."

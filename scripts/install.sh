#!/bin/zsh
# Builds Jarvis, installs it to /Applications, moves data from the old ~/jarvis layout and starts it at login.
#   App:   /Applications/Jarvis.app
#   Data:  ~/Library/Application Support/Jarvis  (memory, usage, settings, models)
#   Logs:  ~/Library/Logs/Jarvis                 (commands.log, jarvis.log)
# Usage: scripts/install.sh [uninstall]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/Jarvis.app
DATA="$HOME/Library/Application Support/Jarvis"
LOGS="$HOME/Library/Logs/Jarvis"
AGENT="$HOME/Library/LaunchAgents/com.jarvis.app.plist"

stop() { launchctl bootout "gui/$UID/com.jarvis.app" 2>/dev/null || true; }

if [[ "${1:-}" == "uninstall" ]]; then
  stop; rm -f "$AGENT"; rm -rf "$APP"
  echo "Removed the app and login item. Your data is still in $DATA"; exit 0
fi

scripts/bundle.sh release
stop
mkdir -p "$DATA" "$LOGS"

# One-time move from the old layout (personal files in the repo folder). Never overwrites newer data.
OLD="$PWD"
for f in memory.md usage.jsonl state.json; do
  [[ -e "$OLD/$f" && ! -e "$DATA/$f" ]] && mv "$OLD/$f" "$DATA/$f" && echo "moved $f"
done
for f in commands.log jarvis.log; do
  [[ -e "$OLD/$f" && ! -e "$LOGS/$f" ]] && mv "$OLD/$f" "$LOGS/$f" && echo "moved $f"
done
if [[ -d "$OLD/models" ]]; then
  mkdir -p "$DATA/models"
  for m in "$OLD"/models/*(N); do
    [[ -e "$DATA/models/${m:t}" ]] || { mv "$m" "$DATA/models/" && echo "moved models/${m:t}"; }
  done
  rmdir "$OLD/models" 2>/dev/null || true
fi

rm -rf "$APP"
ditto Jarvis.app "$APP"
rm -rf Jarvis.app            # one copy only: the one in /Applications

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__APP__|$APP|g" -e "s|__LOGS__|$LOGS|g" launchagent/com.jarvis.app.plist.template > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootstrap "gui/$UID" "$AGENT"
echo "Installed $APP. It starts at every login."

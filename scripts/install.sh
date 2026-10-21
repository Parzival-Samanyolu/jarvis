#!/bin/zsh
# Builds Mycroft, installs it to /Applications, moves data over from the Jarvis names and starts it at login.
#   App:   /Applications/Mycroft.app
#   Data:  ~/Library/Application Support/Mycroft  (memory, usage, settings, models)
#   Logs:  ~/Library/Logs/Mycroft                 (commands.log, mycroft.log)
# Usage: scripts/install.sh [uninstall]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/Mycroft.app
DATA="$HOME/Library/Application Support/Mycroft"
LOGS="$HOME/Library/Logs/Mycroft"
AGENT="$HOME/Library/LaunchAgents/com.mycroft.app.plist"
# Before the rename everything was called Jarvis.
OLD_DATA="$HOME/Library/Application Support/Jarvis"
OLD_LOGS="$HOME/Library/Logs/Jarvis"
OLD_AGENT="$HOME/Library/LaunchAgents/com.jarvis.app.plist"

stop() {
  launchctl bootout "gui/$UID/com.mycroft.app" 2>/dev/null || true
  launchctl bootout "gui/$UID/com.jarvis.app" 2>/dev/null || true
}

if [[ "${1:-}" == "uninstall" ]]; then
  stop; rm -f "$AGENT" "$OLD_AGENT"; rm -rf "$APP" /Applications/Jarvis.app
  echo "Removed the app and login item. Your data is still in $DATA"; exit 0
fi

scripts/bundle.sh release
stop
rm -f "$OLD_AGENT"

# One-time move from the Jarvis folders. Never overwrites anything already in the new ones.
move_into() {   # move_into OLD NEW: every item of OLD not yet in NEW, then remove OLD if empty
  [[ -d "$1" ]] || return 0
  mkdir -p "$2"
  for f in "$1"/*(DN); do
    [[ -e "$2/${f:t}" ]] || { mv "$f" "$2/" && echo "moved ${f:t} to $2"; }
  done
  rmdir "$1" 2>/dev/null || true
}
move_into "$OLD_DATA/models" "$DATA/models"
move_into "$OLD_DATA" "$DATA"
[[ -e "$OLD_LOGS/jarvis.log" && ! -e "$LOGS/mycroft.log" ]] && mkdir -p "$LOGS" && mv "$OLD_LOGS/jarvis.log" "$LOGS/mycroft.log"
move_into "$OLD_LOGS" "$LOGS"
mkdir -p "$DATA" "$LOGS"

rm -rf "$APP" /Applications/Jarvis.app   # Jarvis.app: the name before the Mycroft rename
ditto Mycroft.app "$APP"
rm -rf Mycroft.app           # one copy only: the one in /Applications

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__APP__|$APP|g" -e "s|__LOGS__|$LOGS|g" launchagent/com.mycroft.app.plist.template > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootstrap "gui/$UID" "$AGENT"
echo "Installed $APP. It starts at every login."

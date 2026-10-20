#!/usr/bin/env bash
# Install hdmi-resolution for the current user. No root needed.
#
# Usage: bash install.sh [--no-restart]
#   --no-restart  install and enable, but leave a running copy alone
#                 (it picks up the new version at the next login or restart)
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
label=com.github.bestutsengineer.hdmi-resolution
app_dir="$HOME/Applications"
app="$app_dir/HDMI Resolution.app"
binary="$app/Contents/MacOS/hdmi-resolution"
agent_dir="$HOME/Library/LaunchAgents"
agent="$agent_dir/$label.plist"
bin_dir="$HOME/.local/bin"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hdmi-resolution"
domain="gui/$(id -u)"

if ! command -v swift > /dev/null; then
    echo 'Missing required tool: swift (install Xcode or the Command Line Tools)' >&2
    exit 1
fi

loaded() { launchctl print "$domain/$label" > /dev/null 2>&1; }

bash "$here/scripts/build-app.sh"

restart=1
[[ "${1:-}" == --no-restart ]] && restart=0

# The app is replaced while it is stopped. With --no-restart a running copy
# keeps the old version in memory until it is next started.
if ((restart)) && loaded; then
    launchctl bootout "$domain/$label" 2> /dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        loaded || break
        sleep 0.5
    done
fi

install -d "$app_dir" "$agent_dir" "$bin_dir" "$config_dir"
rm -rf "$app"
cp -R "$here/build/HDMI Resolution.app" "$app"
ln -sf "$binary" "$bin_dir/hdmi-resolution"
# Existing settings are kept.
[[ -e "$config_dir/config" ]] || install -m 644 "$here/config.example" "$config_dir/config"

# The login agent: started in the graphical session, restarted if it fails.
sed -e "s|@BINARY@|$binary|" "$here/launchd/$label.plist" > "$agent"
chmod 644 "$agent"

if ((restart)); then
    launchctl bootstrap "$domain" "$agent"
    echo 'Installed and running. It appears in the menu bar while an external display is connected.'
elif loaded; then
    echo 'Installed. The new version starts at the next login, or now with:'
    echo "  launchctl kickstart -k $domain/$label"
else
    echo 'Installed. It starts at the next login, or now with:'
    echo "  launchctl bootstrap $domain '$agent'"
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Note: $bin_dir is not in your PATH; run it as $bin_dir/hdmi-resolution" ;;
esac

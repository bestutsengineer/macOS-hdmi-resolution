#!/usr/bin/env bash
# Remove hdmi-resolution for the current user. Settings and state are kept.
#
# Usage: bash uninstall.sh
set -eu

label=com.github.bestutsengineer.hdmi-resolution
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hdmi-resolution"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hdmi-resolution"

launchctl bootout "gui/$(id -u)/$label" 2> /dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/hdmi-resolution"
rm -rf "$HOME/Applications/HDMI Resolution.app"

echo 'Removed. Settings, state and the log were kept; delete them with:'
echo "  rm -r '$config_dir' '$state_dir' '$HOME/Library/Logs/hdmi-resolution.log'"
if [[ -e "$state_dir/pending-mode" ]]; then
    echo 'The displays are still at the mirror resolution.'
    echo 'Set them back under System Settings > Displays.'
fi

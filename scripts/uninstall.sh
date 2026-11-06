#!/bin/sh
set -eu

label="io.github.vhorvath2010.agent-audio-jail"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/AgentAudioJail.app"
if [ -L "$HOME/.local/bin/agent-audio-jail" ]; then
    rm "$HOME/.local/bin/agent-audio-jail"
fi
echo "uninstalled; saved clips remain in ~/.agent-audio-jail until you delete it"

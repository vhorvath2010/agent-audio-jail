#!/bin/sh
# Builds the app, installs it to ~/Applications, links the CLI into ~/.local/bin,
# and registers a LaunchAgent that keeps the daemon running.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
label="io.github.vhorvath2010.agent-audio-jail"
app="$HOME/Applications/AgentAudioJail.app"
binary="$app/Contents/MacOS/agent-audio-jail"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_file="$HOME/Library/Logs/agent-audio-jail.log"

"$repo_root/scripts/build-app.sh"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$app"
cp -R "$repo_root/build/AgentAudioJail.app" "$app"
ln -sf "$binary" "$HOME/.local/bin/agent-audio-jail"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$log_file</string>
    <key>StandardOutPath</key>
    <string>$log_file</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed; daemon log: $log_file"
echo "macOS asks once for System Audio Recording permission (it asks again after each rebuild)."

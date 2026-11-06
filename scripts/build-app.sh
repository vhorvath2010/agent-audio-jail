#!/bin/sh
# Builds build/AgentAudioJail.app. The app bundle gives macOS an Info.plist to attach
# the System Audio Recording permission to.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app="$repo_root/build/AgentAudioJail.app"

swift build --package-path "$repo_root" -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$repo_root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/.build/release/agent-audio-jail" "$app/Contents/MacOS/agent-audio-jail"
codesign --force --sign - "$app"
echo "built $app"

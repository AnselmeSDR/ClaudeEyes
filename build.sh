#!/bin/bash
# Build "Claude Eyes.app". With --install, copy it to ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"

appName="Claude Eyes"
buildDir="build"
app="$buildDir/$appName.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework QuartzCore \
  Sources/*.swift -o "$app/Contents/MacOS/ClaudeEyes"

cp Resources/Info.plist "$app/Contents/Info.plist"

iconset="$buildDir/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
"$app/Contents/MacOS/ClaudeEyes" --render-iconset "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
  pkill -x ClaudeEyes || true
  # Wait for the main app and its Dock helpers to exit, or open fails with -600
  for _ in $(seq 1 30); do pgrep -x ClaudeEyes > /dev/null || break; sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$appName.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/$appName.app"
  echo "Installed and launched ~/Applications/$appName.app"
fi

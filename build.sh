#!/bin/bash
# Build "Claude Eyes.app". With --install, copy it to ~/Applications and (re)launch it. With --zip, also pack it
# as build/ClaudeEyes-<version>.zip plus its .sha256, the release assets the in-app updater downloads.
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

# The hook ships with the app, which installs it (install.sh --copy) for those who don't build from source
mkdir -p "$app/Contents/Resources/hooks"
cp hooks/claude-state.sh hooks/install.sh "$app/Contents/Resources/hooks/"
chmod +x "$app/Contents/Resources/hooks/"*.sh

codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = "--zip" ]; then
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  zip="ClaudeEyes-$version.zip"
  rm -f "$buildDir/$zip" "$buildDir/$zip.sha256"
  ditto -c -k --keepParent "$app" "$buildDir/$zip"
  (cd "$buildDir" && shasum -a 256 "$zip" > "$zip.sha256")
  echo "Packed $buildDir/$zip"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x ClaudeEyes || true
  # Wait for the main app and its Dock helpers to exit, or open fails with -600
  for _ in $(seq 1 30); do pgrep -x ClaudeEyes > /dev/null || break; sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$appName.app"
  cp -R "$app" "$HOME/Applications/"
  # LaunchServices may still be forgetting the old instance: retry instead of failing with -600
  for attempt in 1 2 3 4 5; do
    open "$HOME/Applications/$appName.app" 2> /dev/null && break
    if [ "$attempt" -eq 5 ]; then
      echo "Could not launch ~/Applications/$appName.app" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "Installed and launched ~/Applications/$appName.app"
fi

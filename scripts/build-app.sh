#!/usr/bin/env bash
# Build "HDMI Resolution.app" into build/. No Xcode project needed.
#
# Usage: bash scripts/build-app.sh
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app="$here/build/HDMI Resolution.app"
label=com.github.bestutsengineer.hdmi-resolution

cd "$here"
swift build -c release
binary="$(swift build -c release --show-bin-path)/hdmi-resolution"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/hdmi-resolution"

# LSUIElement: no Dock icon and no app menu; the app lives in the menu bar.
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>HDMI Resolution</string>
    <key>CFBundleDisplayName</key>
    <string>HDMI Resolution</string>
    <key>CFBundleIdentifier</key>
    <string>$label</string>
    <key>CFBundleExecutable</key>
    <string>hdmi-resolution</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Signed for this Mac only. It is not notarised, so it is meant to be built
# where it runs rather than downloaded.
codesign --force --sign - "$app" 2> /dev/null

echo "Built $app"

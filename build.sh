#!/bin/sh
# Builds "CI Local.app" and installs it into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/CI Local.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CILocal "$APP/Contents/MacOS/CILocal"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CI Local</string>
<key>CFBundleDisplayName</key><string>CI Local</string>
<key>CFBundleIdentifier</key><string>com.mohamedchami.ci-local</string>
<key>CFBundleExecutable</key><string>CILocal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/CI Local.app"
cp -R "$APP" "$HOME/Applications/"
# Leave one copy only: a second launchable .app would run duplicate runner managers.
rm -rf "$APP"
echo "Installed ~/Applications/CI Local.app"

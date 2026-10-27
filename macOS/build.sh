#!/bin/bash
set -e

VERSION=${1:-"1.7.1"}
echo "Building WFHTimer version $VERSION..."

echo "Compiling Universal Swift Binary (arm64 + x86_64)..."
mkdir -p "WFHTimer.app/Contents/MacOS"
mkdir -p "WFHTimer.app/Contents/Resources"
cp AppIcon.icns "WFHTimer.app/Contents/Resources/"
swiftc -O -target arm64-apple-macos13.0 Source/main.swift -o "WFHTimer.app/Contents/MacOS/WFHTimer_arm64"
swiftc -O -target x86_64-apple-macos13.0 Source/main.swift -o "WFHTimer.app/Contents/MacOS/WFHTimer_x86_64"
lipo -create -output "WFHTimer.app/Contents/MacOS/WFHTimer" \
    "WFHTimer.app/Contents/MacOS/WFHTimer_arm64" \
    "WFHTimer.app/Contents/MacOS/WFHTimer_x86_64"
rm -f "WFHTimer.app/Contents/MacOS/WFHTimer_arm64" "WFHTimer.app/Contents/MacOS/WFHTimer_x86_64"

echo "Creating PkgInfo..."
echo -n "APPL????" > "WFHTimer.app/Contents/PkgInfo"

echo "Creating Info.plist..."
cat <<EOF > "WFHTimer.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WFHTimer</string>
    <key>CFBundleIdentifier</key>
    <string>com.auxetics.wfhtimer</string>
    <key>CFBundleName</key>
    <string>WFH Timer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Codesigning..."
codesign --force --deep -s - "WFHTimer.app"

echo "Creating DMG Installer..."
rm -rf build_dmg WFHTimer.dmg
mkdir -p build_dmg
cp -R "WFHTimer.app" build_dmg/
ln -s /Applications build_dmg/Applications
hdiutil create -volname "WFHTimer" -srcfolder build_dmg -ov -format UDZO "WFHTimer.dmg"

echo "Build Complete! WFHTimer.dmg is ready."

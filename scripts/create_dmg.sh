#!/bin/bash
# Create a styled DMG installer for mywisper
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="mywisper"
DMG_NAME="mywisper.dmg"
DMG_OUTPUT="$HOME/Downloads/$DMG_NAME"
VOLUME_NAME="mywisper"
STAGING_DIR="$PROJECT_DIR/build/dmg_staging"
XCODE_PATH="/Users/barssoft/Downloads/Xcode.app/Contents/Developer"
BG_DIR="$PROJECT_DIR/build/dmg_background"

echo "=== Building mywisper DMG ==="

# 1. Build Release
echo "[1/6] Building Release..."
DEVELOPER_DIR="$XCODE_PATH" xcodebuild \
    -project "$PROJECT_DIR/mywisper.xcodeproj" \
    -scheme mywisper \
    -configuration Release \
    build \
    CONFIGURATION_BUILD_DIR="$PROJECT_DIR/build/Release" \
    -quiet

APP_PATH="$PROJECT_DIR/build/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — $APP_PATH not found"
    exit 1
fi
echo "  Built: $APP_PATH"

# Bundle whisper-cli binary into the app
WHISPER_CLI="$HOME/Downloads/whisper.cpp/build/bin/whisper-cli"
if [ ! -f "$WHISPER_CLI" ]; then
    # Try /usr/local/bin as fallback
    WHISPER_CLI="/usr/local/bin/whisper-cli"
fi
if [ -f "$WHISPER_CLI" ]; then
    echo "  Bundling whisper-cli from: $WHISPER_CLI"
    cp "$WHISPER_CLI" "$APP_PATH/Contents/Resources/whisper-cli"
    chmod +x "$APP_PATH/Contents/Resources/whisper-cli"
else
    echo "ERROR: whisper-cli binary not found. Build whisper.cpp first:"
    echo "  cd ~/Downloads/whisper.cpp && cmake -B build && cmake --build build --config Release"
    exit 1
fi

# 2. Create DMG background image
echo "[2/6] Creating DMG background..."
mkdir -p "$BG_DIR"
swift "$SCRIPT_DIR/make_dmg_background.swift" "$BG_DIR/background.png"

# 3. Prepare staging directory
echo "[3/6] Staging..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Copy background if it exists
if [ -f "$BG_DIR/background.png" ]; then
    mkdir -p "$STAGING_DIR/.background"
    cp "$BG_DIR/background.png" "$STAGING_DIR/.background/background.png"
fi

# 4. Detach any existing mount and remove old DMG
echo "[4/6] Cleaning up old DMG..."
hdiutil detach "/Volumes/$VOLUME_NAME" -quiet 2>/dev/null || true
sleep 1
rm -f "$DMG_OUTPUT"
rm -f "$PROJECT_DIR/build/temp_$DMG_NAME"

# 5. Create DMG
echo "[5/6] Creating DMG..."

# Create a writable DMG first
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    "$PROJECT_DIR/build/temp_$DMG_NAME" \
    -quiet

# Mount it to apply styling
MOUNT_OUTPUT=$(hdiutil attach "$PROJECT_DIR/build/temp_$DMG_NAME" -readwrite -noverify -noautoopen)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
sleep 1

# Style the DMG window with AppleScript
if [ -f "$STAGING_DIR/.background/background.png" ]; then
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 720, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 72
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {130, 170}
        set position of item "Applications" of container window to {390, 170}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
else
    # Plain styling without background
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 660, 450}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "$APP_NAME.app" of container window to {140, 170}
        set position of item "Applications" of container window to {420, 170}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
fi

# Detach
hdiutil detach "$MOUNT_POINT" -quiet
sleep 1

# Convert to compressed read-only DMG
hdiutil convert \
    "$PROJECT_DIR/build/temp_$DMG_NAME" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_OUTPUT" \
    -quiet

rm -f "$PROJECT_DIR/build/temp_$DMG_NAME"

# 6. Done
echo "[6/6] Done!"
DMG_SIZE=$(du -h "$DMG_OUTPUT" | awk '{print $1}')
echo ""
echo "  DMG: $DMG_OUTPUT ($DMG_SIZE)"
echo ""
echo "  To install:"
echo "    1. Open $DMG_OUTPUT"
echo "    2. Drag mywisper to Applications"
echo "    3. Grant Accessibility in System Settings"
echo ""
echo "  Or use the quick reinstall script:"
echo "    bash ~/Downloads/reinstall_mywisper.sh"

#!/bin/bash
# Signed + notarized release build, same flow as the twickets app.
set -e

APP_NAME="gnotify"
APP_LOWER="gnotify"
TEAM_ID="6255B58MWB"
APPLE_ID="jcamp@girl4.com"
ARCHIVE_PATH="/tmp/gnotify.xcarchive"
ICON_DIR="/tmp/gnotify.iconset"
ICON_SRC="$(dirname "$0")/macos/Runner/Assets.xcassets/AppIcon.appiconset"

cd "$(dirname "$0")"

echo "==> Cleaning previous build artifacts..."
rm -f ~/Desktop/${APP_LOWER}.zip ~/Desktop/${APP_LOWER}.dmg
rm -f "/tmp/gnotify.zip"
rm -rf "$ARCHIVE_PATH"

echo "==> Bumping build number..."
perl -i -pe 's/^(version:\s+\S+\+)(\d+)/$1 . ($2 + 1)/e' pubspec.yaml
grep '^version:' pubspec.yaml

echo "==> Building release..."
flutter build macos --release

echo "==> Archiving with Xcode..."
cd macos && xcodebuild \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE="Manual" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  2>&1 | tail -5
cd ..

echo "==> Submitting for notarization..."
ditto -c -k --keepParent \
  "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" \
  "/tmp/gnotify.zip"

xcrun notarytool submit "/tmp/gnotify.zip" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --keychain-profile "notarytool" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple \
  "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"

echo "==> Creating release zip..."
ditto -c -k --keepParent \
  "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" \
  ~/Desktop/${APP_LOWER}.zip

echo "==> Generating .icns for DMG volume icon..."
rm -rf "$ICON_DIR"
mkdir "$ICON_DIR"
cp "$ICON_SRC/app_icon_16.png"   "$ICON_DIR/icon_16x16.png"
cp "$ICON_SRC/app_icon_32.png"   "$ICON_DIR/icon_16x16@2x.png"
cp "$ICON_SRC/app_icon_32.png"   "$ICON_DIR/icon_32x32.png"
cp "$ICON_SRC/app_icon_64.png"   "$ICON_DIR/icon_32x32@2x.png"
cp "$ICON_SRC/app_icon_128.png"  "$ICON_DIR/icon_128x128.png"
cp "$ICON_SRC/app_icon_256.png"  "$ICON_DIR/icon_128x128@2x.png"
cp "$ICON_SRC/app_icon_256.png"  "$ICON_DIR/icon_256x256.png"
cp "$ICON_SRC/app_icon_512.png"  "$ICON_DIR/icon_256x256@2x.png"
cp "$ICON_SRC/app_icon_512.png"  "$ICON_DIR/icon_512x512.png"
cp "$ICON_SRC/app_icon_1024.png" "$ICON_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICON_DIR" -o "/tmp/gnotify.icns"

echo "==> Creating DMG..."
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 175 190 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 425 190 \
  --volicon "/tmp/gnotify.icns" \
  ~/Desktop/${APP_LOWER}.dmg \
  "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"

echo ""
echo "Done! Output on Desktop:"
echo "  ~/Desktop/${APP_LOWER}.zip"
echo "  ~/Desktop/${APP_LOWER}.dmg"

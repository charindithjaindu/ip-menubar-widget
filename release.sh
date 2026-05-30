#!/bin/sh
# Sign (Developer ID + hardened runtime), notarize, staple, build DMG, and cut
# a GitHub Release. Requires: signing identity in keychain + notarytool profile.
set -e
cd "$(dirname "$0")"

IDENTITY="Developer ID Application: Jaindu Charindith Ratnayake (832NR24SWX)"
NOTARY_PROFILE="notarytool"
APP_NAME="WhatsMyIP"
VERSION="${1:-1.0.0}"
DMG="$APP_NAME-$VERSION.dmg"

echo "==> Regenerate project + Release build (signed, hardened runtime)"
xcodegen generate >/dev/null
rm -rf releasebuild
xcodebuild -project WhatsMyIP.xcodeproj -scheme WhatsMyIP \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath releasebuild \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=832NR24SWX \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build

APP="releasebuild/Build/Products/Release/$APP_NAME.app"
echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Build DMG"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> Sign the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarize (uploads to Apple, waits for result)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Staple the notarization ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo "==> Create GitHub Release v$VERSION with the notarized DMG"
gh release create "v$VERSION" "$DMG" \
  --title "What's My IP v$VERSION" \
  --notes "Notarized macOS menu bar app + widget. Download the DMG, open it, and drag the app to Applications."

echo "DONE: $DMG released."

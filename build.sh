#!/bin/sh
# Build an ad-hoc-signed Debug app into ./build, then print where it landed.
set -e
cd "$(dirname "$0")"
[ -f WhatsMyIP.xcodeproj/project.pbxproj ] || xcodegen generate
xcodebuild -project WhatsMyIP.xcodeproj -scheme WhatsMyIP \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES build
echo "Built: build/Build/Products/Debug/WhatsMyIP.app"
echo "Run:   open build/Build/Products/Debug/WhatsMyIP.app"

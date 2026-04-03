#!/bin/bash
set -euo pipefail

APP_NAME="LogitechVerticalMXMapper"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

# Compile
swiftc -O \
    -target arm64-apple-macos13.0 \
    -framework IOKit \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    AppDelegate.swift

# Bundle Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Ad-hoc sign
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "Then grant Accessibility access:"
echo "  System Settings → Privacy & Security → Accessibility → add $APP_NAME"

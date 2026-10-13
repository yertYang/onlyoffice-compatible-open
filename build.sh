#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${ARCH:-arm64}"
VERSION="1.1"
case "$ARCH" in
  arm64) LABEL="Apple芯片" ;;
  x86_64) LABEL="Intel" ;;
  *) echo "ARCH must be arm64 or x86_64" >&2; exit 1 ;;
esac

APP_NAME="ONLYOFFICE兼容打开"
BUILD_DIR="$PROJECT_ROOT/build"
DIST_DIR="$PROJECT_ROOT/dist"
STAGED_APP="$BUILD_DIR/app/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$BUILD_DIR/module-cache" "$DIST_DIR"

/usr/bin/xcrun swiftc -target "$ARCH-apple-macos12.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_ROOT/CompatibleOpen.swift" \
  -o "$STAGED_APP/Contents/MacOS/CompatibleOpen" \
  -framework Cocoa -framework Foundation -framework UniformTypeIdentifiers

cp "$PROJECT_ROOT/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>CompatibleOpen</string>
  <key>CFBundleIdentifier</key><string>local.onlyoffice.compatible-open</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local document compatibility utility</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeExtensions</key><array><string>docx</string></array>
    <key>CFBundleTypeName</key><string>Word DOCX</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>org.openxmlformats.wordprocessingml.document</string></array>
  </dict></array>
</dict></plist>
PLIST

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

FINAL_APP="$DIST_DIR/$APP_NAME.app"
if [ -d "$FINAL_APP" ]; then rm -rf "$FINAL_APP"; fi
/usr/bin/ditto "$STAGED_APP" "$FINAL_APP"

PACKAGE_DIR="$BUILD_DIR/ONLYOFFICE兼容打开安装包"
mkdir -p "$PACKAGE_DIR"
if [ -d "$PACKAGE_DIR/$APP_NAME.app" ]; then rm -rf "$PACKAGE_DIR/$APP_NAME.app"; fi
/usr/bin/ditto "$FINAL_APP" "$PACKAGE_DIR/$APP_NAME.app"
cp "$PROJECT_ROOT/安装与使用说明.txt" "$PACKAGE_DIR/安装与使用说明.txt"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-$LABEL.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ZIP_PATH"
/usr/bin/unzip -tqq "$ZIP_PATH"
echo "Built: $FINAL_APP"
echo "Package: $ZIP_PATH"

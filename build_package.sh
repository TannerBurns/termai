#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TermAI"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/$APP_NAME.app"
ZIP_PATH="$ROOT/$APP_NAME.zip"
ICON_PNG="$ROOT/termai.png"
ICON_ICNS="$ROOT/Icons/TermAI.icns"               # legacy fallback
DOCK_ICNS="$ROOT/Icons/termAIDock.icns"          # preferred app/dock icon
TOOLBAR_ICNS="$ROOT/Icons/termAIToolbar.icns"    # preferred toolbar/status icon
ICONSET_DIR="$ROOT/Icon.iconset"
ICNS_GEN="$ROOT/$APP_NAME.icns"
VERSION_FILE="$ROOT/.build_version"

# Optional signing/notarization env vars
: "${DEVELOPER_ID:=}"   # e.g., Developer ID Application: Your Name (TEAMID)
: "${APPLE_ID:=}"       # e.g., your-apple-id@example.com
: "${TEAM_ID:=}"        # e.g., ABCDE12345
: "${APP_PASSWORD:=}"   # App-specific password or @keychain-profile

step() { echo; echo "[$1] $2"; }

# CalVer versioning: YYYY.MM.DD for version, build number for same-day builds
generate_version() {
    local today
    today=$(date +%Y.%m.%d)
    local build_date
    build_date=$(date +%Y%m%d)
    local build_time
    build_time=$(date +%H%M%S)
    
    # Read previous version info if exists
    local prev_date=""
    local prev_build=0
    if [[ -f "$VERSION_FILE" ]]; then
        prev_date=$(head -1 "$VERSION_FILE" 2>/dev/null || echo "")
        prev_build=$(tail -1 "$VERSION_FILE" 2>/dev/null || echo "0")
    fi
    
    # Determine build number
    local build_num
    if [[ "$prev_date" == "$build_date" ]]; then
        # Same day: increment build number
        build_num=$((prev_build + 1))
    else
        # New day: reset build number
        build_num=1
    fi
    
    # Save version info for next build
    echo "$build_date" > "$VERSION_FILE"
    echo "$build_num" >> "$VERSION_FILE"
    
    # Export version strings
    # CFBundleShortVersionString: YYYY.MM.DD (user-facing version)
    VERSION_STRING="$today"
    # CFBundleVersion: YYYYMMDD.BUILD (build identifier, unique per build)
    BUILD_STRING="${build_date}.${build_num}"
    
    echo "Version: $VERSION_STRING (Build $BUILD_STRING)"
}

generate_version

step 1 "Building Release…"
swift build -c release

step 2 "Preparing icons…"
ICNS_SRC=""     # final chosen app/dock icon to embed
TBAR_SRC=""     # final chosen toolbar icon to embed
rm -f "$ICNS_GEN"; rm -rf "$ICONSET_DIR"
if [[ -f "$DOCK_ICNS" ]]; then
  echo "Using Dock icon: Icons/termAIDock.icns"
  ICNS_SRC="$DOCK_ICNS"
elif [[ -f "$ICON_ICNS" ]]; then
  echo "Using legacy app icon: Icons/TermAI.icns"
  ICNS_SRC="$ICON_ICNS"
elif [[ -f "$ICON_PNG" ]]; then
  echo "Generating icns from termai.png (fallback)"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null 2>&1 || true
  iconutil -c icns "$ICONSET_DIR" -o "$ICNS_GEN"
  ICNS_SRC="$ICNS_GEN"
else
  echo "No icon found; using default system app icon."
fi

# Toolbar icon source: prefer dedicated, otherwise reuse chosen app icon
if [[ -f "$TOOLBAR_ICNS" ]]; then
  TBAR_SRC="$TOOLBAR_ICNS"
else
  TBAR_SRC="$ICNS_SRC"
fi

step 3 "Creating app bundle…"
rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>TermAI</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.terminai</string>
  <key>CFBundleExecutable</key>
  <string>TermAI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION_STRING}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_STRING}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>termAIDock</string>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Copy SPM resource bundle to Contents/Resources/
# Our safe ResourceBundle accessor finds it there (avoiding SPM's fatalError-prone Bundle.module)
RESOURCE_BUNDLE="$BUILD_DIR/TermAI_TermAI.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  echo "Copying resource bundle…"
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
else
  echo "Warning: Resource bundle not found at $RESOURCE_BUNDLE"
fi
if [[ -n "$ICNS_SRC" && -f "$ICNS_SRC" ]]; then
  cp "$ICNS_SRC" "$APP_DIR/Contents/Resources/termAIDock.icns"
fi
if [[ -n "$TBAR_SRC" && -f "$TBAR_SRC" ]]; then
  cp "$TBAR_SRC" "$APP_DIR/Contents/Resources/termAIToolbar.icns"
fi

# Copy PNG files needed for programmatic icon generation
if [[ -f "$ROOT/Icons/termAIDock.png" ]]; then
  cp "$ROOT/Icons/termAIDock.png" "$APP_DIR/Contents/Resources/termAIDock.png"
fi
if [[ -f "$ROOT/Icons/termAIToolbar.png" ]]; then
  cp "$ROOT/Icons/termAIToolbar.png" "$APP_DIR/Contents/Resources/termAIToolbar.png"
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  step 4 "Signing with Developer ID…"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_DIR"
else
  step 4 "Ad-hoc signing (DEVELOPER_ID not set)…"
  codesign --force --deep --sign - "$APP_DIR" || true
fi

step 5 "Creating distributable zip…"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
echo "Created: $ZIP_PATH"

if [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$APP_PASSWORD" ]]; then
  step 6 "Submitting for notarization… (this may take a few minutes)"
  xcrun notarytool submit "$ZIP_PATH" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
  step 7 "Stapling ticket to app…"
  xcrun stapler staple "$APP_DIR"
  step 8 "Creating notarized zip…"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT/${APP_NAME}_notarized.zip"
  echo "Created: $ROOT/${APP_NAME}_notarized.zip"
else
  echo "Notarization skipped (set APPLE_ID, TEAM_ID, APP_PASSWORD to enable)."
fi

echo "Done. App: $APP_DIR"
echo "Zip:  $ZIP_PATH"



#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BRIDGE_BUILD_DIR:-$PROJECT_ROOT/.build}"
DIST_ROOT="${BRIDGE_DIST_DIR:-$PROJECT_ROOT/dist}"
mkdir -p "$BUILD_ROOT" "$DIST_ROOT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_ROOT/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_ROOT/manifest-cache}"
COMMON=(--package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT" --build-system native --cache-path "$BUILD_ROOT/package-cache")
if [[ "${BRIDGE_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then COMMON+=(--disable-sandbox); fi
swift build "${COMMON[@]}" -c release --product WithingsLocalBridge
swift build "${COMMON[@]}" -c release --product withings-bridge
BINARY_ROOT="$(swift build "${COMMON[@]}" -c release --show-bin-path)"
APP="$DIST_ROOT/Withings Health Bridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_ROOT/WithingsLocalBridge" "$APP/Contents/MacOS/WithingsLocalBridge"
cp "$BINARY_ROOT/withings-bridge" "$DIST_ROOT/withings-bridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.withingshealthbridge.Mac</string>
<key>CFBundleName</key><string>Withings Health Bridge</string>
<key>CFBundleExecutable</key><string>WithingsLocalBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.withingshealthbridge.snapshot</string>
<key>UTTypeDescription</key><string>Withings Health Bridge snapshot</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>whealth</string></array></dict>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print "Built $APP"

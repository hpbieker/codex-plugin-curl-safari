#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
BIN_DIR="$ROOT_DIR/bin"
APP_DIR="$ROOT_DIR/CurlSafariServer.app"
SERVER_EXE="$APP_DIR/Contents/MacOS/curl-safari-server"

mkdir -p "$BUILD_DIR/module-cache" "$BIN_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/Sources/CurlSafariServer.swift" \
  -o "$SERVER_EXE"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build bin/curl-safari" >&2
  echo "Install Go, then rerun ./build.sh" >&2
  exit 1
fi

go build -o "$BIN_DIR/curl-safari" "$ROOT_DIR/cmd/curl-safari"
chmod +x "$SERVER_EXE" "$BIN_DIR/curl-safari"


cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>curl-safari-server</string>
  <key>CFBundleIdentifier</key>
  <string>no.hpbieker.CurlSafariServer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Curl Safari Server</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built:"
echo "  $APP_DIR"
echo "  $BIN_DIR/curl-safari"

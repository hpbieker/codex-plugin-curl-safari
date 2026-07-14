#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$ROOT_DIR/bin"
APP_DIR="$ROOT_DIR/CurlSafariServer.app"

xcodebuild \
  -project "$ROOT_DIR/CurlSafariServer.xcodeproj" \
  -scheme CurlSafariServer \
  -configuration Release \
  -derivedDataPath "$ROOT_DIR/.build/xcode" \
  -destination 'platform=macOS' \
  build

mkdir -p "$BIN_DIR"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build bin/curl-safari" >&2
  echo "Install Go, then rerun ./build.sh" >&2
  exit 1
fi

go build -o "$BIN_DIR/curl-safari" "$ROOT_DIR/cmd/curl-safari"

echo "Built:"
echo "  $APP_DIR"
echo "  $BIN_DIR/curl-safari"

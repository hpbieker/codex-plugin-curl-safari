#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$ROOT_DIR/bin"
APP_DIR="$ROOT_DIR/CurlSafariServer.app"
SIGNING_TEAM_FILE="$ROOT_DIR/.signing-team"

SIGNING_ARGS=()
if [[ -f "$SIGNING_TEAM_FILE" ]]; then
  IFS= read -r DEVELOPMENT_TEAM_ID < "$SIGNING_TEAM_FILE"
  if [[ ! "$DEVELOPMENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: .signing-team must contain a 10-character Apple development team ID" >&2
    exit 1
  fi
  SIGNING_ARGS+=(
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM_ID"
    "CODE_SIGN_STYLE=Automatic"
    "CODE_SIGN_IDENTITY=Apple Development"
  )
  echo "Building with Apple Development team $DEVELOPMENT_TEAM_ID"
else
  SIGNING_ARGS+=(
    "DEVELOPMENT_TEAM="
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=-"
  )
  echo "Building with ad hoc signing (.signing-team not found)"
fi

xcodebuild \
  -project "$ROOT_DIR/CurlSafariServer.xcodeproj" \
  -scheme CurlSafariServer \
  -configuration Release \
  -derivedDataPath "$ROOT_DIR/.build/xcode" \
  -destination 'platform=macOS' \
  "${SIGNING_ARGS[@]}" \
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

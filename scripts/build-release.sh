#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/build-release.sh VERSION}"
BUILD_DIR="$ROOT_DIR/.build/release"
PRODUCTS_DIR="$BUILD_DIR/products"
STAGE_DIR="$BUILD_DIR/stage/curl-safari"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: invalid release version: $VERSION" >&2
  exit 1
fi

PLUGIN_VERSION="$(plutil -extract version raw "$ROOT_DIR/.codex-plugin/plugin.json")"
if [[ "${PLUGIN_VERSION%%+*}" != "$VERSION" ]]; then
  echo "error: plugin version $PLUGIN_VERSION does not match release $VERSION" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$PRODUCTS_DIR" "$STAGE_DIR/bin"

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/CurlSafariServer.xcodeproj" \
  -scheme CurlSafariServer \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived-data" \
  -destination 'generic/platform=macOS' \
  "CONFIGURATION_BUILD_DIR=$PRODUCTS_DIR" \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

for architecture in arm64 amd64; do
  GOOS=darwin GOARCH="$architecture" CGO_ENABLED=0 \
    go build -trimpath \
      -ldflags="-s -w" \
      -o "$BUILD_DIR/curl-safari-$architecture" \
      "$ROOT_DIR/cmd/curl-safari"
done

lipo -create \
  "$BUILD_DIR/curl-safari-arm64" \
  "$BUILD_DIR/curl-safari-amd64" \
  -output "$STAGE_DIR/bin/curl-safari"
chmod 0755 "$STAGE_DIR/bin/curl-safari"

ditto "$PRODUCTS_DIR/CurlSafariServer.app" "$STAGE_DIR/CurlSafariServer.app"
ditto "$ROOT_DIR/.codex-plugin" "$STAGE_DIR/.codex-plugin"
ditto "$ROOT_DIR/skills" "$STAGE_DIR/skills"
ditto "$ROOT_DIR/assets" "$STAGE_DIR/assets"
cp "$ROOT_DIR/README.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$STAGE_DIR/"

"$ROOT_DIR/scripts/verify-release.sh" "$STAGE_DIR" unsigned

echo "Built Codex plugin staging directory:"
echo "  $STAGE_DIR"

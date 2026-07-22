#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="${1:-$ROOT_DIR/.build/release/stage/curl-safari}"
IDENTITY="${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required}"

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$STAGE_DIR/bin/curl-safari"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" \
  "$STAGE_DIR/CurlSafariServer.app"

NOTARY_ARCHIVE="$ROOT_DIR/.build/release/notarization.zip"
ditto -c -k --norsrc --keepParent "$STAGE_DIR" "$NOTARY_ARCHIVE"

xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --apple-id "${APPLE_ID:?APPLE_ID is required}" \
  --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}" \
  --password "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}" \
  --wait

xcrun stapler staple "$STAGE_DIR/CurlSafariServer.app"
"$ROOT_DIR/scripts/verify-release.sh" "$STAGE_DIR" distribution

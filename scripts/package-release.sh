#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/package-release.sh VERSION}"
STAGE_DIR="$ROOT_DIR/.build/release/stage/curl-safari"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE="$DIST_DIR/curl-safari-$VERSION-macos-universal.zip"

if [[ ! -d "$STAGE_DIR" ]]; then
  echo "error: release staging directory is missing; run build-release.sh first" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE" "$DIST_DIR/SHA256SUMS.txt"
ditto -c -k --norsrc --keepParent "$STAGE_DIR" "$ARCHIVE"

(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt
)

echo "Packaged Codex plugin release:"
echo "  $ARCHIVE"
echo "  $DIST_DIR/SHA256SUMS.txt"

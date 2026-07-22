#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="${1:?usage: scripts/verify-release.sh PLUGIN_DIR [adhoc|development|distribution]}"
SIGNING_MODE="${2:-adhoc}"

required_paths=(
  ".codex-plugin/plugin.json"
  "skills/curl-safari/SKILL.md"
  "skills/curl-safari/agents/openai.yaml"
  "assets/curl-symbol.svg"
  "assets/curl-white-symbol.svg"
  "bin/curl-safari"
  "CurlSafariServer.app/Contents/MacOS/curl-safari-server"
  "README.md"
  "LICENSE"
  "THIRD_PARTY_NOTICES.md"
)

for relative_path in "${required_paths[@]}"; do
  if [[ ! -e "$PLUGIN_DIR/$relative_path" ]]; then
    echo "error: release is missing $relative_path" >&2
    exit 1
  fi
done

plugin_name="$(plutil -extract name raw "$PLUGIN_DIR/.codex-plugin/plugin.json")"
plugin_skills="$(plutil -extract skills raw "$PLUGIN_DIR/.codex-plugin/plugin.json")"
[[ "$plugin_name" == curl-safari ]] || {
  echo "error: unexpected plugin name: $plugin_name" >&2
  exit 1
}
[[ "$plugin_skills" == ./skills/ ]] || {
  echo "error: unexpected skills path: $plugin_skills" >&2
  exit 1
}
grep -q '^name: curl-safari$' "$PLUGIN_DIR/skills/curl-safari/SKILL.md"
grep -q '^interface:$' "$PLUGIN_DIR/skills/curl-safari/agents/openai.yaml"

for binary in \
  "$PLUGIN_DIR/bin/curl-safari" \
  "$PLUGIN_DIR/CurlSafariServer.app/Contents/MacOS/curl-safari-server"; do
  architectures="$(lipo -archs "$binary")"
  [[ " $architectures " == *" arm64 "* ]] || {
    echo "error: $binary does not contain arm64" >&2
    exit 1
  }
  [[ " $architectures " == *" x86_64 "* ]] || {
    echo "error: $binary does not contain x86_64" >&2
    exit 1
  }
done

"$PLUGIN_DIR/bin/curl-safari" --version >/dev/null

if [[ "$SIGNING_MODE" == development ]]; then
  codesign --verify --deep --strict --verbose=2 "$PLUGIN_DIR/CurlSafariServer.app"
  expected_team="$(sed -n '1p' "$(cd "$(dirname "$0")/.." && pwd)/.signing-team")"
  actual_team="$(codesign -dv --verbose=4 "$PLUGIN_DIR/CurlSafariServer.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$actual_team" == "$expected_team" ]] || {
    echo "error: app team $actual_team does not match .signing-team $expected_team" >&2
    exit 1
  }
elif [[ "$SIGNING_MODE" == distribution ]]; then
  codesign --verify --deep --strict --verbose=2 "$PLUGIN_DIR/CurlSafariServer.app"
  codesign --verify --strict --verbose=2 "$PLUGIN_DIR/bin/curl-safari"
  xcrun stapler validate "$PLUGIN_DIR/CurlSafariServer.app"
elif [[ "$SIGNING_MODE" != adhoc ]]; then
  echo "error: signing mode must be adhoc, development, or distribution" >&2
  exit 1
fi

echo "Verified $SIGNING_MODE Codex plugin release at $PLUGIN_DIR"

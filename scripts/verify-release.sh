#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="${1:?usage: scripts/verify-release.sh PLUGIN_DIR [unsigned|signed]}"
SIGNING_MODE="${2:-unsigned}"

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

if [[ "$SIGNING_MODE" == signed ]]; then
  codesign --verify --deep --strict --verbose=2 "$PLUGIN_DIR/CurlSafariServer.app"
  codesign --verify --strict --verbose=2 "$PLUGIN_DIR/bin/curl-safari"
  xcrun stapler validate "$PLUGIN_DIR/CurlSafariServer.app"
elif [[ "$SIGNING_MODE" != unsigned ]]; then
  echo "error: signing mode must be unsigned or signed" >&2
  exit 1
fi

echo "Verified $SIGNING_MODE Codex plugin release at $PLUGIN_DIR"

#!/usr/bin/env bash
# Packages a signed app as a compressed, read-only DMG that can be run in place.
# Usage: create-dmg.sh [app-path] [output-dmg]
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
app="${1:-$repo_dir/artifacts/macos-app/HAOS USB Creator.app}"
dmg="${2:-$repo_dir/artifacts/macos-app/HAOS-USB-Creator-macos-universal.dmg}"
sign_identity="${CODE_SIGN_IDENTITY:--}"

[[ -d "$app" ]] || { echo "App not found: $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"

notary_args=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  notary_args+=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [[ -n "${APPLE_ID:-}" || -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  : "${APPLE_ID:?APPLE_ID is required for notarization}"
  : "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD is required for notarization}"
  : "${TEAM_ID:?TEAM_ID is required for notarization}"
  notary_args+=(--apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID")
fi
if (( ${#notary_args[@]} > 0 )) && [[ "$sign_identity" == "-" ]]; then
  echo "CODE_SIGN_IDENTITY must be a Developer ID identity when notarizing." >&2
  exit 1
fi

mkdir -p "$(dirname "$dmg")"
dmg_dir="$(cd "$(dirname "$dmg")" && pwd)"
dmg="$dmg_dir/$(basename "$dmg")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root"

# APFS clone-copy avoids temporarily duplicating the 3.4 GB boot image.
cp -cR "$app" "$work/root/"
hdiutil create -quiet -ov \
  -srcfolder "$work/root" \
  -volname "HAOS USB Creator" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=6 \
  "$dmg"

if [[ "$sign_identity" != "-" ]]; then
  codesign --force --sign "$sign_identity" --timestamp "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi
hdiutil verify "$dmg" >/dev/null

if (( ${#notary_args[@]} > 0 )); then
  xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

echo "Built: $dmg"

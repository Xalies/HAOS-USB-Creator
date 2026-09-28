#!/usr/bin/env bash

set -euo pipefail

: "${TARGET_BUILD_DIR:?Xcode did not provide TARGET_BUILD_DIR}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode did not provide UNLOCALIZED_RESOURCES_FOLDER_PATH}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
icon_source="$repo_dir/src/WindowsApp/src/HAOSInstaller.App/Assets/InstallerIcon.png"
boot_dir="${HAOS_BOOT_IMAGE_DIR:-$repo_dir/artifacts/installer-linux}"

mkdir -p "$resources_dir"
cp "$icon_source" "$resources_dir/InstallerIcon.png"
cp "$repo_dir/src/WindowsApp/src/HAOSInstaller.App/Assets/bmc-button.png" "$resources_dir/bmc-button.png"
cp "$repo_dir/LICENSE" "$resources_dir/LICENSE"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

icon_work="$(mktemp -d "${TMPDIR:-/tmp}/haos-icons.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$icon_source" --out "$iconset/$name" >/dev/null
done

iconutil -c icns "$iconset" -o "$resources_dir/AppIcon.icns"

boot_resources="$resources_dir/BootImage"
rm -rf "$boot_resources"

image_path="$(find "$boot_dir" -maxdepth 1 -type f -name '*.img' -print -quit 2>/dev/null || true)"
checksum_path="$(find "$boot_dir" -maxdepth 1 -type f -name '*.sha256' -print -quit 2>/dev/null || true)"
manifest_path="${image_path}.manifest.json"
if [[ ! -f "$manifest_path" ]]; then
  manifest_path="$boot_dir/manifest.json"
fi

if [[ -z "$image_path" || -z "$checksum_path" ]]; then
  if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
    echo "error: No boot image and checksum found in $boot_dir. Run ./fetch-boot-image.sh first." >&2
    exit 1
  fi
  echo "warning: No boot image found in $boot_dir; the Debug app will use its download fallback." >&2
  exit 0
fi

expected_checksum="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
actual_checksum="$(shasum -a 256 "$image_path" | awk '{ print $1 }')"
if [[ -z "$expected_checksum" || "$actual_checksum" != "$expected_checksum" ]]; then
  echo "error: Boot image checksum verification failed for $image_path" >&2
  exit 1
fi

mkdir -p "$boot_resources"
cp -c "$image_path" "$boot_resources/"
cp "$checksum_path" "$boot_resources/"
if [[ -f "$manifest_path" ]]; then
  cp "$manifest_path" "$boot_resources/"
fi

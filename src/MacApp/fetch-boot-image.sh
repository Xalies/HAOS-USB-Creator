#!/usr/bin/env bash
# Copies the prebuilt installer boot image out of a published Windows release, so the macOS app
# can be built and tested without building the Linux boot image locally (which needs Docker).
# Usage: fetch-boot-image.sh [output-dir] [release-tag]
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
out_dir="${1:-$repo_dir/artifacts/installer-linux}"
tag="${2:-latest}"
repo="${HAOS_CREATOR_REPO:-Xalies/HAOS-USB-Creator}"
asset="HAOS-USB-Creator-win-x64.zip"

if [[ "$tag" == latest ]]; then
  api="https://api.github.com/repos/$repo/releases/latest"
else
  api="https://api.github.com/repos/$repo/releases/tags/$tag"
fi
url="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api" \
  | grep -o "\"browser_download_url\": *\"[^\"]*/$asset\"" \
  | sed -E 's/.*"(https:[^"]*)"/\1/' | head -n 1)"
[[ -n "$url" ]] || { echo "No $asset found in release $tag of $repo" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "Downloading $url"
curl -fL --progress-bar "$url" -o "$work/$asset"
unzip -q -j -o "$work/$asset" '*BootImage/haos-installer-x86_64.img*' -d "$work/boot"

image="$work/boot/haos-installer-x86_64.img"
expected="$(awk 'NR == 1 { print $1 }' "$image.sha256")"
actual="$(shasum -a 256 "$image" | awk '{ print $1 }')"
[[ "$expected" == "$actual" ]] || { echo "Boot image SHA-256 mismatch" >&2; exit 1; }

mkdir -p "$out_dir"
mv "$work/boot/"* "$out_dir/"
echo "Boot image ready in $out_dir"

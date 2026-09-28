#!/usr/bin/env bash
# Builds "HAOS USB Creator.app" (universal, ad-hoc signed) and a compressed DMG.
# Usage: build-app.sh [boot-image-dir] [output-dir]
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
boot_dir="${1:-$repo_dir/artifacts/installer-linux}"
out_dir="${2:-$repo_dir/artifacts/macos-app}"
assets="$repo_dir/src/WindowsApp/src/HAOSInstaller.App/Assets"
version="${VERSION:-0.0.0}"
version="${version#v}"
sign_identity="${CODE_SIGN_IDENTITY:--}"
image="$boot_dir/haos-installer-x86_64.img"
checksum="$image.sha256"

if [[ -s "$image" && -s "$checksum" ]]; then
  expected="$(awk 'NR == 1 { print $1 }' "$checksum")"
  actual="$(shasum -a 256 "$image" | awk '{ print $1 }')"
  [[ "$expected" == "$actual" ]] || { echo "Boot image SHA-256 mismatch" >&2; exit 1; }
  bundle_boot_image=1
else
  echo "warning: no boot image in $boot_dir; the app will look in" >&2
  echo "         ~/Library/Application Support/HAOS-USB-Creator/BootImages instead" >&2
  echo "         (see fetch-boot-image.sh)." >&2
  bundle_boot_image=0
fi

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# One build per architecture, then lipo. A multi-arch `swift build` needs a full Xcode install.
for arch in arm64 x86_64; do
  swift build --package-path "$script_dir" -c release --arch "$arch"
  bin="$(swift build --package-path "$script_dir" -c release --arch "$arch" --show-bin-path)"
  mkdir -p "$work/$arch"
  cp "$bin/HAOSUSBCreator" "$bin/HAOSUSBWriter" "$work/$arch/"
done

app="$out_dir/HAOS USB Creator.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for tool in HAOSUSBCreator HAOSUSBWriter; do
  lipo -create "$work/arm64/$tool" "$work/x86_64/$tool" -output "$app/Contents/MacOS/$tool"
done

cp "$assets/InstallerIcon.png" "$assets/bmc-button.png" "$app/Contents/Resources/"
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"
if [[ "$bundle_boot_image" == 1 ]]; then
  mkdir -p "$app/Contents/Resources/BootImage"
  cp "$image" "$checksum" "$app/Contents/Resources/BootImage/"
  if [[ -f "$image.manifest.json" ]]; then
    cp "$image.manifest.json" "$app/Contents/Resources/BootImage/"
  fi
fi

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$assets/InstallerIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$assets/InstallerIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>HAOS AIO USB Creator</string>
  <key>CFBundleExecutable</key><string>HAOSUSBCreator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.xalies.haos-usb-creator</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>HAOS USB Creator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign the helper first, then the bundle around it. Developer ID builds use the hardened runtime
# and Apple's trusted timestamp; CI and local builds remain ad-hoc signed by default.
sign_options=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  sign_options+=(--options runtime --timestamp)
fi
codesign "${sign_options[@]}" "$app/Contents/MacOS/HAOSUSBWriter"
codesign "${sign_options[@]}" "$app"

CODE_SIGN_IDENTITY="$sign_identity" "$script_dir/create-dmg.sh" \
  "$app" "$out_dir/HAOS-USB-Creator-macos.dmg"
echo "Built: $app"

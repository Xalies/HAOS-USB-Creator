#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
boot_dir="${1:-$repo_dir/artifacts/installer-linux}"
out_dir="${2:-$repo_dir/artifacts/linux-app}"
image="$boot_dir/haos-installer-x86_64.img"
checksum="$image.sha256"

test -s "$image"
test -s "$checksum"
expected="$(awk 'NR == 1 { print $1 }' "$checksum")"
actual="$(sha256sum "$image" | awk '{ print $1 }')"
test "$expected" = "$actual" || { echo "Boot image SHA-256 mismatch" >&2; exit 1; }

for tool in python3 lsblk sgdisk partx udevadm mount umount sync curl; do
  command -v "$tool" >/dev/null || { echo "Build tool missing: $tool" >&2; exit 1; }
done

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 -m venv --system-site-packages "$work/venv"
"$work/venv/bin/pip" install --disable-pip-version-check --quiet pyinstaller==6.22.3

tools=()
for tool in lsblk sgdisk partx udevadm mount umount sync; do
  tools+=(--add-binary "$(command -v "$tool"):tools")
done
"$work/venv/bin/pyinstaller" --noconfirm --onedir --name haos-usb-creator \
  --distpath "$work/dist" --workpath "$work/build" --specpath "$work" \
  --add-data "$repo_dir/src/WindowsApp/src/HAOSInstaller.App/Assets/bmc-button.png:assets" \
  "${tools[@]}" "$script_dir/main.py"

appdir="$work/HAOS-USB-Creator.AppDir"
mkdir -p "$appdir/usr/bin" "$appdir/boot-image"
mkdir -p "$appdir/usr/share/doc/haos-usb-creator"
cp -a "$work/dist/haos-usb-creator" "$appdir/usr/bin/"
cp "$script_dir/AppRun" "$script_dir/haos-usb-creator.desktop" "$appdir/"
cp "$repo_dir/src/WindowsApp/src/HAOSInstaller.App/Assets/InstallerIcon.png" "$appdir/haos-usb-creator.png"
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_NOTICES.md" "$appdir/usr/share/doc/haos-usb-creator/"
cp --reflink=auto "$image" "$checksum" "$appdir/boot-image/"
chmod +x "$appdir/AppRun"

curl -fsSL https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  -o "$work/appimagetool.AppImage"
echo 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0  '"$work/appimagetool.AppImage" | sha256sum -c -
curl -fsSL https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
  -o "$work/runtime-x86_64"
echo '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d  '"$work/runtime-x86_64" | sha256sum -c -
chmod +x "$work/appimagetool.AppImage"

output="$out_dir/HAOS-USB-Creator-linux-x86_64.AppImage"
ARCH=x86_64 "$work/appimagetool.AppImage" --appimage-extract-and-run \
  --runtime-file "$work/runtime-x86_64" "$appdir" "$output"
chmod +x "$output"
echo "Built: $output"

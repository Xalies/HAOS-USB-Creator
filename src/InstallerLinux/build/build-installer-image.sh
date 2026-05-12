#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${1:-./artifacts/installer-linux}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="haos-installer-image-builder"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_BRANCH="${ALPINE_BRANCH:-3.20-stable}"
IMAGE_SIZE_MIB="${IMAGE_SIZE_MIB:-2688}"

mkdir -p "$OUTDIR"
OUTDIR_ABS="$(cd "$OUTDIR" && pwd)"

echo "======================================================"
echo " HAOS AIO USB Creator boot image builder"
echo " Alpine base: $ALPINE_VERSION"
echo " Output dir:  $OUTDIR_ABS"
echo " Size:        ${IMAGE_SIZE_MIB} MiB"
echo "======================================================"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/rootfs/usr/local/bin/haos-installer"
mkdir -p "$tmpdir/rootfs/etc/profile.d"
mkdir -p "$tmpdir/rootfs/etc/network"
mkdir -p "$tmpdir/mkimage-profile"

cp -R "$INSTALLER_DIR/rootfs/." "$tmpdir/rootfs/"
cp "$INSTALLER_DIR"/scripts/*.sh "$tmpdir/rootfs/usr/local/bin/haos-installer/"
cp "$SCRIPT_DIR/mkimg.haos_installer.sh" "$tmpdir/mkimage-profile/mkimg.haos_installer.sh"

build_id="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$tmpdir/rootfs/etc/haos-installer-build" <<BUILDINFO
buildTimeUtc=$build_id
builder=build-installer-image.sh
networkProfile=broad-wired-network-support
BUILDINFO

cat > "$tmpdir/rootfs/usr/local/bin/haos-installer-run" <<'RUNNER'
#!/bin/sh
set -eu
PATH="/usr/sbin:/sbin:$PATH"
exec /usr/local/bin/haos-installer/installer.sh "$@"
RUNNER

chmod +x "$tmpdir/rootfs/usr/local/bin/haos-installer-run"
chmod +x "$tmpdir/rootfs/usr/local/bin/haos-installer/"*.sh

cat > "$tmpdir/build-usb-image.sh" <<'BUILDER'
#!/bin/sh
set -eu

BOOT_LABEL="${BOOT_LABEL:-HAOSINSTLR}"
CACHE_LABEL="${CACHE_LABEL:-HAOS-CACHE}"
IMAGE_SIZE_MIB="${IMAGE_SIZE_MIB:-2688}"
BOOT_START_SECTOR=2048
BOOT_SECTORS=1835008
CACHE_START_SECTOR=1839104
CACHE_SECTORS=3665887

mkdir -p /iso-out /work/extract

cd /aports/scripts
sh mkimage.sh \
  --profile haos_installer \
  --outdir /iso-out \
  --arch x86_64 \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community"

iso_path="$(find /iso-out -maxdepth 1 -name '*.iso' | head -n 1)"
if [ -z "$iso_path" ]; then
  echo "ERROR: Alpine image builder did not produce a boot source." >&2
  exit 1
fi

iso_output="/out/haos-installer-x86_64.iso"
rm -f "$iso_output" "${iso_output}.sha256" "${iso_output}.manifest.json"
cp "$iso_path" "$iso_output"
sha256sum "$iso_output" > "${iso_output}.sha256"

iso_sha256="$(sha256sum "$iso_output" | awk '{ print $1 }')"
iso_size_bytes="$(wc -c < "$iso_output" | tr -d ' ')"
iso_built_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  printf '%s\n' '{'
  printf '%s\n' '  "schemaVersion": 1,'
  printf '%s\n' '  "artifactType": "haos_installer_iso",'
  printf '%s\n' '  "format": "bootable-iso-image",'
  printf '%s\n' '  "filename": "haos-installer-x86_64.iso",'
  printf '%s\n' "  \"sha256\": \"$iso_sha256\","
  printf '%s\n' "  \"fileSizeBytes\": $iso_size_bytes,"
  printf '%s\n' "  \"builtAtUtc\": \"$iso_built_at\","
  printf '%s\n' '  "builder": "src/InstallerLinux/build/build-installer-image.sh",'
  printf '%s\n' '  "notes": "Standalone bootable installer ISO. Intended for VMs or optical-style boot media; it does not include the writable HAOS-CACHE USB partition."'
  printf '%s\n' '}'
} > "${iso_output}.manifest.json"

xorriso -osirrox on -indev "$iso_path" -extract / /work/extract >/dev/null
touch /work/extract/.boot_repository

cat > /work/extract/boot/grub/grub.cfg <<GRUBCFG
set timeout=3

menuentry "HAOS AIO Installer USB" {
linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,uas,ahci,nvme,virtio_blk,virtio_pci,virtio_net,e1000,e1000e,igb,igc,ixgbe,i40e,ice,r8169,atlantic,alx,tg3,bnx2,bnx2x,qede,mlx4_en,mlx5_core,be2net,enic,sky2,skge,forcedeth,via-rhine,via-velocity,tulip,pcnet32,8139too,8139cp,sis900,natsemi,vmxnet3,r8152,asix,ax88179_178a,cdc_ether,smsc95xx,dm9601,mcs7830 alpine_dev=LABEL=$BOOT_LABEL console=tty1
initrd /boot/initramfs-lts
}
GRUBCFG

image_path="/out/haos-installer-x86_64.img"
rm -f "$image_path" "${image_path}.sha256" "${image_path}.manifest.json"
truncate -s "${IMAGE_SIZE_MIB}M" "$image_path"

cat > /work/layout.sfdisk <<LAYOUT
label: gpt
unit: sectors

start=${BOOT_START_SECTOR}, size=${BOOT_SECTORS}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="HAOS AIO USB"
start=${CACHE_START_SECTOR}, size=${CACHE_SECTORS}, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, attrs="63", name="HAOS Cache"
LAYOUT

sfdisk "$image_path" < /work/layout.sfdisk >/dev/null

boot_fat="/work/boot.fat"
cache_fat="/work/cache.fat"
truncate -s "$((BOOT_SECTORS * 512))" "$boot_fat"
truncate -s "$((CACHE_SECTORS * 512))" "$cache_fat"

mformat -i "$boot_fat" -F -v "$BOOT_LABEL" ::
mcopy -i "$boot_fat" -s /work/extract/* ::

mformat -i "$cache_fat" -F -v "$CACHE_LABEL" ::
mmd -i "$cache_fat" ::/cache ::/logs

dd if="$boot_fat" of="$image_path" bs=512 seek="$BOOT_START_SECTOR" conv=notrunc status=none
dd if="$cache_fat" of="$image_path" bs=512 seek="$CACHE_START_SECTOR" conv=notrunc status=none

sha256sum "$image_path" > "${image_path}.sha256"

sha256="$(sha256sum "$image_path" | awk '{ print $1 }')"
size_bytes="$(wc -c < "$image_path" | tr -d ' ')"
built_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  printf '%s\n' '{'
  printf '%s\n' '  "schemaVersion": 1,'
  printf '%s\n' '  "artifactType": "haos_installer_boot",'
  printf '%s\n' '  "format": "raw-usb-image",'
  printf '%s\n' '  "filename": "haos-installer-x86_64.img",'
  printf '%s\n' "  \"sha256\": \"$sha256\","
  printf '%s\n' "  \"fileSizeBytes\": $size_bytes,"
  printf '%s\n' "  \"builtAtUtc\": \"$built_at\","
  printf '%s\n' '  "builder": "src/InstallerLinux/build/build-installer-image.sh",'
  printf '%s\n' '  "layout": {'
  printf '%s\n' '    "partitionTable": "gpt",'
  printf '%s\n' "    \"bootPartition\": \"FAT32 ESP, label $BOOT_LABEL, GPT name HAOS AIO USB\","
  printf '%s\n' "    \"cachePartition\": \"FAT32 data, label $CACHE_LABEL, GPT name HAOS Cache, no default Windows drive letter\""
  printf '%s\n' '  }'
  printf '%s\n' '}'
} > "${image_path}.manifest.json"
BUILDER

cat > "$tmpdir/Dockerfile" <<DOCKERFILE
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \\
    alpine-sdk \\
    alpine-conf \\
    apk-tools \\
    bash \\
    squashfs-tools \\
    xorriso \\
    grub \\
    grub-efi \\
    mtools \\
    dosfstools \\
    git \\
    curl \\
    xz \\
    syslinux \\
    abuild \\
    sudo \\
    coreutils \\
    util-linux

ARG ALPINE_BRANCH=${ALPINE_BRANCH}
ARG ALPINE_VERSION=${ALPINE_VERSION}
ENV ALPINE_VERSION=\${ALPINE_VERSION}

RUN git clone --depth 1 --branch \${ALPINE_BRANCH} \\
    https://gitlab.alpinelinux.org/alpine/aports.git /aports

COPY rootfs/ /haos-overlay/
COPY mkimage-profile/mkimg.haos_installer.sh /aports/scripts/mkimg.haos_installer.sh
COPY build-usb-image.sh /usr/local/bin/build-usb-image

RUN chmod +x /usr/local/bin/build-usb-image \\
 && chmod +x /haos-overlay/usr/local/bin/haos-installer-run \\
 && chmod +x /haos-overlay/usr/local/bin/haos-installer-autostart \\
 && chmod +x /haos-overlay/usr/local/bin/haos-installer/*.sh

RUN SUDO= sudo abuild-keygen -a -i -n

RUN cat > /aports/scripts/haos-installer.apkovl.sh <<'APKOVL' && \\
    chmod +x /aports/scripts/haos-installer.apkovl.sh
#!/bin/sh
set -eu
hostname="\${1:-haos-installer}"
tar -C /haos-overlay -czf "\${hostname}.apkovl.tar.gz" .
APKOVL

CMD ["/usr/local/bin/build-usb-image"]
DOCKERFILE

echo "[1/2] Building Docker USB image builder..."
docker build --tag "$IMAGE_NAME:latest" --progress=plain "$tmpdir"

echo "[2/2] Building raw USB image..."
docker run --rm \
  -v "${OUTDIR_ABS}:/out" \
  -e IMAGE_SIZE_MIB="$IMAGE_SIZE_MIB" \
  "$IMAGE_NAME:latest"

image_path="$OUTDIR_ABS/haos-installer-x86_64.img"
echo "Built: $image_path"
echo "Checksum: $image_path.sha256"
echo "Manifest: $image_path.manifest.json"

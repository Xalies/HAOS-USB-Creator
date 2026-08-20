# HAOS AIO Installer USB Linux Environment

This folder contains the Alpine-based Linux installer environment that boots from the USB created by the Windows app.

The Linux environment writes the official Home Assistant OS generic x86-64 image to the selected internal disk. It does not install a Linux desktop, does not install Home Assistant Supervised, and does not preserve data on the selected target disk.

## Build Entry Point

The release build uses:

```sh
src/InstallerLinux/build/build-installer-image.sh
```

That script builds a raw USB boot image containing:

- A FAT32 EFI boot partition with the Alpine-based installer environment.
- A FAT32 `HAOS-CACHE` partition for the downloaded Home Assistant OS image, installer config, and logs.

## Runtime Dependencies

The boot image is expected to include:

- `whiptail` through Alpine `newt`
- `curl`
- `jq`
- `xz`
- `coreutils`
- `util-linux`
- `lsblk`
- `blkid`
- `findmnt`
- `mount`
- `mountpoint`
- `wipefs`
- `dd`
- `sync`
- `sha256sum`
- `pv`
- `sgdisk` through `gptfdisk`
- `efibootmgr`
- `sshd` through `openssh-server`

## Boot Entry Point

The boot image starts this wrapper on `tty1`:

```sh
/usr/local/bin/haos-installer-autostart
```

That wrapper launches:

```sh
/usr/local/bin/haos-installer/installer.sh
```

`tty2` remains available as a debug shell during development.

## Installer Flow

The installer:

1. Checks runtime dependencies.
2. Checks UEFI and Secure Boot state where possible.
3. Finds and mounts the `HAOS-CACHE` partition.
4. Starts SSH if enabled by the USB creator.
5. Checks for a downloaded Home Assistant OS image.
6. Checks online for the latest generic x86-64 Home Assistant OS image.
7. Downloads and verifies a newer image when appropriate.
8. Falls back to the verified downloaded image when online lookup or download fails.
9. Detects eligible internal install disks.
10. Excludes the USB installer disk.
11. Lets the user choose a target disk in attended mode, or uses the only eligible disk in unattended mode.
12. Wipes the selected target disk.
13. Writes the Home Assistant OS image with progress.
14. Syncs, rereads the partition table, and asks the user to reboot.

## Script Roles

- `scripts/installer.sh`: main flow.
- `scripts/tui.sh`: installer-style UI helpers with terminal fallback.
- `scripts/logging.sh`: log helpers.
- `scripts/uefi.sh`: UEFI, Secure Boot, and install loop protection helpers.
- `scripts/image-cache.sh`: cache partition discovery and downloaded image verification.
- `scripts/haos-release.sh`: online release lookup, download, and verification.
- `scripts/image-select.sh`: image selection policy.
- `scripts/ssh.sh`: optional SSH access for headless installs.
- `scripts/disk-detect.sh`: target disk discovery.
- `scripts/target-select.sh`: attended and unattended target selection.
- `scripts/write-image.sh`: destructive write path.

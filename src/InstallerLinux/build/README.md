# Boot Image Build

This folder contains developer/release tooling for building the Alpine-based HAOS AIO Installer USB Linux environment. The default build uses Alpine Linux 3.24 stable.

The primary product output is a HAOS AIO raw USB image. The build also keeps the generated bootable ISO as a secondary release file for VM, Ventoy, and optical-style boot use.

End users should not run this builder. The Windows app should ship with the HAOS AIO boot image already bundled under `Assets/BootImage`.

The build output is a bootable HAOS AIO boot image. It is not the Home Assistant OS generic x86-64 payload image. The HAOS payload is cached separately on the USB data partition and written later by the Linux installer to the selected internal disk.

## Requirements

- Docker
- Internet access from Docker

## Build

Check prerequisites:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\InstallerLinux\build\test-build-prereqs.ps1
```

Build the raw USB image from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\InstallerLinux\build\build-installer-image.ps1 -OutDir .\artifacts\installer-linux
```

From WSL/Git Bash:

```sh
./src/InstallerLinux/build/build-installer-image.sh ./artifacts/installer-linux
```

Raw USB image output:

- `haos-installer-x86_64.img`
- matching `.sha256`
- matching `.manifest.json`

Standalone ISO output:

- `haos-installer-x86_64.iso`
- matching `.sha256`
- matching `.manifest.json`

The ISO boots the same Alpine installer environment, but it does not contain the writable `HAOS-CACHE` USB partition. It is intended for VMs, Ventoy disks, and optical-style boot media. It will normally download the Home Assistant OS generic x86-64 image into temporary memory-backed storage, verify it, and then write the verified image to the selected disk. Boot media discovery uses a short default wait; the raw USB boot menu also includes a slower compatibility entry for machines that need more time to enumerate the installer media.

The raw image contains a GPT layout with:

- `HAOSINSTLR`: 1.5 GiB FAT32 EFI System Partition with the Alpine installer boot files and broad firmware/network support.
- `HAOS-CACHE`: about 1.75 GiB FAT32 data partition with `cache/` and `logs/` folders. This partition is marked with the GPT no-default-drive-letter attribute so Windows should not open it in Explorer while the app is still copying files.

The raw image is intentionally about 3.375 GiB: the boot partition has room for current Alpine firmware and SSH support, while the cache partition stays large enough for the cached Home Assistant OS image and installer-side update downloads.


# Boot Image Build

This folder contains developer/release tooling for building the Alpine-based HAOS AIO Installer USB Linux environment.

The product output is a HAOS AIO raw USB image. The normal build path creates that raw image directly as the only published boot image. Alpine's image builder is still used inside Docker to assemble the bootable Linux environment, but the repository no longer needs a separate ISO build step for the normal workflow.

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

The raw image contains a GPT layout with:

- `HAOSINSTLR`: 896 MiB FAT32 EFI System Partition with the Alpine installer boot files and broad firmware/network support.
- `HAOS-CACHE`: about 1.75 GiB FAT32 data partition with `cache/` and `logs/` folders. This partition is marked with the GPT no-default-drive-letter attribute so Windows should not open it in Explorer while the app is still copying files.

The raw image is intentionally about 2.625 GiB: the boot partition is kept compact, while the cache partition stays large enough for the cached Home Assistant OS image and installer-side update downloads.


# HAOS AIO USB Creator

HAOS AIO USB Creator is an unofficial Windows tool for creating an all-in-one USB installer for Home Assistant OS on dedicated generic x86-64 PCs.

It creates a bootable USB installer, downloads the official Home Assistant OS generic x86-64 image, stores that image on the USB for offline use, and boots into a small Linux installer that writes Home Assistant OS to the selected internal disk.

This is not a normal Windows app installer. It is a disk imaging tool. It can erase drives.

Copyright (C) 2026 Sonny Gilbert.

## Status

This project is functional but still new.

The current flow supports:

- Windows USB creator app
- Removable USB drive detection
- Safety confirmation before erasing the selected USB
- Bundled Alpine-based boot image
- Automatic Home Assistant OS generic x86-64 download
- Cached Home Assistant OS image on the USB
- Linux installer with attended and unattended modes
- Online update check from the Linux installer
- Fallback to cached image when offline
- Internal disk selection and destructive write flow
- Basic install loop protection for unattended installs

## Important Safety Notes

- This tool erases the selected USB drive during creation.
- The booted Linux installer erases the selected target disk during install.
- Do not use this for dual boot.
- Do not use this to preserve existing data.
- Do not point it at a Windows disk unless you intend to erase that disk.
- Home Assistant OS generic x86-64 expects its disk image to be written directly to the target disk.
- Target systems should boot in UEFI mode with Secure Boot disabled.

## Unofficial Project

This project is not made by, endorsed by, or affiliated with Home Assistant, Nabu Casa, or the Open Home Foundation.

Home Assistant OS images are downloaded from the official Home Assistant OS release sources. Home Assistant names and marks belong to their respective owners.

## How It Works

1. Run the Windows app, it will prompt for administrator.
2. Select the USB drive to turn into an installer.
3. Confirm that the USB drive can be erased.
4. The app writes the bundled Linux boot image to the USB.
5. The app downloads the latest Home Assistant OS generic x86-64 image.
6. The app copies that image to the USB cache partition.
7. Boot the target PC from the USB.
8. The Linux installer checks the cached image and looks online for a newer verified image.
9. In attended mode, choose the internal target disk and confirm the erase warning.
10. In unattended mode, install continues only when one eligible internal disk is detected.
11. The installer writes Home Assistant OS to the target disk and reboots.

The tool includes safeguards such as image verification before use, explicit erase confirmations, and unattended install loop protection for both EFI and non-EFI fallback paths.


## Repository Layout

```text
src/InstallerLinux/           Alpine-based Linux installer environment
src/WindowsApp/               WPF USB creator app, core services, and tests
```

## Build From Source

### Requirements

For the Windows app:

- Windows 10 or newer
- .NET 8 SDK or newer
- PowerShell

For rebuilding the bundled Linux boot image:

- Docker Desktop
- Internet access from Docker
- PowerShell plus WSL or Git Bash

### Build the Windows App

From the repository root:

```powershell
dotnet build .\src\WindowsApp\HAOSInstaller.slnx -c Release -p:Platform=x64
```

Run tests:

```powershell
dotnet test .\src\WindowsApp\HAOSInstaller.slnx -c Release -p:Platform=x64
```

### Build the Linux Boot Image

The Windows app expects a boot image under:

```text
src/WindowsApp/src/HAOSInstaller.App/Assets/BootImage/
```

Large boot images should not be committed to git. Build them locally, or download them from a project release when available.

To build the boot image locally:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\InstallerLinux\build\test-build-prereqs.ps1
powershell -ExecutionPolicy Bypass -File .\src\InstallerLinux\build\build-installer-image.ps1 -OutDir .\artifacts\installer-linux
```

Copy the generated files into the app boot image folder:

```powershell
New-Item -ItemType Directory -Force .\src\WindowsApp\src\HAOSInstaller.App\Assets\BootImage
Copy-Item .\artifacts\installer-linux\haos-installer-x86_64.img* .\src\WindowsApp\src\HAOSInstaller.App\Assets\BootImage\ -Force
```

Validate the bundled boot image:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\WindowsApp\validate-bundled-boot-image.ps1
```

Then rebuild the Windows app:

```powershell
dotnet build .\src\WindowsApp\HAOSInstaller.slnx -c Release -p:Platform=x64
```

### Publish the Windows App

Example self-contained x64 publish:

```powershell
dotnet publish .\src\WindowsApp\src\HAOSInstaller.App\HAOSInstaller.App.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -o .\publish\win-x64
```

Before publishing, make sure the `Assets/BootImage` folder contains the matching `.img`, `.sha256`, and `.manifest.json` files.

## Release Guidance

Recommended release assets:

- Published Windows app zip
- Matching Linux boot image zip containing the `.img`, `.sha256`, and `.manifest.json`

Do not commit generated boot images, Home Assistant OS downloads, or publish folders to git.

## License

This project is licensed under the GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE).

Third-party components and downloaded images remain under their own upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

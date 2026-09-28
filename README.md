# HAOS AIO USB Creator

HAOS AIO USB Creator is an unofficial Windows, Linux and macOS tool for creating a bootable all-in-one installer USB for **Home Assistant OS on a dedicated generic x86-64 PC**.

It is meant for dedicated x86-64 machines.

## What It Does

The Windows, Linux and macOS desktop apps:

- detects removable USB drives
- helps you choose the USB drive to turn into an installer
- warns before erasing the USB drive
- downloads the official Home Assistant OS generic x86-64 image
- copies that image to the USB for offline use
- creates a bootable Home Assistant OS installer USB

When you boot another PC from that USB, the installer:

- checks the Home Assistant OS image already stored on the USB
- checks online for a newer verified Home Assistant OS image, if internet is available
- lets you choose the internal disk to install to
- warns before erasing the selected disk
- writes Home Assistant OS to the selected disk
- reboots into Home Assistant OS when finished

## Important Warnings

- The selected USB drive will be erased.
- The selected target disk inside the install PC will be erased.
- Do not use this for dual boot.
- Do not use this if you need to keep existing data.
- Do not select a Windows disk unless you intend to erase it.
- Secure Boot should be disabled.

## Download

From the GitHub release page, download the package for your desktop:

- `HAOS-USB-Creator-win-x64.zip`
- `HAOS-USB-Creator-linux-x86_64.AppImage`
- `HAOS-USB-Creator-macos.dmg`

Optional:

- `HAOS-Installer-ISO.zip`

The ISO is useful for VMs, Ventoy drives, or optical boot media. Unlike the USB created by either desktop app, the ISO does not contain a cached Home Assistant OS image, so it needs internet access during install. The ISO by itself cannot install HAOS for a legacy boot. (for now)


## Basic Use

1. Download and extract the Windows package, open the macOS DMG, or download the Linux AppImage.
2. Run the app (`HAOSInstaller.App.exe` on Windows, the executable AppImage on Linux, or `HAOS USB Creator.app` on macOS).
3. Allow administrator permission when prompted for the USB write.
4. Insert the USB drive you want to turn into the installer.
5. Select the USB drive in the app.
6. Confirm the erase warning.
7. Wait for the app to finish writing the USB.
8. Move the USB to the PC that will run Home Assistant OS.
9. Boot that PC from the USB.
10. Follow the installer prompts.

Linux requirements and source checkout instructions are in [src/LinuxApp/README.md](src/LinuxApp/README.md). macOS notes and build instructions are in [src/MacApp/README.md](src/MacApp/README.md).

After installation, Home Assistant should become available at:

```text
http://homeassistant.local:8123
```

or by using the IP address shown by your router.

## Legacy boot

Check this to enable the install into older non-UEFI systems

## Attended And Unattended Install

The normal install mode asks you to choose the target disk and confirm before erasing it.

The unattended option is intended for headless or appliance-style installs. It should only be used when the target PC has only one internal install disk. If multiple eligible disks are found, unattended install will stop instead of guessing.

Do not use unattended mode on a machine with multiple internal drives.

## Optional SSH Access

The USB creator can enable SSH access in the booted installer.

Use this if the target PC is headless and unattended mode does not suit the install. Set a temporary password in the app, then connect after booting the USB as:

```text
root
```

If the installer cannot bring up the network interface, SSH will not be reachable.

## Unofficial Project

This project is not made by, endorsed by, or affiliated with Home Assistant, Nabu Casa, or the Open Home Foundation.

Home Assistant OS images are downloaded from official Home Assistant OS release sources. Home Assistant names and marks belong to their respective owners.

## License

This project is licensed under the GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE).

Third-party components and downloaded images remain under their own upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

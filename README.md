# HAOS AIO USB Creator

HAOS AIO USB Creator is an unofficial Windows tool for creating a bootable all-in-one installer USB for **Home Assistant OS on a dedicated generic x86-64 PC**.

It is meant for dedicacated x86-64 machines.

## What It Does

The Windows app:

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
- The target PC should use UEFI boot mode.
- Secure Boot should be disabled.

## Download

From the GitHub release page, most users should download:

- `HAOS-USB-Creator-win-x64.zip`

Optional:

- `HAOS-Installer-ISO.zip`

The ISO is useful for VMs, Ventoy drives, or optical boot media. Unlike the USB created by the Windows app, the ISO does not contain a cached Home Assistant OS image, so it normally needs internet access during install.


## Basic Use

1. Download and extract `HAOS-USB-Creator-win-x64.zip`.
2. Run the app on Windows.
3. Allow administrator permission when prompted.
4. Insert the USB drive you want to turn into the installer.
5. Select the USB drive in the app.
6. Confirm the erase warning.
7. Wait for the app to finish writing the USB.
8. Move the USB to the PC that will run Home Assistant OS.
9. Boot that PC from the USB.
10. Follow the installer prompts.

After installation, Home Assistant should become available at:

```text
http://homeassistant.local:8123
```

or by using the IP address shown by your router.

## Attended And Unattended Install

The normal install mode asks you to choose the target disk and confirm before erasing it.

The unattended option is intended for headless or appliance-style installs. It should only be used when the target PC has only one internal install disk. If multiple eligible disks are found, unattended install will stop... this is intended as to safegard against data loss.

Do not use unattended mode on a machine with multiple internal drives.

## Unofficial Project

This project is not made by, endorsed by, or affiliated with Home Assistant, Nabu Casa, or the Open Home Foundation.

Home Assistant OS images are downloaded from official Home Assistant OS release sources. Home Assistant names and marks belong to their respective owners.

## License

This project is licensed under the GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE).

Third-party components and downloaded images remain under their own upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

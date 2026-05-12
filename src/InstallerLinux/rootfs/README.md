# Rootfs Overlay

This folder contains the Alpine root filesystem overlay used by the HAOS AIO boot image.

Current overlay contents include:

- `etc/apk/world`: runtime packages required by the installer.
- `etc/inittab`: starts the installer automatically on tty1 and provides a serial console entry.
- `etc/network/interfaces`: basic network configuration.
- `etc/profile.d/haos-installer.sh`: shell hint for restarting the installer.
- `usr/local/bin/haos-installer-autostart`: login wrapper for the installer.

The main installer scripts are copied from `src/InstallerLinux/scripts` during the boot image build.


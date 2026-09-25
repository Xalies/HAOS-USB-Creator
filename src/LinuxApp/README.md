# HAOS AIO USB Creator for Linux

This is a self-contained GTK AppImage for preparing the same bootable HAOS installer USB as the Windows creator. The AppImage bundles Python, GTK, Linux disk tools, and the installer boot image. The app stays unprivileged while it downloads the official HAOS image; only the disk writer asks for administrator authorization.

## Run

Download the Linux AppImage and run:

```sh
chmod +x HAOS-USB-Creator-linux-x86_64.AppImage
./HAOS-USB-Creator-linux-x86_64.AppImage
```

No Python, GTK, or disk-tool packages need to be installed. A Linux desktop and administrator authentication are still needed to write a USB drive. If FUSE is unavailable, run the same file with `--appimage-extract-and-run`.

From a source checkout, build the boot image using `src/InstallerLinux/build/build-installer-image.sh`, then run `bash src/LinuxApp/build-appimage.sh`. Build dependencies are only needed to create the AppImage, not to use it.

The app only lists USB block devices up to 128 GiB and excludes devices carrying `/`, `/boot`, `/home`, `/var`, or swap. It checks the selected device again in the privileged writer before erasing it. The downloaded HAOS payload is SHA-256 verified before copying; if it cannot be downloaded, the booted installer will need network access. Unattended mode should only be enabled when the target PC has one eligible internal disk.

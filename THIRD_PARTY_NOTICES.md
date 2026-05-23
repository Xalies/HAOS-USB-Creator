# Third-Party Notices

HAOS AIO USB Creator is licensed under the GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE).

This project also builds, bundles, downloads, or runs software and images from third parties. Those components remain under their own upstream licenses.

## Alpine Linux

The bootable installer environment is based on Alpine Linux and includes Alpine packages needed to boot, detect disks, access the network, verify images, and write Home Assistant OS to disk.

Alpine Linux and its packages are distributed under their respective upstream licenses. See the Alpine Linux project and package metadata for details:

- <https://alpinelinux.org/>
- <https://pkgs.alpinelinux.org/>

## Home Assistant OS

The Windows app and Linux installer download official Home Assistant OS generic x86-64 images from upstream release sources. Those images are not part of this project's source license and remain governed by the Home Assistant project's own licensing and release terms.

Home Assistant, Home Assistant OS, Nabu Casa, and Open Home Foundation names and marks belong to their respective owners.

## Microsoft .NET

The Windows app is built with .NET and WPF. Microsoft .NET runtime, SDK, and related packages remain under their respective Microsoft and upstream licenses.

## Build And Release Outputs

Generated release files can include:

- a Windows application package
- a Linux boot image
- a bootable ISO image for VM use

These outputs may contain third-party software. Distributing those files means the distributor should also respect the relevant upstream licenses.

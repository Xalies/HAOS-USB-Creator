# HAOS AIO USB Creator for macOS

A native SwiftUI app that creates the same bootable HAOS installer USB as the Windows and Linux creators. It follows the Windows app's look and wizard (Welcome, USB drive, Review, Writing) and writes the same USB layout and `installer-config.json`.

Requires macOS 13 or newer on Apple silicon or Intel.

## Run

Download `HAOS-USB-Creator-macos.dmg` from the release page, open it and double-click `HAOS USB Creator.app`. The app runs directly from the compressed, read-only disk image and does not need to be copied to Applications. An ad-hoc signed development build may require Control-click → **Open** or approval under **System Settings → Privacy & Security**; a notarized release opens normally.

The app runs without administrator rights. Only opening the USB drive for the raw write asks for an administrator password (the standard macOS prompt, through Apple's `authopen`). If macOS asks whether the app may access files on a removable volume, allow it; that is needed to write the USB drive and to copy Home Assistant OS onto the new `HAOS-CACHE` partition.

## How it works

- Drives come from `diskutil list external physical`. Internal disks, disk images and the disk holding the running system are never listed. Drives above 128 GB are shown with a *Large drive* tag and refused at write time, like the Windows app.
- After confirmation the app starts `Contents/MacOS/HAOSUSBWriter`. The writer checks the drive again, asks for the administrator password, verifies the boot image's SHA-256, unmounts the drive, opens `/dev/rdiskN` through `/usr/libexec/authopen`, writes the image and moves the backup GPT to the end of the disk (as `sgdisk -e` does on Linux). A root process started with `osascript ... with administrator privileges` cannot open the device: macOS denies it with "Operation not permitted" because it is not tied to the app's removable volume permission.
- While the boot image is written, the app downloads the official `haos_generic-x86-64-*.img.xz` from the Home Assistant OS GitHub release into `~/Library/Caches/HAOS-USB-Creator` and verifies its SHA-256 digest. The writer then copies it with `manifest.json` and `.sha256` into `cache/` on the `HAOS-CACHE` partition. If the download fails, the USB is still created and the booted installer downloads Home Assistant OS itself.
- Finally the writer adds `cache/installer-config.json` (unattended, SSH, legacy BIOS options), unmounts and ejects the USB.

## Build

Only the Xcode Command Line Tools are needed (`xcode-select --install`).

```sh
# Boot image: build it with src/InstallerLinux/build/build-installer-image.sh (needs Docker),
# or copy it out of the latest Windows release:
src/MacApp/fetch-boot-image.sh

# Builds artifacts/macos-app/HAOS USB Creator.app and HAOS-USB-Creator-macos.dmg
src/MacApp/build-app.sh
open artifacts/macos-app/HAOS-USB-Creator-macos.dmg
```

`build-app.sh [boot-image-dir] [output-dir]` bundles `haos-installer-x86_64.img` and its `.sha256` from the boot image directory (default `artifacts/installer-linux`). Without a bundled image the app also looks in `~/Library/Application Support/HAOS-USB-Creator/BootImages`.

The default build is ad-hoc signed. To create a Developer ID signed build using a certificate already installed in Keychain:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" src/MacApp/build-app.sh
```

Developer ID signing does not notarize the app. To sign the app and DMG, submit the DMG to Apple's notary service, and staple its ticket, first save notary credentials in Keychain with `xcrun notarytool store-credentials`, then run:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="your-keychain-profile" \
src/MacApp/build-app.sh
```

To package an app exported from Xcode without rebuilding it, use the same environment variables with:

```sh
src/MacApp/create-dmg.sh "/path/to/HAOS USB Creator.app" \
  artifacts/macos-app/HAOS-USB-Creator-macos.dmg
```

GitHub release builds use the same signing and notarization credentials as the MeshVault workflow. Add these repository or organization Actions secrets before running a release:

- `MAC_DEVELOPER_ID_CERTIFICATE_BASE64`
- `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `MAC_NOTARY_APPLE_ID`
- `MAC_NOTARY_APP_PASSWORD`

The release job refuses to publish the macOS artifact if a secret is missing, notarization fails, the ticket cannot be stapled, or Gatekeeper rejects the DMG.

The logic in `Sources/HAOSUSBCreatorCore` has unit tests (`swift test` needs a full Xcode install for XCTest).

## Archive in Xcode

The checked-in Xcode project builds a universal app, embeds the universal writer helper, enables the hardened runtime and signs Release archives with Developer ID Application.

1. Run `src/MacApp/fetch-boot-image.sh` so `artifacts/installer-linux` contains the boot image and checksum.
2. Open `src/MacApp/HAOSUSBCreator.xcodeproj` in Xcode.
3. Select the **HAOS USB Creator** scheme and **Any Mac** destination.
4. In the app target's **Signing & Capabilities** tab, confirm the team and bundle identifier. Update **Version** and **Build** before a release.
5. Choose **Product → Archive**. In Organizer, select the archive and export the Developer ID signed app.
6. Run `create-dmg.sh` as shown above. With `NOTARYTOOL_PROFILE` set, it signs, notarizes and staples the final compressed DMG.

Release archives require the bundled boot image and fail early if it is missing or its SHA-256 does not match. Debug builds may run without one and use the existing Application Support fallback.

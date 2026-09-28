import Foundation

/// UI text, kept identical to the Windows app's `Resources/UiStrings.resx`.
enum UiText {
    static let appTitle = "HAOS AIO USB Creator"
    static let brandLine1 = "HAOS AIO"
    static let brandLine2 = "USB Creator"
    static let stepWelcome = "1. Welcome"
    static let stepDrive = "2. USB drive"
    static let stepConfirm = "3. Review"
    static let stepWrite = "4. Writing"

    static let welcomeHeading = "Create an all-in-one HAOS install USB"
    static let welcomeSubheading = "Unofficial USB creator for installing Home Assistant OS on a dedicated generic x86-64 PC."
    static let welcomeWhatWillHappen = "What will happen"
    static let welcomeBullets = [
        "- This app will erase the selected USB drive and turn it into an all-in-one install USB.",
        "- It will download the latest Home Assistant OS generic x86-64 image and copy it to the USB.",
        "- Boot the target PC from the USB and the installer will start automatically.",
        "- The installer on the USB will check for a newer Home Assistant OS image if internet is available.",
        "- On the target PC, you will choose the internal drive, confirm the erase warning, and install Home Assistant OS.",
        "- Reboot.",
    ]
    static let buttonGetStarted = "Get Started"

    static let driveHeading = "Select your USB drive"
    static let driveSubheading = "Choose the USB stick that will receive the Linux installer environment. The selected USB will be erased when you confirm the write."
    static let driveScanning = "Scanning for USB drives..."
    static let buttonRefresh = "Refresh"
    static let driveEmpty = "No removable USB drives detected."
    static let driveLarge = "Large drive"
    static let driveHaosInstaller = "HAOS install USB"
    static let driveWindowsLayout = "Windows layout"
    static let driveDetailSeparator = "  -  "
    static let buttonBack = "Back"
    static let buttonContinue = "Continue"

    static let confirmHeading = "Review and confirm"
    static let confirmSubheading = "Check the selected USB drive before writing. This USB will be completely erased."
    static let confirmTargetUsb = "Target USB"
    static let confirmSize = "Size"
    static let confirmDevicePath = "Device path"
    static let confirmStatus = "Status"
    static let confirmEraseText = "This will erase the selected USB drive and create an all-in-one HAOS install USB."
    static let unattendedTitle = "Unattended install"
    static let unattendedWarning = "Only use this on a dedicated system with one disk. Installer should fall back to a choice if more than one disk is detected during install. If you plan to keep the USB after creating it, LABEL IT!!!."
    static let unattendedConfirmText = "I understand the booted installer will automatically erase the detected internal target disk without asking me again."
    static let sshAccessTitle = "Enable installer SSH"
    static let sshAccessWarning = "Allows root login. This password is stored on this USB."
    static let sshPasswordLabel = "SSH password (at least 8 characters)"
    static let legacyBiosTitle = "Legacy BIOS support"
    static let legacyBiosWarning = "Enable support for installing HAOS onto older machines without UEFI."
    static let buttonStartWrite = "Start write"

    static let writeHeading = "Creating all-in-one install USB"
    static let writeSubheading = "Do not remove the USB drive or close this window."
    static let writePrepareTitle = "1 - Prepare installer environment"
    static let writeBootTitle = "2 - Write boot environment to USB"
    static let writeDownloadTitle = "3 - Download Home Assistant OS"
    static let writeCopyTitle = "4 - Copy HAOS image to USB"
    static let writeBadgeWaiting = "Waiting"
    static let writeBadgeWorking = "Working..."
    static let writeBadgeDone = "Done"
    static let writeBadgeBlocked = "Blocked"
    static let writePrepareInitial = "Checking bundled installer image."
    static let writeBootInitial = "Waiting"
    static let writeDownloadInitial = "Fetches the latest HAOS release."
    static let writeCopyInitial = "Waiting"
    static let writeErrorIcon = "X"

    static let finishHeading = "Install USB is ready"
    static let finishSummaryDefault = "Home Assistant OS has been added to the USB."
    static let finishSummaryNoPayload = "The install USB is ready. This installer does not include the Home Assistant OS  image, the Linux installer will download it if the internet is available."
    static let finishSummaryWithPayload = "The install USB is ready. This installer does include the Home Assistant OS  image, the Linux installer will check for newer versions if the internet is available."
    static let buttonStartOver = "Start over"

    static let progressCheckingLatestHaos = "Checking for the latest Home Assistant OS image."
    static let progressLatestImageFormat = "Latest image: %@"
    static let progressHaosReady = "Home Assistant OS image is ready."
    static let progressSkippedFormat = "Skipped: %@"
    static let progressPrepareInstaller = "Preparing installer environment."
    static let progressInstallerReady = "Installer environment ready."
    static let progressVerifyingHaos = "Verifying Home Assistant OS image."
    static let progressVerifyingPrefix = "Verifying image hash:"
    static let progressWaitingForUsb = "Waiting for the USB disk to be prepared."

    static let errorBootImageNotFound = "Bundled HAOS AIO boot image was not found."
    static let errorBootImageChecksum = "The HAOS AIO boot image has no valid .sha256 checksum file."
    static let errorSelectUsbDrive = "Select a removable USB drive."
    static let errorScanUsbFormat = "Could not scan USB drives: %@"
    static let errorWriteFailed = "USB creation failed or administrator authorization was cancelled."
    static let quitWhileWritingTitle = "The install USB is still being created."
    static let quitWhileWritingText = "Do not remove the USB drive or close this window."

    static let driveFallbackModel = "USB drive"
    static let driveStatusExistingHaos = "Existing HAOS install USB. It will be overwritten."
    static let driveStatusWindowsLayout = "Existing Windows-style partitions detected. They will be erased."
    static let driveStatusReady = "Ready to create an all-in-one HAOS install USB."
    static let buyMeCoffeeShortText = "If this saved you some time"
    static let buyMeCoffeeTooltip = "If this saved you some time, feel free to buy me a coffee!"
    static let buyMeCoffeeUrl = URL(string: "https://buymeacoffee.com/xalies")!

    static let finishNextStepAttended = "When the Linux installer starts, it will check the Home Assistant OS image on the USB, look online for a newer verified image, and use the newest valid option. It will then show the internal drives it can install to, ask you to choose the target disk, show a clear erase warning, write Home Assistant OS, set up boot where possible, and reboot when finished."
    static let finishNextStepUnattended = "When the Linux installer starts, it will check the Home Assistant OS image on the USB, look online for a newer verified image, and use the newest valid option automatically. Because unattended mode is enabled, it will continue only when it finds one eligible internal disk, erase that disk, write Home Assistant OS, set up boot drive where possible and reboot when finished. Unattended setups are marked on install USB so install loops should have protection for clean installs."
    static let finishLegacyBiosNote = "Legacy BIOS support is enabled. After writing Home Assistant OS, the installer will add the extra GRUB boot files needed by older non-UEFI PCs."
    static let finishSshAccessFormat = "SSH is enabled for the booted installer. Connect as root using the SSH password you set: %@"
}

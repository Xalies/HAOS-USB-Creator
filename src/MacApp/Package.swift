// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HAOSUSBCreator",
    platforms: [.macOS(.v13)],
    targets: [
        // Disk, download and USB layout logic shared by the app and the privileged writer.
        .target(name: "HAOSUSBCreatorCore"),
        // SwiftUI desktop app. Runs unprivileged.
        .executableTarget(name: "HAOSUSBCreator", dependencies: ["HAOSUSBCreatorCore"]),
        // Small command line writer that the app starts with administrator rights.
        .executableTarget(name: "HAOSUSBWriter", dependencies: ["HAOSUSBCreatorCore"]),
        .testTarget(name: "HAOSUSBCreatorCoreTests", dependencies: ["HAOSUSBCreatorCore"]),
    ]
)

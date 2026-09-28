import Foundation

public struct UsbDrive: Identifiable, Equatable, Codable {
    /// Whole-disk BSD name, e.g. `disk4`.
    public let identifier: String
    public let model: String?
    public let sizeBytes: Int64
    public let blockSize: Int
    public let isHaosInstaller: Bool
    public let hasWindowsPartitions: Bool
    public let mountPoints: [String]

    public init(identifier: String, model: String?, sizeBytes: Int64, blockSize: Int,
                isHaosInstaller: Bool, hasWindowsPartitions: Bool, mountPoints: [String]) {
        self.identifier = identifier
        self.model = model
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.isHaosInstaller = isHaosInstaller
        self.hasWindowsPartitions = hasWindowsPartitions
        self.mountPoints = mountPoints
    }

    public var id: String { identifier }
    public var devicePath: String { "/dev/\(identifier)" }
    public var rawDevicePath: String { "/dev/r\(identifier)" }
    public var sizeDisplay: String { ByteFormat.gib(sizeBytes) }
    public var isLargeDrive: Bool { sizeBytes > 128_000_000_000 }
    public var showWindowsLayoutWarning: Bool { hasWindowsPartitions && !isHaosInstaller }
}

public enum DiskUtil {
    public static let path = "/usr/sbin/diskutil"
    public static let haosVolumeLabels: Set<String> = ["HAOSINSTLR", "HAOS-INSTLR", "HAOS-BOOT", "HAOS-CACHE"]
    /// Partition contents that the Windows app reports as "Windows layout".
    static let windowsContents: Set<String> = [
        "EFI", "Microsoft Basic Data", "Microsoft Reserved", "Windows Recovery", "Windows_NTFS",
    ]
    /// Same limit as the Windows `DiskWriteGuard`.
    public static let maximumTargetBytes: Int64 = 128 * 1024 * 1024 * 1024

    public static func plist(_ arguments: [String]) throws -> [String: Any] {
        let data = try Shell.run(path, arguments)
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CreatorError("diskutil returned unexpected output.")
        }
        return object
    }

    public static func info(_ identifier: String) throws -> [String: Any] {
        try plist(["info", "-plist", identifier])
    }

    /// External physical disks that may be turned into an installer USB.
    public static func removableDrives() throws -> [UsbDrive] {
        let list = try plist(["list", "-plist", "external", "physical"])
        let bootDisks = bootWholeDisks()
        var drives: [UsbDrive] = []
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let identifier = entry["DeviceIdentifier"] as? String,
                  let details = try? info(identifier),
                  let drive = makeDrive(listEntry: entry, info: details, bootDisks: bootDisks) else {
                continue
            }
            drives.append(drive)
        }
        return drives.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    /// Builds a drive from `diskutil list` and `diskutil info` output. Returns nil for disks that must not be offered.
    public static func makeDrive(listEntry: [String: Any], info: [String: Any], bootDisks: Set<String>) -> UsbDrive? {
        guard let identifier = listEntry["DeviceIdentifier"] as? String,
              wholeDisk(of: identifier) == identifier,
              info["WholeDisk"] as? Bool ?? true,
              info["Internal"] as? Bool != true,
              !bootDisks.contains(identifier) else {
            return nil
        }
        let bus = info["BusProtocol"] as? String ?? ""
        if bus == "Disk Image" || bus == "Virtual Interface" || info["VirtualOrPhysical"] as? String == "Virtual" {
            return nil
        }
        let size = int64(info["TotalSize"]) ?? int64(info["Size"]) ?? int64(listEntry["Size"]) ?? 0
        guard size > 0 else { return nil }

        // A disk without a partition table carries its volume on the whole-disk entry.
        let partitions = listEntry["Partitions"] as? [[String: Any]] ?? []
        let volumes = partitions + [listEntry]
        let labels = volumes.compactMap { ($0["VolumeName"] as? String)?.uppercased() }
        let contents = partitions.compactMap { $0["Content"] as? String }
        let model = (info["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)

        return UsbDrive(
            identifier: identifier,
            model: model?.isEmpty == false ? model : nil,
            sizeBytes: size,
            blockSize: Int(int64(info["DeviceBlockSize"]) ?? 512),
            isHaosInstaller: labels.contains { haosVolumeLabels.contains($0) },
            hasWindowsPartitions: contents.contains { windowsContents.contains($0) },
            mountPoints: volumes.compactMap { $0["MountPoint"] as? String }.filter { !$0.isEmpty })
    }

    /// Whole disks that hold the running system, including the physical stores of its APFS container.
    public static func bootWholeDisks() -> Set<String> {
        guard let details = try? info("/") else { return [] }
        var disks = Set<String>()
        for key in ["DeviceIdentifier", "ParentWholeDisk"] {
            if let value = details[key] as? String, let disk = wholeDisk(of: value) {
                disks.insert(disk)
            }
        }
        disks.formUnion(physicalStores(details))
        return disks
    }

    /// Physical whole disks behind a disk, following APFS containers to their physical stores.
    public static func physicalDisks(of identifier: String) -> Set<String> {
        guard let disk = wholeDisk(of: identifier) else { return [] }
        let stores = (try? info(disk)).map(physicalStores) ?? []
        return stores.isEmpty ? [disk] : stores
    }

    static func physicalStores(_ details: [String: Any]) -> Set<String> {
        let stores = details["APFSPhysicalStores"] as? [[String: Any]] ?? []
        return Set(stores.compactMap { ($0["APFSPhysicalStore"] as? String).flatMap(wholeDisk(of:)) })
    }

    /// `disk4s2`, `/dev/rdisk4` → `disk4`.
    public static func wholeDisk(of identifier: String) -> String? {
        var name = Substring(identifier)
        if name.hasPrefix("/dev/") { name = name.dropFirst(5) }
        if name.hasPrefix("rdisk") { name = name.dropFirst() }
        guard name.hasPrefix("disk") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : "disk\(digits)"
    }

    static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

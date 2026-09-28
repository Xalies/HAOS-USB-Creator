import Foundation

public protocol BlockDevice {
    func read(offset: Int64, count: Int) throws -> [UInt8]
    func write(_ bytes: [UInt8], offset: Int64) throws
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum<Bytes: Collection>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// The boot image is smaller than the USB drive, so its backup GPT ends up in the middle of the
/// disk after a raw write. This moves it to the last sector, like `sgdisk -e` in the Linux app.
public enum GPT {
    /// Returns false when the backup GPT already sits at the end of the disk.
    @discardableResult
    public static func moveBackupToEnd(device: BlockDevice, totalSectors: Int64, sectorSize: Int = 512) throws -> Bool {
        let sector = Int64(sectorSize)
        var header = try device.read(offset: sector, count: sectorSize)
        guard header.count == sectorSize, Array(header[0..<8]) == Array("EFI PART".utf8) else {
            throw CreatorError("The written boot image has no GPT header.")
        }
        let headerSize = Int(le32(header, 12))
        guard headerSize >= 92, headerSize <= sectorSize else {
            throw CreatorError("The written boot image has an invalid GPT header.")
        }
        guard headerChecksum(header, size: headerSize) == le32(header, 16) else {
            throw CreatorError("The written boot image has a damaged GPT header.")
        }

        let oldBackupLBA = Int64(bitPattern: le64(header, 32))
        let entriesLBA = Int64(bitPattern: le64(header, 72))
        let entryCount = Int(le32(header, 80))
        let entrySize = Int(le32(header, 84))
        let entriesBytes = entryCount * entrySize
        guard entrySize >= 128, entriesBytes > 0 else {
            throw CreatorError("The written boot image has an invalid GPT partition table.")
        }
        let entrySectors = (entriesBytes + sectorSize - 1) / sectorSize
        let newBackupLBA = totalSectors - 1
        if newBackupLBA == oldBackupLBA {
            return false
        }
        guard newBackupLBA > oldBackupLBA else {
            throw CreatorError("The boot image is larger than the USB drive.")
        }

        let entries = try device.read(offset: entriesLBA * sector, count: entrySectors * sectorSize)
        guard CRC32.checksum(entries[0..<entriesBytes]) == le32(header, 88) else {
            throw CreatorError("The written boot image has a damaged GPT partition table.")
        }

        let newEntriesLBA = newBackupLBA - Int64(entrySectors)
        let newLastUsableLBA = newEntriesLBA - 1

        var backup = [UInt8](repeating: 0, count: sectorSize)
        backup.replaceSubrange(0..<headerSize, with: header[0..<headerSize])
        put64(&backup, 24, UInt64(newBackupLBA))
        put64(&backup, 32, 1)
        put64(&backup, 48, UInt64(newLastUsableLBA))
        put64(&backup, 72, UInt64(newEntriesLBA))
        seal(&backup, size: headerSize)

        put64(&header, 32, UInt64(newBackupLBA))
        put64(&header, 48, UInt64(newLastUsableLBA))
        seal(&header, size: headerSize)

        // Clear the stale backup header first; it can overlap the new entries on a barely larger disk.
        try device.write([UInt8](repeating: 0, count: sectorSize), offset: oldBackupLBA * sector)
        try device.write(entries, offset: newEntriesLBA * sector)
        try device.write(backup, offset: newBackupLBA * sector)
        try device.write(header, offset: sector)
        try updateProtectiveMBR(device: device, totalSectors: totalSectors, sectorSize: sectorSize)
        return true
    }

    /// Grows a plain protective MBR entry to the new disk size. Hybrid MBRs are left untouched.
    static func updateProtectiveMBR(device: BlockDevice, totalSectors: Int64, sectorSize: Int) throws {
        var mbr = try device.read(offset: 0, count: sectorSize)
        guard mbr.count >= 512, mbr[510] == 0x55, mbr[511] == 0xAA else { return }
        let used = (0..<4).map { 446 + $0 * 16 }.filter { mbr[$0 + 4] != 0 }
        guard used.count == 1, let entry = used.first, mbr[entry + 4] == 0xEE, le32(mbr, entry + 8) == 1 else {
            return
        }
        let size = UInt32(min(totalSectors - 1, Int64(UInt32.max)))
        guard le32(mbr, entry + 12) != size else { return }
        put32(&mbr, entry + 12, size)
        try device.write(mbr, offset: 0)
    }

    static func headerChecksum(_ header: [UInt8], size: Int) -> UInt32 {
        var copy = Array(header[0..<size])
        put32(&copy, 16, 0)
        return CRC32.checksum(copy)
    }

    static func seal(_ header: inout [UInt8], size: Int) {
        put32(&header, 16, headerChecksum(header, size: size))
    }

    static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }

    static func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << UInt64(8 * $1) }
    }

    static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(8 * index))
        }
    }

    static func put64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(8 * index))
        }
    }
}

import XCTest
@testable import HAOSUSBCreatorCore

final class MemoryDisk: BlockDevice {
    var bytes: [UInt8]

    init(sectors: Int) {
        bytes = [UInt8](repeating: 0, count: sectors * 512)
    }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        Array(bytes[Int(offset)..<Int(offset) + count])
    }

    func write(_ data: [UInt8], offset: Int64) throws {
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
    }
}

final class GPTTests: XCTestCase {
    /// Builds a GPT disk image like the boot image: protective MBR, primary GPT, one partition, backup GPT.
    private func makeImage(sectors: Int) -> MemoryDisk {
        let disk = MemoryDisk(sectors: sectors)
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[446 + 4] = 0xEE
        GPT.put32(&mbr, 446 + 8, 1)
        GPT.put32(&mbr, 446 + 12, UInt32(sectors - 1))
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try! disk.write(mbr, offset: 0)

        var entries = [UInt8](repeating: 0, count: 128 * 128)
        entries[0] = 0x28 // any non-zero type GUID
        GPT.put64(&entries, 32, 2048)
        GPT.put64(&entries, 40, UInt64(sectors - 100))

        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        GPT.put32(&header, 8, 0x0001_0000)
        GPT.put32(&header, 12, 92)
        GPT.put64(&header, 24, 1)
        GPT.put64(&header, 32, UInt64(sectors - 1))
        GPT.put64(&header, 40, 34)
        GPT.put64(&header, 48, UInt64(sectors - 34))
        GPT.put64(&header, 72, 2)
        GPT.put32(&header, 80, 128)
        GPT.put32(&header, 84, 128)
        GPT.put32(&header, 88, CRC32.checksum(entries))
        GPT.seal(&header, size: 92)
        try! disk.write(header, offset: 512)
        try! disk.write(entries, offset: 2 * 512)

        var backup = header
        GPT.put64(&backup, 24, UInt64(sectors - 1))
        GPT.put64(&backup, 32, 1)
        GPT.put64(&backup, 72, UInt64(sectors - 33))
        GPT.seal(&backup, size: 92)
        try! disk.write(entries, offset: Int64(sectors - 33) * 512)
        try! disk.write(backup, offset: Int64(sectors - 1) * 512)
        return disk
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testMovesBackupToEndOfLargerDisk() throws {
        let image = makeImage(sectors: 4096)
        let disk = MemoryDisk(sectors: 10000)
        disk.bytes.replaceSubrange(0..<image.bytes.count, with: image.bytes)

        XCTAssertTrue(try GPT.moveBackupToEnd(device: disk, totalSectors: 10000))

        let primary = try disk.read(offset: 512, count: 512)
        XCTAssertEqual(GPT.le64(primary, 32), 9999)
        XCTAssertEqual(GPT.le64(primary, 48), 9999 - 33)
        XCTAssertEqual(GPT.headerChecksum(primary, size: 92), GPT.le32(primary, 16))

        let backup = try disk.read(offset: 9999 * 512, count: 512)
        XCTAssertEqual(Array(backup[0..<8]), Array("EFI PART".utf8))
        XCTAssertEqual(GPT.le64(backup, 24), 9999)
        XCTAssertEqual(GPT.le64(backup, 32), 1)
        XCTAssertEqual(GPT.le64(backup, 72), 9999 - 32)
        XCTAssertEqual(GPT.headerChecksum(backup, size: 92), GPT.le32(backup, 16))

        let backupEntries = try disk.read(offset: (9999 - 32) * 512, count: 128 * 128)
        XCTAssertEqual(backupEntries, try disk.read(offset: 2 * 512, count: 128 * 128))
        XCTAssertEqual(try disk.read(offset: 4095 * 512, count: 512), [UInt8](repeating: 0, count: 512))

        let mbr = try disk.read(offset: 0, count: 512)
        XCTAssertEqual(GPT.le32(mbr, 446 + 12), 9999)

        XCTAssertFalse(try GPT.moveBackupToEnd(device: disk, totalSectors: 10000))
    }

    func testRejectsDamagedHeader() {
        let disk = makeImage(sectors: 4096)
        disk.bytes[512 + 40] ^= 0xFF
        XCTAssertThrowsError(try GPT.moveBackupToEnd(device: disk, totalSectors: 8192))
    }
}

final class ReleaseTests: XCTestCase {
    func testParsesVerifiedGenericImage() throws {
        let digest = String(repeating: "ab", count: 32)
        let json = """
        {"tag_name": "16.2", "assets": [
          {"name": "haos_ova-16.2.qcow2.xz", "browser_download_url": "https://github.com/home-assistant/operating-system/releases/download/16.2/haos_ova-16.2.qcow2.xz", "size": 1, "digest": "sha256:\(digest)"},
          {"name": "haos_generic-x86-64-16.2.img.xz", "browser_download_url": "https://github.com/home-assistant/operating-system/releases/download/16.2/haos_generic-x86-64-16.2.img.xz", "size": 12345, "digest": "sha256:\(digest.uppercased())"}
        ]}
        """
        let release = try ReleaseService.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "16.2")
        XCTAssertEqual(release.filename, "haos_generic-x86-64-16.2.img.xz")
        XCTAssertEqual(release.sha256, digest)
        XCTAssertEqual(release.size, 12345)
    }

    func testRejectsImageWithoutDigestOrForeignUrl() {
        let missing = #"{"assets": [{"name": "haos_generic-x86-64-16.2.img.xz", "browser_download_url": "https://github.com/home-assistant/operating-system/releases/download/16.2/x", "size": 1}]}"#
        XCTAssertThrowsError(try ReleaseService.parse(Data(missing.utf8)))
        let digest = String(repeating: "0", count: 64)
        let foreign = #"{"assets": [{"name": "haos_generic-x86-64-16.2.img.xz", "browser_download_url": "https://example.com/x", "size": 1, "digest": "sha256:\#(digest)"}]}"#
        XCTAssertThrowsError(try ReleaseService.parse(Data(foreign.utf8)))
    }
}

final class DriveTests: XCTestCase {
    func testMakesDriveFromDiskutilOutput() {
        let entry: [String: Any] = [
            "DeviceIdentifier": "disk4",
            "Content": "GUID_partition_scheme",
            "Size": 32_010_928_128,
            "Partitions": [
                ["DeviceIdentifier": "disk4s1", "Content": "EFI", "VolumeName": "HAOSINSTLR"],
                ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data", "VolumeName": "HAOS-CACHE",
                 "MountPoint": "/Volumes/HAOS-CACHE"],
            ],
        ]
        let info: [String: Any] = [
            "MediaName": "SanDisk Ultra ", "TotalSize": 32_010_928_128, "BusProtocol": "USB",
            "Internal": false, "WholeDisk": true, "DeviceBlockSize": 512,
        ]
        let drive = DiskUtil.makeDrive(listEntry: entry, info: info, bootDisks: ["disk0"])
        XCTAssertEqual(drive?.identifier, "disk4")
        XCTAssertEqual(drive?.model, "SanDisk Ultra")
        XCTAssertEqual(drive?.sizeDisplay, "29.81 GiB")
        XCTAssertEqual(drive?.isHaosInstaller, true)
        XCTAssertEqual(drive?.showWindowsLayoutWarning, false)
        XCTAssertEqual(drive?.mountPoints, ["/Volumes/HAOS-CACHE"])
        XCTAssertEqual(drive?.isLargeDrive, false)
    }

    func testSkipsInternalBootAndDiskImages() {
        let entry: [String: Any] = ["DeviceIdentifier": "disk5", "Size": 1000]
        XCTAssertNil(DiskUtil.makeDrive(listEntry: entry, info: ["Internal": true], bootDisks: []))
        XCTAssertNil(DiskUtil.makeDrive(listEntry: entry, info: ["BusProtocol": "Disk Image"], bootDisks: []))
        XCTAssertNil(DiskUtil.makeDrive(listEntry: entry, info: [:], bootDisks: ["disk5"]))
        XCTAssertNotNil(DiskUtil.makeDrive(listEntry: entry, info: [:], bootDisks: []))
    }

    func testWholeDisk() {
        XCTAssertEqual(DiskUtil.wholeDisk(of: "disk4s2"), "disk4")
        XCTAssertEqual(DiskUtil.wholeDisk(of: "/dev/rdisk12"), "disk12")
        XCTAssertEqual(DiskUtil.wholeDisk(of: "/dev/disk3s1s1"), "disk3")
        XCTAssertNil(DiskUtil.wholeDisk(of: "map auto_home"))
    }
}

final class WriterProtocolTests: XCTestCase {
    func testEventLinesRoundTrip() {
        let events: [WriterEvent] = [
            .ready,
            .progress(.boot, 12.5, "Wrote 1,024 of 2,048 bytes."),
            .progress(.copy, nil, "Waiting for the USB to be ready."),
            .error("Something failed"),
            .done(payloadCopied: true),
        ]
        for event in events {
            XCTAssertEqual(WriterEvent(line: event.line), event)
        }
        XCTAssertNil(WriterEvent(line: "Fatal error: something"))
    }

    func testInstallerConfigMatchesOtherCreators() throws {
        let data = try JSONFiles.encode(InstallerConfig(unattended: true, legacyBios: false, sshPassword: "secret123"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        let unattended = json?["unattended"] as? [String: Any]
        XCTAssertEqual(unattended?["mode"] as? String, "first-available-single-disk")
        XCTAssertEqual(unattended?["runOnce"] as? Bool, true)
        XCTAssertEqual((json?["ssh"] as? [String: Any])?["password"] as? String, "secret123")
        XCTAssertEqual((json?["legacyBiosBoot"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testByteFormats() {
        XCTAssertEqual(ByteFormat.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(ByteFormat.gib(0), "Unknown size")
        XCTAssertEqual(ByteFormat.gib(8 * 1_073_741_824), "8 GiB")
    }
}

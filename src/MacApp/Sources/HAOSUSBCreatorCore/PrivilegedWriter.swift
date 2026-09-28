import Foundation

/// Started by the app as the logged-in user and turns the selected USB drive into the installer:
/// raw boot image write, GPT fix-up, then the HAOS-CACHE files. Only the raw device is opened with
/// administrator rights, through `authopen` (see `RawDiskAccess`).
public final class PrivilegedWriter {
    private let emit: (WriterEvent) -> Void
    private var mountedCachePartition: String?
    private static let chunkSize = 4 << 20

    public init(emit: @escaping (WriterEvent) -> Void) {
        self.emit = emit
    }

    public func run(requestPath: String) -> Int32 {
        do {
            let copied = try write(requestPath: requestPath)
            emit(.done(payloadCopied: copied))
            return 0
        } catch {
            if let partition = mountedCachePartition {
                _ = try? Shell.run(DiskUtil.path, ["unmount", partition])
            }
            emit(.error(error.localizedDescription))
            return 1
        }
    }

    private func write(requestPath: String) throws -> Bool {
        let request = try JSONDecoder().decode(WriteRequest.self, from: Data(contentsOf: URL(fileURLWithPath: requestPath)))
        let drive = try eligibleDrive(request)
        // Ask for the administrator password first, before anything on the USB changes.
        let rawDisk = try RawDiskAccess(path: drive.rawDevicePath)
        let image = URL(fileURLWithPath: request.bootImage)
        guard image.pathExtension == "img", isSHA256Hex(request.bootImageSha256) else {
            throw CreatorError("Select a raw haos-installer .img file.")
        }
        let imageSize = try regularFileSize(image)
        guard imageSize > 0 else {
            throw CreatorError("The installer boot image is empty.")
        }
        guard imageSize <= drive.sizeBytes else {
            throw CreatorError("Boot image is larger than the selected USB drive.")
        }
        try ensureNotOnTarget([image.path, CommandLine.arguments[0]], drive)
        let password = request.sshPassword
        if !password.isEmpty && password.count < 8 {
            throw CreatorError("The SSH password must have at least 8 characters.")
        }

        emit(.progress(.boot, 0, "Checking the installer boot image."))
        try FileHash.verify(image, expected: request.bootImageSha256) { done, total in
            self.emit(.progress(.boot, nil,
                                "Verifying boot image: \(ByteFormat.grouped(done)) of \(ByteFormat.grouped(total)) bytes."))
        }

        emit(.progress(.boot, 0, "Preparing physical USB target: \(drive.devicePath)"))
        try Shell.run(DiskUtil.path, ["unmountDisk", "force", drive.devicePath])
        // Check the physical device again after unmounting, immediately before erasing it.
        _ = try eligibleDrive(request)

        let device = try openRawDevice(rawDisk, path: drive.rawDevicePath)
        do {
            emit(.ready)
            emit(.progress(.boot, 0, "Opened \(drive.rawDevicePath) for raw write access."))
            try writeImage(image, size: imageSize, to: device, blockSize: drive.blockSize, path: drive.devicePath)
            if drive.blockSize == 512 {
                emit(.progress(.boot, 99, "Moving the backup partition table to the end of the USB."))
                try GPT.moveBackupToEnd(device: RawDevice(fd: device), totalSectors: drive.sizeBytes / 512)
            }
            flush(device)
        } catch {
            close(device)
            throw error
        }
        // Closing the raw device makes macOS read the new partition table.
        close(device)
        emit(.progress(.boot, 100, "Boot environment written to the USB."))

        let partition = try findCachePartition(drive.identifier)
        let mountPoint = try mountCache(partition)
        mountedCachePartition = partition
        let cache = URL(fileURLWithPath: mountPoint).appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Keeps Spotlight from indexing the cache partition while it is mounted.
        FileManager.default.createFile(atPath: (mountPoint as NSString).appendingPathComponent(".metadata_never_index"),
                                       contents: nil)
        let config = InstallerConfig(unattended: request.unattended, legacyBios: request.legacyBios, sshPassword: password)
        try JSONFiles.encode(config).write(to: cache.appendingPathComponent("installer-config.json"))

        emit(.progress(.copy, nil, "Waiting for the Home Assistant OS download to finish."))
        let handoff = try waitForPayload(URL(fileURLWithPath: request.workDirectory, isDirectory: true))
        var copied = false
        if let payload = handoff.payload, let release = handoff.release {
            try addPayload(URL(fileURLWithPath: payload), release: release, cache: cache, mountPoint: mountPoint, drive: drive)
            copied = true
        }

        emit(.progress(.copy, 97, "Finishing USB setup."))
        sync()
        try Shell.run(DiskUtil.path, ["unmount", partition])
        mountedCachePartition = nil
        _ = try? Shell.run(DiskUtil.path, ["eject", drive.devicePath])
        emit(.progress(.copy, 100, copied
            ? "Finished adding Home Assistant OS to the USB."
            : "Home Assistant OS was not copied. The Linux installer will download it if the internet is available."))
        return copied
    }

    // MARK: - Checks

    private func eligibleDrive(_ request: WriteRequest) throws -> UsbDrive {
        guard DiskUtil.wholeDisk(of: request.disk) == request.disk else {
            throw CreatorError("Select a removable USB drive.")
        }
        guard let drive = try DiskUtil.removableDrives().first(where: {
            $0.identifier == request.disk && $0.sizeBytes == request.sizeBytes && $0.model == request.model
        }) else {
            throw CreatorError("The selected USB drive changed or is no longer eligible. Refresh and select it again.")
        }
        guard drive.sizeBytes <= DiskUtil.maximumTargetBytes else {
            throw CreatorError("Refusing to write because the selected USB is larger than the MVP safety limit.")
        }
        return drive
    }

    private func ensureNotOnTarget(_ paths: [String], _ drive: UsbDrive) throws {
        for path in paths {
            guard let source = Self.mountSource(of: path) else { continue }
            if DiskUtil.physicalDisks(of: source).contains(drive.identifier) {
                throw CreatorError("Source files cannot be stored on the USB drive being erased.")
            }
        }
    }

    static func mountSource(of path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw CreatorError("\(url.lastPathComponent) is not a regular file.")
        }
        return size
    }

    // MARK: - Boot image

    private func openRawDevice(_ rawDisk: RawDiskAccess, path: String) throws -> Int32 {
        for attempt in 1...30 {
            do {
                return try rawDisk.open()
            } catch is RawDiskBusy {
                // Retried below.
            }
            if attempt == 1 {
                emit(.progress(.boot, 0, "Waiting for raw disk access to \(path)."))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw CreatorError("Could not open \(path) for raw write access after waiting. "
            + "Close Finder windows, Disk Utility, or other tools using the USB.")
    }

    private func writeImage(_ image: URL, size: Int64, to device: Int32, blockSize: Int, path: String) throws {
        let source = open(image.path, O_RDONLY)
        guard source >= 0 else {
            throw posixError("Could not open \(image.lastPathComponent)")
        }
        defer { close(source) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 4096)
        defer { buffer.deallocate() }
        let sectorSize = max(blockSize, 512)

        emit(.progress(.boot, 0, "Writing boot image to \(path). Do not remove the USB."))
        var written: Int64 = 0
        var lastPercent = -1
        while written < size {
            let wanted = Int(min(Int64(Self.chunkSize), size - written))
            guard try readFully(source, buffer, wanted) == wanted else {
                throw CreatorError("The boot image changed while it was being written.")
            }
            // Raw devices only accept whole sectors.
            var length = wanted
            if length % sectorSize != 0 {
                let padded = (length + sectorSize - 1) / sectorSize * sectorSize
                (buffer + length).initializeMemory(as: UInt8.self, repeating: 0, count: padded - length)
                length = padded
            }
            try writeFully(device, buffer, length, offset: written, path: path)
            written += Int64(wanted)
            let percent = Int(written * 100 / size)
            if percent != lastPercent {
                lastPercent = percent
                emit(.progress(.boot, Double(min(percent, 99)),
                               "Wrote \(ByteFormat.grouped(written)) of \(ByteFormat.grouped(size)) bytes."))
            }
        }
    }

    private func flush(_ descriptor: Int32) {
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            _ = fsync(descriptor)
        }
    }

    // MARK: - HAOS-CACHE partition

    private func findCachePartition(_ disk: String) throws -> String {
        emit(.progress(.copy, nil, "Waiting for the USB to be ready."))
        for _ in 0..<30 {
            if let list = try? DiskUtil.plist(["list", "-plist", disk]),
               let whole = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first {
                for partition in whole["Partitions"] as? [[String: Any]] ?? [] {
                    guard let identifier = partition["DeviceIdentifier"] as? String else { continue }
                    let details = (try? DiskUtil.info(identifier)) ?? [:]
                    let label = (partition["VolumeName"] as? String) ?? (details["VolumeName"] as? String)
                    if label?.uppercased() == "HAOS-CACHE" || details["MediaName"] as? String == "HAOS Cache" {
                        return identifier
                    }
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw CreatorError("Boot image written, but its HAOS-CACHE partition did not appear.")
    }

    private func mountCache(_ partition: String) throws -> String {
        emit(.progress(.copy, nil, "Preparing the USB for copying."))
        for attempt in 1...10 {
            if let mountPoint = (try? DiskUtil.info(partition))?["MountPoint"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
            // macOS usually mounts the new FAT partition by itself; otherwise mount it here.
            do {
                try Shell.run(DiskUtil.path, ["mount", partition])
            } catch {
                if attempt == 10 { throw error }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw CreatorError("Could not mount the HAOS-CACHE partition.")
    }

    private func waitForPayload(_ workDirectory: URL) throws -> PayloadHandoff {
        let file = workDirectory.appendingPathComponent(PayloadHandoff.fileName)
        let deadline = Date().addingTimeInterval(3 * 60 * 60)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file) {
                return try JSONDecoder().decode(PayloadHandoff.self, from: data)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw CreatorError("Timed out waiting for the Home Assistant OS download.")
    }

    private func addPayload(_ payload: URL, release: HaosRelease, cache: URL, mountPoint: String, drive: UsbDrive) throws {
        guard ReleaseService.imageVersion(release.filename) != nil,
              payload.lastPathComponent == release.filename,
              ReleaseService.isOfficialDownload(release.url),
              isSHA256Hex(release.sha256) else {
            throw CreatorError("Home Assistant OS image metadata does not match the selected file.")
        }
        let size = try regularFileSize(payload)
        try ensureNotOnTarget([payload.path], drive)
        emit(.progress(.copy, 0, "Verifying Home Assistant OS image."))
        try FileHash.verify(payload, expected: release.sha256)
        guard freeSpace(mountPoint) >= size + (16 << 20) else {
            throw CreatorError("The Home Assistant OS image does not fit in the USB cache partition.")
        }

        emit(.progress(.copy, 0, "Adding Home Assistant OS to the USB."))
        try copyFile(payload, to: cache.appendingPathComponent(release.filename), size: size)
        emit(.progress(.copy, 94, "Home Assistant OS image copied."))
        try "\(release.sha256)  \(release.filename)\n"
            .write(to: cache.appendingPathComponent(release.filename + ".sha256"), atomically: false, encoding: .utf8)
        try JSONFiles.encode(HaosImageManifest(release: release, fileSizeBytes: size))
            .write(to: cache.appendingPathComponent("manifest.json"))
    }

    private func copyFile(_ source: URL, to destination: URL, size: Int64) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else {
            throw posixError("Could not open \(source.lastPathComponent)")
        }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else {
            throw posixError("Could not create \(destination.lastPathComponent) on the USB")
        }
        defer { close(output) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 4096)
        defer { buffer.deallocate() }

        var copied: Int64 = 0
        var lastPercent = -1
        while true {
            let count = try readFully(input, buffer, Self.chunkSize)
            if count == 0 { break }
            try writeFully(output, buffer, count, offset: copied, path: destination.path)
            copied += Int64(count)
            let percent = size > 0 ? Int(copied * 100 / size) : 100
            if percent != lastPercent {
                lastPercent = percent
                emit(.progress(.copy, Double(percent) * 0.94,
                               "Copying Home Assistant OS image: \(ByteFormat.grouped(copied)) of \(ByteFormat.grouped(size)) bytes."))
            }
        }
        guard copied == size else {
            throw CreatorError("The Home Assistant OS image changed while it was being copied.")
        }
        flush(output)
    }

    private func freeSpace(_ path: String) -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}

/// Sector access to the open raw USB device, used for the GPT fix-up.
struct RawDevice: BlockDevice {
    let fd: Int32

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
        defer { buffer.deallocate() }
        var done = 0
        while done < count {
            let result = pread(fd, buffer + done, count - done, off_t(offset + Int64(done)))
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError("Could not read the USB drive")
            }
            if result == 0 {
                throw CreatorError("Could not read the USB drive: unexpected end of disk.")
            }
            done += result
        }
        return Array(UnsafeRawBufferPointer(start: buffer, count: count))
    }

    func write(_ bytes: [UInt8], offset: Int64) throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 4096)
        defer { buffer.deallocate() }
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        try writeFully(fd, buffer, bytes.count, offset: offset, path: "the USB drive")
    }
}

private func readFully(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
    var total = 0
    while total < count {
        let result = Darwin.read(descriptor, buffer + total, count - total)
        if result < 0 {
            if errno == EINTR { continue }
            throw posixError("Read failed")
        }
        if result == 0 { break }
        total += result
    }
    return total
}

private func writeFully(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int,
                        offset: Int64, path: String) throws {
    var done = 0
    while done < count {
        let result = pwrite(descriptor, buffer + done, count - done, off_t(offset + Int64(done)))
        if result < 0 {
            if errno == EINTR { continue }
            throw posixError("Write to \(path) failed")
        }
        if result == 0 {
            throw CreatorError("Write to \(path) failed: 0 bytes written.")
        }
        done += result
    }
}

private func posixError(_ action: String) -> CreatorError {
    CreatorError("\(action): \(String(cString: strerror(errno)))")
}

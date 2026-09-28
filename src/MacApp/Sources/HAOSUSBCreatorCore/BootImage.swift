import Foundation

public struct BootImage: Equatable {
    public let url: URL
    public let sha256: String?
    public let sizeBytes: Int64
}

/// Finds the HAOS AIO installer boot image built by `src/InstallerLinux/build`.
public enum BootImageLocator {
    public static let fileName = "haos-installer-x86_64.img"

    public static func searchDirectories(bundle: Bundle = .main) -> [URL] {
        var directories: [URL] = []
        if let resources = bundle.resourceURL {
            directories.append(resources.appendingPathComponent("BootImage", isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directories.append(support.appendingPathComponent("HAOS-USB-Creator/BootImages", isDirectory: true))
        if let repository = repositoryRoot(startingAt: bundle.bundleURL) {
            directories.append(repository.appendingPathComponent("artifacts/installer-linux", isDirectory: true))
            directories.append(repository.appendingPathComponent("src/InstallerLinux/build/out", isDirectory: true))
        }
        return directories
    }

    /// Newest `haos-installer*.img` in the first directory that has one.
    public static func findLatest(in directories: [URL]) -> BootImage? {
        let fileManager = FileManager.default
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            let candidates = names
                .filter { $0.hasPrefix("haos-installer") && $0.hasSuffix(".img") }
                .map { directory.appendingPathComponent($0) }
                .compactMap { url -> (URL, Date, Int64)? in
                    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
                        return nil
                    }
                    return (url, attributes[.modificationDate] as? Date ?? .distantPast, size)
                }
                .sorted { $0.1 > $1.1 }
            if let newest = candidates.first {
                return BootImage(url: newest.0, sha256: expectedSha256(for: newest.0), sizeBytes: newest.2)
            }
        }
        return nil
    }

    /// First token of `<image>.sha256`, if it is a SHA-256 hex digest.
    public static func expectedSha256(for image: URL) -> String? {
        let checksum = URL(fileURLWithPath: image.path + ".sha256")
        guard let text = try? String(contentsOf: checksum, encoding: .ascii),
              let token = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              isSHA256Hex(token) else {
            return nil
        }
        return token.lowercased()
    }

    static func repositoryRoot(startingAt url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            let marker = current.appendingPathComponent("src/InstallerLinux/build").path
            if FileManager.default.fileExists(atPath: marker) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}

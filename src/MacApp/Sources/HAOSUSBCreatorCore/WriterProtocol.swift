import Foundation

/// Everything the privileged writer needs. The app writes it to a private work folder.
public struct WriteRequest: Codable, Equatable {
    public var disk: String
    public var sizeBytes: Int64
    public var model: String?
    public var bootImage: String
    public var bootImageSha256: String
    public var workDirectory: String
    public var unattended: Bool
    public var legacyBios: Bool
    public var sshPassword: String

    public init(disk: String, sizeBytes: Int64, model: String?, bootImage: String, bootImageSha256: String,
                workDirectory: String, unattended: Bool, legacyBios: Bool, sshPassword: String) {
        self.disk = disk
        self.sizeBytes = sizeBytes
        self.model = model
        self.bootImage = bootImage
        self.bootImageSha256 = bootImageSha256
        self.workDirectory = workDirectory
        self.unattended = unattended
        self.legacyBios = legacyBios
        self.sshPassword = sshPassword
    }
}

/// Written by the app once the HAOS download finished or was skipped. The writer waits for it
/// after the boot image is on the USB, so the download runs while the boot image is written.
public struct PayloadHandoff: Codable, Equatable {
    public var payload: String?
    public var release: HaosRelease?

    public init(payload: String?, release: HaosRelease?) {
        self.payload = payload
        self.release = release
    }

    public static let fileName = "payload.json"
}

/// `cache/installer-config.json`, read by the booted installer. Same schema as the Windows and Linux apps.
public struct InstallerConfig: Codable, Equatable {
    public struct Unattended: Codable, Equatable {
        public var enabled: Bool
        public var mode: String
        public var runOnce: Bool
    }

    public struct Ssh: Codable, Equatable {
        public var enabled: Bool
        public var password: String
    }

    public struct LegacyBiosBoot: Codable, Equatable {
        public var enabled: Bool
    }

    public var schemaVersion = 1
    public var unattended: Unattended
    public var ssh: Ssh
    public var legacyBiosBoot: LegacyBiosBoot

    public init(unattended: Bool, legacyBios: Bool, sshPassword: String) {
        self.unattended = Unattended(enabled: unattended,
                                     mode: unattended ? "first-available-single-disk" : "disabled",
                                     runOnce: unattended)
        ssh = Ssh(enabled: !sshPassword.isEmpty, password: sshPassword)
        legacyBiosBoot = LegacyBiosBoot(enabled: legacyBios)
    }
}

/// `cache/manifest.json` next to the cached HAOS image.
public struct HaosImageManifest: Codable, Equatable {
    public var schemaVersion = 1
    public var imageType = "haos_generic-x86-64"
    public var version: String
    public var filename: String
    public var sha256: String
    public var sourceUrl: String
    public var downloadedAtUtc: String
    public var createdBy = "HAOS USB Creator for macOS"
    public var fileSizeBytes: Int64

    public init(release: HaosRelease, fileSizeBytes: Int64, downloadedAt: Date = Date()) {
        version = release.version
        filename = release.filename
        sha256 = release.sha256
        sourceUrl = release.url
        downloadedAtUtc = ISO8601DateFormatter().string(from: downloadedAt)
        self.fileSizeBytes = fileSizeBytes
    }
}

public enum JSONFiles {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// One line of writer output. The writer prints these to stdout; the app reads them from a log file.
public enum WriterEvent: Equatable {
    public enum Stage: String {
        case boot
        case copy
    }

    case progress(Stage, Double?, String)
    /// The USB is open for raw writing; the app may start downloading HAOS now.
    case ready
    case error(String)
    case done(payloadCopied: Bool)

    public var line: String {
        switch self {
        case let .progress(stage, percent, message):
            let value = percent.map { String(format: "%.1f", $0) } ?? "-"
            return "PROGRESS \(stage.rawValue) \(value) \(Self.singleLine(message))"
        case .ready:
            return "READY"
        case let .error(message):
            return "ERROR \(Self.singleLine(message))"
        case let .done(payloadCopied):
            return "DONE \(payloadCopied ? 1 : 0)"
        }
    }

    public init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first ?? "" {
        case "READY":
            self = .ready
        case "ERROR":
            self = .error(String(line.dropFirst(6)))
        case "DONE":
            self = .done(payloadCopied: parts.count > 1 && parts[1] == "1")
        case "PROGRESS":
            guard parts.count == 4, let stage = Stage(rawValue: parts[1]) else { return nil }
            self = .progress(stage, parts[2] == "-" ? nil : Double(parts[2]), parts[3])
        default:
            return nil
        }
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}

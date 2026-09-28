import CryptoKit
import Foundation

public struct HaosRelease: Codable, Equatable {
    public let version: String
    public let filename: String
    public let url: String
    public let sha256: String
    public let size: Int64

    public init(version: String, filename: String, url: String, sha256: String, size: Int64) {
        self.version = version
        self.filename = filename
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public enum ReleaseService {
    public static let latestURL = URL(string: "https://api.github.com/repos/home-assistant/operating-system/releases/latest")!
    public static let downloadPrefix = "https://github.com/home-assistant/operating-system/releases/download/"
    public static let userAgent = "HAOS-USB-Creator-macOS"
    private static let imageName = try! NSRegularExpression(pattern: "^haos_generic-x86-64-([A-Za-z0-9._-]+)\\.img\\.xz$")

    /// The version part of `haos_generic-x86-64-<version>.img.xz`, or nil for any other file name.
    public static func imageVersion(_ filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = imageName.firstMatch(in: filename, range: range),
              let version = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        return String(filename[version])
    }

    public static func isOfficialDownload(_ url: String) -> Bool {
        url.hasPrefix(downloadPrefix)
    }

    /// Picks the generic x86-64 image with a GitHub SHA-256 digest from a release response.
    public static func parse(_ data: Data) throws -> HaosRelease {
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreatorError("GitHub returned an empty release response.")
        }
        for asset in release["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String,
                  let version = imageVersion(name),
                  let digest = asset["digest"] as? String,
                  digest.lowercased().hasPrefix("sha256:"),
                  isSHA256Hex(String(digest.dropFirst(7))) else {
                continue
            }
            let url = asset["browser_download_url"] as? String ?? ""
            guard isOfficialDownload(url) else {
                throw CreatorError("Unexpected Home Assistant OS download URL.")
            }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            return HaosRelease(version: version, filename: name, url: url,
                               sha256: String(digest.dropFirst(7)).lowercased(), size: size)
        }
        throw CreatorError("The latest HAOS release has no verified generic x86-64 image.")
    }

    public static func latest() async throws -> HaosRelease {
        var request = URLRequest(url: latestURL, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CreatorError("GitHub returned HTTP \(http.statusCode).")
        }
        return try parse(data)
    }
}

public enum FileHash {
    /// SHA-256 as lowercase hex. `progress` gets (bytes read, total bytes) once per percent.
    public static func sha256(of url: URL, progress: ((Int64, Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var hasher = SHA256()
        var done: Int64 = 0
        var lastPercent = -1
        while true {
            let chunk: Data = try autoreleasepool { try handle.read(upToCount: 4 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            if let progress, total > 0 {
                let percent = Int(done * 100 / total)
                if percent != lastPercent {
                    lastPercent = percent
                    progress(done, total)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ url: URL, expected: String, progress: ((Int64, Int64) -> Void)? = nil) throws {
        let actual = try sha256(of: url, progress: progress)
        guard actual == expected.lowercased() else {
            throw CreatorError("SHA-256 verification failed. Expected \(expected.lowercased()), got \(actual).")
        }
    }
}

/// Downloads and caches the official HAOS image in ~/Library/Caches, verified against the release digest.
public enum HaosImageCache {
    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAOS-USB-Creator/HaosCache", isDirectory: true)
    }

    public static func prepare(_ release: HaosRelease,
                               progress: @escaping (String, Double?) -> Void) async throws -> URL {
        guard ReleaseService.imageVersion(release.filename) != nil, let remote = URL(string: release.url),
              ReleaseService.isOfficialDownload(release.url) else {
            throw CreatorError("Unexpected Home Assistant OS download URL.")
        }
        let fileManager = FileManager.default
        let folder = directory
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent(release.filename)
        let checksum = folder.appendingPathComponent(release.filename + ".sha256")

        if fileManager.fileExists(atPath: image.path) {
            progress("Existing Home Assistant OS image found. Checking it now.", 0)
            do {
                try await verify(image, release, progress)
                try writeChecksum(checksum, release)
                progress("Existing Home Assistant OS image is ready.", 100)
                return image
            } catch {
                try? fileManager.removeItem(at: image)
            }
        }

        progress("Downloading \(release.filename).", 0)
        let partial = folder.appendingPathComponent(release.filename + ".download")
        defer { try? fileManager.removeItem(at: partial) }
        try await Downloader.download(remote, to: partial, expectedSize: release.size) { done, total in
            // Stay below 100 so the step is only marked done once the image is verified.
            progress("Downloaded \(ByteFormat.grouped(done)) of \(ByteFormat.grouped(total)) bytes.",
                     min(99.9, Double(done) * 100 / Double(total)))
        }
        let size = (try fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard release.size <= 0 || size == release.size else {
            throw CreatorError("Downloaded Home Assistant OS image failed size verification.")
        }
        try? fileManager.removeItem(at: image)
        try fileManager.moveItem(at: partial, to: image)
        do {
            try await verify(image, release, progress)
        } catch {
            try? fileManager.removeItem(at: image)
            throw error
        }
        try writeChecksum(checksum, release)
        progress("Home Assistant OS image downloaded and verified.", 100)
        return image
    }

    static func verify(_ image: URL, _ release: HaosRelease,
                       _ progress: @escaping (String, Double?) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileHash.verify(image, expected: release.sha256) { done, total in
                progress("Verifying image hash: \(ByteFormat.grouped(done)) of \(ByteFormat.grouped(total)) bytes.",
                         Double(done) * 100 / Double(total))
            }
        }.value
    }

    static func writeChecksum(_ url: URL, _ release: HaosRelease) throws {
        try "\(release.sha256)  \(release.filename)\n".write(to: url, atomically: true, encoding: .utf8)
    }
}

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedSize: Int64
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastPercent = -1

    private init(destination: URL, expectedSize: Int64, onProgress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, expectedSize: Int64,
                         progress: @escaping (Int64, Int64) -> Void) async throws {
        let delegate = Downloader(destination: destination, expectedSize: expectedSize, onProgress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(ReleaseService.userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    delegate.continuation = continuation
                    session.downloadTask(with: request).resume()
                }
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / total)
        if percent != lastPercent {
            lastPercent = percent
            onProgress(totalBytesWritten, total)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw CreatorError("Download failed with HTTP \(http.statusCode).")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = error ?? finishError {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

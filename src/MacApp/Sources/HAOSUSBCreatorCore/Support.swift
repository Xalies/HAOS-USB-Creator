import Foundation

public struct CreatorError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ByteFormat {
    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let gibFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter
    }()

    /// Matches the Windows app's `N0` format, e.g. "1,234,567".
    public static func grouped(_ value: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Matches the Windows app's `0.## GiB` format.
    public static func gib(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Unknown size" }
        let value = Double(bytes) / 1_073_741_824
        return "\(gibFormatter.string(from: NSNumber(value: value)) ?? String(value)) GiB"
    }
}

public func isSHA256Hex(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
}

public enum Shell {
    /// Runs a tool and returns its standard output. Throws with the tool's error output on failure.
    @discardableResult
    public static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Read stderr on another thread so neither pipe can fill up and block the tool.
        let errorOutput = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorOutput.data = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorOutput.data
            let text = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (path as NSString).lastPathComponent
            throw CreatorError("\(name) failed: \(text.isEmpty ? "exit status \(process.terminationStatus)" : text)")
        }
        return data
    }
}

/// Holds data written by another thread; access is ordered by a DispatchGroup.
private final class OutputBox {
    var data = Data()
}

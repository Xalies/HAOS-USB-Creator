import Foundation
import HAOSUSBCreatorCore

/// Starts the writer as the logged-in user and streams its progress lines. The writer asks for
/// the administrator password itself when it opens the USB device (see `RawDiskAccess`). It is a
/// direct child of the app so that macOS applies the app's "Removable Volumes" permission to it.
enum WriterRunner {
    static func run(writer: String, request: URL, log: URL) -> AsyncThrowingStream<WriterEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: writer)
            process.arguments = ["--write", request.path]
            process.standardInput = FileHandle.nullDevice
            do {
                let output = try FileHandle(forWritingTo: log)
                process.standardOutput = output
                process.standardError = output
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let reader = LogReader(url: log) { continuation.yield($0) }
            let timer = DispatchSource.makeTimerSource(queue: reader.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { reader.poll() }

            process.terminationHandler = { process in
                reader.queue.async {
                    timer.cancel()
                    reader.poll(final: true)
                    if process.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        let message = reader.lastUnparsedLine ?? ""
                        continuation.finish(throwing: CreatorError(message.isEmpty ? UiText.errorWriteFailed : message))
                    }
                }
            }

            // A dispatch source must not be released while suspended, so resume it before anything can fail.
            timer.resume()
            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Reads new lines from the writer log. Only used on `queue`.
private final class LogReader {
    let queue = DispatchQueue(label: "HAOSUSBCreator.writer-log")
    private let url: URL
    private let onEvent: (WriterEvent) -> Void
    private var offset: UInt64 = 0
    private var pending = Data()
    /// Last line that was not a writer event, e.g. a crash message. Used as error text.
    private(set) var lastUnparsedLine: String?

    init(url: URL, onEvent: @escaping (WriterEvent) -> Void) {
        self.url = url
        self.onEvent = onEvent
    }

    func poll(final: Bool = false) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: offset)
        } catch {
            return
        }
        let data = file.readDataToEndOfFile()
        offset += UInt64(data.count)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending = Data(pending[pending.index(after: newline)...])
            deliver(line)
        }
        if final && !pending.isEmpty {
            deliver(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
    }

    private func deliver(_ line: String) {
        if let event = WriterEvent(line: line) {
            onEvent(event)
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            lastUnparsedLine = line
        }
    }
}

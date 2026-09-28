import AppKit
import Foundation
import HAOSUSBCreatorCore

enum InstallerStep {
    case welcome
    case drive
    case confirm
    case write
    case finish
}

enum CardID: CaseIterable {
    case prepare
    case boot
    case download
    case copy
}

struct WriteCard: Equatable {
    enum Phase {
        case waiting
        case working
        case done
        case blocked
    }

    var phase: Phase = .waiting
    /// Waiting cards are dimmed except the first one, like in the Windows app.
    var isActive = false
    var status: String
    var percent: Double = 0
}

/// State of the wizard. Mirrors `MainWindow.xaml.cs` of the Windows app. Only used on the main thread.
final class CreatorModel: ObservableObject {
    static let shared = CreatorModel()

    @Published var step: InstallerStep = .welcome
    @Published private(set) var drives: [UsbDrive] = []
    @Published var selectedDriveID: String?
    @Published private(set) var isScanning = false
    @Published private(set) var driveMessage: String?

    @Published var eraseConfirmed = false
    @Published var unattended = false {
        didSet { if !unattended { unattendedConfirmed = false } }
    }
    @Published var unattendedConfirmed = false
    @Published var sshEnabled = false {
        didSet { if !sshEnabled { sshPassword = "" } }
    }
    @Published var sshPassword = ""
    @Published var legacyBios = false

    @Published private(set) var cards: [CardID: WriteCard] = [:]
    @Published private(set) var writeError: String?
    @Published private(set) var isWriting = false
    @Published private(set) var finishSummary = UiText.finishSummaryDefault
    @Published private(set) var finishNextStep = UiText.finishNextStepAttended
    @Published var alertMessage: String?

    private var latestRelease: HaosRelease?

    private init() {
        resetCards()
    }

    var selectedDrive: UsbDrive? {
        drives.first { $0.id == selectedDriveID }
    }

    var canStartWrite: Bool {
        eraseConfirmed
            && (!unattended || unattendedConfirmed)
            && (!sshEnabled || sshPassword.count >= 8)
            && !isWriting
    }

    func card(_ id: CardID) -> WriteCard {
        cards[id] ?? WriteCard(status: "")
    }

    // MARK: - Navigation

    @MainActor
    func getStarted() async {
        step = .drive
        await refreshDrives()
    }

    @MainActor
    func refreshDrives() async {
        isScanning = true
        drives = []
        selectedDriveID = nil
        driveMessage = nil
        do {
            let found = try await Task.detached(priority: .userInitiated) { try DiskUtil.removableDrives() }.value
            drives = found
            driveMessage = found.isEmpty ? UiText.driveEmpty : nil
        } catch {
            driveMessage = String(format: UiText.errorScanUsbFormat, error.localizedDescription)
        }
        isScanning = false
    }

    func continueFromDrive() {
        guard selectedDrive != nil else {
            alertMessage = UiText.errorSelectUsbDrive
            return
        }
        guard BootImageLocator.findLatest(in: BootImageLocator.searchDirectories()) != nil else {
            alertMessage = UiText.errorBootImageNotFound
            return
        }
        step = .confirm
    }

    var driveStatusText: String {
        guard let drive = selectedDrive else { return UiText.driveStatusReady }
        if drive.isHaosInstaller { return UiText.driveStatusExistingHaos }
        if drive.showWindowsLayoutWarning { return UiText.driveStatusWindowsLayout }
        return UiText.driveStatusReady
    }

    func startOver() {
        eraseConfirmed = false
        unattended = false
        unattendedConfirmed = false
        legacyBios = false
        sshEnabled = false
        sshPassword = ""
        resetCards()
        step = .welcome
    }

    // MARK: - Writing

    @MainActor
    func startWrite() async {
        guard let drive = selectedDrive, canStartWrite else { return }
        let password = sshEnabled ? sshPassword : ""
        isWriting = true
        resetCards()
        step = .write
        var workDirectory: URL?

        do {
            report(.prepare, UiText.progressPrepareInstaller, 0)
            guard let bootImage = BootImageLocator.findLatest(in: BootImageLocator.searchDirectories()) else {
                throw CreatorError(UiText.errorBootImageNotFound)
            }
            guard let bootSha256 = bootImage.sha256 else {
                throw CreatorError(UiText.errorBootImageChecksum)
            }
            try await Task.detached(priority: .userInitiated) {
                try FileHash.verify(bootImage.url, expected: bootSha256) { done, total in
                    DispatchQueue.main.async {
                        self.report(.prepare,
                                    "Verifying image hash: \(ByteFormat.grouped(done)) of \(ByteFormat.grouped(total)) bytes.",
                                    nil)
                    }
                }
            }.value
            report(.prepare, UiText.progressInstallerReady, 100)
            report(.download, UiText.progressWaitingForUsb, 0)

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("HAOS-USB-Creator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            workDirectory = work
            let requestFile = work.appendingPathComponent("request.json")
            let logFile = work.appendingPathComponent("writer.log")
            let request = WriteRequest(disk: drive.identifier, sizeBytes: drive.sizeBytes, model: drive.model,
                                       bootImage: bootImage.url.path, bootImageSha256: bootSha256,
                                       workDirectory: work.path, unattended: unattended,
                                       legacyBios: legacyBios, sshPassword: password)
            try JSONFiles.encode(request).write(to: requestFile, options: .atomic)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)

            var downloadTask: Task<Void, Never>?
            var payloadCopied: Bool?
            var writerError: String?
            do {
                for try await event in WriterRunner.run(writer: writerPath, request: requestFile, log: logFile) {
                    switch event {
                    case .ready:
                        // Download while the boot image is written, as the Windows app does.
                        if downloadTask == nil {
                            downloadTask = Task { @MainActor in await self.preparePayload(in: work) }
                        }
                    case let .progress(stage, percent, message):
                        report(stage == .boot ? .boot : .copy, message, percent)
                    case let .error(message):
                        writerError = message
                    case let .done(copied):
                        payloadCopied = copied
                    }
                }
            } catch {
                downloadTask?.cancel()
                if let writerError {
                    throw CreatorError(writerError)
                }
                throw error
            }
            downloadTask?.cancel()
            guard let copied = payloadCopied else {
                throw CreatorError(writerError ?? UiText.errorWriteFailed)
            }
            configureFinishText(hasCachedPayload: copied, sshPassword: password)
            step = .finish
        } catch {
            showWriteError(error.localizedDescription)
        }

        // The work folder holds the SSH password; remove it as soon as the writer is done.
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        isWriting = false
    }

    /// Downloads HAOS and tells the writer where it is. A failed download is not fatal:
    /// the booted installer downloads HAOS itself when it has internet access.
    @MainActor
    private func preparePayload(in work: URL) async {
        var handoff = PayloadHandoff(payload: nil, release: nil)
        do {
            reportDownload(UiText.progressCheckingLatestHaos, 0)
            let release: HaosRelease
            if let cached = latestRelease {
                release = cached
            } else {
                release = try await ReleaseService.latest()
                latestRelease = release
            }
            reportDownload(String(format: UiText.progressLatestImageFormat, release.filename), 0)
            let image = try await HaosImageCache.prepare(release) { message, percent in
                DispatchQueue.main.async { self.reportDownload(message, percent) }
            }
            reportDownload(UiText.progressHaosReady, 100)
            handoff = PayloadHandoff(payload: image.path, release: release)
        } catch {
            if Task.isCancelled { return }
            reportDownload(String(format: UiText.progressSkippedFormat, error.localizedDescription), 0)
        }
        try? JSONFiles.encode(handoff).write(to: work.appendingPathComponent(PayloadHandoff.fileName), options: .atomic)
    }

    private var writerPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("HAOSUSBWriter").path
    }

    // MARK: - Progress cards

    private func resetCards() {
        writeError = nil
        cards = [
            .prepare: WriteCard(isActive: true, status: UiText.writePrepareInitial),
            .boot: WriteCard(status: UiText.writeBootInitial),
            .download: WriteCard(status: UiText.writeDownloadInitial),
            .copy: WriteCard(status: UiText.writeCopyInitial),
        ]
    }

    private func report(_ id: CardID, _ message: String, _ percent: Double?) {
        var card = self.card(id)
        card.isActive = true
        if card.phase != .done {
            card.phase = .working
        }
        card.status = message
        if let percent {
            card.percent = min(max(percent, 0), 100)
            if card.percent >= 100 {
                card.phase = .done
            }
        }
        cards[id] = card
    }

    private func reportDownload(_ message: String, _ percent: Double?) {
        if message.hasPrefix(UiText.progressVerifyingPrefix) {
            report(.download, UiText.progressVerifyingHaos, percent)
        } else if let release = latestRelease, !message.contains(release.filename) {
            report(.download, "\(message) (\(release.filename))", percent)
        } else {
            report(.download, message, percent)
        }
    }

    private func showWriteError(_ message: String) {
        writeError = message
        var copy = card(.copy)
        copy.isActive = true
        copy.phase = .blocked
        cards[.copy] = copy
    }

    private func configureFinishText(hasCachedPayload: Bool, sshPassword: String) {
        finishSummary = hasCachedPayload ? UiText.finishSummaryWithPayload : UiText.finishSummaryNoPayload
        var next = unattended ? UiText.finishNextStepUnattended : UiText.finishNextStepAttended
        if legacyBios {
            next += "\n\n" + UiText.finishLegacyBiosNote
        }
        if !sshPassword.isEmpty {
            next += "\n\n" + String(format: UiText.finishSshAccessFormat, sshPassword)
        }
        finishNextStep = next
    }
}

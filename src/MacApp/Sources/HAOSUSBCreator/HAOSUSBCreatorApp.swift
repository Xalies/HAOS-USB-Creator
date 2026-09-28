import AppKit
import SwiftUI

@main
struct HAOSUSBCreatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CreatorModel.shared

    var body: some Scene {
        Window(UiText.appTitle, id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 860, height: 625)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CreatorModel.shared.isWriting else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UiText.quitWhileWritingTitle
        alert.informativeText = UiText.quitWhileWritingText
        alert.runModal()
        return .terminateCancel
    }
}

/// Disables the window's close button (and with it ⌘W) while the USB is being written.
struct CloseButtonLock: NSViewRepresentable {
    let locked: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let locked = locked
        DispatchQueue.main.async {
            view.window?.standardWindowButton(.closeButton)?.isEnabled = !locked
        }
    }
}

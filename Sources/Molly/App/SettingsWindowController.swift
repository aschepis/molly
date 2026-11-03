import AppKit
import SwiftUI

/// One Settings window for the life of the process. Closing hides it; the
/// model survives so unsaved edits are still there when it reopens.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show(model: SettingsModel) {
        let controller: SettingsWindowController
        if let existing = shared, existing.model === model {
            controller = existing
        } else {
            controller = SettingsWindowController(model: model)
            shared = controller
        }
        controller.present()
    }

    private let model: SettingsModel

    private init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Molly Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Accessory apps have no Dock icon, so the window must pull the app
    /// forward itself or it opens behind whatever is frontmost.
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

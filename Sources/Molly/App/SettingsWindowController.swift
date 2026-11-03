import AppKit
import SwiftUI

/// One Settings window for the life of the process. Closing hides it; the
/// model survives so unsaved edits are still there when it reopens.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Fixed so screenshots from scripts/snap-settings.sh are comparable.
    static let defaultSize = NSSize(width: 720, height: 520)

    static func close() { shared?.window?.orderOut(nil) }

    /// Renders the window in-process; screencapture needs Screen Recording
    /// permission for the calling terminal, this does not.
    static func snapshot(to path: String) {
        guard let frame = shared?.window?.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.error("settings snapshot failed: \(error)")
        }
    }

    static func show(model: SettingsModel, tab: SettingsTab? = nil) {
        if let tab { model.selectedTab = tab }
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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Molly Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
        window.setContentSize(Self.defaultSize)
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

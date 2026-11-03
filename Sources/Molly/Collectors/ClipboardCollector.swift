import AppKit
import Foundation

// MARK: - Pure classification (unit-tested)

enum ClipboardContentType: String, CaseIterable {
    case text, image, file, url, other

    /// Picks the most specific type among the pasteboard's declared types.
    /// Files beat URLs beat images beat text so a copied file is "file" even
    /// though Finder also declares a string representation.
    static func classify(_ types: [NSPasteboard.PasteboardType]) -> ClipboardContentType {
        let raw = Set(types.map { $0.rawValue })
        if raw.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .file }
        if raw.contains(NSPasteboard.PasteboardType.URL.rawValue) { return .url }
        if raw.contains(NSPasteboard.PasteboardType.png.rawValue) || raw.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return .image }
        if raw.contains(NSPasteboard.PasteboardType.string.rawValue) || raw.contains(NSPasteboard.PasteboardType.rtf.rawValue) { return .text }
        return .other
    }
}

// MARK: - Collector

/// How often the clipboard changes and what kind of thing landed on it.
/// Invariant: content is never read. Only `changeCount`, declared types,
/// and the byte length of the detected representation are consulted.
final class ClipboardCollector: Collector {
    let name = "clipboard"
    let interval: TimeInterval

    private var lastChangeCount: Int?
    private var changes: Counter?
    private var lastChange: Gauge?
    private var contentBytes: Gauge?

    init(settings: CollectorSettings) {
        interval = settings.interval(default: 2)
    }

    func start(registry r: MetricsRegistry) throws {
        changes = r.counter("molly_clipboard_changes_total", help: "Clipboard changes by content type. Contents are never read.", labels: ["type"])
        lastChange = r.gauge("molly_clipboard_last_change_timestamp_seconds", help: "Unix time of the last clipboard change.")
        contentBytes = r.gauge("molly_clipboard_content_bytes", help: "Byte length of the last copied item's primary representation.")
        for t in ClipboardContentType.allCases { changes?.touch(labels: ["type": t.rawValue]) }
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func collect() throws {
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let type = ClipboardContentType.classify(board.types ?? [])
        changes?.inc(labels: ["type": type.rawValue])
        lastChange?.set(Date().timeIntervalSince1970)
        contentBytes?.set(Double(ClipboardCollector.byteLength(of: type, on: board)))
    }

    /// Length only. `data(forType:)` returns the bytes but they are dropped
    /// immediately after `count` is taken.
    private static func byteLength(of type: ClipboardContentType, on board: NSPasteboard) -> Int {
        let candidates: [NSPasteboard.PasteboardType]
        switch type {
        case .file: candidates = [.fileURL]
        case .url: candidates = [.URL]
        case .image: candidates = [.png, .tiff]
        case .text: candidates = [.string, .rtf]
        case .other: candidates = board.types ?? []
        }
        for candidate in candidates {
            if let data = board.data(forType: candidate) { return data.count }
        }
        return 0
    }
}

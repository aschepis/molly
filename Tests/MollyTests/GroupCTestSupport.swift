import XCTest
@testable import Molly

/// Shared fixtures for the Group C collector tests.
class TempFolderTestCase: XCTestCase {
    func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("molly-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func settings(_ name: String, _ raw: [String: JSONValue] = [:]) -> CollectorSettings {
        CollectorSettings(name: name, raw: raw)
    }

    func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    /// First sample of `name` whose rendered labels contain every given pair.
    func value(_ registry: MetricsRegistry, _ name: String, _ labels: [String: String] = [:]) -> Double? {
        for line in registry.render().split(separator: "\n") where line.hasPrefix(name + "{") || line.hasPrefix(name + " ") {
            if labels.allSatisfy({ line.contains("\($0.key)=\"\($0.value)\"") }) {
                return line.split(separator: " ").last.flatMap { Double($0) }
            }
        }
        return nil
    }

    func append(_ text: String, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    func backdate(_ url: URL, by seconds: TimeInterval = 86400) throws {
        let old = Date().addingTimeInterval(-seconds)
        // Creation first: setting it can move mtime, so mtime is set last.
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
}

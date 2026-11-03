import Foundation

/// Epoch conversions for the databases Molly reads.
enum CocoaTime {
    /// Seconds between 1970-01-01 and 2001-01-01 (Apple's reference date).
    static let cocoaOffset: Double = 978_307_200
    /// Seconds between 1601-01-01 and 1970-01-01 (Chromium/WebKit timestamps).
    static let webKitOffset: Double = 11_644_473_600

    static func date(cocoaSeconds: Double) -> Date {
        Date(timeIntervalSince1970: cocoaSeconds + cocoaOffset)
    }

    /// Messages stores dates as nanoseconds since 2001 on modern macOS.
    static func date(cocoaNanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(cocoaNanoseconds) / 1e9 + cocoaOffset)
    }

    static func date(webKitMicroseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(webKitMicroseconds) / 1e6 - webKitOffset)
    }

    static func cocoaSeconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 - cocoaOffset
    }

    static func cocoaNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - cocoaOffset) * 1e9)
    }

    static func webKitMicroseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + webKitOffset) * 1e6)
    }
}

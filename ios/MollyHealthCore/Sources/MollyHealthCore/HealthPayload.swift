import Foundation

public enum PayloadLimits {
    /// The Mac answers 413 above this size.
    public static let maxBodyBytes = 64 * 1024
}

public enum PayloadError: Error, Equatable {
    case tooLarge(Int)
    case encoding
}

public enum DayKey {
    /// "YYYY-MM-DD" in the calendar's time zone, the key the Mac files a day under.
    public static func string(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func window(for date: Date, calendar: Calendar) -> DayWindow {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DayWindow(start: start, end: end)
    }
}

/// The body of `POST /health` in its daily-totals form.
public struct HealthPayload: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case number(Double)
        case text(String)
    }

    public let device: String
    public let date: String
    public let totals: [String: Value]

    public init(device: String, date: String, totals: [String: Value]) {
        self.device = device
        self.date = date
        self.totals = totals
    }

    /// Timestamps are written with the calendar's UTC offset; non-finite numbers are dropped.
    public static func make(device: String, date: String, totals: [MollyHealthType: TotalValue], calendar: Calendar) -> HealthPayload {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = calendar.timeZone
        var values: [String: Value] = [:]
        for (type, total) in totals {
            switch total {
            case .number(let n) where n.isFinite: values[type.rawValue] = .number(n)
            case .number: continue
            case .timestamp(let d): values[type.rawValue] = .text(formatter.string(from: d))
            }
        }
        return HealthPayload(device: device, date: date, totals: values)
    }

    public func encoded() throws -> Data {
        var totalsObject: [String: Any] = [:]
        for (key, value) in totals {
            switch value {
            case .number(let n): totalsObject[key] = n
            case .text(let s): totalsObject[key] = s
            }
        }
        let object: [String: Any] = ["device": device, "date": date, "totals": totalsObject]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { throw PayloadError.encoding }
        guard data.count <= PayloadLimits.maxBodyBytes else { throw PayloadError.tooLarge(data.count) }
        return data
    }
}

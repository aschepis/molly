import Foundation

/// Every Apple Health quantity Molly accepts, whether posted by the iPhone
/// Shortcut or read from an export. The raw value is the `type` string in a
/// payload and the `type` label on the metrics.
enum HealthType: String, CaseIterable {
    case steps
    case standHours = "stand_hours"
    case activeEnergyKcal = "active_energy_kcal"
    case exerciseMinutes = "exercise_minutes"
    case restingHeartRateBpm = "resting_heart_rate_bpm"
    case heartRateBpm = "heart_rate_bpm"
    case hrvMs = "hrv_ms"
    case sleepMinutes = "sleep_minutes"
    case sleepInBedMinutes = "sleep_in_bed_minutes"
    case bedtime
    case wakeTime = "wake_time"
    case walkingDistanceM = "walking_distance_m"
    case flightsClimbed = "flights_climbed"
    case daylightMinutes = "daylight_minutes"
    case headphoneAudioDb = "headphone_audio_db"
    case vo2max
    case bodyMassKg = "body_mass_kg"
    case respiratoryRate = "respiratory_rate"
    case bloodOxygenRatio = "blood_oxygen_ratio"
    case wristTemperatureDeltaC = "wrist_temperature_delta_c"
    case mindfulMinutes = "mindful_minutes"

    /// How samples of one local day combine into the day's value.
    enum Aggregation {
        case sum
        case latest
        case maximum
    }

    var aggregation: Aggregation {
        switch self {
        case .steps, .standHours, .activeEnergyKcal, .exerciseMinutes, .sleepMinutes, .sleepInBedMinutes,
             .walkingDistanceM, .flightsClimbed, .daylightMinutes, .mindfulMinutes:
            return .sum
        case .headphoneAudioDb:
            return .maximum
        default:
            return .latest
        }
    }

    /// Bedtime and wake time are clock times, stored as seconds since local midnight.
    var isTimeOfDay: Bool { self == .bedtime || self == .wakeTime }

    /// A night's sleep belongs to the day you wake up.
    var belongsToEndDay: Bool { self == .sleepMinutes || self == .sleepInBedMinutes }

    private var isSigned: Bool { self == .wristTemperatureDeltaC }

    private var isMinutes: Bool {
        switch self {
        case .exerciseMinutes, .sleepMinutes, .sleepInBedMinutes, .daylightMinutes, .mindfulMinutes: return true
        default: return false
        }
    }

    /// Converts a posted value to the type's canonical unit. Unknown units are
    /// taken as canonical; nil means the value is unusable.
    func normalize(_ value: Double, unit: String = "") -> Double? {
        guard value.isFinite, abs(value) <= HealthLimits.maxAbsoluteValue else { return nil }
        guard isSigned || value >= 0 else { return nil }
        let unit = unit.trimmingCharacters(in: .whitespaces).lowercased()
        var converted = value
        if isMinutes {
            if ["s", "sec", "second", "seconds"].contains(unit) { converted = value / 60 }
            if ["h", "hr", "hour", "hours"].contains(unit) { converted = value * 60 }
        }
        switch self {
        case .activeEnergyKcal:
            if unit == "kj" { converted = value / HealthLimits.kilojoulesPerKcal }
        case .walkingDistanceM:
            if unit == "km" { converted = value * 1000 }
            if unit == "mi" { converted = value * HealthLimits.metersPerMile }
        case .bodyMassKg:
            if unit == "lb" { converted = value * HealthLimits.kilogramsPerPound }
            if unit == "g" { converted = value / 1000 }
        case .wristTemperatureDeltaC:
            if unit == "degf" || unit == "°f" || unit == "f" { converted = value * 5 / 9 }
        case .hrvMs:
            if unit == "s" { converted = value * 1000 }
        case .bloodOxygenRatio:
            // Shortcuts reports a percentage; the export reports a ratio.
            if converted > 1 { converted /= 100 }
            guard converted <= 1 else { return nil }
        default:
            break
        }
        return converted
    }
}

enum HealthLimits {
    static let maxAbsoluteValue = 1e9
    static let kilojoulesPerKcal = 4.184
    static let metersPerMile = 1609.344
    static let kilogramsPerPound = 0.45359237
    static let secondsPerDay = 86_400.0
    /// A bedtime before this clock time belongs to the previous evening's night.
    static let bedtimeWrapSeconds = 12 * 3600
    /// Samples starting later than this after "now" are clock errors, not data.
    static let futureSlackSeconds = 86_400.0
    static let defaultMaxAgeSeconds = 7 * 86_400.0
    static let maxDevices = 5
    static let maxDeviceLength = 32
    static let otherDevice = "other"
    static let unknownDevice = "unknown"
}

enum HealthRejection: String, CaseIterable, Error {
    case badType = "bad_type"
    case badValue = "bad_value"
    case badTime = "bad_time"
    case tooOld = "too_old"
}

/// One accepted value, already attributed to a local day.
struct HealthSample: Equatable {
    let type: HealthType
    let day: String
    /// When the value was true; decides which of two latest-values wins.
    let at: Date
    /// Identifies the sample so a re-posted one replaces itself instead of adding twice.
    let key: String
    let value: Double
    /// Daily totals (the flat form) overwrite whatever the day held.
    let replacesDay: Bool
}

enum HealthTime {
    private static let internet = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO 8601 with an offset, or a bare local date-time as a fallback.
    static func parse(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = internet.date(from: trimmed) ?? fractional.date(from: trimmed) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: trimmed)
    }

    /// "23:30" or "23:30:15" as seconds since midnight.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let seconds = numbers.count == 3 ? numbers[2] : 0
        guard (0..<24).contains(numbers[0]), (0..<60).contains(numbers[1]), (0..<60).contains(seconds) else { return nil }
        return numbers[0] * 3600 + numbers[1] * 60 + seconds
    }

    static func secondsSinceMidnight(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// Bedtimes after midnight count past 24:00 so 01:15 sorts after 23:30.
    static func bedtimeSeconds(_ secondsSinceMidnight: Int) -> Double {
        let wrapped = secondsSinceMidnight < HealthLimits.bedtimeWrapSeconds
            ? secondsSinceMidnight + Int(HealthLimits.secondsPerDay)
            : secondsSinceMidnight
        return Double(wrapped)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func startOfDay(key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2],
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              dayKey(date, calendar: calendar) == key else { return nil }
        return date
    }

    static func addingDays(_ days: Int, to key: String, calendar: Calendar) -> String? {
        guard let start = startOfDay(key: key, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return dayKey(moved, calendar: calendar)
    }
}

enum HealthDevice {
    /// Free text from the payload becomes a short lowercase label.
    static func sanitize(_ raw: String?) -> String {
        let plain = (raw ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let capped = String(plain.prefix(HealthLimits.maxDeviceLength))
        return capped.isEmpty ? HealthLimits.unknownDevice : capped
    }
}

/// Per-day, per-type aggregates. Additive types keep their samples by key so
/// the Shortcut can safely re-send the same hour.
struct HealthDayValue: Codable, Equatable {
    var parts: [String: Double] = [:]
    var latest: Double?
    var latestAt: Double?
    var maximum: Double?
}

struct HealthDays: Codable, Equatable {
    var days: [String: [String: HealthDayValue]] = [:]

    mutating func apply(_ sample: HealthSample) {
        var entry = days[sample.day]?[sample.type.rawValue] ?? HealthDayValue()
        switch sample.type.aggregation {
        case .sum:
            if sample.replacesDay { entry.parts = [:] }
            entry.parts[sample.key] = sample.value
        case .latest:
            if entry.latestAt == nil || sample.at.timeIntervalSince1970 >= (entry.latestAt ?? 0) {
                entry.latest = sample.value
                entry.latestAt = sample.at.timeIntervalSince1970
            }
        case .maximum:
            entry.maximum = max(entry.maximum ?? sample.value, sample.value)
        }
        days[sample.day, default: [:]][sample.type.rawValue] = entry
    }

    func value(_ type: HealthType, day: String) -> Double? {
        guard let entry = days[day]?[type.rawValue] else { return nil }
        switch type.aggregation {
        case .sum: return entry.parts.isEmpty ? nil : entry.parts.values.reduce(0, +)
        case .latest: return entry.latest
        case .maximum: return entry.maximum
        }
    }

    func hasAny(_ types: [HealthType], day: String) -> Bool {
        types.contains { value($0, day: day) != nil }
    }

    mutating func prune(keeping keep: Set<String>) {
        days = days.filter { keep.contains($0.key) }
    }
}

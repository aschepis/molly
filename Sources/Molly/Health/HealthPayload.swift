import Foundation

/// What a `POST /health` body contained, split into usable samples and
/// counted rejections. A bad sample never fails the whole post.
struct HealthParseResult: Equatable {
    var device: String?
    var samples: [HealthSample] = []
    var rejected: [HealthRejection: Int] = [:]
}

/// Parses both payload shapes:
///   {"device": "...", "samples": [{"type","start","end","value","unit"}]}
///   {"date": "YYYY-MM-DD", "totals": {"steps": 8120, ...}}
struct HealthPayloadParser {
    let now: Date
    let maxAge: TimeInterval
    let calendar: Calendar

    /// nil when the body carries neither `samples` nor `totals`.
    func parse(_ object: [String: JSONValue]) -> HealthParseResult? {
        let samples = object["samples"]?.arrayValue
        let totals = object["totals"]?.objectValue
        guard samples != nil || totals != nil else { return nil }
        var result = HealthParseResult(device: object["device"]?.stringValue)
        for item in samples ?? [] {
            record(sample(item), into: &result)
        }
        if let totals {
            parseTotals(totals, date: object["date"]?.stringValue, into: &result)
        }
        return result
    }

    private func record(_ outcome: Result<HealthSample, HealthRejection>, into result: inout HealthParseResult) {
        switch outcome {
        case .success(let sample): result.samples.append(sample)
        case .failure(let reason): result.rejected[reason, default: 0] += 1
        }
    }

    // MARK: sample form

    private func sample(_ item: JSONValue) -> Result<HealthSample, HealthRejection> {
        guard let object = item.objectValue, let name = object["type"]?.stringValue,
              let type = HealthType(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
        else { return .failure(.badType) }

        var start: Date?
        var end: Date?
        for (key, slot) in [("start", 0), ("end", 1)] {
            guard let raw = object[key], raw != .null else { continue }
            guard let text = raw.stringValue, let date = HealthTime.parse(text, calendar: calendar) else {
                return .failure(.badTime)
            }
            if slot == 0 { start = date } else { end = date }
        }

        if type.isTimeOfDay {
            return clockSample(type, raw: object["value"], reference: start ?? end)
        }
        guard let first = start ?? end else { return .failure(.badTime) }
        let last = end ?? first
        guard last >= first, first <= now.addingTimeInterval(HealthLimits.futureSlackSeconds) else {
            return .failure(.badTime)
        }
        guard last >= now.addingTimeInterval(-maxAge) else { return .failure(.tooOld) }
        guard let value = number(object["value"]),
              let normalized = type.normalize(value, unit: object["unit"]?.stringValue ?? "")
        else { return .failure(.badValue) }

        let attributedTo = type.belongsToEndDay ? last : first
        return .success(HealthSample(
            type: type, day: HealthTime.dayKey(attributedTo, calendar: calendar), at: last,
            key: "\(Int(first.timeIntervalSince1970))-\(Int(last.timeIntervalSince1970))",
            value: normalized, replacesDay: false))
    }

    /// Bedtime and wake time carry an ISO time (or "HH:mm") as `value`;
    /// without one, `start` is the time.
    private func clockSample(_ type: HealthType, raw: JSONValue?, reference: Date?) -> Result<HealthSample, HealthRejection> {
        var moment: Date?
        var seconds: Int?
        switch raw {
        case .some(.string(let text)):
            if let date = HealthTime.parse(text, calendar: calendar) {
                moment = date
                seconds = HealthTime.secondsSinceMidnight(date, calendar: calendar)
            } else if let clock = HealthTime.parseClock(text) {
                moment = reference
                seconds = clock
            } else {
                return .failure(.badValue)
            }
        case .none, .some(.null):
            moment = reference
            seconds = reference.map { HealthTime.secondsSinceMidnight($0, calendar: calendar) }
        default:
            return .failure(.badValue)
        }
        guard let moment, let seconds else { return .failure(.badTime) }
        guard moment >= now.addingTimeInterval(-maxAge) else { return .failure(.tooOld) }
        guard moment <= now.addingTimeInterval(HealthLimits.futureSlackSeconds) else { return .failure(.badTime) }

        // Bedtime 23:30 on the 2nd and 01:15 on the 3rd are both the night ending on the 3rd.
        let dayAnchor = type == .bedtime ? moment.addingTimeInterval(TimeInterval(HealthLimits.bedtimeWrapSeconds)) : moment
        return .success(HealthSample(
            type: type, day: HealthTime.dayKey(dayAnchor, calendar: calendar), at: moment, key: "clock",
            value: clockValue(type, seconds), replacesDay: false))
    }

    private func clockValue(_ type: HealthType, _ seconds: Int) -> Double {
        type == .bedtime ? HealthTime.bedtimeSeconds(seconds) : Double(seconds)
    }

    // MARK: totals form

    private func parseTotals(_ totals: [String: JSONValue], date: String?, into result: inout HealthParseResult) {
        let dayKey = date ?? HealthTime.dayKey(now, calendar: calendar)
        let names = totals.keys.sorted()
        guard let dayStart = HealthTime.startOfDay(key: dayKey, calendar: calendar),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            result.rejected[.badTime, default: 0] += names.count
            return
        }
        if dayStart > now.addingTimeInterval(HealthLimits.futureSlackSeconds) {
            result.rejected[.badTime, default: 0] += names.count
            return
        }
        if dayEnd < now.addingTimeInterval(-maxAge) {
            result.rejected[.tooOld, default: 0] += names.count
            return
        }
        for name in names {
            guard let type = HealthType(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) else {
                result.rejected[.badType, default: 0] += 1
                continue
            }
            record(total(type, raw: totals[name], day: dayKey), into: &result)
        }
    }

    private func total(_ type: HealthType, raw: JSONValue?, day: String) -> Result<HealthSample, HealthRejection> {
        if type.isTimeOfDay {
            guard let text = raw?.stringValue else { return .failure(.badValue) }
            let seconds: Int
            if let date = HealthTime.parse(text, calendar: calendar) {
                seconds = HealthTime.secondsSinceMidnight(date, calendar: calendar)
            } else if let clock = HealthTime.parseClock(text) {
                seconds = clock
            } else {
                return .failure(.badValue)
            }
            return .success(HealthSample(type: type, day: day, at: now, key: "total",
                                         value: clockValue(type, seconds), replacesDay: true))
        }
        guard let value = number(raw), let normalized = type.normalize(value) else { return .failure(.badValue) }
        return .success(HealthSample(type: type, day: day, at: now, key: "total", value: normalized, replacesDay: true))
    }

    /// Shortcuts often emits numbers as strings.
    private func number(_ raw: JSONValue?) -> Double? {
        switch raw {
        case .some(.number(let n)): return n
        case .some(.string(let s)): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

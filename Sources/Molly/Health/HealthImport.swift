import Foundation

/// Reads an Apple Health export (`export.xml`) with a streaming parser and
/// folds it into the same per-day table the live collector uses. Exports run
/// to gigabytes, so nothing but the aggregates is ever held.
final class HealthExportParser: NSObject, XMLParserDelegate {
    static let quantityTypes: [String: HealthType] = [
        "HKQuantityTypeIdentifierStepCount": .steps,
        "HKQuantityTypeIdentifierActiveEnergyBurned": .activeEnergyKcal,
        "HKQuantityTypeIdentifierAppleExerciseTime": .exerciseMinutes,
        "HKQuantityTypeIdentifierRestingHeartRate": .restingHeartRateBpm,
        "HKQuantityTypeIdentifierHeartRate": .heartRateBpm,
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": .hrvMs,
        "HKQuantityTypeIdentifierDistanceWalkingRunning": .walkingDistanceM,
        "HKQuantityTypeIdentifierFlightsClimbed": .flightsClimbed,
        "HKQuantityTypeIdentifierTimeInDaylight": .daylightMinutes,
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": .headphoneAudioDb,
        "HKQuantityTypeIdentifierVO2Max": .vo2max,
        "HKQuantityTypeIdentifierBodyMass": .bodyMassKg,
        "HKQuantityTypeIdentifierRespiratoryRate": .respiratoryRate,
        "HKQuantityTypeIdentifierOxygenSaturation": .bloodOxygenRatio,
    ]
    static let sleepIdentifier = "HKCategoryTypeIdentifierSleepAnalysis"
    static let standIdentifier = "HKCategoryTypeIdentifierAppleStandHour"
    static let mindfulIdentifier = "HKCategoryTypeIdentifierMindfulSession"
    static let inBedValue = "HKCategoryValueSleepAnalysisInBed"
    static let asleepPrefix = "HKCategoryValueSleepAnalysisAsleep"
    static let stoodValue = "HKCategoryValueAppleStandHourStood"

    private struct Interval {
        let start: Date
        let end: Date
    }

    private let calendar: Calendar
    private let dateFormatter: DateFormatter
    private(set) var days = HealthDays()
    private(set) var recordCount = 0
    private(set) var usedRecordCount = 0
    private var asleep: [String: [Interval]] = [:]
    private var inBed: [String: [Interval]] = [:]

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    }

    /// Streams the whole document; throws the parser's error if it is malformed.
    func parse(_ parser: XMLParser) throws {
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        finishSleep()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "Record", let kind = attributeDict["type"] else { return }
        recordCount += 1
        guard let start = attributeDict["startDate"].flatMap(date), let end = attributeDict["endDate"].flatMap(date) else { return }
        if let type = Self.quantityTypes[kind] {
            guard let raw = attributeDict["value"].flatMap(Double.init),
                  let value = type.normalize(raw, unit: attributeDict["unit"] ?? "") else { return }
            add(type, value: value, start: start, end: end)
        } else if kind == Self.sleepIdentifier {
            addSleep(value: attributeDict["value"] ?? "", Interval(start: start, end: end))
        } else if kind == Self.standIdentifier, attributeDict["value"] == Self.stoodValue {
            add(.standHours, value: 1, start: start, end: end)
        } else if kind == Self.mindfulIdentifier {
            add(.mindfulMinutes, value: end.timeIntervalSince(start) / 60, start: start, end: end)
        }
    }

    private func date(_ text: String) -> Date? { dateFormatter.date(from: text) }

    private func add(_ type: HealthType, value: Double, start: Date, end: Date) {
        usedRecordCount += 1
        let attributed = type.belongsToEndDay ? end : start
        days.apply(HealthSample(
            type: type, day: HealthTime.dayKey(attributed, calendar: calendar), at: end,
            key: "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))",
            value: value, replacesDay: false))
    }

    private func addSleep(value: String, _ interval: Interval) {
        let day = HealthTime.dayKey(interval.end, calendar: calendar)
        if value == Self.inBedValue {
            inBed[day, default: []].append(interval)
        } else if value.hasPrefix(Self.asleepPrefix) {
            asleep[day, default: []].append(interval)
        }
    }

    /// Watch and phone both log a night; merging overlaps keeps minutes honest.
    private func finishSleep() {
        for (day, intervals) in asleep {
            usedRecordCount += intervals.count
            put(.sleepMinutes, minutes(Self.union(intervals)), day: day)
        }
        for (day, intervals) in inBed {
            usedRecordCount += intervals.count
            put(.sleepInBedMinutes, minutes(Self.union(intervals)), day: day)
        }
        for (day, intervals) in asleep.merging(inBed, uniquingKeysWith: +) {
            guard let first = intervals.map({ $0.start }).min(), let last = intervals.map({ $0.end }).max() else { continue }
            let bedtime = HealthTime.bedtimeSeconds(HealthTime.secondsSinceMidnight(first, calendar: calendar))
            put(.bedtime, bedtime, day: day)
            put(.wakeTime, Double(HealthTime.secondsSinceMidnight(last, calendar: calendar)), day: day)
        }
    }

    private func put(_ type: HealthType, _ value: Double, day: String) {
        days.apply(HealthSample(type: type, day: day, at: Date(timeIntervalSince1970: 0), key: "import",
                                value: value, replacesDay: true))
    }

    private func minutes(_ intervals: [(start: Date, end: Date)]) -> Double {
        intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60
    }

    private static func union(_ intervals: [Interval]) -> [(start: Date, end: Date)] {
        var merged: [(start: Date, end: Date)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append((interval.start, interval.end))
            }
        }
        return merged
    }
}

/// OpenMetrics text for `promtool tsdb create-blocks-from openmetrics`.
enum HealthOpenMetrics {
    static let metricName = "molly_health_day"
    /// Samples sit at midday so a day's value never straddles a timezone change.
    static let sampleHourOfDay = 12

    static func render(_ days: HealthDays, user: String, host: String, calendar: Calendar = .current) -> String {
        var lines = [
            "# HELP \(metricName) Apple Health value for one local day, imported from an export.",
            "# TYPE \(metricName) gauge",
        ]
        for type in HealthType.allCases {
            for day in days.days.keys.sorted() {
                guard let value = days.value(type, day: day),
                      let start = HealthTime.startOfDay(key: day, calendar: calendar),
                      let noon = calendar.date(bySettingHour: sampleHourOfDay, minute: 0, second: 0, of: start)
                else { continue }
                let labels = "type=\"\(type.rawValue)\",user=\"\(Metrics.escapeLabelValue(user))\",host=\"\(Metrics.escapeLabelValue(host))\""
                lines.append("\(metricName){\(labels)} \(Metrics.format(value)) \(Int(noon.timeIntervalSince1970))")
            }
        }
        lines.append("# EOF")
        return lines.joined(separator: "\n") + "\n"
    }
}

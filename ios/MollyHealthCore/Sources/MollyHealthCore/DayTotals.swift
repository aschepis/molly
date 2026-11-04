import Foundation

/// One sample reduced to what the aggregation needs. For category samples `value`
/// is the category's raw integer value.
public struct SamplePoint: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

/// What the HealthKit layer hands over for one type. A type with no reading at all
/// means its query failed or was not allowed, and the key is left out.
public enum Reading: Equatable, Sendable {
    /// Result of a statistics query; nil when the query succeeded with no data.
    case statistic(Double?)
    /// Today's average and the baseline average, for types sent as a change from baseline.
    case deltaStatistic(today: Double?, baseline: Double?)
    case samples([SamplePoint])
}

public enum TotalValue: Equatable, Sendable {
    case number(Double)
    case timestamp(Date)
}

public struct DayWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Raw values of HKCategoryValueSleepAnalysis and HKCategoryValueAppleStandHour.
public enum CategoryValues {
    public static let inBed = 0.0
    public static let asleepStages: Set<Double> = [1, 3, 4, 5]
    public static let stood = 0.0
}

public enum DayTotalsBuilder {
    public static func build(
        window: DayWindow,
        readings: [MollyHealthType: Reading]
    ) -> [MollyHealthType: TotalValue] {
        var totals: [MollyHealthType: TotalValue] = [:]
        for type in MollyHealthType.allCases {
            guard let reading = readings[type] else { continue }
            if let value = total(for: type, reading: reading, window: window) {
                totals[type] = value
            }
        }
        return totals
    }

    private static func total(for type: MollyHealthType, reading: Reading, window: DayWindow) -> TotalValue? {
        let spec = type.spec
        let number: Double?
        switch spec.aggregation {
        case .sum, .average, .maximum:
            number = quantityValue(spec.aggregation, reading, window)
        case .averageMinusBaseline:
            guard case .deltaStatistic(let today, let baseline) = reading, let today, let baseline else { return nil }
            number = today - baseline
        case .standCount:
            let stood = points(reading, window, by: \.start).filter { $0.value == CategoryValues.stood }
            number = Double(stood.count)
        case .mindfulDuration:
            number = points(reading, window, by: \.start).map { $0.end.timeIntervalSince($0.start) / 60 }.reduce(0, +)
        case .sleep(let measure):
            return sleepValue(measure, points(reading, window, by: \.end))
        }
        if let number { return .number(number) }
        return spec.zeroWhenEmpty ? .number(0) : nil
    }

    private static func quantityValue(_ aggregation: Aggregation, _ reading: Reading, _ window: DayWindow) -> Double? {
        let values: [Double]
        switch reading {
        case .statistic(let value): return value
        case .deltaStatistic: return nil
        case .samples(let samples): values = samples.filter { window.contains($0.start) }.map(\.value)
        }
        guard !values.isEmpty else { return nil }
        switch aggregation {
        case .sum: return values.reduce(0, +)
        case .average: return values.reduce(0, +) / Double(values.count)
        default: return values.max()
        }
    }

    private static func points(_ reading: Reading, _ window: DayWindow, by key: KeyPath<SamplePoint, Date>) -> [SamplePoint] {
        guard case .samples(let samples) = reading else { return [] }
        return samples.filter { window.contains($0[keyPath: key]) }
    }

    // MARK: sleep

    /// Phone and watch both record sleep, so overlapping intervals are merged before summing.
    private static func sleepValue(_ measure: SleepMeasure, _ samples: [SamplePoint]) -> TotalValue? {
        let asleep = merged(samples.filter { CategoryValues.asleepStages.contains($0.value) })
        switch measure {
        case .asleepMinutes:
            return asleep.isEmpty ? nil : .number(minutes(asleep))
        case .inBedMinutes:
            let inBed = merged(samples.filter { $0.value == CategoryValues.inBed })
            return inBed.isEmpty ? nil : .number(minutes(inBed))
        case .bedtime:
            return asleep.first.map { .timestamp($0.start) }
        case .wakeTime:
            return asleep.last.map { .timestamp($0.end) }
        }
    }

    private static func minutes(_ intervals: [SamplePoint]) -> Double {
        intervals.map { $0.end.timeIntervalSince($0.start) / 60 }.reduce(0, +)
    }

    private static func merged(_ samples: [SamplePoint]) -> [SamplePoint] {
        var result: [SamplePoint] = []
        for sample in samples.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, sample.start <= last.end {
                result[result.count - 1] = SamplePoint(start: last.start, end: max(last.end, sample.end), value: last.value)
            } else {
                result.append(sample)
            }
        }
        return result
    }
}

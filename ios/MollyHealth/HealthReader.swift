import Foundation
import HealthKit
import MollyHealthCore

/// The only file that touches HealthKit. It turns each enabled type into a `Reading`
/// for one day; the arithmetic on those readings lives in MollyHealthCore.
final class HealthReader: @unchecked Sendable {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func sampleType(for type: MollyHealthType) -> HKSampleType {
        let spec = type.spec
        if spec.isCategory {
            return HKCategoryType(HKCategoryTypeIdentifier(rawValue: spec.healthKitIdentifier))
        }
        return HKQuantityType(HKQuantityTypeIdentifier(rawValue: spec.healthKitIdentifier))
    }

    func requestAuthorization() async throws {
        let types = Set(MollyHealthType.allCases.map { sampleType(for: $0) as HKObjectType })
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func readings(for date: Date, types: [MollyHealthType], calendar: Calendar, log: LogRing) async -> [MollyHealthType: Reading] {
        let window = DayKey.window(for: date, calendar: calendar)
        var readings: [MollyHealthType: Reading] = [:]
        for type in types {
            do {
                readings[type] = try await reading(for: type, window: window, calendar: calendar)
            } catch {
                log.append("\(type.rawValue): query failed, leaving it out (\(error.localizedDescription))")
            }
        }
        return readings
    }

    private func reading(for type: MollyHealthType, window: DayWindow, calendar: Calendar) async throws -> Reading {
        let spec = type.spec
        switch spec.aggregation {
        case .sum:
            return .statistic(try await statistic(type, .cumulativeSum, window.start, window.end))
        case .average:
            return .statistic(try await statistic(type, .discreteAverage, window.start, window.end))
        case .maximum:
            return .statistic(try await statistic(type, .discreteMax, window.start, window.end))
        case .averageMinusBaseline:
            let baselineStart = calendar.date(byAdding: .day, value: -HealthCatalog.wristBaselineDays, to: window.start) ?? window.start
            let today = try await statistic(type, .discreteAverage, window.start, window.end)
            let baseline = try await statistic(type, .discreteAverage, baselineStart, window.start)
            return .deltaStatistic(today: today, baseline: baseline)
        case .standCount, .mindfulDuration, .sleep:
            return .samples(try await samples(type, window))
        }
    }

    private func unit(_ text: String) -> HKUnit? {
        switch text {
        case "count": return .count()
        case "kcal": return .kilocalorie()
        case "min": return .minute()
        case "count/min": return HKUnit.count().unitDivided(by: .minute())
        case "ms": return .secondUnit(with: .milli)
        case "m": return .meter()
        case "dBASPL": return .decibelAWeightedSoundPressureLevel()
        case "ml/(kg*min)": return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case "kg": return .gramUnit(with: .kilo)
        case "%": return .percent()
        case "degC": return .degreeCelsius()
        default: return nil
        }
    }

    /// nil means the query worked and found nothing; a thrown error means it could not run.
    private func statistic(_ type: MollyHealthType, _ options: HKStatisticsOptions, _ start: Date, _ end: Date) async throws -> Double? {
        guard let quantityType = sampleType(for: type) as? HKQuantityType, let unit = unit(type.spec.unit) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: options) { _, statistics, error in
                if let error = error as? HKError, error.code == .errorNoData {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    let quantity = statistics?.sumQuantity() ?? statistics?.averageQuantity() ?? statistics?.maximumQuantity()
                    continuation.resume(returning: quantity?.doubleValue(for: unit))
                }
            }
            store.execute(query)
        }
    }

    /// Samples that overlap the day; every sample the aggregation wants overlaps it, and
    /// MollyHealthCore then applies the exact start or end rule per type.
    private func samples(_ type: MollyHealthType, _ window: DayWindow) async throws -> [SamplePoint] {
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sampleType(for: type), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let points = (results ?? []).compactMap { sample -> SamplePoint? in
                    guard let category = sample as? HKCategorySample else { return nil }
                    return SamplePoint(start: category.startDate, end: category.endDate, value: Double(category.value))
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }
}

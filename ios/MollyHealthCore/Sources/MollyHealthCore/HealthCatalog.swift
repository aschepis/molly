import Foundation

/// Raw values must equal the Mac's `HealthType` in Sources/Molly/Health/HealthModel.swift;
/// scripts/check-health-types.sh enforces it. Keep the cases contiguous so the script can read them.
public enum MollyHealthType: String, CaseIterable, Codable, Sendable {
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
}

public enum SleepMeasure: Equatable, Sendable {
    case asleepMinutes, inBedMinutes, bedtime, wakeTime
}

public enum Aggregation: Equatable, Sendable {
    /// HKStatisticsQuery cumulativeSum; HealthKit de-duplicates overlapping sources.
    case sum
    /// HKStatisticsQuery discreteAverage.
    case average
    /// HKStatisticsQuery discreteMax.
    case maximum
    /// Today's average minus the average over the preceding baseline window.
    case averageMinusBaseline
    /// Count of AppleStandHour samples with value stood that started today.
    case standCount
    /// Sum of MindfulSession durations that started today.
    case mindfulDuration
    /// Derived from SleepAnalysis samples that ended today.
    case sleep(SleepMeasure)
}

public struct TypeSpec: Sendable {
    /// Raw value of an HKQuantityTypeIdentifier or HKCategoryTypeIdentifier.
    public let healthKitIdentifier: String
    public let isCategory: Bool
    /// Unit string accepted by HKUnit(from:); empty for category types.
    public let unit: String
    public let aggregation: Aggregation
    /// Sent as 0 when the query succeeds with no data; every other type omits its key.
    public let zeroWhenEmpty: Bool
    public let title: String
}

public extension MollyHealthType {
    var spec: TypeSpec {
        switch self {
        case .steps: return quantity("StepCount", "count", .sum, zero: true, "Steps")
        case .standHours: return category("AppleStandHour", .standCount, zero: true, "Stand hours")
        case .activeEnergyKcal: return quantity("ActiveEnergyBurned", "kcal", .sum, zero: true, "Active energy (kcal)")
        case .exerciseMinutes: return quantity("AppleExerciseTime", "min", .sum, zero: true, "Exercise minutes")
        case .restingHeartRateBpm: return quantity("RestingHeartRate", "count/min", .average, zero: false, "Resting heart rate")
        case .heartRateBpm: return quantity("HeartRate", "count/min", .average, zero: false, "Heart rate (average)")
        case .hrvMs: return quantity("HeartRateVariabilitySDNN", "ms", .average, zero: false, "HRV (ms)")
        case .sleepMinutes: return category("SleepAnalysis", .sleep(.asleepMinutes), zero: false, "Sleep (minutes)")
        case .sleepInBedMinutes: return category("SleepAnalysis", .sleep(.inBedMinutes), zero: false, "In bed (minutes)")
        case .bedtime: return category("SleepAnalysis", .sleep(.bedtime), zero: false, "Bedtime")
        case .wakeTime: return category("SleepAnalysis", .sleep(.wakeTime), zero: false, "Wake time")
        case .walkingDistanceM: return quantity("DistanceWalkingRunning", "m", .sum, zero: true, "Walking + running distance (m)")
        case .flightsClimbed: return quantity("FlightsClimbed", "count", .sum, zero: true, "Flights climbed")
        case .daylightMinutes: return quantity("TimeInDaylight", "min", .sum, zero: true, "Time in daylight")
        case .headphoneAudioDb: return quantity("HeadphoneAudioExposure", "dBASPL", .maximum, zero: false, "Headphone audio (max dB)")
        case .vo2max: return quantity("VO2Max", "ml/(kg*min)", .average, zero: false, "VO2 max")
        case .bodyMassKg: return quantity("BodyMass", "kg", .average, zero: false, "Body mass (kg)")
        case .respiratoryRate: return quantity("RespiratoryRate", "count/min", .average, zero: false, "Respiratory rate")
        case .bloodOxygenRatio: return quantity("OxygenSaturation", "%", .average, zero: false, "Blood oxygen (0..1)")
        case .wristTemperatureDeltaC:
            return quantity("AppleSleepingWristTemperature", "degC", .averageMinusBaseline, zero: false, "Wrist temperature change (C)")
        case .mindfulMinutes: return category("MindfulSession", .mindfulDuration, zero: true, "Mindful minutes")
        }
    }

    /// bedtime and wake_time are sent as ISO 8601 strings, everything else as a number.
    var isTimestamp: Bool { self == .bedtime || self == .wakeTime }

    private func quantity(_ name: String, _ unit: String, _ aggregation: Aggregation, zero: Bool, _ title: String) -> TypeSpec {
        TypeSpec(healthKitIdentifier: "HKQuantityTypeIdentifier" + name, isCategory: false, unit: unit,
                 aggregation: aggregation, zeroWhenEmpty: zero, title: title)
    }

    private func category(_ name: String, _ aggregation: Aggregation, zero: Bool, _ title: String) -> TypeSpec {
        TypeSpec(healthKitIdentifier: "HKCategoryTypeIdentifier" + name, isCategory: true, unit: "",
                 aggregation: aggregation, zeroWhenEmpty: zero, title: title)
    }
}

public enum HealthCatalog {
    /// Days of history the wrist temperature baseline averages over.
    public static let wristBaselineDays = 28
}

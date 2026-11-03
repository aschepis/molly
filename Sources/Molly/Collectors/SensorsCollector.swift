import Foundation

/// What the collector needs from the hardware. The live implementation
/// (SensorsSupport.swift) uses private interfaces; tests inject fakes.
protocol SensorProvider {
    func temperatures() throws -> [SensorReading]
    func ambientLight() throws -> Double?
    func fans() throws -> [SensorReading]
    func power() throws -> [SensorReading]
    func displayBrightness() throws -> Double
    func lidAngle() throws -> Double
}

struct SensorsFailure: Error, CustomStringConvertible {
    let description: String
}

/// Opt-in hardware sensors on Apple Silicon: temperatures, ambient light,
/// fans, power, display brightness and lid angle. Each source is independent;
/// one that is missing or refuses is reported in `molly_sensor_source_available`
/// and the rest keep working.
final class SensorsCollector: Collector {
    static let sensorsDefaults = LabelPolicy(enabled: true, mode: .denylist, maxCardinality: 40)
    static let systemPowerRail = "system"

    let name = "sensors"
    let interval: TimeInterval
    private let sources: [SensorSourceID]
    private let sensors: LabelFilter
    private let provider: SensorProvider

    private var temperature: Gauge?
    private var temperatureMax: Gauge?
    private var ambientLight: Gauge?
    private var fanRPM: Gauge?
    private var systemPower: Gauge?
    private var railPower: Gauge?
    private var brightness: Gauge?
    private var lidAngle: Gauge?
    private var available: Gauge?
    private var warned: Set<SensorSourceID> = []

    init(settings: CollectorSettings, provider: SensorProvider = LiveSensorProvider()) throws {
        interval = settings.interval(default: 30)
        sensors = try settings.filter("sensors", defaults: SensorsCollector.sensorsDefaults)
        sources = SensorsCollector.parseSources(settings.strings("sources", default: SensorSourceID.allCases.map(\.rawValue)))
        self.provider = provider
    }

    static func parseSources(_ names: [String]) -> [SensorSourceID] {
        let wanted = Set(names.map { $0.lowercased() })
        return SensorSourceID.allCases.filter { wanted.contains($0.rawValue) }
    }

    func start(registry r: MetricsRegistry) throws {
        temperature = r.gauge("molly_sensor_temperature_celsius", help: "Hardware temperature sensors (private HID interface); readings outside -40..150 are dropped.", labels: ["sensor"])
        temperatureMax = r.gauge("molly_sensor_temperature_max_celsius", help: "Hottest valid temperature sensor, before the sensors policy folds series.")
        ambientLight = r.gauge("molly_sensor_ambient_light_lux", help: "Ambient light sensor level as the HID service reports it (not calibrated lux on every model).")
        fanRPM = r.gauge("molly_sensor_fan_rpm", help: "Fan speed from the SMC.", labels: ["fan"])
        systemPower = r.gauge("molly_sensor_system_power_watts", help: "Total system power from SMC key PSTR.")
        railPower = r.gauge("molly_sensor_power_watts", help: "Other SMC power keys that read: battery, cpu, gpu, dc_in.", labels: ["rail"])
        brightness = r.gauge("molly_display_brightness_ratio", help: "Main display brightness, 0..1 (private DisplayServices).")
        lidAngle = r.gauge("molly_lid_angle_degrees", help: "Lid opening angle in degrees from the lid angle HID sensor.")
        available = r.gauge("molly_sensor_source_available", help: "1 when a sensor source read successfully on the last run, 0 when it is absent or refused.", labels: ["source"])
    }

    func collect() throws {
        var failures: [String] = []
        var anyUnavailable = false
        var succeeded = 0
        for source in sources {
            do {
                try read(source)
                available?.set(1, labels: ["source": source.rawValue])
                warned.remove(source)
                succeeded += 1
            } catch {
                available?.set(0, labels: ["source": source.rawValue])
                clear(source)
                if error is CollectorUnavailable { anyUnavailable = true }
                failures.append("\(source.rawValue): \(error)")
                report(error, for: source)
            }
        }
        guard succeeded == 0, !failures.isEmpty else { return }
        let message = failures.joined(separator: "; ")
        if anyUnavailable && failures.count == sources.count { throw CollectorUnavailable(reason: message) }
        throw SensorsFailure(description: message)
    }

    private func read(_ source: SensorSourceID) throws {
        switch source {
        case .hid: try readHID()
        case .smc: try readSMC()
        case .display: brightness?.set(try provider.displayBrightness())
        case .lidAngle: lidAngle?.set(try provider.lidAngle())
        }
    }

    private func readHID() throws {
        let valid = SensorFilter.normaliseNames(SensorFilter.validTemperatures(try provider.temperatures()))
        guard !valid.isEmpty else { throw CollectorUnavailable(reason: "no HID temperature services returned a valid reading") }
        publishTemperatures(valid)
        if let lux = try provider.ambientLight() {
            ambientLight?.set(lux)
        } else {
            ambientLight?.reset()
        }
    }

    private func publishTemperatures(_ readings: [SensorReading]) {
        temperatureMax?.set(SensorFilter.maxValue(readings) ?? 0)
        temperature?.reset()
        guard sensors.enabled else { return }
        var byLabel: [String: Double] = [:]
        for reading in readings {
            let label = sensors.label(reading.name)
            byLabel[label] = max(byLabel[label] ?? -.infinity, reading.value)
        }
        // Folding temperatures into "other" would sum them, so extras are dropped.
        let limit = sensors.maxCardinality
        let kept = byLabel.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit > 0 ? limit : byLabel.count)
        for (label, value) in kept { temperature?.set(value, labels: ["sensor": label]) }
    }

    private func readSMC() throws {
        let fans = try provider.fans()
        let rails = try provider.power()
        guard !fans.isEmpty || !rails.isEmpty else {
            throw CollectorUnavailable(reason: "no SMC fan or power key read (AppleSMC refused or keys absent)")
        }
        fanRPM?.reset()
        for fan in fans { fanRPM?.set(fan.value, labels: ["fan": fan.name]) }
        railPower?.reset()
        systemPower?.reset()
        for rail in rails where rail.value.isFinite {
            if rail.name == Self.systemPowerRail {
                systemPower?.set(rail.value)
            } else {
                railPower?.set(rail.value, labels: ["rail": rail.name])
            }
        }
    }

    private func clear(_ source: SensorSourceID) {
        switch source {
        case .hid:
            temperature?.reset()
            temperatureMax?.reset()
            ambientLight?.reset()
        case .smc:
            fanRPM?.reset()
            systemPower?.reset()
            railPower?.reset()
        case .display: brightness?.reset()
        case .lidAngle: lidAngle?.reset()
        }
    }

    private func report(_ error: Error, for source: SensorSourceID) {
        if error is CollectorUnavailable {
            guard warned.insert(source).inserted else { return }
            Log.info("sensors: source \(source.rawValue) unavailable: \(error)")
        } else {
            Log.error("sensors: source \(source.rawValue) failed: \(error)")
        }
    }
}

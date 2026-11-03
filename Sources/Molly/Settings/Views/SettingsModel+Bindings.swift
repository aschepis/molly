import SwiftUI

extension SettingsModel {
    /// A two-way binding onto one of the model's typed settings.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    func collectorEnabledBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { self.collectorEnabled(name) }, set: { self.setCollectorEnabled(name, $0) })
    }

    func collectorIntervalBinding(_ name: String) -> Binding<Double> {
        Binding(get: { self.collectorInterval(name) }, set: { self.setCollectorInterval(name, $0) })
    }

    func policyEnabledBinding(_ dimension: PrivacyDimension) -> Binding<Bool> {
        Binding(get: { self.policy(dimension).enabled }, set: { self.setPolicyEnabled(dimension, $0) })
    }

    func policyModeBinding(_ dimension: PrivacyDimension) -> Binding<LabelPolicy.Mode> {
        Binding(get: { self.policy(dimension).mode }, set: { self.setPolicyMode(dimension, $0) })
    }

    func policyPatternsBinding(_ dimension: PrivacyDimension) -> Binding<[String]> {
        Binding(get: { self.policy(dimension).patterns }, set: { self.setPolicyPatterns(dimension, $0) })
    }

    func policyHashBinding(_ dimension: PrivacyDimension) -> Binding<Bool> {
        Binding(get: { self.policy(dimension).hash }, set: { self.setPolicyHash(dimension, $0) })
    }

    func policyMaxCardinalityBinding(_ dimension: PrivacyDimension) -> Binding<Int> {
        Binding(get: { self.policy(dimension).maxCardinality }, set: { self.setPolicyMaxCardinality(dimension, $0) })
    }
}

extension SettingsModel {
    var alertsNotify: Bool {
        get { get(["collectors", "alerts", "notify"])?.boolValue ?? true }
        set { set(["collectors", "alerts", "notify"], .bool(newValue)) }
    }

    var mutedAlerts: Set<String> {
        Set((get(["collectors", "alerts", "muted"])?.arrayValue ?? []).compactMap { $0.stringValue })
    }

    func setAlertMuted(_ name: String, _ muted: Bool) {
        var names = mutedAlerts
        if muted { names.insert(name) } else { names.remove(name) }
        set(["collectors", "alerts", "muted"], names.isEmpty ? nil : .array(names.sorted().map { .string($0) }))
    }

    func alertMutedBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { self.mutedAlerts.contains(name) }, set: { self.setAlertMuted(name, $0) })
    }
}

import CoreAudio
import CoreMediaIO
import Foundation

// MARK: - Pure state (unit-tested)

struct MeetingDeltas: Equatable {
    var microphoneSeconds: Double = 0
    var cameraSeconds: Double = 0
    var meetingSeconds: Double = 0
    var microphoneActivations = 0
    var cameraActivations = 0
    var meetingStarts = 0
}

/// Accumulates seconds and off-to-on transitions for the mic and camera.
/// Like `FocusState`, an interval is credited using the state at its start.
struct MeetingState {
    /// Intervals longer than this (sleep, suspended process) are not credited.
    let maxGap: Double

    private(set) var microphone = false
    private(set) var camera = false
    private var lastTick: Date?

    var meetingActive: Bool { microphone || camera }

    init(maxGap: Double = 30) { self.maxGap = maxGap }

    mutating func advance(to now: Date, microphone newMic: Bool, camera newCamera: Bool) -> MeetingDeltas {
        var deltas = MeetingDeltas()
        if let last = lastTick {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0, elapsed <= maxGap {
                if microphone { deltas.microphoneSeconds = elapsed }
                if camera { deltas.cameraSeconds = elapsed }
                if meetingActive { deltas.meetingSeconds = elapsed }
            }
        }
        lastTick = now
        let wasActive = meetingActive
        if newMic && !microphone { deltas.microphoneActivations += 1 }
        if newCamera && !camera { deltas.cameraActivations += 1 }
        microphone = newMic
        camera = newCamera
        if meetingActive && !wasActive { deltas.meetingStarts += 1 }
        return deltas
    }
}

// MARK: - Collector

/// Whether the default microphone or any camera is being used by some process,
/// the best available signal that a call or meeting is happening.
final class MeetingCollector: Collector {
    let name = "meeting"
    let interval: TimeInterval

    private var state: MeetingState
    private var micGauge: Gauge?
    private var cameraGauge: Gauge?
    private var meetingGauge: Gauge?
    private var micSeconds: Counter?
    private var cameraSeconds: Counter?
    private var meetingSeconds: Counter?
    private var micActivations: Counter?
    private var cameraActivations: Counter?
    private var meetingStarts: Counter?
    private var skipped: Set<String> = []

    init(settings: CollectorSettings) {
        interval = settings.interval(default: 5)
        state = MeetingState(maxGap: max(settings.interval(default: 5) * 6, 30))
    }

    func start(registry r: MetricsRegistry) throws {
        micGauge = r.gauge("molly_microphone_in_use", help: "1 when some process is capturing from the default microphone.")
        cameraGauge = r.gauge("molly_camera_in_use", help: "1 when some process is using a camera.")
        meetingGauge = r.gauge("molly_meeting_active", help: "1 when the microphone or a camera is in use.")
        micSeconds = r.counter("molly_microphone_in_use_seconds_total", help: "Seconds the microphone was in use.")
        cameraSeconds = r.counter("molly_camera_in_use_seconds_total", help: "Seconds a camera was in use.")
        meetingSeconds = r.counter("molly_meeting_seconds_total", help: "Seconds the microphone or a camera was in use.")
        micActivations = r.counter("molly_microphone_activations_total", help: "Times the microphone went from idle to in use.")
        cameraActivations = r.counter("molly_camera_activations_total", help: "Times a camera went from idle to in use.")
        meetingStarts = r.counter("molly_meetings_total", help: "Times mic and camera went from both idle to either in use.")
        for c in [micSeconds, cameraSeconds, meetingSeconds, micActivations, cameraActivations, meetingStarts] { c?.touch() }
    }

    func collect() throws {
        let mic = microphoneInUse()
        let camera = cameraInUse()
        guard mic != nil || camera != nil else { throw CollectorUnavailable(reason: "neither CoreAudio nor CoreMediaIO could be read") }
        let d = state.advance(to: Date(), microphone: mic ?? false, camera: camera ?? false)
        micGauge?.set(state.microphone ? 1 : 0)
        cameraGauge?.set(state.camera ? 1 : 0)
        meetingGauge?.set(state.meetingActive ? 1 : 0)
        for (counter, value) in [(micSeconds, d.microphoneSeconds), (cameraSeconds, d.cameraSeconds), (meetingSeconds, d.meetingSeconds),
                                 (micActivations, Double(d.microphoneActivations)), (cameraActivations, Double(d.cameraActivations)),
                                 (meetingStarts, Double(d.meetingStarts))] where value > 0 {
            counter?.add(value)
        }
    }

    private func microphoneInUse() -> Bool? {
        let value = CoreAudioProbe.isInputRunning()
        if value == nil { noteOnce("microphone", "no default input device") }
        return value
    }

    private func cameraInUse() -> Bool? {
        let value = CoreMediaIOProbe.isAnyCameraRunning()
        if value == nil { noteOnce("camera", "CoreMediaIO device list unreadable") }
        return value
    }

    private func noteOnce(_ source: String, _ reason: String) {
        guard skipped.insert(source).inserted else { return }
        Log.debug("meeting: \(source) unavailable: \(reason)")
    }
}

enum CoreMediaIOProbe {
    private static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func deviceIDs() -> [CMIOObjectID]? {
        var addr = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0 else { return nil }
        return devices
    }

    /// nil when the device list cannot be read; false for a Mac with no camera.
    static func isAnyCameraRunning() -> Bool? {
        guard let devices = deviceIDs() else { return nil }
        return devices.contains { device in
            var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &running) == 0 else { return false }
            return running != 0
        }
    }
}

import Foundation

@MainActor
final class ObservePreferences: ObservableObject {
    private enum Keys {
        static let selectedHomeID = "observe.selectedHomeID"
        static let density = "observe.wallDensity"
        static let remotePriority = "observe.remotePriority"
        static let staleVisualHighlightSeconds = "observe.staleVisualHighlightSeconds"
        static let batteryWakeCameraIDs = "observe.batteryWakeCameraIDs"
        static let batteryWakeTriggerSeconds = "observe.batteryWakeTriggerSeconds"
        static let batteryCaptureWarmupSeconds = "observe.batteryCaptureWarmupSeconds"
        static let batteryStaleSeconds = "observe.batteryStaleSeconds"
    }

    @Published var selectedHomeID: String? {
        didSet { userDefaults.set(selectedHomeID, forKey: Keys.selectedHomeID) }
    }

    @Published var wallDensity: WallDensity {
        didSet { userDefaults.set(wallDensity.rawValue, forKey: Keys.density) }
    }

    @Published var remotePriorityIDs: [String] {
        didSet { userDefaults.set(remotePriorityIDs, forKey: Keys.remotePriority) }
    }

    @Published private(set) var staleVisualHighlightSeconds: Int
    @Published private(set) var batteryWakeCameraIDs: [String]
    @Published private(set) var batteryWakeTriggerSeconds: Int
    @Published private(set) var batteryCaptureWarmupSeconds: Int
    @Published private(set) var batteryStaleSeconds: Int

    private let userDefaults: UserDefaults

    var staleVisualHighlightThreshold: TimeInterval {
        TimeInterval(staleVisualHighlightSeconds)
    }

    var defaultStaleVisualHighlightSeconds: Int {
        Int(CameraSchedulingDefaults.staleVisualHighlightThreshold)
    }

    var batteryWakeTriggerThreshold: TimeInterval {
        TimeInterval(batteryWakeTriggerSeconds)
    }

    var batteryCaptureWarmupThreshold: TimeInterval {
        TimeInterval(batteryCaptureWarmupSeconds)
    }

    var batteryStaleThreshold: TimeInterval {
        TimeInterval(batteryStaleSeconds)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedHomeID = userDefaults.string(forKey: Keys.selectedHomeID)
        let storedDensity = userDefaults.string(forKey: Keys.density) ?? ""
        self.wallDensity = switch storedDensity {
        case "focus":
            .oneColumn
        case "balanced":
            .twoColumns
        case "overview":
            .twoColumns
        default:
            WallDensity(rawValue: storedDensity) ?? .twoColumns
        }
        self.remotePriorityIDs = userDefaults.stringArray(forKey: Keys.remotePriority) ?? []
        self.batteryWakeCameraIDs = userDefaults.stringArray(forKey: Keys.batteryWakeCameraIDs) ?? []
        let storedStaleSeconds = userDefaults.object(forKey: Keys.staleVisualHighlightSeconds) as? Int
        self.staleVisualHighlightSeconds = max(
            1,
            storedStaleSeconds ?? Int(CameraSchedulingDefaults.staleVisualHighlightThreshold)
        )
        let storedBatteryWakeTriggerSeconds = userDefaults.object(forKey: Keys.batteryWakeTriggerSeconds) as? Int
        self.batteryWakeTriggerSeconds = max(
            1,
            storedBatteryWakeTriggerSeconds ?? Int(CameraSchedulingDefaults.batteryWakeTriggerThreshold)
        )
        let storedBatteryCaptureWarmupSeconds = userDefaults.object(forKey: Keys.batteryCaptureWarmupSeconds) as? Int
        self.batteryCaptureWarmupSeconds = max(
            1,
            storedBatteryCaptureWarmupSeconds ?? Int(CameraSchedulingDefaults.batteryCaptureWarmup)
        )
        let storedBatteryStaleSeconds = userDefaults.object(forKey: Keys.batteryStaleSeconds) as? Int
        self.batteryStaleSeconds = max(
            1,
            storedBatteryStaleSeconds ?? Int(CameraSchedulingDefaults.batteryStaleThreshold)
        )
    }

    func normalizedPriority(availableIDs: [String]) -> [String] {
        var normalized: [String] = []

        for id in remotePriorityIDs where availableIDs.contains(id) && !normalized.contains(id) {
            normalized.append(id)
        }

        for id in availableIDs where !normalized.contains(id) {
            normalized.append(id)
        }

        if normalized != remotePriorityIDs {
            remotePriorityIDs = normalized
        }

        return normalized
    }

    func movePriority(from source: IndexSet, to destination: Int, availableIDs: [String]) {
        var ids = normalizedPriority(availableIDs: availableIDs)
        ids.move(fromOffsets: source, toOffset: destination)
        remotePriorityIDs = ids
    }

    func prioritize(_ id: String, availableIDs: [String]) {
        var ids = normalizedPriority(availableIDs: availableIDs)
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        remotePriorityIDs = ids
    }

    func adjustDensity(with scale: CGFloat) {
        if scale > 1.1 {
            wallDensity = wallDensity.stepped(by: -1)
        } else if scale < 0.9 {
            wallDensity = wallDensity.stepped(by: 1)
        }
    }

    func setStaleVisualHighlightSeconds(_ seconds: Int) {
        let sanitized = max(1, seconds)
        guard staleVisualHighlightSeconds != sanitized else { return }

        staleVisualHighlightSeconds = sanitized
        userDefaults.set(sanitized, forKey: Keys.staleVisualHighlightSeconds)
    }

    func resetStaleVisualHighlightSeconds() {
        setStaleVisualHighlightSeconds(defaultStaleVisualHighlightSeconds)
    }

    func isBatteryWakeCamera(id: String) -> Bool {
        batteryWakeCameraIDs.contains(id)
    }

    func setBatteryWakeTriggerSeconds(_ seconds: Int) {
        let sanitized = max(1, seconds)
        guard batteryWakeTriggerSeconds != sanitized else { return }

        batteryWakeTriggerSeconds = sanitized
        userDefaults.set(sanitized, forKey: Keys.batteryWakeTriggerSeconds)
    }

    func setBatteryCaptureWarmupSeconds(_ seconds: Int) {
        let sanitized = max(1, seconds)
        guard batteryCaptureWarmupSeconds != sanitized else { return }

        batteryCaptureWarmupSeconds = sanitized
        userDefaults.set(sanitized, forKey: Keys.batteryCaptureWarmupSeconds)
    }

    func setBatteryStaleSeconds(_ seconds: Int) {
        let sanitized = max(1, seconds)
        guard batteryStaleSeconds != sanitized else { return }

        batteryStaleSeconds = sanitized
        userDefaults.set(sanitized, forKey: Keys.batteryStaleSeconds)
    }

    func setBatteryWakeEnabled(_ enabled: Bool, for id: String) {
        var ids = batteryWakeCameraIDs

        if enabled {
            if !ids.contains(id) {
                ids.append(id)
            }
        } else {
            ids.removeAll { $0 == id }
        }

        guard ids != batteryWakeCameraIDs else { return }
        batteryWakeCameraIDs = ids
        userDefaults.set(ids, forKey: Keys.batteryWakeCameraIDs)
    }
}

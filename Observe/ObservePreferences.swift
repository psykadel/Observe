import Foundation

@MainActor
final class ObservePreferences: ObservableObject {
    private enum Keys {
        static let selectedHomeID = "observe.selectedHomeID"
        static let density = "observe.wallDensity"
        static let remotePriority = "observe.remotePriority"
        static let staleVisualHighlightSeconds = "observe.staleVisualHighlightSeconds"
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

    private let userDefaults: UserDefaults

    var staleVisualHighlightThreshold: TimeInterval {
        TimeInterval(staleVisualHighlightSeconds)
    }

    var defaultStaleVisualHighlightSeconds: Int {
        Int(CameraSchedulingDefaults.staleVisualHighlightThreshold)
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
        let storedStaleSeconds = userDefaults.object(forKey: Keys.staleVisualHighlightSeconds) as? Int
        self.staleVisualHighlightSeconds = max(
            1,
            storedStaleSeconds ?? Int(CameraSchedulingDefaults.staleVisualHighlightThreshold)
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
}

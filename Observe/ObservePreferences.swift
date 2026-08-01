import Foundation

@MainActor
final class ObservePreferences: ObservableObject {
    private enum Keys {
        static let selectedHomeID = "observe.selectedHomeID"
        static let homeNetworkSSID = "observe.homeNetworkSSID"
        static let density = "observe.wallDensity"
        static let cameraNameVisibility = "observe.cameraNameVisibility"
        static let remotePriority = "observe.remotePriority"
        static let livePriority = "observe.livePriority"
        static let staleVisualHighlightSeconds = "observe.staleVisualHighlightSeconds"
        static let batteryWakeCameraIDs = "observe.batteryWakeCameraIDs"
        static let batteryCameraVisibilityEnabled = "observe.batteryCameraVisibilityEnabled"
        static let batteryCameraVisibilityToggleShown = "observe.batteryCameraVisibilityToggleShown"
        static let batteryPercentagesShown = "observe.batteryPercentagesShown"
        static let batteryWakeTriggerSeconds = "observe.batteryWakeTriggerSeconds"
        static let batteryCaptureWarmupSeconds = "observe.batteryCaptureWarmupSeconds"
        static let batteryStaleSeconds = "observe.batteryStaleSeconds"
        static let restrictedLiveCapacities = "observe.restrictedLiveCapacities"
        static let lockStatusEnabled = "observe.lockStatusEnabled"
        static let homeTemperatureEnabled = "observe.homeTemperatureEnabled"
        static let successIndicatorEnabled = "observe.successIndicatorEnabled"
        static let successIndicatorOnlyOffHomeNetwork = "observe.successIndicatorOnlyOffHomeNetwork"
        static let selectedLockIDs = "observe.selectedLockIDs"
        static let selectedTemperatureSensorIDs = "observe.selectedTemperatureSensorIDs"
        static let homeTemperatureLowFahrenheit = "observe.homeTemperatureLowFahrenheit"
        static let homeTemperatureHighFahrenheit = "observe.homeTemperatureHighFahrenheit"
    }

    @Published var selectedHomeID: String? {
        didSet { userDefaults.set(selectedHomeID, forKey: Keys.selectedHomeID) }
    }

    @Published private(set) var homeNetworkSSID: String

    @Published var wallDensity: WallDensity {
        didSet { userDefaults.set(wallDensity.rawValue, forKey: Keys.density) }
    }

    @Published var cameraNameVisibility: CameraNameVisibility {
        didSet { userDefaults.set(cameraNameVisibility.rawValue, forKey: Keys.cameraNameVisibility) }
    }

    @Published var remotePriorityIDs: [String] {
        didSet { userDefaults.set(remotePriorityIDs, forKey: Keys.remotePriority) }
    }

    @Published private(set) var livePriorityIDs: [String] {
        didSet { userDefaults.set(livePriorityIDs, forKey: Keys.livePriority) }
    }

    @Published private(set) var staleVisualHighlightSeconds: Int
    @Published private(set) var batteryWakeCameraIDs: [String]
    @Published private(set) var isBatteryCameraVisibilityEnabled: Bool
    @Published private(set) var showsBatteryCameraVisibilityToggle: Bool
    @Published private(set) var showsBatteryPercentages: Bool
    @Published private(set) var batteryWakeTriggerSeconds: Int
    @Published private(set) var batteryCaptureWarmupSeconds: Int
    @Published private(set) var batteryStaleSeconds: Int
    @Published private(set) var isLockStatusEnabled: Bool
    @Published private(set) var isHomeTemperatureEnabled: Bool
    @Published private(set) var isSuccessIndicatorEnabled: Bool
    @Published private(set) var isSuccessIndicatorOnlyOffHomeNetwork: Bool
    @Published private(set) var selectedLockIDs: [String]
    @Published private(set) var selectedTemperatureSensorIDs: [String]
    @Published private(set) var homeTemperatureLowFahrenheit: Int
    @Published private(set) var homeTemperatureHighFahrenheit: Int

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
        self.homeNetworkSSID = userDefaults.string(forKey: Keys.homeNetworkSSID) ?? ""
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
        let storedCameraNameVisibility = userDefaults.string(forKey: Keys.cameraNameVisibility) ?? ""
        self.cameraNameVisibility = CameraNameVisibility(rawValue: storedCameraNameVisibility) ?? .show
        self.remotePriorityIDs = userDefaults.stringArray(forKey: Keys.remotePriority) ?? []
        self.livePriorityIDs = userDefaults.stringArray(forKey: Keys.livePriority) ?? []
        self.batteryWakeCameraIDs = userDefaults.stringArray(forKey: Keys.batteryWakeCameraIDs) ?? []
        let storedBatteryCameraVisibilityEnabled = userDefaults.object(
            forKey: Keys.batteryCameraVisibilityEnabled
        ) as? Bool ?? true
        let storedBatteryCameraVisibilityToggleShown = userDefaults.object(
            forKey: Keys.batteryCameraVisibilityToggleShown
        ) as? Bool ?? true
        if !storedBatteryCameraVisibilityToggleShown, !storedBatteryCameraVisibilityEnabled {
            self.isBatteryCameraVisibilityEnabled = true
            userDefaults.set(true, forKey: Keys.batteryCameraVisibilityEnabled)
        } else {
            self.isBatteryCameraVisibilityEnabled = storedBatteryCameraVisibilityEnabled
        }
        self.showsBatteryCameraVisibilityToggle = storedBatteryCameraVisibilityToggleShown
        self.showsBatteryPercentages = userDefaults.object(
            forKey: Keys.batteryPercentagesShown
        ) as? Bool ?? false
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
        self.isLockStatusEnabled = userDefaults.object(forKey: Keys.lockStatusEnabled) as? Bool ?? false
        self.isHomeTemperatureEnabled = userDefaults.object(forKey: Keys.homeTemperatureEnabled) as? Bool ?? false
        self.isSuccessIndicatorEnabled = userDefaults.object(
            forKey: Keys.successIndicatorEnabled
        ) as? Bool ?? false
        self.isSuccessIndicatorOnlyOffHomeNetwork = userDefaults.object(
            forKey: Keys.successIndicatorOnlyOffHomeNetwork
        ) as? Bool ?? false
        self.selectedLockIDs = userDefaults.stringArray(forKey: Keys.selectedLockIDs) ?? []
        self.selectedTemperatureSensorIDs = userDefaults.stringArray(
            forKey: Keys.selectedTemperatureSensorIDs
        ) ?? []
        let storedLow = userDefaults.object(forKey: Keys.homeTemperatureLowFahrenheit) as? Int ?? 60
        let storedHigh = userDefaults.object(forKey: Keys.homeTemperatureHighFahrenheit) as? Int ?? 80
        self.homeTemperatureLowFahrenheit = min(storedLow, storedHigh)
        self.homeTemperatureHighFahrenheit = max(storedLow, storedHigh)
    }

    func normalizedPriority(availableIDs: [String]) -> [String] {
        let savedOrder = savedOrder(remotePriorityIDs, adding: availableIDs)

        if savedOrder != remotePriorityIDs {
            remotePriorityIDs = savedOrder
        }

        return availableOrder(savedOrder, availableIDs: availableIDs)
    }

    func movePriority(from source: IndexSet, to destination: Int, availableIDs: [String]) {
        var ids = normalizedPriority(availableIDs: availableIDs)
        ids.move(fromOffsets: source, toOffset: destination)
        remotePriorityIDs = mergingAvailableOrder(ids, into: remotePriorityIDs)
    }

    func normalizedLivePriority(availableIDs: [String]) -> [String] {
        let storedIDs = livePriorityIDs.isEmpty ? availableIDs : livePriorityIDs
        let savedOrder = savedOrder(storedIDs, adding: availableIDs)

        if savedOrder != livePriorityIDs {
            livePriorityIDs = savedOrder
        }

        return availableOrder(savedOrder, availableIDs: availableIDs)
    }

    func moveLivePriority(from source: IndexSet, to destination: Int, availableIDs: [String]) {
        var ids = normalizedLivePriority(availableIDs: availableIDs)
        ids.move(fromOffsets: source, toOffset: destination)
        livePriorityIDs = mergingAvailableOrder(ids, into: livePriorityIDs)
    }

    private func savedOrder(_ storedIDs: [String], adding availableIDs: [String]) -> [String] {
        var saved: [String] = []
        var seen: Set<String> = []

        for id in storedIDs where seen.insert(id).inserted {
            saved.append(id)
        }

        for id in availableIDs where seen.insert(id).inserted {
            saved.append(id)
        }

        return saved
    }

    private func availableOrder(_ savedOrder: [String], availableIDs: [String]) -> [String] {
        let availableIDs = Set(availableIDs)
        return savedOrder.filter(availableIDs.contains)
    }

    private func mergingAvailableOrder(
        _ reorderedAvailableIDs: [String],
        into savedOrder: [String]
    ) -> [String] {
        let reorderedSet = Set(reorderedAvailableIDs)
        var reorderedIndex = 0

        return savedOrder.map { id in
            guard reorderedSet.contains(id) else { return id }
            defer { reorderedIndex += 1 }
            return reorderedAvailableIDs[reorderedIndex]
        }
    }

    func adjustDensity(with scale: CGFloat) {
        if scale > 1.1 {
            wallDensity = wallDensity.stepped(by: -1)
        } else if scale < 0.9 {
            wallDensity = wallDensity.stepped(by: 1)
        }
    }

    func effectiveWallDensity(for platform: CameraWallPlatform) -> WallDensity {
        switch platform {
        case .iPhone:
            wallDensity
        case .mac:
            .auto
        }
    }

    func adjustDensity(withHorizontalSwipe translationWidth: CGFloat) {
        let minimumSwipeDistance: CGFloat = 48
        guard abs(translationWidth) >= minimumSwipeDistance else { return }

        wallDensity = wallDensity.stepped(by: translationWidth < 0 ? 1 : -1)
    }

    func setStaleVisualHighlightSeconds(_ seconds: Int) {
        let sanitized = max(1, seconds)
        guard staleVisualHighlightSeconds != sanitized else { return }

        staleVisualHighlightSeconds = sanitized
        userDefaults.set(sanitized, forKey: Keys.staleVisualHighlightSeconds)
    }

    func setHomeNetworkSSID(_ ssid: String) {
        guard homeNetworkSSID != ssid else { return }

        homeNetworkSSID = ssid
        userDefaults.set(ssid, forKey: Keys.homeNetworkSSID)
    }

    func rememberedRestrictedLiveCapacity(homeID: String?, visibleCameraIDs: [String]) -> Int? {
        guard let key = restrictedLiveCapacityKey(homeID: homeID, visibleCameraIDs: visibleCameraIDs) else {
            return nil
        }

        guard let stored = restrictedLiveCapacities()[key], stored > 0 else {
            return nil
        }

        return min(stored, Set(visibleCameraIDs).count)
    }

    func recordConfirmedRestrictedLiveCapacity(
        _ capacity: Int,
        homeID: String?,
        visibleCameraIDs: [String]
    ) {
        guard let key = restrictedLiveCapacityKey(homeID: homeID, visibleCameraIDs: visibleCameraIDs),
              capacity > 0 else {
            return
        }

        let boundedCapacity = min(capacity, Set(visibleCameraIDs).count)
        var capacities = restrictedLiveCapacities()
        guard boundedCapacity > (capacities[key] ?? 0) else { return }

        capacities[key] = boundedCapacity
        userDefaults.set(capacities, forKey: Keys.restrictedLiveCapacities)
    }

    func recordRestrictedLiveCapacityAfterRejection(
        _ survivingCapacity: Int,
        homeID: String?,
        visibleCameraIDs: [String]
    ) {
        guard let key = restrictedLiveCapacityKey(homeID: homeID, visibleCameraIDs: visibleCameraIDs) else {
            return
        }

        var capacities = restrictedLiveCapacities()
        let boundedCapacity = min(max(0, survivingCapacity), Set(visibleCameraIDs).count)
        if boundedCapacity == 0 {
            capacities.removeValue(forKey: key)
        } else {
            capacities[key] = boundedCapacity
        }
        userDefaults.set(capacities, forKey: Keys.restrictedLiveCapacities)
    }

    func isBatteryWakeCamera(id: String) -> Bool {
        batteryWakeCameraIDs.contains(id)
    }

    func setBatteryCameraVisibilityEnabled(_ enabled: Bool) {
        guard isBatteryCameraVisibilityEnabled != enabled else { return }

        isBatteryCameraVisibilityEnabled = enabled
        userDefaults.set(enabled, forKey: Keys.batteryCameraVisibilityEnabled)
    }

    func setBatteryCameraVisibilityToggleShown(_ shown: Bool) {
        guard showsBatteryCameraVisibilityToggle != shown else {
            if !shown {
                setBatteryCameraVisibilityEnabled(true)
            }
            return
        }

        showsBatteryCameraVisibilityToggle = shown
        userDefaults.set(shown, forKey: Keys.batteryCameraVisibilityToggleShown)
        if !shown {
            setBatteryCameraVisibilityEnabled(true)
        }
    }

    func setBatteryPercentagesShown(_ shown: Bool) {
        guard showsBatteryPercentages != shown else { return }

        showsBatteryPercentages = shown
        userDefaults.set(shown, forKey: Keys.batteryPercentagesShown)
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

    func setLockStatusEnabled(_ enabled: Bool) {
        guard isLockStatusEnabled != enabled else { return }
        isLockStatusEnabled = enabled
        userDefaults.set(enabled, forKey: Keys.lockStatusEnabled)
    }

    func setHomeTemperatureEnabled(_ enabled: Bool) {
        guard isHomeTemperatureEnabled != enabled else { return }
        isHomeTemperatureEnabled = enabled
        userDefaults.set(enabled, forKey: Keys.homeTemperatureEnabled)
    }

    func setSuccessIndicatorEnabled(_ enabled: Bool) {
        guard isSuccessIndicatorEnabled != enabled else { return }
        isSuccessIndicatorEnabled = enabled
        userDefaults.set(enabled, forKey: Keys.successIndicatorEnabled)
    }

    func setSuccessIndicatorOnlyOffHomeNetwork(_ enabled: Bool) {
        guard isSuccessIndicatorOnlyOffHomeNetwork != enabled else { return }
        isSuccessIndicatorOnlyOffHomeNetwork = enabled
        userDefaults.set(enabled, forKey: Keys.successIndicatorOnlyOffHomeNetwork)
    }

    func isLockSelected(id: String) -> Bool {
        selectedLockIDs.contains(id)
    }

    func setLockSelected(_ selected: Bool, for id: String) {
        var ids = selectedLockIDs
        if selected, !ids.contains(id) {
            ids.append(id)
        } else if !selected {
            ids.removeAll { $0 == id }
        }
        guard ids != selectedLockIDs else { return }
        selectedLockIDs = ids
        userDefaults.set(ids, forKey: Keys.selectedLockIDs)
    }

    func isTemperatureSensorSelected(id: String) -> Bool {
        selectedTemperatureSensorIDs.contains(id)
    }

    func setTemperatureSensorSelected(_ selected: Bool, for id: String) {
        var ids = selectedTemperatureSensorIDs
        if selected, !ids.contains(id) {
            ids.append(id)
        } else if !selected {
            ids.removeAll { $0 == id }
        }
        guard ids != selectedTemperatureSensorIDs else { return }
        selectedTemperatureSensorIDs = ids
        userDefaults.set(ids, forKey: Keys.selectedTemperatureSensorIDs)
    }

    func setHomeTemperatureLowFahrenheit(_ value: Int) {
        let clamped = min(value, homeTemperatureHighFahrenheit)
        guard clamped != homeTemperatureLowFahrenheit else { return }
        homeTemperatureLowFahrenheit = clamped
        userDefaults.set(clamped, forKey: Keys.homeTemperatureLowFahrenheit)
    }

    func setHomeTemperatureHighFahrenheit(_ value: Int) {
        let clamped = max(value, homeTemperatureLowFahrenheit)
        guard clamped != homeTemperatureHighFahrenheit else { return }
        homeTemperatureHighFahrenheit = clamped
        userDefaults.set(clamped, forKey: Keys.homeTemperatureHighFahrenheit)
    }

    private func restrictedLiveCapacities() -> [String: Int] {
        let dictionary = userDefaults.dictionary(forKey: Keys.restrictedLiveCapacities) ?? [:]
        return dictionary.compactMapValues { value in
            if let intValue = value as? Int {
                return intValue
            }
            if let numberValue = value as? NSNumber {
                return numberValue.intValue
            }
            return nil
        }
    }

    private func restrictedLiveCapacityKey(homeID: String?, visibleCameraIDs: [String]) -> String? {
        guard let homeID, !homeID.isEmpty else { return nil }
        let cameraIDs = Array(Set(visibleCameraIDs)).sorted()
        guard !cameraIDs.isEmpty else { return nil }

        let homeComponent = "\(homeID.utf8.count):\(homeID)"
        let cameraComponent = cameraIDs
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return "v3#\(homeComponent)#\(cameraComponent)"
    }
}

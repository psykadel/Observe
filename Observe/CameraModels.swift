import Foundation
import CoreGraphics
import HomeKit

enum CameraSchedulingDefaults {
    static let staleVisualHighlightThreshold: TimeInterval = 60
    static let batteryWakeTriggerThreshold: TimeInterval = 60
    static let batteryStaleThreshold: TimeInterval = 120
    static let snapshotRequestTimeout: TimeInterval = 4
    static let maxConcurrentSnapshotRequests = 3
    static let untrustedSnapshotRefreshInterval: TimeInterval = 2
    static let minimumSnapshotRefreshInterval: TimeInterval = 5
    static let batteryCaptureWarmup: TimeInterval = 5
    static let batteryCaptureLeasePadding: TimeInterval = 3
    static let batteryWakeLeaseDuration: TimeInterval = 8
    static let batteryWakeLiveStartTimeout: TimeInterval = 30
    static let restrictedStartupSnapshotPrimingDuration: TimeInterval = 10
    static let liveCapacityExpansionRetryDelay: TimeInterval = 10
}

enum WallDensity: String, CaseIterable, Identifiable {
    case auto
    case oneColumn
    case twoColumns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneColumn: "1 Column"
        case .twoColumns: "2 Columns"
        case .auto: "Auto"
        }
    }

    var columnCount: Int {
        switch self {
        case .oneColumn: 1
        case .twoColumns, .auto: 2
        }
    }

    var preferredVisibleRows: Int {
        3
    }

    var visibleCameraCount: Int {
        return preferredVisibleRows * columnCount
    }

    static func selectableCases(for platform: CameraWallPlatform) -> [WallDensity] {
        switch platform {
        case .iPhone:
            allCases
        case .mac:
            [.auto]
        }
    }

    func stepped(by delta: Int) -> WallDensity {
        let allCases = Self.allCases
        guard let currentIndex = allCases.firstIndex(of: self) else {
            return .twoColumns
        }

        let nextIndex = max(0, min(allCases.count - 1, currentIndex + delta))
        return allCases[nextIndex]
    }
}

enum CameraWallPlatform {
    case iPhone
    case mac

    static var current: CameraWallPlatform {
        #if targetEnvironment(macCatalyst) || os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }
}

enum SettingsPresentation {
    static func showsWallDensitySection(for platform: CameraWallPlatform) -> Bool {
        switch platform {
        case .iPhone:
            true
        case .mac:
            false
        }
    }

    static func doneButtonPlacement(for platform: CameraWallPlatform) -> SettingsDoneButtonPlacement {
        switch platform {
        case .iPhone:
            .leading
        case .mac:
            .trailing
        }
    }
}

enum SettingsDoneButtonPlacement {
    case leading
    case trailing
}

enum MainWindowPresentation {
    static func shouldMaximizeOnLaunch(for platform: CameraWallPlatform) -> Bool {
        switch platform {
        case .iPhone:
            false
        case .mac:
            true
        }
    }

    static func minimumSize(for platform: CameraWallPlatform) -> CGSize? {
        switch platform {
        case .iPhone:
            nil
        case .mac:
            CGSize(width: 120, height: 48)
        }
    }
}

enum CameraWallInteraction {
    static func allowsDensityAdjustment(for platform: CameraWallPlatform) -> Bool {
        switch platform {
        case .iPhone:
            true
        case .mac:
            false
        }
    }
}

enum BatteryCameraVisibilityPolicy {
    static func isVisible(
        isHomeKitVisible: Bool,
        isBatteryCamera: Bool,
        batteryCameraVisibilityEnabled: Bool,
        showsBatteryCameraVisibilityToggle: Bool
    ) -> Bool {
        let isBatteryCameraVisible = batteryCameraVisibilityEnabled || !showsBatteryCameraVisibilityToggle
        return isHomeKitVisible && (!isBatteryCamera || isBatteryCameraVisible)
    }

    static func showsToggle(showsSetting: Bool, hasBatteryCameras: Bool) -> Bool {
        showsSetting && hasBatteryCameras
    }
}

enum BatteryPercentageOverlayPolicy {
    static func showsOverlay(
        showsBatteryPercentages: Bool,
        isBatteryCamera: Bool,
        batteryPercentage: Int?
    ) -> Bool {
        showsBatteryPercentages && isBatteryCamera && batteryPercentage != nil
    }

    static func normalizedPercentage(from value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }

        let rounded = Int(number.doubleValue.rounded())
        return min(100, max(0, rounded))
    }

    static func label(for batteryPercentage: Int?) -> String? {
        guard let batteryPercentage else { return nil }

        return "\(min(100, max(0, batteryPercentage)))%"
    }
}

enum CameraNameVisibility: String, CaseIterable, Identifiable {
    case show
    case oneColumnOnly
    case hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "Show"
        case .oneColumnOnly: "1 Column Only"
        case .hide: "Hide"
        }
    }

    func showsName(isOneColumnLayout: Bool) -> Bool {
        switch self {
        case .show:
            true
        case .oneColumnOnly:
            isOneColumnLayout
        case .hide:
            false
        }
    }
}

enum CameraWallAvailability {
    struct CharacteristicSnapshot {
        let serviceType: String
        let characteristicType: String
        let value: Any?
    }

    private static let homeKitCameraActiveCharacteristicTypes = Set([
        "0000021B-0000-1000-8000-0026BB765291",
        "public.hap.characteristics.homekit-camera-active"
    ].map(normalizedType))

    private static let manuallyDisabledCharacteristicTypes = Set([
        "00000227-0000-1000-8000-0026BB765291",
        "public.hap.characteristics.manually-disabled"
    ].map(normalizedType))

    static func isVisibleOnWall(
        isReachable: Bool,
        isAvailableInSession: Bool,
        isHomeKitCameraActive: Bool?
    ) -> Bool {
        isReachable && isHomeKitCameraActive != false
    }

    static func homeKitCameraActiveState(from value: Any?) -> Bool? {
        guard let value else {
            return nil
        }

        if let value = value as? Bool {
            return value
        }

        if let value = value as? NSNumber {
            return value.intValue != HMCharacteristicValueActivationState.inactive.rawValue
        }

        if let value = value as? Int {
            return value != HMCharacteristicValueActivationState.inactive.rawValue
        }

        return nil
    }

    static func homeKitCameraActiveState(from snapshots: [CharacteristicSnapshot]) -> Bool? {
        let homeKitActiveValues = snapshots
            .filter { homeKitCameraActiveCharacteristicTypes.contains(normalizedType($0.characteristicType)) }
            .compactMap { boolState(from: $0.value) }

        if homeKitActiveValues.contains(false) {
            return false
        }
        if homeKitActiveValues.contains(true) {
            return true
        }

        let isManuallyDisabled = snapshots
            .filter { manuallyDisabledCharacteristicTypes.contains(normalizedType($0.characteristicType)) }
            .compactMap { boolState(from: $0.value) }
            .contains(true)
        if isManuallyDisabled {
            return false
        }

        return nil
    }

    static func isCameraAvailabilityCharacteristic(serviceType _: String, characteristicType: String) -> Bool {
        let normalizedCharacteristicType = normalizedType(characteristicType)

        return homeKitCameraActiveCharacteristicTypes.contains(normalizedCharacteristicType)
            || manuallyDisabledCharacteristicTypes.contains(normalizedCharacteristicType)
    }

    static func shouldRemoveFromCurrentSession(errorCode _: Int?) -> Bool {
        // HomeKit communication errors may affect status/refresh, but never wall membership.
        false
    }

    private static func boolState(from value: Any?) -> Bool? {
        guard let value else {
            return nil
        }

        if let value = value as? Bool {
            return value
        }

        if let value = value as? NSNumber {
            return value.boolValue
        }

        if let value = value as? Int {
            return value != 0
        }

        return nil
    }

    private static func normalizedType(_ value: String) -> String {
        value.uppercased()
    }
}

enum SessionMode: String {
    case optimistic
    case constrained

    var summary: String {
        switch self {
        case .optimistic:
            "Observe is attempting live video for all visible cameras."
        case .constrained:
            "Observe is prioritizing live video for selected cameras and refreshing the rest as snapshots."
        }
    }
}

enum CameraSessionActivation {
    static func shouldRebuildSession(currentlyActive: Bool, nextActive: Bool) -> Bool {
        !currentlyActive && nextActive
    }
}

enum LiveStartRecoveryPolicy {
    static func shouldRestartStartingStream(
        requestedAt: Date?,
        timeout: TimeInterval,
        now: Date
    ) -> Bool {
        guard let requestedAt, timeout > 0 else { return false }
        return now.timeIntervalSince(requestedAt) >= timeout
    }
}

enum FeedDisplayState: Equatable {
    case idle
    case starting
    case live
    case snapshot
    case offline
    case failed(String)

    var shortLabel: String? {
        switch self {
        case .idle:
            "Loading"
        case .starting:
            "Live…"
        case .live:
            nil
        case .snapshot:
            "Snapshot"
        case .offline:
            "Offline"
        case .failed(let message):
            message
        }
    }
}

enum FeedRecencyTier: Int, Equatable {
    case live
    case recentSnapshot
    case staleSnapshot
    case empty
}

enum FeedRecoveryPhase: Equatable {
    case idle
    case batteryCapture
    case batteryWaiting
    case batteryWaitingPriming
}

enum CameraStatusIndicator: Equatable {
    case neutral
    case green
    case yellow
    case red
}

struct HomeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let isPrimary: Bool
}

struct CameraStatusSnapshot: Equatable {
    let label: String
    let recencyTier: FeedRecencyTier
    let recoveryPhase: FeedRecoveryPhase
    let indicator: CameraStatusIndicator
}

struct CameraDisplayClassification: Equatable {
    let status: CameraStatusSnapshot
    let isStale: Bool
}

enum CameraDisplayClassifier {
    static func classify(
        isStreaming: Bool,
        isBatteryCamera: Bool,
        recoveryPhase: FeedRecoveryPhase,
        liveStartedAt: Date? = nil,
        displayedStillDate: Date?,
        staleThreshold: TimeInterval,
        batteryTrustedStillThreshold: TimeInterval? = nil,
        batteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup,
        now: Date
    ) -> CameraDisplayClassification {
        if isBatteryCamera {
            let isBatteryStillVisuallyStale = isStillVisuallyStale(
                displayedStillDate: displayedStillDate,
                threshold: staleThreshold,
                now: now
            )
            switch recoveryPhase {
            case .batteryCapture:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: batteryCaptureLabel(
                            isStreaming: isStreaming,
                            liveStartedAt: liveStartedAt,
                            warmup: batteryCaptureWarmup,
                            now: now
                        ),
                        recencyTier: isStreaming ? .live : recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: staleThreshold,
                            now: now
                        ),
                        recoveryPhase: .batteryCapture,
                        indicator: isStreaming ? .green : .yellow
                    ),
                    isStale: isStreaming ? false : isBatteryStillVisuallyStale
                )
            case .batteryWaiting, .batteryWaitingPriming:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: recoveryPhase == .batteryWaitingPriming ? "Queued (Priming)" : "Queued",
                        recencyTier: recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: staleThreshold,
                            now: now
                        ),
                        recoveryPhase: recoveryPhase,
                        indicator: .yellow
                    ),
                    isStale: isBatteryStillVisuallyStale
                )
            case .idle:
                break
            }
        }

        if isStreaming {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: "Live",
                    recencyTier: .live,
                    recoveryPhase: .idle,
                    indicator: .green
                ),
                isStale: false
            )
        }

        guard let displayedStillDate else {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: "Stale",
                    recencyTier: .empty,
                    recoveryPhase: .idle,
                    indicator: .red
                ),
                isStale: true
            )
        }

        let age = max(0, now.timeIntervalSince(displayedStillDate))
        if age <= staleThreshold {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: recentLabel(age: age),
                    recencyTier: .recentSnapshot,
                    recoveryPhase: .idle,
                    indicator: .yellow
                ),
                isStale: false
            )
        }

        return CameraDisplayClassification(
            status: CameraStatusSnapshot(
                label: staleLabel(age: age),
                recencyTier: .staleSnapshot,
                recoveryPhase: .idle,
                indicator: .red
            ),
            isStale: true
        )
    }

    private static func recencyTier(
        displayedStillDate: Date?,
        threshold: TimeInterval,
        now: Date
    ) -> FeedRecencyTier {
        guard let displayedStillDate else { return .empty }
        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age <= threshold ? .recentSnapshot : .staleSnapshot
    }

    private static func batteryCaptureLabel(
        isStreaming: Bool,
        liveStartedAt: Date?,
        warmup: TimeInterval,
        now: Date
    ) -> String {
        guard isStreaming, let liveStartedAt else {
            return "Live Capture"
        }

        let remaining = max(0, warmup - now.timeIntervalSince(liveStartedAt))
        return "Live Capture (\(Int(ceil(remaining)))s)"
    }

    private static func isStillVisuallyStale(
        displayedStillDate: Date?,
        threshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard let displayedStillDate else { return true }
        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age > threshold
    }

    private static func recentLabel(age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds >= 60 {
            return "Recent (\(seconds / 60)m)"
        }
        return "Recent (\(seconds)s)"
    }

    private static func staleLabel(age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds >= 60 {
            return "Stale (\(seconds / 60)m)"
        }
        return "Stale (\(seconds)s)"
    }
}

import CoreGraphics
import Foundation
import HomeKit

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

enum LockIndicatorState: Equatable {
    case loading
    case locked
    case alert
}

enum TemperatureIndicatorState: Equatable {
    case loading
    case value(Int, isInRange: Bool)
    case alert
}

enum HomeSecurityReadPolicy {
    static func shouldLoad(
        hasVisibleCameras: Bool,
        allVisibleCamerasTrusted: Bool
    ) -> Bool {
        !hasVisibleCameras || allVisibleCamerasTrusted
    }
}

enum HomeTemperatureDiscoveryPolicy {
    static func includes(hasCurrentTemperature: Bool) -> Bool {
        hasCurrentTemperature
    }

    static func optionName(serviceName: String, accessoryName: String) -> String {
        serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? accessoryName
            : serviceName
    }
}

enum HomeSecurityStatusPolicy {
    static func lockState(
        isLoading: Bool,
        selectedIDs: Set<String>,
        valuesByID: [String: Int]
    ) -> LockIndicatorState {
        guard !isLoading else { return .loading }
        guard !selectedIDs.isEmpty else { return .alert }
        return selectedIDs.allSatisfy { valuesByID[$0] == 1 } ? .locked : .alert
    }

    static func temperatureState(
        isLoading: Bool,
        selectedIDs: Set<String>,
        celsiusValuesByID: [String: Double],
        lowFahrenheit: Int,
        highFahrenheit: Int
    ) -> TemperatureIndicatorState {
        guard !isLoading else { return .loading }
        let values = selectedIDs.compactMap { celsiusValuesByID[$0] }
        guard !selectedIDs.isEmpty,
              values.count == selectedIDs.count,
              values.allSatisfy(\.isFinite) else {
            return .alert
        }

        let averageCelsius = values.reduce(0, +) / Double(values.count)
        let fahrenheit = Int(
            Measurement(value: averageCelsius, unit: UnitTemperature.celsius)
                .converted(to: .fahrenheit)
                .value
                .rounded()
        )
        return .value(
            fahrenheit,
            isInRange: (lowFahrenheit...highFahrenheit).contains(fahrenheit)
        )
    }
}

enum SuccessIndicatorPolicy {
    static func isHealthy(
        hasVisibleCameras: Bool,
        allVisibleCamerasReady: Bool,
        isLockStatusEnabled: Bool,
        lockState: LockIndicatorState,
        isHomeTemperatureEnabled: Bool,
        temperatureState: TemperatureIndicatorState
    ) -> Bool {
        guard hasVisibleCameras, allVisibleCamerasReady else { return false }
        guard !isLockStatusEnabled || lockState == .locked else { return false }

        if isHomeTemperatureEnabled {
            guard case .value(_, isInRange: true) = temperatureState else { return false }
        }

        return true
    }
}

enum SuccessIndicatorNetworkPolicy {
    static func allowsAnimation(
        onlyOffHomeNetwork: Bool,
        connectionResolution: CameraConnectionModeResolution
    ) -> Bool {
        guard onlyOffHomeNetwork else { return true }

        return switch connectionResolution.reason {
        case .notOnWiFi, .homeNetworkMismatch:
            true
        case .homeNetworkMatched, .homeNetworkNotConfigured, .ssidUnavailable:
            false
        }
    }
}

struct SuccessIndicatorOpenState {
    private(set) var hasAnimatedThisOpen = false

    mutating func beginOpen() {
        hasAnimatedThisOpen = false
    }

    mutating func shouldAnimate(
        isEnabled: Bool,
        isHealthy: Bool,
        isAllowedByNetwork: Bool = true
    ) -> Bool {
        guard isEnabled, isHealthy, isAllowedByNetwork, !hasAnimatedThisOpen else { return false }
        hasAnimatedThisOpen = true
        return true
    }
}

struct SuccessIndicatorAnimationPresentation {
    let drawProgress: Double
    let coreOpacity: Double
    let radiance: Double
    let trailPhase: Double
    let trailOpacity: Double
    let sparkleIntensity: Double
    let isComplete: Bool
}

enum SuccessIndicatorAnimationTimeline {
    static let duration: TimeInterval = 3.2

    static func presentation(
        at elapsedTime: TimeInterval,
        reduceMotion: Bool
    ) -> SuccessIndicatorAnimationPresentation {
        let elapsed = max(0, elapsedTime)
        guard elapsed < duration else {
            return SuccessIndicatorAnimationPresentation(
                drawProgress: 1,
                coreOpacity: 0,
                radiance: 0,
                trailPhase: 0,
                trailOpacity: 0,
                sparkleIntensity: 0,
                isComplete: true
            )
        }

        let fade = elapsed <= 2.35 ? 1 : clamp(1 - ((elapsed - 2.35) / 0.85))

        if reduceMotion {
            let intro = clamp(elapsed / 0.22)
            let breath = 0.78 + (0.16 * sin(elapsed * .pi * 1.4))
            return SuccessIndicatorAnimationPresentation(
                drawProgress: 1,
                coreOpacity: intro * fade,
                radiance: max(0, breath) * intro * fade,
                trailPhase: 0,
                trailOpacity: 0,
                sparkleIntensity: 0.38 * intro * fade,
                isComplete: false
            )
        }

        let intro = clamp(elapsed / 0.18)
        let drawProgress = clamp(elapsed / 0.9)
        let radiancePulse = 0.78 + (0.22 * sin(.pi * clamp(elapsed / 1.6)))
        let sparkleIntensity: Double
        if elapsed < 0.55 {
            sparkleIntensity = 0
        } else if elapsed < 1 {
            sparkleIntensity = clamp((elapsed - 0.55) / 0.45)
        } else {
            sparkleIntensity = clamp(1 - ((elapsed - 1) / 1.35))
        }

        return SuccessIndicatorAnimationPresentation(
            drawProgress: drawProgress,
            coreOpacity: intro * fade,
            radiance: radiancePulse * intro * fade,
            trailPhase: elapsed * 0.34,
            trailOpacity: clamp(elapsed / 0.25) * fade,
            sparkleIntensity: sparkleIntensity * fade,
            isComplete: false
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
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

struct RestrictedStartupCameraActivity: Equatable {
    let hasCurrentPicture: Bool
    let hasActiveWork: Bool
    let isRecovering: Bool
}

struct RestrictedStartupOverlayPresentation: Equatable {
    let cameraCount: Int
    let checkingCount: Int
    let waitingCount: Int
    let retryingCount: Int

    var cameraCountText: String {
        "\(cameraCount) \(cameraCount == 1 ? "Camera" : "Cameras") Found"
    }

    var activityText: String {
        [
            checkingCount > 0 ? "Trying \(checkingCount)" : nil,
            waitingCount > 0 ? "Waiting \(waitingCount)" : nil,
            retryingCount > 0 ? "Retrying \(retryingCount)" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

enum RestrictedStartupOverlayPolicy {
    static func presentation(
        isRestrictedStartup: Bool,
        hasHome: Bool,
        cameras: [RestrictedStartupCameraActivity]
    ) -> RestrictedStartupOverlayPresentation? {
        guard isRestrictedStartup,
              hasHome,
              !cameras.isEmpty,
              !cameras.contains(where: \.hasCurrentPicture) else {
            return nil
        }

        let retryingCount = cameras.count(where: \.isRecovering)
        let checkingCount = cameras.count { !$0.isRecovering && $0.hasActiveWork }
        let waitingCount = cameras.count - retryingCount - checkingCount

        return RestrictedStartupOverlayPresentation(
            cameraCount: cameras.count,
            checkingCount: checkingCount,
            waitingCount: waitingCount,
            retryingCount: retryingCount
        )
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

    static func isCameraAvailabilityCharacteristic(characteristicType: String) -> Bool {
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

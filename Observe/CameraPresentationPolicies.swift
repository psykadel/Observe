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

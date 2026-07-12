import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class ObservePreferencesTests: ObserveTestCase {
    func testBatteryCameraVisibilityPolicyHidesOnlyBatteryCamerasWhenDisabled() {
        XCTAssertTrue(
            BatteryCameraVisibilityPolicy.isVisible(
                isHomeKitVisible: true,
                isBatteryCamera: true,
                batteryCameraVisibilityEnabled: true,
                showsBatteryCameraVisibilityToggle: true
            )
        )
        XCTAssertFalse(
            BatteryCameraVisibilityPolicy.isVisible(
                isHomeKitVisible: true,
                isBatteryCamera: true,
                batteryCameraVisibilityEnabled: false,
                showsBatteryCameraVisibilityToggle: true
            )
        )
        XCTAssertTrue(
            BatteryCameraVisibilityPolicy.isVisible(
                isHomeKitVisible: true,
                isBatteryCamera: false,
                batteryCameraVisibilityEnabled: false,
                showsBatteryCameraVisibilityToggle: true
            )
        )
        XCTAssertFalse(
            BatteryCameraVisibilityPolicy.isVisible(
                isHomeKitVisible: false,
                isBatteryCamera: false,
                batteryCameraVisibilityEnabled: true,
                showsBatteryCameraVisibilityToggle: true
            )
        )
    }
    func testBatteryCameraVisibilityPolicyForcesBatteryVisibleWhenToggleHidden() {
        XCTAssertTrue(
            BatteryCameraVisibilityPolicy.isVisible(
                isHomeKitVisible: true,
                isBatteryCamera: true,
                batteryCameraVisibilityEnabled: false,
                showsBatteryCameraVisibilityToggle: false
            )
        )
    }
    func testBatteryCameraVisibilityToggleRequiresSettingAndBatteryCameras() {
        XCTAssertTrue(BatteryCameraVisibilityPolicy.showsToggle(showsSetting: true, hasBatteryCameras: true))
        XCTAssertFalse(BatteryCameraVisibilityPolicy.showsToggle(showsSetting: false, hasBatteryCameras: true))
        XCTAssertFalse(BatteryCameraVisibilityPolicy.showsToggle(showsSetting: true, hasBatteryCameras: false))
    }
    func testBatteryPercentageOverlayRequiresSettingBatteryCameraAndData() {
        XCTAssertTrue(
            BatteryPercentageOverlayPolicy.showsOverlay(
                showsBatteryPercentages: true,
                isBatteryCamera: true,
                batteryPercentage: 72
            )
        )
        XCTAssertFalse(
            BatteryPercentageOverlayPolicy.showsOverlay(
                showsBatteryPercentages: false,
                isBatteryCamera: true,
                batteryPercentage: 72
            )
        )
        XCTAssertFalse(
            BatteryPercentageOverlayPolicy.showsOverlay(
                showsBatteryPercentages: true,
                isBatteryCamera: false,
                batteryPercentage: 72
            )
        )
        XCTAssertFalse(
            BatteryPercentageOverlayPolicy.showsOverlay(
                showsBatteryPercentages: true,
                isBatteryCamera: true,
                batteryPercentage: nil
            )
        )
    }
    func testBatteryPercentageOverlaySanitizesAndFormatsValues() {
        XCTAssertEqual(BatteryPercentageOverlayPolicy.normalizedPercentage(from: NSNumber(value: 71.6)), 72)
        XCTAssertEqual(BatteryPercentageOverlayPolicy.normalizedPercentage(from: NSNumber(value: -8)), 0)
        XCTAssertEqual(BatteryPercentageOverlayPolicy.normalizedPercentage(from: NSNumber(value: 140)), 100)
        XCTAssertNil(BatteryPercentageOverlayPolicy.normalizedPercentage(from: "82"))
        XCTAssertEqual(BatteryPercentageOverlayPolicy.label(for: 72), "72%")
        XCTAssertNil(BatteryPercentageOverlayPolicy.label(for: nil))
    }

    @MainActor
    func testPreferencesIgnoreLegacySnapshotLimitAndRoundTripBatterySettings() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(6, forKey: "observe.maxConcurrentSnapshotRequests")

        let preferences = ObservePreferences(userDefaults: defaults)
        XCTAssertFalse(preferences.isBatteryWakeCamera(id: "battery"))
        XCTAssertTrue(preferences.isBatteryCameraVisibilityEnabled)
        XCTAssertTrue(preferences.showsBatteryCameraVisibilityToggle)
        XCTAssertFalse(preferences.showsBatteryPercentages)
        XCTAssertEqual(preferences.batteryCaptureWarmupSeconds, 5)
        XCTAssertFalse(
            Mirror(reflecting: preferences).children.contains {
                $0.label == "maxConcurrentSnapshotRequests"
            }
        )

        preferences.setBatteryWakeEnabled(true, for: "battery")
        preferences.setBatteryCameraVisibilityEnabled(false)
        preferences.setBatteryCameraVisibilityToggleShown(false)
        preferences.setBatteryPercentagesShown(true)
        preferences.setBatteryWakeTriggerSeconds(75)
        preferences.setBatteryCaptureWarmupSeconds(9)
        preferences.setBatteryStaleSeconds(150)
        XCTAssertTrue(preferences.isBatteryWakeCamera(id: "battery"))

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertTrue(reloaded.isBatteryWakeCamera(id: "battery"))
        XCTAssertTrue(reloaded.isBatteryCameraVisibilityEnabled)
        XCTAssertFalse(reloaded.showsBatteryCameraVisibilityToggle)
        XCTAssertTrue(reloaded.showsBatteryPercentages)
        XCTAssertEqual(reloaded.batteryWakeTriggerSeconds, 75)
        XCTAssertEqual(reloaded.batteryCaptureWarmupSeconds, 9)
        XCTAssertEqual(reloaded.batteryStaleSeconds, 150)

        defaults.removePersistentDomain(forName: suiteName)
    }
    func testNumberSettingsExcludeInternalSnapshotConcurrency() {
        XCTAssertEqual(
            NumberSettingKind.allCases,
            [.staleThreshold, .batteryWakeTrigger, .batteryCaptureWarmup, .batteryStale]
        )
    }
    func testBatteryNumberSettingsHaveShortDescriptions() {
        XCTAssertEqual(
            NumberSettingKind.batteryWakeTrigger.helperText,
            "When a battery camera still gets this old, start a live capture."
        )
        XCTAssertEqual(
            NumberSettingKind.batteryCaptureWarmup.helperText,
            "After live starts, wait this long before saving the still."
        )
        XCTAssertEqual(
            NumberSettingKind.batteryStale.helperText,
            "Mark a battery still stale when it gets this old."
        )
    }
    func testNumberSettingDraftClampsTypedAndAdjustedValuesToMinimum() {
        var draft = NumberSettingDraft(value: 5, minimumValue: 1)

        draft.adjust(by: -10)
        XCTAssertEqual(draft.value, 1)
        XCTAssertEqual(draft.text, "1")

        draft.updateText("0")
        XCTAssertEqual(draft.value, 1)
        XCTAssertEqual(draft.text, "0")

        draft.updateText("42")
        XCTAssertEqual(draft.value, 42)
        XCTAssertEqual(draft.text, "42")
    }
    func testNumberSettingDraftIgnoresNonNumericTypedTextUntilValid() {
        var draft = NumberSettingDraft(value: 15, minimumValue: 1)

        draft.updateText("")
        XCTAssertEqual(draft.value, 15)
        XCTAssertEqual(draft.text, "")

        draft.updateText("abc")
        XCTAssertEqual(draft.value, 15)
        XCTAssertEqual(draft.text, "abc")

        draft.setValue(30)
        XCTAssertEqual(draft.value, 30)
        XCTAssertEqual(draft.text, "30")
    }
    @MainActor
    func testCameraNameVisibilityPreferenceRoundTrip() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.cameraNameVisibility, .show)

        preferences.cameraNameVisibility = .oneColumnOnly
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).cameraNameVisibility, .oneColumnOnly)

        preferences.cameraNameVisibility = .hide
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).cameraNameVisibility, .hide)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testWallDensitySwipeNavigationPersistsInSettingsOrder() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        preferences.wallDensity = .auto

        preferences.adjustDensity(withHorizontalSwipe: -80)
        XCTAssertEqual(preferences.wallDensity, .oneColumn)
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).wallDensity, .oneColumn)

        preferences.adjustDensity(withHorizontalSwipe: -80)
        XCTAssertEqual(preferences.wallDensity, .twoColumns)

        preferences.adjustDensity(withHorizontalSwipe: 80)
        XCTAssertEqual(preferences.wallDensity, .oneColumn)
        preferences.adjustDensity(withHorizontalSwipe: 80)
        XCTAssertEqual(preferences.wallDensity, .auto)

        defaults.removePersistentDomain(forName: suiteName)
    }
}

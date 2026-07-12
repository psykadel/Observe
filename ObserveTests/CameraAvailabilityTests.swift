import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraAvailabilityTests: ObserveTestCase {
    func testCameraNetworkClassPolicyRequiresSatisfiedWiFiPath() {
        XCTAssertEqual(
            CameraNetworkClassPolicy.classify(
                isSatisfied: true,
                usesWiFi: true,
                usesCellular: false
            ),
            .wifi
        )
        XCTAssertEqual(
            CameraNetworkClassPolicy.classify(
                isSatisfied: true,
                usesWiFi: false,
                usesCellular: true
            ),
            .cellular
        )
        XCTAssertEqual(
            CameraNetworkClassPolicy.classify(
                isSatisfied: false,
                usesWiFi: true,
                usesCellular: false
            ),
            .unknown
        )
        XCTAssertEqual(
            CameraNetworkClassPolicy.classify(
                isSatisfied: true,
                usesWiFi: false,
                usesCellular: false
            ),
            .other
        )
    }
    func testCameraSessionGenerationAcceptsOnlyActiveSession() {
        XCTAssertTrue(
            CameraSessionGeneration.accepts(callbackGeneration: 4, activeGeneration: 4)
        )
        XCTAssertFalse(
            CameraSessionGeneration.accepts(callbackGeneration: 3, activeGeneration: 4)
        )
    }
    func testAlreadyActiveScenePhaseDoesNotRebuildCameraSession() {
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: true, nextActive: true))
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: true, nextActive: false))
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: false, nextActive: false))
        XCTAssertTrue(CameraSessionActivation.shouldRebuildSession(currentlyActive: false, nextActive: true))
    }
    func testHomeKitOffAndNotRespondingRemoveCameraFromWallSlots() {
        XCTAssertTrue(CameraWallAvailability.isVisibleOnWall(isReachable: true, isHomeKitCameraActive: true))
        XCTAssertTrue(CameraWallAvailability.isVisibleOnWall(isReachable: true, isHomeKitCameraActive: nil))
        XCTAssertFalse(CameraWallAvailability.isVisibleOnWall(isReachable: false, isHomeKitCameraActive: true))
        XCTAssertFalse(CameraWallAvailability.isVisibleOnWall(isReachable: true, isHomeKitCameraActive: false))
    }
    func testHomeKitInactiveCharacteristicRemovesCameraFromWallSlots() {
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: HMCharacteristicValueActivationState.active.rawValue), true)
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: HMCharacteristicValueActivationState.inactive.rawValue), false)
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: NSNumber(value: HMCharacteristicValueActivationState.active.rawValue)), true)
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: NSNumber(value: HMCharacteristicValueActivationState.inactive.rawValue)), false)
        XCTAssertNil(CameraWallAvailability.homeKitCameraActiveState(from: nil))
    }
    func testHomeKitCameraActiveCharacteristicControlsWallSlots() {
        let offSnapshot = CameraWallAvailability.CharacteristicSnapshot(
            characteristicType: "0000021b-0000-1000-8000-0026bb765291",
            value: false
        )
        let onSnapshot = CameraWallAvailability.CharacteristicSnapshot(
            characteristicType: "0000021B-0000-1000-8000-0026BB765291",
            value: true
        )

        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: [offSnapshot]), false)
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: [onSnapshot]), true)
    }
    func testRTPInactiveAloneDoesNotRemoveCameraFromWallSlots() {
        let rtpInactive = CameraWallAvailability.CharacteristicSnapshot(
            characteristicType: HMCharacteristicTypeActive,
            value: false
        )
        let rtpActive = CameraWallAvailability.CharacteristicSnapshot(
            characteristicType: HMCharacteristicTypeActive,
            value: true
        )
        let detectingActivity = CameraWallAvailability.CharacteristicSnapshot(
            characteristicType: "0000021B-0000-1000-8000-0026BB765291",
            value: true
        )

        XCTAssertNil(CameraWallAvailability.homeKitCameraActiveState(from: [rtpInactive]))
        XCTAssertNil(CameraWallAvailability.homeKitCameraActiveState(from: [rtpActive]))
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: [rtpInactive, detectingActivity]), true)
    }
    func testTransientHomeKitErrorsDoNotRemoveCameraFromWallSlots() {
        XCTAssertFalse(CameraWallAvailability.shouldRemoveFromCurrentSession(errorCode: HMError.Code.networkUnavailable.rawValue))
        XCTAssertFalse(CameraWallAvailability.shouldRemoveFromCurrentSession(errorCode: HMError.Code.accessoryCommunicationFailure.rawValue))
        XCTAssertFalse(CameraWallAvailability.shouldRemoveFromCurrentSession(errorCode: HMError.Code.timedOutWaitingForAccessory.rawValue))
        XCTAssertFalse(CameraWallAvailability.shouldRemoveFromCurrentSession(errorCode: HMError.Code.maximumObjectLimitReached.rawValue))
        XCTAssertFalse(CameraWallAvailability.shouldRemoveFromCurrentSession(errorCode: HMError.Code.accessoryIsBusy.rawValue))
    }
}

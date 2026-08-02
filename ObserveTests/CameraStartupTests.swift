import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraStartupTests: ObserveTestCase {
    func testAppEntitlementsAllowMacLocationForSSIDLookup() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let entitlementsURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Observe/Observe.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            entitlements["com.apple.security.personal-information.location"] as? Bool,
            true
        )
    }

    func testMacCatalystSSIDLookupUsesNativeMacFallbackRegardlessOfPrimaryPath() {
        let sources = CurrentWiFiSSIDLookupPolicy.sources(
            isMacCatalyst: true,
            networkClass: .other
        )

        XCTAssertEqual(sources, [.networkExtension, .coreWLAN])
    }

    func testIOSSSIDLookupOnlyRunsWhileThePathUsesWiFi() {
        XCTAssertEqual(
            CurrentWiFiSSIDLookupPolicy.sources(
                isMacCatalyst: false,
                networkClass: .wifi
            ),
            [.networkExtension]
        )
        XCTAssertTrue(
            CurrentWiFiSSIDLookupPolicy.sources(
                isMacCatalyst: false,
                networkClass: .other
            ).isEmpty
        )
    }

    func testAvailableSSIDCanMatchHomeNetworkWhenMacPrimaryPathIsNotWiFi() {
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .other,
                currentSSID: "Backmeyer Home",
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .homeNetwork, reason: .homeNetworkMatched)
        )
    }

    func testHomeNetworkModeRequiresAnExactNonemptySSIDMatch() {
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .wifi,
                currentSSID: "Backmeyer Home",
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .homeNetwork, reason: .homeNetworkMatched)
        )
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .wifi,
                currentSSID: "backmeyer home",
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .restricted, reason: .homeNetworkMismatch)
        )
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .wifi,
                currentSSID: "Backmeyer Home",
                configuredHomeSSID: ""
            ),
            CameraConnectionModeResolution(mode: .restricted, reason: .homeNetworkNotConfigured)
        )
    }

    func testHomeNetworkModeExplainsEveryRestrictedFallback() {
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .cellular,
                currentSSID: nil,
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .restricted, reason: .notOnWiFi)
        )
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .wifi,
                currentSSID: nil,
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .restricted, reason: .ssidUnavailable)
        )
        XCTAssertEqual(
            CameraConnectionModePolicy.resolve(
                networkClass: .wifi,
                currentSSID: "Coffee Shop",
                configuredHomeSSID: "Backmeyer Home"
            ),
            CameraConnectionModeResolution(mode: .restricted, reason: .homeNetworkMismatch)
        )
    }

    func testHomeNetworkStartupPolicyStartsEveryVisibleCameraWithoutCapacityOrOrderingLimits() {
        let selectedIDs = Set(["first", "second", "battery"])
        let policy = StartupLivePolicy.homeNetwork(liveIDs: selectedIDs)
        let feeds = [
            makeFeed(id: "first", priorityIndex: 2, livePriorityIndex: 2),
            makeFeed(id: "second", priorityIndex: 0, livePriorityIndex: 1),
            makeFeed(
                id: "battery",
                priorityIndex: 1,
                livePriorityIndex: 0,
                isBatteryWakeCamera: true
            )
        ]

        let plan = planner.makePlan(
            feeds: feeds,
            liveCapacity: 1,
            startupLivePolicy: policy,
            now: now
        )

        XCTAssertEqual(Set(liveIDs(in: plan)), selectedIDs)

        var controller = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: Int.max),
            sustainableCapacity: 1
        )
        let decision = controller.reconcile(
            intents: selectedIDs.map {
                LiveIntent(id: $0, role: .steadyState, priorityIndex: 0)
            },
            transports: Dictionary(
                uniqueKeysWithValues: selectedIDs.map { ($0, LiveTransportPhase.idle) }
            ),
            plannerCapacity: selectedIDs.count,
            now: now
        )

        XCTAssertEqual(Set(decision.startIDs), selectedIDs)
        XCTAssertTrue(decision.queuedStartIDs.isEmpty)
    }

    func testRestrictedLiveFillUsesLiveOrderImmediately() {
        XCTAssertTrue(
            LiveAdmissionOrderingPolicy.usesLiveOrder(
                connectionMode: .restricted
            )
        )
        XCTAssertFalse(
            LiveAdmissionOrderingPolicy.usesLiveOrder(
                connectionMode: .homeNetwork
            )
        )
    }

    func testRestrictedMetadataWaitsForInitialMediaAdmissionThenRunsOneWide() {
        let mode = StartupMetadataWorkMode.resolve(connectionMode: .restricted)

        XCTAssertEqual(mode, .mediaPrioritySerial)
        XCTAssertEqual(
            StartupMetadataAdmissionPolicy.maxConcurrentOperations(
                mode: mode,
                initialMediaAdmissionCompleted: false
            ),
            0
        )
        XCTAssertEqual(
            StartupMetadataAdmissionPolicy.maxConcurrentOperations(
                mode: mode,
                initialMediaAdmissionCompleted: true
            ),
            1
        )
    }
    func testRestrictedMetadataKeepsReadsBehindTrustAndMediaWork() {
        let mode = StartupMetadataWorkMode.mediaPrioritySerial

        XCTAssertTrue(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .availabilityNotification,
                mode: mode,
                initialMediaAdmissionCompleted: true,
                allVisibleFeedsTrusted: false,
                criticalMediaWorkActive: true
            )
        )
        XCTAssertTrue(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .batteryNotification,
                mode: mode,
                initialMediaAdmissionCompleted: true,
                allVisibleFeedsTrusted: false,
                criticalMediaWorkActive: true
            )
        )
        XCTAssertFalse(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .availabilityRead,
                mode: mode,
                initialMediaAdmissionCompleted: true,
                allVisibleFeedsTrusted: false,
                criticalMediaWorkActive: false
            )
        )
        XCTAssertFalse(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .batteryRead,
                mode: mode,
                initialMediaAdmissionCompleted: true,
                allVisibleFeedsTrusted: true,
                criticalMediaWorkActive: true
            )
        )
        XCTAssertTrue(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .availabilityRead,
                mode: mode,
                initialMediaAdmissionCompleted: true,
                allVisibleFeedsTrusted: true,
                criticalMediaWorkActive: false
            )
        )
    }
    func testCompletedRestrictedMetadataReportsCompleteEvenWhenMediaBecomesBusyAgain() {
        XCTAssertEqual(
            StartupMetadataGateStatePolicy.resolve(
                mode: .mediaPrioritySerial,
                initialMediaAdmissionCompleted: true,
                hasQueuedOperations: false,
                activeOperationKind: nil,
                completedOperationCount: 8,
                allVisibleFeedsTrusted: true,
                criticalMediaWorkActive: true
            ),
            "complete"
        )
    }
    func testHomeNetworkMetadataKeepsImmediateParallelBehavior() {
        let mode = StartupMetadataWorkMode.resolve(connectionMode: .homeNetwork)

        XCTAssertEqual(mode, .immediateParallel)
        XCTAssertTrue(
            StartupMetadataAdmissionPolicy.shouldIssue(
                kind: .batteryRead,
                mode: mode,
                initialMediaAdmissionCompleted: false,
                allVisibleFeedsTrusted: false,
                criticalMediaWorkActive: true
            )
        )
        XCTAssertEqual(
            StartupMetadataAdmissionPolicy.maxConcurrentOperations(
                mode: mode,
                initialMediaAdmissionCompleted: false
            ),
            Int.max
        )
    }
    func testStartupMetadataRegistersAllNotificationsBeforeExplicitReads() {
        let operations = [
            StartupMetadataOperationDescriptor(
                feedID: "battery",
                characteristicID: "battery-level",
                characteristicType: "battery",
                kind: .batteryRead
            ),
            StartupMetadataOperationDescriptor(
                feedID: "front",
                characteristicID: "active",
                characteristicType: "active",
                kind: .availabilityRead
            ),
            StartupMetadataOperationDescriptor(
                feedID: "front",
                characteristicID: "active",
                characteristicType: "active",
                kind: .availabilityNotification
            ),
            StartupMetadataOperationDescriptor(
                feedID: "battery",
                characteristicID: "battery-level",
                characteristicType: "battery",
                kind: .batteryNotification
            )
        ]

        XCTAssertEqual(
            StartupMetadataAdmissionPolicy.ordered(operations).map(\.kind),
            [
                .availabilityNotification,
                .batteryNotification,
                .availabilityRead,
                .batteryRead
            ]
        )
    }
    func testRestrictedStartupSnapshotFailureMovesWiredCameraToRecoveryImmediately() {
        var state = StartupCameraState()

        state.apply(.snapshotRequested(at: now), isBatteryCamera: false)
        state.apply(.snapshotFailed(entersRecovery: true), isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .recovering)
        XCTAssertTrue(state.snapshotAttempted)
        XCTAssertTrue(state.snapshotFailed)
    }
    func testSnapshotFailureCanRemainPendingWhenRecoveryIsDisabled() {
        var state = StartupCameraState()

        state.apply(.snapshotRequested(at: now), isBatteryCamera: false)
        state.apply(.snapshotFailed(entersRecovery: false), isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .pending)
    }
    func testStartupCameraStateTreatsBatteryLiveAsTrustedImmediately() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.liveStarted, isBatteryCamera: true)

        XCTAssertEqual(state.resolution, .trusted)
    }
    func testBatteryLiveResolvesStartupWithoutCapturedStill() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.liveStarted, isBatteryCamera: true)

        XCTAssertEqual(state.livePath, .succeeded)
        XCTAssertEqual(state.resolution, .trusted)
    }
    func testStartupCameraStateAllowsLiveRetryAfterBothPathsFail() {
        var state = StartupCameraState()
        state.apply(.snapshotFailed(entersRecovery: false), isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)

        let retryAt = now.addingTimeInterval(2)
        state.apply(.liveRequested(at: retryAt), isBatteryCamera: false)

        XCTAssertEqual(state.livePath, .inFlight(startedAt: retryAt))
        XCTAssertEqual(state.liveFallbackStartedAt, retryAt)

        state.apply(.liveStarted, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .trusted)
    }
    func testStartupCameraStateWiredLiveStartBecomesTrusted() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: false)
        XCTAssertEqual(state.liveFallbackStartedAt, now)

        state.apply(.liveStarted, isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .trusted)
        XCTAssertNil(state.liveFallbackStartedAt)
    }
    func testStartupCameraStateResetReturnsToWaiting() {
        var state = StartupCameraState()
        state.apply(.snapshotFailed(entersRecovery: false), isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .recovering)

        state.apply(.reset, isBatteryCamera: false)

        XCTAssertEqual(state, StartupCameraState())
    }
    func testHomeNetworkUsesPlainLiveForDueBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired", priorityIndex: 0),
                makeFeed(
                    id: "battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 90,
                    isBatteryWakeCamera: true
                )
            ],
            liveCapacity: 2,
            startupLivePolicy: .homeNetwork(liveIDs: ["wired", "battery"]),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "wired"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }
    func testStartupLiveTimeoutPolicySeparatesWiredAndBatteryWork() {
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: true,
                isBatteryCamera: false
            ),
            8
        )
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: true,
                isBatteryCamera: true
            ),
            30
        )
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: false,
                isBatteryCamera: false
            ),
            30
        )
    }
    func testRestrictedStartupOverlayCountsVisibleCameras() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(hasCurrentPicture: false),
                RestrictedStartupCameraActivity(hasCurrentPicture: false),
                RestrictedStartupCameraActivity(hasCurrentPicture: false)
            ]
        )

        XCTAssertEqual(
            presentation,
            RestrictedStartupOverlayPresentation(cameraCount: 3)
        )
    }
    func testRestrictedStartupOverlayHidesAsSoonAsAnyCameraHasCurrentPicture() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(hasCurrentPicture: false),
                RestrictedStartupCameraActivity(hasCurrentPicture: true)
            ]
        )

        XCTAssertNil(presentation)
    }
    func testRestrictedStartupOverlayRequiresRestrictedStartupHomeAndCameras() {
        let waitingCamera = RestrictedStartupCameraActivity(hasCurrentPicture: false)

        XCTAssertNil(
            RestrictedStartupOverlayPolicy.presentation(
                isRestrictedStartup: false,
                hasHome: true,
                cameras: [waitingCamera]
            )
        )
        XCTAssertNil(
            RestrictedStartupOverlayPolicy.presentation(
                isRestrictedStartup: true,
                hasHome: false,
                cameras: [waitingCamera]
            )
        )
        XCTAssertNil(
            RestrictedStartupOverlayPolicy.presentation(
                isRestrictedStartup: true,
                hasHome: true,
                cameras: []
            )
        )
    }
    func testRestrictedStartupOverlayRemainsVisibleWhileNoCameraHasAPicture() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(hasCurrentPicture: false),
                RestrictedStartupCameraActivity(hasCurrentPicture: false)
            ]
        )

        XCTAssertEqual(presentation?.cameraCount, 2)
    }
    func testRestrictedStartupOverlayCopyShowsOnlyContactingCameraCount() {
        let presentation = RestrictedStartupOverlayPresentation(cameraCount: 3)

        XCTAssertEqual(presentation.cameraCountText, "Contacting 3 Cameras")
    }
}

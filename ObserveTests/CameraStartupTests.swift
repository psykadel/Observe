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
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: policy,
            now: now
        )

        XCTAssertEqual(Set(liveIDs(in: plan)), selectedIDs)
        XCTAssertEqual(policy.pendingStartLimit, Int.max)

        var controller = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: policy.pendingStartLimit),
            sustainableCapacity: 1
        )
        let decision = controller.reconcile(
            intents: selectedIDs.map {
                LiveIntent(id: $0, role: .steadyState, priorityIndex: 0)
            },
            transports: Dictionary(
                uniqueKeysWithValues: selectedIDs.map { ($0, LiveTransportPhase.idle) }
            ),
            preserveActiveDuringCoverage: false,
            plannerCapacity: selectedIDs.count,
            now: now
        )

        XCTAssertEqual(Set(decision.startIDs), selectedIDs)
        XCTAssertTrue(decision.queuedStartIDs.isEmpty)
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
    func testRestrictedTrustGateSuppressesRefreshesForAlreadyTrustedFeeds() {
        XCTAssertFalse(
            TrustedFrameSnapshotAdmissionPolicy.shouldQueue(
                isTrusted: true,
                startupCoverageActive: false,
                startupLiveRampActive: false,
                restrictedLiveGateClosed: true
            )
        )
        XCTAssertTrue(
            TrustedFrameSnapshotAdmissionPolicy.shouldQueue(
                isTrusted: false,
                startupCoverageActive: false,
                startupLiveRampActive: false,
                restrictedLiveGateClosed: true
            )
        )
        XCTAssertTrue(
            TrustedFrameSnapshotAdmissionPolicy.shouldQueue(
                isTrusted: true,
                startupCoverageActive: false,
                startupLiveRampActive: false,
                restrictedLiveGateClosed: false
            )
        )
        XCTAssertFalse(
            TrustedFrameSnapshotAdmissionPolicy.shouldQueue(
                isTrusted: true,
                startupCoverageActive: false,
                startupLiveRampActive: true,
                restrictedLiveGateClosed: false
            )
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
    func testRestrictedStartupPhaseIsDerivedFromInitialPassAndTrust() {
        XCTAssertEqual(
            RestrictedStartupPhase.resolve(
                initialSnapshotPassActive: true,
                allVisibleFeedsTrusted: false,
                allVisibleFeedsCompletedStartupCoverage: false
            ),
            .initialSnapshotPass
        )
        XCTAssertEqual(
            RestrictedStartupPhase.resolve(
                initialSnapshotPassActive: false,
                allVisibleFeedsTrusted: false,
                allVisibleFeedsCompletedStartupCoverage: false
            ),
            .snapshotRecovery
        )
        XCTAssertEqual(
            RestrictedStartupPhase.resolve(
                initialSnapshotPassActive: false,
                allVisibleFeedsTrusted: true,
                allVisibleFeedsCompletedStartupCoverage: true
            ),
            .liveFill
        )
        XCTAssertFalse(RestrictedStartupPhase.initialSnapshotPass.isOrdinaryLiveGateOpen)
        XCTAssertFalse(RestrictedStartupPhase.snapshotRecovery.isOrdinaryLiveGateOpen)
        XCTAssertTrue(RestrictedStartupPhase.liveFill.isOrdinaryLiveGateOpen)
    }
    func testRestrictedStartupPhaseDoesNotReopenAfterCompletedCoverageBecomesOld() {
        XCTAssertEqual(
            RestrictedStartupPhase.resolve(
                initialSnapshotPassActive: false,
                allVisibleFeedsTrusted: false,
                allVisibleFeedsCompletedStartupCoverage: true
            ),
            .liveFill
        )
    }
    func testRestrictedSnapshotOnlyPolicyAllowsOnePendingBatteryStart() {
        XCTAssertEqual(StartupLivePolicy.restrictedSnapshotOnly.pendingStartLimit, 1)
    }
    func testStartupLiveRampUsesTwoPendingSlotsAfterFastFirstSuccess() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])

        ramp.recordLiveStarted(feedID: "one", sessionElapsed: 0.8, fastSessionThreshold: 3)
        let firstWave = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four", "five"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now
        )

        XCTAssertEqual(ramp.mode, .fast)
        XCTAssertEqual(ramp.maxPendingCount, 2)
        XCTAssertEqual(firstWave, ["one", "two", "three"])
        XCTAssertEqual(ramp.pendingIDs, ["two", "three"])

        ramp.recordLiveStarted(feedID: "two", sessionElapsed: 1.1, fastSessionThreshold: 3)
        ramp.recordLiveStarted(feedID: "three", sessionElapsed: 1.2, fastSessionThreshold: 3)
        let secondWave = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four", "five"],
            streamingIDs: ["one", "two", "three"],
            focusedID: nil,
            now: now
        )

        XCTAssertEqual(secondWave, ["one", "two", "three", "four", "five"])
        XCTAssertEqual(ramp.pendingIDs, ["four", "five"])
    }
    func testStartupLiveRampStaysOneWideAfterSlowFirstSuccess() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])

        ramp.recordLiveStarted(feedID: "one", sessionElapsed: 3, fastSessionThreshold: 3)
        let selection = ramp.reconcile(
            priorityIDs: ["one", "two", "three"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now
        )

        XCTAssertEqual(ramp.mode, .conservative)
        XCTAssertEqual(ramp.maxPendingCount, 1)
        XCTAssertEqual(selection, ["one", "two"])
        XCTAssertEqual(ramp.pendingIDs, ["two"])
    }
    func testStartupLiveRampSkipsFailedCameraUntilCooldownExpires() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])
        ramp.recordLiveStarted(feedID: "one", sessionElapsed: 0.5, fastSessionThreshold: 3)
        _ = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now
        )

        ramp.recordLiveStopped(
            feedID: "two",
            at: now,
            isCapacitySignal: false,
            retryDelay: 10
        )
        let duringCooldown = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(duringCooldown, ["one", "three", "four"])
        XCTAssertFalse(duringCooldown.contains("two"))
    }
    func testStartupLiveRampStopsAdmittingAfterCapacitySignal() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])
        ramp.recordLiveStarted(feedID: "one", sessionElapsed: 0.5, fastSessionThreshold: 3)
        _ = ramp.reconcile(
            priorityIDs: ["one", "two", "three"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now
        )

        ramp.recordLiveStopped(
            feedID: "two",
            at: now,
            isCapacitySignal: true,
            retryDelay: 10
        )
        let selection = ramp.reconcile(
            priorityIDs: ["one", "two", "three"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now.addingTimeInterval(20)
        )

        XCTAssertEqual(ramp.mode, .stopped)
        XCTAssertEqual(selection, ["one"])
        XCTAssertTrue(ramp.pendingIDs.isEmpty)
    }
    func testStartupLiveRampFocusedCameraPreemptsLowestPriorityPendingProbe() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])
        ramp.recordLiveStarted(feedID: "one", sessionElapsed: 0.5, fastSessionThreshold: 3)
        _ = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four"],
            streamingIDs: ["one"],
            focusedID: nil,
            now: now
        )

        let focusedSelection = ramp.reconcile(
            priorityIDs: ["one", "two", "three", "four"],
            streamingIDs: ["one"],
            focusedID: "four",
            now: now
        )

        XCTAssertEqual(focusedSelection, ["one", "two", "four"])
        XCTAssertEqual(ramp.pendingIDs, ["two", "four"])
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
    func testStartupCameraStateKeepsBatteryPendingUntilTrustedStill() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.liveStarted, isBatteryCamera: true)

        XCTAssertEqual(state.resolution, .pending)

        state.apply(.trustedImageObserved, isBatteryCamera: true)

        XCTAssertEqual(state.resolution, .trusted)
    }
    func testHomeNetworkPlainLiveResolvesBatteryStartupWithoutCapturedStill() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.plainLiveStarted, isBatteryCamera: true)

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
    func testPostCoverageRampPlannerUsesOnlyItsAdmittedLiveIDs() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0),
                makeFeed(id: "back", priorityIndex: 1),
                makeFeed(id: "garage", priorityIndex: 2, isStreaming: true)
            ],
            sessionMode: .optimistic,
            liveCapacity: 3,
            startupLivePolicy: .capacityRamp(
                liveIDs: ["front", "garage"],
                maxPendingStarts: 1
            ),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front", "garage"])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .snapshot)
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
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .homeNetwork(liveIDs: ["wired", "battery"]),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "wired"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }
    func testNormalCapacityRampStillCapturesDueBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 0,
                    lastSnapshotAge: 90,
                    isBatteryWakeCamera: true
                )
            ],
            sessionMode: .optimistic,
            liveCapacity: 1,
            startupLivePolicy: .capacityRamp(
                liveIDs: ["battery"],
                maxPendingStarts: 1
            ),
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryCapture)
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
    func testRestrictedStartupOverlayCountsEachCameraOnceWithRecoveryTakingPriority() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: true,
                    isRecovering: false
                ),
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: false,
                    isRecovering: false
                ),
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: true,
                    isRecovering: true
                )
            ]
        )

        XCTAssertEqual(
            presentation,
            RestrictedStartupOverlayPresentation(
                cameraCount: 3,
                checkingCount: 1,
                waitingCount: 1,
                retryingCount: 1
            )
        )
    }
    func testRestrictedStartupOverlayHidesAsSoonAsAnyCameraHasCurrentPicture() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: true,
                    isRecovering: false
                ),
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: true,
                    hasActiveWork: false,
                    isRecovering: false
                )
            ]
        )

        XCTAssertNil(presentation)
    }
    func testRestrictedStartupOverlayRequiresRestrictedStartupHomeAndCameras() {
        let waitingCamera = RestrictedStartupCameraActivity(
            hasCurrentPicture: false,
            hasActiveWork: false,
            isRecovering: false
        )

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
    func testRestrictedStartupOverlayRemainsVisibleWhenEveryCameraIsRetrying() {
        let presentation = RestrictedStartupOverlayPolicy.presentation(
            isRestrictedStartup: true,
            hasHome: true,
            cameras: [
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: false,
                    isRecovering: true
                ),
                RestrictedStartupCameraActivity(
                    hasCurrentPicture: false,
                    hasActiveWork: true,
                    isRecovering: true
                )
            ]
        )

        XCTAssertEqual(presentation?.cameraCount, 2)
        XCTAssertEqual(presentation?.retryingCount, 2)
        XCTAssertEqual(presentation?.checkingCount, 0)
        XCTAssertEqual(presentation?.waitingCount, 0)
    }
    func testRestrictedStartupOverlayCopyOmitsEmptyActivityGroups() {
        let presentation = RestrictedStartupOverlayPresentation(
            cameraCount: 1,
            checkingCount: 0,
            waitingCount: 0,
            retryingCount: 1
        )

        XCTAssertEqual(presentation.cameraCountText, "1 Camera Found")
        XCTAssertEqual(presentation.activityText, "Retrying 1")
    }
}

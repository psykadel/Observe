import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraLiveAdmissionTests: ObserveTestCase {
    func testBatteryInRetryBackoffDoesNotConsumeNormalLiveFillSlot() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired-live", priorityIndex: 0, isStreaming: true),
                makeFeed(
                    id: "backing-off-battery",
                    priorityIndex: 1,
                    isBatteryWakeCamera: true,
                    batteryWakeRetryAfter: now.addingTimeInterval(5)
                ),
                makeFeed(id: "wired-recent", priorityIndex: 2, lastSnapshotAge: 4)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["wired-live", "wired-recent"])
        XCTAssertEqual(plan.decisionsByID["backing-off-battery"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["backing-off-battery"]?.recoveryPhase, .batteryWaiting)
    }
    func testSnapshotAdmissionCapsActiveAndOutstandingStartupWorkSeparately() {
        let states: [SnapshotWorkState] = [
            .pending(
                SnapshotPendingRequest(
                    id: 1,
                    priority: .urgent,
                    issuedAt: now.addingTimeInterval(-5),
                    timeoutReportedAt: now.addingTimeInterval(-1)
                )
            ),
            .pending(
                SnapshotPendingRequest(
                    id: 2,
                    priority: .urgent,
                    issuedAt: now,
                    timeoutReportedAt: nil
                )
            )
        ]

        let capacity = SnapshotAdmissionPolicy.capacity(
            states: states,
            activeLimit: 2,
            outstandingLimit: 4
        )

        XCTAssertEqual(capacity.activeCount, 1)
        XCTAssertEqual(capacity.outstandingCount, 2)
        XCTAssertEqual(capacity.availableActiveSlots, 1)
        XCTAssertEqual(capacity.availableOutstandingSlots, 2)
    }
    func testSnapshotQueueAdmissionRejectsBatteryAndNonePriorityWork() {
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: true, priority: .urgent))
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .none))
        XCTAssertTrue(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .refresh))
    }
    func testLivePlanTransitionDrainsOutgoingTransportBeforeStartingReplacements() {
        let transition = LivePlanTransitionPolicy.makeTransition(
            activeTransportIDs: ["garage"],
            desiredLiveIDs: ["front", "back"]
        )

        XCTAssertEqual(transition.stopIDs, ["garage"])
        XCTAssertTrue(transition.startIDs.isEmpty)
        XCTAssertEqual(transition.deferredStartIDs, ["front", "back"])

        let afterStop = LivePlanTransitionPolicy.makeTransition(
            activeTransportIDs: [],
            desiredLiveIDs: ["front", "back"]
        )

        XCTAssertTrue(afterStop.stopIDs.isEmpty)
        XCTAssertEqual(afterStop.startIDs, ["front", "back"])
        XCTAssertTrue(afterStop.deferredStartIDs.isEmpty)
    }
    func testLiveTransportStateOwnsCapacityIndependentlyFromDisplayState() {
        var transport = CameraLiveTransportState.idle
        let display = FeedDisplayState.starting

        XCTAssertEqual(display, .starting)
        XCTAssertEqual(transport.phase, .idle)
        XCTAssertFalse(transport.phase.reservesCapacity)

        XCTAssertTrue(transport.requestStart(at: now))
        XCTAssertEqual(transport.phase, .starting)
        XCTAssertEqual(transport.startRequestedAt, now)
        XCTAssertTrue(transport.phase.reservesCapacity)

        XCTAssertTrue(
            transport.requestStop(
                at: now.addingTimeInterval(8),
                reason: .startupTimeout
            )
        )
        XCTAssertEqual(transport.phase, .stopping)
        XCTAssertEqual(transport.stopReason, .startupTimeout)
        XCTAssertFalse(
            transport.requestStop(
                at: now.addingTimeInterval(9),
                reason: .startupTimeout
            )
        )

        XCTAssertEqual(transport.confirmStopped(), .startupTimeout)
        XCTAssertEqual(transport, .idle)
    }
    func testLateStartWhileStoppingDoesNotRestoreStreamingOwnership() {
        var transport = CameraLiveTransportState.starting(requestedAt: now)
        _ = transport.requestStop(
            at: now.addingTimeInterval(8),
            reason: .startupTimeout
        )

        XCTAssertFalse(transport.confirmStarted(at: now.addingTimeInterval(8.1)))
        XCTAssertEqual(transport.phase, .stopping)
    }
    func testLiveTransportDoesNotConfirmStartedWithoutVideoSource() {
        var transport = CameraLiveTransportState.starting(requestedAt: now)

        XCTAssertFalse(
            transport.confirmStarted(
                at: now.addingTimeInterval(1),
                hasVideoSource: false
            )
        )
        XCTAssertEqual(transport.phase, .starting)

        XCTAssertTrue(
            transport.confirmStarted(
                at: now.addingTimeInterval(2),
                hasVideoSource: true
            )
        )
        XCTAssertEqual(transport.phase, .streaming)
    }
    func testLivePresentationRequiresStreamingTransportAndVideoSource() {
        XCTAssertFalse(
            CameraLivePresentationPolicy.isLive(
                transportPhase: .starting,
                hasVideoSource: true
            )
        )
        XCTAssertFalse(
            CameraLivePresentationPolicy.isLive(
                transportPhase: .streaming,
                hasVideoSource: false
            )
        )
        XCTAssertTrue(
            CameraLivePresentationPolicy.isLive(
                transportPhase: .streaming,
                hasVideoSource: true
            )
        )
    }
    func testSnapshotPresentationDoesNotReplaceActiveLiveVideo() {
        XCTAssertFalse(
            CameraLivePresentationPolicy.shouldPresentSnapshot(
                transportPhase: .streaming,
                hasVideoSource: true
            )
        )
        XCTAssertFalse(
            CameraLivePresentationPolicy.shouldPresentSnapshot(
                transportPhase: .stopping,
                hasVideoSource: true
            )
        )
    }
    func testSnapshotPresentationReplacesReleasedVideoAfterStopCallback() {
        XCTAssertTrue(
            CameraLivePresentationPolicy.shouldPresentSnapshot(
                transportPhase: .idle,
                hasVideoSource: true
            )
        )
        XCTAssertTrue(
            CameraLivePresentationPolicy.shouldPresentSnapshot(
                transportPhase: .starting,
                hasVideoSource: false
            )
        )
    }
    func testLateStartAfterStopDoesNotReacquireTransportOwnership() {
        var transport = CameraLiveTransportState.starting(requestedAt: now)
        _ = transport.requestStop(
            at: now.addingTimeInterval(8),
            reason: .startupTimeout
        )
        _ = transport.confirmStopped()

        XCTAssertFalse(transport.confirmStarted(at: now.addingTimeInterval(8.2)))
        XCTAssertEqual(transport.phase, .idle)
    }
    func testExpectedOperationCancelledStreamStopIsNotReportedAsFailure() {
        XCTAssertFalse(
            CameraStreamStopErrorPolicy.shouldReport(
                domain: HMErrorDomain,
                code: HMError.Code.operationCancelled.rawValue,
                stopWasRequested: true
            )
        )
        XCTAssertTrue(
            CameraStreamStopErrorPolicy.shouldReport(
                domain: HMErrorDomain,
                code: HMError.Code.operationCancelled.rawValue,
                stopWasRequested: false
            )
        )
        XCTAssertTrue(
            CameraStreamStopErrorPolicy.shouldReport(
                domain: HMErrorDomain,
                code: HMError.Code.accessoryIsBusy.rawValue,
                stopWasRequested: true
            )
        )
    }
    func testLiveStopReasonClassifiesRequestedCapacityAndCameraFailures() throws {
        let cancelled = try XCTUnwrap(CameraTransportError(
            NSError(
                domain: HMErrorDomain,
                code: HMError.Code.operationCancelled.rawValue
            )
        ))
        let capacity = try XCTUnwrap(CameraTransportError(
            NSError(
                domain: HMErrorDomain,
                code: HMError.Code.maximumObjectLimitReached.rawValue
            )
        ))
        let cameraFailure = try XCTUnwrap(CameraTransportError(
            NSError(domain: "Camera", code: 7)
        ))

        let requested = CameraLiveFailureDispositionPolicy.classify(error: cancelled, stopReason: .planned)
        XCTAssertEqual(requested, .requestedStop)
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: nil, stopReason: .startupTimeout),
            .startupTimedOut
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: cancelled, stopReason: .startupTimeout),
            .startupTimedOut
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: capacity, stopReason: nil),
            .hardCapacity(capacity)
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: cameraFailure, stopReason: nil),
            .cameraFailure(cameraFailure)
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: nil, stopReason: nil),
            .ended
        )
    }
    func testLiveFailureDispositionUsesEvidenceInsteadOfTreatingEveryTransportErrorAsCapacity() throws {
        let busy = try XCTUnwrap(CameraTransportError(
            NSError(domain: HMErrorDomain, code: HMError.Code.accessoryIsBusy.rawValue)
        ))
        let hardLimit = try XCTUnwrap(CameraTransportError(
            NSError(domain: HMErrorDomain, code: HMError.Code.maximumObjectLimitReached.rawValue)
        ))
        let communication = try XCTUnwrap(CameraTransportError(
            NSError(domain: HMErrorDomain, code: HMError.Code.communicationFailure.rawValue)
        ))
        let network = try XCTUnwrap(CameraTransportError(
            NSError(domain: HMErrorDomain, code: HMError.Code.networkUnavailable.rawValue)
        ))
        let camera = try XCTUnwrap(CameraTransportError(
            NSError(domain: "Camera", code: 7)
        ))

        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: busy, stopReason: .startupTimeout), .softContention(busy))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: hardLimit, stopReason: .startupTimeout), .hardCapacity(hardLimit))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: communication, stopReason: .startupTimeout), .retryableTransport(communication))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: network, stopReason: .startupTimeout), .infrastructureUnavailable(network))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: camera, stopReason: .startupTimeout), .cameraFailure(camera))
    }
    func testConstrainedAdmissionSerializesColdStarts() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 2)
        let intents = [
            LiveIntent(id: "front", role: .steadyState, priorityIndex: 0),
            LiveIntent(id: "back", role: .steadyState, priorityIndex: 1)
        ]

        let first = controller.reconcile(
            intents: intents,
            transports: ["front": .idle, "back": .idle],
            preserveActiveDuringCoverage: false,
            now: now
        )
        XCTAssertEqual(first.startIDs, ["front"])
        XCTAssertEqual(first.queuedStartIDs, ["back"])

        let second = controller.reconcile(
            intents: intents,
            transports: ["front": .streaming, "back": .idle],
            preserveActiveDuringCoverage: false,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(second.startIDs, ["back"])
    }
    func testAdmissionPreservesWorkingStreamWhileRecoveryUsesFreeSlot() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 2)
        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "back", role: .firstImageRecovery, priorityIndex: 1),
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0),
                LiveIntent(id: "garage", role: .steadyState, priorityIndex: 2)
            ],
            transports: [
                "front": .idle,
                "back": .idle,
                "garage": .streaming
            ],
            preserveActiveDuringCoverage: true,
            now: now
        )

        XCTAssertEqual(decision.targetIDs, ["back", "garage"])
        XCTAssertTrue(decision.stopIDs.isEmpty)
        XCTAssertEqual(decision.startIDs, ["back"])
    }
    func testSoftContentionCreatesTemporaryCeilingFromSurvivingStreams() {
        var controller = LiveAdmissionController(mode: .adaptive(maxPendingStarts: 1), sustainableCapacity: 5)
        let result = controller.recordSoftContention(
            feedID: "back",
            survivingStreamCount: 2,
            at: now
        )

        XCTAssertEqual(controller.mode, .constrained)
        XCTAssertEqual(controller.sustainableCapacity, 5)
        XCTAssertEqual(result.sessionCeiling, 2)
        XCTAssertEqual(result.attempt, 1)
        XCTAssertFalse(result.shouldYieldCamera)

        let blocked = controller.reconcile(
            intents: [
                LiveIntent(id: "back", role: .firstImageRecovery, priorityIndex: 1),
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0, isDesired: false),
                LiveIntent(id: "battery", role: .steadyState, priorityIndex: 4, isDesired: false)
            ],
            transports: ["back": .idle, "front": .streaming, "battery": .streaming],
            preserveActiveDuringCoverage: true,
            now: now.addingTimeInterval(0.5)
        )
        XCTAssertTrue(blocked.startIDs.isEmpty)
        XCTAssertEqual(blocked.targetIDs, ["front", "battery"])
        XCTAssertTrue(blocked.stopIDs.isEmpty)

        let retry = controller.reconcile(
            intents: [
                LiveIntent(id: "back", role: .firstImageRecovery, priorityIndex: 1),
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0, isDesired: false),
                LiveIntent(id: "battery", role: .steadyState, priorityIndex: 4, isDesired: false)
            ],
            transports: ["back": .idle, "front": .streaming, "battery": .streaming],
            preserveActiveDuringCoverage: true,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(retry.targetIDs, ["back", "front"])
        XCTAssertEqual(retry.stopIDs, ["battery"])
        XCTAssertTrue(retry.startIDs.isEmpty)
    }
    func testRepeatedSoftContentionYieldsCameraWithoutShrinkingInitialCeiling() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 5)
        _ = controller.recordSoftContention(
            feedID: "back",
            survivingStreamCount: 2,
            at: now
        )
        let repeated = controller.recordSoftContention(
            feedID: "back",
            survivingStreamCount: 1,
            at: now.addingTimeInterval(2)
        )

        XCTAssertEqual(repeated.sessionCeiling, 2)
        XCTAssertEqual(repeated.attempt, 2)
        XCTAssertTrue(repeated.shouldYieldCamera)
    }
    func testSoftContentionCeilingAllowsOneExplicitCapacityProbeAfterPlannerCooldown() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 5)
        _ = controller.recordSoftContention(
            feedID: "initial-probe",
            survivingStreamCount: 2,
            at: now
        )

        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0),
                LiveIntent(id: "back", role: .steadyState, priorityIndex: 1),
                LiveIntent(id: "mailbox", role: .capacityProbe, priorityIndex: 2)
            ],
            transports: [
                "front": .streaming,
                "back": .streaming,
                "mailbox": .idle
            ],
            preserveActiveDuringCoverage: false,
            plannerCapacity: 3,
            now: now.addingTimeInterval(CameraSchedulingDefaults.liveCapacityExpansionRetryDelay)
        )

        XCTAssertEqual(decision.targetIDs, ["front", "back", "mailbox"])
        XCTAssertEqual(decision.startIDs, ["mailbox"])
        XCTAssertTrue(decision.stopIDs.isEmpty)
        XCTAssertEqual(controller.lastPlannerCapacity, 3)
        XCTAssertEqual(controller.lastEffectiveCapacity, 3)
        XCTAssertEqual(controller.lastCapacityLimitReason, "softContentionProbe")
        XCTAssertEqual(controller.activeCapacityProbeFeedID, "mailbox")

        controller.recordSuccess(feedID: "mailbox")
        let nextProbe = controller.reconcile(
            intents: [
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0),
                LiveIntent(id: "back", role: .steadyState, priorityIndex: 1),
                LiveIntent(id: "mailbox", role: .steadyState, priorityIndex: 2),
                LiveIntent(id: "garage", role: .capacityProbe, priorityIndex: 3)
            ],
            transports: [
                "front": .streaming,
                "back": .streaming,
                "mailbox": .streaming,
                "garage": .idle
            ],
            preserveActiveDuringCoverage: false,
            plannerCapacity: 4,
            now: now.addingTimeInterval(CameraSchedulingDefaults.liveCapacityExpansionRetryDelay + 1)
        )

        XCTAssertEqual(nextProbe.startIDs, ["garage"])
    }
    func testSoftContentionCeilingDoesNotAdmitOrdinaryWorkAboveCeiling() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 5)
        _ = controller.recordSoftContention(
            feedID: "initial-probe",
            survivingStreamCount: 2,
            at: now
        )

        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 0),
                LiveIntent(id: "back", role: .steadyState, priorityIndex: 1),
                LiveIntent(id: "mailbox", role: .steadyState, priorityIndex: 2)
            ],
            transports: [
                "front": .streaming,
                "back": .streaming,
                "mailbox": .idle
            ],
            preserveActiveDuringCoverage: false,
            plannerCapacity: 3,
            now: now.addingTimeInterval(CameraSchedulingDefaults.liveCapacityExpansionRetryDelay)
        )

        XCTAssertEqual(decision.targetIDs, ["front", "back"])
        XCTAssertTrue(decision.startIDs.isEmpty)
    }
    func testRetryBackoffDoesNotEvictWorkingCoverageStream() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 1)
        _ = controller.recordSoftContention(
            feedID: "back",
            survivingStreamCount: 1,
            at: now
        )

        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "back", role: .firstImageRecovery, priorityIndex: 0),
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 1, isDesired: false)
            ],
            transports: ["back": .idle, "front": .streaming],
            preserveActiveDuringCoverage: true,
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(decision.targetIDs, ["front"])
        XCTAssertTrue(decision.stopIDs.isEmpty)
        XCTAssertTrue(decision.startIDs.isEmpty)
    }
    func testRestrictedCapacityKeepsOneSlotWhenConstrainedBeforeStreamsReportLive() {
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(currentLiveCount: 0, visibleFeedCount: 4),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.afterConstrainedSignal(currentLiveCount: 0, visibleFeedCount: 4),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.afterConstrainedSignal(currentLiveCount: 2, visibleFeedCount: 6),
            2
        )
    }
    func testReducedRestrictedCapacitySelectsExactPriorityPrefix() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "first", priorityIndex: 0, lastSnapshotAge: 5),
                makeFeed(id: "second", priorityIndex: 1, lastSnapshotAge: 5),
                makeFeed(id: "third", priorityIndex: 2, lastSnapshotAge: 5),
                makeFeed(id: "battery-last", priorityIndex: 3, lastSnapshotAge: 5, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["first", "second"])
    }
    func testRestrictedCapacityStartsFromRememberedCapacityWhenEnteringConstrainedMode() {
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: 0,
                visibleFeedCount: 6,
                rememberedCapacity: 2
            ),
            2
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: 1,
                visibleFeedCount: 6,
                rememberedCapacity: 3
            ),
            3
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: 0,
                visibleFeedCount: 1,
                rememberedCapacity: 3
            ),
            1
        )
    }
    func testRestrictedCapacityRecordsSuccessfulLiveHighWaterMark() {
        XCTAssertEqual(
            RestrictedLiveCapacity.recordSuccessfulStreams(previousCapacity: 1, currentLiveCount: 2, visibleFeedCount: 4),
            2
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.recordSuccessfulStreams(previousCapacity: 2, currentLiveCount: 1, visibleFeedCount: 4),
            2
        )
    }
    func testRestrictedCapacityProbesOneExtraSlotAfterAllFeedsAreTrusted() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                allVisibleFeedsTrusted: true,
                canProbeCapacity: true
            ),
            2
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 2,
                visibleFeedCount: 4,
                allVisibleFeedsTrusted: true,
                canProbeCapacity: false
            ),
            2
        )
    }
    func testRestrictedCapacityDoesNotProbeExtraSlotBeforeAllFeedsAreTrusted() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: false
            ),
            1
        )
    }
    func testRestrictedCapacityStillAllowsExplicitZeroWhenNoFeedsAreVisible() {
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(currentLiveCount: 0, visibleFeedCount: 0),
            0
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.afterConstrainedSignal(currentLiveCount: 0, visibleFeedCount: 0),
            0
        )
    }

    @MainActor
    func testRememberedRestrictedCapacityUsesExactCameraTopology() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        XCTAssertNil(preferences.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["front", "back", "garage"]
        ))

        preferences.recordConfirmedRestrictedLiveCapacity(
            2,
            homeID: "home-a",
            visibleCameraIDs: ["front", "back", "garage"]
        )
        preferences.recordConfirmedRestrictedLiveCapacity(
            1,
            homeID: "home-a",
            visibleCameraIDs: ["garage", "front", "back"]
        )
        preferences.recordConfirmedRestrictedLiveCapacity(
            3,
            homeID: "home-a",
            visibleCameraIDs: ["front", "back", "side"]
        )

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["back", "garage", "front"]
        ), 2)
        XCTAssertEqual(reloaded.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["side", "front", "back"]
        ), 3)
        XCTAssertNil(reloaded.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["front", "back", "porch"]
        ))
        XCTAssertNil(reloaded.rememberedRestrictedLiveCapacity(
            homeID: "home-b",
            visibleCameraIDs: ["front", "back", "garage"]
        ))

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testCapacityRejectionLowersAndZeroClearsExactTopologyMemory() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        let preferences = ObservePreferences(userDefaults: defaults)
        let cameraIDs = ["front", "back", "garage"]

        preferences.recordConfirmedRestrictedLiveCapacity(
            3,
            homeID: "home-a",
            visibleCameraIDs: cameraIDs
        )
        preferences.recordRestrictedLiveCapacityAfterRejection(
            1,
            homeID: "home-a",
            visibleCameraIDs: cameraIDs
        )
        XCTAssertEqual(preferences.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: cameraIDs
        ), 1)

        preferences.recordRestrictedLiveCapacityAfterRejection(
            0,
            homeID: "home-a",
            visibleCameraIDs: cameraIDs
        )
        XCTAssertNil(preferences.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: cameraIDs
        ))

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testRestrictedCapacityV3IgnoresLegacyEvidence() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            ["v2#6:home-a#4:back|5:front": 2],
            forKey: "observe.restrictedLiveCapacities"
        )

        let preferences = ObservePreferences(userDefaults: defaults)
        XCTAssertNil(preferences.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["front", "back"]
        ))

        preferences.recordConfirmedRestrictedLiveCapacity(
            2,
            homeID: "home-a",
            visibleCameraIDs: ["front", "back"]
        )
        XCTAssertEqual(preferences.rememberedRestrictedLiveCapacity(
            homeID: "home-a",
            visibleCameraIDs: ["back", "front"]
        ), 2)

        defaults.removePersistentDomain(forName: suiteName)
    }
}

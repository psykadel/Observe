import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraLiveAdmissionTests: ObserveTestCase {
    func testPermanentBatteryLiveSlotIgnoresCaptureRetryDelay() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired-live", priorityIndex: 0, isStreaming: true),
                makeFeed(
                    id: "retry-waiting-battery",
                    priorityIndex: 1,
                    isBatteryWakeCamera: true,
                    batteryWakeRetryAfter: now.addingTimeInterval(5)
                ),
                makeFeed(id: "wired-recent", priorityIndex: 2, lastSnapshotAge: 4)
            ],
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["retry-waiting-battery", "wired-live"])
        XCTAssertEqual(plan.decisionsByID["retry-waiting-battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["retry-waiting-battery"]?.recoveryPhase, .idle)
    }
    func testSnapshotQueueAdmissionRejectsBatteryAndNonePriorityWork() {
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: true, priority: .urgent))
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .none))
        XCTAssertTrue(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .refresh))
    }
    func testEligibleBackgroundAndFocusedLiveStartsAreAdmittedTogether() {
        var controller = LiveAdmissionController(mode: .adaptive(maxPendingStarts: 2), sustainableCapacity: 2)

        let decision = controller.reconcile(
            intents: [
                LiveIntent(
                    id: "background",
                    role: .steadyState,
                    priorityIndex: 0
                ),
                LiveIntent(
                    id: "focused",
                    role: .focused,
                    priorityIndex: 1
                )
            ],
            transports: [:],
            now: now
        )

        XCTAssertEqual(decision.startIDs, ["focused", "background"])
    }

    func testUnknownRestrictedCapacityExpandsOneSlotPerLiveSuccess() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 0,
                currentLiveCount: 0,
                visibleFeedCount: 5,
                isDiscovering: true
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                currentLiveCount: 1,
                visibleFeedCount: 5,
                isDiscovering: true
            ),
            2
        )
    }
    func testRepeatedLiveFailuresRetryAfterOneSecond() {
        let liveBudget = RestrictedLiveCapacity.planningBudget(
            knownCapacity: 2,
            currentLiveCount: 2,
            visibleFeedCount: 4,
            isDiscovering: true
        )
        var controller = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 2
        )
        controller.recordRetryableFailure(feedID: "third", at: now)
        controller.recordRetryableFailure(feedID: "third", at: now)
        controller.recordRetryableFailure(feedID: "third", at: now)
        let intents = [
            LiveIntent(id: "first", role: .steadyState, priorityIndex: 0),
            LiveIntent(id: "second", role: .steadyState, priorityIndex: 1),
            LiveIntent(id: "third", role: .steadyState, priorityIndex: 2)
        ]
        let transports: [String: LiveTransportPhase] = [
            "first": .streaming,
            "second": .streaming,
            "third": .idle
        ]

        let beforeRetry = controller.reconcile(
            intents: intents,
            transports: transports,
            plannerCapacity: liveBudget,
            now: now.addingTimeInterval(0.5)
        )
        let afterOneSecond = controller.reconcile(
            intents: intents,
            transports: transports,
            plannerCapacity: liveBudget,
            now: now.addingTimeInterval(1)
        )

        XCTAssertTrue(beforeRetry.startIDs.isEmpty)
        XCTAssertEqual(afterOneSecond.startIDs, ["third"])
    }
    func testRepeatedInfrastructureFailuresRetryAfterOneSecond() {
        var controller = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: 1),
            sustainableCapacity: 1
        )
        controller.recordInfrastructureUnavailable(at: now)
        controller.recordInfrastructureUnavailable(at: now)
        controller.recordInfrastructureUnavailable(at: now)
        let intents = [LiveIntent(id: "front", role: .steadyState, priorityIndex: 0)]
        let transports = ["front": LiveTransportPhase.idle]

        let beforeRetry = controller.reconcile(
            intents: intents,
            transports: transports,
            now: now.addingTimeInterval(0.5)
        )
        let afterOneSecond = controller.reconcile(
            intents: intents,
            transports: transports,
            now: now.addingTimeInterval(1)
        )

        XCTAssertTrue(beforeRetry.startIDs.isEmpty)
        XCTAssertEqual(afterOneSecond.startIDs, ["front"])
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
                at: now.addingTimeInterval(8)
            )
        )
        XCTAssertEqual(transport.phase, .stopping)
        XCTAssertFalse(
            transport.requestStop(
                at: now.addingTimeInterval(9)
            )
        )

        XCTAssertTrue(transport.confirmStopped())
        XCTAssertEqual(transport, .idle)
    }
    func testLateStartWhileStoppingDoesNotRestoreStreamingOwnership() {
        var transport = CameraLiveTransportState.starting(requestedAt: now)
        _ = transport.requestStop(at: now.addingTimeInterval(8))

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
        _ = transport.requestStop(at: now.addingTimeInterval(8))
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
    func testLiveFailureDispositionClassifiesRequestedCapacityAndCameraFailures() throws {
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

        let requested = CameraLiveFailureDispositionPolicy.classify(error: cancelled, stopWasRequested: true)
        XCTAssertEqual(requested, .requestedStop)
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: capacity, stopWasRequested: false),
            .hardCapacity(capacity)
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: cameraFailure, stopWasRequested: false),
            .cameraFailure(cameraFailure)
        )
        XCTAssertEqual(
            CameraLiveFailureDispositionPolicy.classify(error: nil, stopWasRequested: false),
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

        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: busy, stopWasRequested: true), .softContention(busy))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: hardLimit, stopWasRequested: true), .hardCapacity(hardLimit))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: communication, stopWasRequested: true), .retryableTransport(communication))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: network, stopWasRequested: true), .infrastructureUnavailable(network))
        XCTAssertEqual(CameraLiveFailureDispositionPolicy.classify(error: camera, stopWasRequested: true), .cameraFailure(camera))
    }
    func testConstrainedAdmissionSerializesColdStartsInLiveOrder() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 2)
        let intents = [
            LiveIntent(id: "back", role: .steadyState, priorityIndex: 1),
            LiveIntent(id: "front", role: .steadyState, priorityIndex: 0)
        ]

        let first = controller.reconcile(
            intents: intents,
            transports: ["front": .idle, "back": .idle],
            now: now
        )
        XCTAssertEqual(first.startIDs, ["front"])
        XCTAssertEqual(first.queuedStartIDs, ["back"])

        let second = controller.reconcile(
            intents: intents,
            transports: ["front": .streaming, "back": .idle],
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(second.startIDs, ["back"])
    }
    func testRetryDelayDoesNotEvictWorkingCoverageStream() {
        var controller = LiveAdmissionController(mode: .constrained, sustainableCapacity: 1)
        controller.recordRetryableFailure(feedID: "back", at: now)

        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "back", role: .steadyState, priorityIndex: 0),
                LiveIntent(id: "front", role: .steadyState, priorityIndex: 1, isDesired: false)
            ],
            transports: ["back": .idle, "front": .streaming],
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
    func testKnownRestrictedCapacityNeverExpandsSpeculatively() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 2,
                visibleFeedCount: 4
            ),
            2
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

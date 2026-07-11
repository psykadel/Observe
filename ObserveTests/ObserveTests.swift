import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class ObserveTests: XCTestCase {
    private let planner = CameraRecoveryPlanner()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testOptimisticModeRequestsLiveForEveryVisibleFeedIncludingTrustedBattery() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "back", priorityIndex: 1, lastSnapshotAge: 5, isBatteryWakeCamera: true),
                makeFeed(id: "side", priorityIndex: 2),
                makeFeed(id: "driveway", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            sessionMode: .optimistic,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["back", "driveway", "front", "side"])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["back"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["side"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.decisionsByID["driveway"]?.snapshotPriority, .refresh)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["side", "driveway"])
    }

    func testOptimisticModeMarksDueBatteryForCaptureWithoutRemovingLive() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery", priorityIndex: 1, lastSnapshotAge: 90, isBatteryWakeCamera: true)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "wired"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryCapture)
    }

    func testConstrainedCapacityZeroQueuesBatteryAndContinuouslyRefreshesNonBatterySnapshots() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "empty", priorityIndex: 0),
                makeFeed(id: "battery", priorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "stale", priorityIndex: 2, lastSnapshotAge: 90),
                makeFeed(id: "recent", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            sessionMode: .constrained,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["empty", "stale", "recent"])
    }

    func testActiveBatteryCaptureLeaseIsPreservedBeforeFocusAndPriority() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "highest-priority", priorityIndex: 0, lastSnapshotAge: 5),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(id: "new-battery", priorityIndex: 2, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["active-battery"])
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["highest-priority"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryWaiting)
    }

    func testActiveBatteryCaptureLeaseIsPreservedDuringPostLiveWarmup() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "new-battery", priorityIndex: 0, isBatteryWakeCamera: true),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    isStreaming: true,
                    liveStartedAt: now.addingTimeInterval(-2),
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-10)
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["active-battery"])
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryWaiting)
    }

    func testActiveBatteryCaptureLeaseIsPreservedWhileWaitingForLiveConnection() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "new-battery", priorityIndex: 0, isBatteryWakeCamera: true),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-10)
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["active-battery"])
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryWaiting)
    }

    func testBatteryCaptureLeaseTimesOutWhenLiveConnectionNeverStarts() {
        let planner = CameraRecoveryPlanner(batteryWakeLiveStartTimeout: 30)
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "new-battery", priorityIndex: 0, isBatteryWakeCamera: true),
                makeFeed(
                    id: "stuck-battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-31)
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["new-battery"])
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["stuck-battery"]?.recoveryPhase, .batteryWaiting)
    }

    func testTrustedBatteryStillEndsActiveCaptureLeaseEvenWhenStillPredatesLease() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "next-battery", priorityIndex: 0, isBatteryWakeCamera: true),
                makeFeed(
                    id: "trusted-battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 5,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["next-battery"])
        XCTAssertEqual(plan.decisionsByID["next-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["trusted-battery"]?.recoveryPhase, .idle)
    }

    func testFocusedFeedMayExplicitlyCancelActiveBatteryCaptureWhenCapacityIsFull() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "focused", priorityIndex: 0, isFocused: true, lastSnapshotAge: 5),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(id: "new-battery", priorityIndex: 2, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused"])
        XCTAssertEqual(plan.decisionsByID["focused"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryWaiting)
    }

    func testFocusedBatteryUsesFocusSlotForTrustedStillCapture() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "focused-battery", priorityIndex: 1, isFocused: true, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused-battery"])
        XCTAssertEqual(plan.decisionsByID["focused-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .snapshot)
    }

    func testBatteryCaptureCandidatesUseRemainingSlotsInUISortOrder() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery-first", priorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "battery-second", priorityIndex: 2, lastSnapshotAge: 90, isBatteryWakeCamera: true),
                makeFeed(id: "battery-third", priorityIndex: 3, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery-first", "battery-second"])
        XCTAssertEqual(plan.decisionsByID["battery-first"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["battery-second"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["battery-third"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .snapshot)
    }

    func testUnusedBatteryCaptureCapacityFallsBackToNormalLivePriority() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "top-live", priorityIndex: 0, lastSnapshotAge: 5),
                makeFeed(id: "second-live", priorityIndex: 1, lastSnapshotAge: 5),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 2,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(id: "trusted-battery", priorityIndex: 3, lastSnapshotAge: 5, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["active-battery", "top-live"])
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["top-live"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["second-live"]?.presentationMode, .snapshot)
    }

    func testNormalLiveAssignmentAfterEveryVisibleCameraIsTrusted() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "battery", priorityIndex: 0, lastSnapshotAge: 5, isBatteryWakeCamera: true),
                makeFeed(id: "focused", priorityIndex: 1, isFocused: true, lastSnapshotAge: 5),
                makeFeed(id: "second", priorityIndex: 2, lastSnapshotAge: 5),
                makeFeed(id: "third", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "focused"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["second"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["focused", "second", "third"])
    }

    func testCapturedBatteryStillReleasesSlotAndRotatesToNextWaitingBattery() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "captured-battery",
                    priorityIndex: 0,
                    lastSnapshotAge: 1,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-2)
                ),
                makeFeed(id: "next-battery", priorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "healthy-live", priorityIndex: 2, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["next-battery"])
        XCTAssertEqual(plan.decisionsByID["captured-battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["next-battery"]?.recoveryPhase, .batteryCapture)
    }

    func testBatteryWakeBackoffRotatesLiveSlotToNextEligibleBattery() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "backing-off-battery",
                    priorityIndex: 0,
                    isBatteryWakeCamera: true,
                    batteryWakeRetryAfter: now.addingTimeInterval(5)
                ),
                makeFeed(id: "next-battery", priorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "trusted-battery", priorityIndex: 2, lastSnapshotAge: 5, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["next-battery"])
        XCTAssertEqual(plan.decisionsByID["backing-off-battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["next-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["trusted-battery"]?.recoveryPhase, .idle)
    }

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

    func testNonBatterySnapshotRefreshesPrioritizeEmptyAndStaleBeforeRecent() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "recent-high-priority", priorityIndex: 0, lastSnapshotAge: 5),
                makeFeed(id: "stale-first", priorityIndex: 1, lastSnapshotAge: 80),
                makeFeed(id: "empty-second", priorityIndex: 2),
                makeFeed(id: "stale-third", priorityIndex: 3, lastSnapshotAge: 90),
                makeFeed(id: "battery", priorityIndex: 4, isBatteryWakeCamera: true),
                makeFeed(id: "recent-low-priority", priorityIndex: 5, lastSnapshotAge: 5),
                makeFeed(id: "live", priorityIndex: 6, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(
            plan.orderedSnapshotIDs,
            ["stale-first", "empty-second", "stale-third", "recent-high-priority", "recent-low-priority"]
        )
        XCTAssertEqual(plan.decisionsByID["empty-second"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.decisionsByID["recent-high-priority"]?.snapshotPriority, .refresh)
    }

    func testSnapshotQueueUsesAggressiveMinimumForUntrustedSnapshots() {
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(
                current: .distantFuture,
                requestedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-1),
                minimumInterval: SnapshotQueuePolicy.minimumRefreshInterval(for: .urgent)
            ),
            now.addingTimeInterval(1)
        )
        XCTAssertEqual(SnapshotQueuePolicy.minimumRefreshInterval(for: .urgent), 2)
    }

    func testSnapshotQueueKeepsSteadyStateMinimumForRecentSnapshots() {
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(
                current: .distantFuture,
                requestedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-1),
                minimumInterval: SnapshotQueuePolicy.minimumRefreshInterval(for: .refresh)
            ),
            now.addingTimeInterval(4)
        )
        XCTAssertEqual(SnapshotQueuePolicy.minimumRefreshInterval(for: .refresh), 5)
    }

    func testSnapshotQueueRetriesFailuresFromCompletionTime() {
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDateAfterFailure(
                failedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-1),
                priority: .urgent
            ),
            now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDateAfterFailure(
                failedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-8),
                priority: .refresh
            ),
            now.addingTimeInterval(5)
        )
    }

    func testOverdueSnapshotKeepsRequestOwnershipWhileOpeningAnActiveSlot() {
        let request = SnapshotPendingRequest(
            id: 41,
            priority: .urgent,
            issuedAt: now.addingTimeInterval(-5),
            timeoutReportedAt: nil
        )
        var state = SnapshotWorkState.pending(request)

        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.isOutstanding)

        XCTAssertTrue(state.markOverdue(at: now))

        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.isOutstanding)
        XCTAssertEqual(state.pendingRequest?.id, 41)
        XCTAssertEqual(state.pendingRequest?.timeoutReportedAt, now)
        XCTAssertFalse(state.markOverdue(at: now.addingTimeInterval(1)))
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

    func testIdleHomeHubHarnessAttemptsFourWiredPathsBeforeFallbackWithoutDuplicates() {
        let feedIDs = ["front", "garage", "deck", "side"]
        var nextRequestID: SnapshotRequestID = 1
        var states = Dictionary(
            uniqueKeysWithValues: feedIDs.map {
                ($0, SnapshotWorkState.queued(priority: .urgent, eligibleAt: now))
            }
        )
        var attemptedIDs: [String] = []

        func issueAvailable(at date: Date) {
            var capacity = SnapshotAdmissionPolicy.capacity(
                states: Array(states.values),
                activeLimit: 2,
                outstandingLimit: 4
            )
            for feedID in feedIDs where capacity.availableActiveSlots > 0
                && capacity.availableOutstandingSlots > 0 {
                guard states[feedID]?.queuedEligibleAt != nil else { continue }
                states[feedID] = .pending(
                    SnapshotPendingRequest(
                        id: nextRequestID,
                        priority: .urgent,
                        issuedAt: date,
                        timeoutReportedAt: nil
                    )
                )
                nextRequestID += 1
                attemptedIDs.append(feedID)
                capacity = SnapshotAdmissionPolicy.capacity(
                    states: Array(states.values),
                    activeLimit: 2,
                    outstandingLimit: 4
                )
            }
        }

        issueAvailable(at: now)
        XCTAssertEqual(attemptedIDs, ["front", "garage"])

        let firstTimeoutBoundary = now.addingTimeInterval(4.01)
        for feedID in feedIDs {
            _ = states[feedID]?.markOverdue(at: firstTimeoutBoundary)
        }
        issueAvailable(at: firstTimeoutBoundary)
        XCTAssertEqual(attemptedIDs, ["front", "garage", "deck", "side"])

        let secondTimeoutBoundary = now.addingTimeInterval(8.02)
        for feedID in feedIDs {
            _ = states[feedID]?.markOverdue(at: secondTimeoutBoundary)
        }
        let finalCapacity = SnapshotAdmissionPolicy.capacity(
            states: Array(states.values),
            activeLimit: 2,
            outstandingLimit: 4
        )

        XCTAssertEqual(finalCapacity.activeCount, 0)
        XCTAssertEqual(finalCapacity.outstandingCount, 4)
        XCTAssertEqual(Set(attemptedIDs), Set(feedIDs))
        XCTAssertEqual(attemptedIDs.count, feedIDs.count)
    }

    func testSnapshotQueueingIsIdempotentUntilPriorityIncreases() {
        let initialDate = now.addingTimeInterval(3)
        var state = SnapshotWorkState.queued(priority: .refresh, eligibleAt: initialDate)

        XCTAssertFalse(state.enqueue(priority: .refresh, eligibleAt: now))
        XCTAssertEqual(state, .queued(priority: .refresh, eligibleAt: initialDate))

        XCTAssertTrue(state.enqueue(priority: .urgent, eligibleAt: now))
        XCTAssertEqual(state, .queued(priority: .urgent, eligibleAt: now))
    }

    func testSnapshotQueueAdmissionRejectsBatteryAndNonePriorityWork() {
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: true, priority: .urgent))
        XCTAssertFalse(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .none))
        XCTAssertTrue(SnapshotQueueAdmissionPolicy.shouldQueue(isBatteryCamera: false, priority: .refresh))
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

        let requested = CameraLiveStopReasonPolicy.classify(error: cancelled, stopWasRequested: true)
        XCTAssertEqual(requested, .requested)
        XCTAssertFalse(requested.shouldFailStartupPath)
        XCTAssertEqual(
            CameraLiveStopReasonPolicy.classify(error: capacity, stopWasRequested: false),
            .capacityConstrained(capacity)
        )
        XCTAssertEqual(
            CameraLiveStopReasonPolicy.classify(error: cameraFailure, stopWasRequested: false),
            .failure(cameraFailure)
        )
        XCTAssertEqual(
            CameraLiveStopReasonPolicy.classify(error: nil, stopWasRequested: false),
            .ended
        )
    }

    func testSnapshotFirstStartupRunsOneBatteryCaptureBeforeWiredLiveFallback() {
        let feeds = [
            makeFeed(id: "front", priorityIndex: 0),
            makeFeed(id: "garage", priorityIndex: 1),
            makeFeed(id: "battery", priorityIndex: 2, isBatteryWakeCamera: true)
        ]

        let snapshotFirstPlan = planner.makePlan(
            feeds: feeds,
            sessionMode: .optimistic,
            liveCapacity: 3,
            startupLivePolicy: .firstImage(allowWiredFallback: false),
            now: now
        )
        let fallbackPlan = planner.makePlan(
            feeds: feeds,
            sessionMode: .optimistic,
            liveCapacity: 3,
            startupLivePolicy: .firstImage(allowWiredFallback: true),
            now: now
        )

        XCTAssertEqual(liveIDs(in: snapshotFirstPlan), ["battery"])
        XCTAssertEqual(snapshotFirstPlan.decisionsByID["battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(snapshotFirstPlan.orderedSnapshotIDs, ["front", "garage"])
        XCTAssertEqual(liveIDs(in: fallbackPlan), ["battery"])
    }

    func testSnapshotFirstStartupAlwaysStartsOneWiredLiveProbeWithoutBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "first", priorityIndex: 0),
                makeFeed(id: "second", priorityIndex: 1)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .firstImage(allowWiredFallback: false),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["first"])
        XCTAssertEqual(plan.decisionsByID["second"]?.presentationMode, .snapshot)
    }

    func testStartupLiveRampUsesTwoPendingSlotsAfterFastFirstSuccess() {
        var ramp = StartupLiveRampState(initialSelectedIDs: ["one"])

        ramp.recordLiveStarted(feedID: "one", elapsed: 0.8, fastThreshold: 3)
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

        ramp.recordLiveStarted(feedID: "two", elapsed: 1.1, fastThreshold: 3)
        ramp.recordLiveStarted(feedID: "three", elapsed: 1.2, fastThreshold: 3)
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

        ramp.recordLiveStarted(feedID: "one", elapsed: 3, fastThreshold: 3)
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
        ramp.recordLiveStarted(feedID: "one", elapsed: 0.5, fastThreshold: 3)
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
        ramp.recordLiveStarted(feedID: "one", elapsed: 0.5, fastThreshold: 3)
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
        ramp.recordLiveStarted(feedID: "one", elapsed: 0.5, fastThreshold: 3)
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

    func testStartupCameraStateRequiresBothWiredPathsToFail() {
        var state = StartupCameraState()

        state.apply(.snapshotRequested(at: now), isBatteryCamera: false)
        state.apply(.snapshotFailed, isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .pending)
        XCTAssertTrue(state.snapshotAttempted)
        XCTAssertTrue(state.snapshotFailed)

        state.apply(.liveRequested(at: now), isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .unresolved)
        XCTAssertTrue(state.liveAttempted)
        XCTAssertNil(state.liveFallbackStartedAt)
    }

    func testStartupCameraStateKeepsBatteryPendingUntilTrustedStill() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.liveStarted, isBatteryCamera: true)

        XCTAssertEqual(state.resolution, .pending)

        state.apply(.trustedImageObserved, isBatteryCamera: true)

        XCTAssertEqual(state.resolution, .trusted)
    }

    func testStartupCameraStateAcceptsLateSnapshotSuccessAfterFailure() {
        var state = StartupCameraState()

        state.apply(.snapshotFailed, isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .unresolved)

        state.apply(.snapshotSucceeded, isBatteryCamera: false)

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
        state.apply(.snapshotFailed, isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .unresolved)

        state.apply(.reset, isBatteryCamera: false)

        XCTAssertEqual(state, StartupCameraState())
    }

    func testCameraSessionGenerationAcceptsOnlyActiveSession() {
        XCTAssertTrue(
            CameraSessionGeneration.accepts(callbackGeneration: 4, activeGeneration: 4)
        )
        XCTAssertFalse(
            CameraSessionGeneration.accepts(callbackGeneration: 3, activeGeneration: 4)
        )
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
            startupLivePolicy: .capacityRamp(liveIDs: ["front", "garage"]),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front", "garage"])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .snapshot)
    }

    func testSnapshotFirstStartupUsesOnlyOneWiredFallbackWithoutBatteryDemand() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, startupSnapshotAttempted: true),
                makeFeed(id: "garage", priorityIndex: 1, startupSnapshotAttempted: true)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .firstImage(allowWiredFallback: true),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front"])
        XCTAssertEqual(plan.decisionsByID["garage"]?.presentationMode, .snapshot)
    }

    func testSnapshotFirstStartupPreservesAnActiveWiredFallback() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "front",
                    priorityIndex: 0,
                    startupSnapshotAttempted: true,
                    startupLiveFallbackStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(id: "garage", priorityIndex: 1, startupSnapshotAttempted: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: .firstImage(allowWiredFallback: false),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front"])
    }

    func testSnapshotFirstStartupSkipsExplicitlyUnresolvedFeeds() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "failed-wired",
                    priorityIndex: 0,
                    startupSnapshotAttempted: true,
                    startupCoverageResolution: .unresolved
                ),
                makeFeed(
                    id: "failed-battery",
                    priorityIndex: 1,
                    isBatteryWakeCamera: true,
                    startupCoverageResolution: .unresolved
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: .firstImage(allowWiredFallback: true),
            now: now
        )

        XCTAssertTrue(liveIDs(in: plan).isEmpty)
    }

    func testStartupSnapshotConcurrencyPolicyCapsFirstFrameRequests() {
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                nonBatteryTrustedCount: 0,
                nonBatteryCount: 5
            ),
            2
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                nonBatteryTrustedCount: 1,
                nonBatteryCount: 5
            ),
            3
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                nonBatteryTrustedCount: 5,
                nonBatteryCount: 5
            ),
            3
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: false,
                nonBatteryTrustedCount: 0,
                nonBatteryCount: 5
            ),
            3
        )
    }

    func testSnapshotRequestTimeoutDefaultsToFourSeconds() {
        XCTAssertEqual(CameraSchedulingDefaults.snapshotRequestTimeout, 4)
    }

    func testSnapshotRequestMatchPolicyIgnoresStaleResults() {
        XCTAssertTrue(
            SnapshotRequestMatchPolicy.isCurrent(
                currentRequestID: 2,
                resultRequestID: 2,
                isInFlight: true
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.isCurrent(
                currentRequestID: 2,
                resultRequestID: 1,
                isInFlight: true
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.isCurrent(
                currentRequestID: 2,
                resultRequestID: nil,
                isInFlight: true
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.isCurrent(
                currentRequestID: 2,
                resultRequestID: 2,
                isInFlight: false
            )
        )
    }

    func testSnapshotRequestMatchPolicyAcceptsLateFirstSuccessWithinStaleThreshold() {
        XCTAssertTrue(
            SnapshotRequestMatchPolicy.acceptsLateFirstSuccess(
                result: .success(now.addingTimeInterval(-30)),
                hasTrustedImage: false,
                staleThreshold: 60,
                now: now
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.acceptsLateFirstSuccess(
                result: .success(now.addingTimeInterval(-61)),
                hasTrustedImage: false,
                staleThreshold: 60,
                now: now
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.acceptsLateFirstSuccess(
                result: .success(now.addingTimeInterval(-30)),
                hasTrustedImage: true,
                staleThreshold: 60,
                now: now
            )
        )
        XCTAssertFalse(
            SnapshotRequestMatchPolicy.acceptsLateFirstSuccess(
                result: .failure(nil),
                hasTrustedImage: false,
                staleThreshold: 60,
                now: now
            )
        )
    }

    func testSnapshotResultTelemetryClarifiesStaleSchedulerSuccessUpdatedImage() {
        XCTAssertEqual(
            SnapshotResultTelemetry.staleSchedulerResultIgnoredMessage(
                feedID: "front",
                requestID: 1,
                currentRequestID: 3,
                result: .success(now.addingTimeInterval(-4)),
                now: now
            ),
            "snapshot stale scheduler result ignored front request=1 current=3 imageUpdated=true captureAge=4.0s"
        )
        XCTAssertEqual(
            SnapshotResultTelemetry.staleSchedulerResultIgnoredMessage(
                feedID: "front",
                requestID: 1,
                currentRequestID: 3,
                result: .failure(nil),
                now: now
            ),
            "snapshot stale scheduler result ignored front request=1 current=3 imageUpdated=false error=nil"
        )
    }

    func testBatteryTrustedStillCanBeCapturedFromAnyWarmLiveStream() {
        let liveStartedAt = now.addingTimeInterval(-6)

        XCTAssertTrue(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: liveStartedAt,
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: nil,
                allowsUnleasedCapture: true,
                warmup: 5,
                now: now
            )
        )
        XCTAssertTrue(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: liveStartedAt,
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: liveStartedAt,
                allowsUnleasedCapture: false,
                warmup: 5,
                now: now
            )
        )
        XCTAssertFalse(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: liveStartedAt,
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: nil,
                allowsUnleasedCapture: false,
                warmup: 5,
                now: now
            )
        )
        XCTAssertFalse(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: now.addingTimeInterval(-2),
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: nil,
                allowsUnleasedCapture: true,
                warmup: 5,
                now: now
            )
        )
        XCTAssertFalse(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: liveStartedAt,
                batteryStillDate: now.addingTimeInterval(-1),
                batteryWakeLeaseStartedAt: nil,
                allowsUnleasedCapture: true,
                warmup: 5,
                now: now
            )
        )
    }

    func testBatteryTrustedStillWarmupStartsAfterLiveConnection() {
        XCTAssertFalse(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: now.addingTimeInterval(-2),
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: now.addingTimeInterval(-10),
                allowsUnleasedCapture: false,
                warmup: 5,
                now: now
            )
        )

        XCTAssertTrue(
            BatteryTrustedStillCapturePolicy.shouldCapture(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: now.addingTimeInterval(-6),
                batteryStillDate: nil,
                batteryWakeLeaseStartedAt: now.addingTimeInterval(-10),
                allowsUnleasedCapture: false,
                warmup: 5,
                now: now
            )
        )
    }

    func testTimedOutLiveStartShouldRestartInsteadOfStayingStartingForever() {
        XCTAssertFalse(
            LiveStartRecoveryPolicy.shouldRestartStartingStream(
                requestedAt: now.addingTimeInterval(-29),
                timeout: 30,
                now: now
            )
        )
        XCTAssertTrue(
            LiveStartRecoveryPolicy.shouldRestartStartingStream(
                requestedAt: now.addingTimeInterval(-31),
                timeout: 30,
                now: now
            )
        )
        XCTAssertFalse(
            LiveStartRecoveryPolicy.shouldRestartStartingStream(
                requestedAt: nil,
                timeout: 30,
                now: now
            )
        )
    }

    func testConstrainedSignalDoesNotPreserveBatteryLeaseBeforeLiveStarts() {
        XCTAssertFalse(
            BatteryWakeConstrainedSignalPolicy.shouldKeepLeaseAlive(
                isBatteryCamera: true,
                isStreaming: false,
                liveStartedAt: nil,
                batteryWakeLeaseStartedAt: now.addingTimeInterval(-5),
                didCaptureTrustedStill: false,
                warmup: 5,
                leaseDuration: 8,
                liveStartTimeout: 30,
                now: now
            )
        )
        XCTAssertTrue(
            BatteryWakeConstrainedSignalPolicy.shouldKeepLeaseAlive(
                isBatteryCamera: true,
                isStreaming: true,
                liveStartedAt: now.addingTimeInterval(-2),
                batteryWakeLeaseStartedAt: now.addingTimeInterval(-5),
                didCaptureTrustedStill: false,
                warmup: 5,
                leaseDuration: 8,
                liveStartTimeout: 30,
                now: now
            )
        )
    }

    func testRestrictedCapacityKeepsOneSlotWhenConstrainedBeforeStreamsReportLive() {
        XCTAssertEqual(
            RestrictedLiveCapacity.enteringAfterConstrainedSignal(currentLiveCount: 0, visibleFeedCount: 4),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.afterConstrainedSignal(previousCapacity: 2, currentLiveCount: 0, visibleFeedCount: 4),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.afterConstrainedSignal(previousCapacity: 3, currentLiveCount: 2, visibleFeedCount: 6),
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
                hasBatteryCaptureDemand: false,
                allVisibleFeedsTrusted: true,
                canProbeCapacity: true
            ),
            2
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                hasBatteryCaptureDemand: false,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 2,
                visibleFeedCount: 4,
                hasBatteryCaptureDemand: false,
                allVisibleFeedsTrusted: true,
                canProbeCapacity: false
            ),
            2
        )
    }

    func testBatteryCaptureDemandUsesKnownCapacityBeforeProbingExtraSlots() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 2,
                visibleFeedCount: 6,
                hasBatteryCaptureDemand: true,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            2
        )
    }

    func testRestrictedCapacityDoesNotProbeExtraSlotWhileBatteryCaptureIsWaiting() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                hasBatteryCaptureDemand: true,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            1
        )
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                hasBatteryCaptureDemand: true,
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
            RestrictedLiveCapacity.afterConstrainedSignal(previousCapacity: 2, currentLiveCount: 0, visibleFeedCount: 0),
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

    func testDisplayClassifierMarksLiveAsGreenAndNotStale() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: true,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: nil,
            staleThreshold: 60,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live")
        XCTAssertEqual(classification.status.indicator, .green)
        XCTAssertFalse(classification.isStale)
    }

    func testInitialCameraTileHidesMissingOrStaleCachedImageBeforeFreshImage() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: nil,
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: now.addingTimeInterval(-61),
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
    }

    func testInitialCameraTileImmediatelyShowsRecentCachedImage() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: now.addingTimeInterval(-60),
                staleThreshold: 60,
                now: now
            ),
            .normal
        )
    }

    func testInitialCameraTileReturnsToNormalOnlyAfterFreshImageReceipt() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: true,
                displayedStillDate: now.addingTimeInterval(-600),
                staleThreshold: 60,
                now: now
            ),
            .normal
        )
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: nil,
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
    }

    func testCameraSessionImageFreshnessIgnoresCacheAndResetsPerSession() {
        var freshness = CameraSessionImageFreshness()

        freshness.apply(.cachedSnapshotPresented)
        XCTAssertFalse(freshness.hasFreshImage)

        freshness.apply(.freshSnapshotReceived)
        XCTAssertTrue(freshness.hasFreshImage)

        freshness.apply(.reset)
        XCTAssertFalse(freshness.hasFreshImage)

        freshness.apply(.liveStreamReceived)
        XCTAssertTrue(freshness.hasFreshImage)
    }

    func testDisplayClassifierKeepsBatteryCaptureLabelWhileLiveWithCountdown() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: true,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            liveStartedAt: now.addingTimeInterval(-1.4),
            displayedStillDate: now.addingTimeInterval(-90),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            batteryCaptureWarmup: 5,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture (4s)")
        XCTAssertEqual(classification.status.indicator, .green)
        XCTAssertEqual(classification.status.recencyTier, .live)
        XCTAssertFalse(classification.isStale)
    }

    func testDisplayClassifierMarksBatteryCaptureBeforeLiveAsYellow() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-45),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            batteryCaptureWarmup: 5,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertFalse(classification.isStale)
    }

    func testDisplayClassifierMarksBatteryCaptureAndWaitingWithoutDisplayedStillAsStale() {
        let capturing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: nil,
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )
        let waiting = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryWaiting,
            displayedStillDate: nil,
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )

        XCTAssertEqual(capturing.status.label, "Live Capture")
        XCTAssertEqual(waiting.status.label, "Queued")
        XCTAssertEqual(capturing.status.indicator, .yellow)
        XCTAssertEqual(waiting.status.indicator, .yellow)
        XCTAssertTrue(capturing.isStale)
        XCTAssertTrue(waiting.isStale)
    }

    func testDisplayClassifierMarksBatteryCaptureAndWaitingWithTrustedStillAsNotStale() {
        let capturing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )
        let waiting = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryWaiting,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )

        XCTAssertFalse(capturing.isStale)
        XCTAssertFalse(waiting.isStale)
    }

    func testBatteryCaptureDoesNotShowStaleBorderUntilVisualThresholdIsReached() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-45),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertFalse(classification.isStale)
    }

    func testBatteryCaptureShowsStaleBorderAfterVisualThresholdIsReached() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-61),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertTrue(classification.isStale)
    }

    func testDisplayClassifierKeepsStatusAndBorderStaleStateTogether() {
        let missing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: nil,
            staleThreshold: 60,
            now: now
        )
        let recent = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 60,
            now: now
        )
        let stale = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .idle,
            displayedStillDate: now.addingTimeInterval(-90),
            staleThreshold: 60,
            now: now
        )

        XCTAssertEqual(missing.status.indicator, .red)
        XCTAssertTrue(missing.isStale)
        XCTAssertEqual(recent.status.indicator, .yellow)
        XCTAssertFalse(recent.isStale)
        XCTAssertEqual(stale.status.indicator, .red)
        XCTAssertTrue(stale.isStale)
    }

    func testWallDensityOrdersAutoBeforeColumnOptions() {
        XCTAssertEqual(WallDensity.allCases, [.auto, .oneColumn, .twoColumns])
        XCTAssertEqual(WallDensity.allCases.map(\.title), ["Auto", "1 Column", "2 Columns"])
        XCTAssertEqual(WallDensity.auto.stepped(by: 1), .oneColumn)
        XCTAssertEqual(WallDensity.oneColumn.stepped(by: 1), .twoColumns)
        XCTAssertEqual(WallDensity.twoColumns.stepped(by: -1), .oneColumn)
    }

    func testWallDensityOptionsStayEditableOnIPhoneButAutoOnlyOnMac() {
        XCTAssertEqual(WallDensity.selectableCases(for: .iPhone), [.auto, .oneColumn, .twoColumns])
        XCTAssertEqual(WallDensity.selectableCases(for: .mac), [.auto])
        XCTAssertTrue(SettingsPresentation.showsWallDensitySection(for: .iPhone))
        XCTAssertFalse(SettingsPresentation.showsWallDensitySection(for: .mac))
        XCTAssertTrue(CameraWallInteraction.allowsDensityAdjustment(for: .iPhone))
        XCTAssertFalse(CameraWallInteraction.allowsDensityAdjustment(for: .mac))
        XCTAssertEqual(SettingsPresentation.doneButtonPlacement(for: .iPhone), .leading)
        XCTAssertEqual(SettingsPresentation.doneButtonPlacement(for: .mac), .trailing)
    }

    func testMainWindowLaunchesMaximizedOnlyOnMac() {
        XCTAssertFalse(MainWindowPresentation.shouldMaximizeOnLaunch(for: .iPhone))
        XCTAssertTrue(MainWindowPresentation.shouldMaximizeOnLaunch(for: .mac))
        XCTAssertNil(MainWindowPresentation.minimumSize(for: .iPhone))
        XCTAssertEqual(MainWindowPresentation.minimumSize(for: .mac), CGSize(width: 120, height: 48))
    }

    func testCameraNameVisibilityControlsWallNameDisplay() {
        XCTAssertTrue(CameraNameVisibility.show.showsName(isOneColumnLayout: false))
        XCTAssertTrue(CameraNameVisibility.show.showsName(isOneColumnLayout: true))
        XCTAssertFalse(CameraNameVisibility.oneColumnOnly.showsName(isOneColumnLayout: false))
        XCTAssertTrue(CameraNameVisibility.oneColumnOnly.showsName(isOneColumnLayout: true))
        XCTAssertFalse(CameraNameVisibility.hide.showsName(isOneColumnLayout: false))
        XCTAssertFalse(CameraNameVisibility.hide.showsName(isOneColumnLayout: true))
        XCTAssertEqual(CameraNameVisibility.allCases.map(\.title), ["Show", "1 Column Only", "Hide"])
    }

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

    func testTelemetryReportIncludesStartupPolicyEventsAndFeedState() {
        let generatedAt = now.addingTimeInterval(20)
        let report = CameraTelemetryReport(
            generatedAt: generatedAt,
            sessionStartedAt: now,
            appVersion: "test",
            authorizationStatus: "authorized",
            selectedHomeName: "Home",
            homeHubState: "Connected",
            sessionMode: "constrained",
            isAppActive: true,
            focusedFeedID: nil,
            liveCapacity: 1,
            visibleFeedCount: 2,
            internalMaxConcurrentSnapshotRequests: 3,
            effectiveMaxConcurrentSnapshotRequests: 2,
            snapshotRequestTimeout: 2.75,
            untrustedSnapshotRefreshInterval: 2,
            trustedSnapshotRefreshInterval: 5,
            batteryCaptureWarmup: 5,
            batteryWakeLeaseDuration: 8,
            batteryWakeLiveStartTimeout: 30,
            startupCoverageActive: true,
            startupLiveRampMode: "fast",
            startupLiveRampSelectedIDs: ["front", "side"],
            startupLiveRampPendingIDs: ["side"],
            startupLiveRampMaxPendingCount: 2,
            startupLiveRampFastThreshold: 3,
            activeSnapshotRequests: 2,
            outstandingSnapshotRequests: 3,
            liveCapacityExpansionBlockedUntil: generatedAt.addingTimeInterval(5),
            liveCapacityIncludesUnconfirmedMemory: false,
            startupMilestones: CameraStartupTelemetryMilestones(
                enteredConstrainedModeAt: 1,
                enteredConstrainedModeLiveCapacity: 1,
                firstConstrainedSignalAt: 1,
                firstConstrainedSignalFeedID: "front",
                allVisibleFeedsTrustedAt: 12,
                allVisibleFeedsLiveAt: 8,
                startupCoverageEndedAt: 15,
                startupCoverageResult: "completedWithUnresolved",
                unresolvedFeedIDs: ["side"],
                peakActiveSnapshotRequests: 3,
                peakOutstandingSnapshotRequests: 4,
                feedsByID: [
                    "front": CameraStartupTelemetryFeedMilestones(
                        feedID: "front",
                        firstTrustedImageAt: 12,
                        firstSnapshotQueuedAt: 1,
                        firstSnapshotIssuedAt: 2,
                        firstSnapshotSuccessAt: 3,
                        lastSnapshotSuccessAt: 10,
                        snapshotQueuedCount: 5,
                        snapshotIssuedCount: 3,
                        snapshotSuccessCount: 2,
                        snapshotFailureCount: 1,
                        snapshotTimeoutCount: 1,
                        lastSnapshotCallbackLatency: 2.5,
                        firstStartupLiveFallbackAt: 4,
                        startupResolvedAsUnresolved: false,
                        firstBatteryWakeLeaseStartedAt: nil,
                        firstBatteryTrustedStillAt: nil,
                        batteryWakeLeaseStartedCount: 0,
                        batteryTrustedStillCount: 0,
                        batteryWakeFailureCount: 0,
                        batteryWakeTimeoutCount: 0
                    )
                ]
            ),
            feeds: [
                CameraTelemetryFeed(
                    priorityIndex: 0,
                    id: "front",
                    name: "Front",
                    roomName: "Porch",
                    isVisibleOnWall: true,
                    isReachable: true,
                    isAvailableInSession: true,
                    isHomeKitCameraActive: true,
                    isBatteryWakeCamera: false,
                    isStreaming: false,
                    isStartingLive: false,
                    displayState: "starting",
                    recencyTier: "empty",
                    recoveryPhase: "idle",
                    snapshotPriority: "urgent",
                    presentationMode: "snapshot",
                    displayedStillAge: nil,
                    lastSnapshotSuccessAge: nil,
                    snapshotWorkState: "active",
                    snapshotRequestID: "4",
                    snapshotInFlightAge: 1,
                    snapshotOverdueAge: nil,
                    nextEligibleSnapshotIn: 1,
                    lastSnapshotRequestAge: 1,
                    startupCoverageResolution: "pending",
                    startupSnapshotAttempted: true,
                    startupSnapshotPath: "inFlight",
                    startupLivePath: "notAttempted",
                    startupLiveFallbackAge: nil,
                    batteryStillAge: nil,
                    batteryWakeLeaseAge: nil,
                    batteryWakeRetryIn: nil,
                    consecutiveBatteryWakeFailures: 0,
                    liveStartedAge: nil,
                    liveStartRequestedAge: nil,
                    lastErrorMessage: nil
                )
            ],
            events: [
                CameraTelemetryEvent(elapsed: 0, message: "session start"),
                CameraTelemetryEvent(elapsed: 2, message: "snapshot issued front priority=urgent")
            ]
        )

        let text = report.text
        XCTAssertTrue(text.contains("Observe Telemetry"))
        XCTAssertTrue(text.contains("sessionElapsed=20.0s"))
        XCTAssertTrue(text.contains("internalMaxConcurrentSnapshotRequests=3"))
        XCTAssertTrue(text.contains("effectiveMaxConcurrentSnapshotRequests=2"))
        XCTAssertTrue(text.contains("startupLiveRampMode=fast"))
        XCTAssertTrue(text.contains("startupLiveRampSelectedIDs=front,side"))
        XCTAssertTrue(text.contains("startupLiveRampPendingIDs=side"))
        XCTAssertTrue(text.contains("startupLiveRampMaxPendingCount=2"))
        XCTAssertTrue(text.contains("startupLiveRampFastThreshold=3.0s"))
        XCTAssertTrue(text.contains("outstandingSnapshotRequests=3"))
        XCTAssertTrue(text.contains("untrustedSnapshotRefreshInterval=2.0s"))
        XCTAssertTrue(text.contains("allVisibleFeedsTrustedAt=12.0s"))
        XCTAssertTrue(text.contains("allVisibleFeedsLiveAt=8.0s"))
        XCTAssertTrue(text.contains("startupCoverageResult=completedWithUnresolved"))
        XCTAssertTrue(text.contains("peakOutstandingSnapshotRequests=4"))
        XCTAssertTrue(text.contains("front | firstTrustedImageAt=12.0s"))
        XCTAssertTrue(text.contains("snapshotTimeoutCount=1"))
        XCTAssertTrue(text.contains("front | Front | room=Porch"))
        XCTAssertTrue(text.contains("snapshotInFlightAge=1.0s"))
        XCTAssertTrue(text.contains("snapshotWorkState=active"))
        XCTAssertTrue(text.contains("startupSnapshotPath=inFlight"))
        XCTAssertTrue(text.contains("startupLivePath=notAttempted"))
        XCTAssertTrue(text.contains("+2.0s snapshot issued front priority=urgent"))
    }

    @MainActor
    func testAutoWallDensityPreferenceRoundTrip() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        preferences.wallDensity = .auto

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.wallDensity, .auto)

        defaults.set("focus", forKey: "observe.wallDensity")
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).wallDensity, .oneColumn)

        defaults.set("overview", forKey: "observe.wallDensity")
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).wallDensity, .twoColumns)

        defaults.removePersistentDomain(forName: suiteName)
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

    func testCameraWallDismissesFullScreenSelectionWhenAppLeavesForeground() {
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .active, hasSelectedFeed: true))
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .inactive, hasSelectedFeed: true))
        XCTAssertTrue(CameraWallPresentation.shouldClearSelection(scenePhase: .background, hasSelectedFeed: true))
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .background, hasSelectedFeed: false))
    }

    func testAlreadyActiveScenePhaseDoesNotRebuildCameraSession() {
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: true, nextActive: true))
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: true, nextActive: false))
        XCTAssertFalse(CameraSessionActivation.shouldRebuildSession(currentlyActive: false, nextActive: false))
        XCTAssertTrue(CameraSessionActivation.shouldRebuildSession(currentlyActive: false, nextActive: true))
    }

    func testHomeKitOffAndNotRespondingRemoveCameraFromWallSlots() {
        XCTAssertTrue(CameraWallAvailability.isVisibleOnWall(isReachable: true, isAvailableInSession: true, isHomeKitCameraActive: true))
        XCTAssertTrue(CameraWallAvailability.isVisibleOnWall(isReachable: true, isAvailableInSession: true, isHomeKitCameraActive: nil))
        XCTAssertFalse(CameraWallAvailability.isVisibleOnWall(isReachable: false, isAvailableInSession: true, isHomeKitCameraActive: true))
        XCTAssertTrue(CameraWallAvailability.isVisibleOnWall(isReachable: true, isAvailableInSession: false, isHomeKitCameraActive: true))
        XCTAssertFalse(CameraWallAvailability.isVisibleOnWall(isReachable: true, isAvailableInSession: true, isHomeKitCameraActive: false))
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
            serviceType: "0000021a-0000-1000-8000-0026bb765291",
            characteristicType: "0000021b-0000-1000-8000-0026bb765291",
            value: false
        )
        let onSnapshot = CameraWallAvailability.CharacteristicSnapshot(
            serviceType: "0000021A-0000-1000-8000-0026BB765291",
            characteristicType: "0000021B-0000-1000-8000-0026BB765291",
            value: true
        )

        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: [offSnapshot]), false)
        XCTAssertEqual(CameraWallAvailability.homeKitCameraActiveState(from: [onSnapshot]), true)
    }

    func testRTPInactiveAloneDoesNotRemoveCameraFromWallSlots() {
        let rtpInactive = CameraWallAvailability.CharacteristicSnapshot(
            serviceType: HMServiceTypeCameraRTPStreamManagement,
            characteristicType: HMCharacteristicTypeActive,
            value: false
        )
        let rtpActive = CameraWallAvailability.CharacteristicSnapshot(
            serviceType: HMServiceTypeCameraRTPStreamManagement,
            characteristicType: HMCharacteristicTypeActive,
            value: true
        )
        let detectingActivity = CameraWallAvailability.CharacteristicSnapshot(
            serviceType: "0000021A-0000-1000-8000-0026BB765291",
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

    func testAutoWallLayoutFitsOneThroughTenCamerasInPortraitWithoutCropping() {
        let layout = CameraWallAutoLayout(availableSize: CGSize(width: 390, height: 820), spacing: 8)

        for count in 1...10 {
            let cameras = makeAutoLayoutCameras(count: count)
            let tiles = layout.tiles(for: cameras)

            XCTAssertEqual(tiles.map(\.id), cameras.map(\.id), "count \(count)")
            assertAutoTiles(tiles, fitIn: CGSize(width: 390, height: 820), message: "count \(count)")
        }
    }

    func testAutoWallLayoutCentersOnePortraitCameraAtFullWidth() {
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: [
            CameraWallAutoLayout.Camera(id: "front", aspectRatio: 16 / 9)
        ])

        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.width, 390, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.height, 219.375, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.midY, 410, accuracy: 0.001)
    }

    func testAutoWallLayoutStacksTwoPortraitCamerasWithBalancedVerticalSpacing() {
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: [
            CameraWallAutoLayout.Camera(id: "front", aspectRatio: 16 / 9),
            CameraWallAutoLayout.Camera(id: "back", aspectRatio: 16 / 9)
        ])

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[1].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.width, 390, accuracy: 0.001)
        XCTAssertEqual(tiles[1].frame.width, 390, accuracy: 0.001)

        let topGap = tiles[0].frame.minY
        let middleGap = tiles[1].frame.minY - tiles[0].frame.maxY
        let bottomGap = 820 - tiles[1].frame.maxY
        XCTAssertEqual(topGap, bottomGap, accuracy: 0.001)
        XCTAssertEqual(topGap, middleGap, accuracy: 0.001)
    }

    func testAutoWallLayoutFitsLandscapeAndDiffersFromPortrait() {
        let cameras = makeAutoLayoutCameras(count: 7)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)
        let landscape = CameraWallAutoLayout(
            availableSize: CGSize(width: 820, height: 390),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(landscape.map(\.id), cameras.map(\.id))
        assertAutoTiles(landscape, fitIn: CGSize(width: 820, height: 390), message: "landscape")
        XCTAssertNotEqual(portrait.map { roundedFrame($0.frame) }, landscape.map { roundedFrame($0.frame) })
    }

    func testAutoWallLayoutLimitsPortraitRowsToTwoColumns() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertLessThanOrEqual(maxRowSize(in: portrait), 2)
    }

    func testAutoWallLayoutGivesSixPortraitCamerasTwoPriorityRows() {
        let cameras = makeAutoLayoutCameras(count: 6)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(rowSizes(in: portrait), [1, 1, 2, 2])
    }

    func testAutoWallLayoutAllowsMoreThanTwoColumnsInLandscape() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let landscape = CameraWallAutoLayout(
            availableSize: CGSize(width: 820, height: 390),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertGreaterThan(maxRowSize(in: landscape), 2)
    }

    func testAutoWallLayoutCapsAtTenAndKeepsPriorityOrder() {
        let cameras = makeAutoLayoutCameras(count: 12)
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(tiles.map(\.id), cameras.prefix(10).map(\.id))
    }

    func testAutoWallLayoutHandlesMixedAndInvalidAspectRatios() {
        let cameras = [
            CameraWallAutoLayout.Camera(id: "wide", aspectRatio: 2.4),
            CameraWallAutoLayout.Camera(id: "tall", aspectRatio: 0.5),
            CameraWallAutoLayout.Camera(id: "invalid", aspectRatio: 0),
            CameraWallAutoLayout.Camera(id: "nan", aspectRatio: .nan),
            CameraWallAutoLayout.Camera(id: "normal", aspectRatio: 16 / 9)
        ]

        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 430, height: 700),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(tiles.map(\.id), cameras.map(\.id))
        assertAutoTiles(tiles, fitIn: CGSize(width: 430, height: 700), message: "mixed ratios")
        XCTAssertEqual(tiles[0].aspectRatio, 2.2, accuracy: 0.001)
        XCTAssertEqual(tiles[1].aspectRatio, 0.75, accuracy: 0.001)
        XCTAssertEqual(tiles[2].aspectRatio, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(tiles[3].aspectRatio, 16 / 9, accuracy: 0.001)
    }

    func testMacAutoWallLayoutChoosesColumnsFromWindowShape() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let square = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 900, height: 900),
            spacing: 8
        ).layout(for: cameras)
        let wide = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 1440, height: 900),
            spacing: 8
        ).layout(for: cameras)
        let narrow = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 500, height: 900),
            spacing: 8
        ).layout(for: cameras)

        XCTAssertEqual(maxRowSize(in: square.tiles), 3)
        XCTAssertEqual(maxRowSize(in: wide.tiles), 4)
        XCTAssertEqual(maxRowSize(in: narrow.tiles), 2)
        XCTAssertEqual(square.contentSize, CGSize(width: 900, height: 900))
        XCTAssertEqual(wide.contentSize, CGSize(width: 1440, height: 900))
        XCTAssertEqual(narrow.contentSize, CGSize(width: 500, height: 900))
        assertMacTiles(square.tiles, fitIn: CGSize(width: 900, height: 900), message: "square")
        assertMacTiles(wide.tiles, fitIn: CGSize(width: 1440, height: 900), message: "wide")
        assertMacTiles(narrow.tiles, fitIn: CGSize(width: 500, height: 900), message: "narrow")
    }

    func testMacAutoWallLayoutFitsEveryTileInSmallWindows() {
        let cameras = makeAutoLayoutCameras(count: 4)
        let availableSize = CGSize(width: 320, height: 360)
        let layout = CameraWallMacAutoLayout(
            availableSize: availableSize,
            spacing: 8
        ).layout(for: cameras)

        XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id))
        XCTAssertEqual(layout.contentSize, availableSize)
        assertMacTiles(layout.tiles, fitIn: availableSize, message: "small window")
    }

    func testMacAutoWallLayoutFitsEveryTileInTinyResizableWindows() {
        let cameras = makeAutoLayoutCameras(count: 4)
        let sizes = [
            CGSize(width: 160, height: 48),
            CGSize(width: 220, height: 90),
            CGSize(width: 96, height: 320)
        ]

        for size in sizes {
            let layout = CameraWallMacAutoLayout(availableSize: size, spacing: 8).layout(for: cameras)

            XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id), "\(size)")
            XCTAssertEqual(layout.contentSize, size, "\(size)")
            assertMacTiles(layout.tiles, fitIn: size, message: "\(size)")
        }
    }

    func testMacAutoWallLayoutFitsEveryTileInAwkwardResizableWindows() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let sizes = [
            CGSize(width: 1212, height: 839),
            CGSize(width: 1180, height: 680),
            CGSize(width: 760, height: 560),
            CGSize(width: 520, height: 720)
        ]

        for size in sizes {
            let layout = CameraWallMacAutoLayout(availableSize: size, spacing: 8).layout(for: cameras)

            XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id), "\(size)")
            XCTAssertEqual(layout.contentSize, size, "\(size)")
            assertMacTiles(layout.tiles, fitIn: size, message: "\(size)")
        }
    }

    func testMacAutoWallLayoutIncludesMoreThanThePhoneAutoLimit() {
        let cameras = makeAutoLayoutCameras(count: CameraWallAutoLayout.maxCameraCount + 2)
        let availableSize = CGSize(width: 1440, height: 900)
        let layout = CameraWallMacAutoLayout(availableSize: availableSize, spacing: 8).layout(for: cameras)

        XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id))
        XCTAssertEqual(layout.contentSize, availableSize)
        assertMacTiles(layout.tiles, fitIn: availableSize, message: "more than phone limit")
    }

    private func makeFeed(
        id: String,
        priorityIndex: Int,
        isFocused: Bool = false,
        isStreaming: Bool = false,
        liveStartedAt: Date? = nil,
        lastSnapshotAge: TimeInterval? = nil,
        staleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold,
        isBatteryWakeCamera: Bool = false,
        batteryWakeTriggerThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold,
        batteryWakeLeaseStartedAt: Date? = nil,
        batteryWakeRetryAfter: Date? = nil,
        startupSnapshotAttempted: Bool = false,
        startupLiveFallbackStartedAt: Date? = nil,
        startupCoverageResolution: StartupCoverageResolution = .pending
    ) -> FeedPlanningSnapshot {
        let resolvedStaleThreshold = isBatteryWakeCamera
            ? CameraSchedulingDefaults.batteryStaleThreshold
            : staleThreshold
        var startupState = StartupCameraState()
        if startupSnapshotAttempted {
            startupState.apply(.snapshotRequested(at: now), isBatteryCamera: isBatteryWakeCamera)
        }
        if let startupLiveFallbackStartedAt {
            startupState.apply(
                .liveRequested(at: startupLiveFallbackStartedAt),
                isBatteryCamera: isBatteryWakeCamera
            )
        }
        switch startupCoverageResolution {
        case .pending:
            break
        case .trusted:
            startupState.apply(.trustedImageObserved, isBatteryCamera: isBatteryWakeCamera)
        case .unresolved:
            startupState.apply(.snapshotFailed, isBatteryCamera: isBatteryWakeCamera)
            startupState.apply(.liveFailed, isBatteryCamera: isBatteryWakeCamera)
        }

        return FeedPlanningSnapshot(
            id: id,
            priorityIndex: priorityIndex,
            isFocused: isFocused,
            isStreaming: isStreaming,
            liveStartedAt: liveStartedAt,
            lastSnapshotDate: lastSnapshotAge.map { now.addingTimeInterval(-$0) },
            staleThreshold: resolvedStaleThreshold,
            isBatteryWakeCamera: isBatteryWakeCamera,
            batteryWakeTriggerThreshold: batteryWakeTriggerThreshold,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            batteryWakeRetryAfter: batteryWakeRetryAfter,
            startupState: startupState
        )
    }

    private func liveIDs(in plan: CameraRecoveryPlan) -> [String] {
        plan.decisionsByID.values
            .filter { $0.presentationMode == .live }
            .map(\.id)
            .sorted()
    }

    private func makeAutoLayoutCameras(count: Int) -> [CameraWallAutoLayout.Camera] {
        (0..<count).map { index in
            CameraWallAutoLayout.Camera(id: "camera-\(index)", aspectRatio: index.isMultiple(of: 3) ? 4 / 3 : 16 / 9)
        }
    }

    private func assertAutoTiles(
        _ tiles: [CameraWallAutoLayout.Tile],
        fitIn availableSize: CGSize,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for tile in tiles {
            XCTAssertGreaterThan(tile.frame.width, 0, message, file: file, line: line)
            XCTAssertGreaterThan(tile.frame.height, 0, message, file: file, line: line)
            XCTAssertGreaterThanOrEqual(tile.frame.minX, -0.01, message, file: file, line: line)
            XCTAssertGreaterThanOrEqual(tile.frame.minY, -0.01, message, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.frame.maxX, availableSize.width + 0.01, message, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.frame.maxY, availableSize.height + 0.01, message, file: file, line: line)
            XCTAssertEqual(tile.frame.width / tile.frame.height, tile.aspectRatio, accuracy: 0.001, message, file: file, line: line)
        }
    }

    private func assertMacTiles(
        _ tiles: [CameraWallAutoLayout.Tile],
        fitIn contentSize: CGSize,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertAutoTiles(tiles, fitIn: contentSize, message: message, file: file, line: line)
        XCTAssertFalse(tiles.isEmpty, message, file: file, line: line)
        for tile in tiles {
            XCTAssertTrue(tile.frame.width.isFinite, message, file: file, line: line)
            XCTAssertTrue(tile.frame.height.isFinite, message, file: file, line: line)
        }
    }

    private func roundedFrame(_ frame: CGRect) -> String {
        "\(Int(frame.minX.rounded()))-\(Int(frame.minY.rounded()))-\(Int(frame.width.rounded()))-\(Int(frame.height.rounded()))"
    }

    private func maxRowSize(in tiles: [CameraWallAutoLayout.Tile]) -> Int {
        rowSizes(in: tiles).max() ?? 0
    }

    private func rowSizes(in tiles: [CameraWallAutoLayout.Tile]) -> [Int] {
        let rows = Dictionary(grouping: tiles) { tile in
            Int(tile.frame.midY.rounded())
        }
        return rows
            .sorted { $0.key < $1.key }
            .map { $0.value.count }
    }
}

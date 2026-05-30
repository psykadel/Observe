import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class ObserveTests: XCTestCase {
    private let planner = CameraRecoveryPlanner()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testOptimisticModeRequestsLiveForEveryFeedAndNonBatterySnapshotFallbacks() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "back", priorityIndex: 1, lastSnapshotAge: 90, isBatteryWakeCamera: true),
                makeFeed(id: "side", priorityIndex: 2),
                makeFeed(id: "driveway", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            sessionMode: .optimistic,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["back", "driveway", "front", "side"])
        XCTAssertEqual(plan.decisionsByID["back"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["side"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.decisionsByID["driveway"]?.snapshotPriority, .refresh)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["side", "driveway"])
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

    func testSnapshotQueuePreservesFailureBackoffButAllowsContinuousRefresh() {
        let backedOffUntil = now.addingTimeInterval(3)

        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(current: backedOffUntil, requestedAt: now),
            backedOffUntil
        )
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(current: now.addingTimeInterval(-2), requestedAt: now),
            now
        )
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(current: .distantFuture, requestedAt: now),
            now
        )
    }

    func testSnapshotQueueEnforcesMinimumRefreshIntervalPerCamera() {
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(
                current: .distantFuture,
                requestedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-1),
                minimumInterval: 5
            ),
            now.addingTimeInterval(4)
        )
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(
                current: now.addingTimeInterval(10),
                requestedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-1),
                minimumInterval: 5
            ),
            now.addingTimeInterval(10)
        )
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDate(
                current: .distantFuture,
                requestedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-8),
                minimumInterval: 5
            ),
            now
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
                warmup: 5,
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
            2
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

    func testRestrictedCapacityProbesOneExtraSlotWhileBatteryCaptureIsWaiting() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 1,
                visibleFeedCount: 4,
                hasBatteryCaptureDemand: true,
                allVisibleFeedsTrusted: false,
                canProbeCapacity: true
            ),
            2
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

    @MainActor
    func testBatteryWakePreferenceRoundTrip() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        XCTAssertFalse(preferences.isBatteryWakeCamera(id: "battery"))
        XCTAssertEqual(preferences.batteryCaptureWarmupSeconds, 5)

        preferences.setBatteryWakeEnabled(true, for: "battery")
        preferences.setBatteryWakeTriggerSeconds(75)
        preferences.setBatteryCaptureWarmupSeconds(9)
        preferences.setBatteryStaleSeconds(150)
        XCTAssertTrue(preferences.isBatteryWakeCamera(id: "battery"))

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertTrue(reloaded.isBatteryWakeCamera(id: "battery"))
        XCTAssertEqual(reloaded.batteryWakeTriggerSeconds, 75)
        XCTAssertEqual(reloaded.batteryCaptureWarmupSeconds, 9)
        XCTAssertEqual(reloaded.batteryStaleSeconds, 150)

        defaults.removePersistentDomain(forName: suiteName)
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
        batteryWakeRetryAfter: Date? = nil
    ) -> FeedPlanningSnapshot {
        let resolvedStaleThreshold = isBatteryWakeCamera
            ? CameraSchedulingDefaults.batteryStaleThreshold
            : staleThreshold

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
            batteryWakeRetryAfter: batteryWakeRetryAfter
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

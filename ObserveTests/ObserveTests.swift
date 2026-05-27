import XCTest
@testable import Observe

final class ObserveTests: XCTestCase {
    private let planner = CameraRecoveryPlanner()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testOptimisticModeRequestsLiveForEveryFeedWithoutRefreshWork() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "back", priorityIndex: 1, lastSnapshotAge: 90, isBatteryWakeCamera: true),
                makeFeed(id: "side", priorityIndex: 2)
            ],
            sessionMode: .optimistic,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["back", "front", "side"])
        XCTAssertEqual(plan.decisionsByID["back"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.orderedSnapshotIDs, [])
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

        XCTAssertEqual(liveIDs(in: plan), ["active-battery"])
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["focused"]?.presentationMode, .snapshot)
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

    func testNonBatterySnapshotRefreshesContinuouslyUseUIPriorityOnly() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "stale-first", priorityIndex: 0, lastSnapshotAge: 80),
                makeFeed(id: "empty-second", priorityIndex: 1),
                makeFeed(id: "battery", priorityIndex: 2, isBatteryWakeCamera: true),
                makeFeed(id: "recent", priorityIndex: 3, lastSnapshotAge: 5),
                makeFeed(id: "live", priorityIndex: 4, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(plan.orderedSnapshotIDs, ["stale-first", "empty-second", "recent"])
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

    func testDisplayClassifierMarksBatteryCaptureAndWaitingWithoutTrustedStillAsStale() {
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
            displayedStillDate: now.addingTimeInterval(-90),
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )

        XCTAssertEqual(capturing.status.label, "Capturing")
        XCTAssertEqual(waiting.status.label, "Wait for Capture")
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

    private func makeFeed(
        id: String,
        priorityIndex: Int,
        isFocused: Bool = false,
        isStreaming: Bool = false,
        lastSnapshotAge: TimeInterval? = nil,
        staleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold,
        isBatteryWakeCamera: Bool = false,
        batteryWakeTriggerThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold,
        batteryWakeLeaseStartedAt: Date? = nil
    ) -> FeedPlanningSnapshot {
        let resolvedStaleThreshold = isBatteryWakeCamera
            ? CameraSchedulingDefaults.batteryStaleThreshold
            : staleThreshold

        return FeedPlanningSnapshot(
            id: id,
            priorityIndex: priorityIndex,
            isFocused: isFocused,
            isStreaming: isStreaming,
            lastSnapshotDate: lastSnapshotAge.map { now.addingTimeInterval(-$0) },
            staleThreshold: resolvedStaleThreshold,
            isBatteryWakeCamera: isBatteryWakeCamera,
            batteryWakeTriggerThreshold: batteryWakeTriggerThreshold,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt
        )
    }

    private func liveIDs(in plan: CameraRecoveryPlan) -> [String] {
        plan.decisionsByID.values
            .filter { $0.presentationMode == .live }
            .map(\.id)
            .sorted()
    }
}

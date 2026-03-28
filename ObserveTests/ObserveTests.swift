import XCTest
@testable import Observe

final class ObserveTests: XCTestCase {
    private let planner = CameraRecoveryPlanner()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testOptimisticModeRequestsLiveForEveryFeedAndSkipsFreshSnapshotWork() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "back", priorityIndex: 1, lastSnapshotAge: 4)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["front"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .live)
        XCTAssertEqual(plan.orderedSnapshotIDs, [])
    }

    func testConstrainedModePinsFocusedFeedAndPromotesRedFeedOverHealthyLiveFeed() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "focused", priorityIndex: 0, isFocused: true, lastSnapshotAge: 3),
                makeFeed(id: "red", priorityIndex: 1, lastSnapshotAge: 14),
                makeFeed(id: "healthy-live", priorityIndex: 2, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused", "red"])
        XCTAssertEqual(plan.decisionsByID["red"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .snapshot)
    }

    func testBatteryCameraWithNoStillIsImmediatelyEligibleForCapture() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery", priorityIndex: 1, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWake)
    }

    func testHigherPriorityFeedWinsEvenIfLowerPriorityFeedIsAlreadyLive() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "higher-priority", priorityIndex: 0, lastSnapshotAge: 4),
                makeFeed(id: "lower-priority-live", priorityIndex: 1, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["higher-priority"])
        XCTAssertEqual(plan.decisionsByID["lower-priority-live"]?.presentationMode, .snapshot)
    }

    func testSnapshotQueuePrefersEmptyThenOldestRedThenYellow() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "empty", priorityIndex: 1),
                makeFeed(id: "older-red", priorityIndex: 2, lastSnapshotAge: 21),
                makeFeed(id: "newer-red", priorityIndex: 3, lastSnapshotAge: 12),
                makeFeed(id: "yellow", priorityIndex: 4, lastSnapshotAge: 4)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(plan.orderedSnapshotIDs, ["empty", "older-red", "newer-red", "yellow"])
    }

    func testRecentSnapshotExitsRecoveryEvenWithOldLeaseMetadata() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "recent",
                    priorityIndex: 0,
                    lastSnapshotAge: 5,
                    liveRecoveryLeaseStartedAt: now.addingTimeInterval(-2),
                    liveRetryEligibleAt: now.addingTimeInterval(3)
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["recent"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["recent"]?.snapshotPriority, .maintenance)
    }

    func testRedFeedKeepsUrgentSnapshotPriorityWhileAssignedLive() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "red", priorityIndex: 0, lastSnapshotAge: 15),
                makeFeed(id: "other", priorityIndex: 1, lastSnapshotAge: 5)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["red"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["red"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["red"])
    }

    func testHigherPriorityRecentSnapshotPreemptsLowerPriorityHealthyLiveFeed() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front-door", priorityIndex: 0, lastSnapshotAge: 4),
                makeFeed(id: "second", priorityIndex: 1, isStreaming: true),
                makeFeed(id: "third", priorityIndex: 2, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front-door", "second"])
        XCTAssertEqual(plan.decisionsByID["third"]?.presentationMode, .snapshot)
    }

    func testTaggedBatteryCameraStaysInSnapshotUntilWakeThreshold() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery", priorityIndex: 1, lastSnapshotAge: 20, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }

    func testTaggedBatteryCameraUsesBatteryWakeAfterThreshold() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery", priorityIndex: 1, lastSnapshotAge: 70, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWake)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .live)
    }

    func testActiveBatteryWakeLeaseKeepsCameraSelectedLive() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 20,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-2)
                ),
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWake)
    }

    func testBatteryWakeCooldownPreventsImmediateReselection() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeCooldownUntil: now.addingTimeInterval(60)
                ),
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }

    func testBatteryWakeCanBeForcedEvenWhenSnapshotLooksRecent() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 5,
                    isBatteryWakeCamera: true,
                    batteryWakeForceEligible: true
                ),
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWake)
    }

    func testFocusedFeedIsNotDisplacedByBatteryWake() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "focused", priorityIndex: 0, isFocused: true, lastSnapshotAge: 3),
                makeFeed(id: "battery", priorityIndex: 1, lastSnapshotAge: 70, isBatteryWakeCamera: true),
                makeFeed(id: "healthy-live", priorityIndex: 2, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .snapshot)
    }

    func testOnlyOneBatteryWakeCameraIsSelectedAtATime() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "battery-older", priorityIndex: 1, lastSnapshotAge: 80, isBatteryWakeCamera: true),
                makeFeed(id: "battery-newer", priorityIndex: 2, lastSnapshotAge: 70, isBatteryWakeCamera: true),
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery-older", "healthy-live"])
        XCTAssertEqual(plan.decisionsByID["battery-older"]?.recoveryPhase, .batteryWake)
        XCTAssertEqual(plan.decisionsByID["battery-newer"]?.presentationMode, .snapshot)
    }

    func testOptimisticModeDoesNotUseBatteryWakeRecoveryPhase() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "battery", priorityIndex: 0, lastSnapshotAge: 70, isBatteryWakeCamera: true)
            ],
            sessionMode: .optimistic,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertNotEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWake)
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

        preferences.setBatteryWakeEnabled(true, for: "battery")
        preferences.setBatteryWakeTriggerSeconds(75)
        preferences.setBatteryStaleSeconds(150)
        XCTAssertTrue(preferences.isBatteryWakeCamera(id: "battery"))

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertTrue(reloaded.isBatteryWakeCamera(id: "battery"))
        XCTAssertEqual(reloaded.batteryWakeTriggerSeconds, 75)
        XCTAssertEqual(reloaded.batteryStaleSeconds, 150)

        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeFeed(
        id: String,
        priorityIndex: Int,
        isFocused: Bool = false,
        isStreaming: Bool = false,
        lastSnapshotAge: TimeInterval? = nil,
        staleThreshold: TimeInterval = CameraSchedulingDefaults.staleSnapshotThreshold,
        liveRecoveryLeaseStartedAt: Date? = nil,
        liveRetryEligibleAt: Date? = nil,
        isBatteryWakeCamera: Bool = false,
        batteryWakeForceEligible: Bool = false,
        batteryWakeTriggerThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold,
        batteryWakeLeaseStartedAt: Date? = nil,
        batteryWakeCooldownUntil: Date? = nil
    ) -> FeedPlanningSnapshot {
        let resolvedStaleThreshold = if isBatteryWakeCamera {
            CameraSchedulingDefaults.batteryStaleThreshold
        } else {
            staleThreshold
        }
        return FeedPlanningSnapshot(
            id: id,
            priorityIndex: priorityIndex,
            isFocused: isFocused,
            isStreaming: isStreaming,
            lastSnapshotDate: lastSnapshotAge.map { now.addingTimeInterval(-$0) },
            staleThreshold: resolvedStaleThreshold,
            isBatteryWakeCamera: isBatteryWakeCamera,
            batteryWakeForceEligible: batteryWakeForceEligible,
            batteryWakeTriggerThreshold: batteryWakeTriggerThreshold,
            liveRecoveryLeaseStartedAt: liveRecoveryLeaseStartedAt,
            liveRetryEligibleAt: liveRetryEligibleAt,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            batteryWakeCooldownUntil: batteryWakeCooldownUntil
        )
    }

    private func liveIDs(in plan: CameraRecoveryPlan) -> [String] {
        plan.decisionsByID.values
            .filter { $0.presentationMode == .live }
            .map(\.id)
            .sorted()
    }
}

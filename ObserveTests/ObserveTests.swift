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
        XCTAssertEqual(plan.decisionsByID["red"]?.recoveryPhase, .liveRecovery)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .snapshot)
    }

    func testActiveRecoveryLeaseKeepsRedFeedInLiveSelection() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "leased-red",
                    priorityIndex: 1,
                    lastSnapshotAge: 18,
                    liveRecoveryLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["leased-red"])
        XCTAssertEqual(plan.decisionsByID["leased-red"]?.recoveryPhase, .liveRecovery)
    }

    func testExpiredRecoveryLeaseRespectsLiveRetryCooldown() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "cooling-red",
                    priorityIndex: 0,
                    lastSnapshotAge: 18,
                    liveRecoveryLeaseStartedAt: now.addingTimeInterval(-4),
                    liveRetryEligibleAt: now.addingTimeInterval(4)
                ),
                makeFeed(id: "healthy-live", priorityIndex: 1, isStreaming: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["healthy-live"])
        XCTAssertEqual(plan.decisionsByID["cooling-red"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["cooling-red"]?.recoveryPhase, .snapshotRecovery)
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

    private func makeFeed(
        id: String,
        priorityIndex: Int,
        isFocused: Bool = false,
        isStreaming: Bool = false,
        lastSnapshotAge: TimeInterval? = nil,
        liveRecoveryLeaseStartedAt: Date? = nil,
        liveRetryEligibleAt: Date? = nil
    ) -> FeedPlanningSnapshot {
        FeedPlanningSnapshot(
            id: id,
            priorityIndex: priorityIndex,
            isFocused: isFocused,
            isStreaming: isStreaming,
            lastSnapshotDate: lastSnapshotAge.map { now.addingTimeInterval(-$0) },
            liveRecoveryLeaseStartedAt: liveRecoveryLeaseStartedAt,
            liveRetryEligibleAt: liveRetryEligibleAt
        )
    }

    private func liveIDs(in plan: CameraRecoveryPlan) -> [String] {
        plan.decisionsByID.values
            .filter { $0.presentationMode == .live }
            .map(\.id)
            .sorted()
    }
}

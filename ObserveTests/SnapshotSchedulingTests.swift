import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class SnapshotSchedulingTests: ObserveTestCase {
    func testConstrainedCapacityZeroQueuesBatteryAndContinuouslyRefreshesNonBatterySnapshots() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "empty", priorityIndex: 0),
                makeFeed(id: "battery", priorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "stale", priorityIndex: 2, lastSnapshotAge: 90),
                makeFeed(id: "recent", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["empty", "stale", "recent"])
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
    func testSnapshotFailureRetriesAfterOneSecond() {
        XCTAssertEqual(
            SnapshotQueuePolicy.nextEligibleDateAfterFailure(failedAt: now),
            now.addingTimeInterval(1)
        )
    }
    func testRestrictedStartupSnapshotRecoveryBeginsAfterFirstFailure() {
        var startupState = StartupCameraState()
        startupState.apply(.snapshotRequested(at: now.addingTimeInterval(-4)), isBatteryCamera: false)
        startupState.apply(.snapshotFailed(entersRecovery: true), isBatteryCamera: false)

        XCTAssertEqual(startupState.resolution, .recovering)
        XCTAssertEqual(
            StartupSnapshotRecoveryPolicy.retryEligibleDate(
                startupCoverageActive: true,
                startupState: startupState,
                snapshotFailedAt: now
            ),
            now.addingTimeInterval(1)
        )
    }
    func testSnapshotQueueingIsIdempotentUntilPriorityIncreases() {
        let initialDate = now.addingTimeInterval(3)
        var state = SnapshotWorkState.queued(priority: .refresh, eligibleAt: initialDate)

        XCTAssertFalse(state.enqueue(priority: .refresh, eligibleAt: now))
        XCTAssertEqual(state, .queued(priority: .refresh, eligibleAt: initialDate))

        XCTAssertTrue(state.enqueue(priority: .urgent, eligibleAt: now))
        XCTAssertEqual(state, .queued(priority: .urgent, eligibleAt: now))
    }
    func testLiveTargetAlsoQueuesSnapshotWorkWhileItsPictureIsMissing() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0)
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front"])
        XCTAssertEqual(plan.decisionsByID["front"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["front"])
    }
    func testHomeNetworkLiveTargetsDoNotQueueSnapshotWork() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0),
                makeFeed(id: "side", priorityIndex: 1, lastSnapshotAge: 90)
            ],
            liveCapacity: 2,
            startupLivePolicy: .homeNetwork(liveIDs: ["front", "side"]),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front", "side"])
        XCTAssertEqual(plan.decisionsByID["front"]?.snapshotPriority, SnapshotPriority.none)
        XCTAssertEqual(plan.decisionsByID["side"]?.snapshotPriority, SnapshotPriority.none)
        XCTAssertTrue(plan.orderedSnapshotIDs.isEmpty)
    }
    func testStartupCameraStateAcceptsLateSnapshotSuccessAfterFailure() {
        var state = StartupCameraState()

        state.apply(.snapshotFailed(entersRecovery: true), isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .recovering)

        state.apply(.snapshotSucceeded, isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .trusted)
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
}

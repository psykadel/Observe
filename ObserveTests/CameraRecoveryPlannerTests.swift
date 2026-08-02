import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraRecoveryPlannerTests: ObserveTestCase {
    func testRestrictedDirectRolesUseOneBatteryCaptureLane() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "a", priorityIndex: 0, livePriorityIndex: 0, isBatteryWakeCamera: true),
                makeFeed(id: "b", priorityIndex: 1, livePriorityIndex: 1, isBatteryWakeCamera: true),
                makeFeed(id: "c", priorityIndex: 2, livePriorityIndex: 2, isBatteryWakeCamera: true)
            ],
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["a", "c"])
        XCTAssertEqual(plan.decisionsByID["a"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["b"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["c"]?.recoveryPhase, .batteryCapture)
    }

    func testRestrictedPermanentBatteryDoesNotCaptureStill() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "battery", priorityIndex: 0, isBatteryWakeCamera: true)
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }

    func testTemporaryBatteryLiveIsCurrentBeforeStillCapture() {
        let feed = makeFeed(
            id: "battery",
            priorityIndex: 0,
            isStreaming: true,
            liveStartedAt: now,
            isBatteryWakeCamera: true,
            batteryWakeLeaseStartedAt: now
        )

        XCTAssertTrue(feed.hasTrustedImage(at: now))
    }

    func testDemotedLiveBatteryCapturesStillBeforeGivingUpItsSlot() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "new-permanent", priorityIndex: 0, livePriorityIndex: 0),
                makeFeed(
                    id: "demoted-battery",
                    priorityIndex: 1,
                    livePriorityIndex: 1,
                    isStreaming: true,
                    liveStartedAt: now.addingTimeInterval(-6),
                    isBatteryWakeCamera: true
                )
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["demoted-battery"])
        XCTAssertEqual(plan.decisionsByID["demoted-battery"]?.recoveryPhase, .batteryCapture)
    }

    func testZeroCapacityRequestsNoLiveFeeds() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "back", priorityIndex: 1, lastSnapshotAge: 5, isBatteryWakeCamera: true),
                makeFeed(id: "side", priorityIndex: 2),
                makeFeed(id: "driveway", priorityIndex: 3, lastSnapshotAge: 5)
            ],
            liveCapacity: 0,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["back"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["side"]?.snapshotPriority, .urgent)
        XCTAssertEqual(plan.decisionsByID["driveway"]?.snapshotPriority, .refresh)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["side", "driveway"])
    }
    func testPermanentBatteryUsesItsLiveSlotWithoutCapturing() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "battery", priorityIndex: 1, lastSnapshotAge: 90, isBatteryWakeCamera: true)
            ],
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "wired"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }
    func testAlreadyLiveBatteryDoesNotEnterCaptureRecovery() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 0,
                    isStreaming: true,
                    liveStartedAt: now.addingTimeInterval(-6),
                    isBatteryWakeCamera: true
                )
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }
    func testActiveBatteryCaptureLeaseIsPreservedBeforeFocusAndPriority() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "highest-priority",
                    priorityIndex: 0,
                    livePriorityIndex: 0,
                    lastSnapshotAge: 5
                ),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    livePriorityIndex: 2,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(
                    id: "new-battery",
                    priorityIndex: 2,
                    livePriorityIndex: 1,
                    isBatteryWakeCamera: true
                )
            ],
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
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["new-battery"])
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["stuck-battery"]?.recoveryPhase, .batteryWaiting)
    }
    func testTrustedBatteryStillNeedsNoCaptureLane() {
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
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["next-battery"])
        XCTAssertEqual(plan.decisionsByID["next-battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["trusted-battery"]?.recoveryPhase, .idle)
    }
    func testFocusedFeedMayExplicitlyCancelActiveBatteryCaptureWhenCapacityIsFull() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "focused",
                    priorityIndex: 0,
                    livePriorityIndex: 2,
                    isFocused: true,
                    lastSnapshotAge: 5
                ),
                makeFeed(
                    id: "active-battery",
                    priorityIndex: 1,
                    livePriorityIndex: 0,
                    lastSnapshotAge: 70,
                    isBatteryWakeCamera: true,
                    batteryWakeLeaseStartedAt: now.addingTimeInterval(-1)
                ),
                makeFeed(
                    id: "new-battery",
                    priorityIndex: 2,
                    livePriorityIndex: 1,
                    isBatteryWakeCamera: true
                )
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused"])
        XCTAssertEqual(plan.decisionsByID["focused"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["active-battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["new-battery"]?.recoveryPhase, .batteryWaiting)
    }
    func testFocusedBatteryUsesPermanentLiveSlotWithoutStillCapture() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, isStreaming: true),
                makeFeed(id: "focused-battery", priorityIndex: 1, isFocused: true, isBatteryWakeCamera: true)
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["focused-battery"])
        XCTAssertEqual(plan.decisionsByID["focused-battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["healthy-live"]?.presentationMode, .snapshot)
    }
    func testBatteryCaptureUsesExactlyOneLaneAfterPermanentLiveSelection() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "healthy-live", priorityIndex: 0, livePriorityIndex: 3, isStreaming: true),
                makeFeed(id: "battery-first", priorityIndex: 1, livePriorityIndex: 2, isBatteryWakeCamera: true),
                makeFeed(
                    id: "battery-second",
                    priorityIndex: 2,
                    livePriorityIndex: 1,
                    lastSnapshotAge: 90,
                    isBatteryWakeCamera: true
                ),
                makeFeed(id: "battery-third", priorityIndex: 3, livePriorityIndex: 0, isBatteryWakeCamera: true)
            ],
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery-first", "battery-third"])
        XCTAssertEqual(plan.decisionsByID["battery-second"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["battery-third"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["battery-first"]?.recoveryPhase, .batteryCapture)
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
            liveCapacity: 2,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "focused"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
        XCTAssertEqual(plan.decisionsByID["second"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.orderedSnapshotIDs, ["second", "third"])
    }
    func testRestrictedLiveOrderSelectsCapacityPrefixWithoutChangingSnapshotOrder() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "first", priorityIndex: 0, livePriorityIndex: 1, lastSnapshotAge: 5),
                makeFeed(id: "second", priorityIndex: 1, livePriorityIndex: 2, lastSnapshotAge: 5),
                makeFeed(id: "third", priorityIndex: 2, livePriorityIndex: 0, lastSnapshotAge: 5)
            ],
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["third"])
        XCTAssertEqual(plan.orderedSnapshotIDs, ["first", "second"])
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
            liveCapacity: 1,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["next-battery"])
        XCTAssertEqual(plan.decisionsByID["backing-off-battery"]?.recoveryPhase, .batteryWaiting)
        XCTAssertEqual(plan.decisionsByID["next-battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(plan.decisionsByID["trusted-battery"]?.recoveryPhase, .idle)
    }
    func testBatteryTrustedStillCaptureRequiresWakeLease() {
        let liveStartedAt = now.addingTimeInterval(-6)

        XCTAssertFalse(
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
                liveStartedAt: liveStartedAt,
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
    func testKnownCapacityRemainsFixedWhileFeedsAreUntrusted() {
        XCTAssertEqual(
            RestrictedLiveCapacity.planningBudget(
                knownCapacity: 2,
                visibleFeedCount: 6
            ),
            2
        )
    }
}

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
            sessionMode: .constrained,
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
    func testRestrictedStartupSnapshotRecoveryBeginsAfterFirstFailure() {
        var startupState = StartupCameraState()
        startupState.apply(.snapshotRequested(at: now.addingTimeInterval(-4)), isBatteryCamera: false)
        startupState.apply(.snapshotFailed(entersRecovery: true), isBatteryCamera: false)

        XCTAssertEqual(startupState.resolution, .recovering)
        XCTAssertEqual(
            StartupSnapshotRecoveryPolicy.retryEligibleDate(
                startupCoverageActive: true,
                startupState: startupState,
                snapshotFailedAt: now,
                lastRequestIssuedAt: now.addingTimeInterval(-4),
                priority: .urgent
            ),
            now.addingTimeInterval(2)
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
    func testRestrictedStartupAttemptsThreeWiredSnapshotsThenFourthWithoutDuplicates() {
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
                activeLimit: 3,
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
                    activeLimit: 3,
                    outstandingLimit: 4
                )
            }
        }

        issueAvailable(at: now)
        XCTAssertEqual(attemptedIDs, ["front", "garage", "deck"])

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
            activeLimit: 3,
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
    func testLivePromotionSuppressesOnlyRoutineSnapshotRefresh() {
        XCTAssertFalse(
            LivePromotionSnapshotPolicy.shouldQueue(
                priority: .refresh,
                presentationMode: .live,
                wifiBurstOpen: false
            )
        )
        XCTAssertTrue(
            LivePromotionSnapshotPolicy.shouldQueue(
                priority: .urgent,
                presentationMode: .live,
                wifiBurstOpen: false
            )
        )
        XCTAssertTrue(
            LivePromotionSnapshotPolicy.shouldQueue(
                priority: .refresh,
                presentationMode: .live,
                wifiBurstOpen: true
            )
        )
        XCTAssertTrue(
            LivePromotionSnapshotPolicy.shouldQueue(
                priority: .refresh,
                presentationMode: .snapshot,
                wifiBurstOpen: false
            )
        )
    }
    func testRestrictedStartupRunsOneBatteryCaptureAlongsideWiredSnapshots() {
        let feeds = [
            makeFeed(id: "front", priorityIndex: 0),
            makeFeed(id: "garage", priorityIndex: 1),
            makeFeed(id: "battery", priorityIndex: 2, isBatteryWakeCamera: true)
        ]

        let snapshotFirstPlan = planner.makePlan(
            feeds: feeds,
            sessionMode: .optimistic,
            liveCapacity: 3,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )
        XCTAssertEqual(liveIDs(in: snapshotFirstPlan), ["battery"])
        XCTAssertEqual(snapshotFirstPlan.decisionsByID["battery"]?.recoveryPhase, .batteryCapture)
        XCTAssertEqual(snapshotFirstPlan.orderedSnapshotIDs, ["front", "garage"])
    }
    func testRestrictedStartupNeverStartsWiredLiveWithoutBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "first", priorityIndex: 0),
                makeFeed(id: "second", priorityIndex: 1)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["first"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["second"]?.presentationMode, .snapshot)
    }
    func testWiFiLiveBurstOpensAllLiveAndReleasesSnapshotsAfterHeadStart() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two", "three"],
            startedAt: now,
            snapshotHeadStart: 0.2,
            deadline: 2
        )

        XCTAssertEqual(burst.mode, .headStart)
        XCTAssertEqual(burst.liveIDs, ["one", "two", "three"])
        XCTAssertFalse(burst.allowsSnapshotIssue(at: now.addingTimeInterval(0.199)))

        burst.evaluate(streamingIDs: [], at: now.addingTimeInterval(0.2))

        XCTAssertEqual(burst.mode, .active)
        XCTAssertTrue(burst.allowsSnapshotIssue(at: now.addingTimeInterval(0.2)))
        XCTAssertEqual(burst.liveIDs, ["one", "two", "three"])
    }
    func testWiFiLiveBurstDefaultSnapshotHeadStartIsOneSecond() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        XCTAssertFalse(burst.allowsSnapshotIssue(at: now.addingTimeInterval(0.999)))
        burst.evaluate(streamingIDs: [], at: now.addingTimeInterval(1))
        XCTAssertEqual(burst.mode, .active)
        XCTAssertTrue(burst.allowsSnapshotIssue(at: now.addingTimeInterval(1)))
    }
    func testStartupCameraStateAcceptsLateSnapshotSuccessAfterFailure() {
        var state = StartupCameraState()

        state.apply(.snapshotFailed(entersRecovery: true), isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)
        XCTAssertEqual(state.resolution, .recovering)

        state.apply(.snapshotSucceeded, isBatteryCamera: false)

        XCTAssertEqual(state.resolution, .trusted)
    }
    func testRestrictedStartupKeepsAttemptedWiredCamerasSnapshotOnly() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "front", priorityIndex: 0, startupSnapshotAttempted: true),
                makeFeed(id: "garage", priorityIndex: 1, startupSnapshotAttempted: true)
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["front"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["garage"]?.presentationMode, .snapshot)
    }
    func testRestrictedStartupDoesNotPreserveAnEarlierWiredStart() {
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
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["front"]?.presentationMode, .snapshot)
    }
    func testRestrictedStartupKeepsRecoveringBatteryCaptureEligible() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "failed-wired",
                    priorityIndex: 0,
                    startupSnapshotAttempted: true,
                    startupCoverageResolution: .recovering
                ),
                makeFeed(
                    id: "failed-battery",
                    priorityIndex: 1,
                    isBatteryWakeCamera: true,
                    startupCoverageResolution: .recovering
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["failed-battery"])
    }
    func testRestrictedStartupKeepsPendingAndRecoveringWiredCamerasSnapshotOnly() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "back",
                    priorityIndex: 0,
                    startupSnapshotAttempted: true,
                    startupCoverageResolution: .recovering
                ),
                makeFeed(
                    id: "mailbox",
                    priorityIndex: 1,
                    startupSnapshotAttempted: true,
                    startupCoverageResolution: .pending
                )
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), [])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .snapshot)
        XCTAssertEqual(plan.decisionsByID["mailbox"]?.presentationMode, .snapshot)
    }
    func testRestrictedStartupFocusedWiredCameraRemainsSnapshotOnly() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "focused", priorityIndex: 0, isFocused: true),
                makeFeed(id: "battery", priorityIndex: 1, isBatteryWakeCamera: true)
            ],
            sessionMode: .constrained,
            liveCapacity: 1,
            startupLivePolicy: .restrictedSnapshotOnly,
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery"])
        XCTAssertEqual(plan.decisionsByID["focused"]?.presentationMode, .snapshot)
    }
    func testStartupSnapshotConcurrencyPolicyCapsFirstFrameRequests() {
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                usesRestrictedSnapshotOnlyStrategy: true,
                nonBatteryTrustedCount: 0,
                nonBatteryCount: 5
            ),
            3
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                usesRestrictedSnapshotOnlyStrategy: false,
                nonBatteryTrustedCount: 0,
                nonBatteryCount: 5
            ),
            2
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                usesRestrictedSnapshotOnlyStrategy: false,
                nonBatteryTrustedCount: 1,
                nonBatteryCount: 5
            ),
            3
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: true,
                usesRestrictedSnapshotOnlyStrategy: false,
                nonBatteryTrustedCount: 5,
                nonBatteryCount: 5
            ),
            3
        )
        XCTAssertEqual(
            StartupSnapshotConcurrencyPolicy.effectiveLimit(
                isFirstFramePhaseActive: false,
                usesRestrictedSnapshotOnlyStrategy: true,
                nonBatteryTrustedCount: 0,
                nonBatteryCount: 5
            ),
            3
        )
    }
    func testSnapshotRequestTimeoutDefaultsToFourSeconds() {
        XCTAssertEqual(CameraSchedulingDefaults.snapshotRequestTimeout, 4)
        XCTAssertEqual(CameraSchedulingDefaults.startupMaxOutstandingSnapshotRequests, 4)
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

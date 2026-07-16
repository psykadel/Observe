import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraStartupTests: ObserveTestCase {
    func testCellularStallAdmitsOneWiredRescueOnlyAfterTimeout() {
        let beforeTimeout = StalledStartupRescuePolicy.rescueCandidateID(
            networkClass: .cellular,
            startupCoverageActive: true,
            rescueAlreadyAttempted: false,
            sessionElapsed: 3.99,
            stallThreshold: 4,
            hasAnyTrustedImage: false,
            hasPendingBatteryProbe: true,
            eligibleWiredIDs: ["front", "back"]
        )
        let atTimeout = StalledStartupRescuePolicy.rescueCandidateID(
            networkClass: .cellular,
            startupCoverageActive: true,
            rescueAlreadyAttempted: false,
            sessionElapsed: 4,
            stallThreshold: 4,
            hasAnyTrustedImage: false,
            hasPendingBatteryProbe: true,
            eligibleWiredIDs: ["front", "back"]
        )

        XCTAssertNil(beforeTimeout)
        XCTAssertEqual(atTimeout, "front")
    }
    func testCellularStallRescueRequiresPendingBatteryAndNoTrustedImage() {
        XCTAssertNil(
            StalledStartupRescuePolicy.rescueCandidateID(
                networkClass: .wifi,
                startupCoverageActive: true,
                rescueAlreadyAttempted: false,
                sessionElapsed: 5,
                stallThreshold: 4,
                hasAnyTrustedImage: false,
                hasPendingBatteryProbe: true,
                eligibleWiredIDs: ["front"]
            )
        )
        XCTAssertNil(
            StalledStartupRescuePolicy.rescueCandidateID(
                networkClass: .cellular,
                startupCoverageActive: true,
                rescueAlreadyAttempted: false,
                sessionElapsed: 5,
                stallThreshold: 4,
                hasAnyTrustedImage: true,
                hasPendingBatteryProbe: true,
                eligibleWiredIDs: ["front"]
            )
        )
        XCTAssertNil(
            StalledStartupRescuePolicy.rescueCandidateID(
                networkClass: .cellular,
                startupCoverageActive: true,
                rescueAlreadyAttempted: false,
                sessionElapsed: 5,
                stallThreshold: 4,
                hasAnyTrustedImage: false,
                hasPendingBatteryProbe: false,
                eligibleWiredIDs: ["front"]
            )
        )
        XCTAssertNil(
            StalledStartupRescuePolicy.rescueCandidateID(
                networkClass: .cellular,
                startupCoverageActive: true,
                rescueAlreadyAttempted: true,
                sessionElapsed: 5,
                stallThreshold: 4,
                hasAnyTrustedImage: false,
                hasPendingBatteryProbe: true,
                eligibleWiredIDs: ["front"]
            )
        )
    }
    func testStalledRescueContractAdmitsWiredStartAlongsidePendingBattery() {
        let policy = StartupLivePolicy.capacityRamp(
            liveIDs: ["battery", "front"],
            maxPendingStarts: 2
        )
        var controller = LiveAdmissionController(
            mode: .adaptive(maxPendingStarts: policy.pendingStartLimit),
            sustainableCapacity: 5
        )

        XCTAssertEqual(policy.pendingStartLimit, 2)

        let decision = controller.reconcile(
            intents: [
                LiveIntent(id: "battery", role: .batteryCapture, priorityIndex: 1),
                LiveIntent(id: "front", role: .firstImageRecovery, priorityIndex: 0)
            ],
            transports: ["battery": .starting, "front": .idle],
            preserveActiveDuringCoverage: false,
            now: now
        )

        XCTAssertEqual(decision.targetIDs, ["battery", "front"])
        XCTAssertEqual(decision.startIDs, ["front"])
        XCTAssertTrue(decision.queuedStartIDs.isEmpty)
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
    func testWiFiLiveBurstCompletesWhenEveryVisibleFeedIsLive() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        burst.evaluate(streamingIDs: ["one", "two"], at: now.addingTimeInterval(0.5))

        XCTAssertEqual(burst.mode, .completed)
        XCTAssertEqual(burst.liveIDs, ["one", "two"])
        XCTAssertTrue(burst.allowsSnapshotIssue(at: now.addingTimeInterval(0.5)))
    }
    func testWiFiLiveBurstClosesAfterCompletionWhenWiFiPathIsLost() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        burst.evaluate(streamingIDs: ["one", "two"], at: now.addingTimeInterval(0.5))
        burst.invalidatePath(streamingIDs: ["one"])

        XCTAssertEqual(burst.mode, .closed(.pathInvalidated))
        XCTAssertEqual(burst.survivingLiveIDs, ["one"])
        XCTAssertTrue(burst.liveIDs.isEmpty)
    }
    func testWiFiLiveBurstDeadlineClosesAndCannotReopen() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two", "three"],
            startedAt: now,
            deadline: 2
        )

        burst.evaluate(streamingIDs: ["one"], at: now.addingTimeInterval(2))
        XCTAssertEqual(burst.mode, .closed(.deadline))
        XCTAssertEqual(burst.survivingLiveIDs, ["one"])
        XCTAssertTrue(burst.liveIDs.isEmpty)

        burst.evaluate(streamingIDs: ["one", "two", "three"], at: now.addingTimeInterval(2.5))
        XCTAssertEqual(burst.mode, .closed(.deadline))
        XCTAssertTrue(burst.liveIDs.isEmpty)
    }
    func testWiFiLiveBurstDefaultWiredDeadlineIsFourSeconds() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        burst.evaluate(streamingIDs: ["one"], at: now.addingTimeInterval(2))
        XCTAssertEqual(burst.mode, .active)
        XCTAssertEqual(burst.liveIDs, ["one", "two"])

        burst.evaluate(streamingIDs: ["one"], at: now.addingTimeInterval(4))
        XCTAssertEqual(burst.mode, .closed(.deadline))
        XCTAssertEqual(burst.survivingLiveIDs, ["one"])
    }
    func testWiFiLiveBurstWaitsForBatteryAfterEveryWiredFeedIsLive() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["wired", "battery"],
            batteryFeedIDs: ["battery"],
            startedAt: now,
            deadline: 2,
            batteryDeadline: 30
        )

        burst.evaluate(streamingIDs: ["wired"], at: now.addingTimeInterval(2))

        XCTAssertEqual(burst.mode, .batteryGrace)
        XCTAssertEqual(burst.liveIDs, ["wired", "battery"])

        burst.evaluate(streamingIDs: ["wired", "battery"], at: now.addingTimeInterval(8))
        XCTAssertEqual(burst.mode, .completed)
    }
    func testWiFiLiveBurstStillFallsBackAtTwoSecondsWhenWiredFeedIsPending() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["wired-one", "wired-two", "battery"],
            batteryFeedIDs: ["battery"],
            startedAt: now,
            deadline: 2,
            batteryDeadline: 30
        )

        burst.evaluate(streamingIDs: ["wired-one"], at: now.addingTimeInterval(2))

        XCTAssertEqual(burst.mode, .closed(.deadline))
        XCTAssertEqual(burst.survivingLiveIDs, ["wired-one"])
    }
    func testWiFiLiveBurstBatteryGraceRemainsBounded() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["wired", "battery"],
            batteryFeedIDs: ["battery"],
            startedAt: now,
            deadline: 2,
            batteryDeadline: 30
        )

        burst.evaluate(streamingIDs: ["wired"], at: now.addingTimeInterval(2))
        burst.evaluate(streamingIDs: ["wired"], at: now.addingTimeInterval(30))

        XCTAssertEqual(burst.mode, .closed(.batteryDeadline))
        XCTAssertEqual(burst.survivingLiveIDs, ["wired"])
    }
    func testWiFiLiveBurstGivesBatteryOnlyWallTheSameGrace() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["battery"],
            batteryFeedIDs: ["battery"],
            startedAt: now,
            deadline: 2,
            batteryDeadline: 30
        )

        burst.evaluate(streamingIDs: [], at: now.addingTimeInterval(2))

        XCTAssertEqual(burst.mode, .batteryGrace)
        XCTAssertEqual(burst.liveIDs, ["battery"])
    }
    func testWiFiLiveBurstCapacitySignalClosesImmediately() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two", "three"],
            startedAt: now
        )

        burst.recordCapacityRejection(streamingIDs: ["one"])

        XCTAssertEqual(burst.mode, .closed(.capacity))
        XCTAssertEqual(burst.survivingLiveIDs, ["one"])
        XCTAssertTrue(burst.liveIDs.isEmpty)
        XCTAssertTrue(burst.allowsSnapshotIssue(at: now.addingTimeInterval(0.3)))
    }
    func testWiFiLiveBurstOrdinaryFailureAlsoClosesWithoutRetry() {
        var burst = WiFiLiveBurstState(
            networkClass: .wifi,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        burst.recordFailure(streamingIDs: ["one"])

        XCTAssertEqual(burst.mode, .closed(.failure))
        XCTAssertEqual(burst.survivingLiveIDs, ["one"])
        XCTAssertTrue(burst.liveIDs.isEmpty)
    }
    func testWiFiLiveBurstStaysInactiveForCellularAndUnknownPaths() {
        let cellular = WiFiLiveBurstState(
            networkClass: .cellular,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )
        let unknown = WiFiLiveBurstState(
            networkClass: .unknown,
            visibleFeedIDs: ["one", "two"],
            startedAt: now
        )

        XCTAssertEqual(cellular.mode, .inactive)
        XCTAssertEqual(unknown.mode, .inactive)
        XCTAssertTrue(cellular.liveIDs.isEmpty)
        XCTAssertTrue(unknown.allowsSnapshotIssue(at: now))
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

        XCTAssertEqual(state.resolution, .recovering)
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
    func testWiFiBurstPlainLiveResolvesBatteryStartupWithoutCapturedStill() {
        var state = StartupCameraState()

        state.apply(.liveRequested(at: now), isBatteryCamera: true)
        state.apply(.plainLiveStarted, isBatteryCamera: true)

        XCTAssertEqual(state.livePath, .succeeded)
        XCTAssertEqual(state.resolution, .trusted)
    }
    func testStartupCameraStateAllowsLiveRetryAfterBothPathsFail() {
        var state = StartupCameraState()
        state.apply(.snapshotFailed, isBatteryCamera: false)
        state.apply(.liveFailed, isBatteryCamera: false)

        let retryAt = now.addingTimeInterval(2)
        state.apply(.liveRequested(at: retryAt), isBatteryCamera: false)

        XCTAssertEqual(state.livePath, .inFlight(startedAt: retryAt))
        XCTAssertEqual(state.liveFallbackStartedAt, retryAt)

        state.apply(.liveStarted, isBatteryCamera: false)
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
        XCTAssertEqual(state.resolution, .recovering)

        state.apply(.reset, isBatteryCamera: false)

        XCTAssertEqual(state, StartupCameraState())
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
            startupLivePolicy: .capacityRamp(
                liveIDs: ["front", "garage"],
                maxPendingStarts: 1
            ),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["front", "garage"])
        XCTAssertEqual(plan.decisionsByID["back"]?.presentationMode, .snapshot)
    }
    func testWiFiLiveBurstUsesPlainLiveForDueBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(id: "wired", priorityIndex: 0),
                makeFeed(
                    id: "battery",
                    priorityIndex: 1,
                    lastSnapshotAge: 90,
                    isBatteryWakeCamera: true
                )
            ],
            sessionMode: .optimistic,
            liveCapacity: 2,
            startupLivePolicy: .liveBurst(liveIDs: ["wired", "battery"]),
            now: now
        )

        XCTAssertEqual(liveIDs(in: plan), ["battery", "wired"])
        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .idle)
    }
    func testNormalCapacityRampStillCapturesDueBatteryCamera() {
        let plan = planner.makePlan(
            feeds: [
                makeFeed(
                    id: "battery",
                    priorityIndex: 0,
                    lastSnapshotAge: 90,
                    isBatteryWakeCamera: true
                )
            ],
            sessionMode: .optimistic,
            liveCapacity: 1,
            startupLivePolicy: .capacityRamp(
                liveIDs: ["battery"],
                maxPendingStarts: 1
            ),
            now: now
        )

        XCTAssertEqual(plan.decisionsByID["battery"]?.presentationMode, .live)
        XCTAssertEqual(plan.decisionsByID["battery"]?.recoveryPhase, .batteryCapture)
    }
    func testStartupLiveTimeoutPolicySeparatesWiredAndBatteryWork() {
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: true,
                isBatteryCamera: false
            ),
            8
        )
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: true,
                isBatteryCamera: true
            ),
            30
        )
        XCTAssertEqual(
            LiveStartTimeoutPolicy.timeout(
                startupCoverageActive: false,
                isBatteryCamera: false
            ),
            30
        )
    }
}

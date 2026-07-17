import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraTelemetryTests: ObserveTestCase {
    func testMetadataMilestonesMeasureQueueConcurrencyFailuresAndLatency() {
        var milestones = CameraStartupMetadataTelemetryMilestones()

        milestones.recordQueued(count: 4, at: 0)
        milestones.recordIssued(activeCount: 1, at: 0.1)
        milestones.recordCompleted(failed: false, callbackLatency: 0.8, at: 0.9)
        milestones.recordIssued(activeCount: 1, at: 1)
        milestones.recordCompleted(failed: true, callbackLatency: 1.4, at: 2.4)

        XCTAssertEqual(milestones.queuedCount, 4)
        XCTAssertEqual(milestones.issuedCount, 2)
        XCTAssertEqual(milestones.completedCount, 2)
        XCTAssertEqual(milestones.failureCount, 1)
        XCTAssertEqual(milestones.peakActiveOperations, 1)
        XCTAssertEqual(milestones.firstQueuedAt, 0)
        XCTAssertEqual(milestones.firstIssuedAt, 0.1)
        XCTAssertEqual(milestones.firstCompletedAt, 0.9)
        XCTAssertEqual(milestones.lastCompletedAt, 2.4)
        XCTAssertEqual(milestones.maxCallbackLatency, 1.4)
    }
    func testBatteryLiveTelemetryIsFreshBeforeTrustedStillCapture() {
        var milestones = CameraStartupTelemetryFeedMilestones(feedID: "battery")

        milestones.recordLiveStarted(
            callbackLatency: 1.2,
            resolvesTrustedImage: false,
            at: 4
        )

        XCTAssertEqual(milestones.firstFreshImageAt, 4)
        XCTAssertNil(milestones.firstTrustedImageAt)
        XCTAssertNil(milestones.firstTrustedImageSource)

        milestones.recordBatteryTrustedStill(at: 7)

        XCTAssertEqual(milestones.firstTrustedImageAt, 7)
        XCTAssertEqual(milestones.firstTrustedImageSource, "batteryStill")
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
    @MainActor
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
            liveAdmissionMode: "constrained",
            liveAdmissionSustainableCapacity: 1,
            liveAdmissionSoftContentionCeiling: 1,
            liveAdmissionPlannerCapacity: 2,
            liveAdmissionEffectiveCapacity: 2,
            liveAdmissionCapacityLimitReason: "softContentionProbe",
            liveAdmissionActiveCapacityProbeFeedID: "side",
            liveAdmissionTargetIDs: ["front"],
            liveAdmissionReservedIDs: ["front"],
            liveAdmissionQueuedIDs: ["side"],
            visibleFeedCount: 2,
            internalMaxConcurrentSnapshotRequests: 3,
            effectiveMaxConcurrentSnapshotRequests: 2,
            snapshotRequestTimeout: 2.75,
            untrustedSnapshotRefreshInterval: 2,
            trustedSnapshotRefreshInterval: 5,
            batteryCaptureWarmup: 5,
            batteryWakeTriggerThreshold: 30,
            batteryWakeLeaseDuration: 8,
            batteryWakeLiveStartTimeout: 30,
            wiredStartupLiveStartTimeout: 8,
            startupCoverageActive: true,
            restrictedStartupPhase: "snapshotRecovery",
            ordinaryLiveGateState: "waitingForAllTrusted",
            sessionNetworkClass: "cellular",
            currentNetworkClass: "cellular",
            wifiLiveBurstMode: "closed:capacity",
            wifiLiveBurstSurvivorIDs: ["front"],
            startupLiveRampMode: "fast",
            startupLiveRampSelectedIDs: ["front", "side"],
            startupLiveRampPendingIDs: ["side"],
            startupLiveRampMaxPendingCount: 2,
            startupLiveRampFastThreshold: 3,
            activeSnapshotRequests: 2,
            outstandingSnapshotRequests: 3,
            startupMetadataMode: "mediaPrioritySerial",
            startupMetadataGateState: "open",
            activeMetadataOperations: 1,
            queuedMetadataOperations: 3,
            activeMetadataOperation: "front:availabilityRead",
            liveCapacityExpansionRetryIn: 5,
            liveCapacityExpansionCooldownEligible: false,
            liveCapacityIncludesUnconfirmedMemory: false,
            startupMilestones: CameraStartupTelemetryMilestones(
                enteredConstrainedModeAt: 1,
                enteredConstrainedModeLiveCapacity: 1,
                firstConstrainedSignalAt: 1,
                firstConstrainedSignalFeedID: "front",
                allVisibleFeedsTrustedAt: 12,
                allVisibleFeedsLiveAt: 8,
                startupCoverageEndedAt: 15,
                startupCoverageResult: "completedWithRecovery",
                recoveringFeedIDs: ["side"],
                peakActiveSnapshotRequests: 3,
                peakOutstandingSnapshotRequests: 4,
                metadata: CameraStartupMetadataTelemetryMilestones(
                    queuedCount: 8,
                    issuedCount: 5,
                    completedCount: 4,
                    failureCount: 1,
                    peakActiveOperations: 1,
                    firstQueuedAt: 0,
                    firstIssuedAt: 0.02,
                    firstCompletedAt: 0.6,
                    lastCompletedAt: 4.2,
                    maxCallbackLatency: 1.4
                ),
                feedsByID: [
                    "front": CameraStartupTelemetryFeedMilestones(
                        feedID: "front",
                        firstTrustedImageAt: 12,
                        firstTrustedImageSource: "live",
                        firstFreshImageAt: 2,
                        firstSnapshotQueuedAt: 1,
                        firstSnapshotIssuedAt: 2,
                        firstSnapshotSuccessAt: 3,
                        lastSnapshotSuccessAt: 10,
                        snapshotQueuedCount: 5,
                        snapshotIssuedCount: 3,
                        snapshotSuccessCount: 2,
                        snapshotFailureCount: 1,
                        snapshotInitialFailureCount: 1,
                        snapshotRecoveryFailureCount: 0,
                        snapshotRoutineFailureCount: 0,
                        snapshotTimeoutCount: 1,
                        lastSnapshotCallbackLatency: 2.5,
                        lastLiveStartCallbackLatency: 0.9,
                        lastLiveStopCallbackLatency: 0.012,
                        startupEnteredRecovery: false,
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
                    liveTransportPhase: "stopping",
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
                    batteryStillAge: nil,
                    nextBatteryCaptureDueIn: 25,
                    batteryWakeLeaseAge: nil,
                    batteryWakeRetryIn: nil,
                    consecutiveBatteryWakeFailures: 0,
                    liveStartedAge: nil,
                    liveStartRequestedAge: nil,
                    liveStopRequestedAge: 0.5,
                    liveStopReason: "startupTimeout",
                    lastErrorMessage: nil
                )
            ],
            events: [
                CameraTelemetryEvent(sequence: 1, elapsed: 0, message: "session start"),
                CameraTelemetryEvent(sequence: 2, elapsed: 2, message: "snapshot issued front priority=urgent")
            ]
        )

        let text = report.text
        XCTAssertTrue(text.contains("Observe Telemetry"))
        XCTAssertTrue(text.contains("sessionElapsed=20.0s"))
        XCTAssertTrue(text.contains("internalMaxConcurrentSnapshotRequests=3"))
        XCTAssertTrue(text.contains("effectiveMaxConcurrentSnapshotRequests=2"))
        XCTAssertTrue(text.contains("liveAdmissionSoftContentionCeiling=1"))
        XCTAssertTrue(text.contains("liveAdmissionPlannerCapacity=2"))
        XCTAssertTrue(text.contains("liveAdmissionEffectiveCapacity=2"))
        XCTAssertTrue(text.contains("liveAdmissionCapacityLimitReason=softContentionProbe"))
        XCTAssertTrue(text.contains("liveAdmissionActiveCapacityProbeFeedID=side"))
        XCTAssertTrue(text.contains("startupLiveRampMode=fast"))
        XCTAssertTrue(text.contains("restrictedStartupPhase=snapshotRecovery"))
        XCTAssertTrue(text.contains("ordinaryLiveGateState=waitingForAllTrusted"))
        XCTAssertTrue(text.contains("startupMetadataMode=mediaPrioritySerial"))
        XCTAssertTrue(text.contains("startupMetadataGateState=open"))
        XCTAssertTrue(text.contains("activeMetadataOperations=1"))
        XCTAssertTrue(text.contains("queuedMetadataOperations=3"))
        XCTAssertTrue(text.contains("activeMetadataOperation=front:availabilityRead"))
        XCTAssertTrue(text.contains("sessionNetworkClass=cellular"))
        XCTAssertTrue(text.contains("currentNetworkClass=cellular"))
        XCTAssertTrue(text.contains("wifiLiveBurstMode=closed:capacity"))
        XCTAssertTrue(text.contains("wifiLiveBurstSurvivorIDs=front"))
        XCTAssertTrue(text.contains("startupLiveRampSelectedIDs=front,side"))
        XCTAssertTrue(text.contains("startupLiveRampPendingIDs=side"))
        XCTAssertTrue(text.contains("startupLiveRampMaxPendingCount=2"))
        XCTAssertTrue(text.contains("startupLiveRampFastThreshold=3.0s"))
        XCTAssertTrue(text.contains("outstandingSnapshotRequests=3"))
        XCTAssertTrue(text.contains("untrustedSnapshotRefreshInterval=2.0s"))
        XCTAssertTrue(text.contains("batteryWakeTriggerThreshold=30.0s"))
        XCTAssertTrue(text.contains("wiredStartupLiveStartTimeout=8.0s"))
        XCTAssertTrue(text.contains("nextBatteryCaptureDueIn=25.0s"))
        XCTAssertTrue(text.contains("liveCapacityExpansionRetryIn=5.0s"))
        XCTAssertTrue(text.contains("liveCapacityExpansionCooldownEligible=false"))
        XCTAssertTrue(text.contains("allVisibleFeedsTrustedAt=12.0s"))
        XCTAssertTrue(text.contains("allVisibleFeedsLiveAt=8.0s"))
        XCTAssertTrue(text.contains("startupCoverageResult=completedWithRecovery"))
        XCTAssertTrue(text.contains("peakOutstandingSnapshotRequests=4"))
        XCTAssertTrue(text.contains("metadataQueuedCount=8"))
        XCTAssertTrue(text.contains("metadataIssuedCount=5"))
        XCTAssertTrue(text.contains("metadataCompletedCount=4"))
        XCTAssertTrue(text.contains("metadataFailureCount=1"))
        XCTAssertTrue(text.contains("peakActiveMetadataOperations=1"))
        XCTAssertTrue(text.contains("firstMetadataIssuedAt=0.0s"))
        XCTAssertTrue(text.contains("lastMetadataCompletedAt=4.2s"))
        XCTAssertTrue(text.contains("maxMetadataCallbackLatency=1.4s"))
        XCTAssertTrue(text.contains("front | firstTrustedImageAt=12.0s"))
        XCTAssertTrue(text.contains("firstTrustedImageSource=live"))
        XCTAssertTrue(text.contains("firstFreshImageAt=2.0s"))
        XCTAssertTrue(text.contains("lastLiveStartCallbackLatency=0.9s"))
        XCTAssertTrue(text.contains("lastLiveStopCallbackLatency=0.0s"))
        XCTAssertTrue(text.contains("snapshotInitialFailureCount=1"))
        XCTAssertTrue(text.contains("snapshotTimeoutCount=1"))
        XCTAssertTrue(text.contains("front | Front | room=Porch"))
        XCTAssertTrue(text.contains("snapshotInFlightAge=1.0s"))
        XCTAssertTrue(text.contains("snapshotWorkState=active"))
        XCTAssertTrue(text.contains("startupSnapshotPath=inFlight"))
        XCTAssertTrue(text.contains("startupLivePath=notAttempted"))
        XCTAssertTrue(text.contains("liveTransportPhase=stopping"))
        XCTAssertTrue(text.contains("liveStopRequestedAge=0.5s"))
        XCTAssertTrue(text.contains("liveStopReason=startupTimeout"))
        XCTAssertTrue(text.contains("#2 +2.000s snapshot issued front priority=urgent"))
        XCTAssertEqual(stableFingerprint(text), 5_555_762_793_498_386_261)
    }

    private func stableFingerprint(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

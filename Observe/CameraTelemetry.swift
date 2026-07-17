import Foundation

struct CameraTelemetryEvent: Equatable {
    let sequence: Int
    let elapsed: TimeInterval
    let message: String
}

struct CameraStartupTelemetryMilestones: Equatable {
    var enteredConstrainedModeAt: TimeInterval?
    var enteredConstrainedModeLiveCapacity: Int?
    var firstConstrainedSignalAt: TimeInterval?
    var firstConstrainedSignalFeedID: String?
    var allVisibleFeedsTrustedAt: TimeInterval?
    var allVisibleFeedsLiveAt: TimeInterval?
    var startupCoverageEndedAt: TimeInterval?
    var startupCoverageResult: String?
    var recoveringFeedIDs: [String] = []
    var peakActiveSnapshotRequests = 0
    var peakOutstandingSnapshotRequests = 0
    var feedsByID: [String: CameraStartupTelemetryFeedMilestones] = [:]

    mutating func recordEnteredConstrainedMode(liveCapacity: Int, at elapsed: TimeInterval) {
        guard enteredConstrainedModeAt == nil else { return }

        enteredConstrainedModeAt = elapsed
        enteredConstrainedModeLiveCapacity = liveCapacity
    }

    mutating func recordConstrainedSignal(feedID: String, at elapsed: TimeInterval) {
        guard firstConstrainedSignalAt == nil else { return }

        firstConstrainedSignalAt = elapsed
        firstConstrainedSignalFeedID = feedID
    }

    mutating func recordAllVisibleFeedsTrusted(at elapsed: TimeInterval) {
        if allVisibleFeedsTrustedAt == nil {
            allVisibleFeedsTrustedAt = elapsed
        }
    }

    mutating func recordAllVisibleFeedsLive(at elapsed: TimeInterval) {
        if allVisibleFeedsLiveAt == nil {
            allVisibleFeedsLiveAt = elapsed
        }
    }

    mutating func recordTrustedImage(feedID: String, source: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordTrustedImage(source: source, at: elapsed) }
    }

    mutating func recordSnapshotQueued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotQueued(at: elapsed) }
    }

    mutating func recordSnapshotIssued(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotIssued(at: elapsed) }
    }

    mutating func recordSnapshotSuccess(
        feedID: String,
        callbackLatency: TimeInterval?,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) { $0.recordSnapshotSuccess(callbackLatency: callbackLatency, at: elapsed) }
    }

    mutating func recordSnapshotFailure(
        feedID: String,
        callbackLatency: TimeInterval?,
        phase: String,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) {
            $0.recordSnapshotFailure(callbackLatency: callbackLatency, phase: phase)
        }
    }

    mutating func recordLiveStarted(
        feedID: String,
        callbackLatency: TimeInterval?,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        updateFeed(feedID) {
            $0.recordLiveStarted(
                callbackLatency: callbackLatency,
                resolvesTrustedImage: resolvesTrustedImage,
                at: elapsed
            )
        }
    }

    mutating func recordLiveStopped(feedID: String, callbackLatency: TimeInterval?) {
        updateFeed(feedID) { $0.lastLiveStopCallbackLatency = callbackLatency }
    }

    mutating func recordSnapshotTimeout(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordSnapshotTimeout() }
    }

    mutating func recordBatteryWakeLeaseStarted(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeLeaseStarted(at: elapsed) }
    }

    mutating func recordBatteryTrustedStill(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryTrustedStill(at: elapsed) }
    }

    mutating func recordBatteryWakeFailure(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeFailure() }
    }

    mutating func recordBatteryWakeTimeout(feedID: String, at elapsed: TimeInterval) {
        updateFeed(feedID) { $0.recordBatteryWakeTimeout() }
    }

    mutating func recordSnapshotConcurrency(active: Int, outstanding: Int) {
        peakActiveSnapshotRequests = max(peakActiveSnapshotRequests, active)
        peakOutstandingSnapshotRequests = max(peakOutstandingSnapshotRequests, outstanding)
    }

    mutating func recordStartupRecovering(feedID: String) {
        updateFeed(feedID) { $0.startupEnteredRecovery = true }
    }

    mutating func recordStartupCoverageEnded(recoveringFeedIDs: [String], at elapsed: TimeInterval) {
        guard startupCoverageEndedAt == nil else { return }
        startupCoverageEndedAt = elapsed
        self.recoveringFeedIDs = recoveringFeedIDs.sorted()
        startupCoverageResult = recoveringFeedIDs.isEmpty ? "allTrusted" : "completedWithRecovery"
    }

    private mutating func updateFeed(
        _ feedID: String,
        _ update: (inout CameraStartupTelemetryFeedMilestones) -> Void
    ) {
        var milestones = feedsByID[feedID] ?? CameraStartupTelemetryFeedMilestones(feedID: feedID)
        update(&milestones)
        feedsByID[feedID] = milestones
    }
}

struct CameraStartupTelemetryFeedMilestones: Equatable {
    let feedID: String
    var firstTrustedImageAt: TimeInterval?
    var firstTrustedImageSource: String?
    var firstFreshImageAt: TimeInterval?
    var firstSnapshotQueuedAt: TimeInterval?
    var firstSnapshotIssuedAt: TimeInterval?
    var firstSnapshotSuccessAt: TimeInterval?
    var lastSnapshotSuccessAt: TimeInterval?
    var snapshotQueuedCount = 0
    var snapshotIssuedCount = 0
    var snapshotSuccessCount = 0
    var snapshotFailureCount = 0
    var snapshotInitialFailureCount = 0
    var snapshotRecoveryFailureCount = 0
    var snapshotRoutineFailureCount = 0
    var snapshotTimeoutCount = 0
    var lastSnapshotCallbackLatency: TimeInterval?
    var lastLiveStartCallbackLatency: TimeInterval?
    var lastLiveStopCallbackLatency: TimeInterval?
    var startupEnteredRecovery = false
    var firstBatteryWakeLeaseStartedAt: TimeInterval?
    var firstBatteryTrustedStillAt: TimeInterval?
    var batteryWakeLeaseStartedCount = 0
    var batteryTrustedStillCount = 0
    var batteryWakeFailureCount = 0
    var batteryWakeTimeoutCount = 0

    mutating func recordTrustedImage(source: String, at elapsed: TimeInterval) {
        if firstTrustedImageAt == nil {
            firstTrustedImageAt = elapsed
            firstTrustedImageSource = source
        }
    }

    mutating func recordFreshImage(
        source: String,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        if firstFreshImageAt == nil {
            firstFreshImageAt = elapsed
        }
        if resolvesTrustedImage {
            recordTrustedImage(source: source, at: elapsed)
        }
    }

    mutating func recordSnapshotQueued(at elapsed: TimeInterval) {
        snapshotQueuedCount += 1
        if firstSnapshotQueuedAt == nil {
            firstSnapshotQueuedAt = elapsed
        }
    }

    mutating func recordSnapshotIssued(at elapsed: TimeInterval) {
        snapshotIssuedCount += 1
        if firstSnapshotIssuedAt == nil {
            firstSnapshotIssuedAt = elapsed
        }
    }

    mutating func recordSnapshotSuccess(callbackLatency: TimeInterval?, at elapsed: TimeInterval) {
        snapshotSuccessCount += 1
        lastSnapshotSuccessAt = elapsed
        lastSnapshotCallbackLatency = callbackLatency
        if firstSnapshotSuccessAt == nil {
            firstSnapshotSuccessAt = elapsed
        }
        recordFreshImage(source: "snapshot", resolvesTrustedImage: true, at: elapsed)
    }

    mutating func recordSnapshotFailure(callbackLatency: TimeInterval?, phase: String) {
        snapshotFailureCount += 1
        lastSnapshotCallbackLatency = callbackLatency
        switch phase {
        case "initialStartup": snapshotInitialFailureCount += 1
        case "recovering": snapshotRecoveryFailureCount += 1
        default: snapshotRoutineFailureCount += 1
        }
    }

    mutating func recordLiveStarted(
        callbackLatency: TimeInterval?,
        resolvesTrustedImage: Bool,
        at elapsed: TimeInterval
    ) {
        lastLiveStartCallbackLatency = callbackLatency
        recordFreshImage(
            source: "live",
            resolvesTrustedImage: resolvesTrustedImage,
            at: elapsed
        )
    }

    mutating func recordSnapshotTimeout() {
        snapshotTimeoutCount += 1
    }

    mutating func recordBatteryWakeLeaseStarted(at elapsed: TimeInterval) {
        batteryWakeLeaseStartedCount += 1
        if firstBatteryWakeLeaseStartedAt == nil {
            firstBatteryWakeLeaseStartedAt = elapsed
        }
    }

    mutating func recordBatteryTrustedStill(at elapsed: TimeInterval) {
        batteryTrustedStillCount += 1
        if firstBatteryTrustedStillAt == nil {
            firstBatteryTrustedStillAt = elapsed
        }
        recordFreshImage(source: "batteryStill", resolvesTrustedImage: true, at: elapsed)
    }

    mutating func recordBatteryWakeFailure() {
        batteryWakeFailureCount += 1
    }

    mutating func recordBatteryWakeTimeout() {
        batteryWakeTimeoutCount += 1
    }

}

struct CameraTelemetryFeed: Equatable {
    let priorityIndex: Int
    let id: String
    let name: String
    let roomName: String?
    let isVisibleOnWall: Bool
    let isReachable: Bool
    let isAvailableInSession: Bool
    let isHomeKitCameraActive: Bool?
    let isBatteryWakeCamera: Bool
    let isStreaming: Bool
    let isStartingLive: Bool
    let liveTransportPhase: String
    let displayState: String
    let recencyTier: String
    let recoveryPhase: String
    let snapshotPriority: String
    let presentationMode: String
    let displayedStillAge: TimeInterval?
    let lastSnapshotSuccessAge: TimeInterval?
    let snapshotWorkState: String
    let snapshotRequestID: String?
    let snapshotInFlightAge: TimeInterval?
    let snapshotOverdueAge: TimeInterval?
    let nextEligibleSnapshotIn: TimeInterval?
    let lastSnapshotRequestAge: TimeInterval?
    let startupCoverageResolution: String
    let startupSnapshotAttempted: Bool
    let startupSnapshotPath: String
    let startupLivePath: String
    let batteryStillAge: TimeInterval?
    let nextBatteryCaptureDueIn: TimeInterval?
    let batteryWakeLeaseAge: TimeInterval?
    let batteryWakeRetryIn: TimeInterval?
    let consecutiveBatteryWakeFailures: Int
    let liveStartedAge: TimeInterval?
    let liveStartRequestedAge: TimeInterval?
    let liveStopRequestedAge: TimeInterval?
    let liveStopReason: String?
    let lastErrorMessage: String?
}

struct CameraTelemetryReport: Equatable {
    let generatedAt: Date
    let sessionStartedAt: Date
    let appVersion: String
    let authorizationStatus: String
    let selectedHomeName: String?
    let homeHubState: String
    let sessionMode: String
    let isAppActive: Bool
    let focusedFeedID: String?
    let liveCapacity: Int
    let liveAdmissionMode: String
    let liveAdmissionSustainableCapacity: Int
    let liveAdmissionSoftContentionCeiling: Int?
    let liveAdmissionPlannerCapacity: Int?
    let liveAdmissionEffectiveCapacity: Int?
    let liveAdmissionCapacityLimitReason: String
    let liveAdmissionActiveCapacityProbeFeedID: String?
    let liveAdmissionTargetIDs: [String]
    let liveAdmissionReservedIDs: [String]
    let liveAdmissionQueuedIDs: [String]
    let visibleFeedCount: Int
    let internalMaxConcurrentSnapshotRequests: Int
    let effectiveMaxConcurrentSnapshotRequests: Int
    let snapshotRequestTimeout: TimeInterval
    let untrustedSnapshotRefreshInterval: TimeInterval
    let trustedSnapshotRefreshInterval: TimeInterval
    let batteryCaptureWarmup: TimeInterval
    let batteryWakeTriggerThreshold: TimeInterval
    let batteryWakeLeaseDuration: TimeInterval
    let batteryWakeLiveStartTimeout: TimeInterval
    let wiredStartupLiveStartTimeout: TimeInterval
    let startupCoverageActive: Bool
    let restrictedStartupPhase: String
    let ordinaryLiveGateState: String
    let sessionNetworkClass: String
    let currentNetworkClass: String
    let wifiLiveBurstMode: String
    let wifiLiveBurstSurvivorIDs: [String]
    let startupLiveRampMode: String
    let startupLiveRampSelectedIDs: [String]
    let startupLiveRampPendingIDs: [String]
    let startupLiveRampMaxPendingCount: Int
    let startupLiveRampFastThreshold: TimeInterval
    let activeSnapshotRequests: Int
    let outstandingSnapshotRequests: Int
    let liveCapacityExpansionRetryIn: TimeInterval?
    let liveCapacityExpansionCooldownEligible: Bool
    let liveCapacityIncludesUnconfirmedMemory: Bool
    let startupMilestones: CameraStartupTelemetryMilestones
    let feeds: [CameraTelemetryFeed]
    let events: [CameraTelemetryEvent]

    var text: String {
        var lines: [String] = []
        lines.append("Observe Telemetry")
        lines.append("generatedAt=\(generatedAt.timeIntervalSinceReferenceDate)")
        lines.append("sessionElapsed=\(formatSeconds(generatedAt.timeIntervalSince(sessionStartedAt)))")
        lines.append("appVersion=\(appVersion)")
        lines.append("authorizationStatus=\(authorizationStatus)")
        lines.append("selectedHome=\(selectedHomeName ?? "nil")")
        lines.append("homeHubState=\(homeHubState)")
        lines.append("sessionMode=\(sessionMode)")
        lines.append("isAppActive=\(isAppActive)")
        lines.append("focusedFeedID=\(focusedFeedID ?? "nil")")
        lines.append("liveCapacity=\(liveCapacity)")
        lines.append("liveAdmissionMode=\(liveAdmissionMode)")
        lines.append("liveAdmissionSustainableCapacity=\(liveAdmissionSustainableCapacity)")
        lines.append("liveAdmissionSoftContentionCeiling=\(liveAdmissionSoftContentionCeiling.map(String.init) ?? "nil")")
        lines.append("liveAdmissionPlannerCapacity=\(liveAdmissionPlannerCapacity.map(String.init) ?? "nil")")
        lines.append("liveAdmissionEffectiveCapacity=\(liveAdmissionEffectiveCapacity.map(String.init) ?? "nil")")
        lines.append("liveAdmissionCapacityLimitReason=\(liveAdmissionCapacityLimitReason)")
        lines.append("liveAdmissionActiveCapacityProbeFeedID=\(liveAdmissionActiveCapacityProbeFeedID ?? "nil")")
        lines.append("liveAdmissionTargetIDs=\(liveAdmissionTargetIDs.isEmpty ? "none" : liveAdmissionTargetIDs.joined(separator: ","))")
        lines.append("liveAdmissionReservedIDs=\(liveAdmissionReservedIDs.isEmpty ? "none" : liveAdmissionReservedIDs.joined(separator: ","))")
        lines.append("liveAdmissionQueuedIDs=\(liveAdmissionQueuedIDs.isEmpty ? "none" : liveAdmissionQueuedIDs.joined(separator: ","))")
        lines.append("visibleFeedCount=\(visibleFeedCount)")
        lines.append("internalMaxConcurrentSnapshotRequests=\(internalMaxConcurrentSnapshotRequests)")
        lines.append("effectiveMaxConcurrentSnapshotRequests=\(effectiveMaxConcurrentSnapshotRequests)")
        lines.append("snapshotRequestTimeout=\(formatSeconds(snapshotRequestTimeout))")
        lines.append("untrustedSnapshotRefreshInterval=\(formatSeconds(untrustedSnapshotRefreshInterval))")
        lines.append("trustedSnapshotRefreshInterval=\(formatSeconds(trustedSnapshotRefreshInterval))")
        lines.append("batteryCaptureWarmup=\(formatSeconds(batteryCaptureWarmup))")
        lines.append("batteryWakeTriggerThreshold=\(formatSeconds(batteryWakeTriggerThreshold))")
        lines.append("batteryWakeLeaseDuration=\(formatSeconds(batteryWakeLeaseDuration))")
        lines.append("batteryWakeLiveStartTimeout=\(formatSeconds(batteryWakeLiveStartTimeout))")
        lines.append("wiredStartupLiveStartTimeout=\(formatSeconds(wiredStartupLiveStartTimeout))")
        lines.append("startupCoverageActive=\(startupCoverageActive)")
        lines.append("restrictedStartupPhase=\(restrictedStartupPhase)")
        lines.append("ordinaryLiveGateState=\(ordinaryLiveGateState)")
        lines.append("sessionNetworkClass=\(sessionNetworkClass)")
        lines.append("currentNetworkClass=\(currentNetworkClass)")
        lines.append("wifiLiveBurstMode=\(wifiLiveBurstMode)")
        lines.append("wifiLiveBurstSurvivorIDs=\(wifiLiveBurstSurvivorIDs.isEmpty ? "none" : wifiLiveBurstSurvivorIDs.joined(separator: ","))")
        lines.append("startupLiveRampMode=\(startupLiveRampMode)")
        lines.append("startupLiveRampSelectedIDs=\(startupLiveRampSelectedIDs.isEmpty ? "none" : startupLiveRampSelectedIDs.joined(separator: ","))")
        lines.append("startupLiveRampPendingIDs=\(startupLiveRampPendingIDs.isEmpty ? "none" : startupLiveRampPendingIDs.joined(separator: ","))")
        lines.append("startupLiveRampMaxPendingCount=\(startupLiveRampMaxPendingCount)")
        lines.append("startupLiveRampFastThreshold=\(formatSeconds(startupLiveRampFastThreshold))")
        lines.append("activeSnapshotRequests=\(activeSnapshotRequests)")
        lines.append("outstandingSnapshotRequests=\(outstandingSnapshotRequests)")
        lines.append("liveCapacityExpansionRetryIn=\(optionalSeconds(liveCapacityExpansionRetryIn))")
        lines.append("liveCapacityExpansionCooldownEligible=\(liveCapacityExpansionCooldownEligible)")
        lines.append("liveCapacityIncludesUnconfirmedMemory=\(liveCapacityIncludesUnconfirmedMemory)")
        lines.append("")
        lines.append("Startup Milestones")
        lines.append("enteredConstrainedModeAt=\(optionalSeconds(startupMilestones.enteredConstrainedModeAt))")
        lines.append("enteredConstrainedModeLiveCapacity=\(startupMilestones.enteredConstrainedModeLiveCapacity.map(String.init) ?? "nil")")
        lines.append("firstConstrainedSignalAt=\(optionalSeconds(startupMilestones.firstConstrainedSignalAt))")
        lines.append("firstConstrainedSignalFeedID=\(startupMilestones.firstConstrainedSignalFeedID ?? "nil")")
        lines.append("allVisibleFeedsTrustedAt=\(optionalSeconds(startupMilestones.allVisibleFeedsTrustedAt))")
        lines.append("allVisibleFeedsLiveAt=\(optionalSeconds(startupMilestones.allVisibleFeedsLiveAt))")
        lines.append("startupCoverageEndedAt=\(optionalSeconds(startupMilestones.startupCoverageEndedAt))")
        lines.append("startupCoverageResult=\(startupMilestones.startupCoverageResult ?? "nil")")
        lines.append("recoveringFeedIDs=\(startupMilestones.recoveringFeedIDs.isEmpty ? "none" : startupMilestones.recoveringFeedIDs.joined(separator: ","))")
        lines.append("peakActiveSnapshotRequests=\(startupMilestones.peakActiveSnapshotRequests)")
        lines.append("peakOutstandingSnapshotRequests=\(startupMilestones.peakOutstandingSnapshotRequests)")
        lines.append("")
        lines.append("Startup Feed Milestones")
        let feedMilestones = startupMilestones.feedsByID.values.sorted { $0.feedID < $1.feedID }
        if feedMilestones.isEmpty {
            lines.append("none")
        } else {
            for milestones in feedMilestones {
                lines.append(feedMilestoneLine(milestones))
            }
        }
        lines.append("")
        lines.append("Feeds")
        for feed in feeds {
            lines.append(feedLine(feed))
        }
        lines.append("")
        lines.append("Events")
        if events.isEmpty {
            lines.append("none")
        } else {
            lines.append(contentsOf: events.map {
                "#\($0.sequence) +\(formatPreciseSeconds($0.elapsed)) \($0.message)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private func feedMilestoneLine(_ milestones: CameraStartupTelemetryFeedMilestones) -> String {
        [
            milestones.feedID,
            "firstTrustedImageAt=\(optionalSeconds(milestones.firstTrustedImageAt))",
            "firstTrustedImageSource=\(milestones.firstTrustedImageSource ?? "nil")",
            "firstFreshImageAt=\(optionalSeconds(milestones.firstFreshImageAt))",
            "firstSnapshotQueuedAt=\(optionalSeconds(milestones.firstSnapshotQueuedAt))",
            "firstSnapshotIssuedAt=\(optionalSeconds(milestones.firstSnapshotIssuedAt))",
            "firstSnapshotSuccessAt=\(optionalSeconds(milestones.firstSnapshotSuccessAt))",
            "lastSnapshotSuccessAt=\(optionalSeconds(milestones.lastSnapshotSuccessAt))",
            "snapshotQueuedCount=\(milestones.snapshotQueuedCount)",
            "snapshotIssuedCount=\(milestones.snapshotIssuedCount)",
            "snapshotSuccessCount=\(milestones.snapshotSuccessCount)",
            "snapshotFailureCount=\(milestones.snapshotFailureCount)",
            "snapshotInitialFailureCount=\(milestones.snapshotInitialFailureCount)",
            "snapshotRecoveryFailureCount=\(milestones.snapshotRecoveryFailureCount)",
            "snapshotRoutineFailureCount=\(milestones.snapshotRoutineFailureCount)",
            "snapshotTimeoutCount=\(milestones.snapshotTimeoutCount)",
            "lastSnapshotCallbackLatency=\(optionalSeconds(milestones.lastSnapshotCallbackLatency))",
            "lastLiveStartCallbackLatency=\(optionalSeconds(milestones.lastLiveStartCallbackLatency))",
            "lastLiveStopCallbackLatency=\(optionalSeconds(milestones.lastLiveStopCallbackLatency))",
            "startupEnteredRecovery=\(milestones.startupEnteredRecovery)",
            "firstBatteryWakeLeaseStartedAt=\(optionalSeconds(milestones.firstBatteryWakeLeaseStartedAt))",
            "firstBatteryTrustedStillAt=\(optionalSeconds(milestones.firstBatteryTrustedStillAt))",
            "batteryWakeLeaseStartedCount=\(milestones.batteryWakeLeaseStartedCount)",
            "batteryTrustedStillCount=\(milestones.batteryTrustedStillCount)",
            "batteryWakeFailureCount=\(milestones.batteryWakeFailureCount)",
            "batteryWakeTimeoutCount=\(milestones.batteryWakeTimeoutCount)"
        ].joined(separator: " | ")
    }

    private func feedLine(_ feed: CameraTelemetryFeed) -> String {
        [
            "#\(feed.priorityIndex)",
            "\(feed.id) | \(feed.name) | room=\(feed.roomName ?? "nil")",
            "visible=\(feed.isVisibleOnWall)",
            "reachable=\(feed.isReachable)",
            "sessionAvailable=\(feed.isAvailableInSession)",
            "homeKitActive=\(feed.isHomeKitCameraActive.map(String.init) ?? "nil")",
            "battery=\(feed.isBatteryWakeCamera)",
            "streaming=\(feed.isStreaming)",
            "startingLive=\(feed.isStartingLive)",
            "liveTransportPhase=\(feed.liveTransportPhase)",
            "displayState=\(feed.displayState)",
            "recency=\(feed.recencyTier)",
            "recovery=\(feed.recoveryPhase)",
            "snapshotPriority=\(feed.snapshotPriority)",
            "presentation=\(feed.presentationMode)",
            "displayedStillAge=\(optionalSeconds(feed.displayedStillAge))",
            "lastSnapshotSuccessAge=\(optionalSeconds(feed.lastSnapshotSuccessAge))",
            "snapshotWorkState=\(feed.snapshotWorkState)",
            "snapshotRequestID=\(feed.snapshotRequestID ?? "nil")",
            "snapshotInFlightAge=\(optionalSeconds(feed.snapshotInFlightAge))",
            "snapshotOverdueAge=\(optionalSeconds(feed.snapshotOverdueAge))",
            "nextEligibleSnapshotIn=\(optionalSeconds(feed.nextEligibleSnapshotIn))",
            "lastSnapshotRequestAge=\(optionalSeconds(feed.lastSnapshotRequestAge))",
            "startupCoverage=\(feed.startupCoverageResolution)",
            "startupSnapshotAttempted=\(feed.startupSnapshotAttempted)",
            "startupSnapshotPath=\(feed.startupSnapshotPath)",
            "startupLivePath=\(feed.startupLivePath)",
            "batteryStillAge=\(optionalSeconds(feed.batteryStillAge))",
            "nextBatteryCaptureDueIn=\(optionalSeconds(feed.nextBatteryCaptureDueIn))",
            "batteryWakeLeaseAge=\(optionalSeconds(feed.batteryWakeLeaseAge))",
            "batteryWakeRetryIn=\(optionalSeconds(feed.batteryWakeRetryIn))",
            "batteryWakeFailures=\(feed.consecutiveBatteryWakeFailures)",
            "liveStartedAge=\(optionalSeconds(feed.liveStartedAge))",
            "liveStartRequestedAge=\(optionalSeconds(feed.liveStartRequestedAge))",
            "liveStopRequestedAge=\(optionalSeconds(feed.liveStopRequestedAge))",
            "liveStopReason=\(feed.liveStopReason ?? "nil")",
            "lastError=\(feed.lastErrorMessage ?? "nil")"
        ].joined(separator: " | ")
    }

}

func age(of date: Date?, at reference: Date) -> TimeInterval? {
    guard let date else { return nil }
    return max(0, reference.timeIntervalSince(date))
}

func secondsUntil(_ date: Date?, from reference: Date) -> TimeInterval? {
    guard let date, date != .distantPast, date != .distantFuture else { return nil }
    return date.timeIntervalSince(reference)
}

func optionalSeconds(_ value: TimeInterval?) -> String {
    guard let value else { return "nil" }
    return formatSeconds(value)
}

func formatSeconds(_ value: TimeInterval) -> String {
    String(format: "%.1fs", value)
}

func formatPreciseSeconds(_ value: TimeInterval) -> String {
    String(format: "%.3fs", value)
}

func transportErrorLabel(_ error: CameraTransportError?) -> String {
    guard let error else { return "nil" }
    return "\(error.domain):\(error.code) \(error.message)"
}

func snapshotWorkStateLabel(_ state: SnapshotWorkState?) -> String {
    guard let state else { return "unknown" }
    switch state {
    case .idle:
        return "idle"
    case .queued:
        return "queued"
    case .pending(let request):
        return request.timeoutReportedAt == nil ? "active" : "overdue"
    }
}

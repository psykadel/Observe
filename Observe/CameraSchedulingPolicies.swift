import Foundation

enum CameraSchedulingDefaults {
    static let staleVisualHighlightThreshold: TimeInterval = 60
    static let batteryWakeTriggerThreshold: TimeInterval = 60
    static let batteryStaleThreshold: TimeInterval = 120
    static let snapshotRequestTimeout: TimeInterval = 4
    static let maxConcurrentSnapshotRequests = 3
    static let untrustedSnapshotRefreshInterval: TimeInterval = 2
    static let minimumSnapshotRefreshInterval: TimeInterval = 5
    static let batteryCaptureWarmup: TimeInterval = 5
    static let batteryCaptureLeasePadding: TimeInterval = 3
    static let batteryWakeLeaseDuration: TimeInterval = 8
    static let batteryWakeLiveStartTimeout: TimeInterval = 30
    static let liveCapacityExpansionRetryDelay: TimeInterval = 10
}

enum SnapshotQueuePolicy {
    static func minimumRefreshInterval(for priority: SnapshotPriority) -> TimeInterval {
        switch priority {
        case .urgent:
            CameraSchedulingDefaults.untrustedSnapshotRefreshInterval
        case .refresh, .none:
            CameraSchedulingDefaults.minimumSnapshotRefreshInterval
        }
    }

    static func nextEligibleDate(current: Date, requestedAt: Date) -> Date {
        nextEligibleDate(
            current: current,
            requestedAt: requestedAt,
            lastRequestIssuedAt: nil,
            minimumInterval: 0
        )
    }

    static func nextEligibleDate(
        current: Date,
        requestedAt: Date,
        lastRequestIssuedAt: Date?,
        minimumInterval: TimeInterval
    ) -> Date {
        let intervalEligibleDate = lastRequestIssuedAt.map {
            $0.addingTimeInterval(max(0, minimumInterval))
        } ?? requestedAt
        let requestedOrThrottledDate = max(requestedAt, intervalEligibleDate)

        if current == .distantFuture {
            return requestedOrThrottledDate
        }

        if current > requestedAt {
            return max(current, requestedOrThrottledDate)
        }

        return requestedOrThrottledDate
    }

    static func nextEligibleDateAfterFailure(
        failedAt: Date,
        lastRequestIssuedAt: Date?,
        priority: SnapshotPriority
    ) -> Date {
        let minimumInterval = minimumRefreshInterval(for: priority)
        let issueEligibleDate = lastRequestIssuedAt.map {
            $0.addingTimeInterval(max(0, minimumInterval))
        } ?? failedAt
        let completionEligibleDate = failedAt.addingTimeInterval(max(0, minimumInterval))
        return max(issueEligibleDate, completionEligibleDate)
    }
}

enum StartupSnapshotRecoveryPolicy {
    static func retryEligibleDate(
        startupCoverageActive: Bool,
        startupState: StartupCameraState,
        snapshotFailedAt: Date?,
        lastRequestIssuedAt: Date?,
        priority: SnapshotPriority
    ) -> Date? {
        guard let snapshotFailedAt else { return nil }
        guard !startupCoverageActive || startupState.resolution == .recovering else {
            return nil
        }

        return SnapshotQueuePolicy.nextEligibleDateAfterFailure(
            failedAt: snapshotFailedAt,
            lastRequestIssuedAt: lastRequestIssuedAt,
            priority: priority
        )
    }
}

enum StartupSnapshotConcurrencyPolicy {
    static func effectiveLimit(
        isFirstFramePhaseActive: Bool,
        nonBatteryTrustedCount: Int,
        nonBatteryCount: Int
    ) -> Int {
        guard isFirstFramePhaseActive,
              nonBatteryCount > 0,
              nonBatteryTrustedCount < nonBatteryCount else {
            return CameraSchedulingDefaults.maxConcurrentSnapshotRequests
        }

        let startupLimit = nonBatteryTrustedCount == 0 ? 2 : 3
        return min(CameraSchedulingDefaults.maxConcurrentSnapshotRequests, startupLimit)
    }
}

enum SnapshotRequestMatchPolicy {
    static func isCurrent(
        currentRequestID: SnapshotRequestID?,
        resultRequestID: SnapshotRequestID?,
        isInFlight: Bool
    ) -> Bool {
        guard isInFlight,
              let currentRequestID,
              let resultRequestID else {
            return false
        }

        return currentRequestID == resultRequestID
    }

    static func acceptsLateFirstSuccess(
        result: SnapshotRequestResult,
        hasTrustedImage: Bool,
        staleThreshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard !hasTrustedImage,
              case .success(let captureDate) = result else {
            return false
        }

        return max(0, now.timeIntervalSince(captureDate)) <= staleThreshold
    }
}

enum SnapshotResultTelemetry {
    static func staleSchedulerResultIgnoredMessage(
        feedID: String,
        requestID: SnapshotRequestID?,
        currentRequestID: SnapshotRequestID?,
        result: SnapshotRequestResult,
        now: Date
    ) -> String {
        let baseMessage = "snapshot stale scheduler result ignored \(feedID) request=\(requestID.map(String.init) ?? "nil") current=\(currentRequestID.map(String.init) ?? "nil")"
        switch result {
        case .success(let captureDate):
            return "\(baseMessage) imageUpdated=true captureAge=\(formatSeconds(max(0, now.timeIntervalSince(captureDate))))"
        case .failure(let error):
            return "\(baseMessage) imageUpdated=false error=\(transportErrorLabel(error))"
        }
    }
}

enum BatteryTrustedStillCapturePolicy {
    static func shouldCapture(
        isBatteryCamera: Bool,
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryStillDate: Date?,
        batteryWakeLeaseStartedAt: Date?,
        allowsUnleasedCapture: Bool,
        warmup: TimeInterval,
        now: Date
    ) -> Bool {
        guard isBatteryCamera, isStreaming, let liveStartedAt else { return false }
        guard allowsUnleasedCapture || batteryWakeLeaseStartedAt != nil else { return false }

        guard now.timeIntervalSince(liveStartedAt) >= warmup else { return false }

        return (batteryStillDate ?? .distantPast) < liveStartedAt
    }
}

enum BatteryWakeLeaseTimeoutPolicy {
    static func hasTimedOut(
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryWakeLeaseStartedAt: Date,
        warmup: TimeInterval,
        leaseDuration: TimeInterval,
        liveStartTimeout: TimeInterval,
        now: Date
    ) -> Bool {
        if isStreaming, let liveStartedAt {
            return now.timeIntervalSince(liveStartedAt) >= max(warmup, leaseDuration)
        }
        return now.timeIntervalSince(batteryWakeLeaseStartedAt) >= liveStartTimeout
    }
}

enum BatteryWakeConstrainedSignalPolicy {
    static func shouldKeepLeaseAlive(
        isBatteryCamera: Bool,
        isStreaming: Bool,
        liveStartedAt: Date?,
        batteryWakeLeaseStartedAt: Date?,
        didCaptureTrustedStill: Bool,
        warmup: TimeInterval,
        leaseDuration: TimeInterval,
        liveStartTimeout: TimeInterval,
        now: Date
    ) -> Bool {
        guard isBatteryCamera,
              isStreaming,
              liveStartedAt != nil,
              let batteryWakeLeaseStartedAt,
              !didCaptureTrustedStill else {
            return false
        }

        return !BatteryWakeLeaseTimeoutPolicy.hasTimedOut(
            isStreaming: isStreaming,
            liveStartedAt: liveStartedAt,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            warmup: warmup,
            leaseDuration: leaseDuration,
            liveStartTimeout: liveStartTimeout,
            now: now
        )
    }
}

enum RestrictedLiveCapacity {
    static func enteringAfterConstrainedSignal(
        currentLiveCount: Int,
        visibleFeedCount: Int,
        rememberedCapacity: Int? = nil
    ) -> Int {
        boundedCapacity(
            observedLiveCount: max(currentLiveCount, rememberedCapacity ?? 0),
            visibleFeedCount: visibleFeedCount
        )
    }

    static func recordSuccessfulStreams(
        previousCapacity: Int,
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        boundedCapacity(
            observedLiveCount: max(previousCapacity, currentLiveCount),
            visibleFeedCount: visibleFeedCount
        )
    }

    static func planningBudget(
        knownCapacity: Int,
        visibleFeedCount: Int,
        allVisibleFeedsTrusted: Bool,
        canProbeCapacity: Bool
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        let boundedKnownCapacity = boundedCapacity(
            observedLiveCount: knownCapacity,
            visibleFeedCount: visibleFeedCount
        )
        guard canProbeCapacity, allVisibleFeedsTrusted else {
            return boundedKnownCapacity
        }

        return min(visibleFeedCount, boundedKnownCapacity + 1)
    }

    static func afterConstrainedSignal(
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return boundedCapacity(
            observedLiveCount: currentLiveCount,
            visibleFeedCount: visibleFeedCount
        )
    }

    private static func boundedCapacity(observedLiveCount: Int, visibleFeedCount: Int) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return min(max(1, observedLiveCount), visibleFeedCount)
    }
}

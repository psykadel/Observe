import Foundation

enum PlannedPresentationMode: Equatable {
    case live
    case snapshot
}

enum StartupLivePolicy: Equatable {
    case normal
    case firstImage(allowWiredFallback: Bool)
    case postCoverageRamp(liveIDs: Set<String>)
}

enum StartupCoverageResolution: Equatable {
    case pending
    case trusted
    case unresolved
}

enum StartupCameraPathState: Equatable {
    case notAttempted
    case inFlight(startedAt: Date)
    case succeeded
    case failed

    var wasAttempted: Bool {
        self != .notAttempted
    }

    var startedAt: Date? {
        guard case .inFlight(let startedAt) = self else { return nil }
        return startedAt
    }

    var label: String {
        switch self {
        case .notAttempted: "notAttempted"
        case .inFlight: "inFlight"
        case .succeeded: "succeeded"
        case .failed: "failed"
        }
    }
}

enum StartupCameraEvent: Equatable {
    case reset
    case snapshotRequested(at: Date)
    case snapshotSucceeded
    case snapshotFailed
    case liveRequested(at: Date)
    case liveStarted
    case liveFailed
    case trustedImageObserved
}

struct StartupCameraState: Equatable {
    private(set) var snapshotPath: StartupCameraPathState = .notAttempted
    private(set) var livePath: StartupCameraPathState = .notAttempted
    private(set) var resolution: StartupCoverageResolution = .pending

    var snapshotAttempted: Bool { snapshotPath.wasAttempted }
    var snapshotFailed: Bool { snapshotPath == .failed }
    var liveAttempted: Bool { livePath.wasAttempted }
    var liveFallbackStartedAt: Date? {
        resolution == .pending ? livePath.startedAt : nil
    }

    mutating func apply(_ event: StartupCameraEvent, isBatteryCamera: Bool) {
        switch event {
        case .reset:
            self = StartupCameraState()
        case .snapshotRequested(let startedAt):
            guard resolution == .pending else { return }
            snapshotPath = .inFlight(startedAt: startedAt)
        case .snapshotSucceeded:
            snapshotPath = .succeeded
            resolution = .trusted
        case .snapshotFailed:
            guard resolution != .trusted else { return }
            snapshotPath = .failed
            resolveFailureIfNeeded(isBatteryCamera: isBatteryCamera)
        case .liveRequested(let startedAt):
            guard resolution == .pending else { return }
            livePath = .inFlight(startedAt: startedAt)
        case .liveStarted:
            livePath = .succeeded
            if !isBatteryCamera {
                resolution = .trusted
            }
        case .liveFailed:
            guard resolution != .trusted else { return }
            livePath = .failed
            resolveFailureIfNeeded(isBatteryCamera: isBatteryCamera)
        case .trustedImageObserved:
            resolution = .trusted
        }
    }

    private mutating func resolveFailureIfNeeded(isBatteryCamera: Bool) {
        if isBatteryCamera {
            if livePath == .failed {
                resolution = .unresolved
            }
        } else if snapshotPath == .failed, livePath == .failed {
            resolution = .unresolved
        }
    }
}

enum CameraSessionGeneration {
    static func accepts(callbackGeneration: UInt64, activeGeneration: UInt64) -> Bool {
        callbackGeneration == activeGeneration
    }
}

enum SnapshotPriority: Int, Comparable, Equatable {
    case none = 0
    case refresh = 1
    case urgent = 2

    static func < (lhs: SnapshotPriority, rhs: SnapshotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SnapshotPendingRequest: Equatable {
    let id: SnapshotRequestID
    let priority: SnapshotPriority
    let issuedAt: Date
    var timeoutReportedAt: Date?
}

enum SnapshotWorkState: Equatable {
    case idle
    case queued(priority: SnapshotPriority, eligibleAt: Date)
    case pending(SnapshotPendingRequest)

    var pendingRequest: SnapshotPendingRequest? {
        guard case .pending(let request) = self else { return nil }
        return request
    }

    var isActive: Bool {
        pendingRequest?.timeoutReportedAt == nil && pendingRequest != nil
    }

    var isOutstanding: Bool {
        pendingRequest != nil
    }

    var queuedEligibleAt: Date? {
        guard case .queued(_, let eligibleAt) = self else { return nil }
        return eligibleAt
    }

    @discardableResult
    mutating func markOverdue(at date: Date) -> Bool {
        guard case .pending(var request) = self, request.timeoutReportedAt == nil else {
            return false
        }

        request.timeoutReportedAt = date
        self = .pending(request)
        return true
    }

    @discardableResult
    mutating func enqueue(priority: SnapshotPriority, eligibleAt: Date) -> Bool {
        switch self {
        case .idle:
            self = .queued(priority: priority, eligibleAt: eligibleAt)
            return true
        case .queued(let existingPriority, let existingDate):
            guard priority > existingPriority else { return false }
            self = .queued(priority: priority, eligibleAt: min(existingDate, eligibleAt))
            return true
        case .pending:
            return false
        }
    }
}

struct SnapshotAdmissionCapacity: Equatable {
    let activeCount: Int
    let outstandingCount: Int
    let availableActiveSlots: Int
    let availableOutstandingSlots: Int
}

enum SnapshotAdmissionPolicy {
    static func capacity(
        states: [SnapshotWorkState],
        activeLimit: Int,
        outstandingLimit: Int
    ) -> SnapshotAdmissionCapacity {
        let activeCount = states.filter(\.isActive).count
        let outstandingCount = states.filter(\.isOutstanding).count
        return SnapshotAdmissionCapacity(
            activeCount: activeCount,
            outstandingCount: outstandingCount,
            availableActiveSlots: max(0, activeLimit - activeCount),
            availableOutstandingSlots: max(0, outstandingLimit - outstandingCount)
        )
    }
}

enum SnapshotQueueAdmissionPolicy {
    static func shouldQueue(isBatteryCamera: Bool, priority: SnapshotPriority) -> Bool {
        !isBatteryCamera && priority != .none
    }
}

enum StartupFastLocalLivePolicy {
    static func shouldActivate(
        liveStartedAtElapsed: TimeInterval,
        threshold: TimeInterval
    ) -> Bool {
        liveStartedAtElapsed >= 0 && liveStartedAtElapsed < threshold
    }
}

enum PostCoverageLiveRampPolicy {
    static func nextSelection(
        feeds: [FeedPlanningSnapshot],
        selectedIDs: Set<String>
    ) -> Set<String> {
        let prioritizedFeeds = feeds.sorted { $0.priorityIndex < $1.priorityIndex }
        let eligibleFeeds = prioritizedFeeds
        let eligibleIDs = Set(eligibleFeeds.map(\.id))
        var selection = selectedIDs.intersection(eligibleIDs)
        if let focused = eligibleFeeds.first(where: \.isFocused) {
            selection.insert(focused.id)
        }

        guard selection.allSatisfy({ id in
            feeds.first(where: { $0.id == id })?.isStreaming == true
        }) else {
            return selection
        }

        if let nextFeed = eligibleFeeds.first(where: { !selection.contains($0.id) }) {
            selection.insert(nextFeed.id)
        }
        return selection
    }

    static func isComplete(feeds: [FeedPlanningSnapshot], selectedIDs: Set<String>) -> Bool {
        let eligibleIDs = Set(feeds.map(\.id))
        return selectedIDs == eligibleIDs && selectedIDs.allSatisfy { id in
            feeds.first(where: { $0.id == id })?.isStreaming == true
        }
    }
}

struct FeedPlanningSnapshot: Equatable {
    let id: String
    let priorityIndex: Int
    let isFocused: Bool
    let isStreaming: Bool
    let liveStartedAt: Date?
    let lastSnapshotDate: Date?
    let staleThreshold: TimeInterval
    let isBatteryWakeCamera: Bool
    let batteryWakeTriggerThreshold: TimeInterval
    let batteryWakeLeaseStartedAt: Date?
    let batteryWakeRetryAfter: Date?
    let startupState: StartupCameraState

    func recencyTier(at now: Date) -> FeedRecencyTier {
        if isStreaming {
            return .live
        }

        guard let lastSnapshotDate else {
            return .empty
        }

        let age = max(0, now.timeIntervalSince(lastSnapshotDate))
        return age <= staleThreshold ? .recentSnapshot : .staleSnapshot
    }

    func snapshotAge(at now: Date) -> TimeInterval? {
        guard let lastSnapshotDate else { return nil }
        return max(0, now.timeIntervalSince(lastSnapshotDate))
    }

    func hasTrustedImage(at now: Date) -> Bool {
        if isBatteryWakeCamera {
            guard let lastSnapshotDate else { return false }
            return max(0, now.timeIntervalSince(lastSnapshotDate)) <= batteryWakeTriggerThreshold
        }

        if isStreaming {
            return true
        }

        guard let lastSnapshotDate else { return false }
        return max(0, now.timeIntervalSince(lastSnapshotDate)) <= staleThreshold
    }

    func snapshotPriority(at now: Date) -> SnapshotPriority {
        guard !isBatteryWakeCamera, !isStreaming else { return .none }

        switch recencyTier(at: now) {
        case .empty, .staleSnapshot:
            return .urgent
        case .recentSnapshot:
            return .refresh
        case .live:
            return .none
        }
    }

    func hasActiveBatteryCapture(
        at now: Date,
        leaseDuration: TimeInterval,
        warmup: TimeInterval,
        liveStartTimeout: TimeInterval
    ) -> Bool {
        guard let batteryWakeLeaseStartedAt else { return false }
        guard !hasTrustedImage(at: now) else { return false }
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

    func needsBatteryCapture(
        at now: Date,
        leaseDuration: TimeInterval,
        warmup: TimeInterval,
        liveStartTimeout: TimeInterval
    ) -> Bool {
        guard isBatteryWakeCamera else { return false }
        if hasActiveBatteryCapture(
            at: now,
            leaseDuration: leaseDuration,
            warmup: warmup,
            liveStartTimeout: liveStartTimeout
        ) {
            return true
        }
        return !hasTrustedImage(at: now) && isBatteryWakeRetryEligible(at: now)
    }

    private func isBatteryWakeRetryEligible(at now: Date) -> Bool {
        guard let batteryWakeRetryAfter else { return true }
        return now >= batteryWakeRetryAfter
    }
}

struct PresentationDecision: Equatable {
    let id: String
    let presentationMode: PlannedPresentationMode
    let recencyTier: FeedRecencyTier
    let recoveryPhase: FeedRecoveryPhase
    let snapshotPriority: SnapshotPriority
}

struct CameraRecoveryPlan {
    let decisionsByID: [String: PresentationDecision]
    let orderedSnapshotIDs: [String]
}

struct CameraRecoveryPlanner {
    let batteryWakeLeaseDuration: TimeInterval
    let batteryCaptureWarmup: TimeInterval
    let batteryWakeLiveStartTimeout: TimeInterval

    init(
        batteryWakeLeaseDuration: TimeInterval = CameraSchedulingDefaults.batteryWakeLeaseDuration,
        batteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup,
        batteryWakeLiveStartTimeout: TimeInterval = CameraSchedulingDefaults.batteryWakeLiveStartTimeout
    ) {
        self.batteryWakeLeaseDuration = batteryWakeLeaseDuration
        self.batteryCaptureWarmup = batteryCaptureWarmup
        self.batteryWakeLiveStartTimeout = batteryWakeLiveStartTimeout
    }

    func makePlan(
        feeds: [FeedPlanningSnapshot],
        sessionMode: SessionMode,
        liveCapacity: Int,
        startupLivePolicy: StartupLivePolicy = .normal,
        now: Date
    ) -> CameraRecoveryPlan {
        let prioritizedFeeds = feeds.sorted { $0.priorityIndex < $1.priorityIndex }
        let recencyByID = Dictionary(
            uniqueKeysWithValues: prioritizedFeeds.map {
                ($0.id, $0.recencyTier(at: now))
            }
        )

        let liveSelection: ConstrainedLiveSelection
        switch startupLivePolicy {
        case .firstImage(let allowWiredFallback):
            liveSelection = firstImageLiveSelection(
                feeds: prioritizedFeeds,
                allowWiredFallback: allowWiredFallback,
                now: now
            )
        case .postCoverageRamp(let liveIDs):
            let batteryCaptureIDs = Set(prioritizedFeeds.filter {
                liveIDs.contains($0.id)
                    && $0.isBatteryWakeCamera
                    && $0.needsBatteryCapture(
                        at: now,
                        leaseDuration: batteryWakeLeaseDuration,
                        warmup: batteryCaptureWarmup,
                        liveStartTimeout: batteryWakeLiveStartTimeout
                    )
            }.map(\.id))
            liveSelection = ConstrainedLiveSelection(
                liveIDs: liveIDs,
                batteryCaptureIDs: batteryCaptureIDs,
                batteryWaitingIDs: []
            )
        case .normal:
            switch sessionMode {
            case .optimistic:
                liveSelection = optimisticLiveSelection(feeds: prioritizedFeeds, now: now)
            case .constrained:
                liveSelection = constrainedLiveSelection(
                    feeds: prioritizedFeeds,
                    liveCapacity: liveCapacity,
                    now: now
                )
            }
        }

        var decisionsByID: [String: PresentationDecision] = [:]
        for feed in prioritizedFeeds {
            let recencyTier = recencyByID[feed.id] ?? .empty
            let wantsLive = liveSelection.liveIDs.contains(feed.id)
            let recoveryPhase: FeedRecoveryPhase
            if liveSelection.batteryCaptureIDs.contains(feed.id) {
                recoveryPhase = .batteryCapture
            } else if liveSelection.batteryWaitingIDs.contains(feed.id) {
                recoveryPhase = .batteryWaiting
            } else {
                recoveryPhase = .idle
            }

            decisionsByID[feed.id] = PresentationDecision(
                id: feed.id,
                presentationMode: wantsLive ? .live : .snapshot,
                recencyTier: recencyTier,
                recoveryPhase: recoveryPhase,
                snapshotPriority: feed.snapshotPriority(at: now)
            )
        }

        let orderedSnapshotIDs = prioritizedFeeds
            .filter { (decisionsByID[$0.id]?.snapshotPriority ?? .none) != .none }
            .sorted {
                let lhsPriority = decisionsByID[$0.id]?.snapshotPriority ?? .none
                let rhsPriority = decisionsByID[$1.id]?.snapshotPriority ?? .none
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                return $0.priorityIndex < $1.priorityIndex
            }
            .map(\.id)

        return CameraRecoveryPlan(decisionsByID: decisionsByID, orderedSnapshotIDs: orderedSnapshotIDs)
    }

    private func optimisticLiveSelection(
        feeds: [FeedPlanningSnapshot],
        now: Date
    ) -> ConstrainedLiveSelection {
        let batteryCaptureIDs = Set(feeds.filter {
            $0.isBatteryWakeCamera
                && $0.needsBatteryCapture(
                    at: now,
                    leaseDuration: batteryWakeLeaseDuration,
                    warmup: batteryCaptureWarmup,
                    liveStartTimeout: batteryWakeLiveStartTimeout
                )
        }.map(\.id))

        return ConstrainedLiveSelection(
            liveIDs: Set(feeds.map(\.id)),
            batteryCaptureIDs: batteryCaptureIDs,
            batteryWaitingIDs: []
        )
    }

    private func firstImageLiveSelection(
        feeds: [FeedPlanningSnapshot],
        allowWiredFallback: Bool,
        now: Date
    ) -> ConstrainedLiveSelection {
        let batteryNeedingTrustedStillIDs = Set(
            feeds
                .filter {
                    $0.isBatteryWakeCamera
                        && !$0.hasTrustedImage(at: now)
                        && $0.startupState.resolution != .unresolved
                }
                .map(\.id)
        )

        if let focused = feeds.first(where: \.isFocused) {
            let capturesBattery = focused.needsBatteryCapture(
                at: now,
                leaseDuration: batteryWakeLeaseDuration,
                warmup: batteryCaptureWarmup,
                liveStartTimeout: batteryWakeLiveStartTimeout
            )
            return ConstrainedLiveSelection(
                liveIDs: [focused.id],
                batteryCaptureIDs: capturesBattery ? [focused.id] : [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs.subtracting(capturesBattery ? [focused.id] : [])
            )
        }

        if let activeBattery = feeds.first(where: {
            $0.startupState.resolution != .unresolved
                && $0.hasActiveBatteryCapture(
                    at: now,
                    leaseDuration: batteryWakeLeaseDuration,
                    warmup: batteryCaptureWarmup,
                    liveStartTimeout: batteryWakeLiveStartTimeout
                )
        }) {
            return ConstrainedLiveSelection(
                liveIDs: [activeBattery.id],
                batteryCaptureIDs: [activeBattery.id],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs.subtracting([activeBattery.id])
            )
        }

        if let activeWiredFallback = feeds.first(where: {
            !$0.isBatteryWakeCamera
                && $0.startupState.resolution != .unresolved
                && $0.startupState.liveFallbackStartedAt != nil
                && !$0.hasTrustedImage(at: now)
        }) {
            return ConstrainedLiveSelection(
                liveIDs: [activeWiredFallback.id],
                batteryCaptureIDs: [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
            )
        }

        if let battery = feeds.first(where: {
            $0.startupState.resolution != .unresolved
                && $0.needsBatteryCapture(
                at: now,
                leaseDuration: batteryWakeLeaseDuration,
                warmup: batteryCaptureWarmup,
                liveStartTimeout: batteryWakeLiveStartTimeout
            )
        }) {
            return ConstrainedLiveSelection(
                liveIDs: [battery.id],
                batteryCaptureIDs: [battery.id],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs.subtracting([battery.id])
            )
        }

        let hasAttemptedWiredLiveProbe = feeds.contains {
            !$0.isBatteryWakeCamera && $0.startupState.liveAttempted
        }
        if !hasAttemptedWiredLiveProbe,
           let wiredProbe = feeds.first(where: {
               !$0.isBatteryWakeCamera
                   && !$0.hasTrustedImage(at: now)
                   && $0.startupState.resolution == .pending
           }) {
            return ConstrainedLiveSelection(
                liveIDs: [wiredProbe.id],
                batteryCaptureIDs: [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
            )
        }

        if allowWiredFallback,
           let wiredFallback = feeds.first(where: {
               !$0.isBatteryWakeCamera
                   && !$0.hasTrustedImage(at: now)
                   && $0.startupState.snapshotAttempted
                   && $0.startupState.resolution != .unresolved
           }) {
            return ConstrainedLiveSelection(
                liveIDs: [wiredFallback.id],
                batteryCaptureIDs: [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
            )
        }

        return ConstrainedLiveSelection(
            liveIDs: [],
            batteryCaptureIDs: [],
            batteryWaitingIDs: batteryNeedingTrustedStillIDs
        )
    }

    private func constrainedLiveSelection(
        feeds: [FeedPlanningSnapshot],
        liveCapacity: Int,
        now: Date
    ) -> ConstrainedLiveSelection {
        let capacity = max(0, min(liveCapacity, feeds.count))
        let batteryNeedingTrustedStillIDs = Set(
            feeds
                .filter { $0.isBatteryWakeCamera && !$0.hasTrustedImage(at: now) }
                .map(\.id)
        )

        guard capacity > 0 else {
            return ConstrainedLiveSelection(
                liveIDs: [],
                batteryCaptureIDs: [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
            )
        }

        let orderedFeeds = feeds.sorted { $0.priorityIndex < $1.priorityIndex }

        var selectedIDs: [String] = []
        var batteryCaptureIDs: [String] = []
        let focusedFeed = orderedFeeds.first(where: { $0.isFocused })

        if let focusedFeed, selectedIDs.count < capacity {
            selectedIDs.append(focusedFeed.id)
            if focusedFeed.needsBatteryCapture(
                at: now,
                leaseDuration: batteryWakeLeaseDuration,
                warmup: batteryCaptureWarmup,
                liveStartTimeout: batteryWakeLiveStartTimeout
            ) {
                batteryCaptureIDs.append(focusedFeed.id)
            }
        }

        for feed in orderedFeeds where selectedIDs.count < capacity {
            guard !selectedIDs.contains(feed.id) else { continue }
            guard feed.hasActiveBatteryCapture(
                at: now,
                leaseDuration: batteryWakeLeaseDuration,
                warmup: batteryCaptureWarmup,
                liveStartTimeout: batteryWakeLiveStartTimeout
            ) else { continue }
            selectedIDs.append(feed.id)
            batteryCaptureIDs.append(feed.id)
        }

        if !batteryNeedingTrustedStillIDs.isEmpty {
            for feed in orderedFeeds where selectedIDs.count < capacity {
                guard !selectedIDs.contains(feed.id),
                      feed.needsBatteryCapture(
                        at: now,
                        leaseDuration: batteryWakeLeaseDuration,
                        warmup: batteryCaptureWarmup,
                        liveStartTimeout: batteryWakeLiveStartTimeout
                      ) else { continue }
                selectedIDs.append(feed.id)
                batteryCaptureIDs.append(feed.id)
            }

            fillRemainingLiveSlots(
                from: orderedFeeds,
                selectedIDs: &selectedIDs,
                capacity: capacity,
                excluding: batteryNeedingTrustedStillIDs
            )

            return ConstrainedLiveSelection(
                liveIDs: Set(selectedIDs),
                batteryCaptureIDs: Set(batteryCaptureIDs),
                batteryWaitingIDs: batteryNeedingTrustedStillIDs.subtracting(batteryCaptureIDs)
            )
        }

        fillRemainingLiveSlots(from: orderedFeeds, selectedIDs: &selectedIDs, capacity: capacity)

        return ConstrainedLiveSelection(
            liveIDs: Set(selectedIDs),
            batteryCaptureIDs: Set(batteryCaptureIDs),
            batteryWaitingIDs: []
        )
    }

    private func fillRemainingLiveSlots(
        from feeds: [FeedPlanningSnapshot],
        selectedIDs: inout [String],
        capacity: Int,
        excluding excludedIDs: Set<String> = []
    ) {
        for feed in feeds where selectedIDs.count < capacity {
            guard !selectedIDs.contains(feed.id) else { continue }
            guard !excludedIDs.contains(feed.id) else { continue }
            selectedIDs.append(feed.id)
        }
    }
}

private extension Set where Element == String {
    func subtracting(_ ids: [String]) -> Set<String> {
        subtracting(Set(ids))
    }
}

private struct ConstrainedLiveSelection {
    let liveIDs: Set<String>
    let batteryCaptureIDs: Set<String>
    let batteryWaitingIDs: Set<String>
}

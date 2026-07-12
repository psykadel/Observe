import Foundation

enum PlannedPresentationMode: Equatable {
    case live
    case snapshot
}

enum StartupLivePolicy: Equatable {
    case normal
    case firstImage(allowWiredFallback: Bool)
    case liveBurst(liveIDs: Set<String>)
    case capacityRamp(liveIDs: Set<String>)
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
    case plainLiveStarted
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
        case .plainLiveStarted:
            livePath = .succeeded
            resolution = .trusted
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

struct LivePlanTransition: Equatable {
    let stopIDs: Set<String>
    let startIDs: Set<String>
    let deferredStartIDs: Set<String>
}

enum LivePlanTransitionPolicy {
    static func makeTransition(
        activeTransportIDs: Set<String>,
        desiredLiveIDs: Set<String>
    ) -> LivePlanTransition {
        let stopIDs = activeTransportIDs.subtracting(desiredLiveIDs)
        let missingDesiredIDs = desiredLiveIDs.subtracting(activeTransportIDs)
        return LivePlanTransition(
            stopIDs: stopIDs,
            startIDs: stopIDs.isEmpty ? missingDesiredIDs : [],
            deferredStartIDs: stopIDs.isEmpty ? [] : missingDesiredIDs
        )
    }
}

enum LivePromotionSnapshotPolicy {
    static func shouldQueue(
        priority: SnapshotPriority,
        presentationMode: PlannedPresentationMode,
        wifiBurstOpen: Bool
    ) -> Bool {
        guard priority != .none else { return false }
        if wifiBurstOpen { return true }
        return presentationMode != .live || priority == .urgent
    }
}

enum StalledStartupRescuePolicy {
    static func rescueCandidateID(
        networkClass: CameraNetworkClass,
        startupCoverageActive: Bool,
        rescueAlreadyAttempted: Bool,
        sessionElapsed: TimeInterval,
        stallThreshold: TimeInterval,
        hasAnyTrustedImage: Bool,
        hasPendingBatteryProbe: Bool,
        eligibleWiredIDs: [String]
    ) -> String? {
        guard networkClass == .cellular,
              startupCoverageActive,
              !rescueAlreadyAttempted,
              sessionElapsed >= max(0, stallThreshold),
              !hasAnyTrustedImage,
              hasPendingBatteryProbe else {
            return nil
        }

        return eligibleWiredIDs.first
    }
}

enum StartupLiveRampMode: String, Equatable {
    case probing
    case conservative
    case fast
    case stopped
    case completed
}

enum CameraNetworkClass: String, Equatable {
    case wifi
    case cellular
    case other
    case unknown
}

enum WiFiLiveBurstCloseReason: String, Equatable {
    case capacity
    case deadline
    case batteryDeadline
    case failure
    case pathInvalidated
}

enum WiFiLiveBurstMode: Equatable {
    case inactive
    case headStart
    case active
    case batteryGrace
    case completed
    case closed(WiFiLiveBurstCloseReason)
}

enum WiFiLiveBurstDefaults {
    static let snapshotHeadStart: TimeInterval = 1
    static let deadline: TimeInterval = 4
    static let batteryDeadline: TimeInterval = CameraSchedulingDefaults.batteryWakeLiveStartTimeout
}

struct WiFiLiveBurstState: Equatable {
    private(set) var mode: WiFiLiveBurstMode
    private(set) var survivingLiveIDs: Set<String> = []

    private let visibleFeedIDs: Set<String>
    private let batteryFeedIDs: Set<String>
    private let startedAt: Date
    private let snapshotHeadStart: TimeInterval
    private let deadline: TimeInterval
    private let batteryDeadline: TimeInterval

    init(
        networkClass: CameraNetworkClass,
        visibleFeedIDs: Set<String>,
        batteryFeedIDs: Set<String> = [],
        startedAt: Date,
        snapshotHeadStart: TimeInterval = WiFiLiveBurstDefaults.snapshotHeadStart,
        deadline: TimeInterval = WiFiLiveBurstDefaults.deadline,
        batteryDeadline: TimeInterval = WiFiLiveBurstDefaults.batteryDeadline
    ) {
        self.visibleFeedIDs = visibleFeedIDs
        self.batteryFeedIDs = batteryFeedIDs.intersection(visibleFeedIDs)
        self.startedAt = startedAt
        self.snapshotHeadStart = max(0, snapshotHeadStart)
        self.deadline = max(0, deadline)
        self.batteryDeadline = max(self.deadline, batteryDeadline)
        mode = networkClass == .wifi && !visibleFeedIDs.isEmpty ? .headStart : .inactive
    }

    var liveIDs: Set<String> {
        switch mode {
        case .headStart, .active, .batteryGrace, .completed:
            visibleFeedIDs
        case .inactive, .closed:
            []
        }
    }

    func allowsSnapshotIssue(at date: Date) -> Bool {
        guard case .headStart = mode else { return true }
        return date.timeIntervalSince(startedAt) + 0.000_001 >= snapshotHeadStart
    }

    mutating func evaluate(streamingIDs: Set<String>, at date: Date) {
        switch mode {
        case .inactive, .completed, .closed:
            return
        case .headStart, .active, .batteryGrace:
            break
        }

        let visibleStreamingIDs = streamingIDs.intersection(visibleFeedIDs)
        survivingLiveIDs = visibleStreamingIDs
        let elapsed = date.timeIntervalSince(startedAt)
        if visibleStreamingIDs == visibleFeedIDs {
            mode = .completed
        } else if elapsed >= batteryDeadline {
            mode = .closed(.batteryDeadline)
        } else if elapsed >= deadline {
            let wiredFeedIDs = visibleFeedIDs.subtracting(batteryFeedIDs)
            mode = visibleStreamingIDs.isSuperset(of: wiredFeedIDs)
                ? .batteryGrace
                : .closed(.deadline)
        } else if elapsed + 0.000_001 >= snapshotHeadStart {
            mode = .active
        }
    }

    mutating func recordCapacityRejection(streamingIDs: Set<String>, at _: Date) {
        close(reason: .capacity, streamingIDs: streamingIDs)
    }

    mutating func recordFailure(streamingIDs: Set<String>, at _: Date) {
        close(reason: .failure, streamingIDs: streamingIDs)
    }

    mutating func invalidatePath(streamingIDs: Set<String>) {
        close(reason: .pathInvalidated, streamingIDs: streamingIDs)
    }

    private mutating func close(
        reason: WiFiLiveBurstCloseReason,
        streamingIDs: Set<String>
    ) {
        guard mode != .inactive else { return }
        guard case .closed = mode else {
            survivingLiveIDs = streamingIDs.intersection(visibleFeedIDs)
            mode = .closed(reason)
            return
        }
    }
}

struct StartupLiveRampState: Equatable {
    private(set) var mode: StartupLiveRampMode = .probing
    private(set) var selectedIDs: Set<String>
    private(set) var confirmedIDs: Set<String> = []
    private(set) var retryAfterByID: [String: Date] = [:]

    init(initialSelectedIDs: Set<String> = []) {
        selectedIDs = initialSelectedIDs
    }

    var maxPendingCount: Int {
        switch mode {
        case .fast:
            2
        case .probing, .conservative:
            1
        case .stopped, .completed:
            0
        }
    }

    var pendingIDs: Set<String> {
        selectedIDs.subtracting(confirmedIDs)
    }

    mutating func recordLiveStarted(
        feedID: String,
        elapsed: TimeInterval,
        fastThreshold: TimeInterval
    ) {
        selectedIDs.insert(feedID)
        confirmedIDs.insert(feedID)
        retryAfterByID.removeValue(forKey: feedID)

        if mode == .probing {
            mode = elapsed >= 0 && elapsed < fastThreshold ? .fast : .conservative
        }
    }

    mutating func recordLiveStopped(
        feedID: String,
        at date: Date,
        isCapacitySignal: Bool,
        retryDelay: TimeInterval
    ) {
        selectedIDs.remove(feedID)
        confirmedIDs.remove(feedID)

        if isCapacitySignal {
            mode = .stopped
            selectedIDs = confirmedIDs
            retryAfterByID.removeAll()
        } else {
            retryAfterByID[feedID] = date.addingTimeInterval(max(0, retryDelay))
        }
    }

    @discardableResult
    mutating func reconcile(
        priorityIDs: [String],
        streamingIDs: Set<String>,
        focusedID: String?,
        now: Date
    ) -> Set<String> {
        let eligibleIDs = Set(priorityIDs)
        selectedIDs.formIntersection(eligibleIDs)
        confirmedIDs.formIntersection(streamingIDs.intersection(eligibleIDs))
        retryAfterByID = retryAfterByID.filter { eligibleIDs.contains($0.key) }

        guard mode != .stopped else {
            selectedIDs = streamingIDs.intersection(eligibleIDs)
            confirmedIDs = selectedIDs
            return selectedIDs
        }

        if let focusedID,
           eligibleIDs.contains(focusedID),
           !selectedIDs.contains(focusedID) {
            if pendingIDs.count >= maxPendingCount,
               let preemptedID = priorityIDs.reversed().first(where: { pendingIDs.contains($0) }) {
                selectedIDs.remove(preemptedID)
            }
            selectedIDs.insert(focusedID)
        }

        for id in priorityIDs where pendingIDs.count < maxPendingCount {
            guard !selectedIDs.contains(id) else { continue }
            guard retryAfterByID[id].map({ $0 <= now }) ?? true else { continue }
            selectedIDs.insert(id)
        }

        if confirmedIDs == eligibleIDs {
            mode = .completed
            selectedIDs = eligibleIDs
        }
        return selectedIDs
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
        case .liveBurst(let liveIDs):
            liveSelection = ConstrainedLiveSelection(
                liveIDs: liveIDs,
                batteryCaptureIDs: [],
                batteryWaitingIDs: []
            )
        case .capacityRamp(let liveIDs):
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

import Foundation

enum PlannedPresentationMode: Equatable {
    case live
    case snapshot
}

enum SnapshotPriority: Int, Comparable, Equatable {
    case none = 0
    case refresh = 1
    case urgent = 2

    static func < (lhs: SnapshotPriority, rhs: SnapshotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
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
        return !BatteryWakeLeaseTimeoutPolicy.hasTimedOut(
            isStreaming: isStreaming,
            liveStartedAt: liveStartedAt,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            warmup: warmup,
            leaseDuration: leaseDuration,
            liveStartTimeout: liveStartTimeout,
            now: now
        ) && !capturedTrustedStillDuringLease(at: now)
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

    private func capturedTrustedStillDuringLease(at now: Date) -> Bool {
        guard let lastSnapshotDate,
              let batteryWakeLeaseStartedAt else {
            return false
        }

        return lastSnapshotDate >= batteryWakeLeaseStartedAt && hasTrustedImage(at: now)
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
        now: Date
    ) -> CameraRecoveryPlan {
        let prioritizedFeeds = feeds.sorted { $0.priorityIndex < $1.priorityIndex }
        let recencyByID = Dictionary(
            uniqueKeysWithValues: prioritizedFeeds.map {
                ($0.id, $0.recencyTier(at: now))
            }
        )

        let liveSelection: ConstrainedLiveSelection
        switch sessionMode {
        case .optimistic:
            liveSelection = ConstrainedLiveSelection(
                liveIDs: Set(prioritizedFeeds.map(\.id)),
                batteryCaptureIDs: [],
                batteryWaitingIDs: []
            )
        case .constrained:
            liveSelection = constrainedLiveSelection(
                feeds: prioritizedFeeds,
                liveCapacity: liveCapacity,
                now: now
            )
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

            return ConstrainedLiveSelection(
                liveIDs: Set(selectedIDs),
                batteryCaptureIDs: Set(batteryCaptureIDs),
                batteryWaitingIDs: batteryNeedingTrustedStillIDs.subtracting(batteryCaptureIDs)
            )
        }

        for feed in orderedFeeds where selectedIDs.count < capacity {
            guard !selectedIDs.contains(feed.id) else { continue }
            selectedIDs.append(feed.id)
        }

        return ConstrainedLiveSelection(
            liveIDs: Set(selectedIDs),
            batteryCaptureIDs: Set(batteryCaptureIDs),
            batteryWaitingIDs: []
        )
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

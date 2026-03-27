import Foundation

enum PlannedPresentationMode: Equatable {
    case live
    case snapshot
}

enum SnapshotPriority: Int, Equatable {
    case none = 0
    case maintenance = 1
    case urgent = 2
}

struct FeedPlanningSnapshot: Equatable {
    let id: String
    let priorityIndex: Int
    let isFocused: Bool
    let isStreaming: Bool
    let lastSnapshotDate: Date?
    let liveRecoveryLeaseStartedAt: Date?
    let liveRetryEligibleAt: Date?

    func recencyTier(at now: Date, staleSnapshotThreshold: TimeInterval) -> FeedRecencyTier {
        if isStreaming {
            return .live
        }

        guard let lastSnapshotDate else {
            return .empty
        }

        let age = max(0, now.timeIntervalSince(lastSnapshotDate))
        return age <= staleSnapshotThreshold ? .recentSnapshot : .staleSnapshot
    }

    func snapshotAge(at now: Date) -> TimeInterval? {
        guard let lastSnapshotDate else { return nil }
        return max(0, now.timeIntervalSince(lastSnapshotDate))
    }

    func hasActiveRecoveryLease(at now: Date, leaseDuration: TimeInterval) -> Bool {
        guard let liveRecoveryLeaseStartedAt else { return false }
        return now.timeIntervalSince(liveRecoveryLeaseStartedAt) < leaseDuration
    }

    func isEligibleForLiveRecovery(at now: Date) -> Bool {
        guard !isFocused else { return true }
        return (liveRetryEligibleAt ?? .distantPast) <= now
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
    let staleSnapshotThreshold: TimeInterval
    let liveRecoveryLeaseDuration: TimeInterval

    init(
        staleSnapshotThreshold: TimeInterval = CameraSchedulingDefaults.staleSnapshotThreshold,
        liveRecoveryLeaseDuration: TimeInterval = CameraSchedulingDefaults.liveRecoveryLeaseDuration
    ) {
        self.staleSnapshotThreshold = staleSnapshotThreshold
        self.liveRecoveryLeaseDuration = liveRecoveryLeaseDuration
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
                ($0.id, $0.recencyTier(at: now, staleSnapshotThreshold: staleSnapshotThreshold))
            }
        )

        let liveIDs: Set<String>
        switch sessionMode {
        case .optimistic:
            liveIDs = Set(prioritizedFeeds.map(\.id))
        case .constrained:
            liveIDs = constrainedLiveIDs(
                feeds: prioritizedFeeds,
                recencyByID: recencyByID,
                liveCapacity: liveCapacity,
                now: now
            )
        }

        var decisionsByID: [String: PresentationDecision] = [:]
        for feed in prioritizedFeeds {
            let recencyTier = recencyByID[feed.id] ?? .empty
            let wantsLive = liveIDs.contains(feed.id)
            let recoveryPhase: FeedRecoveryPhase

            switch recencyTier {
            case .live, .recentSnapshot:
                recoveryPhase = .idle
            case .staleSnapshot, .empty:
                recoveryPhase = wantsLive ? .liveRecovery : .snapshotRecovery
            }

            let snapshotPriority: SnapshotPriority
            switch recencyTier {
            case .live:
                snapshotPriority = .none
            case .recentSnapshot:
                snapshotPriority = wantsLive ? .none : .maintenance
            case .staleSnapshot, .empty:
                snapshotPriority = .urgent
            }

            decisionsByID[feed.id] = PresentationDecision(
                id: feed.id,
                presentationMode: wantsLive ? .live : .snapshot,
                recencyTier: recencyTier,
                recoveryPhase: recoveryPhase,
                snapshotPriority: snapshotPriority
            )
        }

        let orderedSnapshotIDs = prioritizedFeeds
            .filter { (decisionsByID[$0.id]?.snapshotPriority ?? .none) != .none }
            .sorted {
                let lhsDecision = decisionsByID[$0.id]
                let rhsDecision = decisionsByID[$1.id]
                let lhsPriority = lhsDecision?.snapshotPriority.rawValue ?? SnapshotPriority.none.rawValue
                let rhsPriority = rhsDecision?.snapshotPriority.rawValue ?? SnapshotPriority.none.rawValue

                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                let lhsAge = $0.snapshotAge(at: now) ?? .greatestFiniteMagnitude
                let rhsAge = $1.snapshotAge(at: now) ?? .greatestFiniteMagnitude
                if lhsAge != rhsAge {
                    return lhsAge > rhsAge
                }

                return $0.priorityIndex < $1.priorityIndex
            }
            .map(\.id)

        return CameraRecoveryPlan(decisionsByID: decisionsByID, orderedSnapshotIDs: orderedSnapshotIDs)
    }

    private func constrainedLiveIDs(
        feeds: [FeedPlanningSnapshot],
        recencyByID: [String: FeedRecencyTier],
        liveCapacity: Int,
        now: Date
    ) -> Set<String> {
        let capacity = max(0, min(liveCapacity, feeds.count))
        guard capacity > 0 else { return [] }

        func isRecoveryCandidate(_ feed: FeedPlanningSnapshot) -> Bool {
            guard let recencyTier = recencyByID[feed.id] else { return false }
            return recencyTier == .staleSnapshot || recencyTier == .empty
        }

        func recoverySort(lhs: FeedPlanningSnapshot, rhs: FeedPlanningSnapshot) -> Bool {
            let lhsAge = lhs.snapshotAge(at: now) ?? .greatestFiniteMagnitude
            let rhsAge = rhs.snapshotAge(at: now) ?? .greatestFiniteMagnitude
            if lhsAge != rhsAge {
                return lhsAge > rhsAge
            }
            return lhs.priorityIndex < rhs.priorityIndex
        }

        var selectedIDs: [String] = []

        if let focusedFeed = feeds.first(where: { $0.isFocused }) {
            selectedIDs.append(focusedFeed.id)
        }

        let leasedRecoveryFeeds = feeds
            .filter {
                !selectedIDs.contains($0.id)
                && !$0.isFocused
                && isRecoveryCandidate($0)
                && $0.hasActiveRecoveryLease(at: now, leaseDuration: liveRecoveryLeaseDuration)
            }
            .sorted(by: recoverySort)

        for feed in leasedRecoveryFeeds where selectedIDs.count < capacity {
            selectedIDs.append(feed.id)
        }

        let recoveryFeeds = feeds
            .filter {
                !selectedIDs.contains($0.id)
                && isRecoveryCandidate($0)
                && $0.isEligibleForLiveRecovery(at: now)
            }
            .sorted(by: recoverySort)

        for feed in recoveryFeeds where selectedIDs.count < capacity {
            selectedIDs.append(feed.id)
        }

        let healthyLiveFeeds = feeds
            .filter {
                !selectedIDs.contains($0.id)
                && (recencyByID[$0.id] == .live)
            }
            .sorted { $0.priorityIndex < $1.priorityIndex }

        for feed in healthyLiveFeeds where selectedIDs.count < capacity {
            selectedIDs.append(feed.id)
        }

        let remainingFeeds = feeds
            .filter { !selectedIDs.contains($0.id) }
            .sorted { $0.priorityIndex < $1.priorityIndex }

        for feed in remainingFeeds where selectedIDs.count < capacity {
            selectedIDs.append(feed.id)
        }

        return Set(selectedIDs)
    }
}

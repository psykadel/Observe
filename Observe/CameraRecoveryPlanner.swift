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
    let staleThreshold: TimeInterval
    let isBatteryWakeCamera: Bool
    let batteryWakeForceEligible: Bool
    let batteryWakeTriggerThreshold: TimeInterval
    let liveRecoveryLeaseStartedAt: Date?
    let liveRetryEligibleAt: Date?
    let batteryWakeLeaseStartedAt: Date?
    let batteryWakeCooldownUntil: Date?

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

    func hasActiveRecoveryLease(at now: Date, leaseDuration: TimeInterval) -> Bool {
        guard let liveRecoveryLeaseStartedAt else { return false }
        return now.timeIntervalSince(liveRecoveryLeaseStartedAt) < leaseDuration
    }

    func isEligibleForLiveRecovery(at now: Date) -> Bool {
        guard !isFocused else { return true }
        return (liveRetryEligibleAt ?? .distantPast) <= now
    }

    func hasActiveBatteryWakeLease(at now: Date, leaseDuration: TimeInterval) -> Bool {
        guard let batteryWakeLeaseStartedAt else { return false }
        return now.timeIntervalSince(batteryWakeLeaseStartedAt) < leaseDuration
    }

    func isEligibleForBatteryWake(at now: Date) -> Bool {
        guard isBatteryWakeCamera, !isFocused, !isStreaming else {
            return false
        }

        guard (batteryWakeCooldownUntil ?? .distantPast) <= now else {
            return false
        }

        guard let snapshotAge = snapshotAge(at: now) else {
            return true
        }

        guard batteryWakeForceEligible || snapshotAge >= batteryWakeTriggerThreshold else {
            return false
        }
        return true
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
    let maxConcurrentBatteryWakeFeeds: Int

    init(
        batteryWakeLeaseDuration: TimeInterval = CameraSchedulingDefaults.batteryWakeLeaseDuration,
        maxConcurrentBatteryWakeFeeds: Int = CameraSchedulingDefaults.maxConcurrentBatteryWakeFeeds
    ) {
        self.batteryWakeLeaseDuration = batteryWakeLeaseDuration
        self.maxConcurrentBatteryWakeFeeds = maxConcurrentBatteryWakeFeeds
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
            liveSelection = ConstrainedLiveSelection(liveIDs: Set(prioritizedFeeds.map(\.id)), batteryWakeIDs: [])
        case .constrained:
            liveSelection = constrainedLiveSelection(
                feeds: prioritizedFeeds,
                recencyByID: recencyByID,
                liveCapacity: liveCapacity,
                now: now
            )
        }

        var decisionsByID: [String: PresentationDecision] = [:]
        for feed in prioritizedFeeds {
            let recencyTier = recencyByID[feed.id] ?? .empty
            let wantsLive = liveSelection.liveIDs.contains(feed.id)
            let recoveryPhase: FeedRecoveryPhase
            if liveSelection.batteryWakeIDs.contains(feed.id) {
                recoveryPhase = .batteryWake
            } else {
                recoveryPhase = .idle
            }

            let snapshotPriority: SnapshotPriority
            if recoveryPhase == .batteryWake || feed.isBatteryWakeCamera {
                snapshotPriority = .none
            } else {
                switch recencyTier {
                case .live:
                    snapshotPriority = .none
                case .recentSnapshot:
                    snapshotPriority = wantsLive ? .none : .maintenance
                case .staleSnapshot, .empty:
                    snapshotPriority = .urgent
                }
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

    private func constrainedLiveSelection(
        feeds: [FeedPlanningSnapshot],
        recencyByID: [String: FeedRecencyTier],
        liveCapacity: Int,
        now: Date
    ) -> ConstrainedLiveSelection {
        let capacity = max(0, min(liveCapacity, feeds.count))
        guard capacity > 0 else {
            return ConstrainedLiveSelection(liveIDs: [], batteryWakeIDs: [])
        }

        func isBatteryWakeCandidate(_ feed: FeedPlanningSnapshot) -> Bool {
            feed.hasActiveBatteryWakeLease(at: now, leaseDuration: batteryWakeLeaseDuration)
                || feed.isEligibleForBatteryWake(at: now)
        }

        let orderedFeeds = feeds.sorted {
            if $0.isFocused != $1.isFocused {
                return $0.isFocused && !$1.isFocused
            }
            return $0.priorityIndex < $1.priorityIndex
        }

        var selectedIDs = Array(orderedFeeds.prefix(capacity).map(\.id))
        var batteryWakeIDs: [String] = []
        let focusedFeedID = orderedFeeds.first(where: { $0.isFocused })?.id

        if let captureCandidate = orderedFeeds.first(where: isBatteryWakeCandidate) {
            if selectedIDs.contains(captureCandidate.id) {
                batteryWakeIDs = [captureCandidate.id]
            } else if selectedIDs.count < capacity {
                selectedIDs.append(captureCandidate.id)
                batteryWakeIDs = [captureCandidate.id]
            } else if let replaceIndex = selectedIDs.lastIndex(where: { $0 != focusedFeedID }) {
                selectedIDs[replaceIndex] = captureCandidate.id
                batteryWakeIDs = [captureCandidate.id]
            }
        }

        return ConstrainedLiveSelection(
            liveIDs: Set(selectedIDs),
            batteryWakeIDs: Set(batteryWakeIDs)
        )
    }
}

private struct ConstrainedLiveSelection {
    let liveIDs: Set<String>
    let batteryWakeIDs: Set<String>
}

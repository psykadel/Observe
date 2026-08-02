import Foundation

struct FeedPlanningSnapshot: Equatable {
    let id: String
    let priorityIndex: Int
    let livePriorityIndex: Int
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

    func hasTrustedImage(at now: Date) -> Bool {
        if isBatteryWakeCamera {
            if isStreaming { return true }
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

    func hasActiveBatteryCapture() -> Bool {
        guard let batteryWakeLeaseStartedAt else { return false }
        if let lastSnapshotDate, lastSnapshotDate >= batteryWakeLeaseStartedAt {
            return false
        }
        return true
    }

    func needsBatteryCapture(at now: Date) -> Bool {
        guard isBatteryWakeCamera else { return false }
        if hasActiveBatteryCapture() {
            return true
        }
        if batteryWakeLeaseStartedAt != nil {
            return false
        }
        return !hasTrustedBatteryStill(at: now) && isBatteryWakeRetryEligible(at: now)
    }

    fileprivate func hasTrustedBatteryStill(at now: Date) -> Bool {
        guard isBatteryWakeCamera, let lastSnapshotDate else { return false }
        return max(0, now.timeIntervalSince(lastSnapshotDate)) <= batteryWakeTriggerThreshold
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
    func makePlan(
        feeds: [FeedPlanningSnapshot],
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
        let allowsSnapshotWork: Bool
        switch startupLivePolicy {
        case .homeNetwork(let liveIDs):
            allowsSnapshotWork = false
            liveSelection = ConstrainedLiveSelection(
                liveIDs: liveIDs,
                batteryCaptureIDs: [],
                batteryWaitingIDs: []
            )
        case .normal:
            allowsSnapshotWork = true
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

            let snapshotPriority: SnapshotPriority
            if !allowsSnapshotWork || (wantsLive && feed.hasTrustedImage(at: now)) {
                snapshotPriority = .none
            } else {
                snapshotPriority = feed.snapshotPriority(at: now)
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
        let orderedFeeds = feeds.sorted { $0.livePriorityIndex < $1.livePriorityIndex }
        let focusedFeed = orderedFeeds.first(where: { $0.isFocused })
        var permanentFeeds: [FeedPlanningSnapshot] = []

        if let focusedFeed {
            permanentFeeds.append(focusedFeed)
        }
        for feed in orderedFeeds where permanentFeeds.count < capacity {
            guard !permanentFeeds.contains(where: { $0.id == feed.id }) else { continue }
            permanentFeeds.append(feed)
        }

        let permanentIDs = Set(permanentFeeds.map(\.id))
        let batteryNeedingTrustedStillIDs = Set(orderedFeeds.compactMap { feed -> String? in
            guard feed.isBatteryWakeCamera,
                  !permanentIDs.contains(feed.id),
                  !feed.hasTrustedBatteryStill(at: now) else { return nil }
            return feed.id
        })

        guard capacity > 0 else {
            return ConstrainedLiveSelection(
                liveIDs: [],
                batteryCaptureIDs: [],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
            )
        }

        let activeCapture = orderedFeeds.first { feed in
            batteryNeedingTrustedStillIDs.contains(feed.id) && feed.hasActiveBatteryCapture()
        }
        let nextCapture = activeCapture ?? orderedFeeds.first { feed in
            batteryNeedingTrustedStillIDs.contains(feed.id)
                && feed.needsBatteryCapture(at: now)
        }

        if let nextCapture, !(capacity == 1 && focusedFeed != nil) {
            let selectedPermanentIDs = permanentFeeds.prefix(max(0, capacity - 1)).map(\.id)
            let selectedIDs = Set(selectedPermanentIDs + [nextCapture.id])
            let displacedPermanentBatteryIDs = Set(permanentFeeds.compactMap { feed -> String? in
                guard !selectedIDs.contains(feed.id),
                      feed.isBatteryWakeCamera,
                      !feed.hasTrustedBatteryStill(at: now) else { return nil }
                return feed.id
            })
            return ConstrainedLiveSelection(
                liveIDs: selectedIDs,
                batteryCaptureIDs: [nextCapture.id],
                batteryWaitingIDs: batteryNeedingTrustedStillIDs
                    .union(displacedPermanentBatteryIDs)
                    .subtracting([nextCapture.id])
            )
        }

        return ConstrainedLiveSelection(
            liveIDs: permanentIDs,
            batteryCaptureIDs: [],
            batteryWaitingIDs: batteryNeedingTrustedStillIDs
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

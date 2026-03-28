import Foundation
import HomeKit

@MainActor
final class HomeKitCameraStore: NSObject, ObservableObject {
    @Published private(set) var homes: [HomeOption] = []
    @Published private(set) var feeds: [CameraFeedCoordinator] = []
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus
    @Published private(set) var sessionMode: SessionMode = .optimistic
    @Published private(set) var homeHubState: HMHomeHubState = .notAvailable
    @Published private(set) var selectedHomeName: String?
    @Published private(set) var isAppActive = true
    @Published private(set) var focusedFeedID: String?
    @Published private(set) var liveCapacity = 0

    let preferences: ObservePreferences

    private let homeManager = HMHomeManager()
    private weak var selectedHome: HMHome?
    private var snapshotSchedulerTask: Task<Void, Never>?
    private var constraintEvaluationTask: Task<Void, Never>?
    private var lastLiveProbeAt: Date?
    private var liveProbeState: LiveProbeState?
    private var sessionStartedAt: Date?
    private var feedScheduleStates: [String: FeedScheduleState] = [:]
    private var currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
    private let recoveryPlanner = CameraRecoveryPlanner()

    private let maxConcurrentSnapshotRequests = 3
    private let snapshotSuccessInterval = CameraSchedulingDefaults.snapshotSuccessInterval
    private let snapshotRequestTimeout = CameraSchedulingDefaults.snapshotRequestTimeout
    private let staleSnapshotRetryThreshold = CameraSchedulingDefaults.staleSnapshotThreshold
    private let liveRecoveryLeaseDuration = CameraSchedulingDefaults.liveRecoveryLeaseDuration
    private let liveRecoveryRetryCooldown = CameraSchedulingDefaults.liveRecoveryRetryCooldown
    private let batteryCaptureWarmup = CameraSchedulingDefaults.batteryCaptureWarmup
    private let batteryWakeLeaseDuration = CameraSchedulingDefaults.batteryWakeLeaseDuration

    init(preferences: ObservePreferences) {
        self.preferences = preferences
        self.authorizationStatus = homeManager.authorizationStatus
        super.init()
        homeManager.delegate = self
        rebuildHomesAndFeeds()
    }

    var selectedHomeID: String? { preferences.selectedHomeID }

    var priorityOrderedFeeds: [CameraFeedCoordinator] {
        let normalized = preferences.normalizedPriority(availableIDs: feeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        return normalized.compactMap { feedLookup[$0] }
    }

    var wallFeeds: [CameraFeedCoordinator] {
        priorityOrderedFeeds.filter(\.isVisibleOnWall)
    }

    private var minimumLiveCapacity: Int {
        min(2, wallFeeds.count)
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active

        if active {
            startSession(forceSnapshotRefresh: true)
        } else {
            snapshotSchedulerTask?.cancel()
            constraintEvaluationTask?.cancel()
            feeds.forEach { $0.stopLiveIfNeeded() }
        }
    }

    func selectHome(id: String) {
        preferences.selectedHomeID = id
        rebuildHomesAndFeeds()
    }

    func movePriority(from source: IndexSet, to destination: Int) {
        preferences.movePriority(from: source, to: destination, availableIDs: feeds.map(\.id))
        objectWillChange.send()
        refreshPresentation(forceSnapshotRefresh: false, focusedFeedID: focusedFeedID)
    }

    func focusOn(feed: CameraFeedCoordinator) {
        focusedFeedID = feed.id
        refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: feed.id)
    }

    func clearFocus() {
        focusedFeedID = nil
        refreshPresentation(forceSnapshotRefresh: false, focusedFeedID: nil)
    }

    func adjustDensity(with scale: CGFloat) {
        preferences.adjustDensity(with: scale)
    }

    private func rebuildHomesAndFeeds() {
        homes = homeManager.homes
            .map { HomeOption(id: $0.uniqueIdentifier.uuidString, name: $0.name, isPrimary: $0.isPrimary) }
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary && !$1.isPrimary }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        let fallbackHomeID = homes.first(where: \.isPrimary)?.id ?? homes.first?.id
        if preferences.selectedHomeID == nil {
            preferences.selectedHomeID = fallbackHomeID
        }

        let targetHomeID = preferences.selectedHomeID ?? fallbackHomeID
        let home = homeManager.homes.first { $0.uniqueIdentifier.uuidString == targetHomeID } ?? homeManager.homes.first
        selectedHome = home
        selectedHomeName = home?.name
        homeHubState = home?.homeHubState ?? .notAvailable

        feeds.forEach { $0.stopLiveIfNeeded() }

        guard let home else {
            feeds = []
            feedScheduleStates = [:]
            currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
            liveCapacity = 0
            return
        }

        home.delegate = self

        var discoveredFeeds: [CameraFeedCoordinator] = []
        for accessory in home.accessories {
            accessory.delegate = self

            let profiles = accessory.cameraProfiles ?? []
            for (index, profile) in profiles.enumerated() {
                let feed = CameraFeedCoordinator(accessory: accessory, profile: profile, profileIndex: index)
                feed.onConstrainedSignal = { [weak self] feedID in
                    Task { @MainActor [weak self] in
                        self?.handleConstrainedSignal(from: feedID)
                    }
                }
                feed.onSnapshotResult = { [weak self] feedID, result in
                    Task { @MainActor [weak self] in
                        self?.handleSnapshotResult(for: feedID, result: result)
                    }
                }
                discoveredFeeds.append(feed)
            }
        }

        let priorityIDs = preferences.normalizedPriority(availableIDs: discoveredFeeds.map(\.id))
        let feedLookup = Dictionary(uniqueKeysWithValues: discoveredFeeds.map { ($0.id, $0) })
        feeds = priorityIDs.compactMap { feedLookup[$0] }

        feedScheduleStates = Dictionary(
            uniqueKeysWithValues: feeds.map { feed in
                (
                    feed.id,
                    FeedScheduleState(
                        lastSnapshotSuccessAt: feed.lastSnapshotDate,
                        snapshotInFlight: false,
                        snapshotRequestStartedAt: nil,
                        nextEligibleSnapshotAt: .distantPast,
                        consecutiveSnapshotFailures: 0,
                        liveRecoveryLeaseStartedAt: nil,
                        liveRetryEligibleAt: .distantPast,
                        batteryWakeLeaseStartedAt: nil,
                        batteryWakeCooldownUntil: .distantPast,
                        lastBatteryWakeAt: Date()
                    )
                )
            }
        )

        sessionMode = .optimistic
        liveCapacity = wallFeeds.count
        liveProbeState = nil
        lastLiveProbeAt = nil
        startSession(forceSnapshotRefresh: true)
    }

    private func startSession(forceSnapshotRefresh: Bool) {
        snapshotSchedulerTask?.cancel()
        constraintEvaluationTask?.cancel()
        liveProbeState = nil
        lastLiveProbeAt = nil
        sessionStartedAt = Date()

        guard isAppActive, !feeds.isEmpty else { return }

        refreshPresentation(forceSnapshotRefresh: forceSnapshotRefresh, focusedFeedID: focusedFeedID)

        snapshotSchedulerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self.handleSnapshotTimeouts()
                    self.refreshPresentation(forceSnapshotRefresh: false, focusedFeedID: self.focusedFeedID)
                    self.serviceSnapshotQueue()
                    self.evaluateLiveProbeIfNeeded()
                    self.startLiveProbeIfNeeded()
                }
            }
        }
    }

    private func refreshPresentation(forceSnapshotRefresh: Bool, focusedFeedID: String?) {
        guard isAppActive else { return }

        feeds.forEach { feed in
            feed.setBatteryWakeEnabled(preferences.isBatteryWakeCamera(id: feed.id))
            feed.setConfiguredStaleThreshold(
                preferences.isBatteryWakeCamera(id: feed.id)
                    ? preferences.batteryStaleThreshold
                    : preferences.staleVisualHighlightThreshold
            )
        }

        let now = Date()
        reconcileFeedScheduleStates(at: now, focusedFeedID: focusedFeedID)

        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        let liveBudget: Int
        switch sessionMode {
        case .optimistic:
            liveBudget = planningSnapshots.count
        case .constrained:
            liveBudget = max(minimumLiveCapacity, min(liveCapacity, planningSnapshots.count))
        }

        currentRecoveryPlan = recoveryPlanner.makePlan(
            feeds: planningSnapshots,
            sessionMode: sessionMode,
            liveCapacity: liveBudget,
            now: now
        )

        for feed in feeds {
            guard feed.isVisibleOnWall else {
                feed.stopLiveIfNeeded()
                continue
            }

            guard let decision = currentRecoveryPlan.decisionsByID[feed.id] else { continue }
            feed.updatePlanningStatus(recencyTier: decision.recencyTier, recoveryPhase: decision.recoveryPhase)
            updateBatteryWakeLease(for: feed.id, decision: decision, at: now, focusedFeedID: focusedFeedID)
            updateLiveRecoveryLease(for: feed.id, decision: decision, at: now, focusedFeedID: focusedFeedID)

            if decision.presentationMode == .live {
                feed.preferLive(at: now)
                updateBatteryCaptureTrust(for: feed.id, at: now)
            } else {
                feed.stopLiveIfNeeded()
                feed.presentSnapshotIfAvailable()
            }

            if forceSnapshotRefresh, decision.snapshotPriority != .none {
                queueImmediateSnapshot(for: feed.id, at: now)
            }
        }
    }

    private func planningSnapshots(at now: Date, focusedFeedID: String?) -> [FeedPlanningSnapshot] {
        wallFeeds.enumerated().map { index, feed in
            let state = feedScheduleStates[feed.id]
            let isBatteryWakeCamera = preferences.isBatteryWakeCamera(id: feed.id)
            let lastSnapshotDate = if isBatteryWakeCamera {
                feed.displayedStillDate
            } else {
                feed.displayedStillDate ?? state?.lastSnapshotSuccessAt
            }
            return FeedPlanningSnapshot(
                id: feed.id,
                priorityIndex: index,
                isFocused: feed.id == focusedFeedID,
                isStreaming: feed.isStreaming,
                lastSnapshotDate: lastSnapshotDate,
                staleThreshold: isBatteryWakeCamera ? preferences.batteryStaleThreshold : preferences.staleVisualHighlightThreshold,
                isBatteryWakeCamera: isBatteryWakeCamera,
                batteryWakeForceEligible: false,
                batteryWakeTriggerThreshold: preferences.batteryWakeTriggerThreshold,
                liveRecoveryLeaseStartedAt: state?.liveRecoveryLeaseStartedAt,
                liveRetryEligibleAt: state?.liveRetryEligibleAt,
                batteryWakeLeaseStartedAt: state?.batteryWakeLeaseStartedAt,
                batteryWakeCooldownUntil: state?.batteryWakeCooldownUntil
            )
        }
    }

    private func reconcileFeedScheduleStates(at now: Date, focusedFeedID: String?) {
        for feed in feeds {
            guard var state = feedScheduleStates[feed.id] else { continue }

            guard feed.isVisibleOnWall else {
                state.liveRecoveryLeaseStartedAt = nil
                state.liveRetryEligibleAt = .distantPast
                state.batteryWakeLeaseStartedAt = nil
                feedScheduleStates[feed.id] = state
                continue
            }

            let recencyTier = recencyTier(for: feed, state: state, now: now)
            if !preferences.isBatteryWakeCamera(id: feed.id) {
                state.batteryWakeLeaseStartedAt = nil
            } else if feed.id == focusedFeedID {
                if state.batteryWakeLeaseStartedAt != nil {
                    let didCaptureStill = didCaptureBatteryStill(for: feed.id, since: state.batteryWakeLeaseStartedAt)
                    state.batteryWakeLeaseStartedAt = nil
                    state.batteryWakeCooldownUntil = didCaptureStill
                        ? .distantPast
                        : now.addingTimeInterval(liveRecoveryRetryCooldown)
                    state.lastBatteryWakeAt = now
                }
            } else if let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt,
                      now.timeIntervalSince(batteryWakeLeaseStartedAt) >= batteryWakeLeaseDuration {
                let didCaptureStill = didCaptureBatteryStill(for: feed.id, since: state.batteryWakeLeaseStartedAt)
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeCooldownUntil = didCaptureStill
                    ? .distantPast
                    : now.addingTimeInterval(liveRecoveryRetryCooldown)
                state.lastBatteryWakeAt = now
                state.nextEligibleSnapshotAt = now
            }

            if feed.id == focusedFeedID || recencyTier == .live || recencyTier == .recentSnapshot {
                state.liveRecoveryLeaseStartedAt = nil
                state.liveRetryEligibleAt = .distantPast
            } else if let liveRecoveryLeaseStartedAt = state.liveRecoveryLeaseStartedAt,
                      now.timeIntervalSince(liveRecoveryLeaseStartedAt) >= liveRecoveryLeaseDuration {
                state.liveRecoveryLeaseStartedAt = nil
                state.liveRetryEligibleAt = now.addingTimeInterval(liveRecoveryRetryCooldown)
            }

            feedScheduleStates[feed.id] = state
        }
    }

    private func updateLiveRecoveryLease(
        for feedID: String,
        decision: PresentationDecision,
        at now: Date,
        focusedFeedID: String?
    ) {
        guard var state = feedScheduleStates[feedID] else { return }

        if feedID == focusedFeedID || decision.recoveryPhase != .liveRecovery || decision.recencyTier == .live {
            state.liveRecoveryLeaseStartedAt = nil
            if feedID == focusedFeedID || decision.recencyTier == .live || decision.recencyTier == .recentSnapshot {
                state.liveRetryEligibleAt = .distantPast
            }
            feedScheduleStates[feedID] = state
            return
        }

        if state.liveRecoveryLeaseStartedAt == nil {
            state.liveRecoveryLeaseStartedAt = now
            state.liveRetryEligibleAt = .distantPast
            feedScheduleStates[feedID] = state
        }
    }

    private func updateBatteryWakeLease(
        for feedID: String,
        decision: PresentationDecision,
        at now: Date,
        focusedFeedID: String?
    ) {
        guard var state = feedScheduleStates[feedID] else { return }

        if feedID == focusedFeedID {
            if state.batteryWakeLeaseStartedAt != nil {
                let didCaptureStill = didCaptureBatteryStill(for: feedID, since: state.batteryWakeLeaseStartedAt)
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeCooldownUntil = didCaptureStill
                    ? .distantPast
                    : now.addingTimeInterval(liveRecoveryRetryCooldown)
                state.lastBatteryWakeAt = now
                feedScheduleStates[feedID] = state
            }
            return
        }

        guard decision.recoveryPhase == .batteryWake else { return }
        guard state.batteryWakeLeaseStartedAt == nil else { return }

        state.batteryWakeLeaseStartedAt = now
        state.lastBatteryWakeAt = now
        state.nextEligibleSnapshotAt = .distantFuture
        state.liveRecoveryLeaseStartedAt = nil
        state.liveRetryEligibleAt = .distantPast
        feedScheduleStates[feedID] = state
    }

    private func updateBatteryCaptureTrust(for feedID: String, at now: Date) {
        guard let feed = feeds.first(where: { $0.id == feedID }),
              feed.isBatteryWakeCamera,
              feed.isStreaming,
              let state = feedScheduleStates[feedID],
              let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt else {
            return
        }

        guard now.timeIntervalSince(batteryWakeLeaseStartedAt) >= batteryCaptureWarmup else { return }
        guard (feed.batteryStillDate ?? .distantPast) < batteryWakeLeaseStartedAt else { return }

        feed.markBatteryStillCaptured(at: now)
    }

    @discardableResult
    private func concludeBatteryWake(for feedID: String, at date: Date, queueSnapshot: Bool) -> Bool {
        guard var state = feedScheduleStates[feedID], state.batteryWakeLeaseStartedAt != nil else {
            return false
        }

        let didCaptureStill = didCaptureBatteryStill(for: feedID, since: state.batteryWakeLeaseStartedAt)
        state.batteryWakeLeaseStartedAt = nil
        state.batteryWakeCooldownUntil = didCaptureStill
            ? .distantPast
            : date.addingTimeInterval(liveRecoveryRetryCooldown)
        state.lastBatteryWakeAt = date
        if queueSnapshot {
            state.nextEligibleSnapshotAt = date
        }
        feedScheduleStates[feedID] = state
        return true
    }

    private func didCaptureBatteryStill(for feedID: String, since leaseStartedAt: Date?) -> Bool {
        guard let leaseStartedAt,
              let feed = feeds.first(where: { $0.id == feedID }),
              let batteryStillDate = feed.batteryStillDate else {
            return false
        }

        return batteryStillDate >= leaseStartedAt
    }

    private func queueImmediateSnapshot(for feedID: String, at date: Date = Date()) {
        guard var state = feedScheduleStates[feedID] else { return }
        state.nextEligibleSnapshotAt = date
        feedScheduleStates[feedID] = state
    }

    private func serviceSnapshotQueue() {
        guard isAppActive else { return }
        let feedLookup = Dictionary(uniqueKeysWithValues: wallFeeds.map { ($0.id, $0) })
        let snapshotFeeds = currentRecoveryPlan.orderedSnapshotIDs.compactMap { feedLookup[$0] }
        let inFlightCount = snapshotFeeds.filter { feedScheduleStates[$0.id]?.snapshotInFlight == true }.count
        let availableSlots = maxConcurrentSnapshotRequests - inFlightCount

        guard availableSlots > 0 else { return }

        let now = Date()
        let dueFeeds = snapshotFeeds
            .filter { feed in
                guard let state = feedScheduleStates[feed.id] else { return false }
                guard !state.snapshotInFlight else { return false }
                return state.nextEligibleSnapshotAt <= now
            }
            .sorted { lhs, rhs in
                let lhsDecision = currentRecoveryPlan.decisionsByID[lhs.id]
                let rhsDecision = currentRecoveryPlan.decisionsByID[rhs.id]
                let lhsState = feedScheduleStates[lhs.id]
                let rhsState = feedScheduleStates[rhs.id]
                let lhsAge = snapshotAge(for: lhs, now: now)
                let rhsAge = snapshotAge(for: rhs, now: now)
                let lhsPriority = lhsDecision?.snapshotPriority.rawValue ?? SnapshotPriority.none.rawValue
                let rhsPriority = rhsDecision?.snapshotPriority.rawValue ?? SnapshotPriority.none.rawValue

                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                if lhsAge != rhsAge {
                    return lhsAge > rhsAge
                }

                if (lhsState?.consecutiveSnapshotFailures ?? 0) != (rhsState?.consecutiveSnapshotFailures ?? 0) {
                    return (lhsState?.consecutiveSnapshotFailures ?? 0) > (rhsState?.consecutiveSnapshotFailures ?? 0)
                }

                if lhsState?.nextEligibleSnapshotAt != rhsState?.nextEligibleSnapshotAt {
                    return lhsState?.nextEligibleSnapshotAt ?? .distantFuture < rhsState?.nextEligibleSnapshotAt ?? .distantFuture
                }

                return lhsState?.lastSnapshotSuccessAt ?? .distantPast < rhsState?.lastSnapshotSuccessAt ?? .distantPast
            }

        for feed in dueFeeds.prefix(availableSlots) {
            issueSnapshotRequest(for: feed, at: now)
        }
    }

    private func issueSnapshotRequest(for feed: CameraFeedCoordinator, at date: Date) {
        guard var state = feedScheduleStates[feed.id] else { return }
        guard !state.snapshotInFlight else { return }

        if feed.requestSnapshot() {
            state.snapshotInFlight = true
            state.snapshotRequestStartedAt = date
            state.nextEligibleSnapshotAt = .distantFuture
            feedScheduleStates[feed.id] = state
        } else {
            handleSnapshotFailure(for: feed.id, at: date)
        }
    }

    private func handleSnapshotResult(for feedID: String, result: SnapshotRequestResult) {
        switch result {
        case .success(let captureDate):
            guard var state = feedScheduleStates[feedID] else { return }
            state.lastSnapshotSuccessAt = captureDate
            state.snapshotInFlight = false
            state.snapshotRequestStartedAt = nil
            state.consecutiveSnapshotFailures = 0
            let now = Date()
            let snapshotAge = max(0, now.timeIntervalSince(captureDate))
            state.nextEligibleSnapshotAt = snapshotAge <= staleSnapshotRetryThreshold
                ? now.addingTimeInterval(snapshotSuccessInterval)
                : now
            feedScheduleStates[feedID] = state
        case .failure:
            handleSnapshotFailure(for: feedID, at: Date())
        }
    }

    private func handleSnapshotFailure(for feedID: String, at date: Date) {
        guard var state = feedScheduleStates[feedID] else { return }
        state.snapshotInFlight = false
        state.snapshotRequestStartedAt = nil
        state.consecutiveSnapshotFailures += 1
        state.nextEligibleSnapshotAt = date.addingTimeInterval(snapshotBackoff(for: state.consecutiveSnapshotFailures))
        feedScheduleStates[feedID] = state
    }

    private func handleSnapshotTimeouts() {
        let now = Date()

        for (feedID, state) in feedScheduleStates where state.snapshotInFlight {
            guard let snapshotRequestStartedAt = state.snapshotRequestStartedAt else { continue }
            if now.timeIntervalSince(snapshotRequestStartedAt) > snapshotRequestTimeout {
                handleSnapshotFailure(for: feedID, at: now)
            }
        }
    }

    private func snapshotBackoff(for failures: Int) -> TimeInterval {
        switch failures {
        case 0:
            snapshotSuccessInterval
        case 1:
            2
        case 2:
            3
        default:
            4
        }
    }

    private func snapshotAge(for feed: CameraFeedCoordinator, now: Date) -> TimeInterval {
        let lastSnapshotDate = effectiveStillDate(for: feed, state: feedScheduleStates[feed.id])
        guard let lastSnapshotDate else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(lastSnapshotDate)
    }

    private func recencyTier(for feed: CameraFeedCoordinator, state: FeedScheduleState, now: Date) -> FeedRecencyTier {
        if feed.isStreaming {
            return .live
        }

        let lastSnapshotDate = effectiveStillDate(for: feed, state: state)
        guard let lastSnapshotDate else { return .empty }
        let staleThreshold = feed.isBatteryWakeCamera ? preferences.batteryStaleThreshold : preferences.staleVisualHighlightThreshold
        return now.timeIntervalSince(lastSnapshotDate) <= staleThreshold ? .recentSnapshot : .staleSnapshot
    }

    private func effectiveStillDate(for feed: CameraFeedCoordinator, state: FeedScheduleState?) -> Date? {
        if feed.isBatteryWakeCamera {
            guard feed.cameraSource != nil else { return nil }
            return feed.displayedStillDate
        }
        return feed.displayedStillDate ?? state?.lastSnapshotSuccessAt
    }

    private func evaluateInitialLiveCapacityIfNeeded() {
        let visibleFeeds = wallFeeds
        guard sessionMode == .optimistic, visibleFeeds.count > 1 else {
            liveCapacity = visibleFeeds.count
            return
        }

        let liveCount = visibleFeeds.filter(\.isStreaming).count
        if liveCount < visibleFeeds.count {
            liveCapacity = max(minimumLiveCapacity, liveCount)
            enterConstrainedMode()
        } else {
            liveCapacity = visibleFeeds.count
        }
    }

    private func handleConstrainedSignal(from feedID: String) {
        let now = Date()
        if concludeBatteryWake(for: feedID, at: now, queueSnapshot: true) {
            refreshPresentation(forceSnapshotRefresh: false, focusedFeedID: focusedFeedID)
            return
        }

        if var state = feedScheduleStates[feedID] {
            state.liveRecoveryLeaseStartedAt = nil
            state.liveRetryEligibleAt = .distantPast
            feedScheduleStates[feedID] = state
        }
        queueImmediateSnapshot(for: feedID)

        let currentLiveCount = max(minimumLiveCapacity, wallFeeds.filter(\.isStreaming).count)

        if sessionMode == .optimistic {
            if let sessionStartedAt, now.timeIntervalSince(sessionStartedAt) < 8 {
                refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: focusedFeedID)
                return
            }
            liveCapacity = currentLiveCount
            enterConstrainedMode()
            return
        }

        if let liveProbeState {
            liveCapacity = max(minimumLiveCapacity, min(liveProbeState.previousCapacity, currentLiveCount))
            self.liveProbeState = nil
        } else {
            liveCapacity = max(minimumLiveCapacity, min(liveCapacity, currentLiveCount))
        }

        lastLiveProbeAt = now
        refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: focusedFeedID)
    }

    private func enterConstrainedMode() {
        guard sessionMode != .constrained else {
            refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: focusedFeedID)
            return
        }

        sessionMode = .constrained
        refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: focusedFeedID)
    }

    private func startLiveProbeIfNeeded() {
        guard sessionMode == .constrained else { return }
        guard liveProbeState == nil else { return }
        guard liveCapacity < wallFeeds.count else { return }

        let now = Date()
        if let lastLiveProbeAt, now.timeIntervalSince(lastLiveProbeAt) < 10 {
            return
        }

        let targetCapacity = min(liveCapacity + 1, wallFeeds.count)
        liveProbeState = LiveProbeState(
            previousCapacity: liveCapacity,
            targetCapacity: targetCapacity,
            startedAt: now
        )
        liveCapacity = targetCapacity
        refreshPresentation(forceSnapshotRefresh: false, focusedFeedID: focusedFeedID)
    }

    private func evaluateLiveProbeIfNeeded() {
        guard let liveProbeState else { return }

        let now = Date()
        guard now.timeIntervalSince(liveProbeState.startedAt) >= 3 else { return }

        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        if currentLiveCount >= liveProbeState.targetCapacity {
            liveCapacity = liveProbeState.targetCapacity
        } else {
            liveCapacity = max(minimumLiveCapacity, min(liveProbeState.previousCapacity, max(minimumLiveCapacity, currentLiveCount)))
            refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: focusedFeedID)
        }

        self.liveProbeState = nil
        lastLiveProbeAt = now
    }
}

extension HomeKitCameraStore: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = manager.authorizationStatus
            self.rebuildHomesAndFeeds()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            self.rebuildHomesAndFeeds()
        }
    }
}

extension HomeKitCameraStore: HMHomeDelegate {
    nonisolated func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.homeHubState = homeHubState
        }
    }

    nonisolated func home(_ home: HMHome, didEncounterError error: any Error, for accessory: HMAccessory) {
        Task { @MainActor in
            _ = error
            _ = accessory
        }
    }
}

extension HomeKitCameraStore: HMAccessoryDelegate {
    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach { feed in
                feed.markOfflineIfNeeded()
                guard var state = self.feedScheduleStates[feed.id] else { return }
                state.liveRecoveryLeaseStartedAt = nil
                state.liveRetryEligibleAt = .distantPast
                state.batteryWakeLeaseStartedAt = nil
                state.batteryWakeCooldownUntil = .distantPast
                state.nextEligibleSnapshotAt = .distantPast
                self.feedScheduleStates[feed.id] = state
            }

            let visibleCount = self.wallFeeds.count
            if visibleCount == 0 {
                self.liveCapacity = 0
            } else {
                self.liveCapacity = min(max(self.minimumLiveCapacity, self.liveCapacity), visibleCount)
            }

            self.refreshPresentation(forceSnapshotRefresh: true, focusedFeedID: self.focusedFeedID)
        }
    }

    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach {
                $0.refreshMetadata()
            }
        }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            self?.rebuildHomesAndFeeds()
        }
    }
}

private struct FeedScheduleState {
    var lastSnapshotSuccessAt: Date?
    var snapshotInFlight: Bool
    var snapshotRequestStartedAt: Date?
    var nextEligibleSnapshotAt: Date
    var consecutiveSnapshotFailures: Int
    var liveRecoveryLeaseStartedAt: Date?
    var liveRetryEligibleAt: Date
    var batteryWakeLeaseStartedAt: Date?
    var batteryWakeCooldownUntil: Date
    var lastBatteryWakeAt: Date?
}

private struct LiveProbeState {
    let previousCapacity: Int
    let targetCapacity: Int
    let startedAt: Date
}

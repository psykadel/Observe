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
    private var feedScheduleStates: [String: FeedScheduleState] = [:]
    private var currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
    private var liveCapacityExpansionBlockedUntil: Date?

    private let maxConcurrentSnapshotRequests = 3
    private let snapshotRequestTimeout = CameraSchedulingDefaults.snapshotRequestTimeout

    private var batteryCaptureWarmup: TimeInterval {
        preferences.batteryCaptureWarmupThreshold
    }

    private var batteryWakeLeaseDuration: TimeInterval {
        max(
            CameraSchedulingDefaults.batteryWakeLeaseDuration,
            batteryCaptureWarmup + CameraSchedulingDefaults.batteryCaptureLeasePadding
        )
    }

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

    func setAppActive(_ active: Bool) {
        isAppActive = active

        if active {
            focusedFeedID = nil
            rebuildHomesAndFeeds()
        } else {
            snapshotSchedulerTask?.cancel()
            focusedFeedID = nil
            liveCapacity = 0
            liveCapacityExpansionBlockedUntil = nil
            currentRecoveryPlan = CameraRecoveryPlan(decisionsByID: [:], orderedSnapshotIDs: [])
            feeds.forEach { $0.resetSessionState() }
        }
    }

    func selectHome(id: String) {
        preferences.selectedHomeID = id
        rebuildHomesAndFeeds()
    }

    func movePriority(from source: IndexSet, to destination: Int) {
        preferences.movePriority(from: source, to: destination, availableIDs: feeds.map(\.id))
        objectWillChange.send()
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    func focusOn(feed: CameraFeedCoordinator) {
        focusedFeedID = feed.id
        refreshPresentation(focusedFeedID: feed.id)
    }

    func clearFocus() {
        focusedFeedID = nil
        refreshPresentation(focusedFeedID: nil)
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
            liveCapacityExpansionBlockedUntil = nil
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
                        batteryWakeLeaseStartedAt: nil
                    )
                )
            }
        )

        sessionMode = .optimistic
        liveCapacity = wallFeeds.count
        liveCapacityExpansionBlockedUntil = nil
        startSession()
    }

    private func startSession() {
        snapshotSchedulerTask?.cancel()

        guard isAppActive, !feeds.isEmpty else { return }

        refreshPresentation(focusedFeedID: focusedFeedID)

        snapshotSchedulerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self.handleSnapshotTimeouts()
                    self.refreshPresentation(focusedFeedID: self.focusedFeedID)
                    self.serviceSnapshotQueue()
                }
            }
        }
    }

    private func refreshPresentation(focusedFeedID: String?) {
        guard isAppActive else { return }

        feeds.forEach { feed in
            feed.setBatteryWakeEnabled(preferences.isBatteryWakeCamera(id: feed.id))
            feed.setConfiguredStaleThreshold(
                preferences.isBatteryWakeCamera(id: feed.id)
                    ? preferences.batteryStaleThreshold
                    : preferences.staleVisualHighlightThreshold
            )
            feed.setConfiguredBatteryTrustedStillThreshold(preferences.batteryWakeTriggerThreshold)
        }

        let now = Date()
        reconcileFeedScheduleStates(at: now, focusedFeedID: focusedFeedID)

        let planningSnapshots = planningSnapshots(at: now, focusedFeedID: focusedFeedID)
        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        let liveBudget: Int
        switch sessionMode {
        case .optimistic:
            liveBudget = planningSnapshots.count
        case .constrained:
            liveCapacity = RestrictedLiveCapacity.recordSuccessfulStreams(
                previousCapacity: liveCapacity,
                currentLiveCount: currentLiveCount,
                visibleFeedCount: planningSnapshots.count
            )
            let canProbeCapacity = liveCapacityExpansionBlockedUntil.map { now >= $0 } ?? true
            let allVisibleFeedsTrusted = !planningSnapshots.isEmpty && planningSnapshots.allSatisfy {
                $0.hasTrustedImage(at: now)
            }
            liveBudget = RestrictedLiveCapacity.planningBudget(
                knownCapacity: liveCapacity,
                visibleFeedCount: planningSnapshots.count,
                allVisibleFeedsTrusted: allVisibleFeedsTrusted,
                canProbeCapacity: canProbeCapacity
            )
        }

        currentRecoveryPlan = CameraRecoveryPlanner(
            batteryWakeLeaseDuration: batteryWakeLeaseDuration
        ).makePlan(
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
            updateBatteryWakeLease(for: feed.id, decision: decision, at: now)

            if decision.presentationMode == .live {
                feed.preferLive(at: now)
                updateBatteryCaptureTrust(for: feed.id, at: now)
            } else {
                feed.stopLiveIfNeeded()
                feed.presentSnapshotIfAvailable()
            }

            if decision.snapshotPriority != .none {
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
                batteryWakeTriggerThreshold: preferences.batteryWakeTriggerThreshold,
                batteryWakeLeaseStartedAt: state?.batteryWakeLeaseStartedAt
            )
        }
    }

    private func reconcileFeedScheduleStates(at now: Date, focusedFeedID: String?) {
        for feed in feeds {
            guard var state = feedScheduleStates[feed.id] else { continue }

            guard feed.isVisibleOnWall, preferences.isBatteryWakeCamera(id: feed.id) else {
                state.batteryWakeLeaseStartedAt = nil
                feedScheduleStates[feed.id] = state
                continue
            }

            if let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt,
                      now.timeIntervalSince(batteryWakeLeaseStartedAt) >= batteryWakeLeaseDuration {
                state.batteryWakeLeaseStartedAt = nil
                state.nextEligibleSnapshotAt = now
            }

            feedScheduleStates[feed.id] = state
        }
    }

    private func updateBatteryWakeLease(
        for feedID: String,
        decision: PresentationDecision,
        at now: Date
    ) {
        guard var state = feedScheduleStates[feedID] else { return }

        guard preferences.isBatteryWakeCamera(id: feedID) else {
            state.batteryWakeLeaseStartedAt = nil
            feedScheduleStates[feedID] = state
            return
        }

        guard decision.recoveryPhase == .batteryCapture else { return }
        guard state.batteryWakeLeaseStartedAt == nil else { return }

        state.batteryWakeLeaseStartedAt = now
        state.nextEligibleSnapshotAt = .distantFuture
        feedScheduleStates[feedID] = state
    }

    private func updateBatteryCaptureTrust(for feedID: String, at now: Date) {
        guard let feed = feeds.first(where: { $0.id == feedID }),
              feed.isBatteryWakeCamera,
              feed.isStreaming,
              var state = feedScheduleStates[feedID],
              let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt else {
            return
        }

        guard now.timeIntervalSince(batteryWakeLeaseStartedAt) >= batteryCaptureWarmup else { return }
        guard (feed.batteryStillDate ?? .distantPast) < batteryWakeLeaseStartedAt else { return }

        feed.markBatteryStillCaptured(at: now)
        state.batteryWakeLeaseStartedAt = nil
        state.nextEligibleSnapshotAt = now
        feedScheduleStates[feedID] = state
    }

    @discardableResult
    private func concludeBatteryWake(for feedID: String, at date: Date) -> Bool {
        guard var state = feedScheduleStates[feedID], state.batteryWakeLeaseStartedAt != nil else {
            return false
        }

        state.batteryWakeLeaseStartedAt = nil
        state.nextEligibleSnapshotAt = date
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
            state.nextEligibleSnapshotAt = .distantFuture
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
            0
        case 1:
            2
        case 2:
            3
        default:
            4
        }
    }

    private func effectiveStillDate(for feed: CameraFeedCoordinator, state: FeedScheduleState?) -> Date? {
        if feed.isBatteryWakeCamera {
            guard feed.cameraSource != nil else { return nil }
            return feed.displayedStillDate
        }
        return feed.displayedStillDate ?? state?.lastSnapshotSuccessAt
    }

    private func handleConstrainedSignal(from feedID: String) {
        let now = Date()
        if keepBatteryWakeLeaseAliveAfterConstrainedSignal(for: feedID, at: now) {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        if concludeBatteryWake(for: feedID, at: now) {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        queueImmediateSnapshot(for: feedID)
        liveCapacityExpansionBlockedUntil = now.addingTimeInterval(
            CameraSchedulingDefaults.liveCapacityExpansionRetryDelay
        )

        let currentLiveCount = wallFeeds.filter(\.isStreaming).count
        let visibleFeedCount = wallFeeds.count

        if sessionMode == .optimistic {
            liveCapacity = RestrictedLiveCapacity.enteringAfterConstrainedSignal(
                currentLiveCount: currentLiveCount,
                visibleFeedCount: visibleFeedCount
            )
            enterConstrainedMode()
            return
        }

        liveCapacity = RestrictedLiveCapacity.afterConstrainedSignal(
            previousCapacity: liveCapacity,
            currentLiveCount: currentLiveCount,
            visibleFeedCount: visibleFeedCount
        )
        refreshPresentation(focusedFeedID: focusedFeedID)
    }

    private func keepBatteryWakeLeaseAliveAfterConstrainedSignal(for feedID: String, at now: Date) -> Bool {
        guard preferences.isBatteryWakeCamera(id: feedID),
              var state = feedScheduleStates[feedID],
              let batteryWakeLeaseStartedAt = state.batteryWakeLeaseStartedAt,
              !didCaptureBatteryStill(for: feedID, since: batteryWakeLeaseStartedAt),
              now.timeIntervalSince(batteryWakeLeaseStartedAt) < batteryWakeLeaseDuration else {
            return false
        }

        state.nextEligibleSnapshotAt = .distantFuture
        feedScheduleStates[feedID] = state
        return true
    }

    private func enterConstrainedMode() {
        guard sessionMode != .constrained else {
            refreshPresentation(focusedFeedID: focusedFeedID)
            return
        }

        sessionMode = .constrained
        refreshPresentation(focusedFeedID: focusedFeedID)
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
                state.batteryWakeLeaseStartedAt = nil
                state.nextEligibleSnapshotAt = .distantPast
                self.feedScheduleStates[feed.id] = state
            }

            let visibleCount = self.wallFeeds.count
            self.liveCapacity = min(self.liveCapacity, visibleCount)
            if visibleCount == 0 {
                self.liveCapacityExpansionBlockedUntil = nil
            }

            self.refreshPresentation(focusedFeedID: self.focusedFeedID)
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
    var batteryWakeLeaseStartedAt: Date?
}

enum RestrictedLiveCapacity {
    static func enteringAfterConstrainedSignal(currentLiveCount: Int, visibleFeedCount: Int) -> Int {
        boundedCapacity(observedLiveCount: currentLiveCount, visibleFeedCount: visibleFeedCount)
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
        guard allVisibleFeedsTrusted, canProbeCapacity else {
            return boundedKnownCapacity
        }

        return min(visibleFeedCount, boundedKnownCapacity + 1)
    }

    static func afterConstrainedSignal(
        previousCapacity: Int,
        currentLiveCount: Int,
        visibleFeedCount: Int
    ) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        let observedCapacity = boundedCapacity(
            observedLiveCount: max(previousCapacity, currentLiveCount),
            visibleFeedCount: visibleFeedCount
        )
        return min(max(1, observedCapacity), visibleFeedCount)
    }

    private static func boundedCapacity(observedLiveCount: Int, visibleFeedCount: Int) -> Int {
        guard visibleFeedCount > 0 else { return 0 }

        return min(max(1, observedLiveCount), visibleFeedCount)
    }
}

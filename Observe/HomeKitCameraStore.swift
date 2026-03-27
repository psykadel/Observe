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
    private var snapshotStates: [String: SnapshotScheduleState] = [:]

    private let maxConcurrentSnapshotRequests = 3
    private let snapshotSuccessInterval: TimeInterval = 2
    private let snapshotRequestTimeout: TimeInterval = 2.75
    private let staleSnapshotRetryThreshold: TimeInterval = 10

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
            snapshotStates = [:]
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

        snapshotStates = Dictionary(
            uniqueKeysWithValues: feeds.map { feed in
                (
                    feed.id,
                    SnapshotScheduleState(
                        lastSnapshotSuccessAt: feed.lastSnapshotDate,
                        snapshotInFlight: false,
                        snapshotRequestStartedAt: nil,
                        nextEligibleSnapshotAt: .distantPast,
                        consecutiveSnapshotFailures: 0
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

        guard isAppActive, !feeds.isEmpty else { return }

        refreshPresentation(forceSnapshotRefresh: forceSnapshotRefresh, focusedFeedID: focusedFeedID)

        snapshotSchedulerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self.handleSnapshotTimeouts()
                    self.serviceSnapshotQueue()
                    self.evaluateLiveProbeIfNeeded()
                    self.startLiveProbeIfNeeded()
                }
            }
        }

        constraintEvaluationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                self?.evaluateInitialLiveCapacityIfNeeded()
            }
        }
    }

    private func refreshPresentation(forceSnapshotRefresh: Bool, focusedFeedID: String?) {
        guard isAppActive else { return }

        let liveIDs = Set(desiredLiveIDs(focusedFeedID: focusedFeedID))
        let now = Date()

        for feed in feeds {
            guard feed.isVisibleOnWall else {
                feed.stopLiveIfNeeded()
                continue
            }

            if liveIDs.contains(feed.id) {
                feed.preferLive()
            } else {
                feed.stopLiveIfNeeded()
                feed.presentSnapshotIfAvailable()

                if forceSnapshotRefresh || snapshotStates[feed.id]?.lastSnapshotSuccessAt == nil {
                    queueImmediateSnapshot(for: feed.id, at: now)
                }
            }
        }
    }

    private func desiredLiveIDs(focusedFeedID: String?) -> [String] {
        let orderedIDs = wallFeeds.map(\.id)

        switch sessionMode {
        case .optimistic:
            return orderedIDs
        case .constrained:
            let budget = max(minimumLiveCapacity, min(liveCapacity, orderedIDs.count))
            var desired: [String] = []

            if let focusedFeedID, orderedIDs.contains(focusedFeedID) {
                desired.append(focusedFeedID)
            }

            for id in orderedIDs where !desired.contains(id) {
                desired.append(id)
                if desired.count == budget {
                    break
                }
            }

            return desired
        }
    }

    private func queueImmediateSnapshot(for feedID: String, at date: Date = Date()) {
        guard var state = snapshotStates[feedID] else { return }
        state.nextEligibleSnapshotAt = date
        snapshotStates[feedID] = state
    }

    private func serviceSnapshotQueue() {
        guard isAppActive else { return }

        let liveIDs = Set(desiredLiveIDs(focusedFeedID: focusedFeedID))
        let snapshotFeeds = wallFeeds.filter { !liveIDs.contains($0.id) }
        let inFlightCount = snapshotFeeds.filter { snapshotStates[$0.id]?.snapshotInFlight == true }.count
        let availableSlots = maxConcurrentSnapshotRequests - inFlightCount

        guard availableSlots > 0 else { return }

        let now = Date()
        let dueFeeds = snapshotFeeds
            .filter { feed in
                guard let state = snapshotStates[feed.id] else { return false }
                guard !state.snapshotInFlight else { return false }

                if state.nextEligibleSnapshotAt <= now {
                    return true
                }

                return snapshotAge(for: feed, now: now) >= staleSnapshotRetryThreshold
            }
            .sorted { lhs, rhs in
                let lhsState = snapshotStates[lhs.id]
                let rhsState = snapshotStates[rhs.id]
                let lhsAge = snapshotAge(for: lhs, now: now)
                let rhsAge = snapshotAge(for: rhs, now: now)
                let lhsIsStale = lhsAge >= staleSnapshotRetryThreshold
                let rhsIsStale = rhsAge >= staleSnapshotRetryThreshold

                if lhsIsStale != rhsIsStale {
                    return lhsIsStale && !rhsIsStale
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
        guard var state = snapshotStates[feed.id] else { return }
        guard !state.snapshotInFlight else { return }

        if feed.requestSnapshot() {
            state.snapshotInFlight = true
            state.snapshotRequestStartedAt = date
            state.nextEligibleSnapshotAt = .distantFuture
            snapshotStates[feed.id] = state
        } else {
            handleSnapshotFailure(for: feed.id, at: date)
        }
    }

    private func handleSnapshotResult(for feedID: String, result: SnapshotRequestResult) {
        switch result {
        case .success(let captureDate):
            guard var state = snapshotStates[feedID] else { return }
            state.lastSnapshotSuccessAt = captureDate
            state.snapshotInFlight = false
            state.snapshotRequestStartedAt = nil
            state.consecutiveSnapshotFailures = 0
            state.nextEligibleSnapshotAt = Date().addingTimeInterval(snapshotSuccessInterval)
            snapshotStates[feedID] = state
        case .failure:
            handleSnapshotFailure(for: feedID, at: Date())
        }
    }

    private func handleSnapshotFailure(for feedID: String, at date: Date) {
        guard var state = snapshotStates[feedID] else { return }
        state.snapshotInFlight = false
        state.snapshotRequestStartedAt = nil
        state.consecutiveSnapshotFailures += 1
        state.nextEligibleSnapshotAt = date.addingTimeInterval(snapshotBackoff(for: state.consecutiveSnapshotFailures))
        snapshotStates[feedID] = state
    }

    private func handleSnapshotTimeouts() {
        let now = Date()

        for (feedID, state) in snapshotStates where state.snapshotInFlight {
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
        let lastSnapshotDate = feed.lastSnapshotDate ?? snapshotStates[feed.id]?.lastSnapshotSuccessAt
        guard let lastSnapshotDate else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(lastSnapshotDate)
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
        let currentLiveCount = max(minimumLiveCapacity, wallFeeds.filter(\.isStreaming).count)

        if sessionMode == .optimistic {
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

        lastLiveProbeAt = Date()
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
            if homeHubState != .connected {
                self.enterConstrainedMode()
            }
        }
    }

    nonisolated func home(_ home: HMHome, didEncounterError error: any Error, for accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error = error as NSError?, HMError.Code(rawValue: error.code) == .noHomeHub {
                self.enterConstrainedMode()
            }
        }
    }
}

extension HomeKitCameraStore: HMAccessoryDelegate {
    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feeds.filter { $0.accessoryID == accessory.uniqueIdentifier.uuidString }.forEach {
                $0.markOfflineIfNeeded()
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

private struct SnapshotScheduleState {
    var lastSnapshotSuccessAt: Date?
    var snapshotInFlight: Bool
    var snapshotRequestStartedAt: Date?
    var nextEligibleSnapshotAt: Date
    var consecutiveSnapshotFailures: Int
}

private struct LiveProbeState {
    let previousCapacity: Int
    let targetCapacity: Int
    let startedAt: Date
}
